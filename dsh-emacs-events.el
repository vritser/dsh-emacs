;;; dsh-emacs-events.el --- dsh WebSocket event stream -*- lexical-binding: t; no-native-compile: t -*-

;; Copyright (C) 2026 vritser
;; Version: 0.7.0
;; Package-Requires: ((emacs "28.1"))
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
(require 'url-parse)
(require 'dsh-emacs-protocol)
(require 'dsh-emacs-server)
(require 'dsh-emacs-subagent)

(defvar-local dsh-emacs--event-process nil)
(defvar-local dsh-emacs--event-ready nil)
(defvar-local dsh-emacs--event-reconnect-timer nil)
(defvar-local dsh-emacs--event-connect-timer nil)

;; Last accepted process-local revision; dense within an Agent lifecycle.
;; A new lifecycle may send start/revision=1 on the same follow connection.
(defvar-local dsh-emacs--assistant-stream-revision nil)

;; Active attempt's :id, :position (TURN . STEP), and dense :next-index.
;; Chunk block indices are unrelated to this frame counter.
(defvar-local dsh-emacs--assistant-stream-attempt nil)

(defvar dsh-emacs-events--snapshot-model-slots nil
  "Dynamic stack of (SESSION-ID . SELECTION) slots for active snapshots.
Core model updates delivered while history yields fill matching slots;
the late snapshot projections must not replace those newer live values.")

;; Last wall-clock time (float-time) at which the stream delivered an event,
;; and watchdog bookkeeping for confirming the stream stays healthy mid-turn.
(defvar-local dsh-emacs--ws-last-event-time nil)
(defvar-local dsh-emacs--ws-last-probe-time nil)
(defvar-local dsh-emacs--ws-probe-inflight nil)
(defvar-local dsh-emacs--ws-watchdog-timer nil)

(defun dsh-emacs-events--stream-id ()
  "Return a fresh client stream id for a `/api/remote.mux' logical stream."
  (format "emacs-%d-%d" (random 999999) (truncate (float-time))))

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

(defvar dsh-emacs-events--defer-host-repaint nil
  "Non-nil while applying a whole host baseline before its final repaint.")

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
(defvar dsh-emacs--history-earliest-seq)
;; Cross-file free variables read under boundp guards: `dsh-emacs-base-url'
;; is a defcustom in dsh-emacs.el, `dsh-emacs--buffer-session' its
;; buffer-local session state.  Declare-only forms — the real definitions
;; own the values.
(defvar dsh-emacs-base-url)
(defvar dsh-emacs--buffer-session)
(defvar dsh-emacs--buffer-subagent)
(defvar dsh-emacs--subagent-departure)
;; Owned by dsh-emacs.el (`defvar-local'); the `userQuestions' projection
;; consumer and the late-answer command share it with the result renderer.
(defvar dsh-emacs--session-questions)
(defvar dsh-emacs--modeline-run-start)
(defvar dsh-emacs-history-window)
(declare-function dsh-emacs-history--start-load "dsh-emacs-history"
                  (count &optional visit))
(declare-function dsh-emacs--chat-session-item "dsh-emacs" (session-id))
(declare-function dsh-emacs--seed-input-history "dsh-emacs" (events session-id &optional older))
(declare-function dsh-emacs--chat-buffer-sync "dsh-emacs" (session-id))
(declare-function dsh-emacs--chat-buffer-model-sync "dsh-emacs"
                  (session-id buf &optional selection))
(declare-function dsh-emacs--question-requested "dsh-emacs" (chat event-id session-id questions &optional wait))
(declare-function dsh-emacs--session-questions-apply "dsh-emacs" (questions))
(declare-function dsh-emacs--question-cancelled "dsh-emacs" (event-id))
(declare-function dsh-emacs-plan--cancel "dsh-emacs-plan" (&optional event-id))
(declare-function dsh-emacs--approval-requested "dsh-emacs" (chat event-id session-id tool-name reason call-id))
(declare-function dsh-emacs--approval-display-reason "dsh-emacs" (request))
(declare-function dsh-emacs--approval-cancelled "dsh-emacs" (event-id))
(declare-function dsh-emacs--events-result-async "dsh-emacs" (client-id event-id outcome callback))
(declare-function dsh-emacs--waterfall-generation-retired "dsh-emacs" ())
(declare-function dsh-emacs-session--render "dsh-emacs-session" ())
(declare-function dsh-emacs--normalize-archived "dsh-emacs" (archived))
(declare-function dsh-emacs-modeline-set-context-snapshot "dsh-emacs-modeline" (pressure window))
(declare-function dsh-emacs-modeline-set-permission "dsh-emacs-modeline" (permission))
(declare-function dsh-emacs-queue-apply "dsh-emacs-queue" (chat process items))
(declare-function dsh-emacs-composer-set-goal "dsh-emacs-composer" (goal))
(declare-function dsh-emacs-jobs-reopen "dsh-emacs-jobs" (chat))

;; Defined in dsh-emacs-modeline.el, which loads after this module.  Referenced
;; at runtime from teardown only.
(declare-function dsh-emacs--ml-busy-clear "dsh-emacs-modeline" ())
(declare-function dsh-emacs--ml-busy-set "dsh-emacs-modeline" (flag))
(declare-function dsh-emacs-modeline-reset-execution
                  "dsh-emacs-modeline" (&optional events))
(declare-function dsh-emacs-modeline-set-plan "dsh-emacs-modeline" (plan))
(declare-function dsh-emacs-render--flush-stream "dsh-emacs-render"
                  (&optional buffer final))
(declare-function dsh-emacs-render--discard-stream "dsh-emacs-render"
                  (&optional key))
;; Runtime dependencies defined in dsh-emacs-render.el.
(declare-function dsh-emacs-render-history-events "dsh-emacs-render" (events &optional stream bound &key insert-before follow-p))
(declare-function dsh-emacs-render--note-history-window "dsh-emacs-render" (entries has-more))
(declare-function dsh-emacs-render--consume-pending-user-message "dsh-emacs-render" (event))
(declare-function dsh-emacs-render-event "dsh-emacs-render" (event))
(declare-function dsh-emacs-render--follow-stream "dsh-emacs-render" (&optional windows))

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
         (default-port (if (equal (url-type url) "https") 443 80))
         (port (or (url-port url) default-port))
         (host-header (if (= port default-port) host
                        (format "%s:%s" host port)))
         (seed (format "%s-%s-%s" (float-time) (random) (emacs-pid)))
         (key (base64-encode-string
               (substring (secure-hash 'sha1 seed nil nil t) 0 16) t))
         (path "/api/remote.mux")
         (origin (format "%s://%s" (url-type url) host-header)))
    (let* ((headers (dsh-emacs--server-auth-header t))
           (request (concat
                     (format "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nOrigin: %s\r\n"
                             path host-header key origin)
                     (mapconcat (lambda (header)
                                  (format "%s: %s\r\n"
                                          (car header) (cdr header)))
                                headers "")
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

(cl-defun dsh-emacs-events--read-frame (input &optional (start 0))
  "Read INPUT at START; return (OPCODE FIN PAYLOAD NEXT), or nil.
NEXT is the byte offset following this frame; INPUT is never copied as a tail."
  (let ((length (length input)))
    (when (>= (- length start) 2)
      (let* ((first (aref input start))
             (second (aref input (1+ start)))
             (fin (/= 0 (logand first 128)))
             (opcode (logand first 15))
             (masked (/= 0 (logand second 128)))
             (size (logand second 127))
             (offset (+ start 2)))
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
          (let ((payload (substring input offset (+ offset size))))
            (when mask
              (dotimes (i size)
                (aset payload i
                      (logxor (aref payload i) (aref mask (mod i 4))))))
            (list opcode fin payload (+ offset size))))))))

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
    (dsh-emacs-events--host-repaint)
    ;; The live chat buffer of that session (if any) renames immediately;
    ;; `dsh-emacs--chat-buffer-sync' also refreshes default-directory.
    (when (and (hash-table-p dsh-emacs--chat-buffers)
               (gethash session-id dsh-emacs--chat-buffers))
      (dsh-emacs--chat-buffer-sync session-id))))

(defun dsh-emacs-events--apply-model-projection (session-id selection)
  "Apply decoded last-used SELECTION to SESSION-ID's cache and live chat.
Record the update even before its row exists, so a pending list refresh
can replay it after installing its older snapshot."
  (when selection
    (when-let* ((item (dsh-emacs--chat-session-item session-id)))
      (setf (dsh-protocol-session-model-selection item) selection))
    (when-let* ((chat (dsh-emacs-events--chat-buffer session-id)))
      (dsh-emacs--chat-buffer-model-sync session-id chat selection))
    (dsh-emacs-events--host-frame-record
     (list :apply-model-selection session-id selection))
    (dsh-emacs-events--host-repaint)))

(defun dsh-emacs--events-apply-context-projection (session-id value)
  "Update SESSION-ID's mode-line ctx% from context projection VALUE.
VALUE is a `dsh-protocol-context-pressure' or a wire alist.  Only the
session's live chat buffer is touched; the snapshot setter lands usage and
window together.  Live projections prefer a positive projected estimate
over raw pressure once the raw sample is trusted.

The whole pair is trusted only while the RAW usage sample is positive: a
provider-rejected run (quota/rate) reports usage 0/0 and the last-wins
sample collapses to 0; the projected estimate — raw pressure plus surface
movement — then just tracks the surface's later
growth (a small lying value after the user submits again).  While the
sample stays 0 the previous snapshot is kept; the next real usage sample
lands the genuine pair."
  (when (hash-table-p dsh-emacs--chat-buffers)
    (pcase-let* (((cl-struct dsh-protocol-context-pressure
                            pressure projected window)
                 (dsh-protocol--struct
                  #'dsh-protocol-context-pressure-p
                  #'dsh-protocol-context-pressure--from-alist value))
                (used (and (numberp pressure) (> pressure 0)
                           (or (and (numberp projected) (> projected 0)
                                    projected)
                               pressure)))
                (buf (gethash session-id dsh-emacs--chat-buffers)))
      (when (and used window (> window 0) (buffer-live-p buf))
        (with-current-buffer buf
          (dsh-emacs-modeline-set-context-snapshot used window))))))

(defun dsh-emacs--events-apply-permission-projection (session-id current)
  "Update SESSION-ID's permission segment from decoded preset CURRENT.
The protocol decoder supplies a preset name, including `auto', `custom'
and host-defined names.  Empty or absent values leave the segment as it
was.  The selectable catalog is independent of this current value.
Only the session's live chat buffer is touched."
  (when-let* (((and current (hash-table-p dsh-emacs--chat-buffers)))
              (buf (gethash session-id dsh-emacs--chat-buffers))
              ((buffer-live-p buf)))
    (with-current-buffer buf
      (dsh-emacs-modeline-set-permission current))))

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
      (let ((seq (dsh-protocol-event-sequence--from-alist event)))
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
`dsh-emacs-events--host-dispatch'.  Otherwise the message belongs to one of
the chat connection's logical `/api/remote.mux' streams: `session/follow'
(see `dsh-emacs-events--dispatch-follow') or any stream a feature module
opened through `dsh-emacs-events-open-stream' (e.g. the `job' namespace
streams), each routed by its own `streamId' to the handler registered for
it.  A message without a `streamId' is not a frame the protocol sends and
is dropped."
  (condition-case err
      (if (and (processp process)
               (process-get process 'dsh-emacs-host-stream))
          (dsh-emacs-events--host-dispatch process json)
        (let ((frame (dsh-protocol-mux-frame--from-alist
                      (condition-case nil (dsh-protocol-read-json json)
                        (error nil)))))
          (when (dsh-protocol-mux-frame-stream-id frame)
            (dsh-emacs-events--dispatch-stream process frame))))
    (error (message "dsh event decode error: %S" err))))

(defun dsh-emacs-events--dispatch-stream (process frame)
  "Route one decoded chat-socket mux FRAME on PROCESS.
The frame is either this connection's `session/follow' stream or a
stream opened through `dsh-emacs-events-open-stream'; both share the
`item'/`error'/`end' envelope, so the routing decision is only *which*
handler owns its stream id."
  (let ((stream-id (dsh-protocol-mux-frame-stream-id frame)))
    (if (equal stream-id (process-get process 'dsh-emacs-follow-stream-id))
        (dsh-emacs-events--dispatch-follow process frame)
      (let* ((entry (assoc stream-id
                          (process-get process 'dsh-emacs-stream-handlers)))
             (handler (cddr entry)))
        (when (functionp handler)
          (pcase (dsh-protocol-mux-frame-type frame)
            ("item" (funcall handler (dsh-protocol-mux-frame-value frame)))
            ("error"
             (message "dsh %s stream error: %S" (car entry)
                      (dsh-protocol-mux-frame-error frame)))
            ("end" (dsh-emacs-events-close-stream process stream-id))))))))

(defun dsh-emacs-events-open-stream (process endpoint args name handler)
  "Open a logical Remote stream ENDPOINT on PROCESS and route it to HANDLER.
ARGS is the content of the wire `args' object (an alist, or nil).  NAME
labels the stream in error messages.  HANDLER is called with each `item'
frame's `value'; on the server's `end' (or on
`dsh-emacs-events-close-stream') it is called once with nil so the owner
can retire its state, and the registration is dropped.

Returns the fresh stream id, or nil when PROCESS is not live — a caller
must treat nil as \"could not subscribe\" rather than assume frames will
arrive.  The stream is cancelled automatically when the socket drops,
because the registration lives on the process."
  (when (process-live-p process)
    (let ((stream-id (dsh-emacs-events--stream-id)))
      (process-put process 'dsh-emacs-stream-handlers
                   (cons (cons stream-id (cons name handler))
                         (process-get process 'dsh-emacs-stream-handlers)))
      (process-send-string
       process
       (dsh-emacs-events--frame
        1 (dsh-protocol-mux-open-json stream-id endpoint args)))
      stream-id)))

(defun dsh-emacs-events-close-stream (process stream-id)
  "Cancel STREAM-ID on PROCESS and retire its handler.
Sends the `cancel' uplink (so the host stops producing frames) and calls
the handler once with nil, which is the same signal a server `end' gives.
Safe on an unknown STREAM-ID or a dead PROCESS."
  (when (and (processp process) (process-live-p process))
    (process-send-string
     process
     (dsh-emacs-events--frame 1 (dsh-protocol-mux-cancel-json stream-id))))
  (when (processp process)
    (let* ((handlers (process-get process 'dsh-emacs-stream-handlers))
           (entry (assoc stream-id handlers))
           (handler (cddr entry)))
      (when entry
        ;; `assq-delete-all' is not reliable here (observed leaving the entry
        ;; in place on Emacs 30), so filter explicitly by the same `equal'
        ;; the lookup above used.
        (process-put process 'dsh-emacs-stream-handlers
                     (cl-remove-if (lambda (e) (equal (car e) stream-id))
                                   handlers))
        (when (functionp handler) (funcall handler nil))))))

(defun dsh-emacs-events--close-streams (process)
  "Retire every custom stream registered on PROCESS.
Called from the socket teardown path: the server drops all logical
streams with the connection, so each handler is told once (nil) to drop
whatever it mirrored."
  (when (processp process)
    (let ((handlers (process-get process 'dsh-emacs-stream-handlers)))
      (process-put process 'dsh-emacs-stream-handlers nil)
      (dolist (entry handlers)
        (let ((handler (cddr entry)))
          (when (functionp handler) (funcall handler nil)))))))

(defun dsh-emacs-events--follow-open (process)
  "Send the `session/follow' open frame for PROCESS's chat stream.
The follow endpoint needs the session the chat buffer is attached to
(process property `dsh-emacs-follow-session', set at connect).  No-op for
connections without a session (the core list connection opens
`session/control' + `workspace/follow' + `$events' instead).

`assistantStream: true' opts into the process-local `assistant-stream'
frames (dsh 0.1.5).  They are the only incremental text source left:
`assistant/chunk' is no longer a durable Session event, so without the
opt-in a reply would appear only once its `assistant/message' settles.
The opening snapshot replaces the local revision and attempt baseline."
  (let ((session-id (process-get process 'dsh-emacs-follow-session)))
    (when (and session-id (process-live-p process))
      (let* ((stream-id (or (process-get process 'dsh-emacs-follow-stream-id)
                            (let ((id (dsh-emacs-events--stream-id)))
                              (process-put process 'dsh-emacs-follow-stream-id id)
                              id)))
             (chat (dsh-emacs-events--chat process))
             (json (dsh-protocol-mux-open-json
                    stream-id "session/follow"
                    (dsh-protocol-session-follow-request
                     session-id (process-get process 'dsh-emacs-follow-address)
                     (bound-and-true-p dsh-emacs-history-window) 1))))
        (when (buffer-live-p chat)
          (with-current-buffer chat
            (setq dsh-emacs--assistant-stream-revision nil
                  dsh-emacs--assistant-stream-attempt nil)))
        (process-send-string process (dsh-emacs-events--frame 1 json))))))

(defun dsh-emacs-events--dispatch-follow (process frame)
  "Dispatch one decoded `session/follow' mux FRAME on PROCESS.
Only messages for the stream this connection opened (process property
`dsh-emacs-follow-stream-id') are consumed: `item' frames carry the
snapshot/event values, `error' and `end' close the stream and reconnect."
  (when (equal (dsh-protocol-mux-frame-stream-id frame)
               (process-get process 'dsh-emacs-follow-stream-id))
    (pcase (dsh-protocol-mux-frame-type frame)
      ("item"
       (let ((chat (dsh-emacs-events--chat process)))
         (when (buffer-live-p chat)
           (dsh-emacs-events--follow-item
            chat (dsh-protocol-mux-frame-value frame)))))
      ("error"
       (message "dsh follow stream error: %S"
                (dsh-protocol-mux-frame-error frame))
       (dsh-emacs-events--lost process))
      ("end"
       ;; The server closed the stream: reconnect so a fresh follow
       ;; snapshot reseeds the transcript (the seq anchor dedups).
       (dsh-emacs-events--lost process)))))

(defun dsh-emacs-events--follow-item (chat value)
  "Consume one `session/follow' item VALUE on the stream of CHAT.
`snapshot' frames seed the transcript; `event' frames feed the live
event path; `assistant-stream' frames carry the process-local token
deltas that used to arrive as `assistant/chunk' events.
VALUE may already be a decoded `dsh-protocol-follow-item'."
  (when (buffer-live-p chat)
    (pcase-let* (((cl-struct dsh-protocol-follow-item type payload)
                  (dsh-protocol--struct #'dsh-protocol-follow-item-p
                                        #'dsh-protocol-follow-item--from-alist
                                        value)))
      (pcase type
        ("snapshot" (dsh-emacs-events--follow-snapshot chat payload))
        ("event" (dsh-emacs-events--follow-event chat payload))
        ("assistant-stream"
         (dsh-emacs-events--assistant-stream-frame chat payload))))))

(defun dsh-emacs-events--follow-rebaseline ()
  "Replace this chat's logical follow stream after a presentation gap.
Retire the stream id before reopening so queued frames from the old stream
cannot affect the replacement snapshot. Keep the socket and durable anchor."
  (let ((process dsh-emacs--event-process))
    (when (and (process-live-p process)
               (process-get process 'dsh-emacs-follow-session))
      (let ((old (process-get process 'dsh-emacs-follow-stream-id)))
        (when old
          (process-send-string
           process (dsh-emacs-events--frame
                    1 (dsh-protocol-mux-cancel-json old)))))
      (process-put process 'dsh-emacs-follow-stream-id
                   (dsh-emacs-events--stream-id))
      (dsh-emacs-modeline-reset-execution)
      (dsh-emacs-events--follow-open process))))

(defun dsh-emacs-events--assistant-stream-render-chunk (chat chunk)
  "Render raw CHUNK as live assistant output in CHAT.
CHUNK is exactly the payload a durable `assistant/chunk' event used to carry,
so the durable envelope is rebuilt around it and the ordinary event path —
and therefore the ordinary incremental renderer — does the work."
  (let ((position (plist-get dsh-emacs--assistant-stream-attempt :position)))
    (when (and position (listp chunk))
      (dsh-emacs-events--dispatch-event
       chat
       `((type . "assistant/chunk")
         (data . ((turn . ,(car position))
                  (step . ,(cdr position))
                  (chunk . ,chunk))))))))

(defun dsh-emacs-events--assistant-stream-frame (chat frame)
  "Render one assistant-stream FRAME for CHAT.
FRAME is `start' / `chunk' / `end' (dsh 0.1.5).  Frames are process-local
presentation state, not durable events: they carry no `seq', so they bypass
the seq gate and never advance `dsh-emacs--anchor-seq'. Keep the attempt id,
turn/step and next frame index from start or the opening baseline. A gap
requests a fresh baseline instead of publishing an incomplete body.
FRAME may already be a decoded `dsh-protocol-assistant-frame'."
  (when (buffer-live-p chat)
    (with-current-buffer chat
      (let* ((frame (dsh-protocol--struct
                     #'dsh-protocol-assistant-frame-p
                     #'dsh-protocol-assistant-frame--from-alist frame))
             (type (dsh-protocol-assistant-frame-type frame))
             (revision (dsh-protocol-assistant-frame-revision frame))
             (id (dsh-protocol-assistant-frame-attempt-id frame))
             (attempt dsh-emacs--assistant-stream-attempt))
        ;; An attached Agent can restart its counter without reconnecting.
        ;; Revision 1 is emitted once per Agent lifecycle, so it is a reset
        ;; whenever the watermark has already advanced past it; the attempt
        ;; id cannot stand in for that (ids restart per lifecycle too).
        (when (and (equal type "start") (equal revision 1)
                   (integerp dsh-emacs--assistant-stream-revision)
                   (> dsh-emacs--assistant-stream-revision 1))
          (dsh-emacs-render--discard-stream)
          (setq dsh-emacs--assistant-stream-revision nil
                dsh-emacs--assistant-stream-attempt nil
                attempt nil))
        (when (and (integerp revision)
                   (or (null dsh-emacs--assistant-stream-revision)
                       (> revision dsh-emacs--assistant-stream-revision)))
          (if (or (and dsh-emacs--assistant-stream-revision
                       (/= revision
                           (1+ dsh-emacs--assistant-stream-revision)))
                  (if (equal type "start")
                      (or attempt (not (stringp id))
                          (not (integerp
                                (dsh-protocol-assistant-frame-turn frame)))
                          (not (integerp
                                (dsh-protocol-assistant-frame-step frame))))
                    (or (null attempt)
                        (not (equal id (plist-get attempt :id)))
                        (not (equal (dsh-protocol-assistant-frame-index frame)
                                    (plist-get attempt :next-index))))))
              (dsh-emacs-events--follow-rebaseline)
            (setq dsh-emacs--assistant-stream-revision revision)
            (pcase type
              ("start"
               (setq dsh-emacs--assistant-stream-attempt
                     (list :id id :next-index 0
                           :position
                           (cons (dsh-protocol-assistant-frame-turn frame)
                                 (dsh-protocol-assistant-frame-step frame)))))
              ("chunk"
               (cl-incf (plist-get attempt :next-index))
               (dsh-emacs-events--assistant-stream-render-chunk
                chat (dsh-protocol-assistant-frame-chunk frame)))
              ("end"
               ;; A committed attempt settles through its durable
               ;; `assistant/message' / `assistant/attempt' (which finishes or
               ;; takes over the live body); an abandoned one has no such event,
               ;; so publish what arrived.
               (when (equal (dsh-protocol-assistant-frame-outcome-kind frame)
                            "abandoned")
                 (dsh-emacs-render--flush-stream (current-buffer) t))
               (setq dsh-emacs--assistant-stream-attempt nil))
              (_ nil))))))))

(defun dsh-emacs-events--follow-event (chat event)
  "Handle one live follow EVENT for CHAT.
`session/title' events update the session cache and buffer name for any
session; transcript events render into CHAT's own buffer."
  (when (and (buffer-live-p chat) (listp event))
    (let ((session-id (with-current-buffer chat
                        dsh-emacs--buffer-session)))
      (when-let* ((update (dsh-protocol-session-title--from-alist event)))
        (let ((title (dsh-protocol-session-title-title update)))
          (dsh-emacs-events--apply-title chat session-id title)
          (dsh-emacs-events--host-frame-record
           (list :apply-title session-id title))))
      (dsh-emacs-events--dispatch-event chat event))))

(defun dsh-emacs-events--follow-snapshot (chat value)
  "Seed CHAT's transcript from a `session/follow' snapshot VALUE.
Renders the message-aligned `records' tail (each record is one durable
event; there is no packed-row form any more) — then advances
`dsh-emacs--anchor-seq' to the snapshot CURSOR, replays any mid-attempt
`assistantStream' baseline so a reconnect continues the live body, and
decodes and applies the remaining snapshot projections.  The snapshot is the
opening history tail; no separate history fetch precedes the connect.  On
first open, bounded backward pages complete only the latest round after
applying the snapshot, without moving point.  Live follow stays connected;
rendering a long completed range can still block the main thread.
VALUE may already be a decoded `dsh-protocol-follow-snapshot'."
  (when (buffer-live-p chat)
    (with-current-buffer chat
      (pcase-let* (((cl-struct dsh-protocol-follow-snapshot
                              cursor (records entries) has-more
                              human-round-count
                              execution plan (assistant baseline) projections)
                   (dsh-protocol--struct
                    #'dsh-protocol-follow-snapshot-p
                    #'dsh-protocol-follow-snapshot--from-alist value))
                  (initial (null dsh-emacs--history-earliest-seq))
                  (session-id dsh-emacs--buffer-session)
                  (model-slot (cons session-id nil))
                  (dsh-emacs-events--snapshot-model-slots
                   (cons model-slot dsh-emacs-events--snapshot-model-slots)))
        ;; A snapshot replaces transient output with its durable window
        ;; and active prefix; it must not append onto the disconnected
        ;; socket's partial text or folded Think fragments.
        (dsh-emacs-render--discard-stream)
        (setq dsh-emacs--assistant-stream-attempt nil)
        ;; Fold the whole window before rendering can yield to newer events.
        ;; This includes starts below the transcript anchor; absent starts
        ;; leave an operation unknown rather than retaining stale feedback.
        (dsh-emacs-modeline-reset-execution execution)
        ;; Plan is projection-owned and must be seeded before history can
        ;; yield to a newer control increment.  History never folds Plan.
        (dsh-emacs-modeline-set-plan plan)
        (when entries
          (dsh-emacs-render-history-events entries nil)
          (dsh-emacs--seed-input-history entries session-id))
        ;; Record what the tail covers so `dsh-emacs-load-older-history' can
        ;; page backwards from it (and knows whether anything is left).  The
        ;; snapshot cursor is kept too: it is the `throughSeq' a backward page
        ;; needs (the wire's `-1' would read an empty page).
        (dsh-emacs-render--note-history-window entries has-more)
        (when (integerp cursor)
          (setq dsh-emacs--history-cursor cursor)
          (setq dsh-emacs--anchor-seq
                (max (or dsh-emacs--anchor-seq 0) cursor)))
        ;; A reconnect opening can land mid-attempt: replay the accumulated
        ;; process-local stream so the live body continues instead of starting
        ;; empty.  These frames are presentation state, so the anchor must not
        ;; move (and the records carry no seq to move it with).
        (let* ((id (dsh-protocol-assistant-baseline-attempt-id baseline))
               (turn (dsh-protocol-assistant-baseline-turn baseline))
               (step (dsh-protocol-assistant-baseline-step baseline))
               (next (dsh-protocol-assistant-baseline-next-index baseline)))
          (setq dsh-emacs--assistant-stream-revision
                (dsh-protocol-assistant-baseline-revision baseline))
          (when (and (stringp id) (integerp turn) (integerp step)
                     (integerp next) (>= next 0))
            (setq dsh-emacs--assistant-stream-attempt
                  (list :id id :position (cons turn step) :next-index next))
            (dolist (record (dsh-protocol-assistant-baseline-stream baseline))
              (pcase (dsh-protocol-assistant-record-type record)
                ("chunk"
                 (dsh-emacs-events--assistant-stream-render-chunk
                  chat (dsh-protocol-assistant-record-chunk record)))
                ((and type (or "text-chunks" "reasoning-chunks"))
                 (dolist (text (dsh-protocol-assistant-record-texts record))
                   (dsh-emacs-events--assistant-stream-render-chunk
                    chat `((type . ,(if (equal type "text-chunks")
                                        "text-delta" "reasoning-delta"))
                           (index . ,(dsh-protocol-assistant-record-index
                                      record))
                           (text . ,text)))))))))
        (dsh-emacs-events--apply-snapshot-projections
         session-id projections)
        (when (markerp dsh-emacs--subagent-departure)
          (xref-push-marker-stack dsh-emacs--subagent-departure)
          (setq dsh-emacs--subagent-departure nil))
        (setq dsh-emacs--ws-last-event-time (float-time))
        ;; Complete only the latest human round on opening.  A snapshot that
        ;; starts at a child/goal wake has no user prompt, so it backs up to
        ;; the preceding human round.  The manual pagination target must not
        ;; multiply automatic work for long rounds.  Reconnects must not
        ;; restart a canceled load or extend a browsed transcript.
        (when (and initial entries has-more (integerp cursor)
                   (zerop human-round-count))
          (dsh-emacs-history--start-load 1))))))

(defun dsh-emacs-events--apply-snapshot-projections (session-id projections)
  "Apply decoded follow PROJECTIONS after history and the assistant prefix.
Raw baseline fixtures enter through the protocol gate here, so a migration
error cannot prevent history from rendering.  Plan is seeded earlier, before
history can yield to newer updates; questions settle the cards just rendered
in the current chat.  Inbox is owned by the control stream."
  (pcase-let (((cl-struct dsh-protocol-follow-projections
                         subagents title context permission
                         goal goal-update-p questions model-selection)
               (dsh-protocol--struct
                #'dsh-protocol-follow-projections-p
                #'dsh-protocol-follow-projections--from-alist projections)))
    (dsh-emacs-subagent-apply session-id subagents)
    (dsh-emacs-subagent--sync-animation)
    (when (and title (not (string-empty-p title)))
      (dsh-emacs-events--apply-title nil session-id title)
      (dsh-emacs-events--host-frame-record (list :apply-title session-id title)))
    (when context
      (dsh-emacs--events-apply-context-projection session-id context))
    (when permission
      (dsh-emacs--events-apply-permission-projection session-id permission))
    (dsh-emacs-events--apply-model-projection
     session-id (or (cdr (assoc session-id dsh-emacs-events--snapshot-model-slots))
                    model-selection))
    (when goal-update-p
      (dsh-emacs-events--apply-goal-projection session-id goal))
    (when questions
      (dsh-emacs--session-questions-apply questions))))

(defconst dsh-emacs-events--dispatch-budget 0.01
  "Maximum seconds of business-message dispatch before yielding to Emacs.
A single message is atomic and may exceed this budget.")

(defvar dsh-emacs-events--dispatching nil
  "Non-nil while the WebSocket dispatcher runs a batch of business messages.
Waterfall prompts check this so they open outside the dispatcher: a reader
started here would keep the dispatcher from consuming the host's `cancel'
frame (sent when another client answers) until the local user acted.")

(defun dsh-emacs-events--cancel-dispatch (process)
  "Cancel queued business messages and continuation for PROCESS."
  (when (processp process)
    (when-let* ((timer (process-get process 'dsh-emacs-event-dispatch-timer)))
      (cancel-timer timer))
    (process-put process 'dsh-emacs-event-dispatch-timer nil)
    (process-put process 'dsh-emacs-event-messages nil)))

(defun dsh-emacs-events--resume-dispatch (process)
  "Resume queued business messages for a still-live PROCESS."
  (when-let* ((timer (process-get process 'dsh-emacs-event-dispatch-timer)))
    (cancel-timer timer))
  (process-put process 'dsh-emacs-event-dispatch-timer nil)
  (if (and (process-live-p process)
           (buffer-live-p (process-buffer process)))
      (with-current-buffer (process-buffer process)
        (dsh-emacs-events--dispatch-pending process))
    (dsh-emacs-events--cancel-dispatch process)))

(defun dsh-emacs-events--dispatch-pending (process)
  "Dispatch a bounded batch of PROCESS's messages in wire order.
Reentrant filters may enqueue messages and answer Pings, but only this
consumer dispatches business messages.  Keep an already-pending timer's
deadline when more input arrives."
  (unless (or (process-get process 'dsh-emacs-event-draining)
              (process-get process 'dsh-emacs-event-dispatch-timer))
    (let ((dsh-emacs-events--dispatching t)
          (deadline (+ (float-time) dsh-emacs-events--dispatch-budget)))
      (process-put process 'dsh-emacs-event-draining t)
      (unwind-protect
          (condition-case err
              (let (queue)
                (while (and (< (float-time) deadline)
                            (setq queue
                                  (process-get process
                                               'dsh-emacs-event-messages)))
                  ;; Remove the message before dispatch can reenter the filter.
                  (process-put process 'dsh-emacs-event-messages (cdr queue))
                  (if (= (caar queue) 8)
                      (progn
                        (dsh-emacs-events--cancel-dispatch process)
                        (delete-process process))
                    (dsh-emacs-events--dispatch-json process (cdar queue)))))
            (error
             (if (process-live-p process)
                 (message "dsh WebSocket frame error: %S" err)
               (dsh-emacs-events--lost process))))
        (process-put process 'dsh-emacs-event-draining nil)
        (when (and (process-live-p process)
                   (buffer-live-p (process-buffer process))
                   (process-get process 'dsh-emacs-event-messages))
          (process-put process 'dsh-emacs-event-dispatch-timer
                       (run-at-time 0.001 nil
                                    #'dsh-emacs-events--resume-dispatch
                                    process)))))))

(defun dsh-emacs-events--consume-frames (process)
  "Decode buffered WebSocket frames, then dispatch a bounded message batch.
Answer control Pings before rendering business messages, so a busy chat
cannot hold its own connection's heartbeat behind a rendering backlog."
  (unless (process-get process 'dsh-emacs-event-parsing)
    (let ((offset 0) messages)
      (process-put process 'dsh-emacs-event-parsing t)
      (unwind-protect
          (condition-case err
              (let (input frame)
                (while (and (setq input (process-get process 'dsh-emacs-event-input))
                            (setq frame (dsh-emacs-events--read-frame input offset)))
                  (setq offset (nth 3 frame))
                  (let ((opcode (nth 0 frame))
                        (fin (nth 1 frame))
                        (payload (nth 2 frame)))
                    (cond
                     ((= opcode 9) (dsh-emacs-events--send-pong process payload))
                     ((= opcode 10)
                      (let ((chat (dsh-emacs-events--chat process)))
                        (when (buffer-live-p chat)
                          (with-current-buffer chat
                            (when (and (eq process dsh-emacs--event-process)
                                       (equal payload dsh-emacs--ws-probe-inflight))
                              (setq dsh-emacs--ws-probe-inflight nil))))))
                     ;; Close follows preceding messages; it must not discard
                     ;; business messages already accepted from the wire.
                     ((= opcode 8) (push (cons 8 nil) messages))
                     ((or (= opcode 1) (= opcode 0))
                      (let ((fragment
                             (cons payload
                                   (unless (= opcode 1)
                                     (process-get process 'dsh-emacs-event-fragment)))))
                        (if fin
                            (progn
                              (process-put process 'dsh-emacs-event-fragment nil)
                              (push (cons 1 (decode-coding-string
                                             (apply #'concat (nreverse fragment)) 'utf-8))
                                    messages))
                          (process-put process 'dsh-emacs-event-fragment fragment))))))))
            (error
             (if (process-live-p process)
                 (message "dsh WebSocket frame error: %S" err)
               (dsh-emacs-events--lost process))))
        (process-put process 'dsh-emacs-event-input
                     (substring (or (process-get process 'dsh-emacs-event-input) "")
                                offset))
        (process-put process 'dsh-emacs-event-messages
                     (nconc (process-get process 'dsh-emacs-event-messages)
                            (nreverse messages)))
        (process-put process 'dsh-emacs-event-parsing nil)))
    (dsh-emacs-events--dispatch-pending process)))

(defconst dsh-emacs-events--read-batch-interval 0.05
  "Seconds to accumulate chat socket input between reads.
Kept aligned with `dsh-emacs-render--stream-batch-interval'.")

(defun dsh-emacs-events--cancel-read-timer (process)
  "Cancel PROCESS's pending socket-read resume and clear its saved filter."
  (when (processp process)
    (when-let* ((timer (process-get process 'dsh-emacs-event-read-timer)))
      (cancel-timer timer))
    (process-put process 'dsh-emacs-event-read-timer nil)
    (process-put process 'dsh-emacs-event-read-filter nil)))

(defun dsh-emacs-events--resume-reads (process)
  "Resume PROCESS after a short burst of chat input.
No repeating timer is needed: a quiet socket stays normally readable."
  (when (process-get process 'dsh-emacs-event-read-timer)
    (let ((filter (process-get process 'dsh-emacs-event-read-filter)))
      (dsh-emacs-events--cancel-read-timer process)
      (when (and (process-live-p process)
                 (buffer-live-p (process-buffer process))
                 (eq (process-filter process) t))
        (set-process-filter process filter)))))

(defun dsh-emacs-events--filter (process string)
  "Process raw HTTP/WebSocket STRING received by PROCESS."
  (when (buffer-live-p (process-buffer process))
    ;; Each process read can make Emacs redisplay, even when the renderer
    ;; merely queues text.  Let the socket accumulate the next 50ms of bytes
    ;; instead.  A filter of t suspends reads without dropping data or
    ;; changing connection status; the first received bytes still run below.
    ;; Keep the handshake and the host's question/approval channel immediate.
    (when (and (process-live-p process)
               (process-get process 'dsh-emacs-event-ready)
               (not (process-get process 'dsh-emacs-host-stream))
               (not (process-get process 'dsh-emacs-event-read-timer)))
      (process-put process 'dsh-emacs-event-read-timer
                   (run-at-time dsh-emacs-events--read-batch-interval nil
                                #'dsh-emacs-events--resume-reads process))
      (process-put process 'dsh-emacs-event-read-filter (process-filter process))
      (set-process-filter process t))
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
                        (dsh-emacs-events--follow-open process)
                        ;; Feature streams (the `job' namespace roster)
                        ;; are per-connection too: re-open them on the
                        ;; replacement socket after a reconnect.
                        (dsh-emacs-jobs-reopen chat)))
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
  (dsh-emacs-events--cancel-dispatch process)
  (dsh-emacs-events--cancel-read-timer process)
  (if (process-get process 'dsh-emacs-host-stream)
      (dsh-emacs-events--host-lost process)
    (let ((chat (dsh-emacs-events--chat process)))
      (when (and (buffer-live-p chat)
                 (eq process (with-current-buffer chat dsh-emacs--event-process)))
        (with-current-buffer chat
          (setq dsh-emacs--event-process nil
                dsh-emacs--event-ready nil)
          (dsh-emacs-subagent--sync-animation)
          (dsh-emacs-modeline-reset-execution)
          ;; The connection carried every logical stream; tell each feature
          ;; handler its stream is gone so no mirror outlives it.
          (dsh-emacs-events--close-streams process)
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
  "Probe BUFFER's quiet WebSocket while a turn runs.
After three seconds without business events, send a ping.  Only an
unanswered ping times out the connection; a slow model or tool may stay
silent indefinitely while its transport continues to answer pings."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (and (bound-and-true-p dsh-emacs--ml-busy)
               dsh-emacs--event-ready
               (process-live-p dsh-emacs--event-process))
          (let ((now (float-time)))
            (cond
             (dsh-emacs--ws-probe-inflight
              (when (> (- now dsh-emacs--ws-last-probe-time) 3.0)
                (delete-process dsh-emacs--event-process)))
             ((and (> (- now (or dsh-emacs--ws-last-event-time 0)) 3.0)
                   (> (- now (or dsh-emacs--ws-last-probe-time 0)) 3.0))
              (setq dsh-emacs--ws-probe-inflight (format "dsh-%s" now)
                    dsh-emacs--ws-last-probe-time now)
              (let ((process dsh-emacs--event-process)
                    (frame (dsh-emacs-events--frame
                            9 dsh-emacs--ws-probe-inflight)))
                (condition-case err
                    (process-send-string process frame)
                  (error
                   (message "dsh: event stream probe failed: %S" err)
                   ;; A live check cannot predict a failed socket write.  The
                   ;; send may already have closed it, with its sentinel pending.
                   (when (process-live-p process)
                     (delete-process process))
                   (dsh-emacs-events--lost process)))))))
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
      (let* ((session (and dsh-emacs--buffer-session
                           (dsh-emacs--chat-session-item
                            dsh-emacs--buffer-session)))
             (was-busy (or (bound-and-true-p dsh-emacs--ml-busy)
                           (and (zerop (or dsh-emacs--anchor-seq 0))
                                session
                                (dsh-protocol-session-running session))))
             (run-start (and was-busy dsh-emacs--modeline-run-start))
             (process nil))
        (dsh-emacs-events-disconnect chat)
        ;; Teardown clears busy, but a failed connection is not a turn end.
        ;; Restore before opening the socket so every retry retains liveness;
        ;; a bounded snapshot after compaction may omit the original start.
        ;; Only fresh transcripts seed from the host cache (above): an old
        ;; cached running flag must never undo an already consumed turn/end.
        (when was-busy
          ;; Reconnecting the stream does not start a new turn.  Restore the
          ;; clock before busy-set synchronizes the animation timer.
          (setq dsh-emacs--modeline-run-start run-start)
          (dsh-emacs--ml-busy-set t))
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
               (process-put process 'dsh-emacs-follow-address
                            dsh-emacs--buffer-subagent)
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
              (dsh-emacs-events--health-start))
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
        (dsh-emacs-render--flush-stream nil t)
        (when (timerp dsh-emacs--event-reconnect-timer)
          (cancel-timer dsh-emacs--event-reconnect-timer))
        (dsh-emacs-events--health-stop)
        (setq dsh-emacs--event-reconnect-timer nil)
        (dsh-emacs-events--watchdog-stop)
        (let ((process dsh-emacs--event-process))
          (dsh-emacs-events--cancel-read-timer process)
          (dsh-emacs-events--cancel-dispatch process)
          ;; Clear ownership before deleting: the sentinel must not schedule a
          ;; reconnect for an intentional session switch or buffer teardown.
          (setq dsh-emacs--event-process nil
                dsh-emacs--event-ready nil)
          (dsh-emacs-events--close-streams process)
          (when (process-live-p process)
            (delete-process process)))
        ;; Tearing down the stream: stop the mode-line running spinner so it
        ;; never keeps ticking in a detached conversation.
        (dsh-emacs--ml-busy-clear)))))

;;; ---------------------------------------------------------------------------
;;; Core connection (`session/control' + `workspace/follow' + `$events')
;;; --- workspace/session/archive changes
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-events--host-repaint ()
  "Repaint the session list buffer, if it is live.
Gated on the session list having been read: a repaint driven by workspace
frames arriving before the first `session/list' response would render
every group with its \"New Session\" row and a zero count, then be
replaced once the rows landed — the groups flashed in while the sessions
waited for the round trip.  Until the list is read the window keeps the
empty state, and the fetch paints groups and rows together.  An empty
host paints its empty state from `dsh-emacs-list-sessions-display' and
the fetch's own drain, which are not gated."
  (when (and (not dsh-emacs-events--defer-host-repaint)
             (consp dsh-emacs--sessions)
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

(defun dsh-emacs-events--host-replay-frame (frame)
  "Apply one recorded refresh FRAME to the caches.
FRAME is a handler description recorded by
`dsh-emacs-events--host-frame-record'.  The incremental mutations do not
repaint themselves here; the drain batches them and repaints once."
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
    (:session-activity
     (dsh-emacs-events--host-session-activity
      (cadr frame) (car (cddr frame))))
    (:apply-model-selection
     (dsh-emacs-events--apply-model-projection
      (cadr frame) (car (cddr frame))))
    (:apply-title
     (dsh-emacs-events--apply-title
      nil (cadr frame) (car (cddr frame))))))

(defun dsh-emacs-events--host-refresh-drain ()
  "End a refresh span; when the last one ends, replay recorded frames.
The replay is batched: the recorded frames mutate the caches with the
repaint deferred, then the list is repainted once.  A `session/control'
baseline that lands mid-refresh records one `:apply-title' frame per
session (hundreds on a large host), and repainting per frame is what made
the first open block for seconds before any row appeared."
  (when (> dsh-emacs--host-refresh-depth 0)
    (setq dsh-emacs--host-refresh-depth
          (1- dsh-emacs--host-refresh-depth)))
  (when (= dsh-emacs--host-refresh-depth 0)
    ;; Defer repaints for the whole replay: a `session/control' baseline that
    ;; lands mid-refresh records one `:apply-title' frame per session, and
    ;; repainting per frame is what made the first open block for seconds.
    ;; The flag is cleared before the trailing repaint so the batched result
    ;; actually reaches the list, and a caller's own defer state (a control
    ;; baseline may already be deferring) is restored either way.
    (let* ((deferred dsh-emacs-events--defer-host-repaint)
           (frames (nreverse dsh-emacs--host-refresh-frames))
           (dsh-emacs-events--defer-host-repaint t))
      (setq dsh-emacs--host-refresh-frames nil)
      (dolist (frame frames)
        (dsh-emacs-events--host-replay-frame frame))
      (setq dsh-emacs-events--defer-host-repaint deferred)
      (dsh-emacs-events--host-repaint))))

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
  "Merge live facts from SUMMARY without replacing newer projection cells."
  (let* ((incoming (dsh-protocol-session--from-alist summary))
         (id (dsh-protocol-session-session-id incoming))
         (existing (and id (dsh-emacs--chat-session-item id))))
    (when id
      (if existing
          (setf (dsh-protocol-session-running existing)
                (dsh-protocol-session-running incoming)
                (dsh-protocol-session-blank existing)
                (dsh-protocol-session-blank incoming)
                (dsh-protocol-session-agent-available existing)
                (dsh-protocol-session-agent-available incoming)
                (dsh-protocol-session-updated-at existing)
                (dsh-protocol-session-updated-at incoming))
        (push incoming dsh-emacs--sessions))
      (dsh-emacs-subagent-summary-changed id)
      (dsh-emacs-events--host-repaint))))

(defun dsh-emacs-events--host-session-removed (session-id)
  "Drop SESSION-ID from the cached session list."
  (setq dsh-emacs--sessions
        (cl-remove-if-not
         (lambda (s)
           (not (equal session-id
                       (dsh-protocol-session-session-id s))))
         dsh-emacs--sessions))
  (dsh-emacs-subagent-summary-changed session-id)
  (dsh-emacs-events--host-repaint))

(defun dsh-emacs-events--host-session-status (session-id running)
  "Set cached SESSION-ID's decoded RUNNING flag; repaint the list."
  (let ((item (dsh-emacs--chat-session-item session-id)))
    (when item
      (setf (dsh-protocol-session-running item) running)))
  (dsh-emacs-subagent-summary-changed session-id t)
  (dsh-emacs-events--host-repaint))

(defun dsh-emacs-events--host-dispatch (process json)
  "Route one decoded `/api/remote.mux' message from PROCESS.
The list-scoped core connection multiplexes the `session/control',
`workspace/follow' and `$events' logical streams.  Server frames arrive as
`item' (value = a control/workspace/$events logical frame), `error' or
`end'; the logical frame `type' routes to the shared caches and chat
buffers (see `dsh-emacs-events--host-item')."
  (condition-case err
      (let ((frame (dsh-protocol-mux-frame--from-alist
                    (condition-case nil (dsh-protocol-read-json json)
                      (error nil)))))
        (pcase (dsh-protocol-mux-frame-type frame)
          ("item" (dsh-emacs-events--host-item
                   process (dsh-protocol-mux-frame-value frame)))
          ("error"
           (message "dsh core stream error: %S"
                    (dsh-protocol-mux-frame-error frame)))
          ("end" (dsh-emacs-events--host-lost process))
          (_ nil)))
    (error (message "dsh core event decode error: %S" err))))

(defun dsh-emacs-events--host-item (process item)
  "Consume one logical core ITEM arriving on PROCESS.
`session/control' frames feed the queue mirrors (through the `inbox'
projection) and the other projections, `workspace/follow' frames mutate
the workspace caches, `$events' frames
carry the session list's live changes and the question/approval
waterfalls: `ready' captures the generation `clientId', `emit' delivers
`api-session/*' events, `waterfall' routes an approval/question request
to its chat buffer (auto-answering `next' when no live chat), and `cancel'
retires a pending waterfall by `eventId'."
  (pcase-let (((cl-struct dsh-protocol-core-item type (payload value))
               (dsh-protocol--struct #'dsh-protocol-core-item-p
                                     #'dsh-protocol-core-item--from-alist item)))
    (pcase type
      ("baseline"
       (if (dsh-protocol-workspace-list-p value)
           (dsh-emacs-events--host-workspace-baseline value)
         (dsh-emacs-events--host-control-baseline process value)))
      ("projection"
       (dsh-emacs-events--host-apply-projection process value))
      ("upsert"
       (when value
         (dsh-emacs-events--host-upsert-workspace value)
         (dsh-emacs-events--host-frame-record (list :upsert-workspace value))))
      ("remove"
       (dsh-emacs-events--host-remove-workspace value)
       (dsh-emacs-events--host-frame-record (list :remove-workspace value)))
      ("order"
       (dsh-emacs-events--host-reorder-workspaces value)
       (dsh-emacs-events--host-frame-record (list :reorder-workspaces value)))
      ("archived"
       (dsh-emacs-events--host-set-archived value)
       (dsh-emacs-events--host-frame-record (list :set-archived value)))
      ("ready"
       ;; $events ready: this generation's clientId.  Each reconnect yields a
       ;; new generation/clientId; the old generation's still-queued waterfalls
       ;; can no longer be answered meaningfully, so retire them.
       (when value
         (when (and dsh-emacs-events--client-id
                    (not (equal value dsh-emacs-events--client-id)))
           (dsh-emacs--waterfall-generation-retired))
         (setq dsh-emacs-events--client-id value)))
      ("emit"
       (pcase-let (((cl-struct dsh-protocol-session-notice
                               name session-id (value payload)) value))
         (pcase name
           ("api-session/added"
            (when (listp payload)
              (dsh-emacs-events--host-session-added payload)
              (dsh-emacs-events--host-frame-record
               (list :session-added payload))))
           ("api-session/removed"
            (dsh-emacs-events--host-session-removed session-id)
            (dsh-emacs-events--host-frame-record
             (list :session-removed session-id)))
           ("api-session/status"
            (when session-id
              (dsh-emacs-events--host-session-status session-id payload)
              (dsh-emacs-events--host-frame-record
               (list :session-status session-id payload))))
           ("api-session/activity"
            (when session-id
              (dsh-emacs-events--host-session-activity session-id payload)
              (dsh-emacs-events--host-frame-record
               (list :session-activity session-id payload))))
           (_ nil))))
      ("waterfall"
       ;; Approval / question waterfalls arrive on `$events' and are answered
       ;; via POST /api/$events/result (see `dsh-emacs--events-result-async' in
       ;; dsh-emacs.el).  Resolve the target before decoding the request.
       (pcase-let* (((cl-struct dsh-protocol-waterfall
                                (name event-name) event-id agent-id request) value)
                    (chat (and agent-id
                               (dsh-emacs-events--chat-buffer agent-id))))
         (if (not (and event-id (buffer-live-p chat)))
             ;; No open chat for the asking agent (or no event id): this client
             ;; is not the waterfall's claimant — hand it on so the host does
             ;; not wait on us.
             (when (and event-id dsh-emacs-events--client-id)
               (dsh-emacs--events-result-async
                dsh-emacs-events--client-id event-id
                (dsh-protocol-events-next-outcome)
                (lambda (_ok _value) nil)))
           (pcase event-name
             ("approval/request"
              (let ((approval (dsh-protocol-approval-request--from-alist request)))
                (dsh-emacs--approval-requested
                 chat event-id agent-id
                 (dsh-protocol-approval-request-tool-name approval)
                 (dsh-emacs--approval-display-reason approval)
                 (dsh-protocol-approval-request-call-id approval))))
             ("user-questions/request"
              (pcase-let (((cl-struct dsh-protocol-question-request questions wait)
                           (dsh-protocol-question-request--from-alist request)))
                (dsh-emacs--question-requested
                 chat event-id agent-id questions wait)))
             (_ nil)))))
      ("cancel"
       ;; Waterfall retirement: drop any still-queued question/approval frame
       ;; for EVENT-ID (replay of the same waterfall never re-asks it).
       (when value
         (dsh-emacs--question-cancelled value)
         (dsh-emacs--approval-cancelled value)))
      ;; Accepted no-op kinds (no UI consumes them yet): the `api-session/error'
      ;; emit and any other host frame type we do not render.  Background jobs
      ;; have no frame here at all since dsh 0.1.7 — they are the `job'
      ;; namespace's own streams (`dsh-emacs-jobs.el'); the 0.1.6
      ;; `session/control' `jobs' record is gone.  Intentionally dropped, not
      ;; wire-parity work — revisit when an error surface is added.
      (_ nil))))

(defun dsh-emacs-events--chat-buffer (session-id)
  "Live chat buffer of SESSION-ID, or nil."
  (and (hash-table-p dsh-emacs--chat-buffers)
       (gethash session-id dsh-emacs--chat-buffers)))

(defun dsh-emacs-events--host-workspace-baseline (baseline)
  "Seed workspace/archive caches from a decoded workspace BASELINE."
  (pcase-let (((cl-struct dsh-protocol-workspace-list items archived-session-ids)
               baseline))
    (setq dsh-emacs--workspaces items)
    (dsh-emacs-events--host-set-archived archived-session-ids)
    (dsh-emacs-events--host-repaint)))

(defun dsh-emacs-events--host-control-baseline (process value)
  "Seed the projection caches from a `session/control' baseline VALUE.
Decode and apply each session in wire order.  Subagent cells land as one
batch before Plan/questions and the remaining projections; repaint only
after every session has been applied."
  (let ((dsh-emacs-events--defer-host-repaint t))
    (when (and (processp process) (not dsh-emacs--subagent-host-live))
      (dsh-emacs-subagent-host-reset t))
    (dolist (entry (dsh-protocol-control-baseline--from-alist value))
      (pcase-let (((cl-struct dsh-protocol-control-session
                             session-id subagents projections)
                  (dsh-protocol-control-session--from-alist entry)))
        (dsh-emacs-subagent-apply session-id subagents)
        (dolist (projection projections)
          (dsh-emacs-events--host-apply-projection process projection)))))
  (dsh-emacs-events--host-repaint))

(defun dsh-emacs-events--host-apply-projection (process projection)
  "Apply a decoded control PROJECTION arriving on PROCESS.
Legacy fixtures may supply a wire update frame.  Buffer-local projections
only reach their session's live chat; other cells update the shared caches."
  (pcase-let (((cl-struct dsh-protocol-projection session-id key value)
               (dsh-protocol--struct
                #'dsh-protocol-projection-p
                #'dsh-protocol-projection--from-alist projection)))
    (when session-id
      (pcase key
        ((or "subagentCatalog" "subagent" "subagentTiming" "tokenUsage")
         (dsh-emacs-subagent-apply session-id (list value)))
        ("contextPressure"
         (dsh-emacs--events-apply-context-projection session-id value))
        ("permissions"
         (dsh-emacs--events-apply-permission-projection session-id value))
        ("modelSelection"
         (dsh-emacs-events--apply-model-projection session-id value)
         (when value
           (dolist (slot dsh-emacs-events--snapshot-model-slots)
             (when (equal session-id (car slot)) (setcdr slot value)))))
        ("goal"
         (dsh-emacs-events--apply-goal-projection session-id value))
        ("plan"
         (let ((chat (dsh-emacs-events--chat-buffer session-id)))
           (when (buffer-live-p chat)
             (with-current-buffer chat
               (dsh-emacs-modeline-set-plan value)))))
        ("inbox"
         (let ((chat (dsh-emacs-events--chat-buffer session-id)))
           (when (buffer-live-p chat)
             (dsh-emacs-queue-apply chat process value))))
        ("userQuestions"
         (let ((chat (dsh-emacs-events--chat-buffer session-id)))
           (when (buffer-live-p chat)
             (with-current-buffer chat
               (dsh-emacs--session-questions-apply value)))))
        ("title"
         (when (and value (not (string-empty-p value)))
           (dsh-emacs-events--apply-title nil session-id value)
           (dsh-emacs-events--host-frame-record
            (list :apply-title session-id value))))))))

(defun dsh-emacs-events--apply-goal-projection (session-id goal)
  "Apply decoded GOAL to SESSION-ID's live chat buffer.
Render the Composer Goal Row there (hidden when GOAL is nil).
Unlike the ctx/title consumers this touches only
the session's own chat buffer — the Goal Row is composer chrome, not list or
mode-line state."
  (when (and (boundp 'dsh-emacs--chat-buffers)
             (hash-table-p dsh-emacs--chat-buffers))
    (let ((buf (gethash session-id dsh-emacs--chat-buffers)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (dsh-emacs-composer-set-goal goal))))))

(defun dsh-emacs-events--host-session-activity (session-id updated-at)
  "Advance SESSION-ID's cached activity time to UPDATED-AT and repaint.
Ignore older or repeated timestamps, including refresh replay over a newer
snapshot.  UPDATED-AT is the host's timestamp in milliseconds."
  (let ((item (dsh-emacs--chat-session-item session-id)))
    (when (and item (> updated-at (or (dsh-protocol-session-updated-at item) 0)))
      (setf (dsh-protocol-session-updated-at item) updated-at)
      (setq dsh-emacs--sessions
            (cons item (delq item dsh-emacs--sessions)))
      (dsh-emacs-events--host-repaint))))

(defun dsh-emacs-events--host-lost (process)
  "Handle a closed host-stream PROCESS: reset and schedule reconnect."
  (dsh-emacs-events--cancel-dispatch process)
  (let ((buffer (process-get process 'dsh-emacs-host-buffer)))
    (when (and (buffer-live-p buffer)
               (eq process (with-current-buffer buffer
                             dsh-emacs--host-process)))
      (with-current-buffer buffer
        (setq dsh-emacs--host-process nil
              dsh-emacs--host-ready nil)
        (dsh-emacs-subagent-host-reset)
        (dsh-emacs-plan--cancel)
        (unless (timerp dsh-emacs--host-reconnect-timer)
          (setq dsh-emacs--host-reconnect-timer
                (run-at-time 1 nil
                             (lambda (buffer)
                               (when (buffer-live-p buffer)
                                 (with-current-buffer buffer
                                   (setq dsh-emacs--host-reconnect-timer nil)
                                   (dsh-emacs-events-host-connect))))
                             buffer)))))))

(defun dsh-emacs-events-host-connected-p ()
  "Non-nil when the current buffer's host stream is already live.
A live process covers a handshake still in flight: keeping it preserves the
work already done instead of starting the connect over."
  (and (boundp 'dsh-emacs--host-process)
       (process-live-p dsh-emacs--host-process)))

(defun dsh-emacs-events-host-connect ()
  "Connect BUFFER's core stream to dsh's `/api/remote.mux'.
The core connection is scoped to the session-list buffer (owned by
`dsh-emacs-session-mode'): it opens the `session/control',
`workspace/follow' and `$events' logical streams after the handshake
(`dsh-emacs-events--host-open') and repaints the list on workspace/
session/archive/queue/projection changes while the list is open;
everything tears down with the buffer.

Already connected is a no-op: the session-list mode re-runs on every open
(`dsh-emacs-list-sessions-display'), and re-opening a list that is already
live must not tear its streams down and handshake again.  A dropped
connection clears `dsh-emacs--host-process' first (see
`dsh-emacs-events--host-lost'), so the reconnect path still connects."
  (when (and (buffer-live-p (current-buffer))
             (not (dsh-emacs-events-host-connected-p)))
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
    ;; A new Host generation may replay a Session in a new sequence space.
    ;; Drop Plan/question cuts before its baselines and increments arrive.
    (maphash (lambda (_session-id chat)
               (when (buffer-live-p chat)
                 (with-current-buffer chat
                   (dsh-emacs-modeline-set-plan nil)
                   (dsh-emacs--session-questions-apply nil))))
             dsh-emacs--chat-buffers)
    (dolist (endpoint '("session/control" "workspace/follow" "$events"))
      (let* ((stream-id (dsh-emacs-events--stream-id))
             (json (dsh-protocol-mux-open-json stream-id endpoint nil)))
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
                 1 (dsh-protocol-mux-cancel-json old)))))
      (let* ((stream-id (dsh-emacs-events--stream-id))
             (json (dsh-protocol-mux-open-json
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
    (when process (dsh-emacs-subagent-host-reset))
    (dsh-emacs-plan--cancel)
    (when (process-live-p process)
      (delete-process process))))

(provide 'dsh-emacs-events)

;;; dsh-emacs-events.el ends here
