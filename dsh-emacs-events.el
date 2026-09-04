;;; dsh-emacs-events.el --- dsh WebSocket event stream -*- lexical-binding: t; no-native-compile: t -*-

;; Copyright (C) 2026 vritser
;; License: GPL-3.0-or-later

;;; Commentary:
;;
;; dsh Web multiplexes all logical Remote streams over one long-lived
;; WebSocket, `/api/remote.mux'.  A chat buffer opens a `session/follow'
;; stream whose snapshot seeds the transcript and whose `event' items
;; render live; a core connection (the session list's) opens
;; `session/control' + `workspace/follow' + `$events'.  This module
;; implements the small RFC 6455 client needed by those endpoints directly
;; on top of `open-network-stream', then routes each decoded frame:
;; follow items to the chat renderer, control/workspace frames to the
;; shared caches, and `$events' frames to session-list updates plus the
;; question / approval waterfalls (answered via `$events/result', see
;; `dsh-emacs--question-requested' / `dsh-emacs--approval-requested' in
;; dsh-emacs.el).

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'url-parse)

(defvar-local dsh-emacs--event-process nil)
(defvar-local dsh-emacs--event-ready nil)
(defvar-local dsh-emacs--event-reconnect-timer nil)
(defvar-local dsh-emacs--event-connect-timer nil)

;; Last wall-clock time (float-time) at which the stream delivered an event,
;; and watchdog bookkeeping for confirming the stream stays healthy mid-turn.
(defvar-local dsh-emacs--ws-last-event-time nil)
(defvar-local dsh-emacs--ws-last-probe-time nil)
(defvar-local dsh-emacs--ws-probe-inflight nil)
(defvar-local dsh-emacs--ws-watchdog-timer nil)

(defun dsh-emacs-events--stream-id ()
  "Return a fresh client stream id for a `/api/remote.mux' logical stream."
  (format "emacs-%d-%d" (random 999999) (truncate (float-time))))

