#!/usr/bin/env python3
"""Minimal nginx-equivalent reverse proxy with Basic Auth for testing
dsh-emacs against a non-directly-accessible dsh server.

Simulates nginx `auth_basic` + `proxy_pass`:
  - request without/invalid `Authorization: Basic` -> 401
  - valid credential         -> forwarded to the real dsh server
  - WebSocket upgrade        -> forwarded to the real dsh server as-is
                               (HTTP/1.1 101 handled by the TCP relay)

Usage: python3 basic-auth-proxy.py [listen_port] [user:pass] [target_host:port]
Example: python3 basic-auth-proxy.py 3081 alice:secret 127.0.0.1:3080
"""
import base64
import select
import socket
import socketserver
import sys


def relay_tcp(src, dst):
    """Bidirectional copy until both sides are done (used post-101 upgrade)."""
    try:
        while True:
            r, _, _ = select.select([src, dst], [], [], 30)
            if not r:
                break
            for s in r:
                data = s.recv(65536)
                if not data:
                    return
                (dst if s is src else src).sendall(data)
    except OSError:
        pass
    finally:
        try:
            src.close()
        except OSError:
            pass
        try:
            dst.close()
        except OSError:
            pass


class AuthHandler(socketserver.BaseRequestHandler):
    def handle(self):
        userpass = self.server.auth_userpass
        target = self.server.target
        expected = "Basic " + base64.b64encode(userpass.encode()).decode()
        client = self.request
        # Read the request head
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = client.recv(65536)
            if not chunk:
                return
            data += chunk
            if len(data) > 1 << 20:
                return
        head, _, rest = data.partition(b"\r\n\r\n")
        lines = head.split(b"\r\n")
        request_line = lines[0]
        headers = {}
        for line in lines[1:]:
            if b":" in line:
                k, _, v = line.partition(b":")
                headers[k.strip().lower()] = v.strip()
        auth = headers.get(b"authorization", b"").decode()
        if auth != expected:
            body = b'<html>401 Unauthorized</html>'
            client.sendall(
                b"HTTP/1.1 401 Unauthorized\r\n"
                b"Content-Type: text/html\r\n"
                b"Content-Length: " + str(len(body)).encode() + b"\r\n"
                b"WWW-Authenticate: Basic realm=\"dsh-test\"\r\n"
                b"\r\n" + body)
            client.close()
            return
        # Forward verbatim (request line + headers + any extra bytes)
        method, path, _ = request_line.decode().split(" ", 2)
        upgrade = headers.get(b"upgrade", b"").lower() == b"websocket"
        upstream = socket.create_connection(target, timeout=10)
        outbound = b"%s %s HTTP/1.1\r\n" % (method.encode(), path.encode())
        for k, v in headers.items():
            if k in (b"proxy-connection",):
                continue
            outbound += k + b": " + v + b"\r\n"
        # WebSocket upgrade must keep Connection: Upgrade; plain requests
        # downgrade to close so no keep-alive bookkeeping is needed here.
        if not upgrade:
            outbound += b"Connection: close\r\n"
        outbound += b"\r\n"
        upstream.sendall(outbound)
        if rest:
            upstream.sendall(rest)
        # Read upstream response head; if 101 (websocket), relay raw from here.
        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = upstream.recv(65536)
            if not chunk:
                break
            resp += chunk
        status_line = resp.split(b"\r\n", 1)[0]
        client.sendall(resp)
        if b" 101 " in status_line:
            # Websocket: keep relaying raw bytes both ways.
            relay_tcp(client, upstream)
        else:
            # Plain HTTP: forward remaining response body then close.
            try:
                while True:
                    chunk = upstream.recv(65536)
                    if not chunk:
                        break
                    client.sendall(chunk)
            except OSError:
                pass
            client.close()
            upstream.close()


class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, addr, handler, auth_userpass, target):
        self.auth_userpass = auth_userpass
        self.target = target
        super().__init__(addr, handler)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 3081
    userpass = sys.argv[2] if len(sys.argv) > 2 else "alice:secret"
    hostport = sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1:3080"
    target = (hostport.split(":")[0], int(hostport.split(":")[1]))
    server = ThreadedTCPServer(("127.0.0.1", port), AuthHandler, userpass, target)
    print(f"basic-auth proxy on 127.0.0.1:{port} -> {hostport} (creds {userpass})")
    server.serve_forever()


if __name__ == "__main__":
    main()