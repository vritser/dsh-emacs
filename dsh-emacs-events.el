;;; dsh-emacs-events.el --- dsh WebSocket event stream -*- lexical-binding: t; no-native-compile: t -*-

;; Copyright (C) 2026 vritser
;; License: GPL-3.0-or-later

;;; Commentary:
;;
;; dsh Web uses /api/events.mux as a long-lived WebSocket carrying
;; server-request envelopes whose payload is session/event, an answerable
;; ask-user interaction (question/requested), or an answerable sandbox
;; approval (approval/requested — both answered via POST /api/respond,
;; see `dsh-emacs--question-requested' / `dsh-emacs--approval-requested').
;; Emacs does not ship a WebSocket client, so this module implements the
;; small RFC 6455 client needed by that endpoint directly on top of
;; `open-network-stream'.  HTTP `session.history' remains the bootstrap for
;; opening a session; the mux stream is the only automatic delivery channel.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'url-parse)

(defvar-local dsh-emacs--event-process nil)
(defvar-local dsh-emacs--event-ready nil)
(defvar-local dsh-emacs--event-history-loading nil)
(defvar-local dsh-emacs--event-reconnect-timer nil)
(defvar-local dsh-emacs--event-connect-timer nil)

;; Last wall-clock time (float-time) at which the stream delivered an event,
;; and watchdog bookkeeping for confirming the stream stays healthy mid-turn.
(defvar-local dsh-emacs--ws-last-event-time nil)
(defvar-local dsh-emacs--ws-last-probe-time nil)
(defvar-local dsh-emacs--ws-probe-inflight nil)
(defvar-local dsh-emacs--ws-watchdog-timer nil)

;; The list view (`*dsh-sessions*') additionally subscribes to
;; `/api/events.host', the dsh-wide host stream.  Unlike the per-chat mux
;; it is scoped to the list buffer's lifecycle: workspace/session/archive
;; changes arrive there and refresh the caches and the list in place, so a
;; dsh web (or second client) editing a workspace shows up without `g'.
(defvar-local dsh-emacs--host-process nil
  "Live host-stream network process, or nil.")
(defvar-local dsh-emacs--host-ready nil
  "Non-nil once the host-stream handshake completed.")
(defvar-local dsh-emacs--host-reconnect-timer nil
  "Timer scheduling a host-stream reconnect after a drop.")

;; Refresh in-flight protection (mirrors dsh web's `refreshFrames'): a
;; `session.list'/`workspace.list' response is a snapshot at request time.
;; When the response is in flight, host/mux frames may already have advanced
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
(declare-function dsh-emacs--chat-session-item "dsh-emacs" (session-id))
(declare-function dsh-emacs--chat-buffer-sync "dsh-emacs" (session-id))
(declare-function dsh-emacs--question-requested "dsh-emacs" (chat rpc-id session-id questions))
(declare-function dsh-emacs--approval-requested "dsh-emacs" (chat rpc-id session-id approval-id tool-name reason call-id))
(declare-function dsh-emacs--approval-resolved "dsh-emacs" (session-id approval-id outcome))
(declare-function dsh-emacs-render--aget "dsh-emacs-render" (key alist))
(declare-function dsh-emacs-render--json-bool "dsh-emacs-render" (value))
(declare-function dsh-emacs-session--render "dsh-emacs-session" ())
(declare-function dsh-emacs--normalize-archived "dsh-emacs" (archived))
(declare-function dsh-emacs-modeline-set-context-snapshot "dsh-emacs-modeline" (pressure window))
(declare-function dsh-emacs-server--basic-auth-header "dsh-emacs-server" ())

;; Defined in dsh-emacs-modeline.el, which loads after this module.  Referenced
;; at runtime from teardown only.
(declare-function dsh-emacs--ml-busy-clear "dsh-emacs-modeline" ())
(declare-function dsh-emacs--ml-busy-set "dsh-emacs-modeline" (flag))
(declare-function dsh-emacs--command-spinner-clear-all "dsh-emacs-render" ())
(declare-function dsh-emacs--command-spinner-revive "dsh-emacs-render" ())
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
  "Send the WebSocket upgrade request for PROCESS.
The path defaults to `/api/events.mux'; the host stream (list-scoped)
overrides it via the `dsh-emacs-event-path' process property."
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
         (path (or (process-get process 'dsh-emacs-event-path)
                   "/api/events.mux"))
         (origin (format "%s://%s%s"
                         (url-type url) host
                         (if (and port (not (memq port '(80 443))))
                             (format ":%s" port)
                           ""))))
    (let* ((auth (and (fboundp 'dsh-emacs-server--basic-auth-header)
                      (dsh-emacs-server--basic-auth-header)))
           (request (concat
                     (format "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nOrigin: %s\r\n"
                             path host-header key origin)
                     ;; nginx basic auth 下握手必须带认证头，否则 401 拒绝、
                     ;; 实时事件流（mux/host）全部断连。
                     (if auth (format "%s: %s\r\n" (car auth) (cdr auth)) "")
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

(defun dsh-emacs-events--apply-title (chat session-id title)
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
`session.list' projections carry, aligned with dsh web's ctx meter which
reads projectedTokens ?? pressureTokens).  Only the session's live chat
buffer is touched; the mode-line snapshot setter lands the pair in one go."
  (when (and (listp value)
             (hash-table-p dsh-emacs--chat-buffers))
    (let* ((projected (dsh-emacs-render--aget "projectedTokens" value))
           (pressure (dsh-emacs-render--aget "pressureTokens" value))
           (window (dsh-emacs-render--aget "contextWindow" value))
           ;; dsh web 口径：优先 projected（含 surface 增量），回退 pressure
           (used (or (and (numberp projected) projected)
                     (and (numberp pressure) pressure)))
           (buf (gethash session-id dsh-emacs--chat-buffers)))
      (when (and used window (> window 0)
                 (buffer-live-p buf)
                 (fboundp 'dsh-emacs-modeline-set-context-snapshot))
        (with-current-buffer buf
          (dsh-emacs-modeline-set-context-snapshot used window))))))

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
Host-stream frames (list-scoped workspace/session/archive changes) are
routed to `dsh-emacs-events--host-dispatch'; the mux stream (per-chat
session/event envelopes) goes to the transcript path below, and
answerable `question/requested' frames are presented and answered
interactively (they are NOT gated on history loading — pending
questions replay on mux open; answering is queued one frame at a time,
since the minibuffer is a single global resource).
While the initial history is loading, the mux replay of the ENTIRE global
backlog is dropped UNPARSED: big sessions alone replay 500k+ raw events, and
queueing + sorting + flushing them (historically the multi-second freeze on
every open) was pure waste, since the history page's anchor already sits at
the newest seq once the page renders.  The gap this drop opens is closed by
one bounded re-fetch (`dsh-emacs--load-history'), and live events resume
through the normal path once loading completes."
  (condition-case err
      (if (and (processp process)
               (process-get process 'dsh-emacs-host-stream))
          (dsh-emacs-events--host-dispatch process json)
        (let ((chat (dsh-emacs-events--chat process)))
          (when (buffer-live-p chat)
            (let* ((message (json-read-from-string json))
                   (payload (dsh-emacs-render--aget "payload" message))
                   (rpc-id (dsh-emacs-render--aget "rpcId" message))
                   (type (dsh-emacs-render--aget "type" payload))
                   (session-id (dsh-emacs-render--aget "sessionId" payload))
                   (event (dsh-emacs-render--aget "event" payload)))
              (cond
               ;; answerable ask-user interaction (`ask' tool): show the
               ;; question card and read the answers now.  Pending questions
               ;; REPLAY on mux open — possibly while history is still loading
               ;; — so this branch must not be gated on the loading flag.
               ((equal type "question/requested")
                (when (and rpc-id
                           (equal session-id
                                  (buffer-local-value
                                   'dsh-emacs--buffer-session chat)))
                  (dsh-emacs--question-requested
                   chat rpc-id session-id
                   (dsh-emacs-render--aget "questions" payload))))
               ;; answerable sandbox/approval interaction: a tool (bash/fs…)
               ;; that needs to step outside the workspace asks for the user's
               ;; permission.  Answerable like question/requested (stable
               ;; rpcId echoed on POST /api/respond), so it is never gated on
               ;; history loading either — pending approvals REPLAY on mux open
               ;; and must not be dropped with the backlog.
               ((equal type "approval/requested")
                (when (and rpc-id
                           (equal session-id
                                  (buffer-local-value
                                   'dsh-emacs--buffer-session chat)))
                  (dsh-emacs--approval-requested
                   chat rpc-id session-id
                   (dsh-emacs-render--aget "approvalId" payload)
                   (dsh-emacs-render--aget "toolName" payload)
                   (dsh-emacs-render--aget "reason" payload)
                   (dsh-emacs-render--aget "callId" payload))))
               ;; Pure push: the approval was decided (allowed-once/rejected)
               ;; or withdrawn host-side (cancelled/unavailable).  No answer
               ;; is expected — just retire any still-queued frame for the
               ;; same approval so a replay never re-asks a finished one.
               ((equal type "approval/resolved")
                (dsh-emacs--approval-resolved
                 session-id
                 (dsh-emacs-render--aget "approvalId" payload)
                 (dsh-emacs-render--aget "outcome" payload)))
               ;; host 推送的投影帧：会话上下文占用（contextPressure）随
               ;; 事件流实时更新（对齐 dsh web 的 session-projection 推送
               ;; 模型，免去全量 session.list 拉取）。value 是投影的 wire
               ;; view：{projectedTokens, pressureTokens, contextWindow}。
               ;; 投影是 per-session 实时状态，不依赖 history 加载门控。
               ((equal type "session/projection")
                (when (equal (dsh-emacs-render--aget "key" payload)
                             "contextPressure")
                  (dsh-emacs--events-apply-context-projection
                   session-id
                   (dsh-emacs-render--aget "value" payload))))
               ;; Server auto-renames a session after its first turns (summary
               ;; title) and `session.rename' also lands here: both surface as
               ;; a `session/title' event.  Titles are per-session metadata, not
               ;; transcript content, so apply them for ANY session (the buffer
               ;; name and the list row must track dsh web in real time) and
               ;; only render transcript events for the session this chat buffer
               ;; is attached to.  The whole bulk is gated on history loading:
               ;; the mux replay of the ENTIRE backlog is dropped UNPARSED
               ;; during it (see the docstring), and the gap closes on the
               ;; bounded re-fetch once the page renders.
               ((equal type "session/event")
                (when (not (with-current-buffer chat
                             dsh-emacs--event-history-loading))
                  (when (and event
                             (equal (dsh-emacs-render--aget "type" event)
                                    "session/title"))
                    (let ((title (dsh-emacs-render--aget "title"
                                                         (dsh-emacs-render--aget "data" event))))
                      (dsh-emacs-events--apply-title chat session-id title)
                      ;; A refresh snapshot arriving after this title would roll
                      ;; the row back to an old title: record it for replay too.
                      (dsh-emacs-events--host-frame-record
                       (list :apply-title session-id title))))
                  (when (and event
                             (equal session-id
                                    (buffer-local-value
                                     'dsh-emacs--buffer-session chat)))
                    (dsh-emacs-events--dispatch-event chat event))))
               ;; 其余 mux 帧（session/subscribed 等）当前不处理。
               (t nil))))))
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
                    (if (process-get process 'dsh-emacs-host-stream)
                        ;; Host stream has no chat buffer to mark ready; the
                        ;; flag lives on the owning list buffer.
                        (let ((buffer (process-get process
                                                   'dsh-emacs-host-buffer)))
                          (when (buffer-live-p buffer)
                            (with-current-buffer buffer
                              (setq dsh-emacs--host-ready t))))
                      (let ((chat (dsh-emacs-events--chat process)))
                        (when (buffer-live-p chat)
                          (with-current-buffer chat
                            (setq dsh-emacs--event-ready t)
                            (setq dsh-emacs--ws-last-event-time (float-time))
                            (dsh-emacs-events--health-stop)))))
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
alive although nothing renders.  A cheap `session.history' fetch both renders
whatever the stream missed (anchor-diffed, so re-delivery is harmless) and
reveals the stall: if the anchor advanced although the stream had been silent
for > 3s, kill the socket so the sentinel reconnects.  Self-stops outside an
active turn.  BUFFER is the chat buffer this
watchdog was armed for: the timer is buffer-local but timers fire with no
buffer context, so the owning buffer is passed explicitly (with several
session buffers open, the global `dsh-emacs--current-buffer' would point at
the last-opened one and the watchdog would probe the wrong stream)."
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
              (setq dsh-emacs--ws-last-probe-time now)
              (setq dsh-emacs--ws-probe-inflight t)
              (let ((before dsh-emacs--anchor-seq)
                    (buffer (current-buffer)))
                (dsh-emacs--rpc-async
                 "session.history"
                 `((sessionId . ,(or (and (boundp 'dsh-emacs--buffer-session)
                                           dsh-emacs--buffer-session)
                                      dsh-emacs--current-session))
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
                             ;; will reconnect and resume delivery.
                             (when (process-live-p dsh-emacs--event-process)
                               (delete-process dsh-emacs--event-process))))))))))))
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
  "Connect CHAT to dsh's `/api/events.mux' WebSocket stream.

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
;;; Host stream (`/api/events.host') — workspace/session/archive changes
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
           (dsh-emacs-events--host-session-added
            (cadr frame) (car (cddr frame)) (cadr (cddr frame))))
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
The host stream is authoritative for workspace membership, so the cached
workspace (including its `session-ids') is replaced wholesale."
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
`host/workspace-changed' settles) are appended in cache order."
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

(defun dsh-emacs-events--host-session-added (session-id blank cwd)
  "Cache a freshly created SESSION-ID reported by the host stream.
Mirrors `dsh-emacs--cache-new-session' but without workspace attachment:
the host stream reports `host/workspace-changed' separately for the
workspace membership update, so the session row must only appear (blank)
until titles arrive via mux.  Idempotent: a session already cached (from a
`session.create' callback) is left untouched."
  (when (and session-id
             (not (dsh-emacs--chat-session-item session-id)))
    (push (dsh-protocol-session--from-alist
           (list (cons 'sessionId session-id)
                 (cons 'blank t)
                 (cons 'cwd cwd)))
          dsh-emacs--sessions)
    (dsh-emacs-events--host-repaint)))

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
  "Handle one decoded host-stream JSON envelope from PROCESS.
Updates the shared caches (`dsh-emacs--workspaces', `dsh-emacs--sessions',
`dsh-emacs--archived-sessions') in place from the wire payload and repaints
the session list, mirroring dsh web's live workspace browser.  While a
list refresh is in flight the frame is ALSO recorded (like dsh web's
`refreshFrames'); the refresh response snapshot is replayed through the
recorded frames so a stale snapshot never rolls the caches back."
  (condition-case err
      (let* ((message (json-read-from-string json))
             (payload (dsh-emacs-render--aget "payload" message))
             (type (dsh-emacs-render--aget "type" payload)))
        (cond
         ((equal type "host/workspace-changed")
          (let ((ws (dsh-emacs-render--aget "workspace" payload)))
            (when ws
              (let ((struct (dsh-protocol-workspace--from-alist ws)))
                (dsh-emacs-events--host-upsert-workspace struct)
                (dsh-emacs-events--host-frame-record
                 (list :upsert-workspace struct))))))
         ((equal type "host/workspace-removed")
          (let ((id (dsh-emacs-render--aget "workspaceId" payload)))
            (dsh-emacs-events--host-remove-workspace id)
            (dsh-emacs-events--host-frame-record
             (list :remove-workspace id))))
         ((equal type "host/workspace-order-changed")
          (let ((ids (dsh-emacs--sequence-list
                      (dsh-emacs-render--aget "workspaceIds" payload))))
            (dsh-emacs-events--host-reorder-workspaces ids)
            (dsh-emacs-events--host-frame-record
             (list :reorder-workspaces ids))))
         ((equal type "host/archived-sessions-changed")
          (let ((ids (dsh-emacs--sequence-list
                      (dsh-emacs-render--aget "archivedSessionIds" payload))))
            (dsh-emacs-events--host-set-archived ids)
            (dsh-emacs-events--host-frame-record
             (list :set-archived ids))))
         ((equal type "host/session-added")
          (let ((sid (dsh-emacs-render--aget "sessionId" payload))
                (blank (dsh-emacs-render--aget "blank" payload))
                (cwd (dsh-emacs-render--aget "cwd" payload)))
            (dsh-emacs-events--host-session-added sid blank cwd)
            (dsh-emacs-events--host-frame-record
             (list :session-added sid blank cwd))))
         ((equal type "host/session-removed")
          (let ((sid (dsh-emacs-render--aget "sessionId" payload)))
            (dsh-emacs-events--host-session-removed sid)
            (dsh-emacs-events--host-frame-record
             (list :session-removed sid))))
         ((equal type "host/session-status")
          (let ((sid (dsh-emacs-render--aget "sessionId" payload))
                (running (dsh-emacs-render--aget "running" payload)))
            (dsh-emacs-events--host-session-status sid running)
            (dsh-emacs-events--host-frame-record
             (list :session-status sid running))))
         (t nil)))
    (error (message "dsh host event decode error: %S" err))))

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
  "Connect BUFFER's host stream to dsh's `/api/events.host'.
The host stream is scoped to the session-list buffer (owned by
`dsh-emacs-session-mode'): it repaints the list on workspace/session/
archive changes while the list is open, and everything tears down with the
buffer."
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
                (process-put process 'dsh-emacs-event-path
                             "/api/events.host")
                (process-put process 'dsh-emacs-event-input "")
                (process-put process 'dsh-emacs-event-ready nil)
                (process-put process 'dsh-emacs-host-buffer buffer)
                ;; Reuse the mux sentinel: it routes by the host-stream property
                ;; to `dsh-emacs-events--host-lost', and the handshake path is
                ;; taken from the process property (set above).  Bytecode
                ;; delegates, as with the mux (native subrs are not reliably
                ;; invoked as `:nowait' filters on this build).
                (set-process-filter process dsh-emacs-events--filter-fn)
                (set-process-sentinel process dsh-emacs-events--sentinel-fn)
                (with-current-buffer buffer
                  (setq dsh-emacs--host-process process
                        dsh-emacs--host-ready nil))))))))))

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