(defun dsh-emacs-events--open-message (stream-id endpoint args)
  "JSON text of a `/api/remote.mux' `open' message.
Opens logical stream STREAM-ID at ENDPOINT (e.g. \"session/follow\")
with ARGS, the content of the wire `args' object (an alist, or nil for
no parameters) — the frame payload is exactly `{args: {...}}' (rpc.md
§3.1/§3.2)."
  (json-encode
   `((type . "open")
     (streamId . ,stream-id)
     (endpoint . ,endpoint)
     (payload . ,(list (cons 'args
                             (or args (make-hash-table))))))))

(defun dsh-emacs-events--cancel-message (stream-id)
  "JSON text of a `/api/remote.mux' `cancel' message for STREAM-ID.
Tells the host to close the logical stream STREAM-ID and stop sending its
frames (rpc.md §3.1); the socket stays up for the other multiplexed
streams.  Lets a caller retire one logical stream (e.g. the
`workspace/follow' stream before it re-opens a fresh one for a re-baseline)
without tearing down the whole core connection."
  (json-encode `((type . "cancel") (streamId . ,stream-id))))

(defun dsh-emacs-events--message-frame (json)
  "Parse one `/api/remote.mux' text message JSON into a plist.
Returns (:type TYPE :stream-id ID [:value VALUE] [:error ERROR])
following the server frame vocabulary (`item' carries :value, `error'
carries :error, `cancel'/`end'/`ready'/`emit'/`waterfall' their own
fields), or nil when JSON is not an object.  Only the shared envelope
keys are read; frame-specific payloads stay on the caller."
  (let ((msg (condition-case nil (json-read-from-string json)
               (error nil))))
    (when (and msg (listp msg))
      (let ((type (dsh-emacs-render--aget "type" msg))
            (stream-id (dsh-emacs-render--aget "streamId" msg)))
        (cond
         ((null type) nil)
         ((equal type "item")
          (list :type type :stream-id stream-id
                :value (dsh-emacs-render--aget "value" msg)))
         ((equal type "error")
          (list :type type :stream-id stream-id
                :error (dsh-emacs-render--aget "error" msg)))
         (t (list :type type :stream-id stream-id)))))))

;; The list view (`*dsh-sessions*') additionally opens a core
;; `/api/remote.mux' connection carrying `$events' + `session/control' +
;; `workspace/follow' logical streams.  Unlike the per-chat follow stream it
;; is scoped to the list buffer's lifecycle: workspace/session/archive
;; changes arrive there and refresh the caches and the list in place, so a
;; dsh web (or second client) editing a workspace shows up without `g'.
(defvar-local dsh-emacs--host-process nil
  "Live core-stream network process, or nil.")
(defvar-local dsh-emacs--host-ready nil
  "Non-nil once the core-stream handshake completed.")
(defvar-local dsh-emacs--host-reconnect-timer nil
  "Timer scheduling a core-stream reconnect after a drop.")

(defvar dsh-emacs-events--client-id nil
  "clientId of the current `$events' generation (from its `ready' frame).
Answers to waterfalls must carry this id; each core reconnect yields a new
generation and a new clientId.")

;; Refresh in-flight protection (mirrors dsh web's `refreshFrames'): a
;; `session/list' response is a snapshot at request time.
;; When the response is in flight, core/mux frames may already have advanced
;; the caches to a newer state (another client reordered/renamed/archived… );
;; blindly replacing the caches with the snapshot would roll them back.  The
;; frames arriving during the refresh are recorded here and replayed over the
;; snapshot when the last in-flight refresh completes.
(defvar dsh-emacs--host-refresh-depth 0
  "Nested refresh span count; frames are only recorded while > 0.")
(defvar dsh-emacs--host-refresh-frames nil
  "Frames (in arrival order) received while a refresh was in flight.")

;; `:nowait' network process filters installed as native-compiled subrs are
;; never invoked (repeatedly) on some Emacs builds: the socket is read once
;; at most, then Emacs stops dispatching to the subr while HTTP/url-retrieve
;; keeps working.  Install BYTECODE delegates instead — the symbolic
;; `defun's stay native-compilable, but the process callbacks assigned below
;; are plain closures, which every build delivers events to reliably.
(defvar dsh-emacs-events--filter-fn
  (lambda (process string)
    (dsh-emacs-events--filter process string))
  "Bytecode alias of `dsh-emacs-events--filter', for `set-process-filter'.")

(defvar dsh-emacs-events--sentinel-fn
  (lambda (process event)
    (dsh-emacs-events--sentinel process event))
  "Bytecode alias of `dsh-emacs-events--sentinel', for `set-process-sentinel'.")

;; Cross-file caches owned by dsh-emacs.el / dsh-emacs-session.el; declared
;; here (not loaded values) so native-comp does not flag free variables while
;; compiling this module ahead of the owner.  The bare `(defvar X)' form
;; asserts existence without binding a default, so the owner's own defvar
;; (e.g. `dsh-emacs--chat-buffers' as a hash table) is not shadowed by nil.
(defvar dsh-emacs--sessions)
(defvar dsh-emacs--chat-buffers)
(defvar dsh-emacs--current-session)
(defvar dsh-emacs-sessions-buffer)
(defvar dsh-emacs--workspaces)
(defvar dsh-emacs--archived-sessions)
;; Owned by dsh-emacs-render.el (`defvar-local', default 0); the dispatch
;; seq gate reads it without loading order guarantees.
(defvar dsh-emacs--anchor-seq)
;; Cross-file free variables read under boundp guards: `dsh-emacs-base-url'
;; is a defcustom in dsh-emacs.el, `dsh-emacs--buffer-session' its
;; buffer-local session state.  Declare-only forms — the real definitions
;; own the values.
(defvar dsh-emacs-base-url)
(defvar dsh-emacs--buffer-session)
(defvar dsh-emacs-history-window)
(declare-function dsh-emacs--chat-session-item "dsh-emacs" (session-id))
(declare-function dsh-emacs--seed-input-history "dsh-emacs" (events session-id))
(declare-function dsh-emacs--chat-buffer-sync "dsh-emacs" (session-id))
(declare-function dsh-emacs--question-requested "dsh-emacs" (chat event-id session-id questions))
(declare-function dsh-emacs--question-cancelled "dsh-emacs" (event-id))
(declare-function dsh-emacs--approval-requested "dsh-emacs" (chat event-id session-id tool-name reason call-id))
(declare-function dsh-emacs--approval-cancelled "dsh-emacs" (event-id))
(declare-function dsh-emacs--events-result-async "dsh-emacs" (client-id event-id outcome callback))
(declare-function dsh-emacs--waterfall-generation-retired "dsh-emacs" ())
(declare-function dsh-emacs-render--aget "dsh-emacs-render" (key alist))
(declare-function dsh-emacs-session--render "dsh-emacs-session" ())
(declare-function dsh-emacs--normalize-archived "dsh-emacs" (archived))
(declare-function dsh-emacs-modeline-set-context-snapshot "dsh-emacs-modeline" (pressure window))
(declare-function dsh-emacs-queue-apply "dsh-emacs-queue" (chat process payload))
(declare-function dsh-emacs-server--basic-auth-header "dsh-emacs-server" ())
(declare-function dsh-emacs--server-auth-cookie-header "dsh-emacs-server" ())

;; Defined in dsh-emacs-modeline.el, which loads after this module.  Referenced
;; at runtime from teardown only.
(declare-function dsh-emacs--ml-busy-clear "dsh-emacs-modeline" ())
(declare-function dsh-emacs--ml-busy-set "dsh-emacs-modeline" (flag))
(declare-function dsh-emacs--command-spinner-clear-all "dsh-emacs-render" ())
(declare-function dsh-emacs--command-spinner-revive "dsh-emacs-render" ())
;; Runtime dependencies defined in dsh-emacs.el / dsh-emacs-render.el.
(declare-function dsh-emacs--sequence-list "dsh-emacs" (value))
(declare-function dsh-emacs-render-history-events "dsh-emacs-render" (events stream))
(declare-function dsh-emacs-render--consume-pending-user-message "dsh-emacs-render" (event))
(declare-function dsh-emacs-render--event-seq "dsh-emacs-render" (event))
(declare-function dsh-emacs-render-event "dsh-emacs-render" (event))
(declare-function dsh-emacs-render--follow-stream "dsh-emacs-render" ())

(defun dsh-emacs-events--chat (process)
  "Return the chat buffer attached to PROCESS."
  (process-get process 'dsh-emacs-chat-buffer))

(defun dsh-emacs-events--send-handshake (process)
  "Send the WebSocket upgrade request for PROCESS.
Every logical Remote stream is multiplexed over one `/api/remote.mux'
socket; the caller opens its specific stream (a chat's
`session/follow', the session list's `session/control' +
`workspace/follow' + `$events') right after the handshake."
  (let* ((url (url-generic-parse-url dsh-emacs-base-url))
         (host (url-host url))
         (port (or (url-port url)
                   (if (equal (url-type url) "https") 443 80)))
         (host-header (if (and port (not (memq port '(80 443))))
                          (format "%s:%s" host port)
                        host))
         (seed (format "%s-%s-%s" (float-time) (random) (emacs-pid)))
         (key (base64-encode-string
               (substring (secure-hash 'sha1 seed nil nil t) 0 16) t))
         (path "/api/remote.mux")
         (origin (format "%s://%s%s"
                         (url-type url) host
                         (if (and port (not (memq port '(80 443))))
                             (format ":%s" port)
                           ""))))
    (let* ((auth (and (fboundp 'dsh-emacs-server--basic-auth-header)
                      (dsh-emacs-server--basic-auth-header)))
           (cookie (and (fboundp 'dsh-emacs--server-auth-cookie-header)
                        (dsh-emacs--server-auth-cookie-header)))
           (request (concat
                     (format "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nOrigin: %s\r\n"
                             path host-header key origin)
                     ;; nginx basic auth 下握手必须带认证头，否则 401 拒绝、
                     ;; 实时事件流（mux/host）全部断连。
                     (if auth (format "%s: %s\r\n" (car auth) (cdr auth)) "")
                     ;; 0.1.2-rc.1+ 的浏览器会话认证：握手必须带 dsh-auth-* cookie。
                     (if cookie (format "Cookie: %s\r\n" cookie) "")
                     "\r\n")))
      (process-send-string process request))))

(defun dsh-emacs-events--random-mask ()
  "Return four random bytes as a unibyte string."
  (apply #'unibyte-string
         (cl-loop repeat 4 collect (random 256))))

(defun dsh-emacs-events--frame (opcode payload)
  "Encode client WebSocket PAYLOAD with OPCODE."
  (let* ((payload (or payload ""))
         (payload (if (multibyte-string-p payload)
                      (string-to-unibyte (encode-coding-string payload 'utf-8))
                    payload))
         (length (length payload))
         (mask (dsh-emacs-events--random-mask))
         (header (cond
                  ((< length 126)
                   (unibyte-string 129 (logior 128 length)))
                  ((< length 65536)
                   (concat (unibyte-string 129 254)
                           (unibyte-string (logand (ash length -8) 255)
                                           (logand length 255))))
                  (t
                   (concat (unibyte-string 129 255)
                           (apply #'unibyte-string
                                  (cl-loop for shift from 56 downto 0 by 8
                                           collect (logand (ash length (- shift))
                                                           255)))))))
         ;; Replace the FIN/opcode byte after building the generic text header.
         (header (concat (unibyte-string (logior 128 opcode))
                         (substring header 1)))
         (masked (copy-sequence payload)))
    (dotimes (i length)
      (aset masked i
            (logxor (aref masked i) (aref mask (mod i 4)))))
    (concat header mask masked)))

(defun dsh-emacs-events--send-pong (process payload)
  "Reply to a WebSocket ping PAYLOAD on PROCESS."
  (when (process-live-p process)
    (process-send-string process
                         (dsh-emacs-events--frame 10 payload))))

(cl-defun dsh-emacs-events--read-frame (input)
  "Return (OPCODE FIN PAYLOAD REST), or nil when INPUT is incomplete."
  (let ((length (length input)))
    (when (>= length 2)
      (let* ((first (aref input 0))
             (second (aref input 1))
             (fin (/= 0 (logand first 128)))
             (opcode (logand first 15))
             (masked (/= 0 (logand second 128)))
             (size (logand second 127))
             (offset 2))
        (cond
         ((= size 126)
          (when (< length (+ offset 2)) (cl-return-from dsh-emacs-events--read-frame nil))
          (setq size (+ (ash (aref input offset) 8)
                        (aref input (1+ offset)))
                offset (+ offset 2)))
         ((= size 127)
          (when (< length (+ offset 8)) (cl-return-from dsh-emacs-events--read-frame nil))
          (setq size 0)
          (dotimes (i 8)
            (setq size (+ (ash size 8) (aref input (+ offset i)))))
          (setq offset (+ offset 8))))
        (let ((mask (when masked
                      (when (< length (+ offset 4))
                        (cl-return-from dsh-emacs-events--read-frame nil))
                      (prog1 (substring input offset (+ offset 4))
                        (setq offset (+ offset 4))))))
          (when (< length (+ offset size))
            (cl-return-from dsh-emacs-events--read-frame nil))
          (let ((payload (copy-sequence (substring input offset (+ offset size))))
                (rest (substring input (+ offset size))))
            (when mask
              (dotimes (i size)
                (aset payload i
                      (logxor (aref payload i) (aref mask (mod i 4))))))
            (list opcode fin payload rest)))))))

(defun dsh-emacs-events--apply-title (_chat session-id title)
  "Apply a live `session/title' event: update the session cache, the chat\n buffer name (when SESSION-ID is the buffer's session) and the session list\n row, without touching the transcript."
  (when (and session-id title (not (string-empty-p title))
             (listp dsh-emacs--sessions))
    ;; Refresh the cached session row so the session list and any future
    ;; buffer-name computation see the new title.  The summary title lives in
    ;; `projections.values.title' (dsh web convention); a real title also
    ;; clears the placeholder `blank' flag, or `display-title' would keep
    ;; showing "New Session" on top of it.
    (let ((item (cl-find-if (lambda (s)
                              (equal session-id
                                     (and s (dsh-protocol-session-session-id s))))
                            dsh-emacs--sessions)))
      (when item
        (setf (dsh-protocol-session-title-value item) title)
        (setf (dsh-protocol-session-blank item) nil)))
    ;; Repaint the session list if it is currently displayed.
    (when (and (listp dsh-emacs--sessions)
               dsh-emacs-sessions-buffer
               (get-buffer dsh-emacs-sessions-buffer))
      (with-current-buffer (get-buffer dsh-emacs-sessions-buffer)
        (dsh-emacs-session--render)))
    ;; The live chat buffer of that session (if any) renames immediately;
    ;; `dsh-emacs--chat-buffer-sync' also refreshes default-directory.
    (when (and (fboundp 'dsh-emacs--chat-buffer-sync)
               (hash-table-p dsh-emacs--chat-buffers)
               (gethash session-id dsh-emacs--chat-buffers))
      (dsh-emacs--chat-buffer-sync session-id))))

(defun dsh-emacs--events-apply-context-projection (session-id value)
  "Update the mode-line ctx% for SESSION-ID from a `contextPressure' projection VALUE.
VALUE is the projection's wire view: an alist with symbol/string keys for
`projectedTokens', `pressureTokens' and `contextWindow' (the same shape
`session/list' projections carry, aligned with dsh web's ctx meter which
reads projectedTokens ?? pressureTokens).  Only the session's live chat
buffer is touched; the mode-line snapshot setter lands the pair in one go.

The whole pair is trusted only while the RAW usage sample is positive: a
provider-rejected run (quota/rate) reports usage 0/0 and the last-wins
sample collapses to 0; `projectedTokens' — derived as
pressureTokens + surface movement — then just tracks the surface's later
growth (a small lying value after the user submits again).  While the
sample stays 0 the previous snapshot is kept; the next real usage sample
lands the genuine pair."
  (when (and (listp value)
             (hash-table-p dsh-emacs--chat-buffers))
    (let* ((projected (dsh-emacs-render--aget "projectedTokens" value))
           (pressure (dsh-emacs-render--aget "pressureTokens" value))
           (window (dsh-emacs-render--aget "contextWindow" value))
           (used (and (numberp pressure) (> pressure 0)
                      (or (and (numberp projected) (> projected 0)
                               projected)
                          pressure)))
           (buf (gethash session-id dsh-emacs--chat-buffers)))
      (when (and used window (> window 0)
                 (buffer-live-p buf)
                 (fboundp 'dsh-emacs-modeline-set-context-snapshot))
        (with-current-buffer buf
          (dsh-emacs-modeline-set-context-snapshot used window))))))

(defun dsh-emacs-events--dispatch-event (chat event)
  "Dispatch EVENT received for CHAT, respecting seq and optimistic input.
The seq gate is the dedup line: a `session/follow' reconnect re-seeds the
transcript with a fresh snapshot (see `dsh-emacs-events--dispatch-json'),
whose records carry their ORIGINAL seq — and that includes MID-SESSION
reconnects, not just the initial open.  `dsh-emacs--anchor-seq' tracks the
newest event this buffer has rendered or consumed, so a replayed record —
already on screen — must be dropped: without the gate a reconnect painted
the whole transcript a second time (doubled user messages and assistant
replies, interleaved by the second pass).  Events that arrived while the
socket was down carry seq > anchor and render here as the catch-up, exactly
like the follow snapshot's reseed is anchor-gated."
  (when (and (buffer-live-p chat) (listp event))
    (with-current-buffer chat
      (let ((seq (dsh-emacs-render--event-seq event)))
        (when (or (not (integerp seq))
                  (> seq (or dsh-emacs--anchor-seq 0)))
          (if (dsh-emacs-render--consume-pending-user-message event)
              (when (integerp seq)
                (setq dsh-emacs--anchor-seq
                      (max dsh-emacs--anchor-seq seq)))
            (dsh-emacs-render-event event))
          ;; Keep windows that already show the bottom pinned to the newest
          ;; content; never touch windows the user scrolled away.
          (dsh-emacs-render--follow-stream))))
      ;; The stream just delivered (even a replayed frame): note it for
      ;; the stall watchdog.
      (setq dsh-emacs--ws-last-event-time (float-time))))

(defun dsh-emacs-events--dispatch-json (process json)
  "Route one decoded WebSocket text message from PROCESS.
A process flagged `dsh-emacs-host-stream' (the core connection) routes to
`dsh-emacs-events--host-dispatch'.  A chat process's `/api/remote.mux'
messages all carry a top-level `streamId' — its `session/follow' frames
go to `dsh-emacs-events--dispatch-follow'.  Anything else (a chat socket
message without a streamId) is not a frame the migrated protocol sends
and is dropped."
  (condition-case err
      (if (and (processp process)
               (process-get process 'dsh-emacs-host-stream))
          (dsh-emacs-events--host-dispatch process json)
        (let* ((message (condition-case nil (json-read-from-string json)
                          (error nil)))
               (stream-id (and (listp message)
                               (dsh-emacs-render--aget "streamId" message))))
          (when stream-id
            (dsh-emacs-events--dispatch-follow process message))))
    (error (message "dsh event decode error: %S" err))))

(defun dsh-emacs-events--follow-open (process)
  "Send the `session/follow' open frame for PROCESS's chat stream.
The follow endpoint needs the session the chat buffer is attached to
(process property `dsh-emacs-follow-session', set at connect).  No-op for
connections without a session (the core list connection opens
`session/control' + `workspace/follow' + `$events' instead)."
  (let ((session-id (process-get process 'dsh-emacs-follow-session)))
    (when (and session-id (process-live-p process))
      (let* ((stream-id (or (process-get process 'dsh-emacs-follow-stream-id)
                            (let ((id (dsh-emacs-events--stream-id)))
                              (process-put process 'dsh-emacs-follow-stream-id id)
                              id)))
             (request `((address . ((kind . "session")
                                    (sessionId . ,session-id)))))
             (request (if (bound-and-true-p dsh-emacs-history-window)
                          (append request
                                  `((maxMessages . ,dsh-emacs-history-window)))
                        request))
             (json (dsh-emacs-events--open-message
                    stream-id "session/follow"
                    `((request . ,request)))))
        (process-send-string process (dsh-emacs-events--frame 1 json))))))

(defun dsh-emacs-events--dispatch-follow (process message)
  "Dispatch one `session/follow' stream message on PROCESS.
Only messages for the stream this connection opened (process property
`dsh-emacs-follow-stream-id') are consumed: `item' frames carry the
snapshot/event values, `error' and `end' close the stream and reconnect."
  (when (equal (dsh-emacs-render--aget "streamId" message)
               (process-get process 'dsh-emacs-follow-stream-id))
    (pcase (dsh-emacs-render--aget "type" message)
      ("item"
       (let ((chat (dsh-emacs-events--chat process)))
         (when (buffer-live-p chat)
           (dsh-emacs-events--follow-item
            chat (dsh-emacs-render--aget "value" message)))))
      ("error"
       (message "dsh follow stream error: %S"
                (dsh-emacs-render--aget "error" message))
       (dsh-emacs-events--lost process))
      ("end"
       ;; The server closed the stream: reconnect so a fresh follow
       ;; snapshot reseeds the transcript (the seq anchor dedups).
       (dsh-emacs-events--lost process)))))

(defun dsh-emacs-events--follow-item (chat value)
  "Consume one `session/follow' item VALUE on the stream of CHAT.
`snapshot' frames seed the transcript; `event' frames feed the live
event path."
  (pcase (dsh-emacs-render--aget "type" value)
    ("snapshot" (dsh-emacs-events--follow-snapshot chat value))
    ("event" (dsh-emacs-events--follow-event
              chat (dsh-emacs-render--aget "event" value)))
    (_ nil)))

(defun dsh-emacs-events--follow-event (chat event)
  "Handle one live follow EVENT for CHAT.
`session/title' events update the session cache and buffer name for any
session; transcript events render into CHAT's own buffer."
  (when (and (buffer-live-p chat) (listp event))
    (let ((session-id (with-current-buffer chat
                        dsh-emacs--buffer-session)))
      (when (equal (dsh-emacs-render--aget "type" event) "session/title")
        (let ((title (dsh-emacs-render--aget "title"
                                             (dsh-emacs-render--aget "data" event))))
          (dsh-emacs-events--apply-title chat session-id title)
          (dsh-emacs-events--host-frame-record
           (list :apply-title session-id title))))
      (dsh-emacs-events--dispatch-event chat event))))

(defun dsh-emacs-events--follow-snapshot (chat value)
  "Seed CHAT's transcript from a `session/follow' snapshot VALUE.
Renders the message-aligned `records' tail — `chunks' packed rows are
skipped, raw `assistant/chunk' deltas too (the completed
`assistant/message' events render the content) — then advances
`dsh-emacs--anchor-seq' to the snapshot CURSOR and applies snapshot
projections (title/contextPressure).  The snapshot is the opening history
tail; no separate history fetch precedes the connect."
  (when (buffer-live-p chat)
    (with-current-buffer chat
      (let* ((session-id dsh-emacs--buffer-session)
             (cursor (dsh-emacs-render--aget "cursor" value))
             (records (let ((r (dsh-emacs-render--aget "records" value)))
                        (cond ((vectorp r) (append r nil))
                              ((listp r) r)
                              (t nil))))
             (entries (delq nil
                            (mapcar (lambda (rec)
                                      (and (equal (dsh-emacs-render--aget
                                                   "type" rec)
                                                  "event")
                                           rec))
                                    records))))
        (when entries
          (dsh-emacs-render-history-events entries nil)
          (when (fboundp 'dsh-emacs--seed-input-history)
            (dsh-emacs--seed-input-history entries session-id)))
        (when (integerp cursor)
          (setq dsh-emacs--anchor-seq
                (max (or dsh-emacs--anchor-seq 0) cursor)))
        (dsh-emacs-events--apply-snapshot-projections
         session-id (dsh-emacs-render--aget "projections" value))
        (setq dsh-emacs--ws-last-event-time (float-time))))))

(defun dsh-emacs-events--apply-snapshot-projections (session-id projections)
  "Apply a follow snapshot's PROJECTIONS block (`{asOfSeq, values}').
`title' feeds the session cache/buffer name, `contextPressure' the
mode-line ctx% — the same consumers as the `session/control' projection
increment frames use."
  (let ((values (and (listp projections)
                     (dsh-emacs-render--aget "values" projections))))
    (when (listp values)
      (let ((title (dsh-emacs-render--aget "title" values)))
        (when (and title (not (string-empty-p title)))
          (dsh-emacs-events--apply-title nil session-id title)
          (dsh-emacs-events--host-frame-record
           (list :apply-title session-id title))))
      (let ((pressure (dsh-emacs-render--aget "contextPressure" values)))
        (when (listp pressure)
          (dsh-emacs--events-apply-context-projection session-id pressure))))))


(defun dsh-emacs-events--consume-frames (process)
  "Consume complete WebSocket frames buffered for PROCESS."
  (condition-case err
      (let ((input (process-get process 'dsh-emacs-event-input))
            frame)
        (while (and input (setq frame (dsh-emacs-events--read-frame input)))
      (setq input (nth 3 frame))
      (let ((opcode (nth 0 frame))
            (fin (nth 1 frame))
            (payload (nth 2 frame)))
        (cond
         ((= opcode 9) (dsh-emacs-events--send-pong process payload))
         ((= opcode 8) (delete-process process))
         ((or (= opcode 1) (= opcode 0))
          (let ((fragment (if (= opcode 1) ""
                            (or (process-get process 'dsh-emacs-event-fragment) ""))))
            (setq fragment (concat fragment payload))
            (if fin
                (progn
                  (process-put process 'dsh-emacs-event-fragment nil)
                  (dsh-emacs-events--dispatch-json
                   process (decode-coding-string fragment 'utf-8)))
              (process-put process 'dsh-emacs-event-fragment fragment)))))))
        (process-put process 'dsh-emacs-event-input input))
    (error (message "dsh WebSocket frame error: %S" err))))

(defun dsh-emacs-events--filter (process string)
  "Process raw HTTP/WebSocket STRING received by PROCESS."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (let ((input (concat (or (process-get process 'dsh-emacs-event-input) "")
                           (string-to-unibyte string))))
        (if (process-get process 'dsh-emacs-event-ready)
            ;; Data is already past the handshake: buffer the raw bytes and
            ;; parse complete frames immediately so the live stream is
            ;; actually consumed.  (Frames must be parsed on EVERY chunk,
            ;; not just the one that happened to carry the handshake.)
            (progn
              (process-put process 'dsh-emacs-event-input input)
              (dsh-emacs-events--consume-frames process))
          (let ((header-end (string-match "\r\n\r\n" input)))
            (when header-end
              (if (string-match-p "\\`HTTP/[0-9.]+ 101" input)
                  (progn
                    (process-put process 'dsh-emacs-event-ready t)
                    (process-put process 'dsh-emacs-event-input
                                 (substring input (+ header-end 4)))
                    (if (process-get process 'dsh-emacs-host-stream)
                        ;; Core stream has no chat buffer to mark ready; the
                        ;; flag lives on the owning list buffer, then the
                        ;; `session/control' + `workspace/follow' + `$events'
                        ;; logical streams are opened on the socket.
                        (let ((buffer (process-get process
                                                   'dsh-emacs-host-buffer)))
                          (when (buffer-live-p buffer)
                            (with-current-buffer buffer
                              (setq dsh-emacs--host-ready t)))
                          (dsh-emacs-events--host-open process))
                      (let ((chat (dsh-emacs-events--chat process)))
                        (when (buffer-live-p chat)
                          (with-current-buffer chat
                            (setq dsh-emacs--event-ready t)
                            (setq dsh-emacs--ws-last-event-time (float-time))
                            (dsh-emacs-events--health-stop)))
                        ;; 0.1.2: open the chat's `session/follow' logical
                        ;; stream once the socket upgrade completed.
                        (dsh-emacs-events--follow-open process)))
                    (dsh-emacs-events--consume-frames process))
                (delete-process process)))))))))

(defun dsh-emacs-events--schedule-reconnect ()
  "Arm a one-shot reconnect for the current chat buffer, unless one is pending.
Reconnects after 1s via `dsh-emacs-events-connect', which runs the full
teardown + rebuild cycle.  Guarded so concurrent loss/connect-error paths
never stack parallel reconnect timers."
  (unless (timerp dsh-emacs--event-reconnect-timer)
    (setq dsh-emacs--event-reconnect-timer
          (run-at-time 1 nil
                       (lambda (buffer)
                         (when (buffer-live-p buffer)
                           (with-current-buffer buffer
                             (setq dsh-emacs--event-reconnect-timer nil)
                             (dsh-emacs-events-connect buffer))))
                       (current-buffer)))))

(defun dsh-emacs-events--lost (process)
  "Handle a closed event stream PROCESS and arrange a reconnect."
  (if (process-get process 'dsh-emacs-host-stream)
      (dsh-emacs-events--host-lost process)
    (let ((chat (dsh-emacs-events--chat process)))
      (when (and (buffer-live-p chat)
                 (eq process (with-current-buffer chat dsh-emacs--event-process)))
        (with-current-buffer chat
          (setq dsh-emacs--event-process nil
                dsh-emacs--event-ready nil)
          (dsh-emacs-events--health-stop)
          (dsh-emacs-events--watchdog-stop)
          (dsh-emacs-events--schedule-reconnect))))))

(defun dsh-emacs-events--sentinel (process _event)
  "Handle PROCESS lifecycle changes."
  (when (and (process-live-p process)
             (eq (process-status process) 'open)
             (not (process-get process 'dsh-emacs-event-handshake-sent)))
    (process-put process 'dsh-emacs-event-handshake-sent t)
    (dsh-emacs-events--send-handshake process))
  (when (memq (process-status process) '(closed failed exit signal))
    (dsh-emacs-events--lost process)))

(defun dsh-emacs-events--watchdog-tick (buffer)
  "Confirm the event stream is actually delivering while a turn runs.
The dsh mux can leave a socket open-but-unread (bytes pile up in the kernel
queue while Emacs never invokes the process filter), making the stream look
alive although nothing renders.  When the stream stays silent for > 3s
mid-turn the socket is killed so the sentinel reconnects; the fresh
`session/follow' snapshot then reseeds whatever was missed (records carry
original seqs, the anchor gate renders only the new tail) — no history
probe RPC is needed anymore.  Self-stops outside an active turn.  BUFFER is
the chat buffer this watchdog was armed for: the timer is buffer-local but
timers fire with no buffer context, so the owning buffer is passed
explicitly (with several session buffers open, the global
`dsh-emacs--current-buffer' would point at the last-opened one and the
watchdog would check the wrong stream)."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (and (bound-and-true-p dsh-emacs--ml-busy)
               dsh-emacs--event-ready
               (process-live-p dsh-emacs--event-process))
          (let ((now (float-time)))
            (when (and (not dsh-emacs--ws-probe-inflight)
                       (or (null dsh-emacs--ws-last-event-time)
                           (> (- now dsh-emacs--ws-last-event-time) 3.0))
                       (> (- now (or dsh-emacs--ws-last-probe-time 0)) 3.0))
              ;; The stream is stalled mid-turn: reconnect; the fresh follow
              ;; snapshot catches the stream up (anchor-diffed rendering).
              (when (process-live-p dsh-emacs--event-process)
                (setq dsh-emacs--ws-probe-inflight t)
                (setq dsh-emacs--ws-last-probe-time now)
                (delete-process dsh-emacs--event-process))))
        ;; No turn in progress: stop.
        (dsh-emacs-events--watchdog-stop)))))

(defun dsh-emacs-events--watchdog-start ()
  "Start the mid-turn stream-health watchdog for the current buffer."
  (setq dsh-emacs--ws-last-event-time (float-time))
  (unless (timerp dsh-emacs--ws-watchdog-timer)
    (setq-local dsh-emacs--ws-watchdog-timer
                (let ((buffer (current-buffer)))
                  ;; 1s probe cadence: probes are anchor-diffed and cheap.
                  (run-with-timer 2 1.0
                                  (lambda ()
                                    (when (buffer-live-p buffer)
                                      (dsh-emacs-events--watchdog-tick
                                       buffer))))))))

(defun dsh-emacs-events--watchdog-stop ()
  "Cancel the stream-health watchdog timer."
  (when (timerp dsh-emacs--ws-watchdog-timer)
    (cancel-timer dsh-emacs--ws-watchdog-timer))
  (setq-local dsh-emacs--ws-watchdog-timer nil))

(defun dsh-emacs-events--health-tick (buffer)
  "Health-check the stream socket of BUFFER every repeat.
A `:nowait' socket on affected builds can stay `open' while the kernel queue
fills and the filter never runs (handshake never processed).  If BUFFER's
handshake has not completed, delete the socket so the sentinel schedules a
fresh connect; stop once ready or the socket is gone.
Errors are CONTAINED here on purpose: a repeating timer whose function
signals is silently dropped from `timer-list' by Emacs (Lisp errors only
message when the timer code path reports them), which would leave the socket
wedged with no recovery scheduled — the exact limbo observed on this build."
  (when (buffer-live-p buffer)
    (condition-case err
        (with-current-buffer buffer
          (if (or dsh-emacs--event-ready
                  (not (process-live-p dsh-emacs--event-process)))
              (dsh-emacs-events--health-stop)
            (delete-process dsh-emacs--event-process)))
      (error
       (message "dsh: connection health check error (loop continues): %S" err)))))

(defun dsh-emacs-events--health-start ()
  "Start the connect-handshake health check for the current buffer."
  (dsh-emacs-events--health-stop)
  (setq-local dsh-emacs--event-connect-timer
              (run-with-timer 2 2 #'dsh-emacs-events--health-tick
                              (current-buffer))))

(defun dsh-emacs-events--health-stop ()
  "Cancel the connect-handshake health check."
  (when (timerp dsh-emacs--event-connect-timer)
    (cancel-timer dsh-emacs--event-connect-timer))
  (setq-local dsh-emacs--event-connect-timer nil))

(defun dsh-emacs-events-connect (chat)
  "Connect CHAT to dsh's `/api/remote.mux' WebSocket stream.

Socket creation is failure-contained: `open-network-stream' can signal
synchronously (unresolvable host, malformed `dsh-emacs-base-url'); the
disconnect below has already torn down the reconnect timer, so a throw
from here used to leave the chat permanently deaf — no socket, no
reconnect — while other sessions' sockets kept rendering.  On error the
reconnect is re-armed and another connect scheduled."
  (when (buffer-live-p chat)
    (with-current-buffer chat
      (let ((was-busy (bound-and-true-p dsh-emacs--ml-busy))
            (process nil))
        (dsh-emacs-events-disconnect chat)
        (condition-case err
            (let* ((url (url-generic-parse-url dsh-emacs-base-url))
                   (host (url-host url))
                   (port (or (url-port url)
                             (if (equal (url-type url) "https") 443 80)))
                   (buffer (get-buffer-create
                            (format " *dsh-events:%s*"
                                    (or dsh-emacs--buffer-session
                                        dsh-emacs--current-session)))))
              (setq process (let ((url-proxy-services nil))
                              (open-network-stream
                               (buffer-name buffer) buffer host port
                               :type (if (equal (url-type url) "https")
                                         'tls 'plain)
                               :nowait t)))
              (with-current-buffer buffer
                (set-buffer-multibyte nil))
              (set-process-query-on-exit-flag process nil)
              ;; Keep CRLF handshake bytes untouched.  On a REUSED events
              ;; buffer (the reconnect case: this buffer already served a
              ;; mux process), the process coding system is re-inferred with
              ;; a decoder that folds the 101 response's `\r\n\r\n' to
              ;; `\n\n', so the handshake never matches, the health check
              ;; keeps killing the socket in a reconnect loop, and the
              ;; session silently stops rendering replies while other
              ;; sessions' sockets keep working.  `no-conversion' preserves
              ;; the exact bytes (frames are decoded to UTF-8 explicitly in
              ;; `dsh-emacs-events--consume-frames'); same fix and rationale
              ;; as the host stream.
              (set-process-coding-system process 'no-conversion
                                         'no-conversion)
              (process-put process 'dsh-emacs-chat-buffer chat)
               ;; The chat's `session/follow' stream needs the session id at
               ;; handshake completion (see `dsh-emacs-events--follow-open').
               (process-put process 'dsh-emacs-follow-session
                            (buffer-local-value 'dsh-emacs--buffer-session chat))
              (process-put process 'dsh-emacs-event-input "")
              (process-put process 'dsh-emacs-event-ready nil)
              ;; Install the bytecode delegates, not the native subrs directly:
              ;; `:nowait' sockets whose filter is a native-compiled subr stop
              ;; being read on affected Emacs builds (see
              ;; `dsh-emacs-events--filter-fn').
              (set-process-filter process dsh-emacs-events--filter-fn)
              (set-process-sentinel process dsh-emacs-events--sentinel-fn)
              (setq dsh-emacs--event-process process
                    dsh-emacs--event-ready nil
                    dsh-emacs--ws-last-event-time (float-time)
                    dsh-emacs--ws-last-probe-time nil
                    dsh-emacs--ws-probe-inflight nil)
              ;; Connect health (repeating): while the handshake is pending,
              ;; every 2s check that the socket is really being read; a wedged
              ;; socket is killed so `dsh-emacs-events--lost' schedules a
              ;; fresh connect and retries.
              (dsh-emacs-events--health-start)
              ;; A mid-command stream drop just ran
              ;; `dsh-emacs-events-disconnect' (above), which cancels every row
              ;; spinner so a detached conversation never keeps animating.  If
              ;; this connect is a reconnect for the same chat buffer while a
              ;; slash command is still running, re-arm its spinner (a no-op
              ;; for fresh buffers and already-settled rows).
              (when (fboundp 'dsh-emacs--command-spinner-revive)
                (dsh-emacs--command-spinner-revive))
              ;; The disconnect above also cleared the mode-line busy flag —
              ;; and with it the C-c C-c interrupt gate, which keys on the
              ;; same flag.  The send path is the only other place that sets
              ;; it, so a mid-turn reconnect would leave the turn
              ;; uninterruptible until the next send.  If a turn was in flight
              ;; when this connect ran, re-light the spinner; the real
              ;; `turn/end' render still clears it when the turn ends (no-op
              ;; for fresh buffers and settled turns).
              (when (and was-busy (fboundp 'dsh-emacs--ml-busy-set))
                (dsh-emacs--ml-busy-set t)))
          (error
           (when (and (processp process) (process-live-p process))
             (delete-process process))
           (message "dsh: event stream connect failed for %s: %S"
                    (buffer-name chat) err)
           ;; A synchronous connect failure ran inside this timer (or inside
           ;; `dsh-emacs-open-session'): the disconnect above already canceled
           ;; every recovery timer, so without this the chat would sit deaf —
           ;; no socket, no reconnect — while other sessions' sockets keep
           ;; rendering.  Re-arm the reconnect so the stream recovers.
           (dsh-emacs-events--schedule-reconnect)))))))

(defun dsh-emacs-events-disconnect (&optional chat)
  "Disconnect CHAT's dsh event stream."
  (let ((chat (or chat (current-buffer))))
    (when (buffer-live-p chat)
      (with-current-buffer chat
        (when (timerp dsh-emacs--event-reconnect-timer)
          (cancel-timer dsh-emacs--event-reconnect-timer))
        (dsh-emacs-events--health-stop)
        (setq dsh-emacs--event-reconnect-timer nil)
        (dsh-emacs-events--watchdog-stop)
        (let ((process dsh-emacs--event-process))
          ;; Clear ownership before deleting: the sentinel must not schedule a
          ;; reconnect for an intentional session switch or buffer teardown.
          (setq dsh-emacs--event-process nil
                dsh-emacs--event-ready nil)
          (when (process-live-p process)
            (delete-process process)))
        ;; Tearing down the stream: stop the mode-line running spinner so it
        ;; never keeps ticking in a detached conversation, and cancel any
        ;; running slash-command row animations.
        (when (fboundp 'dsh-emacs--ml-busy-clear)
          (dsh-emacs--ml-busy-clear))
        (when (fboundp 'dsh-emacs--command-spinner-clear-all)
          (dsh-emacs--command-spinner-clear-all))))))

;;; ---------------------------------------------------------------------------
;;; Core connection (`session/control' + `workspace/follow' + `$events')
;;; --- workspace/session/archive changes
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-events--host-repaint ()
  "Repaint the session list buffer, if it is live."
  (when (and (listp dsh-emacs--sessions)
             dsh-emacs-sessions-buffer
             (get-buffer dsh-emacs-sessions-buffer))
    (with-current-buffer (get-buffer dsh-emacs-sessions-buffer)
      (dsh-emacs-session--render))))

(defun dsh-emacs-events--host-frame-record (frame)
  "Record FRAME while a list refresh is in flight (best-effort).
FRAME is a handler-description list, e.g. (:upsert-workspace WS) or
(:session-status ID RUNNING).  Replayed by
`dsh-emacs-events--host-refresh-drain' once the refresh completes, so a
late-arriving snapshot response never rolls the caches back below the
state the stream already delivered."
  (when (> dsh-emacs--host-refresh-depth 0)
    (push frame dsh-emacs--host-refresh-frames)))

(defun dsh-emacs-events--host-refresh-begin ()
  "Mark a list-refresh span: snapshot responses arriving inside it are
drained through recorded frames before being installed."
  (setq dsh-emacs--host-refresh-depth (1+ dsh-emacs--host-refresh-depth))
  (when (= dsh-emacs--host-refresh-depth 1)
    (setq dsh-emacs--host-refresh-frames nil)))

(defun dsh-emacs-events--host-refresh-drain ()
  "End a refresh span; when the last one ends, replay recorded frames."
  (when (> dsh-emacs--host-refresh-depth 0)
    (setq dsh-emacs--host-refresh-depth
          (1- dsh-emacs--host-refresh-depth)))
  (when (= dsh-emacs--host-refresh-depth 0)
    (let ((frames (nreverse dsh-emacs--host-refresh-frames)))
      (setq dsh-emacs--host-refresh-frames nil)
      (dolist (frame frames)
        (pcase (car frame)
          (:upsert-workspace
           (dsh-emacs-events--host-upsert-workspace (cadr frame)))
          (:remove-workspace
           (dsh-emacs-events--host-remove-workspace (cadr frame)))
          (:reorder-workspaces
           (dsh-emacs-events--host-reorder-workspaces (cadr frame)))
          (:set-archived
           (dsh-emacs-events--host-set-archived (cadr frame)))
          (:session-added
           (dsh-emacs-events--host-session-added (cadr frame)))
          (:session-removed
           (dsh-emacs-events--host-session-removed (cadr frame)))
          (:session-status
           (dsh-emacs-events--host-session-status
            (cadr frame) (car (cddr frame))))
          (:apply-title
           (dsh-emacs-events--apply-title
            nil (cadr frame) (car (cddr frame)))))))))

(defun dsh-emacs-events--host-upsert-workspace (workspace)
  "Insert or replace WORKSPACE (a protocol struct) in the cache.
The `workspace/follow' stream is authoritative for workspace membership, so
the cached workspace (including its `session-ids') is replaced wholesale."
  (let* ((id (dsh-protocol-workspace-workspace-id workspace))
         (found nil)
         (result nil))
    (dolist (ws dsh-emacs--workspaces)
      (if (equal id (dsh-protocol-workspace-workspace-id ws))
          (progn (push workspace result) (setq found t))
        (push ws result)))
    (unless found
      (push workspace result))
    (setq dsh-emacs--workspaces (nreverse result)))
  (dsh-emacs-events--host-repaint))

(defun dsh-emacs-events--host-remove-workspace (workspace-id)
  "Remove WORKSPACE-ID from the cache."
  (setq dsh-emacs--workspaces
        (cl-remove-if-not
         (lambda (ws)
           (not (equal workspace-id
                       (dsh-protocol-workspace-workspace-id ws))))
         dsh-emacs--workspaces))
  (dsh-emacs-events--host-repaint))

(defun dsh-emacs-events--host-reorder-workspaces (workspace-ids)
  "Reorder the cached workspaces to match the server order WORKSPACE-IDS.
Unknown trailing ids (a workspace appearing in the payload before its
`workspace/follow' `order' frame settles) are appended in cache order."
  (let ((rest nil))
    (dolist (ws dsh-emacs--workspaces)
      (unless (member (dsh-protocol-workspace-workspace-id ws)
                      workspace-ids)
        (push ws rest)))
    (setq dsh-emacs--workspaces
          (append (mapcar
                   (lambda (id)
                     (cl-find-if
                      (lambda (ws)
                        (equal id (dsh-protocol-workspace-workspace-id ws)))
                      dsh-emacs--workspaces))
                   workspace-ids)
                  (nreverse rest)))
    (dsh-emacs-events--host-repaint)))

(defun dsh-emacs-events--host-set-archived (archived-ids)
  "Replace the archived-session set with ARCHIVED-IDS."
  (setq dsh-emacs--archived-sessions
        (dsh-emacs--normalize-archived archived-ids))
  (dsh-emacs-events--host-repaint))

(defun dsh-emacs-events--host-session-added (summary)
  "Cache a freshly visible session from an `api-session/added' SUMMARY.
The summary is the `SessionSummary' wire alist (sessionId, running,
blank, cwd, projections...); the row is only inserted when not already
cached (a `session/create' callback may have raced ahead).  Workspace
membership is reported separately by `workspace/follow' frames."
  (let ((session-id (and (listp summary)
                         (dsh-emacs-render--aget "sessionId" summary))))
    (when (and session-id
               (not (dsh-emacs--chat-session-item session-id)))
      (push (dsh-protocol-session--from-alist summary)
            dsh-emacs--sessions)
      (dsh-emacs-events--host-repaint))))

(defun dsh-emacs-events--host-session-removed (session-id)
  "Drop SESSION-ID from the cached session list."
  (setq dsh-emacs--sessions
        (cl-remove-if-not
         (lambda (s)
           (not (equal session-id
                       (dsh-protocol-session-session-id s))))
         dsh-emacs--sessions))
  (dsh-emacs-events--host-repaint))

(defun dsh-emacs-events--host-session-status (session-id running)
  "Update the running flag of cached SESSION-ID; repaint the list."
  (let ((item (dsh-emacs--chat-session-item session-id)))
    (when item
      (setf (dsh-protocol-session-running item)
            (and running (not (eq running :json-false))))))
  (dsh-emacs-events--host-repaint))

(defun dsh-emacs-events--host-dispatch (process json)
  "Route one decoded `/api/remote.mux' message from PROCESS.
The list-scoped core connection multiplexes the `session/control',
`workspace/follow' and `$events' logical streams.  Server frames arrive as
`item' (value = a control/workspace/$events logical frame), `error' or
`end'; the logical frame `type' routes to the shared caches and chat
buffers (see `dsh-emacs-events--host-item')."
  (condition-case err
      (let* ((frame (dsh-emacs-events--message-frame json))
             (type (plist-get frame :type)))
        (pcase type
          ("item" (dsh-emacs-events--host-item
                   process (plist-get frame :value)))
          ("error"
           (message "dsh core stream error: %S" (plist-get frame :error)))
          ("end" (dsh-emacs-events--host-lost process))
          (_ nil)))
    (error (message "dsh core event decode error: %S" err))))

(defun dsh-emacs-events--host-item (process value)
  "Consume one logical core frame VALUE arriving on PROCESS.
`session/control' frames feed queue mirrors and projections,
`workspace/follow' frames mutate the workspace caches, `$events' frames
carry the session list's live changes and the question/approval
waterfalls: `ready' captures the generation `clientId', `emit' delivers
`api-session/*' events, `waterfall' routes an approval/question request
to its chat buffer (auto-answering `next' when no live chat), and `cancel'
retires a pending waterfall by `eventId'."
  (pcase (dsh-emacs-render--aget "type" value)
    ("baseline"
     ;; Baseline frames differ from the incremental ones (`upsert'/`order'/
     ;; `queue'/`projection' put their fields directly on the frame), the
     ;; payload is nested one level deeper: the logical baseline frame is
     ;; `{type:'baseline', value:{...}}' (workspace/follow: `items' +
     ;; `archivedSessionIds'; session/control: `queues'/`jobs'/`projections').
     ;; Unwrap that inner `value' before routing and hand each handler its
     ;; own payload shape — otherwise the check below sees no `items' at the
     ;; frame level and every baseline is misrouted to session/control,
     ;; leaving `dsh-emacs--workspaces' never seeded (session list ungrouped).
     (let ((payload (dsh-emacs-render--aget "value" value)))
       (if (dsh-emacs-render--aget "items" payload)
           ;; workspace/follow baseline: authoritative workspace + archive set.
           (dsh-emacs-events--host-workspace-baseline payload)
         ;; session/control baseline: seed queue mirrors + projections.
         (dsh-emacs-events--host-control-baseline process payload))))
    ("queue"
     (let ((sid (dsh-emacs-render--aget "sessionId" value)))
       (when sid
         (dsh-emacs-queue-apply
          (or (dsh-emacs-events--chat-buffer sid) (current-buffer))
          process value))))
    ("projection"
     (dsh-emacs-events--host-apply-projection
      (dsh-emacs-render--aget "sessionId" value)
      (dsh-emacs-render--aget "key" value)
      (dsh-emacs-render--aget "value" value)))
    ("upsert"
     (let ((ws (dsh-emacs-render--aget "workspace" value)))
       (when ws
         (let ((struct (dsh-protocol-workspace--from-alist ws)))
           (dsh-emacs-events--host-upsert-workspace struct)
           (dsh-emacs-events--host-frame-record
            (list :upsert-workspace struct))))))
    ("remove"
     (let ((id (dsh-emacs-render--aget "workspaceId" value)))
       (dsh-emacs-events--host-remove-workspace id)
       (dsh-emacs-events--host-frame-record (list :remove-workspace id))))
    ("order"
     (let ((ids (dsh-emacs--sequence-list
                 (dsh-emacs-render--aget "workspaceIds" value))))
       (dsh-emacs-events--host-reorder-workspaces ids)
       (dsh-emacs-events--host-frame-record
        (list :reorder-workspaces ids))))
    ("archived"
     (let ((ids (dsh-emacs--sequence-list
                 (dsh-emacs-render--aget "archivedSessionIds" value))))
       (dsh-emacs-events--host-set-archived ids)
       (dsh-emacs-events--host-frame-record (list :set-archived ids))))
    ("ready"
     ;; $events ready: this generation's clientId.  Each reconnect yields a
     ;; new generation/clientId; the old generation's still-queued waterfalls
     ;; can no longer be answered meaningfully, so retire them.
     (let ((client-id (dsh-emacs-render--aget "clientId" value)))
       (when client-id
         (when (and dsh-emacs-events--client-id
                    (not (equal client-id dsh-emacs-events--client-id)))
           (dsh-emacs--waterfall-generation-retired))
         (setq dsh-emacs-events--client-id client-id))))
    ("emit"
     (let* ((name (dsh-emacs-render--aget "event" value))
            (args (dsh-emacs--sequence-list
                   (dsh-emacs-render--aget "args" value))))
       (pcase name
         ("api-session/added"
          (let ((summary (car args)))
            (when (listp summary)
              (dsh-emacs-events--host-session-added summary)
              (dsh-emacs-events--host-frame-record
               (list :session-added summary)))))
         ("api-session/removed"
          (let ((sid (car args)))
            (dsh-emacs-events--host-session-removed sid)
            (dsh-emacs-events--host-frame-record
             (list :session-removed sid))))
         ("api-session/status"
          (let ((sid (nth 0 args)))
            (when sid
              (dsh-emacs-events--host-session-status sid (nth 1 args))
              (dsh-emacs-events--host-frame-record
               (list :session-status sid (nth 1 args))))))
         ("api-session/activity"
          ;; Re-sort the cached list by the reported updatedAt; the summary
          ;; ordering mirrors `session/list' (updatedAt desc).
          (let ((sid (nth 0 args)))
            (when sid
              (dsh-emacs-events--host-session-activity sid (nth 1 args)))))
         (_ nil))))
    ("waterfall"
     ;; Approval / question waterfalls arrive on `$events' and are answered
     ;; via POST /api/$events/result (see `dsh-emacs--events-result-async' in
     ;; dsh-emacs.el).  VALUE carries {type, event, eventId, agentId,
     ;; request}; the target chat buffer is resolved by agentId.
     (let* ((event-name (dsh-emacs-render--aget "event" value))
            (event-id (dsh-emacs-render--aget "eventId" value))
            (agent-id (dsh-emacs-render--aget "agentId" value))
            (request (dsh-emacs-render--aget "request" value))
            (chat (and agent-id
                       (dsh-emacs-events--chat-buffer agent-id))))
       (if (not (and event-id (buffer-live-p chat)))
           ;; No open chat for the asking agent (or no event id): this client
           ;; is not the waterfall's claimant — hand it on so the host does
           ;; not wait on us.
           (when (and event-id dsh-emacs-events--client-id)
             (dsh-emacs--events-result-async
              dsh-emacs-events--client-id event-id '((kind . "next"))
              (lambda (_ok _value) nil)))
         (pcase event-name
           ("approval/request"
            (dsh-emacs--approval-requested
             chat event-id agent-id
             (dsh-emacs-render--aget "toolName" request)
             (dsh-emacs-render--aget "reason" request)
             (dsh-emacs-render--aget "callId" request)))
           ("user-questions/request"
            (dsh-emacs--question-requested
             chat event-id agent-id
             (dsh-emacs--sequence-list
              (dsh-emacs-render--aget "questions" request))))
           (_ nil)))))
    ("cancel"
     ;; Waterfall retirement: drop any still-queued question/approval frame
     ;; for EVENT-ID (replay of the same waterfall never re-asks it).
     (let ((event-id (dsh-emacs-render--aget "eventId" value)))
       (when event-id
         (dsh-emacs--question-cancelled event-id)
         (dsh-emacs--approval-cancelled event-id))))
    ;; Accepted no-op kinds (no UI consumes them yet): `session/control'
    ;; `jobs' frames/records (background-task mirror), the `api-session/error'
    ;; emit, and any other host frame type we do not render.  Intentionally
    ;; dropped, not wire-parity work — revisit when a jobs/task or error
    ;; surface is added.
    (_ nil)))

(defun dsh-emacs-events--chat-buffer (session-id)
  "Live chat buffer of SESSION-ID, or nil."
  (and (hash-table-p dsh-emacs--chat-buffers)
       (gethash session-id dsh-emacs--chat-buffers)))

(defun dsh-emacs-events--host-workspace-baseline (value)
  "Seed the workspace/archive caches from a `workspace/follow' baseline."
  (let* ((items (dsh-emacs--sequence-list
                 (dsh-emacs-render--aget "items" value)))
         (archived (dsh-emacs--sequence-list
                    (dsh-emacs-render--aget "archivedSessionIds" value))))
    (setq dsh-emacs--workspaces
          (mapcar #'dsh-protocol-workspace--from-alist items))
    (dsh-emacs-events--host-set-archived archived)
    (dsh-emacs-events--host-repaint)))

(defun dsh-emacs-events--host-control-baseline (process value)
  "Seed chat queue mirrors and projections from a `session/control'
baseline VALUE (whole-host queues/jobs/projections records).  The `jobs'
record is intentionally not read — no background-task UI consumes it yet
(see the accepted no-op kinds in `dsh-emacs-events--host-item')."
  (let* ((queues (dsh-emacs-render--aget "queues" value))
         (projections (dsh-emacs-render--aget "projections" value)))
    (dolist (pair (if (vectorp queues) (append queues nil)
                    (and (listp queues) queues)))
      (when (and (listp pair) (cdr pair))
        (let ((sid (car pair))
              (items (dsh-emacs--sequence-list (cdr pair))))
          (when (and sid (buffer-live-p (dsh-emacs-events--chat-buffer sid)))
            (dsh-emacs-queue-apply
             (dsh-emacs-events--chat-buffer sid)
             process
             (list (cons 'sessionId sid) (cons 'items items)))))))
    ;; Projection baseline: Record<sessionId, SessionProjectionBaseline>.
    (dolist (pair (if (vectorp projections) (append projections nil)
                    (and (listp projections) projections)))
      (when (and (listp pair) (cdr pair))
        (let* ((sid (car pair))
               (baseline (cdr pair))
               (values (dsh-emacs-render--aget "values" baseline)))
          (dolist (kv (if (vectorp values) (append values nil)
                        (and (listp values) values)))
            (when (and (listp kv) (cdr kv))
              (dsh-emacs-events--host-apply-projection
               sid (car kv) (cdr kv)))))))))

(defun dsh-emacs-events--host-apply-projection (session-id key value)
  "Apply one projection cell (KEY . VALUE) of SESSION-ID locally.
`contextPressure' feeds the mode-line ctx%, `title' the session cache and
chat buffer name; other keys are reserved for later milestones."
  (when session-id
    (pcase key
      ("contextPressure"
       (when (listp value)
         (dsh-emacs--events-apply-context-projection session-id value)))
      ("title"
       (when (and value (not (string-empty-p value)))
         (dsh-emacs-events--apply-title nil session-id value)
         (dsh-emacs-events--host-frame-record
          (list :apply-title session-id value))))
      (_ nil))))

(defun dsh-emacs-events--host-session-activity (session-id _updated-at)
  "Bump SESSION-ID to the front of the cached session list (recent first)."
  (let ((item (dsh-emacs--chat-session-item session-id)))
    (when (and item (listp dsh-emacs--sessions))
      (setq dsh-emacs--sessions
            (cons item (delq item dsh-emacs--sessions)))
      (dsh-emacs-events--host-repaint))))

(defun dsh-emacs-events--host-lost (process)
  "Handle a closed host-stream PROCESS: reset and schedule reconnect."
  (let ((buffer (process-get process 'dsh-emacs-host-buffer)))
    (when (and (buffer-live-p buffer)
               (eq process (with-current-buffer buffer
                             dsh-emacs--host-process)))
      (with-current-buffer buffer
        (setq dsh-emacs--host-process nil
              dsh-emacs--host-ready nil)
        (unless (timerp dsh-emacs--host-reconnect-timer)
          (setq dsh-emacs--host-reconnect-timer
                (run-at-time 1 nil
                             (lambda (buffer)
                               (when (buffer-live-p buffer)
                                 (with-current-buffer buffer
                                   (setq dsh-emacs--host-reconnect-timer nil)
                                   (dsh-emacs-events-host-connect))))
                             buffer)))))))

(defun dsh-emacs-events-host-connect ()
  "Connect BUFFER's core stream to dsh's `/api/remote.mux'.
The core connection is scoped to the session-list buffer (owned by
`dsh-emacs-session-mode'): it opens the `session/control',
`workspace/follow' and `$events' logical streams after the handshake
(`dsh-emacs-events--host-open') and repaints the list on workspace/
session/archive/queue/projection changes while the list is open;
everything tears down with the buffer."
  (when (buffer-live-p (current-buffer))
    (dsh-emacs-events-host-disconnect)
    (when (and (bound-and-true-p dsh-emacs-base-url)
               (not (string-empty-p dsh-emacs-base-url)))
      (let* ((url (url-generic-parse-url dsh-emacs-base-url))
             (host (url-host url))
             (port (or (url-port url)
                       (if (equal (url-type url) "https") 443 80))))
        (when (and host port)
          (let ((buffer (current-buffer)))
            (let ((stream-buffer (get-buffer-create " *dsh-host*")))
              (with-current-buffer stream-buffer
                (set-buffer-multibyte nil))
              (let ((process
                     (let ((url-proxy-services nil))
                       (open-network-stream
                        "dsh-host" stream-buffer host port
                        :type (if (equal (url-type url) "https") 'tls 'plain)
                        :nowait t))))
                (set-process-query-on-exit-flag process nil)
                ;; Keep CRLF handshake bytes untouched.  Without this the
                ;; process coding system is inferred as nil (the stream buffer
                ;; is converted to unibyte BEFORE opening, unlike the mux
                ;; connect), and Emacs then folds the response's CRLF line
                ;; endings to LF, so `\r\n\r\n' never matches and the
                ;; handshake never completes.  `no-conversion' preserves the
                ;; raw bytes so `dsh-emacs-events--filter' sees the exact
                ;; HTTP/1.1 101 upgrade response.
                (set-process-coding-system process 'no-conversion
                                           'no-conversion)
                (process-put process 'dsh-emacs-host-stream t)
                (process-put process 'dsh-emacs-event-input "")
                (process-put process 'dsh-emacs-event-ready nil)
                (process-put process 'dsh-emacs-host-buffer buffer)
                ;; Reuse the mux sentinel: it routes by the host-stream property
                ;; to `dsh-emacs-events--host-lost', and the handshake path is
                ;; taken from the process property (defaults to
                ;; /api/remote.mux).  Bytecode delegates, as with the mux
                ;; (native subrs are not reliably invoked as `:nowait' filters
                ;; on this build).
                (set-process-filter process dsh-emacs-events--filter-fn)
                (set-process-sentinel process dsh-emacs-events--sentinel-fn)
                (with-current-buffer buffer
                  (setq dsh-emacs--host-process process
                        dsh-emacs--host-ready nil))))))))))

(defun dsh-emacs-events--host-open (process)
  "Open the core logical streams on PROCESS after its handshake.
`session/control' and `workspace/follow' carry the whole-host control and
workspace state; `$events' broadcasts host events and (later milestone)
waterfalls.  Each stream uses a fresh stream id; the `workspace/follow'
stream id is recorded on PROCESS so a later re-baseline
(`dsh-emacs-events--core-workspace-rebaseline') can retire it before
re-opening (never two live workspace streams on one socket)."
  (when (process-live-p process)
    (dolist (endpoint '("session/control" "workspace/follow" "$events"))
      (let* ((stream-id (dsh-emacs-events--stream-id))
             (json (dsh-emacs-events--open-message stream-id endpoint nil)))
        (when (equal endpoint "workspace/follow")
          (process-put process 'dsh-emacs-host-ws-stream-id stream-id))
        (process-send-string process
                             (dsh-emacs-events--frame 1 json))))))

(defun dsh-emacs-events--core-workspace-rebaseline ()
  "Ask the core connection to resend the `workspace/follow' baseline.
The 0.1.2 protocol has no `workspace/list' RPC: a re-baseline re-opens the
`workspace/follow' stream on the live core socket, whose fresh baseline
seeds the workspace/archive caches.  Because `dsh-emacs-events--host-item'
dispatches on logical frame type and ignores `streamId', a second live
`workspace/follow' stream would feed the same caches as the one opened at
connect — a stale `order'/'remove' from the retired stream could revert a
newer reorder.  The prior stream is therefore cancelled first (its frames
are dropped once the host closes it), then a fresh one is opened and its
id recorded.  Returns non-nil when a core process existed and the request
was sent."
  (let* ((list-buf (and (boundp 'dsh-emacs-sessions-buffer)
                        (get-buffer dsh-emacs-sessions-buffer)))
         (proc (and list-buf
                    (buffer-local-value 'dsh-emacs--host-process list-buf))))
    (when (and (processp proc) (process-live-p proc))
      ;; Retire the workspace/follow stream opened at connect (or by the last
      ;; re-baseline) so exactly one live workspace stream feeds the caches.
      (let ((old (process-get proc 'dsh-emacs-host-ws-stream-id)))
        (when old
          (process-send-string
           proc (dsh-emacs-events--frame
                 1 (dsh-emacs-events--cancel-message old)))))
      (let* ((stream-id (dsh-emacs-events--stream-id))
             (json (dsh-emacs-events--open-message
                    stream-id "workspace/follow" nil)))
        (process-put proc 'dsh-emacs-host-ws-stream-id stream-id)
        (process-send-string proc (dsh-emacs-events--frame 1 json)))
      t)))

(defun dsh-emacs-events-host-disconnect ()
  "Disconnect the current buffer's host stream, if any."
  (when (timerp dsh-emacs--host-reconnect-timer)
    (cancel-timer dsh-emacs--host-reconnect-timer))
  (setq dsh-emacs--host-reconnect-timer nil)
  (let ((process dsh-emacs--host-process))
    ;; Clear ownership before deleting: the host sentinel must not schedule a
    ;; reconnect for an intentional teardown.
    (setq dsh-emacs--host-process nil
          dsh-emacs--host-ready nil)
    (when (process-live-p process)
      (delete-process process))))

(provide 'dsh-emacs-events)

;;; dsh-emacs-events.el ends here
