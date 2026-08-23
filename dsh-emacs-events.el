;;; dsh-emacs-events.el --- dsh WebSocket event stream -*- lexical-binding: t; no-native-compile: t -*-

;; Copyright (C) 2026 vritser
;; License: GPL-3.0-or-later

;;; Commentary:
;;
;; dsh Web uses /api/events.mux as a long-lived WebSocket carrying
;; server-request envelopes whose payload is session/event.  Emacs does not
;; ship a WebSocket client, so this module implements the small RFC 6455
;; client needed by that endpoint directly on top of `open-network-stream'.
;; HTTP history remains the bootstrap and reconnect fallback.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'url-parse)

(defvar-local dsh-emacs--event-process nil)
(defvar-local dsh-emacs--event-ready nil)
(defvar-local dsh-emacs--event-history-loading nil)
(defvar-local dsh-emacs--event-reconnect-timer nil)
(defvar-local dsh-emacs--event-connect-timer nil)
;; Owned by dsh-emacs.el (defined later in load order); reset here on
;; handshake so a later disconnect can warn about fallback polling again.
(defvar-local dsh-emacs--poll-warned nil)
(defvar-local dsh-emacs--poll-timer nil)

;; Last wall-clock time (float-time) at which the stream delivered an event,
;; and watchdog bookkeeping for confirming the stream stays healthy mid-turn.
(defvar-local dsh-emacs--ws-last-event-time nil)
(defvar-local dsh-emacs--ws-last-probe-time nil)
(defvar-local dsh-emacs--ws-probe-inflight nil)
(defvar-local dsh-emacs--ws-watchdog-timer nil)

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

;; Defined in dsh-emacs-footer.el, which loads after this module.  Referenced
;; at runtime from teardown only.
(declare-function dsh-emacs--ml-busy-clear "dsh-emacs-footer" ())
;; Runtime dependencies defined in dsh-emacs.el / dsh-emacs-render.el; used
;; by the stream-health watchdog only.
(declare-function dsh-emacs--rpc-async "dsh-emacs" (method params callback))
(declare-function dsh-emacs--sequence-list "dsh-emacs" (value))
(declare-function dsh-emacs-render-history-events "dsh-emacs-render" (events stream))
(declare-function dsh-emacs-render--consume-pending-user-message "dsh-emacs-render" (event))
(declare-function dsh-emacs-render--event-seq "dsh-emacs-render" (event))

(defun dsh-emacs-events--chat (process)
  "Return the chat buffer attached to PROCESS."
  (process-get process 'dsh-emacs-chat-buffer))

(defun dsh-emacs-events--send-handshake (process)
  "Send the WebSocket upgrade request for PROCESS."
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
         (path "/api/events.mux")
         (origin (format "%s://%s%s"
                         (url-type url) host
                         (if (and port (not (memq port '(80 443))))
                             (format ":%s" port)
                           ""))))
    (let ((request (format "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nOrigin: %s\r\n\r\n"
                           path host-header key origin)))
      (process-send-string process request))))

(defun dsh-emacs-events--random-mask ()
  "Return four random bytes as a unibyte string."
  (apply #'unibyte-string
         (cl-loop repeat 4 collect (random 256))))

(defun dsh-emacs-events--frame (opcode payload)
  "Encode client WebSocket PAYLOAD with OPCODE."
  (let* ((payload (or payload ""))
         (payload (if (multibyte-string-p payload)
                      (encode-coding-string payload 'utf-8 t)
                    payload))
         (length (length payload))
         (mask (dsh-emacs-events--random-mask))
         (header (cond
                  ((< length 126)
                   (unibyte-string 129 (logior 128 length)))
                  ((< length 65536)
                   (concat (unibyte-string 129 254)
                           (unibyte-string (logand (lsh length -8) 255)
                                           (logand length 255))))
                  (t
                   (concat (unibyte-string 129 255)
                           (apply #'unibyte-string
                                  (cl-loop for shift from 56 downto 0 by 8
                                           collect (logand (lsh length (- shift))
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
          (setq size (+ (lsh (aref input offset) 8)
                        (aref input (1+ offset)))
                offset (+ offset 2)))
         ((= size 127)
          (when (< length (+ offset 8)) (cl-return-from dsh-emacs-events--read-frame nil))
          (setq size 0)
          (dotimes (i 8)
            (setq size (+ (lsh size 8) (aref input (+ offset i)))))
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

(defun dsh-emacs-events--dispatch-event (chat event)
  "Dispatch EVENT received for CHAT, respecting seq and optimistic input."
  (when (and (buffer-live-p chat) (listp event))
    (with-current-buffer chat
      (if (dsh-emacs-render--consume-pending-user-message event)
          (let ((seq (dsh-emacs-render--event-seq event)))
            (when (integerp seq)
              (setq dsh-emacs--anchor-seq
                    (max dsh-emacs--anchor-seq seq))))
        (dsh-emacs-render-event event))
      ;; The stream just delivered: note it for the stall watchdog.
      (setq dsh-emacs--ws-last-event-time (float-time))
      ;; Keep windows that already show the bottom pinned to the newest
      ;; content; never touch windows the user scrolled away.
      (dsh-emacs-render--follow-stream))))

(defun dsh-emacs-events--dispatch-json (process json)
  "Handle one decoded WebSocket JSON envelope from PROCESS.
While the initial history is loading, the mux replay of the ENTIRE global
backlog is dropped UNPARSED: big sessions alone replay 500k+ raw events, and
queueing + sorting + flushing them (historically the multi-second freeze on
every open) was pure waste, since the history page's anchor already sits at
the newest seq once the page renders.  The gap this drop opens is closed by
one bounded re-fetch (`dsh-emacs--load-history'), and live events resume
through the normal path once loading completes."
  (condition-case err
      (let ((chat (dsh-emacs-events--chat process)))
        (when (and (buffer-live-p chat)
                   (not (with-current-buffer chat
                          dsh-emacs--event-history-loading)))
          (let* ((message (json-read-from-string json))
                 (payload (dsh-emacs-render--aget "payload" message))
                 (type (dsh-emacs-render--aget "type" payload))
                 (session-id (dsh-emacs-render--aget "sessionId" payload))
                 (event (dsh-emacs-render--aget "event" payload)))
            (when (and (equal type "session/event")
                       (equal session-id
                              (with-current-buffer chat dsh-emacs--current-session))
                       event)
              (dsh-emacs-events--dispatch-event chat event)))))
    (error (message "dsh event decode error: %S" err))))

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
                           (string-as-unibyte string))))
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
                    (let ((chat (dsh-emacs-events--chat process)))
                      (when (buffer-live-p chat)
                        (with-current-buffer chat
                          (setq dsh-emacs--event-ready t)
                          (setq dsh-emacs--poll-warned nil)
                          (setq dsh-emacs--ws-last-event-time (float-time))
                          (when (timerp dsh-emacs--poll-timer)
                            (cancel-timer dsh-emacs--poll-timer)
                            (setq dsh-emacs--poll-timer nil))
                          (dsh-emacs-events--health-stop))))
                    (dsh-emacs-events--consume-frames process))
                (delete-process process)))))))))

(defun dsh-emacs-events--lost (process)
  "Handle a closed event stream PROCESS and arrange reconnect/fallback."
  (let ((chat (dsh-emacs-events--chat process)))
    (when (and (buffer-live-p chat)
               (eq process (with-current-buffer chat dsh-emacs--event-process)))
      (with-current-buffer chat
        (setq dsh-emacs--event-process nil
              dsh-emacs--event-ready nil)
        (dsh-emacs-events--health-stop)
        (dsh-emacs-events--watchdog-stop)
        ;; Keep the conversation usable while reconnecting.
        (when (fboundp 'dsh-emacs--start-polling)
          (dsh-emacs--start-polling))
        (unless (timerp dsh-emacs--event-reconnect-timer)
          (setq dsh-emacs--event-reconnect-timer
                (run-at-time 1 nil
                             (lambda (buffer)
                               (when (buffer-live-p buffer)
                                 (with-current-buffer buffer
                                   (setq dsh-emacs--event-reconnect-timer nil)
                                   (dsh-emacs-events-connect buffer))))
                             chat)))))))

(defun dsh-emacs-events--sentinel (process _event)
  "Handle PROCESS lifecycle changes."
  (when (and (process-live-p process)
             (eq (process-status process) 'open)
             (not (process-get process 'dsh-emacs-event-handshake-sent)))
    (process-put process 'dsh-emacs-event-handshake-sent t)
    (dsh-emacs-events--send-handshake process))
  (when (memq (process-status process) '(closed failed exit signal))
    (dsh-emacs-events--lost process)))

(defun dsh-emacs-events--watchdog-tick ()
  "Confirm the event stream is actually delivering while a turn runs.
The dsh mux can leave a socket open-but-unread (bytes pile up in the kernel
queue while Emacs never invokes the process filter), making the stream look
alive although nothing renders.  A cheap `session.history' fetch both renders
whatever the stream missed (anchor-diffed, so re-delivery is harmless) and
reveals the stall: if the anchor advanced although the stream had been silent
for > 3s, kill the socket so the sentinel reconnects and HTTP polling takes
over.  Self-stops outside an active turn."
  (when (buffer-live-p dsh-emacs--current-buffer)
    (with-current-buffer dsh-emacs--current-buffer
      (if (and (bound-and-true-p dsh-emacs--ml-busy)
               dsh-emacs--event-ready
               (process-live-p dsh-emacs--event-process)
               (null dsh-emacs--poll-timer))
          (let ((now (float-time)))
            (when (and (not dsh-emacs--ws-probe-inflight)
                       (or (null dsh-emacs--ws-last-event-time)
                           (> (- now dsh-emacs--ws-last-event-time) 3.0))
                       (> (- now (or dsh-emacs--ws-last-probe-time 0)) 3.0))
              (setq dsh-emacs--ws-last-probe-time now)
              (setq dsh-emacs--ws-probe-inflight t)
              (let ((before dsh-emacs--anchor-seq)
                    (buffer (current-buffer)))
                (dsh-emacs--rpc-async
                 "session.history"
                 `((sessionId . ,dsh-emacs--current-session)
                   (maxMessages . 50))
                 (lambda (ok value)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (setq dsh-emacs--ws-probe-inflight nil)
                       (when ok
                         (let ((events (dsh-emacs--sequence-list
                                        (cdr (assq 'events value)))))
                           (dsh-emacs-render-history-events events t)
                           (when (> dsh-emacs--anchor-seq before)
                             ;; New content existed that the stream failed to
                             ;; deliver: it is stalled.  Kill it; the sentinel
                             ;; will reconnect and start HTTP polling.
                             (when (process-live-p dsh-emacs--event-process)
                               (delete-process dsh-emacs--event-process))))))))))))
        ;; No turn in progress (or polling already covers us): stop.
        (dsh-emacs-events--watchdog-stop)))))

(defun dsh-emacs-events--watchdog-start ()
  "Start the mid-turn stream-health watchdog for the current buffer."
  (setq dsh-emacs--ws-last-event-time (float-time))
  (unless (timerp dsh-emacs--ws-watchdog-timer)
    (setq-local dsh-emacs--ws-watchdog-timer
                (run-with-timer 2 dsh-emacs-poll-interval
                                #'dsh-emacs-events--watchdog-tick))))

(defun dsh-emacs-events--watchdog-stop ()
  "Cancel the stream-health watchdog timer."
  (when (timerp dsh-emacs--ws-watchdog-timer)
    (cancel-timer dsh-emacs--ws-watchdog-timer))
  (setq-local dsh-emacs--ws-watchdog-timer nil))

(defun dsh-emacs-events--health-tick (buffer)
  "Health-check the stream socket of BUFFER every repeat.
A `:nowait' socket on affected builds can stay `open' while the kernel queue
fills and the filter never runs (handshake never processed).  If BUFFER's
handshake has not completed, delete the socket so the sentinel starts HTTP
polling and schedules a fresh connect; stop once ready or the socket is gone.
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
  "Connect CHAT to dsh's `/api/events.mux' WebSocket stream."
  (when (buffer-live-p chat)
    (with-current-buffer chat
      (dsh-emacs-events-disconnect chat)
      (let* ((url (url-generic-parse-url dsh-emacs-base-url))
             (host (url-host url))
             (port (or (url-port url)
                       (if (equal (url-type url) "https") 443 80)))
             (buffer (get-buffer-create
                      (format " *dsh-events:%s*" dsh-emacs--current-session)))
             (process (let ((url-proxy-services nil))
                        (open-network-stream
                         (buffer-name buffer) buffer host port
                         :type (if (equal (url-type url) "https") 'tls 'plain)
                         :nowait t))))
        (with-current-buffer buffer
          (set-buffer-multibyte nil))
        (set-process-query-on-exit-flag process nil)
        (process-put process 'dsh-emacs-chat-buffer chat)
        (process-put process 'dsh-emacs-event-input "")
        (process-put process 'dsh-emacs-event-ready nil)
        ;; Install the bytecode delegates, not the native subrs directly:
        ;; `:nowait' sockets whose filter is a native-compiled subr stop being
        ;; read on affected Emacs builds (see `dsh-emacs-events--filter-fn').
        (set-process-filter process dsh-emacs-events--filter-fn)
        (set-process-sentinel process dsh-emacs-events--sentinel-fn)
        (setq dsh-emacs--event-process process
              dsh-emacs--event-ready nil
              dsh-emacs--ws-last-event-time (float-time)
              dsh-emacs--ws-last-probe-time nil
              dsh-emacs--ws-probe-inflight nil)
        ;; Connect health (repeating): while the handshake is pending, every
        ;; 2s check that the socket is really being read; a wedged socket is
        ;; killed so `dsh-emacs-events--lost' starts HTTP polling and retries.
        (dsh-emacs-events--health-start)))))

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
        ;; Polling is tied to this conversation/stream: tear it down too, so
        ;; a reused chat buffer never keeps polling a dead session.
        (when (timerp dsh-emacs--poll-timer)
          (cancel-timer dsh-emacs--poll-timer))
        (setq dsh-emacs--poll-timer nil)
        (let ((process dsh-emacs--event-process))
          ;; Clear ownership before deleting: the sentinel must not schedule a
          ;; reconnect for an intentional session switch or buffer teardown.
          (setq dsh-emacs--event-process nil
                dsh-emacs--event-ready nil)
          (when (process-live-p process)
            (delete-process process)))
        ;; Tearing down the stream: stop the mode-line running spinner so it
        ;; never keeps ticking in a detached conversation.
        (when (fboundp 'dsh-emacs--ml-busy-clear)
          (dsh-emacs--ml-busy-clear))))))

(provide 'dsh-emacs-events)

;;; dsh-emacs-events.el ends here
