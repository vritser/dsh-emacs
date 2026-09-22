;;; dsh-emacs.el --- Main entry point for dsh-emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.4.1
;; Package-Requires: ((emacs "27.1"))
;; URL: https://github.com/vritser/dsh-emacs
;; License: GPL-3.0-or-later
;; Keywords: ai, tools, convenience

;;; Commentary:

;; dsh-emacs is a UI for using DeepSeek Harness inside Emacs.
;; It talks to a running dsh web service over HTTP in an Emacs-native way.
;;
;; Main features:
;; - Session list (card view)
;; - Chat buffer (with tool-call and reasoning folding)
;; - Mode-line stats (cwd, git branch, model, tokens, ctx%, cost)
;; - Markdown rendering
;;
;; Quick start:
;;   (require 'dsh-emacs)
;;   M-x dsh-emacs                    ; Open the session list
;;   M-x dsh-emacs-new-session        ; Create a new session
;;
;; Chat buffer keybindings:
;;   C-c C-c   Send (while running, queues/steers per
;;             `dsh-emacs-busy-enter-behavior'; empty input or a reversed
;;             `C-u' interrupts/steers)
;;   C-c C-b   Interrupt the current turn
;;   C-c C-q   Manage the pending queue (edit/steer/delete/send now)
;;   C-c C-r   Refresh
;;   C-c C-o   Load earlier history messages
;;   C-c C-l   Open the session list
;;   C-c C-w   Copy the transcript
;;
;; Session list keybindings:
;;   RET       Open a session
;;   c         Create a new session
;;   r         Rename
;;   D         Delete
;;   g         Refresh
;;   q         Quit

;;; Code:

(require 'json)
(require 'url)
(require 'cl-lib)
(declare-function x-show-tip "xfns.c"
                  (string &optional frame parms timeout dx dy))
(declare-function tooltip-hide "tooltip" (&optional ignored-arg))
(defvar tooltip-frame-parameters)
(defvar tooltip-hide-delay)
(defvar use-system-tooltips)
(defvar x-max-tooltip-size)
(declare-function icomplete-force-complete-and-exit "icomplete" ())
;; Emacs 31-only; the 27.1 baseline falls back to
;; `dsh-emacs--completion-table-with-metadata'.  The declaration only keeps
;; byte-compile on Emacs <=30 from warning about an unknown function.
(declare-function completion-table-with-metadata "minibuffer" (table metadata))

;; Protocol layer: typed access to dsh response fields (dsh-emacs-protocol.el)
(require 'crm)
(require 'dsh-emacs-protocol)

;; Load the core UI framework (must be loaded first)
(require 'dsh-emacs-ui)

;; Load all new modules
(require 'dsh-emacs-faces)
(require 'dsh-emacs-tokens)
(require 'dsh-emacs-markdown)
(require 'dsh-emacs-render)
(declare-function dsh-emacs-render--cancel-markdown "dsh-emacs-render" ())
(declare-function dsh-emacs-render--insert-user-block "dsh-emacs-render"
                  (event references))
(require 'dsh-emacs-composer)
(require 'dsh-emacs-events)
(require 'dsh-emacs-modeline)
(require 'dsh-emacs-queue)
(require 'dsh-emacs-server)
(require 'dsh-emacs-command)
(require 'dsh-emacs-reference)
(require 'dsh-emacs-shell)
(require 'dsh-emacs-session)

;;; ---------------------------------------------------------------------------
;;;  Customization options
;;; ---------------------------------------------------------------------------

(defgroup dsh-emacs nil
  "Emacs UI for DeepSeek Harness (dsh)."
  :group 'applications
  :prefix "dsh-emacs-")

(defcustom dsh-emacs-model-group-format
  #(" %s " 0 4 (face vertico-group-title))
  "Format string for provider group titles in the model selector.
`%s' is replaced with the provider name.
Inside the model selector's minibuffer this overrides vertico's global
`vertico-group-format' (buffer-locally, other completions are untouched):
vertico's stock format draws a long strike-through separator line across
the whole group header (\"----...\"), which is noisy; the default here
paints just the provider name.  Set to nil to hide group titles entirely
inside the picker."
  :type '(choice (const :tag "No group titles" nil) string)
  :group 'dsh-emacs)

(defcustom dsh-emacs-switch-max-candidates 200
  "Max candidates offered to the completion UI per keystroke by switch-session.
The completion framework (vertico/ivy/corfu) rebuilds its candidate list
on every keystroke, so an unbounded list of sessions would allocate a
fresh N-entry structure per keypress — the same pain counsel-rg avoids by
consuming its rg output in bounded increments.  This caps the offered set
to the most-recently-active entries; older sessions remain reachable as
soon as a filter is typed (and the workspace-scoped list is naturally
below this cap).  Raise it for very large session counts, lower it for
snappier keys."
  :type 'integer
  :group 'dsh-emacs)

(defcustom dsh-emacs-base-url "http://127.0.0.1:3080"
  "Address of the running dsh web service."
  :type 'string
  :group 'dsh-emacs)

(defcustom dsh-emacs-history-window 30
  "Size of the history window fetched when opening a session (`maxMessages'
semantics, counted in messages).
A larger window shows more of the conversation, but the raw events returned
by the server grow proportionally (in this package each message in a session
is ~hundreds of incremental events, so parse and GC costs rise linearly:
with the default no-argument window of ~30k raw events, the main thread needs
0.7s+ to parse them).  The default of 30 messages ≈ the latest 1~2 turns,
bringing the open cost down to 0.2~0.4s; increase it (e.g. 100) when a fuller
history is needed, at the cost of a slower open.  The same size is the page
`dsh-emacs-load-older-history' (`C-c C-o') fetches per press, so a larger
window also means fewer presses to reach the start of a long session."
  :type 'integer
  :group 'dsh-emacs)

(defcustom dsh-emacs-show-reasoning t
  "Whether to show reasoning content.  Enabled by default, matching dsh web
(the web always shows the Think line).  Set to nil for a leaner transcript."
  :type 'boolean
  :group 'dsh-emacs)

(defcustom dsh-emacs-show-tool-calls t
  "Whether to show tool calls."
  :type 'boolean
  :group 'dsh-emacs)

(defcustom dsh-emacs-default-cwd default-directory
  "Fallback working directory for new sessions.
Interactive new sessions take the current buffer's `default-directory'
first (a dired buffer's browsed dir, magit's repo root, a file's
directory); this option applies only when the command is called without
a CWD and the current buffer has no directory context."
  :type 'directory
  :group 'dsh-emacs)

(defcustom dsh-emacs-new-session-auto-project t
  "Auto-detect the Emacs project for a new session and place it there.
When `dsh-emacs-new-session' starts a session outside any workspace
context, it detects the project root of the working directory and
creates the session in the workspace registered for that root instead of
the Ungrouped CWD bucket.  The workspace is created server-side on first
use (`workspace/create' is idempotent by canonical path, so re-runs
resolve the existing registration).

Detection prefers project.el (`project-current' / `project-root',
built-in from Emacs 28, also reaching a user's `project-find-functions'
finders), then the VC root, then a `.git' directory walk.  It only runs
against the local loopback server — a remote dsh server's workspace
paths live on another host and cannot match the local project directory.
Set to nil to keep the old behavior (sessions always start in CWD)."
  :type 'boolean
  :group 'dsh-emacs)

(defcustom dsh-emacs-default-model "deepseek-v4-flash-0731"
  "Default model name."
  :type 'string
  :group 'dsh-emacs)

(defcustom dsh-emacs-default-preset nil
  "Default agent preset (agentPreset id) for new sessions.

nil lets the host pick its own default preset (no `agentPreset' field is
sent to `session/create').  Known values are the built-in preset ids
\"standard\" (Standard mode), \"minimal\" (Minimal mode), \"code\" (PTC
mode) and \"cordis\" (Creator mode), or the id of a user preset listed
by `agentPresets/list'.  Interactively, `dsh-emacs-new-session' with a
prefix argument asks for the preset instead of using this value."
  :type '(choice (const :tag "Host default" nil) string)
  :group 'dsh-emacs)

(defcustom dsh-emacs-attach-media-types
  '("image/png" "image/jpeg" "image/webp" "image/gif")
  "Image media types accepted for session attachments.

The host validates every upload against this set (plus byte/pixel limits
of its own), so only files resolving to one of these types are sent."
  :type '(repeat string)
  :group 'dsh-emacs)

(defcustom dsh-emacs-input-history-length 50
  "Maximum number of submitted prompts kept for `M-p' / `M-n' recall."
  :type 'integer
  :group 'dsh-emacs)

(defcustom dsh-emacs-input-history-cross-session nil
  "Whether `M-p' / `M-n' recall prompts from every session.
Non-nil shares one prompt history across all chat buffers; nil (the
default) restricts recall to the prompts the CURRENT session submitted
itself (per-session history, useful while several unrelated sessions are
open).  Every prompt is recorded in both scopes regardless; the option
only picks which list the keys browse, so toggling it never loses
recorded prompts."
  :type 'boolean
  :group 'dsh-emacs)

(defcustom dsh-emacs-busy-enter-behavior 'queue
  "What `\\[dsh-emacs-send-or-stop]' does with input while a turn is running.
Mirrors dsh web's `busyEnter' setting: `queue' lines the input up as the
next turn (delivered automatically when the current one finishes),
`steer' wakes the running agent and redirects its current work, and
`stop' keeps the old behavior of interrupting the turn.  With `queue' or
`steer', an empty input still interrupts.  `\\[universal-argument]
\\[dsh-emacs-send-or-stop]' explicitly steers one nonempty message regardless
of the local busy indicator."
  :type '(choice (const :tag "Queue as the next turn" queue)
                 (const :tag "Steer the running turn" steer)
                 (const :tag "Interrupt the turn" stop))
  :group 'dsh-emacs)

(defcustom dsh-emacs-question-skip-key "C-c C-s"
  "Key that skips the current ask question (answers it with an empty
selection, dsh web's per-question Skip) and moves to the next one.
A `C-c' prefix by default: the reader's text is the answer, so a bare
letter would make that letter untypable (and the free-text sentinel
contains several).  Bound only inside the question reader's minibuffer, so
nothing leaks into unrelated `completing-read' prompts; every question also
skips on an EMPTY input, and the key is only bound where there is a
candidate list.  Set to nil to disable the shortcut."
  :type '(choice (key-sequence :tag "Key sequence")
                 (const :tag "No shortcut" nil))
  :group 'dsh-emacs)

(defcustom dsh-emacs-question-help-display 'echo-area
  "Whether to show the question detail while answering.
`echo-area' shows the detail in the echo area without logging it; nil
disables it.  Selection and answer input are unchanged, and a question
without a detail never shows help.  Option descriptions ride along with
the completion candidates themselves (their `:annotation-function'), so
the echo area carries only the question's own detail."
  :type '(choice (const :tag "Echo area" echo-area)
                 (const :tag "No help" nil))
  :group 'dsh-emacs)

;;; ---------------------------------------------------------------------------
;;;  Internal variables
;;; ---------------------------------------------------------------------------

(defvar dsh-emacs--sessions nil
  "Cache of the session list.")

(defvar dsh-emacs--chat-buffers (make-hash-table :test 'equal)
  "Registry of session id -> live chat buffer.

Chat buffers are named `dsh-<list title>' (matching the session list, with
dsh prepended), and sessions with the same title need unique names, so a
buffer cannot be looked up by title; this table provides stable reuse and
renaming by session ID.")

(defvar dsh-emacs--workspaces nil
  "Cache of the workspace list.")

(defvar dsh-emacs--agent-presets nil
  "Cached `agentPresets/list' response (a `dsh-protocol-agent-preset-list'
struct), used by the new-session preset picker.  Refreshed lazily by
`dsh-emacs--agent-presets-refresh'; nil before the first successful
fetch falls back to the built-in preset ids.")

(defvar dsh-emacs--archived-sessions nil
  "Set of archived session IDs (hash table).")

(defvar dsh-emacs--current-session nil
  "Globally active session (the last opened one).

`dsh-emacs-open-session' sets it; it is the fallback owner for contexts
with no chat buffer (the session list, list-buffer commands, naming
yourself before a session opens).  With several session buffers open it
still points at the LAST-opened session, so interactive commands must
NOT resolve their target from this variable alone — they read
`dsh-emacs--buffer-session' (the owning chat buffer) first, via
`dsh-emacs--active-session-id'.")

(defvar dsh-emacs--current-buffer nil
  "Current chat buffer.")

(defvar dsh-emacs--tool-calls (make-hash-table :test 'equal)
  "Tool-call state table.")

(defvar dsh-emacs--activity-groups (make-hash-table :test 'equal)
  "Activity-group state table.")

(defvar-local dsh-emacs--input-marker nil
  "Marker for the start of the input area (buffer-local).")

(defvar-local dsh-emacs--pending-user-messages nil
  "Text of messages the user sent but that are not yet rendered in the transcript.")

(defvar-local dsh-emacs--pending-user-echoes nil
  "Optimistic transcript echoes awaiting their submit's acceptance.
An alist of (TEXT START-MARKER . END-MARKER) recorded by
`dsh-emacs--render-user-message-optimistic'.  An entry is dropped when the
canonical `user/message' consumes the pending text (the echo stays on
screen), or deleted from the buffer when the submit's RPC fails, so a
rejected prompt never lingers as a phantom message.")

(defvar-local dsh-emacs--buffer-session nil
  "Session ID owned by this chat buffer (buffer-local).

Set by `dsh-emacs-open-session' on every chat buffer; this is the
AUTHORITATIVE owner for event routing and interactive commands while
inside that buffer: mux transcript events are attributed to a chat
buffer via `buffer-local-value of this variable, and
`dsh-emacs--active-session-id' resolves the command target from it
before falling back to the global `dsh-emacs--current-session'.
Several session buffers can be open at once; each keeps its own
binding, so switching buffers never confuses which session a
transcript or a `C-c C-c' belongs to.")
;; `dsh-emacs-mode' is a derived mode, whose generated initializer runs
;; `kill-all-local-variables' (Clearing buffer-local variables on mode
;; switch).  Mark this binding permanent so it survives the mode call and
;; `dsh-emacs--chat-buffer-sync' (invoked from live `session/title' events)
;; can still match the current buffer against its session id.
(put 'dsh-emacs--buffer-session 'permanent-local t)

(defvar dsh-emacs--input-history nil
  "Prompts submitted with `dsh-emacs-send-or-stop', newest first.
Shared across chat buffers (session transcripts are volatile, the prompt
history is not).  Browsed by `M-p' / `M-n' when
`dsh-emacs-input-history-cross-session' is non-nil.")

(defvar dsh-emacs--input-history-by-session
  (make-hash-table :test 'equal)
  "Session id -> prompts that session submitted, newest first.
The recall list per chat buffer's session for `M-p' / `M-n' when
`dsh-emacs-input-history-cross-session' is nil.  Every prompt is recorded
here alongside `dsh-emacs--input-history', so toggling the option never
loses history — the lists merely start with the prompts recorded since
this feature shipped.")

(defvar-local dsh-emacs--input-history-pos nil
  "Index into the browsed `M-p' / `M-n' history list, nil when not browsing.
Buffer-local: each chat buffer holds its own recall position, so browsing
one session never bleeds its index or pending text into another.")

(defvar-local dsh-emacs--input-history-pending nil
  "Input text saved before history browsing started, restored by M-n.
Buffer-local alongside `dsh-emacs--input-history-pos'.")

;;; ---------------------------------------------------------------------------
;;;  RPC client
;;; ---------------------------------------------------------------------------

(defun dsh-emacs--rpc-id ()
  "Generate a unique RPC request id."
  (format "emacs-%d-%d" (random 999999) (truncate (float-time))))

(defun dsh-emacs--wrap-request (method params)
  "Wrap METHOD and PARAMS into the DSH RPC envelope.
PARAMS is the *content of the wire `args' object* (the method parameter
fields, e.g. ((request . ((sessionId . S)))) or ((agentId . A))); the
envelope always carries payload {args: {...}}, so nil PARAMS becomes
`{}'.  METHOD must equal the HTTP endpoint (`<namespace>/<method>', e.g.
\"session/list\" — `dsh-emacs--rpc-request'/`dsh-emacs--rpc-async'
build the /api/ URL from it).  Returns a JSON string."
  (let ((envelope `((type . "client-request")
                    (rpcId . ,(dsh-emacs--rpc-id))
                    (method . ,method)
                    ;; The payload must be exactly an object `args' whose
                    ;; fields are the method parameter names.  An empty
                    ;; Elisp list encodes as JSON null, so use an empty hash
                    ;; table to produce {} for parameter-less methods.
                    (payload . ,(list (cons 'args
                                            (or params (make-hash-table))))))))
    (json-encode envelope)))

(defun dsh-emacs--session-list-args ()
  "Wire `args' content for the `session/list' Remote method.
The 0.1.2-rc.1 `session/list' descriptor declares a single parameter
literally named `_request' (a reserved, usually-empty list request object) —
not `request' like the other session methods.  Its value must be an object
(`{}' for the unfiltered list), so the args alist carries `_request' whose
value is an empty hash table (an empty Elisp list would encode as JSON
`null' and fail boundary validation)."
  (list (cons '_request (make-hash-table))))

(defun dsh-emacs--unwrap-response (response)
  "Unwrap a DSH RPC RESPONSE, returning (ok-p . value-or-error).
RESPONSE is the parsed JSON object from the server."
  (let* ((result (cdr (assq 'result response)))
         (ok (cdr (assq 'ok result))))
    ;; `json-read' represents JSON false as :json-false, which is non-nil    ;; in Elisp.  Test the boolean explicitly instead of using `if ok'.
    (if (and ok (not (eq ok :json-false)))
        (cons t (cdr (assq 'value result)))
      ;; Not an ok envelope: prefer the envelope's error, then a provider
      ;; error body that leaked through the HTTP response (no `result' key,
      ;; e.g. a model-studio quota rejection) so callers show the real
      ;; reason instead of nil.
      (cons nil (or (cdr (assq 'error result))
                    (cdr (assq 'message response))
                    (cdr (assq 'error response))
                    nil)))))

(defun dsh-emacs--decode-response-body ()
  "Decode the current HTTP response body as UTF-8 in place.
`url-retrieve' may leave an application/json response in a unibyte buffer
when the server omits a charset parameter.  Parsing that buffer directly
turns Chinese and emoji into mojibake such as `ä½\240'."
  (unless enable-multibyte-characters
    (let ((body (decode-coding-string
                 (buffer-substring (point) (point-max)) 'utf-8)))
      (delete-region (point) (point-max))
      ;; A decoded multibyte string inserted into a unibyte buffer would be
      ;; encoded back to bytes.  Switch the response buffer first.
      (set-buffer-multibyte t)
      (insert body))))

(defvar url-http-response-status)

(defun dsh-emacs--rpc-request (method params)
  "Send an RPC request to the dsh web service.
METHOD is the `namespace/method' endpoint (e.g. \"session/list\") and
PARAMS the wire `args' content (an alist, or nil for parameter-less
methods).  Returns (ok-p . value) or nil."
  (let* ((url (format "%s/api/%s" (dsh-emacs--server-base-url) method))
         (json-data (dsh-emacs--wrap-request method params))
         (url-request-noninteractive t)
         (url-request-method "POST")
         (url-request-extra-headers
          (append '(("Content-Type" . "application/json"))
                  (dsh-emacs--extra-request-headers)))
         (url-request-data (encode-coding-string json-data 'utf-8)))
    (condition-case err
        ;; Auth cookies are owned by dsh, not the global URL cookie jar.
        (let ((buf (url-retrieve-synchronously url nil t)))
          (unless (buffer-live-p buf)
            (error "No HTTP response from dsh server"))
          (unwind-protect
              (with-current-buffer buf
                (when-let* ((status (bound-and-true-p url-http-response-status))
                            ((>= status 400)))
                  (signal 'error (list 'http status)))
                (goto-char (point-min))
                (re-search-forward "^$")
                (delete-region (point) (point-min))
                (dsh-emacs--decode-response-body)
                (goto-char (point-min))
                (dsh-emacs--unwrap-response (json-read)))
            (kill-buffer buf)))
      (error
       ;; A 401 while we sent a cookie means the cached cookie is stale (an
       ;; out-of-band server restarted and minted a new token): drop it so the
       ;; next call re-mints / re-prompts instead of 401-looping until restart.
       (when (and (dsh-emacs--server-auth-http-401-p err)
                  (fboundp 'dsh-emacs--server-auth-maybe-expire))
         (dsh-emacs--server-auth-maybe-expire))
       (message "RPC error: %s%s" (error-message-string err)
                (dsh-emacs--http-error-hint err))
       (cons nil nil)))))

(defun dsh-emacs--http-error-hint (err)
  "Human-readable hint for an HTTP error ERR, or \"\".
ERR like `(error http 404)' comes from `url-retrieve' status.  404/405
mean the `/api/<namespace>/<method>' endpoint is not claimed by this dsh
server (unknown method or a non-POST RPC path; the gateway 404s
unclaimed /api/* POSTs).  401 means the server requires browser-session
authentication that was not satisfied."
  (if (and (listp err) (numberp (nth 2 err)))
      (let ((code (nth 2 err)))
        (if (equal code 401)
            (format " (HTTP 401: dsh web requires authentication; see `C-h v dsh-emacs-server-auth-token')")
          (if (>= code 400)
              (format " (HTTP %S: current dsh server may not expose this RPC)" code)
            (format " (HTTP %S)" code))))
    ""))

(defun dsh-emacs--extra-request-headers ()
  "Extra `url-request-extra-headers' for RPC posts: the browser-session
cookie when this dsh server needs authentication, else nil.  Re-mints the
cookie lazily when a token became available after the server was probed."
  (when-let* ((auth (dsh-emacs--server-auth-header)))
    auth))

(defun dsh-emacs--rpc-async (method params callback)
  "Asynchronous RPC request; CALLBACK receives (ok-p value-or-error).
METHOD is the `namespace/method' endpoint, PARAMS the wire `args'
content — see `dsh-emacs--wrap-request'."
  (let* ((url (format "%s/api/%s" (dsh-emacs--server-base-url) method))
         (json-data (dsh-emacs--wrap-request method params))
         (url-request-noninteractive t)
         (url-request-method "POST")
         (url-request-extra-headers
          (append '(("Content-Type" . "application/json"))
                  (dsh-emacs--extra-request-headers)))
         (url-request-data (encode-coding-string json-data 'utf-8))
         (callback-buffer (current-buffer)))
    ;; Keep progress messages out of the minibuffer.  In particular,
    ;; `Contacting host...' otherwise remains visible when a successful
    ;; callback does not emit a follow-up message.
    (url-retrieve url
                  (lambda (status)
                    ;; JSON decode of big history windows allocates heavily;
                    ;; Profiler-measured on the default window (~30k raw
                    ;; events): Automatic GC took ~46% of the whole open.
                    ;; Enlarge the GC threshold dynamically to defer the GC
                    ;; storm into one collection after parsing — parsing and
                    ;; the callback run in the same dynamic scope.
                    (let ((gc-cons-threshold (* 64 1024 1024))
                          (gc-cons-percentage 0.6))
                      (if (plist-get status :error)
                          (let ((err (plist-get status :error)))
                            (kill-buffer)
                            ;; A 401 while we sent a cookie means the cached
                            ;; cookie is stale (an out-of-band server restarted
                            ;; and minted a new per-process token): drop it so
                            ;; the next call re-mints / re-prompts instead of
                            ;; 401-looping until Emacs restarts.
                            (when (and (dsh-emacs--server-auth-http-401-p err)
                                       (fboundp 'dsh-emacs--server-auth-maybe-expire))
                              (dsh-emacs--server-auth-maybe-expire))
                            (message "RPC async error: %S%s" status
                                     (dsh-emacs--http-error-hint err))
                            (when (buffer-live-p callback-buffer)
                              (with-current-buffer callback-buffer
                                ;; Callback that interacts inside the filter
                                ;; (completing-read etc.) and hits C-g: swallow the
                                ;; quit instead of a process-filter error.
                                (condition-case nil
                                    (funcall callback nil nil)
                                  (quit nil)))))
                        (goto-char (point-min))
                        (re-search-forward "^$")
                        (delete-region (point) (point-min))
                        (let* ((response
                                (condition-case err
                                    (progn
                                      (dsh-emacs--decode-response-body)
                                      (goto-char (point-min))
                                      (json-read))
                                  (error
                                   ;; Body cannot be parsed (non-JSON, cut
                                   ;; stream, ...): print the reason but still
                                   ;; dispatch the callback (ok=nil), so callers
                                   ;; always reach their failure branch instead
                                   ;; of being silently dropped.
                                   (message "RPC response error: %s"
                                            (error-message-string err))
                                   nil)))
                               (unwrapped (and response
                                               (dsh-emacs--unwrap-response
                                                response))))
                          (let ((ok (car unwrapped))
                                (value (cdr unwrapped)))
                            (kill-buffer)
                            (when (buffer-live-p callback-buffer)
                              (with-current-buffer callback-buffer
                                (condition-case nil
                                    (funcall callback ok value)
                                  (quit nil)))))))))
                  nil t t)))

;;; ---------------------------------------------------------------------------
;;;  Session management
;;; ---------------------------------------------------------------------------

(defun dsh-emacs--sequence-list (value)
  "Convert JSON VALUE, a list or vector, to a proper list.
JSON arrays are decoded as vectors by `json-read', while the UI iteration
helpers expect lists."
  (cond
   ((vectorp value) (append value nil))
   ((listp value) value)
   (t nil)))

(defun dsh-emacs--absolute-cwd (cwd)
  "Return CWD as an absolute path.
Without CWD, the current buffer's `default-directory' is the working
directory — a dired buffer's browsed dir, magit's repo root, a file's
directory — which is the directory the project auto-detection
(`dsh-emacs-new-session-auto-project') must see.  Only when even that
is unavailable does `dsh-emacs-default-cwd' apply."
  (expand-file-name (or cwd default-directory dsh-emacs-default-cwd)))

;; ---------------------------------------------------------------------------
;;  Chat buffer sync: name matches list + workspace path (default-directory)
;; ---------------------------------------------------------------------------

(defun dsh-emacs--chat-session-item (session-id)
  "Return the cached session item for SESSION-ID, or nil."
  (catch 'found
    (dolist (item dsh-emacs--sessions)
      (when (equal session-id (dsh-protocol-session-session-id item))
        (throw 'found item)))))

(defun dsh-emacs--chat-title (session-id)
  "Display title for SESSION-ID, identical to the session list row, or nil."
  (let ((item (dsh-emacs--chat-session-item session-id)))
    (and item (dsh-emacs-session--display-title item))))

(defun dsh-emacs--chat-cwd (session-id)
  "Directory of SESSION-ID: the session's `cwd' from session/list.
Falls back to the path of the workspace that accounts for the session
(a freshly created workspace session may not be in the session cache yet
but is already in `dsh-emacs--workspaces').  Returns nil when the session
is not known at all."
  (or (let ((item (dsh-emacs--chat-session-item session-id)))
        (and item (dsh-protocol-session-cwd item)))
      (catch 'found
        (dolist (ws dsh-emacs--workspaces)
          (when (member session-id
                        (dsh-protocol-workspace-session-ids ws))
            (throw 'found (dsh-protocol-workspace-path ws)))))))

(defun dsh-emacs--sanitize-buffer-name (title)
  "Sanitize TITLE for use as a buffer name.

Mode-line string elements are `%'-expanded by the modeline renderer, so a
literal `%' inside a buffer name would be mis-rendered (e.g. swallow the
following character); it is replaced with the visually close full-width
`％'.  Line breaks are flattened to spaces."
  (string-trim
   (replace-regexp-in-string "%" "％"
     (replace-regexp-in-string "[\n\r]" " " title))))

(defun dsh-emacs--chat-buffer-name (session-id)
  "Base buffer name for SESSION-ID.

`dsh-<list title>' when the session list has a display title for the session
(so the modeline matches the list), otherwise `dsh: <session-id>' as the
historical fallback."
  (let ((title (dsh-emacs--chat-title session-id)))
    (if (and title (not (string-empty-p title)))
        (concat "dsh-" (dsh-emacs--sanitize-buffer-name title))
      (format "dsh: %s" session-id))))

(defun dsh-emacs--chat-buffer-untrack ()
  "Remove the current chat buffer from `dsh-emacs--chat-buffers' when killed."
  (when dsh-emacs--buffer-session
    (remhash dsh-emacs--buffer-session dsh-emacs--chat-buffers)))

(defun dsh-emacs--chat-buffer-sync (session-id)
  "Bring the live chat buffer of SESSION-ID in line with the session cache:
rename it to the current list title and set its buffer-local
`default-directory' to the session workspace, so commands like
`magit-status' start in the right project directory.
A numeric suffix is appended when another buffer already holds the name."
  (let ((buf (gethash session-id dsh-emacs--chat-buffers)))
    (when (and (buffer-live-p buf)
               (equal session-id
                      (buffer-local-value 'dsh-emacs--buffer-session buf)))
      (with-current-buffer buf
        (let ((name (dsh-emacs--chat-buffer-name session-id)))
          (unless (equal (buffer-name) name)
            (rename-buffer name t)))
        (let ((cwd (dsh-emacs--chat-cwd session-id)))
          (when (and cwd (not (string-empty-p cwd)))
            (setq-local default-directory
                        (file-name-as-directory (expand-file-name cwd)))))))))

(defun dsh-emacs--chat-buffers-sync-all ()
  "Re-sync every live chat buffer after the session cache changed.
Updates the mode-line name (list title), the workspace directory, and
feeds each buffer's mode-line stats the server `contextPressure' snapshot
(ctx% segment), the `modelSelection' projection (model/effort/provider) and
the `agentPreset' projection (preset segment) so the mode line matches the
freshly fetched list."
  (maphash (lambda (session-id buf)
             (dsh-emacs--chat-buffer-sync session-id)
             (dsh-emacs--chat-buffer-context-sync session-id buf)
             (dsh-emacs--chat-buffer-model-sync session-id buf)
             (dsh-emacs--chat-buffer-preset-sync session-id buf))
           dsh-emacs--chat-buffers))

(defun dsh-emacs--chat-buffer-context-sync (session-id buf)
  "Push SESSION-ID's server contextPressure snapshot into BUF's mode line.
Pulled from the cached session struct (protocol accessors), so the same
projection pair (pressure, window) always lands together — the ctx% stays
consistent across model switches.
The row is only trusted when it carries a COMPLETE pair: `session/list`'s
projection column is explicitly partial (missing cells and
not-yet-materialized rows are served without `contextPressure'), and a
failed model run can leave the cell without `contextWindow'.  Wiping the
mode-line from such a row would blink out a previously correct ctx% until
the live `session/projection' frame lands the real pair; an incomplete row
therefore leaves the buffer's snapshot untouched, exactly like a session
missing from the cache (first open of a brand-new session, list not
fetched — `dsh-emacs--link-session-preset' brings the list back and the
fetch there re-runs this sync and fills the snapshot in)."
  (when (buffer-live-p buf)
    (let ((item (dsh-emacs--chat-session-item session-id)))
      (when item
        (let ((pressure (dsh-protocol-session-context-pressure item))
              (window (dsh-protocol-session-context-window item)))
          (when (and (integerp pressure) (integerp window) (> window 0))
            (with-current-buffer buf
              (dsh-emacs-modeline-set-context-snapshot pressure window))))))))

(defun dsh-emacs--session-model-selection (session-id)
  "The cached `modelSelection' struct for SESSION-ID, or nil.
Reads the session row's `modelSelection' projection (`lastUsed') and wraps
it in `dsh-protocol-model-selection' so business code reads
`provider'/'model'/'reasoning-effort' through accessors (the wire
`lastUsed' alist keys stay inside the protocol layer).  Nil when the row
is unknown or has no projection yet (fresh session before its first run)."
  (let ((item (dsh-emacs--chat-session-item session-id)))
    (when item
      (let ((selection (dsh-protocol-session-model-selection item)))
        (and selection
             (dsh-protocol-model-selection--from-alist selection))))))

(defun dsh-emacs--chat-buffer-model-sync (session-id buf)
  "Feed BUF's mode-line model/effort/provider for SESSION-ID.
The authoritative (provider, model, reasoningEffort) triple comes from
the cached session row's `modelSelection' projection (`lastUsed'); the
row may not carry one yet (fresh session before its first run), in which
case nothing is touched and `dsh-emacs-default-model' remains the
segment-level fallback — genuinely right for a session just created
with it.  The projection rides `session/list' rows and the follow/control
projection frames, so the feed is re-run by
`dsh-emacs--chat-buffers-sync-all' whenever the cache refreshes."
  (when (and (buffer-live-p buf)
             (equal session-id
                    (buffer-local-value 'dsh-emacs--buffer-session buf)))
    (when-let* ((sel (dsh-emacs--session-model-selection session-id)))
      (let ((model (dsh-protocol-model-selection-model sel))
            (provider (dsh-protocol-model-selection-provider sel))
            (effort (dsh-protocol-model-selection-reasoning-effort sel)))
        (with-current-buffer buf
          (when model (dsh-emacs-modeline-set-model model))
          (when provider (dsh-emacs-modeline-set-provider provider))
          (dsh-emacs-modeline-set-effort effort))))))

(defun dsh-emacs--chat-buffer-preset-sync (session-id buf)
  "Feed BUF's mode-line agent preset for SESSION-ID from the cached row.
The authoritative agent preset is the session's `agentPreset' projection
(the same live source `dsh-emacs--chat-buffer-model-sync' reads for
model/effort/provider).  No-op unless BUF is SESSION-ID's live chat buffer
or the cached row carries no preset yet — mirroring the model sync, a row
without the projection leaves the mode-line untouched rather than wiping a
known value."
  (when (and (buffer-live-p buf)
             (equal session-id
                    (buffer-local-value 'dsh-emacs--buffer-session buf)))
    (let ((preset (dsh-emacs--session-preset session-id)))
      (when (and preset (not (string-empty-p preset)))
        (with-current-buffer buf
          (dsh-emacs-modeline-set-preset preset))))))

;;;###autoload
(defun dsh-emacs-list-sessions--fetch ()
  "Fetch the session list via RPC and populate `dsh-emacs--sessions'."
  (dsh-emacs--rpc-async "session/list" (dsh-emacs--session-list-args)
                        (lambda (ok value)
                          (unwind-protect
                              (if ok
                                  (progn
                                    ;; JSON arrays arrive as vectors; normalize
                                    ;; them before the session list renderer uses
                                    ;; `dolist', and wrap each item in a
                                    ;; `dsh-protocol-session' struct so field
                                    ;; access is centralized (protoco.el).
                                    (setq dsh-emacs--sessions
                                          (mapcar
                                           #'dsh-protocol-session--from-alist
                                           (dsh-emacs--sequence-list
                                            (cdr (assq 'items value)))))
                                    ;; Title/workspace may have drifted
                                    ;; (auto summary/rename/session move):
                                    ;; re-sync all live chat buffers' name and
                                    ;; default-directory.
                                    (dsh-emacs--chat-buffers-sync-all)
                                    ;; Refresh workspaces in parallel so the
                                    ;; session list can group by workspace.
                                    (dsh-emacs-list-workspaces))
                                (message "Failed to fetch session list: %S" value))
                            ;; Snapshot installed: replay any frame that arrived
                            ;; while the refresh was in flight, so the list never
                            ;; rolls back below the stream's latest state.
                            (dsh-emacs-events--host-refresh-drain)))))

(defun dsh-emacs-list-sessions--fetch-when-ready (deadline)
  "Poll until the server is alive, then fetch the session list.
DEADLINE is a `float-time' value: retry every 0.5 s until it passes,
then report why the list stayed empty.  The chain is non-blocking (a
`run-at-time' timer per retry), so a cold server boot never freezes the
UI, and the grace period is the same `dsh-emacs-server-wait-seconds' a
blocking start uses — a first `dsh web' boot composes the profile and
loads the plugin tree, which does not fit in a fixed few seconds."
  (if (dsh-emacs--server-alive-p)
      (dsh-emacs-list-sessions--fetch)
    (if (< (float-time) deadline)
        (run-at-time 0.5 nil #'dsh-emacs-list-sessions--fetch-when-ready
                     deadline)
      (message "dsh: server did not become ready within %ds%s — retry with M-x dsh-emacs"
               dsh-emacs-server-wait-seconds
               (if (and dsh-emacs--server-process
                        (not (process-live-p dsh-emacs--server-process)))
                   " (the server process this package started has exited; see `*dsh-server*')"
                 " (see `*dsh-server*')")))))

(defun dsh-emacs-list-sessions ()
  "Fetch the session list and refresh workspaces."
  (interactive)
  ;; Non-blocking: launch the server in the background if needed.
  ;; When the server was just started, poll until it's ready before
  ;; firing the RPC to avoid a 404 race.
  (let ((alive (dsh-emacs-server-start)))
    (dsh-emacs-events--host-refresh-begin)
    (if alive
        (dsh-emacs-list-sessions--fetch)
      ;; Server just launched — wait for it within the same grace period a
      ;; blocking start would use (see `dsh-emacs-server-wait-seconds'); a
      ;; cold boot regularly outlives a fixed few seconds.
      (dsh-emacs-list-sessions--fetch-when-ready
       (+ (float-time) dsh-emacs-server-wait-seconds)))))

;;;###autoload
(defun dsh-emacs--new-session-workspace ()
  "Resolve the workspace to create the next session in, or nil.
Precedence: the workspace under point (session list header / New Session
row), then — inside a chat buffer — the current session's workspace.
Nil leaves the creation context to CWD; the session still lands in a
workspace (rather than the Ungrouped bucket) when project auto-detection
resolves one for the CWD, see `dsh-emacs-new-session'."
  (or (dsh-emacs-workspace-id-at-point)
      (and (derived-mode-p 'dsh-emacs-mode)
           (dsh-emacs--workspace-for-session
            (dsh-emacs--active-session-id)))))

(defun dsh-emacs--project-root (&optional dir)
  "Project root directory of DIR (default `default-directory'), or nil.
Prefers project.el (`project-current' / `project-root', built-in from
Emacs 28 — this also reaches a user's `project-find-functions' finders
such as projectile), then the VC root, then a `.git' directory walk
(the Emacs 27.1 baseline has neither project.el nor its completion
machinery).  Any failure in the chain yields nil (no detection)."
  (condition-case nil
      (let* ((dir (expand-file-name (or dir default-directory)))
             (root (or
                    (when (and (require 'project nil t)
                               (fboundp 'project-current)
                               (fboundp 'project-root))
                      (let ((pr (project-current nil dir)))
                        (and pr (project-root pr))))
                    (when (and (require 'vc nil t)
                               (fboundp 'vc-root-dir))
                      (vc-root-dir dir))
                    (locate-dominating-file dir ".git"))))
        ;; project.el may hand back an unexpanded `~' form; the canonical
        ;; spellings downstream (workspace matching, `workspace/create')
        ;; expect an absolute path without a trailing slash.
        (and root (directory-file-name (expand-file-name root))))
    (error nil)))

(defun dsh-emacs--workspace-canonical-path (path)
  "Canonical directory form of PATH for workspace-path matching, or nil.
Mirrors the server's workspace uniqueness canon (`fs.realpath'): trailing
slashes, `..' segments and symlinks are resolved, so a project root
matches the workspace registered for it under any spelling."
  (when (and path (not (string-empty-p path)))
    (condition-case nil
        (directory-file-name (file-truename (expand-file-name path)))
      (error nil))))

(defun dsh-emacs--workspace-id-by-path (dir)
  "Workspace-id whose canonical path equals DIR, or nil."
  (let ((want (dsh-emacs--workspace-canonical-path dir)))
    (and want
         (catch 'found
           (dolist (ws dsh-emacs--workspaces)
             (when (equal want
                          (dsh-emacs--workspace-canonical-path
                           (dsh-protocol-workspace-path ws)))
               (throw 'found
                      (dsh-protocol-workspace-workspace-id ws))))))))

(declare-function dsh-emacs-events--host-upsert-workspace
                  "dsh-emacs-events" (workspace))
(declare-function dsh-emacs--server-local-host-p "dsh-emacs-server" ())
(declare-function dsh-emacs--server-auth-http-401-p "dsh-emacs-server" (err))
(declare-function dsh-emacs--server-auth-maybe-expire "dsh-emacs-server" ())

(defun dsh-emacs--workspace-create-resolve (dir)
  "Resolve the workspace for DIR, creating it server-side when missing.
`workspace/create' is idempotent by canonical path, so this single call
both finds an existing registration and registers a new one; the returned
workspace is upserted into `dsh-emacs--workspaces' so the new session
groups into it immediately.  Returns the workspace struct, or nil when
the RPC failed."
  (let ((resp (dsh-emacs--rpc-request
               "workspace/create" `((request . ((path . ,dir)))))))
    (when (car resp)
      (let* ((result (dsh-protocol-workspace-result--from-alist (cdr resp)))
             (ws (dsh-protocol-workspace-result-workspace result)))
        (when ws
          (dsh-emacs-events--host-upsert-workspace ws)
          ws)))))

(defun dsh-emacs--new-session-project-workspace (dir)
  "Workspace-id for the project containing DIR, or nil.
When `dsh-emacs-new-session-auto-project' is on and the server is the
local loopback one (only then do its workspace paths share this
filesystem), detect the Emacs project root of DIR and resolve the
workspace registered for it — creating it when the server has none.
Else nil (the session keeps plain cwd semantics)."
  (when (and dsh-emacs-new-session-auto-project
             (dsh-emacs--server-local-host-p))
    (let ((root (dsh-emacs--project-root dir)))
      (when root
        (or (dsh-emacs--workspace-id-by-path root)
            (let ((ws (dsh-emacs--workspace-create-resolve root)))
              (and ws (dsh-protocol-workspace-workspace-id ws))))))))

;;;###autoload
(defun dsh-emacs-new-session (&optional cwd workspace-id preset)
  "Create a new session.
CWD is the working directory; with WORKSPACE-ID the session is created
inside that workspace (`session/create' takes workspaceId rather than
cwd).  PRESET is the agentPreset id the session starts on; nil lets the
host pick its default preset.

Interactively, when point sits on a workspace header or its empty
New Session row (in the session list), the session is created in that
workspace; inside a chat buffer, it is created in the current session's
workspace.  Otherwise the session is created in CWD — the current
buffer's `default-directory' (e.g. the directory a dired buffer is
browsing) when CWD is nil — unless that directory belongs to a detected
Emacs project, in which case the session goes into the workspace
registered for the project root (created on first use; disable with
`dsh-emacs-new-session-auto-project').  With a
prefix argument, first choose the agent preset from the live
`agentPresets/list' roster (falling back to the built-in presets before
the first roster arrives); without one the session uses
`dsh-emacs-default-preset'."
  (interactive
   (let ((ws (dsh-emacs--new-session-workspace)))
     (list nil ws
           (if current-prefix-arg
               (dsh-emacs--read-preset dsh-emacs-default-preset)
             dsh-emacs-default-preset))))
  (dsh-emacs-server-ensure)
  (let* ((dir (dsh-emacs--absolute-cwd cwd))
         (ws (or workspace-id
                 (dsh-emacs--new-session-project-workspace dir))))
    (dsh-emacs--rpc-async
     "session/create"
     `((request . ,(append (if ws
                               `((workspaceId . ,ws))
                             `((cwd . ,dir)))
                           (and preset `((agentPreset . ,preset))))))
                          (lambda (ok value)
                            (if ok
                                (let ((session-id (cdr (assq 'sessionId value))))
                                  ;; Cache the new session: sessions list +
                                  ;; workspace session-ids (group membership)
                                  ;; — otherwise it lands in ungrouped and
                                  ;; `session/title' events find no cached item,
                                  ;; so live auto-rename never takes effect.
                                  ;; Cache the create response's agentPreset
                                  ;; too, so list details and the footer show
                                  ;; the preset at once.
                                  (dsh-emacs--cache-new-session
                                   session-id ws
                                   (cdr (assq 'agentPreset value)))
                                  (dsh-emacs-open-session session-id)
                                  ;; A newly created workspace session is not
                                  ;; yet in the session/list cache (the event
                                  ;; stream does not carry it), so
                                  ;; `--chat-buffer-sync' finds no cwd; align
                                  ;; default-directory with the workspace path
                                  ;; right away so magit-status etc. locate the
                                  ;; project.  Reopening uses the refreshed
                                  ;; cache and takes the `--chat-cwd' branch.
                                  (when ws
                                    (let ((ws-struct (cl-find-if
                                                      (lambda (w)
                                                        (equal ws
                                                               (dsh-protocol-workspace-workspace-id w)))
                                                      dsh-emacs--workspaces)))
                                      (when ws-struct
                                        (let ((dir (dsh-protocol-workspace-path ws-struct)))
                                          (when (and dir (not (string-empty-p dir))
                                                     (buffer-live-p
                                                      dsh-emacs--current-buffer))
                                            (with-current-buffer dsh-emacs--current-buffer
                                              (setq-local default-directory
                                                          (file-name-as-directory
                                                           (expand-file-name dir))))))))))
                              (message "Failed to create session: %S" value))))))

;;;###autoload
(defun dsh-emacs-new-session-choose-preset ()
  "Create a new session after choosing its agent preset.
Like `dsh-emacs-new-session' (the workspace under point, the current
chat session's workspace, or the CWD's project workspace decides the
creation context), but always reads the preset first — bound to `C' in
the session list, next to `c' which creates immediately with
`dsh-emacs-default-preset'.  C-g during the preset prompt cancels the
creation."
  (interactive)
  (dsh-emacs-server-ensure)
  (dsh-emacs-new-session nil (dsh-emacs--new-session-workspace)
                         (dsh-emacs--read-preset dsh-emacs-default-preset)))

(defun dsh-emacs--cache-new-session (session-id &optional workspace-id preset)
  "Cache the freshly created SESSION-ID so grouping and title updates work
before the next `session/list' refresh: insert a placeholder row (blank,
\"New Session\", PRESET when given) into `dsh-emacs--sessions' and, with
WORKSPACE-ID, append SESSION-ID to that workspace's `session-ids' (the
group renderer assigns sessions to workspaces from those ids).  Repaints
the session list.

The workspace attachment is deliberately INDEPENDENT of the session-row
insert: the core `$events' stream (`api-session/added') may deliver the new
session before the `session/create' RPC callback runs, so guarding both
actions behind the same not-yet-cached check would skip the attach and leave
the session in the Ungrouped bucket until a later `workspace/follow' frame
arrives."
  (let ((ws (and workspace-id
                 (cl-find-if (lambda (w)
                               (equal workspace-id
                                      (dsh-protocol-workspace-workspace-id w)))
                             dsh-emacs--workspaces))))
    (unless (dsh-emacs--chat-session-item session-id)
      (let ((cwd (if ws (dsh-protocol-workspace-path ws)
                   (dsh-emacs--absolute-cwd nil))))
        (push (dsh-protocol-session--from-alist
               (append (list (cons 'sessionId session-id)
                             (cons 'blank t)
                             (cons 'cwd cwd))
                       (and preset (list (cons 'agentPreset preset)))))
              dsh-emacs--sessions)))
    ;; Attach even when the session row already arrived via the core
    ;; `$events' stream (an `api-session/added' emit): membership comes solely
    ;; from the workspace `session-ids', so the row must be accounted there or
    ;; it renders in Ungrouped.  Idempotent by membership.
    (when (and ws
               (not (member session-id
                            (dsh-protocol-workspace-session-ids ws))))
      (setf (dsh-protocol-workspace-session-ids ws)
            (cons session-id
                  (dsh-protocol-workspace-session-ids ws))))
    (when (and (listp dsh-emacs--sessions)
               dsh-emacs-sessions-buffer
               (get-buffer dsh-emacs-sessions-buffer))
      (with-current-buffer (get-buffer dsh-emacs-sessions-buffer)
        (dsh-emacs-session--render))))
  session-id)

;; ---------------------------------------------------------------------------
;;  Agent preset (agentPreset) selection for new sessions
;; ---------------------------------------------------------------------------

(defun dsh-emacs--agent-presets-refresh ()
  "Refresh `dsh-emacs--agent-presets' from `agentPresets/list'.
Async: the response lands in the cache when it arrives; a failed RPC
leaves the previous cache (when any) untouched.  Returns nothing."
  (dsh-emacs--rpc-async "agentPresets/list" nil
                        (lambda (ok value)
                          (when ok
                            (setq dsh-emacs--agent-presets
                                  (dsh-protocol-agent-preset-list--from-alist
                                   value))))))

(defconst dsh-emacs--preset-display-name-mapping
  '(("standard" . "Standard mode")
    ("minimal" . "Minimal mode")
    ("code" . "PTC mode")
    ("cordis" . "Creator mode"))
  "Mapping (PRESET-ID . DISPLAY-NAME) of each shipped system preset.

The dsh web resolves these presets' option labels through exactly this
built-in key map (`presetDisplayText' in the web's agent-preset UI) —
`agentPresets/list' carries no `name' for them.  The picker mirrors the
mapping so the Emacs choices read the same as the web's.")

(defun dsh-emacs--preset-display-name (preset)
  "Web-consistent display name of roster row PRESET.
Mirrors the web's `presetDisplayText': a system preset among the shipped
built-ins shows its web name (\"Standard mode\" …); anything else shows
its published `name', falling back to the id.  PRESET is a
`dsh-protocol-agent-preset' struct or wire alist."
  (let* ((p (dsh-protocol--struct #'dsh-protocol-agent-preset-p
                                  #'dsh-protocol-agent-preset--from-alist
                                  preset))
         (id (dsh-protocol-agent-preset-id p)))
    (or (and (equal "system" (dsh-protocol-agent-preset-trust p))
             (cdr (assoc id dsh-emacs--preset-display-name-mapping)))
        (dsh-protocol-agent-preset-name p)
        id)))

(defun dsh-emacs--preset-choices ()
  "((DISPLAY . ID) ...) preset choices for the new-session picker.
From the cached `agentPresets/list' roster (broken entries excluded),
each DISPLAY matches what the dsh web shows for that preset — the web
name for the shipped system presets (\"Standard mode\" …), the
published `name' (or the id) for everything else.  Before the first
roster arrives, the four built-in presets are offered with their web
names."
  (let ((presets (and dsh-emacs--agent-presets
                      (dsh-protocol-agent-preset-list-presets
                       dsh-emacs--agent-presets))))
    (if presets
        (delq nil
              (mapcar
               (lambda (p)
                 (unless (dsh-protocol-agent-preset-broken p)
                   (cons (dsh-emacs--preset-display-name p)
                         (dsh-protocol-agent-preset-id p))))
               presets))
      (mapcar (lambda (pair) (cons (cdr pair) (car pair)))
              dsh-emacs--preset-display-name-mapping))))

(defun dsh-emacs--preset-default-id (&optional default)
  "Preset id the new-session picker pre-selects, or nil.
DEFAULT (the configured `dsh-emacs-default-preset') wins when it is a
valid choice; otherwise the roster's `isDefault' preset; otherwise nil
(no pre-selection)."
  (let ((choices (dsh-emacs--preset-choices)))
    (or (and default (rassoc default choices) default)
        (let ((presets (and dsh-emacs--agent-presets
                            (dsh-protocol-agent-preset-list-presets
                             dsh-emacs--agent-presets))))
          (cl-some (lambda (p)
                     (and (dsh-protocol-agent-preset-is-default p)
                          (dsh-protocol-agent-preset-id p)))
                   presets)))))

(defun dsh-emacs--read-preset (&optional default)
  "Read an agent preset id for a new session; nil keeps the host default.
Choices come from the cached `agentPresets/list' roster (the built-in
presets with their web names before the first fetch); a background
refresh is kicked off so the next pick sees fresh entries.  Pre-selects
DEFAULT (the configured `dsh-emacs-default-preset') when it is a valid
choice, else the host's `isDefault' preset — an empty RET accepts the
pre-selection; without any pre-selection picking is required (unknown
input is rejected).  C-g cancels the whole session creation."
  (dsh-emacs--agent-presets-refresh)
  (let* ((default-id (dsh-emacs--preset-default-id default))
         (choices (dsh-emacs--preset-choices))
         (default-name (and default-id
                            (car (rassoc default-id choices))))
         (picked (completing-read
                  (format "Agent preset for the new session%s: "
                          (if default-name
                              (format " (default %s)" default-name)
                            ""))
                  choices nil t nil nil default-name)))
    (cond ((and picked (not (string-empty-p picked)))
           (or (cdr (assoc picked choices)) default-id))
          (default-name default-id)
          (t nil))))

(defun dsh-emacs--ensure-input-marker ()
  "Repair the chat input marker when it was lost, without touching content.
The prompt anchor is located by its face; the marker is re-created right
after the `❯ ' prompt so input sync and transcript rendering keep working.
The glyph is found by scanning forward on the anchor's line instead of a
blind 2-char skip: the anchor sits at the start of the prompt-face run,
which may start left of the prompt itself (e.g. a queue prefix sharing
the prompt face), and the marker must land after the prompt, not at the
run start.  When no `❯ ' is found ahead of the anchor, the fixed skip is
kept as a fallback."
  (when (and (fboundp 'dsh-emacs-render--input-anchor-pos)
             (or (null dsh-emacs--input-marker)
                 (not (and (markerp dsh-emacs--input-marker)
                           (eq (marker-buffer dsh-emacs--input-marker)
                               (current-buffer))))))
    (let ((anchor (dsh-emacs-render--input-anchor-pos)))
      (when anchor
        (setq dsh-emacs--input-marker
              (save-excursion
                (goto-char anchor)
                (if (search-forward "❯ " (line-end-position) t)
                    (point-marker)
                  (forward-char 2)      ; skip "❯ "
                  (point-marker))))))))

(defun dsh-emacs--lock-cursor-to-input ()
  "Clamp the cursor around the editable input area (post-command).
Two, complementary clamps:
- BELOW: positions past the end of the input area are pulled back to its
  end, so the cursor can never rest under the input line.
- ABOVE, on the input line itself: the read-only stretch from the start
  of the input line up to the `❯ ' prompt is a no-park zone — e.g. after
  `C-a' in the input or a stray click — and point is pulled to the edit
  start after the prompt; the prompt icon is strictly non-resting while
  the transcript above the input line stays freely readable.
The BELOW clamp is area-based (`dsh-emacs--input-end'), not line-based,
and the ABOVE clamp touches only the input line's left margin, so a
multi-line input is unaffected — the cursor may roam anywhere inside the
editable region.  Runs in every dsh-emacs-mode buffer (buffer-local
hook) independent of the global `dsh-emacs--current-buffer', so it also
holds in an inactive chat buffer while another session is the
last-opened one."
  (dsh-emacs--ensure-input-marker)
  (when (and dsh-emacs--input-marker
             (markerp dsh-emacs--input-marker)
             (eq (marker-buffer dsh-emacs--input-marker) (current-buffer)))
    (let* ((marker-pos (marker-position dsh-emacs--input-marker))
           (input-end (max marker-pos (dsh-emacs--input-end)))
           ;; Start of the input line (the line holding `❯ '): on that
           ;; line, left of the icon is a no-park zone.
           (line-start (save-excursion
                         (goto-char marker-pos)
                         (line-beginning-position))))
      (cond
       ((> (point) input-end)
        (goto-char input-end))
       ((and (< (point) marker-pos)
             (>= (point) line-start))
        (goto-char marker-pos))))))

(defun dsh-emacs--route-typing-to-input ()
  "When about to type or edit while point is in the read-only region, first\nmove the cursor back to the input area after `❯ '.\n
Used with `dsh-emacs--reveal-input-when-typing': typing directly in the\nread-only area would trigger `text-read-only'; this moves point into the\ninput area before the command runs, so typing no longer errors\nand the input area scrolls into view automatically."
  (when (and (memq this-command
                   '(self-insert-command
                     delete-backward-char
                     delete-forward-char
                     backward-delete-char-untabify
                     dsh-emacs-delete-input
                     yank yank-pop))
             dsh-emacs--input-marker
             (markerp dsh-emacs--input-marker)
             (eq (marker-buffer dsh-emacs--input-marker) (current-buffer))
             (< (point) (marker-position dsh-emacs--input-marker)))
    (goto-char (marker-position dsh-emacs--input-marker))))

(defun dsh-emacs--reveal-input-when-typing ()
  "Immediately scroll the window to the input area when typing (self-insert /\nediting commands).\n
When the input line is not visible because the window was scrolled up to\nread history, starting to type scrolls the input line\nback to the bottom of the window, so the `❯ ' line being typed is visible."
  (when (and (window-live-p (get-buffer-window (current-buffer) t))
             (memq this-command
                   '(self-insert-command
                     delete-backward-char
                     delete-forward-char
                     backward-delete-char-untabify
                     dsh-emacs-delete-input
                     yank yank-pop))
             dsh-emacs--input-marker
             (markerp dsh-emacs--input-marker)
             (eq (marker-buffer dsh-emacs--input-marker) (current-buffer))
             (>= (point) (marker-position dsh-emacs--input-marker)))
    (let ((input-pos (marker-position dsh-emacs--input-marker)))
      (unless (pos-visible-in-window-p input-pos (selected-window))
        (save-excursion
          (goto-char input-pos)
          (recenter -1))))))

(defun dsh-emacs--composer-boundary ()
  "Return the editable input's end for the current chat buffer, or nil.
A valid live input marker in the current buffer marks a composer context; the
returned boundary is the position right before the structural newline the
mode-line separator owns.  Deletion guards use it so a forward kill never
removes that newline (see `dsh-emacs--composer-kill-region' and
`dsh-emacs--composer-delete-forward')."
  (when (and dsh-emacs--input-marker
             (markerp dsh-emacs--input-marker)
             (eq (marker-buffer dsh-emacs--input-marker) (current-buffer)))
    (dsh-emacs--input-end)))

(defun dsh-emacs--composer-kill-region (orig start end &rest args)
  "`kill-region' advice: never kill across the composer's structural newline.
A forward kill that reaches the input's end — `C-k'/`kill-line', a trailing
`kill-word'/`M-d', a kill-sentence, or a selected region extended past the
input — would remove the structural newline the mode-line separator owns and
strand the cursor below the input line.  The kill region is clipped at the
input boundary: a region wholly at/after it deletes nothing, one crossing it
keeps only the editable part.  Regions fully inside the input and kills in
non-chat buffers run unchanged.  `kill-line' keeps its normal Emacs semantics
here (kills from point to the end of the input, never the whole input or the
separator)."
  (if-let* ((boundary (dsh-emacs--composer-boundary)))
      (cond ((<= end boundary) (apply orig start end args))
            ((< start boundary) (apply orig start boundary args))
            (t nil))
    (apply orig start end args)))

(defun dsh-emacs--composer-delete-forward (orig &optional arg)
  "`delete-forward-char' advice: stop at the composer's structural newline.
`C-d' at the very end of the input would otherwise delete the separator
newline (a plain buffer's `C-d' at end-of-line joins lines; here the newline is
structural and there is nothing to join), stranding the cursor below the input
line.  Deletions are capped at the input boundary."
  (let* ((arg (or arg 1))
         (boundary (dsh-emacs--composer-boundary))
         (effective (and boundary (min arg (max 0 (- boundary (point)))))))
    (cond ((and boundary (<= effective 0)) nil)
          ((null boundary) (funcall orig arg))
          (t (funcall orig effective)))))

(defvar dsh-emacs--composer-delete-guard-installed nil
  "Non-nil once the composer forward-delete guards have been added once.")

(defun dsh-emacs--composer-delete-guard-install ()
  "Install the composer forward-delete boundary guards (global, idempotent).
Advises the deletion commands (`kill-region', which `C-k'/`kill-line' and
`kill-word'/region kills route through, and `delete-forward-char'/`C-d')
rather than the `delete-region' primitive, because a native-compiled caller
can bypass advice on the primitive while the interactive command symbols are
always reached through advice."
  (unless dsh-emacs--composer-delete-guard-installed
    (setq dsh-emacs--composer-delete-guard-installed t)
    (advice-add 'kill-region :around #'dsh-emacs--composer-kill-region)
    (advice-add 'delete-forward-char :around #'dsh-emacs--composer-delete-forward)))


;;;###autoload
(defun dsh-emacs-open-session (session-id)
  "Open session SESSION-ID.
Connects a per-session mux stream for the chat buffer WITHOUT touching
other open sessions' streams: with several chats live, each buffer keeps
its own realtime stream (tearing the previous one down here used to
leave it stream-less — unable to ever switch back to
realtime)."
  (interactive)
  (dsh-emacs-server-ensure)
  (setq dsh-emacs--current-session session-id)
  (let* ((existing (gethash session-id dsh-emacs--chat-buffers))
         (buf (if (and existing (buffer-live-p existing))
                  existing
                ;; First open, or the buffer was killed: name it
                ;; `dsh-<list title>', appending an <N> suffix when taken
                ;; so it stays unique (same-titled sessions can coexist).
                (get-buffer-create
                 (generate-new-buffer-name
                  (dsh-emacs--chat-buffer-name session-id))))))
    (puthash session-id buf dsh-emacs--chat-buffers)
    (setq dsh-emacs--current-buffer buf)
    (with-current-buffer buf
      (setq-local dsh-emacs--buffer-session session-id)
      ;; The cache may have drifted (auto summary/rename/workspace
      ;; move): align the list title and point the buffer's
      ;; default-directory at the session workspace (magit etc.
      ;; locate the project from it).  Must run after setq-local:
      ;; sync's guard requires buffer-session to match, and a
      ;; first-open buffer has no such local variable yet (it would
      ;; be silently skipped).
      (dsh-emacs--chat-buffer-sync session-id)
      (dsh-emacs-mode)
      (dsh-emacs-modeline-setup)
      ;; Show the default model immediately as a segment-level
      ;; fallback only; the authoritative (provider, model, effort)
      ;; comes from the session row's modelSelection projection
      ;; (`dsh-emacs--chat-buffer-model-sync', arriving with list/
      ;; projection frames) — trusting the default was the root
      ;; cause of the mode-line showing the wrong model.
      (dsh-emacs-modeline-set-model dsh-emacs-default-model)
      (dsh-emacs--chat-buffer-model-sync session-id buf)
      ;; Feed the server contextPressure snapshot to the mode-line
      ;; segment on open.  Must come after `dsh-emacs-mode' (whose
      ;; define-derived-mode runs kill-all-local-variables) and
      ;; `dsh-emacs-modeline-setup': a snapshot fed in earlier is
      ;; wiped by the mode switch, so ctx% never appears (the
      ;; classic first-open symptom).
      (dsh-emacs--chat-buffer-context-sync session-id buf)
      ;; The agent preset (agentPreset) comes from the session
      ;; list cache; fetch session/list once when it is missing.
      (dsh-emacs--link-session-preset session-id)
      ;; Reopening an already-live chat buffer resumes its realtime stream
      ;; without re-rendering what is on screen: the follow snapshot is the
      ;; catch-up (its records carry original seqs, so the
      ;; `dsh-emacs--anchor-seq' gate drops everything already rendered);
      ;; fresh buffers start at anchor 0 and the snapshot seeds the whole
      ;; window.  No separate history fetch precedes the connect.
      (dsh-emacs-command-catalog-prefetch session-id)
      ;; Pre-warm the @ reference candidate cache (files + session roster) so
      ;; the first "@" popup reads warm cache.  Buffer-local cache, so it must
      ;; run in the chat buffer (see dsh-emacs-reference.el).
      (dsh-emacs-reference-prefetch session-id)
      ;; Mode-line setup appends its anchor newline at point-max.  Return point
      ;; to the editable prompt so the cursor stays on the `❯' line.
      (goto-char dsh-emacs--input-marker)
      ;; Connect: the first `session/follow' item is the snapshot that seeds
      ;; the transcript (see `dsh-emacs-events--follow-snapshot'), followed by
      ;; gapless live event frames — no history/stream hand-off gap exists.
      (dsh-emacs-events-connect dsh-emacs--current-buffer))
    (pop-to-buffer dsh-emacs--current-buffer)))

;; ---------------------------------------------------------------------------
;;  Switch session within the same workspace (directly from a chat buffer)
;; ---------------------------------------------------------------------------

(defun dsh-emacs--workspace-sessions (workspace-id)
  "Return SESSIONS belonging to WORKSPACE-ID, excluding archived,
subagent and blank rows.  Returns a list of session structs in recency
order."
  (let ((ws-by-id
         (catch 'found
           (dolist (ws dsh-emacs--workspaces)
             (when (equal workspace-id
                            (dsh-protocol-workspace-workspace-id ws))
               (throw 'found ws))))))
    (if (null ws-by-id)
        nil
      (let ((session-ids (dsh-protocol-workspace-session-ids ws-by-id)))
        (dsh-emacs-session--sort-by-recency
         (cl-remove-if
          (lambda (s)
            (or (not (dsh-emacs-session--visible-p s))
                (not (member (dsh-protocol-session-session-id s)
                             session-ids))))
          dsh-emacs--sessions))))))

(defun dsh-emacs--workspace-label (workspace-id)
  "Human label of WORKSPACE-ID: title, else path basename, else the id."
  (or (dsh-emacs--workspace-title workspace-id)
      (dsh-emacs-session--workspace-basename
       (dsh-emacs--workspace-path workspace-id))
      workspace-id))

(defun dsh-emacs--switch-prompt (workspace-id &optional all)
  "Return the completing-read prompt for switching sessions.
WORKSPACE-ID scopes the prompt to one workspace; non-nil ALL asks
across all workspaces."
  (cond
   (all "Switch session (all workspaces): ")
   (workspace-id (format "Switch session in %s: "
                         (dsh-emacs--workspace-label workspace-id)))
   (t "Switch session: ")))

(defun dsh-emacs--workspace-title (workspace-id)
  "Return the title of the workspace with WORKSPACE-ID, or nil."
  (catch 'found
    (dolist (ws dsh-emacs--workspaces)
      (when (equal workspace-id (dsh-protocol-workspace-workspace-id ws))
        (throw 'found (dsh-protocol-workspace-title ws))))))

(defun dsh-emacs--workspace-path (workspace-id)
  "Return the path of the workspace with WORKSPACE-ID, or nil."
  (catch 'found
    (dolist (ws dsh-emacs--workspaces)
      (when (equal workspace-id (dsh-protocol-workspace-workspace-id ws))
        (throw 'found (dsh-protocol-workspace-path ws))))))

(defun dsh-emacs--workspace-for-session (session-id)
  "Return the workspace id SESSION-ID belongs to, or nil when ungrouped."
  (catch 'found
    (dolist (ws dsh-emacs--workspaces)
      (when (member session-id (dsh-protocol-workspace-session-ids ws))
        (throw 'found (dsh-protocol-workspace-workspace-id ws))))))

;; With `ivy-mode' on, `ivy-sort-functions-alist' takes over
;; sorting; we adapt to whichever completion framework the user
;; actually enabled (see `dsh-emacs--completing-read-ordered').
;; The defvar only silences a byte-compile warning and guarantees
;; dynamic binding; it has no effect when the framework is not
;; loaded.
(defvar ivy-sort-functions-alist)

(defun dsh-emacs--completion-table-with-metadata (collection metadata)
  "Return COLLECTION as a completion table carrying METADATA.
METADATA is an alist of completion metadata (see `completion-metadata'),
e.g. `display-sort-function' pinned to identity to stop a frontend from
reordering the candidates.  Uses the Emacs 31 built-in when present and
the equivalent table lambda otherwise; the built-in is Emacs 31-only,
while the package baseline is 27.1."
  (if (fboundp 'completion-table-with-metadata)
      (completion-table-with-metadata collection metadata)
    (lambda (string pred action)
      (if (eq action 'metadata)
          `(metadata . ,metadata)
        (complete-with-action action collection string pred)))))

(defun dsh-emacs--completing-read-ordered (prompt collection &rest args)
  "`completing-read', but keep COLLECTION's incoming order from
  being reordered by the completion framework.
  Adapts to whichever framework the user actually enabled, without
  hardcoding any of them:
  - vertico / corfu / stock minibuffer: reads the completion
    metadata's `display-sort-function' (vertico--sort-function /
    corfu both take priority over their own sort toggles); set it to
    identity here and the framework drops the reorder by itself;
  - ivy: does not read that metadata and takes the sort function per
    collection/caller from `ivy-sort-functions-alist' — bound
    dynamically to ((t . nil)) (docstring: nil = no sorting),
    effective for this call only;
  - other frameworks (selectrum etc.) also honor the
    display-sort-function convention.
  PROMPT/COLLECTION/ARGS have exactly the same semantics as
  `completing-read'."
  (let ((ordered (dsh-emacs--completion-table-with-metadata
                  collection
                  '((display-sort-function . identity)))))
    (if (bound-and-true-p ivy-mode)
        (let ((ivy-sort-functions-alist '((t))))
          (apply #'completing-read prompt ordered args))
      (apply #'completing-read prompt ordered args))))

(defun dsh-emacs--sessions-index ()
  "Hash table session-id → session struct for `dsh-emacs--sessions'.
Indexing once keeps repeated per-candidate title lookups O(1) instead of
the linear scan in `dsh-emacs--chat-session-item' (switching over
hundreds of sessions makes the scan quadratic)."
  (let ((index (make-hash-table :test 'equal
                                :size (length dsh-emacs--sessions))))
    (dolist (s dsh-emacs--sessions)
      (puthash (dsh-protocol-session-session-id s) s index))
    index))

(defun dsh-emacs--workspaces-by-session ()
  "Hash table session-id → owning workspace-id for `dsh-emacs--workspaces'."
  (let ((index (make-hash-table :test 'equal
                                :size (length dsh-emacs--sessions))))
    (dolist (ws dsh-emacs--workspaces)
      (let ((ws-id (dsh-protocol-workspace-workspace-id ws)))
        (dolist (sid (dsh-protocol-workspace-session-ids ws))
          (puthash sid ws-id index))))
    index))

(defun dsh-emacs--switch-entry-label (session &optional session-index ws-index ws-label-fn)
  "Completion label for SESSION when switching across workspaces:
display title followed by the owning workspace title, so same-titled
sessions from different workspaces stay tellable apart.  SESSION-INDEX
(session-id → struct) and WS-INDEX (session-id → workspace-id) make the
lookups O(1) over many sessions; WS-LABEL-FN maps a workspace-id to its
display label (default `dsh-emacs--workspace-label', which re-scans
`dsh-emacs--workspaces' per call — pass a memoized resolver when the
candidate list is large)."
  (let* ((id (dsh-protocol-session-session-id session))
         (item (if session-index
                   (gethash id session-index)
                 (dsh-emacs--chat-session-item id)))
         (title (or (and item (dsh-emacs-session--display-title item)) id))
         (ws-id (if ws-index
                    (gethash id ws-index)
                  (dsh-emacs--workspace-for-session id))))
    (if ws-id
        (format "%s (%s)" title
                (if ws-label-fn
                    (funcall ws-label-fn ws-id)
                  (dsh-emacs--workspace-label ws-id)))
      title)))

(defun dsh-emacs--switch-candidates (vec string limit)
  "Bound the candidate universe VEC delivers to the completion UI.
VEC holds (LABEL . ID) pairs in recency order; STRING is the current
minibuffer input; LIMIT caps the empty-input offer.  On empty input only
the first LIMIT (most recently active) labels are handed over, so
sustained navigation rebuilds a small list per keystroke instead of a
multi-hundred one — the in-memory equivalent of counsel-rg consuming its
subprocess output in bounded increments.  Once the user types a filter
the full universe is returned and the user's `completion-styles' narrow
it as usual, so older sessions stay reachable."
  (let ((out nil)
        (n 0))
    (if (not (string-empty-p string))
        (cl-loop for rec across vec collect (car rec))
      (catch 'limit
        (cl-loop for rec across vec
                 do (push (car rec) out)
                 (setq n (1+ n))
                 when (>= n limit)
                 do (throw 'limit (nreverse out)))
        (nreverse out)))))

(defun dsh-emacs--switch-table (vec limit)
  "Function completion table over VEC of (LABEL . ID) pairs.
Hands the completion framework a bounded candidate universe (see
`dsh-emacs--switch-candidates') with standard programmed-completion
semantics: trivial boundaries/metadata, and the entries the framework
filters with the user's `completion-styles'."
  (lambda (string pred action)
    (if (or (eq (car-safe action) 'boundaries) (eq action 'metadata))
        nil
      (let ((cands (dsh-emacs--switch-candidates vec string limit)))
        (complete-with-action action cands string pred)))))

(defun dsh-emacs--switch-id-table (vec)
  "Hash display label → session id for VEC; the most recent one wins.
Labels are not guaranteed unique across sessions (same title in one
workspace), so first-write wins to keep the recency-first pick."
  (let ((table (make-hash-table :test 'equal :size (length vec))))
    (cl-loop for rec across vec
             unless (gethash (car rec) table)
             do (puthash (car rec) (cdr rec) table))
    table))

(defun dsh-emacs--switch-title (session &optional session-index)
  "Display title for SESSION: the list-row title, else the session id.
SESSION-INDEX (session-id → struct) makes the lookup O(1) over many
sessions; it defaults to building one from `dsh-emacs--sessions'."
  (let* ((id (dsh-protocol-session-session-id session))
         (index (or session-index (dsh-emacs--sessions-index)))
         (item (gethash id index)))
    (or (and item (dsh-emacs-session--display-title item)) id)))

(defun dsh-emacs--switch-entry-labels (candidates session-index ws-index ws-label)
  "Return the (LABEL . ID) completion entries for CANDIDATES.
Labels are the bare display titles: workspace names never take part in
filtering, so typing a workspace name does not narrow the list.  A
workspace title is appended (via `dsh-emacs--switch-entry-label') only
when several candidates share one display title — the disambiguator that
keeps same-titled sessions from different workspaces selectable — and the
session id if that still collides.  Preserves CANDIDATES' (recency)
order."
  (let ((counts (make-hash-table :test 'equal))
        (seen (make-hash-table :test 'equal))
        (entries nil))
    ;; First pass: count display-title occurrences (duplicate
    ;; titles need workspace disambiguation)
    (dolist (s candidates)
      (let ((title (dsh-emacs--switch-title s session-index)))
        (puthash title (1+ (gethash title counts 0)) counts)))
    ;; Second pass: build (label . id); unique titles show bare
    (dolist (s candidates)
      (let* ((id (dsh-protocol-session-session-id s))
             (title (dsh-emacs--switch-title s session-index))
             (label (if (> (gethash title counts 0) 1)
                        (dsh-emacs--switch-entry-label
                         s session-index ws-index ws-label)
                      title)))
        (if (gethash label seen)
            (let ((final (format "%s · %s" label id)))
              (puthash final t seen)
              (setq entries (cons (cons final id) entries)))
          (progn
            (puthash label t seen)
            (setq entries (cons (cons label id) entries))))))
    (nreverse entries)))

;;;###autoload
(defun dsh-emacs-switch-workspace-session (&optional all)
  "Switch to another session in the same workspace as the current one.
Prompts for a session from the current workspace's session list; opens or
focuses its chat buffer on selection.  The current session itself is
never offered.  When all sessions are in the Ungrouped bucket (no known
workspaces), falls back to switching any cached session.

With prefix argument ALL, or via `dsh-emacs-switch-session', offer
every visible session across all workspaces (the Ungrouped bucket
included) instead; workspace names never take part in filtering — they
disambiguate only same-titled sessions.

The completion list is capped at `dsh-emacs-switch-max-candidates'
entries while the input is empty (recency-first; type to narrow the full
set), so navigating a large session list never churns a multi-hundred
candidate rebuild per keystroke — mirroring how counsel-rg consumes its
results in bounded increments."
  (interactive "P")
  (dsh-emacs-server-ensure)
  (let* ((session-id (dsh-emacs--active-session-id))
         (workspace-id (unless all (dsh-emacs--workspace-for-session session-id)))
         ;; Build the index once per call: per-candidate
         ;; title/workspace lookups drop from a linear scan
         ;; (O(n)/O(n·m)) to a hash O(1), so many sessions no longer
         ;; stall.
         (session-index (dsh-emacs--sessions-index))
         (ws-index (dsh-emacs--workspaces-by-session))
         ;; Memoize workspace display names: each workspace is
         ;; resolved once (`dsh-emacs--workspace-label' scans the
         ;; workspace list per call).
         (ws-label-cache (make-hash-table :test 'equal))
         (ws-label (lambda (ws-id)
                     (or (gethash ws-id ws-label-cache)
                         (puthash ws-id
                                  (dsh-emacs--workspace-label ws-id)
                                  ws-label-cache))))
         (candidates
          (cl-remove-if
           (lambda (s)
             (equal (dsh-protocol-session-session-id s) session-id))
           (if workspace-id
               ;; Members of the same workspace are already filtered by
               ;; the visibility rules (non-archived/subagent/blank) and
               ;; sorted by activity time.
               (dsh-emacs--workspace-sessions workspace-id)
             (dsh-emacs-session--sort-by-recency
              (cl-remove-if-not #'dsh-emacs-session--visible-p
                                dsh-emacs--sessions))))))
    (if (null candidates)
        (message (if all
                     "No other sessions"
                   "No other sessions in this workspace"))
      (let* ((entries (dsh-emacs--switch-entry-labels
                         candidates session-index ws-index ws-label))
             (vec (vconcat entries))
             (id-table (dsh-emacs--switch-id-table vec))
             (table (dsh-emacs--switch-table
                     vec dsh-emacs-switch-max-candidates))
             (picked (dsh-emacs--completing-read-ordered
                      (dsh-emacs--switch-prompt workspace-id all)
                      table nil t)))
        (when picked
          (let ((target-id (gethash picked id-table)))
            (when target-id
              (dsh-emacs-open-session target-id))))))))

;;;###autoload
(defun dsh-emacs-switch-session ()
  "Switch to another session across ALL workspaces (Ungrouped included).
The all-workspaces counterpart of `dsh-emacs-switch-workspace-session':
every visible session is offered (workspace names only disambiguate
same-titled sessions), and the current session itself is never offered."
  (interactive)
  (dsh-emacs-switch-workspace-session 'all))

(defun dsh-emacs--completing-session-id (prompt &optional filter empty-message)
  "Read a session id with completion against the cached session list.
Choices show the display title (like the list); the returned value is
always the session id.  FILTER, when given, restricts the candidates to
the sessions it accepts (unarchive offers only the archived rows); when
that leaves nothing to choose, signal EMPTY-MESSAGE instead of letting
`completing-read' fail on an empty collection."
  (let* ((index (dsh-emacs--sessions-index))
         (sessions (if filter
                       (cl-remove-if-not filter dsh-emacs--sessions)
                     dsh-emacs--sessions))
         (entries (mapcar (lambda (s)
                            (let* ((id (dsh-protocol-session-session-id s))
                                   (item (gethash id index)))
                              (cons (format "%-30s  %s"
                                            (or (and item
                                                     (dsh-emacs-session--display-title item))
                                                id)
                                            id)
                                    id)))
                          sessions)))
    (unless entries
      (user-error "%s" (or empty-message "No session to choose from")))
    (cdr (assoc (completing-read prompt entries nil t) entries))))

;;;###autoload
(defun dsh-emacs-fork-session (session-id)
  "Fork SESSION-ID into a new child session that inherits its history.
The child starts from the session's latest state (`session/fork' without
an explicit seq); after the RPC confirms, the list refreshes and the child
buffer opens with the same workspace path."
  (interactive (list (dsh-emacs--completing-session-id "Fork session: ")))
  (dsh-emacs-server-ensure)
  (dsh-emacs--rpc-async "session/fork"
                        `((request . ((sessionId . ,session-id))))
                        (lambda (ok value)
                          (if (not ok)
                              (message "Failed to fork session: %S" value)
                            (let ((child-id (cdr (assq 'sessionId value))))
                              (unless child-id
                                (user-error "session/fork returned no sessionId"))
                              (dsh-emacs-list-sessions)
                              (message "Forked %s -> %s" session-id child-id)
                              (dsh-emacs-open-session child-id))))))

(defun dsh-emacs--session-preset (session-id)
  "Return the agentPreset cached for SESSION-ID, or nil when unknown."
  (catch 'found
    (dolist (item dsh-emacs--sessions)
      (when (equal session-id (dsh-protocol-session-session-id item))
        (throw 'found (dsh-protocol-session-agent-preset item))))))

(defun dsh-emacs--link-session-preset (session-id)
  "Fill the mode-line agent preset for SESSION-ID.
Uses the cached session list when possible; otherwise refreshes
`session/list' once and lets the sync feed the preset from the response.
SAFE outside a chat buffer (the RPC callback runs in the buffer that called
this).  The lazy fetch also covers the ctx% snapshot on first open: a session
missing from `dsh-emacs--sessions' has no `contextPressure' to feed the
mode-line either (see `dsh-emacs--chat-buffer-context-sync'), so the same
fetch — whose callback calls `dsh-emacs--chat-buffers-sync-all' — brings
preset, context snapshot, title and workspace in one round trip."
  (if (and (dsh-emacs--chat-session-item session-id)
           (dsh-emacs--session-preset session-id))
      ;; Cached row already carries the `agentPreset' projection: feed the
      ;; mode line through the shared sync (same source the cache refresh
      ;; uses for model/ctx), so the preset and its siblings stay consistent.
      (dsh-emacs--chat-buffer-preset-sync session-id (current-buffer))
    (dsh-emacs--rpc-async "session/list" (dsh-emacs--session-list-args)
                          (lambda (ok value)
                            (when ok
                              (let ((items (mapcar
                                            #'dsh-protocol-session--from-alist
                                            (dsh-emacs--sequence-list
                                             (cdr (assq 'items value))))))
                                ;; A brand-new session on first open is missing
                                ;; from the cache: refresh the whole cache so
                                ;; the buffer name (`dsh-<title>') and the
                                ;; workspace (default-directory) come along
                                ;; too; `dsh-emacs--chat-buffers-sync-all' now
                                ;; also feeds the preset to open chat buffers.
                                (setq dsh-emacs--sessions items)
                                (dsh-emacs--chat-buffers-sync-all)))))))

(defun dsh-emacs-archive-session (session-id)
  "Archive SESSION-ID: remove it from its workspace view.
`workspace/archiveSession' (still the only session-removal RPC; there is
no `session.delete'); `dsh-emacs-unarchive-session' is its dsh 0.1.6
inverse.  Refreshes the archived set and the session list on success."
  (interactive (list (dsh-emacs--completing-session-id "Archive session: ")))
  (dsh-emacs-server-ensure)
  (dsh-emacs--rpc-async "workspace/archiveSession"
                        `((request . ((sessionId . ,session-id))))
                        (lambda (ok value)
                          (if ok
                              (progn
                                (setq dsh-emacs--archived-sessions
                                      (dsh-emacs--normalize-archived
                                       (dsh-protocol-archived-set-archived-session-ids
                                        (dsh-protocol-archived-set--from-alist value))))
                                (dsh-emacs-list-sessions)
                                (message "Session archived"))
                            (message "Failed to archive: %S" value)))))

(defun dsh-emacs--archived-session-p (session)
  "Whether SESSION is in the cached archived set."
  (and dsh-emacs--archived-sessions
       (gethash (dsh-protocol-session-session-id session)
                dsh-emacs--archived-sessions)))

(defun dsh-emacs-unarchive-session (session-id)
  "Restore archived SESSION-ID to its workspace view.
`workspace/unarchiveSession' (dsh 0.1.6), the inverse of archiving: the
host drops the id from its registry-global archive set and treats an id
it no longer holds archived as a no-op, so a lost race with another
surface reports success.  The returned set refreshes the archived cache
and the session list."
  (interactive (list (dsh-emacs--completing-session-id
                      "Unarchive session: " #'dsh-emacs--archived-session-p
                      "No archived session can be restored")))
  (dsh-emacs-server-ensure)
  (dsh-emacs--rpc-async "workspace/unarchiveSession"
                        `((request . ((sessionId . ,session-id))))
                        (lambda (ok value)
                          (if ok
                              (progn
                                (setq dsh-emacs--archived-sessions
                                      (dsh-emacs--normalize-archived
                                       (dsh-protocol-archived-set-archived-session-ids
                                        (dsh-protocol-archived-set--from-alist value))))
                                (dsh-emacs-list-sessions)
                                (message "Session restored"))
                            (message "Failed to restore session: %S" value)))))

(defun dsh-emacs-rename-session (session-id new-title)
  "Rename session SESSION-ID to NEW-TITLE.
Interactively the target is read with completion, except inside a chat
buffer, where that buffer's own session is renamed without a picker; the
title prompt is prefilled with the session's current title."
  (interactive
   (let* ((sid (or (and (derived-mode-p 'dsh-emacs-mode)
                        (dsh-emacs--active-session-id))
                   (dsh-emacs--completing-session-id "Rename session: ")))
          (item (dsh-emacs--chat-session-item sid)))
     (list sid
           (read-string "New title: "
                        (or (and item (dsh-emacs-session--title item)) "")))))
  (dsh-emacs-server-ensure)
  (dsh-emacs--rpc-async "session/rename"
                        `((request . ((sessionId . ,session-id)
                                      (title . ,new-title))))
                        (lambda (ok value)
                          (if ok
                              (progn
                                (dsh-emacs-list-sessions)
                                (message "Session renamed"))
                            (message "Failed to rename: %S" value)))))

;;; ---------------------------------------------------------------------------
;;;  Workspace management
;;; ---------------------------------------------------------------------------

(defun dsh-emacs--normalize-archived (archived)
  "Normalize ARCHIVED (JSON array) into a hash table of session ids."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (id (dsh-emacs--sequence-list archived))
      (puthash id t table))
    table))

;;;###autoload
(defun dsh-emacs-list-workspaces ()
  "Re-baseline the workspace cache from the core `workspace/follow' stream.
The 0.1.2 protocol has no `workspace/list' RPC: the list state comes from
the `workspace/follow' logical stream (a baseline frame on open).  A
refresh re-opens that stream on the live core connection (retiring the
previous one first); the fresh baseline seeds
`dsh-emacs--workspaces'/`dsh-emacs--archived-sessions' and repaints.
When no core connection is open the session list is connected first and
the connect's own `workspace/follow' baseline (opened by
`dsh-emacs-events--host-open' once the handshake completes) repaints —
no immediate re-baseline is attempted on a not-yet-handshaken socket."
  (interactive)
  (dsh-emacs-server-ensure)
  (unless (dsh-emacs-events--core-workspace-rebaseline)
    (when (and dsh-emacs-sessions-buffer
               (get-buffer dsh-emacs-sessions-buffer))
      (with-current-buffer (get-buffer dsh-emacs-sessions-buffer)
        (dsh-emacs-events-host-connect)))))

;;;###autoload
(defun dsh-emacs-create-workspace (path)
  "Create a workspace.  PATH is the path of an existing directory."
  (interactive "DWorkspace directory: ")
  (dsh-emacs-server-ensure)
  (dsh-emacs--rpc-async "workspace/create"
                        `((request . ((path . ,(expand-file-name path)))))
                        (lambda (ok value)
                          (if ok
                              (progn
                                (dsh-emacs-list-workspaces)
                                (message "Workspace created"))
                            (message "Failed to create workspace: %S" value)))))

;;;###autoload
(defun dsh-emacs-rename-workspace (workspace-id new-title)
  "Rename workspace."
  (interactive
   (list (read-string "Workspace id: ")
         (read-string "New workspace title: ")))
  (dsh-emacs-server-ensure)
  (dsh-emacs--rpc-async "workspace/rename"
                        `((request . ((workspaceId . ,workspace-id)
                                      (title . ,new-title))))
                        (lambda (ok value)
                          (if ok
                              (progn
                                (dsh-emacs-list-workspaces)
                                (message "Workspace renamed"))
                            (message "Failed to rename: %S" value)))))

;;;###autoload
(defun dsh-emacs-delete-workspace (workspace-id)
  "Delete workspace.  The directory and session logs are not deleted."
  (interactive
   (let ((id (read-string "Delete workspace id: ")))
     (if (yes-or-no-p (format "Delete workspace %s? " id))
         (list id)
       (keyboard-quit))))
  (dsh-emacs-server-ensure)
  (dsh-emacs--rpc-async "workspace/delete"
                        `((request . ((workspaceId . ,workspace-id))))
                        (lambda (ok value)
                          (if ok
                              (progn
                                (dsh-emacs-list-workspaces)
                                (message "Workspace deleted"))
                            (message "Failed to delete: %S" value)))))

;;;###autoload
(defun dsh-emacs-move-workspace (workspace-id before-workspace-id)
  "Move WORKSPACE-ID before BEFORE-WORKSPACE-ID in the workspace order.
With nil BEFORE-WORKSPACE-ID the workspace moves to the end.
Mirrors dsh web's drag ordering (`workspace/insertBefore'): the response
carries the authoritative workspaceIds, which reorder the local cache so
the session list regroups immediately (the `workspace/follow' stream also
repaints)."
  (interactive
   (list (read-string "Move workspace id: ")
         (let ((s (read-string "Insert before workspace id (blank for end): " nil nil t)))
           (and (not (string-empty-p s)) s))))
  (dsh-emacs-server-ensure)
  (dsh-emacs--rpc-async "workspace/insertBefore"
                        (if before-workspace-id
                            `((request . ((workspaceId . ,workspace-id)
                                          (beforeWorkspaceId . ,before-workspace-id))))
                          `((request . ((workspaceId . ,workspace-id)))))
                        (lambda (ok value)
                          (if ok
                              (progn
                                (let* ((ids (dsh-emacs--sequence-list
                                             (cdr (assq 'workspaceIds value))))
                                       (ids-by-local
                                        (delq nil
                                              (mapcar
                                               (lambda (ws)
                                                 (let ((id (dsh-protocol-workspace-workspace-id ws)))
                                                   (and id (cons id ws))))
                                               dsh-emacs--workspaces))))
                                  (when ids
                                    (setq dsh-emacs--workspaces
                                          (append
                                           (delq nil (mapcar (lambda (id)
                                                               (cdr (assoc id ids-by-local)))
                                                             ids))
                                           (delq nil (mapcar
                                                      (lambda (pair)
                                                        (unless (member (car pair) ids)
                                                          (cdr pair)))
                                                      ids-by-local))))
                                    ;; Refresh workspaces in parallel so
                                    ;; membership/order stays authoritative.
                                    (dsh-emacs-list-workspaces)))
                                (message "Workspace reordered"))
                            (message "Failed to reorder: %S" value)))))

;;; ---------------------------------------------------------------------------
;;;  Chat mode
;;; ---------------------------------------------------------------------------

(defvar dsh-emacs-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'dsh-emacs-send-or-stop)
    (define-key map (kbd "C-c C-b") #'dsh-emacs-interrupt-turn)
    (define-key map (kbd "C-c C-q") #'dsh-emacs-list-queue)
    (define-key map (kbd "C-c C-r") #'dsh-emacs-refresh)
    (define-key map (kbd "C-c C-o") #'dsh-emacs-load-older-history)
    (define-key map (kbd "C-c C-l") #'dsh-emacs-list-sessions-display)
    (define-key map (kbd "C-c C-s") #'dsh-emacs-switch-workspace-session)
    (define-key map (kbd "C-c M-s") #'dsh-emacs-switch-session)
    (define-key map (kbd "C-c C-w") #'dsh-emacs-copy-dwim)
    (define-key map (kbd "C-c C-f") #'dsh-emacs-modeline-toggle)
    (define-key map (kbd "C-c C-a") #'dsh-emacs-attach-file)
    (define-key map (kbd "C-c C-m") #'dsh-emacs-select-model)
    (define-key map (kbd "C-c C-g") dsh-emacs-goal-map)
    (define-key map (kbd "C-c C-!") #'dsh-emacs-shell-process-kill)
    (define-key map (kbd "M-p") #'dsh-emacs-input-history-back)
    (define-key map (kbd "M-n") #'dsh-emacs-input-history-forward)
    ;; TAB completes slash command names when the input area
    ;; starts with "/" (whether or not the popup menu is open)
    (define-key map (kbd "TAB") #'completion-at-point)
    (define-key map [drag-n-drop] #'dsh-emacs--dnd-attach)
    map)
  "Keymap for chat mode.")


(defun dsh-emacs--chat-buffer-clear-modified ()
  "`kill-buffer-query-functions' hook: drop the modified flag so killing a
dsh chat buffer never prompts to save a session transcript (which is never
persisted to disk).  Returns t to allow the kill: a query function that
returns nil silently blocks `kill-buffer' (the docstring says \"if any of
them returns nil, the buffer is not killed\")."
  (set-buffer-modified-p nil)
  t)

(defun dsh-emacs--chat-buffer-keep-clean (&rest _)
  "`after-change-functions' hook: keep the transcript buffer unmodified.
The buffer is a live session view that is never saved, so every programmatic
insert (history render, streaming, input sync) must leave it unmodified:
some tab/window managers query `buffer-modified-p' before closing a buffer
and prompt \"save?\".  Restore the flag without invalidating the mode line
after every text or property edit; session statistics refresh separately."
  (restore-buffer-modified-p nil))

(defun dsh-emacs-imenu-create-user-index ()
  "Build an imenu index of user messages in the current buffer.
Each entry maps a human-readable label to the message's start position.
Users can jump to any historical input via `M-x imenu' (or consult-imenu,
vertico, etc.)."
  (let ((index '()))
    (save-excursion
      (goto-char (point-min))
      (while (< (point) (point-max))
        (let ((pos (next-single-property-change (point) 'dsh-emacs-user-message nil (point-max))))
          (if (>= pos (point-max))
              (goto-char (point-max))
            (goto-char pos)
            (when (get-text-property pos 'dsh-emacs-user-message)
              (let* ((line-num (line-number-at-pos pos))
                     (line-end (line-end-position))
                     (raw (buffer-substring-no-properties pos line-end))
                     (content (if (string-prefix-p "\u276f " raw)
                                  (substring raw 2)
                                raw))
                     (preview (if (> (length content) 60)
                                  (concat (substring content 0 57) "...")
                                content))
                     (label (format "%d: %s" line-num preview)))
                (push (cons label pos) index)))
            (goto-char (1+ pos))))))
    (nreverse index)))

(define-derived-mode dsh-emacs-mode fundamental-mode "DSH"
  "DeepSeek Harness chat mode.
\\{dsh-emacs-mode-map}"
  (setq buffer-read-only nil)
  (setq truncate-lines nil)
  (setq word-wrap t)
  ;; telega-style scroll discipline: with point in the input area, vertical
  ;; scrolling keeps the `❯' line visible (recenters rather than jumping far
  ;; away), page commands land on line boundaries, and scrolling past the
  ;; top/bottom wraps to the other end instead of erroring.
  (setq-local scroll-conservatively 101)
  (setq-local next-screen-context-lines 0)
  (setq-local scroll-error-top-bottom t)
  (setq-local buffer-invisibility-spec '(t))
  (setq-local line-spacing 0.15)
  (buffer-disable-undo)
  (setq-local comment-start "// ")
  (setq-local comment-end "")
  ;; Complete slash commands when the input starts with "/"; complete
  ;; file/session references while an "@" token is in progress (see
  ;; dsh-emacs-command.el / dsh-emacs-reference.el).
  (setq-local completion-at-point-functions
              '(dsh-emacs-command-completion-at-point
                dsh-emacs-reference-completion-at-point))
  ;; Cooperative slash / @ auto-trigger (see `dsh-emacs-command-auto-trigger-setup'
  ;; and `dsh-emacs-reference-auto-trigger-setup'): dsh-emacs never enables a
  ;; completion front-end's auto mode itself — it only contributes "/" and "@"
  ;; to a front-end the user already turned on, and that front-end pops the list
  ;; (corfu-auto / company idle).  Stock *Completions* / vertico / icomplete have
  ;; no auto channel and trigger on TAB only.
  (dsh-emacs-command-auto-trigger-setup)
  (dsh-emacs-reference-auto-trigger-setup)
  ;; @ references are host/query-dynamic (files, sessions), unlike the static
  ;; slash catalog: while an @ token is in progress under corfu-auto, watch it
  ;; and issue background host fetches so a settled query can reopen/refresh
  ;; corfu's native popup.  This watcher only fetches data — it never opens a
  ;; completion UI (corfu owns the popup via the "@" trigger; non-corfu buffers
  ;; complete on TAB).  No-op without an active @ token or corfu-auto.
  (add-hook 'post-command-hook #'dsh-emacs-reference--auto-complete nil t)

  ;; @ references match flexibly across the whole path, independent of the
  ;; user's global completion-styles: chat buffers map the @ completion
  ;; category (dsh-emacs-reference.el) to the built-in `flex' style.  Scoped to
  ;; that category via buffer-local overrides, so slash and every other
  ;; completion keep the user's own styles.
  (setq-local completion-category-overrides
              (cons '(dsh-emacs-reference (styles flex))
                    completion-category-overrides))
  ;; imenu: index by user message, so M-x imenu jumps to any past input
  (setq-local imenu-create-index-function #'dsh-emacs-imenu-create-user-index)

  ;; Mode-line assembly is done by `dsh-emacs-modeline-setup'
  ;; (called on session creation); do not override
  ;; mode-line-format here, keeping the user's default mode line.

  ;; Reset rendering state
  ;; add-hook prepends: disconnect and refresh the text first,
  ;; then release the Markdown body markers.
  (add-hook 'kill-buffer-hook #'dsh-emacs-render--cancel-markdown nil t)
  (add-hook 'change-major-mode-hook #'dsh-emacs-render--cancel-markdown nil t)
  (add-hook 'kill-buffer-hook #'dsh-emacs-events-disconnect nil t)
  (add-hook 'change-major-mode-hook #'dsh-emacs-events-disconnect nil t)
  (add-hook 'kill-buffer-hook #'dsh-emacs--chat-buffer-untrack nil t)
  ;; Chat buffers are never "modified": the session transcript
  ;; is not written to disk, so closing must not prompt to save
  (add-hook 'kill-buffer-query-functions #'dsh-emacs--chat-buffer-clear-modified nil t)
  (add-hook 'after-change-functions #'dsh-emacs--chat-buffer-keep-clean nil t)
  ;; Lock the cursor to the input area (after `❯ ') when a session opens
  (add-hook 'post-command-hook #'dsh-emacs--lock-cursor-to-input nil t)
  ;; Before insert/edit commands, move point back to the input
  ;; area if it sits in the read-only region
  (add-hook 'pre-command-hook #'dsh-emacs--route-typing-to-input nil t)
  ;; Scroll to the input area immediately when typing
  (add-hook 'post-command-hook #'dsh-emacs--reveal-input-when-typing nil t)
  ;; Forward deletes (`C-k'/kill-line, `M-d'/kill-word, kill-region, `C-d')
  ;; must never cross the input area's trailing structural newline; `C-k'
  ;; keeps standard semantics (only deletes after point) and the guard holds
  ;; the separator line in place.
  (dsh-emacs--composer-delete-guard-install)
  (setq dsh-emacs--tool-calls (make-hash-table :test 'equal))
  (setq dsh-emacs--activity-groups (make-hash-table :test 'equal))
  (setq dsh-emacs--pending-user-messages nil
        dsh-emacs--event-ready nil)
  (dsh-emacs-events--watchdog-stop)
  (dsh-emacs-events--health-stop)
  (setq dsh-emacs--ws-last-event-time nil
        dsh-emacs--ws-last-probe-time nil
        dsh-emacs--ws-probe-inflight nil)
  (dsh-emacs-render--reset-tool-tracking)
  ;; `!' local shell commands: kill a running process too when
  ;; the buffer is killed
  (dsh-emacs-shell-mode-setup)

  ;; Initialize the input area
  (dsh-emacs--setup-input-area)
  ;; Reset Composer chrome with the buffer; the next projection or snapshot
  ;; rebuilds the Goal Row and its top marker.
  (dsh-emacs-composer-reset))

(defun dsh-emacs--setup-input-area ()
  "Set up the input area (a read-only transcript plus a writable input box).
All welcome text is marked read-only; only the region after ❯ is writable."
  (let ((inhibit-read-only t))
    ;; Clear the buffer
    (erase-buffer)
    ;; Add a minimal chat header and operation hints
    (let ((welcome-start (point)))
      (insert (propertize "dsh  " 'face 'dsh-emacs-accent-face))
      (insert (propertize "DeepSeek Harness\n" 'face 'dsh-emacs-header-face))
      (insert (propertize "C-c C-c send   ·   C-c C-q queue   ·   C-c C-r refresh   ·   C-c C-l session list\n\n"
                          'face 'dsh-emacs-hint-face))
      ;; Input prompt
      (insert (propertize "❯ " 'face 'dsh-emacs-input-prompt-face))
      ;; Mark the whole welcome area read-only (via a text property,
      ;; not buffer-read-only)
      (put-text-property welcome-start (point) 'read-only t)
      (put-text-property welcome-start (point) 'front-sticky '(read-only))
      ;; Do not let properties leak into the input inserted at the end of the
      ;; prompt.  Text properties are sticky by default, so inserting
      ;; immediately after the prompt would otherwise inherit them:
      ;;  - `read-only': would signal `text-read-only' even though the
      ;;    insertion point itself has no `read-only' property.
      ;;  - `face` / `font-lock-face': typing runs `insert-and-inherit'
      ;;    (Emacs 31 `self-insert-command'), which copies the previous
      ;;    character's face.  Without the exclusion, manual input after
      ;;    `❯ ' inherited the prompt's accent face (blue) while pasted
      ;;    (`yank' strips faces) or completed (plain `insert') text stayed
      ;;    default coloured — the "half blue, half white" input line.
      (put-text-property welcome-start (point) 'rear-nonsticky
                         '(read-only face font-lock-face)))
    ;; Mark the input start position (the marker follows text
    ;; insertion/deletion automatically)
    (setq dsh-emacs--input-marker (point-marker))))

(defun dsh-emacs--ensure-input-area ()
  "Ensure the input area exists and point is at the right position."
  (unless (and dsh-emacs--input-marker (marker-buffer dsh-emacs--input-marker))
    (dsh-emacs--setup-input-area))
  (goto-char dsh-emacs--input-marker))

(defun dsh-emacs--active-session-id ()
  "Return the session id the current command context belongs to.
Resolves in this order:
1. the buffer-local `dsh-emacs--buffer-session' of the current chat buffer;
2. the global `dsh-emacs--current-session' as a fallback for list-buffer \ncommands and other contexts with no session ownership.
Interactive commands (send, interrupt, refresh, model picker) must resolve
here rather than reading the global directly: with several session buffers
open, the global points at the last-opened session while the user may be
editing inside an earlier one."
  (or (and (boundp 'dsh-emacs--buffer-session)
           dsh-emacs--buffer-session)
      dsh-emacs--current-session))

(defun dsh-emacs--busy-p ()
  "Return non-nil when this chat buffer is generating.
The chat stream's buffer-local flag drives the mode-line spinner.  The core
session-status projection can arrive before that stream's `turn/start', so
also consult the authoritative cached session row; otherwise `C-c C-c' can
misclassify a running host turn as idle and take the optimistic plain-submit
path."
  (or (and (boundp 'dsh-emacs--ml-busy) dsh-emacs--ml-busy)
      (when-let* ((session-id (dsh-emacs--active-session-id))
                  (session (dsh-emacs--chat-session-item session-id)))
        (dsh-protocol-session-running session))))

(defun dsh-emacs-interrupt-turn ()
  "Interrupt the running turn via `session/cancel'.

The server stops the agent mid-flight; the partial reply stays in the
transcript and `turn/end' arrives normally, which clears the spinner.
The pending-input queue is kept host-side: parked items stay parked
until the next wake (see `dsh-emacs-list-queue')."
  (let ((session-id (dsh-emacs--active-session-id)))
    (when (null session-id)
      (user-error "No session is open"))
    (dsh-emacs--rpc-async "session/cancel"
                          `((request . ((sessionId . ,session-id))))
                          (lambda (ok value)
                            (if ok
                                (progn
                                  ;; User-initiated stop: suppress the
                                  ;; finished-run notification.
                                  (setq dsh-emacs--turn-awaiting nil)
                                  (dsh-emacs--ml-busy-set nil)
                                  (message "⏸ Turn interrupted"))
                              (message "Failed to interrupt: %S" value))))))

(defun dsh-emacs-send-or-stop ()
  "Send the input as a message, or act on the running turn.

`!command' input runs locally before any server or busy-state checks.
When idle, the text after the `❯ ' prompt is submitted.  `C-u' explicitly
steers one nonempty message even if the local busy indicator has not caught up
with the host.  Otherwise, while a turn is executing (the mode-line spinner is
lit), the input is delivered per
`dsh-emacs-busy-enter-behavior': `queue' lines it up as the next turn,
`steer' wakes the running agent, `stop' issues `session/cancel' (the old
interrupt behavior).  With `queue'/`steer' and an EMPTY input the turn is
interrupted, so stopping stays one key away.  Success feedback arrives via the
`session/queue' stream; `\\[dsh-emacs-interrupt-turn]'
(`C-c C-b') interrupts regardless of the behavior."
  (interactive)
  (let ((input (dsh-emacs--get-input)))
    (if-let* ((command (dsh-emacs-shell-parse input)))
        (dsh-emacs-shell-submit input command)
      (dsh-emacs-server-ensure)
      (let ((busy (dsh-emacs--busy-p))
            (steer-p (consp current-prefix-arg))
            (empty-p (string-empty-p (string-trim input))))
        (cond
         ((and steer-p (not empty-p))
          (dsh-emacs--submit-prompt input nil 'steer))
         (busy
          (if (or empty-p (eq dsh-emacs-busy-enter-behavior 'stop))
              (dsh-emacs-interrupt-turn)
            (dsh-emacs--submit-prompt
             input nil dsh-emacs-busy-enter-behavior)))
         (empty-p (message "Please enter a message"))
         (t (dsh-emacs--submit-prompt input)))))))

(defun dsh-emacs--input-end ()
  "Return the end of editable input, before the mode-line separator newline."
  (let ((modeline-start (and (boundp 'dsh-emacs--modeline-overlay)
                             dsh-emacs--modeline-overlay
                             (overlay-start dsh-emacs--modeline-overlay))))
    (cond
     ;; Structural separator the input-area geometry relies on: the editable
     ;; input ends right at the `\n' the mode-line overlay follows.
     ((and modeline-start
           (> modeline-start (point-min))
           (eq (char-before modeline-start) ?\n))
      (1- modeline-start))
     ;; The mode-line overlay can be torn while its separator newline survives
     ;; (window follow / overlay churn around a split).  Falling back to
     ;; point-max here would treat the phantom display line BENEATH the input
     ;; as editable end, so `dsh-emacs--lock-cursor-to-input' could never pull
     ;; a cursor parked there back onto the input line — the "cursor stuck
     ;; under the input line until reopen" symptom.  Mirror the separator
     ;; case instead so below-positions still clamp onto the input line.
     ((and (not (bobp))
           (eq (char-before (point-max)) ?\n))
      (1- (point-max)))
     (t (point-max)))))

(declare-function dsh-emacs-reference--expanded-text "dsh-emacs-reference.el"
                  (start end))

(defun dsh-emacs--get-input ()
  "Get the text in the input area, excluding the mode-line newline.
Completed session @ chips are stored in the buffer as short `@label' text and
expanded back to their canonical mention by
`dsh-emacs-reference--expanded-text', so the returned text is always the wire
form; file references (`@path', no canonical property) and plain text pass
through unchanged."
  (when (and dsh-emacs--input-marker (marker-buffer dsh-emacs--input-marker))
    (dsh-emacs-reference--expanded-text
     dsh-emacs--input-marker (dsh-emacs--input-end))))

(defun dsh-emacs--clear-input ()
  "Clear the input area, keeping the mode-line newline."
  (when (and dsh-emacs--input-marker (marker-buffer dsh-emacs--input-marker))
    (let ((inhibit-read-only t))
      (delete-region dsh-emacs--input-marker (dsh-emacs--input-end))
      (goto-char dsh-emacs--input-marker))))


(defun dsh-emacs--valid-iana-time-zone-p (zone)
  "Return non-nil when ZONE names an installed IANA timezone."
  (and (stringp zone)
       (not (string-empty-p zone))
       (or (string= zone "UTC")
           (and (not (string-prefix-p "/" zone))
                (not (string-match-p "\\.\\." zone))
                (or (file-exists-p (expand-file-name zone "/usr/share/zoneinfo"))
                    (file-exists-p (expand-file-name zone
                                                      "/var/db/timezone/zoneinfo")))))))

(defun dsh-emacs--local-iana-time-zone ()
  "Return the IANA name linked by /etc/localtime, or nil."
  (condition-case nil
      (let ((localtime (file-truename "/etc/localtime")))
        (when (string-match "/zoneinfo/\\(.+\\)$" localtime)
          (match-string 1 localtime)))
    (error nil)))

(defun dsh-emacs--client-time-zone ()
  "Return a valid IANA timezone string for the prompt payload.
Abbreviations such as `CST' are deliberately rejected because they are
ambiguous and are not accepted by the dsh API."
  (let ((env-zone (getenv "TZ")))
    (cond
     ((dsh-emacs--valid-iana-time-zone-p env-zone) env-zone)
     ((let ((local-zone (dsh-emacs--local-iana-time-zone)))
        (when (dsh-emacs--valid-iana-time-zone-p local-zone)
          local-zone)))
     (t "UTC"))))

(defun dsh-emacs--input-history-record (list text)
  "Return LIST with TEXT recorded newest-first.
Drops TEXT when it repeats the newest entry and trims the result to
`dsh-emacs-input-history-length' entries.  LIST may be nil."
  (let ((list (if (string= text (car list)) list (cons text list)))
        (len dsh-emacs-input-history-length))
    (when (> (length list) len)
      (setcdr (nthcdr (1- len) list) nil))
    list))

(defun dsh-emacs--push-input-history (text)
  "Record TEXT in the input history, newest first.
Lands in the shared cross-session list and in the per-session list of the
buffer's session (see `dsh-emacs-input-history-cross-session'); both drop
consecutive repeats and trim to `dsh-emacs-input-history-length'."
  (when (and text (not (string-empty-p text)))
    (let* ((session-id (dsh-emacs--active-session-id))
           (own (gethash session-id dsh-emacs--input-history-by-session)))
      (setq dsh-emacs--input-history
            (dsh-emacs--input-history-record dsh-emacs--input-history text))
      (puthash session-id
               (dsh-emacs--input-history-record own text)
               dsh-emacs--input-history-by-session))))

(defun dsh-emacs--seed-input-history (events session-id &optional older)
  "Seed SESSION-ID's per-session `M-p' / `M-n' recall from EVENTS.
EVENTS is the [{event: ...}] history window; the texts of its
`user/message' events are recorded into that session's per-session list,
newest first.  First-entry recall would otherwise be empty — the
per-session list only holds prompts submitted in THIS Emacs run until the
session's earlier messages are backfilled here, on every history load
(open, refresh, backfill).  Texts already present are skipped, so
reloading the same window never duplicates entries; the shared
cross-session list is untouched.  With OLDER, append missing prompts behind
existing entries instead of treating the batch as a newer snapshot."
  (when (and events session-id)
    (let ((own (gethash session-id dsh-emacs--input-history-by-session))
          (missing nil))
      (dolist (entry (dsh-emacs--sequence-list events))
        (let* ((ev (and entry (dsh-emacs--alist-state entry "event")))
               (data (and ev (dsh-emacs--alist-state ev "data"))))
          (when (and data
                     (string= (dsh-emacs--alist-state ev "type")
                              "user/message"))
            (let ((text (mapconcat
                         #'identity
                         (delq nil
                               (mapcar
                                (lambda (block)
                                  (and (equal (dsh-emacs--alist-state block "type")
                                              "text")
                                       (dsh-emacs--alist-state block "text")))
                                (append (dsh-emacs--alist-state data "content")
                                        nil)))
                         "\n")))
              (when (and (not (string-empty-p text))
                         (not (member text own))
                         (not (member text missing)))
                (push text missing))))))
      (setq own (if older (append own missing) (append missing own)))
      (when (> (length own) dsh-emacs-input-history-length)
        (setcdr (nthcdr (1- dsh-emacs-input-history-length) own) nil))
      (puthash session-id own dsh-emacs--input-history-by-session))))

(defun dsh-emacs--submit-prompt (message &optional attachments mode)
  "Submit MESSAGE to the current session.

Non-nil MODE (\"queue\" or \"steer\") submits the message into a
RUNNING turn's inbox instead of starting one — the deferred path of
`dsh-emacs--submit-deferred', which neither renders a transcript card
nor touches the spinner.  With MODE nil while the session is already
busy (e.g. `C-c C-a' during a run), the configured
`dsh-emacs-busy-enter-behavior' picks the mode; with `stop' the deferred
path is never taken (`C-c C-c' interrupts then, attach-file keeps
sending a plain queue-mode prompt as before).

Lines without attachments starting with \"!<command>\" (e.g. \"!git status\") are
client-side shell commands (see `dsh-emacs-shell-submit'): they run
locally on this machine, independent of the session's busy state or
even the server, and NEVER reach the model or `commands.execute'.
When ATTACHMENTS is non-nil, a leading ! is ordinary caption text and
the attachments are sent to the model.
Slash-command lines (leading \"/name\") are routed to `commands.execute'
instead of the model: the host admits only registered commands, and an
admission miss falls back to sending the line as an ordinary message
(the same semantics as dsh web).  Other lines go through
`dsh-emacs--submit-plain' unchanged.  ATTACHMENTS, when given, is a list
of wire-ready attachment alists
\((mediaType . M) (data . B64) (name . N)); they are appended to the
`content' array of `session/prompt' as `{type: \"image\"}' parts so
the model sees them immediately."
  (let ((command (and (null attachments) (dsh-emacs-shell-parse message))))
    (cond
     ;; A `!' line with no attachments is a local action;
     ;; attachment captions do not go to the shell.
     (command
      (dsh-emacs-shell-submit message command))
     ((or mode
          (and (dsh-emacs--busy-p)
               (not (eq dsh-emacs-busy-enter-behavior 'stop))))
      (dsh-emacs--submit-deferred message attachments mode))
     ((dsh-emacs-command-parse message)
      (let ((session-id (dsh-emacs--active-session-id))
            (input-buffer (current-buffer)))
        ;; Clear the input and record it in history on submit —
        ;; without waiting for the RPC round trip (the same feel as
        ;; the web UI): whether the host admits the command is decided
        ;; by the `commands.execute' response, and the result is
        ;; rendered from the command/run + command/done session events.
        (dsh-emacs--push-input-history message)
        (setq dsh-emacs--input-history-pos nil
              dsh-emacs--input-history-pending nil)
        (when (buffer-live-p input-buffer)
          (with-current-buffer input-buffer
            (dsh-emacs--clear-input)))
        ;; Render the command line immediately (optimistic path) —
        ;; without waiting for the RPC round trip.
        (when (buffer-live-p input-buffer)
          (with-current-buffer input-buffer
            (dsh-emacs-render-command-optimistic message)))
        (dsh-emacs-command-execute
         session-id (string-trim message) attachments
         (lambda (ok execution err)
           ;; The callback may run inside a process filter: swallow C-g's quit.
           (condition-case nil
               (cond
                ((null ok)
                 ;; Transport failure (HTTP/parse error): clear the optimistic
                 ;; row and restore the original text.
                 (when (buffer-live-p input-buffer)
                   (with-current-buffer input-buffer
                     (dsh-emacs-render-command-cleanup-optimistic)
                     (when (string-empty-p
                            (or (dsh-emacs--get-input) ""))
                       (dsh-emacs--replace-input message))))
                 (message "Command failed to run: %S"
                          (or err "transport error")))
                ((null execution)
                 ;; Not in the registry → clear the optimistic row and send
                 ;; it as an ordinary message (browser semantics); history was
                 ;; already recorded at submit time, so do not record it again.
                 (when (buffer-live-p input-buffer)
                   (with-current-buffer input-buffer
                     (dsh-emacs-render-command-cleanup-optimistic)))
                 (dsh-emacs--submit-plain message attachments t))
                (t nil))        ; accepted: the command/run event replaces it
             (quit nil))))))
     (t (dsh-emacs--submit-plain message attachments)))))

(defun dsh-emacs--attachments-prompt-content (message attachments)
  "Return the `session/prompt' `content' array for MESSAGE and ATTACHMENTS.
Each attachment is a wire-ready alist \((mediaType . M) (data . B64)
(name? . N)); it becomes one `{type: \"image\"}' part after the leading
`{type: \"text\"}' part, so the model sees the caption first.  The same
parts feed the optimistic transcript echo."
  (vconcat `(((type . "text") (text . ,message)))
            (mapcar (lambda (attachment)
                      (cons '(type . "image") attachment))
                    attachments)))

(defun dsh-emacs--submit-deferred (message attachments mode)
  "Submit MESSAGE into the running turn's inbox as MODE.
MODE is `queue' (line up as the next turn) or `steer' (wake the running
agent before its next step); nil means resolve from
`dsh-emacs-busy-enter-behavior'.  The wire call is `session/prompt' with
the mode field.  Unlike `dsh-emacs--submit-plain' this renders NO
optimistic transcript card and does not touch the spinner: the item is
not part of the conversation until the host claims it (the durable
`user/message' event renders then), and the queue/steer feedback rides
the `session/queue' frame the host pushes on the splice.  IMAGES is the
same wire-ready attachment list `dsh-emacs--submit-prompt' takes; the
host admits images by the session's current model at claim time.  Slash
lines are NOT routed to `commands.execute' here — busy input is queued
as literal text, the same semantics as dsh web's busyEnter.
With nothing already pending in the mirror, the submit arms
`dsh-emacs-queue--mark-submit-suppress': the splice+claim transient of
this own message gets no `queued:' / `running:' echo (nothing to order
against); genuinely parked items keep their feedback."
  (let* ((mode (pcase mode
                 ((or 'queue 'steer) (symbol-name mode))
                 ('stop "queue")
                 (_ (symbol-name dsh-emacs-busy-enter-behavior))))
         (session-id (dsh-emacs--active-session-id))
         (input-buffer (current-buffer))
         (content (dsh-emacs--attachments-prompt-content message attachments))
         (payload `((request . ((requestId . ,(dsh-emacs--rpc-id))
                                (sessionId . ,session-id)
                                (mode . ,mode)
                                (content . ,content)
                                (clientTimeZone . ,(dsh-emacs--client-time-zone)))))))
    ;; Same web-style feel as the immediate path: the draft leaves the
    ;; input area and lands in history right away, before the RPC settles.
    (dsh-emacs--push-input-history message)
    (setq dsh-emacs--input-history-pos nil
          dsh-emacs--input-history-pending nil)
    (when (buffer-live-p input-buffer)
      (with-current-buffer input-buffer
        (dsh-emacs--clear-input)))
    ;; Queue-empty submit (busy or idle): the host still splices the message
    ;; into the inbox and claims it at the turn start; with nothing already
    ;; parked those frames do not carry any ordering information, so their
    ;; `queued:' / `running:' echoes are noise the submit path's own render
    ;; already covers (see `dsh-emacs-queue--mark-submit-suppress').
    (when (null (dsh-emacs-queue-items))
      (dsh-emacs-queue--mark-submit-suppress))
    ;; A queued message is real but its host `session/queue' frame is still a
    ;; round trip away; show it in the Next Message row now so the send does
    ;; not feel sticky.  The host's frame or the failure branch clears it.
    (dsh-emacs-queue--optimistic-submit-show message)
    (dsh-emacs--rpc-async "session/prompt" payload
                          (lambda (ok value)
                            (if ok
                                ;; Enqueue/steer feedback arrives via the
                                ;; `session/queue' frame diff — and the
                                ;; transcript shows the message when the
                                ;; host claims it (user/message).  Nothing
                                ;; to render here; the optimistic Next row is
                                ;; already up and is replaced by the host's
                                ;; own item.
                                nil
                              ;; A failed prompt never produces the
                              ;; splice/claim frames that would settle the
                              ;; suppression: clear it here (idempotent).
                              (dsh-emacs-queue--submit-suppress-clear)
                              (message "Failed to submit: %S" value)
                              ;; Nothing will consume the text, put it back
                              ;; (same restore as the command path).
                              (when (buffer-live-p input-buffer)
                                (with-current-buffer input-buffer
                                  (when (string-empty-p
                                         (or (dsh-emacs--get-input) ""))
                                    (dsh-emacs--replace-input message)))))))))

(defun dsh-emacs--submit-plain (message &optional attachments skip-history)
  "Submit MESSAGE (a plain string) to the current session.

ATTACHMENTS, when given, is a list of wire-ready attachment alists
\((mediaType . M) (data . B64) (name . N)); the canonical wire shape
is part of `content' (each becomes a `{type: \"image\"}' part) — there is
no top-level attachment field on `session/prompt'.
On acceptance the message is echoed into the transcript (when non-empty),
the running spinner lights up while the run is still awaited (a fast run
that already finished on the stream before the callback repeats must not
re-light it), and the watchdog starts.  Non-nil
SKIP-HISTORY suppresses the input-history push: used by the slash-command
fallback after the line was already recorded at submit time.
Submitting with an empty queue arms
`dsh-emacs-queue--mark-submit-suppress': the host's append+claim splice of
this prompt (the wire has no direct mode) is rendered directly and
silently, without the `queued:' / `running:' flashes.
The draft leaves the input area at submit time — the same web-style feel
as the command and deferred paths — so a second submit keypress during
the RPC round-trip reads an empty input instead of sending the message
twice; on a transport failure the draft is restored when the input is
still empty (a newer draft typed meanwhile is left alone)."
  (let* ((session-id (dsh-emacs--active-session-id))
         (chat-buffer (and (boundp 'dsh-emacs--buffer-session)
                           dsh-emacs--buffer-session
                           (current-buffer)))
         (input-buffer (current-buffer))
         (content (dsh-emacs--attachments-prompt-content message attachments))
         (payload `((request . ((requestId . ,(dsh-emacs--rpc-id))
                                (sessionId . ,session-id)
                                (mode . "queue")
                                (content . ,content)
                                (clientTimeZone . ,(dsh-emacs--client-time-zone))))))
         ;; This submit's own rollback record (nil for an empty message), kept
         ;; for the failure branch: the echo is tied to the submit that made it,
         ;; not re-found by text.
         (echo-entry nil))
    ;; Track the optimistic echo BEFORE the RPC round-trip: the mux may
    ;; deliver the canonical `user/message' at any moment — even before the
    ;; HTTP response is processed — and `dsh-emacs-render--consume-pending-user-message'
    ;; is the only dedup gate.  The entry must already exist when the event
    ;; arrives, or the echo and the canonical copy would both render.
    (when (buffer-live-p chat-buffer)
      (with-current-buffer chat-buffer
        ;; Register before the RPC round-trip: a fast run can end before its
        ;; prompt callback is processed.
        (setq dsh-emacs--turn-awaiting t)
        (unless (string-empty-p message)
          (setq dsh-emacs--pending-user-messages
                (append dsh-emacs--pending-user-messages (list message)))
          ;; Echo the message NOW, not in the response callback: the user
          ;; pressed C-c C-c and the input is about to clear, so the
          ;; transcript must show it without waiting for the HTTP round trip
          ;; (a rejected prompt rolls the echo back, see the failure branch).
          (setq echo-entry
                (dsh-emacs--render-user-message-optimistic
                 message attachments)))
        ;; A submit with an empty queue still passes through the host
        ;; inbox (the wire knows only queue/steer modes): the host splices
        ;; the message in and claims it again at the turn start, and the
        ;; mirror would diff those two frames into `queued:' / `running:'
        ;; echoes — the flash on sending a new message.  The message
        ;; itself is already on screen, so this transient should stay
        ;; silent.  Genuine queueing (items already parked) keeps its
        ;; feedback.
        (when (null (dsh-emacs-queue-items))
          (dsh-emacs-queue--mark-submit-suppress))))
    ;; Clear the input on submit (same feel as the
    ;; command/deferred paths): a second C-c C-c during the RPC
    ;; round trip then reads an empty input and never sends the
    ;; same message twice; the text is restored in the
    ;; transport-failure branch below.
    (when (buffer-live-p input-buffer)
      (with-current-buffer input-buffer
        (dsh-emacs--clear-input)))
    (dsh-emacs--rpc-async "session/prompt" payload
                          (lambda (ok value)
                            (if ok
                                (progn
                                  (unless skip-history
                                    (dsh-emacs--push-input-history message))
                                  (setq dsh-emacs--input-history-pos nil
                                        dsh-emacs--input-history-pending nil)
                                  ;; The echo is already on screen (rendered
                                  ;; optimistically at submit); the callback
                                  ;; only arms the live-follow state.
                                  (when (buffer-live-p chat-buffer)
                                    (with-current-buffer chat-buffer
                                      ;; The host accepted the prompt.  Light
                                      ;; the mode-line running spinner only
                                      ;; while the submitted run is still
                                      ;; awaited: a fast run can start AND end
                                      ;; on the mux before this HTTP callback
                                      ;; runs (the ordering the
                                      ;; `dsh-emacs--turn-awaiting'
                                      ;; pre-registration above exists for),
                                      ;; and re-lighting would leave the
                                      ;; spinner running past that `turn/end'.
                                      (when dsh-emacs--turn-awaiting
                                        (dsh-emacs--ml-busy-set t))
                                      ;; Confirm the stream keeps delivering
                                      ;; while this turn runs.
                                      (dsh-emacs-events--watchdog-start)
                                      (dsh-emacs-render--follow-stream)
                                      (unless dsh-emacs--event-ready
                                        ;; Self-heal when the stream is offline:
                                        ;; with no process at all, this session's
                                        ;; mux dropped and nobody reconnected
                                        ;; (opening a new session used to tear
                                        ;; down the previous one's stream — see
                                        ;; `dsh-emacs-open-session') — so
                                        ;; reconnect first, letting the "switches
                                        ;; back to realtime" promise hold; a
                                        ;; process mid-handshake is covered by
                                        ;; connect's health check, so do not
                                        ;; connect again here.
                                        (when (not (process-live-p
                                                    dsh-emacs--event-process))
                                          (dsh-emacs-events-connect
                                           (current-buffer)))))))
                              (message "Failed to send: %S" value)
                              ;; The server rejected the prompt, so no
                              ;; `user/message' will ever arrive to consume the
                              ;; optimistic entry; drop it, lest the same text
                              ;; sent again later swallow the real event.  Roll
                              ;; back this submit's OWN echo by entry identity
                              ;; (two in-flight copies of the same text are only
                              ;; distinguishable by their entries); a no-op once
                              ;; the canonical event consumed it, because
                              ;; `forget' then already retired the entry.
                              (when (buffer-live-p chat-buffer)
                                (with-current-buffer chat-buffer
                                  (setq dsh-emacs--turn-awaiting nil)
                                  (when echo-entry
                                    (dsh-emacs--discard-user-message-echo
                                     echo-entry))
                                  (setq dsh-emacs--pending-user-messages
                                        (delq message
                                              dsh-emacs--pending-user-messages))
                                  ;; A failed prompt never produces the
                                  ;; splice/claim frames that would settle
                                  ;; the suppression: clear it here
                                  ;; (idempotent).
                                  (dsh-emacs-queue--submit-suppress-clear)))
                              ;; The input was cleared on submit: on a
                              ;; transport failure put the draft back into
                              ;; the input area.  Restore only when the input
                              ;; is still empty — a newer draft typed during
                              ;; the RPC round trip is not overwritten
                              ;; (matching the failure restore in
                              ;; `dsh-emacs--submit-deferred').
                              (when (buffer-live-p input-buffer)
                                (with-current-buffer input-buffer
                                  (when (string-empty-p
                                         (or (dsh-emacs--get-input) ""))
                                    (dsh-emacs--replace-input message)))))))))

;;; ---------------------------------------------------------------------------
;;;  Attachments / model selection / input history
;;; ---------------------------------------------------------------------------

(defun dsh-emacs--file-attachment (file)
  "Read FILE into a wire-ready image attachment alist, or nil.

The dsh host accepts base64 image uploads inline in `session/prompt'
(media type, bytes and pixel limits are enforced server-side).  The
base64 is emitted without line breaks: the wire field is validated as
one continuous base64 run."
  (let* ((media (ignore-errors
                  (mailcap-file-name-to-mime-type
                   (file-name-nondirectory file))))
         (supported (and media (member media dsh-emacs-attach-media-types))))
    (when (and supported (file-readable-p file))
      (let ((bytes (with-temp-buffer
                     (set-buffer-multibyte nil)
                     (insert-file-contents-literally file)
                     (buffer-string))))
        (list (cons 'mediaType media)
              (cons 'data (base64-encode-string bytes t))
              (cons 'name (file-name-nondirectory file)))))))

;;;###autoload
(defun dsh-emacs-attach-file (&optional file caption)
  "Attach an image FILE to the current session and send it as a prompt.
CAPTION (or the file name) accompanies the image as the message text.
Only the media types in `dsh-emacs-attach-media-types' are sent."
  (interactive
   (list (read-file-name "Image to attach: " default-directory)
         (read-string "Caption (optional): ")))
  (dsh-emacs-server-ensure)
  (let ((attachment (dsh-emacs--file-attachment file)))
    (unless attachment
      (user-error "Unsupported or unreadable image: %s" file))
    (dsh-emacs--submit-prompt (if (string-empty-p caption)
                                  (file-name-nondirectory file)
                                caption)
                              (list attachment))))

(defun dsh-emacs--dnd-attach (event)
  "Handle a `drag-n-drop' EVENT in a chat buffer by attaching the files."
  (interactive "e")
  (dsh-emacs-server-ensure)
  (let* ((files (and (listp event) (nth 1 event)))
         (paths (and files
                     (delq nil (mapcar (lambda (f) (dnd-get-local-file-name f t))
                                       (if (listp files) files (list files)))))))
    (unless paths (user-error "No files in drop event"))
    (if (not (y-or-n-p (format "Attach %d file(s) to this session? "
                               (length paths))))
        (message "Attach cancelled")
      (let ((attachments (delq nil (mapcar #'dsh-emacs--file-attachment paths))))
        (if (null attachments)
            (message "No supported image files among the dropped files")
          (dsh-emacs--submit-prompt
           (if (= 1 (length attachments))
               (file-name-nondirectory (car paths))
             (format "%d images" (length attachments)))
           attachments))))))

(defun dsh-emacs--model-candidates (value)
  "Flatten a `session/modelCatalog' VALUE into per-model entries, sorted.

The list is sorted by provider display name then model id
(case-insensitive), so the model picker shows a stable, predictable
order regardless of the host's own group/model ordering.

Each entry is (ID PROVIDER PROVIDER-NAME NAME REASONING):
  ID            — the model id, sent as `session/selectModel' model.
  PROVIDER      — the owning group's id; the live host resolves
                  `current.provider' to exactly this value (the provider
                  `session/selectModel' expects for the model).
  PROVIDER-NAME — the group's display name (may equal PROVIDER).
  NAME          — the model's display name (may equal ID).
  REASONING     — the model's reasoning metadata
                  (a `dsh-protocol-reasoning' struct), or nil when the
                  model offers no reasoning-effort options.

VALUE is the raw `session/modelCatalog' (or legacy directory) response
alist — it is normalized to a `dsh-protocol-model-directory' struct
first, so all field access lives in dsh-emacs-protocol.el."
  (let* ((dir (dsh-protocol-model-directory--from-alist value))
         (groups (dsh-protocol-model-directory-groups dir)))
    (sort (cl-loop for g in groups
                   for provider = (dsh-protocol-provider-group-id g)
                   for provider-name = (or (dsh-protocol-provider-group-name g)
                                           provider)
                   append (cl-loop for m in (dsh-protocol-provider-group-models g)
                                   for id = (dsh-protocol-model-catalog-entry-id m)
                                   for name = (or (dsh-protocol-model-catalog-entry-name m)
                                                  id)
                                   for reasoning = (dsh-protocol-model-catalog-entry-reasoning m)
                                   collect (list id provider provider-name
                                                name reasoning)))
          (lambda (a b)
            (let ((pa (downcase (nth 2 a)))
                  (pb (downcase (nth 2 b)))
                  (ia (downcase (nth 0 a)))
                  (ib (downcase (nth 0 b))))
              (or (string-lessp pa pb)
                  (and (string= pa pb) (string-lessp ia ib))))))))

(defun dsh-emacs--model-effort-choices (reasoning)
  "Effort options of REASONING (a `dsh-protocol-reasoning' struct, or a
wire alist) as ((NAME . ID) ...), keeping the host's directory order for
display; entries without a display name fall back to their id.  Returns
nil when REASONING has no efforts."
  (setq reasoning (dsh-protocol--struct
                   #'dsh-protocol-reasoning-p
                   #'dsh-protocol-reasoning--from-alist
                   reasoning))
  (mapcar (lambda (e)
            (let ((id (dsh-protocol-effort-id e))
                  (name (or (dsh-protocol-effort-name e)
                            (dsh-protocol-effort-id e))))
              (cons name id)))
          (dsh-protocol-reasoning-efforts reasoning)))

(defun dsh-emacs--model-effort-default-id (reasoning &optional current-id)
  "The effort id to pre-select for a model with REASONING options.
CURRENT-ID wins when it is a valid option (the session already runs that
model at that effort); otherwise the model's `defaultEffort' when it is a
known option; otherwise the first effort in the directory."
  (setq reasoning (dsh-protocol--struct
                   #'dsh-protocol-reasoning-p
                   #'dsh-protocol-reasoning--from-alist
                   reasoning))
  (let* ((choices (dsh-emacs--model-effort-choices reasoning))
         (ids (mapcar #'cdr choices))
         (default (dsh-protocol-reasoning-default-effort reasoning)))
    (cond ((and current-id (member current-id ids)) current-id)
          ((member default ids) default)
          (ids (car ids))
          (t nil))))

(defun dsh-emacs--model-pick-effort (model choices default-id)
  "Read a reasoning-effort choice for MODEL from CHOICES ((NAME . ID) ...).
Returns the chosen effort id.  The choice whose id equals DEFAULT-ID is
passed as completing-read's DEF: vertico pre-selects it and an empty RET
takes it — re-picking the current model keeps its live effort, other
models default to their host-supplied default.  Signals quit on C-g, so
the caller can cancel the whole selection."
  (let* ((default-name (car (rassoc default-id choices)))
         (name (completing-read
                (if default-name
                    (format "Reasoning effort for %s (default %s): "
                            model default-name)
                  (format "Reasoning effort for %s: " model))
                choices nil t nil nil default-name)))
    (or (cdr (assoc name choices)) default-id)))

(defun dsh-emacs--model-row-entry (c dup)
  "One (KEY . C) completing-read entry for model tuple C.
KEY = \"id [provider|Provider Name]\" — the id first, so prefix
completion (default `completion-styles' match by prefix) hits when the
user types a model id; provider id and display name are embedded for
exact `assoc' and for searching by provider name — with a `display'
property rendering \"  id\" (or, when DUP non-nil — the same id is
offered by several providers — and no group headers are available,
\"  id (Provider Name)\" so duplicate-id rows stay distinguishable
after the group headers are dropped)."
  (let* ((id (nth 0 c))
         (provider (nth 1 c))
         (provider-name (nth 2 c))
         (shown (if dup
                    (format "  %s (%s)" id provider-name)
                  (format "  %s" id)))
         (key (propertize (format "%s [%s|%s]" id provider provider-name)
                          'display shown)))
    (cons key c)))

(defun dsh-emacs--model-key-parts (key)
  "Parse row KEY built by `dsh-emacs--model-row-entry' as
\"id [provider|Provider Name]\", returning (ID PROVIDER PROVIDER-NAME)
or nil when KEY is not a model row."
  (when (string-match "\\`\\([^ ]+\\) \\[\\([^]|]*\\)|\\([^]]*\\)\\]\\'" key)
    (list (match-string 1 key)
          (match-string 2 key)
          (match-string 3 key))))

(defun dsh-emacs--model-key-provider (key)
  "Provider id embedded in row KEY, or nil."
  (nth 1 (dsh-emacs--model-key-parts key)))

(defun dsh-emacs--model-entries (candidates)
  "Entries for completion UIs WITHOUT grouping support: provider shown
once as a bare header row, its models following, indented, each
showing the model id (the payload keeps the display NAME for
messages/the mode line) with payload = the candidate tuple
(ID PROVIDER PROVIDER-NAME NAME REASONING), where REASONING is the
host's `reasoning' alist (efforts + defaultEffort) or nil.  Rows are
(DISPLAY . PAYLOAD) conses, so a picked header is rejected by the
caller instead of being treated as a model.

The row KEY embeds the owning provider (\"id [provider|Provider
Name]\", id first so prefix filtering still matches) and a `display'
property renders the row: bare \"  id\" for unique ids, and
\"  m2 (Qwen)\" when an id collides across providers — because this
path's group headers are ordinary candidates and vanish from the
displayed list the moment the user types a query."
  (let ((entries '())
        (last-provider nil)
        (id-count (make-hash-table :test #'equal)))
    (dolist (c candidates)
      (let ((id (nth 0 c)))
        (puthash id (1+ (gethash id id-count 0)) id-count)))
    (dolist (c candidates (nreverse entries))
      (let* ((provider-name (nth 2 c))
             (dup (> (gethash (nth 0 c) id-count 0) 1)))
        (unless (equal provider-name last-provider)
          (push (cons provider-name (cons :header provider-name)) entries)
          (setq last-provider provider-name))
        (push (dsh-emacs--model-row-entry c dup) entries)))))

(defun dsh-emacs--model-grouped-collection (candidates)
  "Completion table with sticky group headers, returns (TABLE . ROWS).
For completion UIs that honour the `group-function' completion
metadata — modern vertico draws sticky group headers from it,
recomputing them on every filter input, and the Emacs 27+ *Completions*
buffer renders them too: rows are flat (no header-row candidates),
each KEY \"id [provider|Provider Name]\" rendered as bare \"  id\"
via the `display' property (id first so prefix completion still
matches while typing; provider name sits in the key, so substring
styles also find it), and the table metadata carries a
`group-function' mapping every key back to its provider display name.
The UI then paints one sticky group header per provider that stays
visible while any of its rows still matches the query — grouping is
NOT lost while searching."
  (let* ((rows (mapcar (lambda (c) (dsh-emacs--model-row-entry c nil))
                       candidates))
         (group-fn
          ;; Self-contained: parse the provider display name
          ;; straight from the key, capturing no variables.
          ;; The title must be a property-free string
          ;; (match-string keeps the candidate key's display
          ;; property).  The transform branch moves the match
          ;; highlight face over the id span to the matching
          ;; position in the display string: key = "m2
          ;; [g2|Qwen]" (display hides the rest); typing "m2"
          ;; makes orderless/basic put completion-match-face on
          ;; the key's first [0,2) — spreading the whole key
          ;; through vertico--display-string would paint the
          ;; entire line background, and stripping every
          ;; property loses the highlight; the right move is to
          ;; embed a face-carrying substring into the visible
          ;; "  " + id text
          (lambda (cand transform)
            (if transform
                (let* ((c (copy-sequence cand))
                       (id (car (dsh-emacs--model-key-parts cand))))
                  (if (and id (> (length id) 0))
                      (let ((sub (substring c 0 (length id))))
                        ;; The substring drops display/invisible (properties
                        ;; of the hidden part) while keeping face.
                        (remove-text-properties
                         0 (length sub) '(display nil invisible nil) sub)
                        sub)
                    c))
              (let ((parts (dsh-emacs--model-key-parts cand)))
                (and parts (substring-no-properties (nth 2 parts)))))))
         (table (dsh-emacs--completion-table-with-metadata
                 rows
                 ;; Emacs 31's completion-table-with-metadata wants
                 ;; the metadata without the (metadata ...) prefix —
                 ;; give it the plist directly and it wraps it itself.
                 ;; (category . dsh-model): nerd-icons-completion
                 ;; inserts an icon at the start of every candidate
                 ;; row — in its icon table the nil category maps to
                 ;; nf-cod-arrow_small_right (the "->" arrow at line
                 ;; start) while categories absent from the table
                 ;; return an empty string; declaring a private
                 ;; category keeps the row start icon-free (and
                 ;; marginalia injects no suffix annotation either,
                 ;; because the category is not in its annotator
                 ;; table).
                 ;; An identity affixation-function is the last
                 ;; backstop: a third-party package trying to append
                 ;; an annotation/affixation suffix is overridden too
                 (list (cons 'category 'dsh-model)
                       (cons 'group-function group-fn)
                       (cons 'affixation-function
                             (lambda (cands)
                               (mapcar (lambda (c) (list c "" "")) cands)))))))
    (cons table rows)))

;; Model picker row-start icon (optional integration, no new
;; dependency): the picker metadata declares category=dsh-model;
;; once nerd-icons-completion is loaded, register a default chip
;; icon (nf-cod-chip) for that category — it shows at the row
;; start with no user configuration.  To change the icon,
;; add-to-list a same-category entry in your own config first and
;; it overrides the default (the default registration is skipped
;; when assq already finds one).  No effect when
;; nerd-icons-completion is not installed.
(with-eval-after-load 'nerd-icons-completion
  (when (and (boundp 'nerd-icons-completion-category-icons)
             (not (assq 'dsh-model nerd-icons-completion-category-icons)))
    (add-to-list 'nerd-icons-completion-category-icons
                 '(dsh-model . (nerd-icons-codicon "nf-cod-chip" nerd-icons-blue)))))

(defun dsh-emacs--model-select-setup-hook (grouped)
  "Buffer-local tweaks for the model picker's minibuffer.
GROUPED says whether vertico's native group-function rendering is
active (see the detection in `dsh-emacs--select-model-prompt').
Sorting and preselect are tamed locally so the provider order and the
cursor position stay put; when GROUPED, `vertico-group-format' is
overridden buffer-locally by `dsh-emacs-model-group-format' (killing
the stock long separator lines inside the picker only)."
  (when (boundp 'vertico-sort-function)
    (setq-local vertico-sort-function nil))
  (when (boundp 'vertico-sort-override-function)
    (setq-local vertico-sort-override-function nil))
  (when (boundp 'vertico-preselect)
    (setq-local vertico-preselect 'first))
  (when (and grouped (boundp 'vertico-group-format))
    (setq-local vertico-group-format dsh-emacs-model-group-format))
  ;; Return nil explicitly: Emacs 31's minibuffer-with-setup-hook
  ;; funcalls the evaluation result of the SETUP expression, so
  ;; never let another value flow back (such as the setq-local
  ;; value above — that would become "Invalid function: ...")
  nil)

;;;###autoload
(defun dsh-emacs-select-model ()
  "Choose a model for the current session from the live model catalog.
Lists the models the host can route to (`session/modelCatalog'), shows each
under its provider as its id, reads one with `completing-read'
and switches via `session/selectModel'.  Each row's key carries its
provider (hidden from display), and the provider display name is part
of the key too, so provider names stay searchable while filtering.
Modern vertico draws sticky provider group headers from the table's
`group-function' metadata (an Emacs 27+ *Completions* buffer does the
same), kept while any row of the group matches the query; without a
group-aware UI, header rows plus a per-row provider suffix on
colliding ids are shown.  The mode-line model segment updates
immediately."
  (interactive)
  (dsh-emacs-server-ensure)
  (let ((session-id (dsh-emacs--active-session-id)))
    (unless session-id (user-error "Open or select a session first"))
    ;; `session/modelCatalog' is session-agnostic (args {}), so its only
    ;; "current"-ish value is the host `default'.  The session's real
    ;; running model lives in the cached row's `modelSelection' projection
    ;; (`lastUsed'), and is resolved inside `dsh-emacs--select-model-prompt'
    ;; (falling back to the catalog default only when the row has none yet).
    (dsh-emacs--rpc-async "session/modelCatalog" nil
                          (lambda (ok value)
                            (if (not ok)
                                (message "Failed to list models: %S" value)
                              (dsh-emacs--select-model-prompt
                               session-id value))))))

(defun dsh-emacs--select-model-prompt (session-id value)
  "Read a model choice for SESSION-ID from a `session/modelCatalog' VALUE.
Each candidate is a provider header or an indented model row showing
the model id; the provider
actually sent to `session/selectModel' is the owning group's id (the host
resolves `current.provider' to exactly that).  Row keys carry the
provider hidden behind a `display' property, so `assoc' always resolves
to the row the user picked, even when the same id is offered by
several providers.

Two display paths: with `vertico-group-mode' active (Emacs 27+
`*Completions*' buffers group too), candidates are flat rows and a
`group-function' metadata keeps one sticky header per provider while
the user filters — grouping survives searching.  In completion UIs
without grouping support, provider headers are ordinary candidates
(dropped by filtering) and colliding ids fall back to a visible
provider suffix on their rows.

When the chosen model declares reasoning-effort options (`reasoning'),
a second reader asks for the effort: re-picking the current model
pre-selects its live `reasoningEffort', other models pre-select their
`defaultEffort', and the id is sent as `session/selectModel'
`reasoningEffort'.  The \"current model\" is the session's real running
model from its cached `modelSelection' projection (`lastUsed') — the same
authoritative source the mode-line uses — and only falls back to the
catalog host `default' when the session row carries no projection yet
(a session just created, or never yet run).  Models without reasoning
options send no effort field at all.

No completing-read default is passed on purpose: vertico moves the default
row to the top of the candidate list, which would pull the current model
out of its provider group.  Instead an empty RET keeps the current model
(no RPC at all) and unknown input is rejected against the entry table.
A vertico preselect nudge (vertico-nudge.el) is available but not wired;
without it the highlight starts on the first row and the user navigates
manually.

Runs inside the async RPC callback (a process filter), so C-g during
`completing-read' is caught here; otherwise the `quit' would leak out of
the filter as \"error in process filter: Quit\"."
  (condition-case nil
      (let* ((dir (dsh-protocol-model-directory--from-alist value))
             ;; The reference model: the session's live `modelSelection'
             ;; projection when present, else the catalog host default
             ;; (folded into `dsh-protocol-model-directory-current').
             (current (or (dsh-emacs--session-model-selection session-id)
                          (dsh-protocol-model-directory-current dir)))
             (current-model (and current
                                 (dsh-protocol-model-selection-model current)))
             ;; Same-model-id-across-providers disambiguation in the prompt:
             ;; prefix the current model with its owning provider id, matching
             ;; the mode-line/tooltip convention (the provider is only shown
             ;; when the session row knows it).
             (current-provider (and current
                                    (dsh-protocol-model-selection-provider current)))
             (candidates (dsh-emacs--model-candidates value))
             ;; The prompt's provider must match the picker's group headers,
             ;; which show the provider DISPLAY name, not its id.  Resolve the
             ;; current provider id to the display name from the catalog (the
             ;; first row of that provider carries it); a current provider
             ;; missing from the catalog falls back to its id.
             (current-provider-label
              (or (and current-provider
                       (cl-some (lambda (c)
                                  (and (equal (nth 1 c) current-provider)
                                       (nth 2 c)))
                                candidates))
                  current-provider))
             ;; Modern vertico (>=2.0) natively supports group-function
             ;; metadata: it recomputes groups and redraws sticky group
             ;; headers on every input (no vertico-group.el/group-mode)
             ;; → take the metadata grouping path; otherwise fall back
             ;; to candidate header rows + suffixes on duplicate rows
             ;; (header rows get filtered out).  Old vertico +
             ;; vertico-group use the same protocol.
             (grouped (and (bound-and-true-p vertico-mode)
                           (or (boundp 'vertico--groups)
                               (boundp 'vertico-group--groups))))
             (grouped-pair (and grouped
                                (dsh-emacs--model-grouped-collection
                                 candidates)))
             ;; Provider header row + indented model rows (header
             ;; payload is (:header . NAME))
             (entries (if grouped (cdr grouped-pair)
                        (dsh-emacs--model-entries candidates)))
             (collection (if grouped (car grouped-pair) entries))
             (picked (minibuffer-with-setup-hook
                         ;; Locally disable vertico's sorting inside the model
                         ;; picker (so candidates are not reordered) and set the
                         ;; fallback preselect to the first row (vertico preselect
                         ;; supports only prompt/first).  Must be an expression
                         ;; evaluating to a function object: Emacs 31's macro does
                         ;; (funcall (eval SETUP)), and passing a function call
                         ;; directly makes it call the return value (see
                         ;; dsh-emacs--model-select-setup-hook).
                         (lambda () (dsh-emacs--model-select-setup-hook grouped))
                         ;; No DEF: vertico moves the default to the front of the
                         ;; list, which would pull the current model out of its
                         ;; group and pin it to the first row forever.  An empty
                         ;; RET is handled by the "" branch below (keep the
                         ;; current model); garbage input is caught by the assoc
                         ;; check.
                          (completing-read
                           (format "Select model%s: "
                                   (if current-model
                                       (format " (current %s)"
                                               (if (and current-provider-label
                                                        (not (string-empty-p
                                                              current-provider-label)))
                                                   (concat current-provider-label "/"
                                                           current-model)
                                                 current-model))
                                     ""))
                           collection nil nil nil nil nil)))
             (empty (not (and picked (stringp picked)
                              (not (string-empty-p picked))))))
        (cond
         (empty
          (message (if current-model
                       (format "Kept current model %s" current-model)
                     "Kept the current model")))
         ((not (assoc picked entries))
          (message "Unknown model: %s" picked))
         ;; A provider header row (not a model) was picked →
         ;; message and do not switch
         ((eq :header (car (cdr (assoc picked entries))))
          (message "That is a provider header — pick a model below it"))
         (t
          (let* ((chosen (cdr (assoc picked entries)))
                 (model (nth 0 chosen))
                 (provider (nth 1 chosen))
                 (reasoning (nth 4 chosen))
                 ;; Second layer: ask for effort only when the target
                 ;; model declares reasoning options.  Re-picking the
                 ;; current model → keep its live reasoningEffort; other
                 ;; models → the catalog defaultEffort (or the first one).
                 ;; RET/the vertico preselect takes the default; C-g
                 ;; bubbles to the outer handler for a uniform "cancel".
                 (effort-id (and reasoning
                                 (dsh-emacs--model-pick-effort
                                  model
                                  (dsh-emacs--model-effort-choices reasoning)
                                  (dsh-emacs--model-effort-default-id
                                   reasoning
                                   (and (equal model current-model)
                                        (dsh-protocol-model-selection-reasoning-effort
                                         current)))))))
            (dsh-emacs--rpc-async "session/selectModel"
              `((request . ((sessionId . ,session-id)
                            (provider . ,provider)
                            (model . ,model)
                            ,@(and effort-id `((reasoningEffort . ,effort-id))))))
              (lambda (ok2 value2)
                (if ok2
                    (progn
                      (dsh-emacs-modeline-set-model model)
                      ;; The chosen row carries its provider: for the same
                      ;; id across providers, the mode-line model segment
                      ;; uses it to disambiguate (shown in the tooltip).
                      (dsh-emacs-modeline-set-provider provider)
                      (dsh-emacs-modeline-set-effort effort-id)
                      ;; Refresh the session list right after the model switch:
                      ;; the old model's contextPressure snapshot is no longer
                      ;; trustworthy, so fetch the same projection snapshot for
                      ;; the new model (the mode-line ctx% pressure+window pair
                      ;; updates together).  Go straight through the internal
                      ;; fetch (pure RPC), not server-start/event recovery.
                      (dsh-emacs-list-sessions--fetch)
                      (message "Model switched to %s (%s)%s"
                               (nth 3 chosen) (nth 2 chosen)
                               (if effort-id
                                   (format ", effort %s" effort-id)
                                 "")))
                  (message "Failed to switch model: %S" value2))))))))
    (quit (message "Model selection cancelled"))))

;;;###autoload
(defun dsh-emacs-set-permission ()
  "Choose a permission preset for the current session.
Reads the process-level `permissionPresets/catalog' (dsh 0.1.6; the
`permissions' session projection carries only the current value) and
switches through the `/permission' slash command — the namespace's only
write path — so the recorded `permission/preset' event drives the
mode-line `permission' segment exactly as it does for any other client.
The derived `custom' state is never offered: it is what the projection
reports when the effective knobs match no preset, not a switch target."
  (interactive)
  (dsh-emacs-server-ensure)
  (let ((session-id (dsh-emacs--active-session-id)))
    (unless session-id (user-error "Open or select a session first"))
    (dsh-emacs--rpc-async
     "permissionPresets/catalog" nil
     (lambda (ok value)
       (if (not ok)
           (message "Failed to list permission presets: %S" value)
         (dsh-emacs--set-permission-prompt session-id value))))))

(defun dsh-emacs--set-permission-prompt (session-id value)
  "Read and apply a permission preset for SESSION-ID from catalog VALUE.
VALUE is the `permissionPresets/catalog' wire value; each option's label
and description come from the host so the picker matches dsh web.  Runs
inside the async RPC callback (a process filter), so a C-g during
`completing-read' is caught here instead of leaking out of the filter."
  (condition-case nil
      (let* ((catalog (dsh-protocol-permission-catalog--from-alist value))
             (entries
              (mapcar
               (lambda (option)
                 (let ((name (or (dsh-protocol-permission-option-name option)
                                 (dsh-protocol-permission-option-value option)))
                       (description (dsh-protocol-permission-option-description option)))
                   (cons (if (and (stringp description)
                                  (not (string-empty-p description)))
                             (format "%-20s  %s" name description)
                           name)
                         (dsh-protocol-permission-option-value option))))
               (dsh-protocol-permission-catalog-options catalog))))
        (if (not entries)
            (message "No permission preset available")
          (let ((picked (cdr (assoc (completing-read "Permission preset: "
                                                     entries nil t)
                                    entries))))
            (when picked
              (dsh-emacs-command-execute
               session-id (concat "/permission " picked) nil
               (lambda (ok execution err)
                 (cond
                  ((null ok)
                   (message "Permission switch failed: %S"
                            (or err "transport error")))
                  ((null execution)
                   (message "The host did not admit /permission"))
                  (t
                   (message "%s"
                            (or (dsh-protocol-command-execution-text execution)
                                (if (equal "success"
                                           (dsh-protocol-command-execution-kind
                                            execution))
                                    "Permission updated"
                                  "Permission not changed")))))))))))
    (quit (message "Permission selection cancelled"))))

(defun dsh-emacs--replace-input (text)
  "Replace the input area of the current buffer with TEXT and park point."
  (when (and dsh-emacs--input-marker (marker-buffer dsh-emacs--input-marker))
    (let ((inhibit-read-only t))
      (delete-region dsh-emacs--input-marker (dsh-emacs--input-end))
      (goto-char dsh-emacs--input-marker)
      (insert text)
      (goto-char (dsh-emacs--input-end)))))

(defun dsh-emacs--input-history-active ()
  "Return the prompt-history list `M-p' / `M-n' currently browse.
Cross-session mode (`dsh-emacs-input-history-cross-session' non-nil)
returns the shared global list; per-session mode returns the current
session's own list (nil when the session recorded no prompts yet)."
  (if dsh-emacs-input-history-cross-session
      dsh-emacs--input-history
    (let ((session-id (dsh-emacs--active-session-id)))
      (and session-id
           (gethash session-id dsh-emacs--input-history-by-session)))))

(defun dsh-emacs-input-history-back ()
  "Show the previous submitted prompt in the input area (M-p).
Browses the shared cross-session history, or the current session's own
prompts when `dsh-emacs-input-history-cross-session' is nil."
  (interactive)
  (let* ((history (dsh-emacs--input-history-active))
         (len (length history)))
    (cond
     ((zerop len) (message "No input history"))
     ((null dsh-emacs--input-history-pos)
      (setq-local dsh-emacs--input-history-pending (dsh-emacs--get-input))
      (setq-local dsh-emacs--input-history-pos 0)
      (dsh-emacs--replace-input (nth 0 history)))
     ((>= (1+ dsh-emacs--input-history-pos) len)
      (message "Beginning of history"))
     (t (setq-local dsh-emacs--input-history-pos
                   (1+ dsh-emacs--input-history-pos))
        (dsh-emacs--replace-input
         (nth dsh-emacs--input-history-pos history))))))

(defun dsh-emacs-input-history-forward ()
  "Show the next submitted prompt, or restore the typed text (M-n)."
  (interactive)
  (cond
   ((null dsh-emacs--input-history-pos)
    (message "No newer history"))
   ((zerop dsh-emacs--input-history-pos)
    (dsh-emacs--replace-input dsh-emacs--input-history-pending)
    (setq-local dsh-emacs--input-history-pos nil)
    (setq-local dsh-emacs--input-history-pending nil))
   (t (setq-local dsh-emacs--input-history-pos
                 (1- dsh-emacs--input-history-pos))
      (dsh-emacs--replace-input
       (nth dsh-emacs--input-history-pos
            (dsh-emacs--input-history-active))))))

(defun dsh-emacs--render-user-message-optimistic (message attachments)
  "Render MESSAGE's transcript echo immediately, before its RPC settles.
ATTACHMENTS is a list of wire-ready attachment alists; they become
`{type: \"image\"}' content blocks so the renderer displays them inline
immediately — the bytes are already local, no `session/attachment'
round-trip is needed.  The inserted region is recorded in
`dsh-emacs--pending-user-echoes' so
`dsh-emacs--discard-user-message-echo' can roll it back when the submit is
rejected."
  (let* ((event `((type . "user/message")
                  (data . ((content . ,(dsh-emacs--attachments-prompt-content
                                        message attachments))))))
         (region (dsh-emacs-render--insert-user-block event nil)))
    (when region
      (let ((entry (cons message
                         (cons (copy-marker (car region))
                               (copy-marker
                                (save-excursion
                                  (goto-char (cdr region))
                                  (skip-chars-forward "\n")
                                  (point)))))))
        (setq dsh-emacs--pending-user-echoes
              (append dsh-emacs--pending-user-echoes (list entry)))
        entry))))

(defun dsh-emacs--forget-user-message-echo (message)
  "Drop MESSAGE's rollback entry, leaving its optimistic echo on screen.
Called when the canonical `user/message' consumes the pending text: the echo
is now the accepted message and must never be rolled back."
  (let ((entry (assoc message dsh-emacs--pending-user-echoes)))
    (when entry
      (setq dsh-emacs--pending-user-echoes
            (delete entry dsh-emacs--pending-user-echoes))
      (when (markerp (car (cdr entry))) (set-marker (car (cdr entry)) nil))
      (when (markerp (cdr (cdr entry))) (set-marker (cdr (cdr entry)) nil)))))

(defun dsh-emacs--discard-user-message-echo (entry)
  "Delete optimistic echo ENTRY and drop its rollback record.
ENTRY is one `dsh-emacs--pending-user-echoes' item as returned by
`dsh-emacs--render-user-message-optimistic'.  Deleting by ENTRY keeps the
rollback tied to the submit that owns it: two in-flight submits of the same
text are only distinguishable by their entries, not by their text.  No-op when
the entry was already consumed by its canonical `user/message' — `forget' then
removed it from the list and cleared its markers."
  (setq dsh-emacs--pending-user-echoes
        (delq entry dsh-emacs--pending-user-echoes))
  (let ((start (car (cdr entry)))
        (end (cdr (cdr entry))))
    (when (and (markerp start) (markerp end)
               (marker-buffer start) (marker-buffer end))
      (with-current-buffer (marker-buffer start)
        (let ((inhibit-read-only t))
          (delete-region start end))))
    (when (markerp start) (set-marker start nil))
    (when (markerp end) (set-marker end nil))))

(defvar-local dsh-emacs--history-loading nil
  "Non-nil while a `session/page' request for this buffer is in flight.
Blocks a second load-more before the first page lands.")

(defun dsh-emacs--history-record-list (records)
  "Return RECORDS, a `session/page' or snapshot record vector, as a list."
  (cond ((vectorp records) (append records nil))
        ((listp records) records)
        (t nil)))

(defun dsh-emacs--history-oldest-seq (entries)
  "Return the oldest event seq in ENTRIES, or nil.
ENTRIES is a `session/page' batch of message-aligned records in ascending
seq order, so the first event carrying a numeric seq is the exclusive
`beforeSeq' cursor for the next page."
  (catch 'found
    (dolist (entry entries)
      (let* ((ev (and entry (dsh-emacs-render--aget "event" entry)))
             (seq (and ev (dsh-emacs-render--event-seq ev))))
        (when (integerp seq)
          (throw 'found seq))))))

(defun dsh-emacs--load-older-history-page (buffer page-value)
  "Prepend one older history page, described by PAGE-VALUE, to BUFFER.
Runs as the `session/page' callback: renders the page above the currently
loaded transcript, keeps the loaded window viewport in place, extends the
pagination frontier, and seeds `M-p' recall from the page's user messages."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq dsh-emacs--history-loading nil)
      (let* ((entries (delq nil
                            (mapcar (lambda (record)
                                      (and (equal (dsh-emacs-render--aget
                                                   "type" record)
                                                  "event")
                                           record))
                                    (dsh-emacs--history-record-list
                                     (dsh-emacs-render--aget "records"
                                                             page-value)))))
             (rendered 0)
             (cursor (dsh-emacs--history-oldest-seq entries)))
        (when (and entries (integerp cursor))
          ;; The prepend marker must exist before the first render: every
          ;; renderer resolves its insertion position through it.  The page
          ;; sits below the live frontier, and the renderer leaves
          ;; `dsh-emacs--anchor-seq' alone for a prepend, so a live frame
          ;; cannot replay the loaded page.
          (setq dsh-emacs--history-insert-marker
                (dsh-emacs-render--history-prepend-marker))
          (unwind-protect
              (save-window-excursion
                ;; Bind the page flag around the render: it is what tells the
                ;; renderers this batch is settled history (the insertion
                ;; marker is positional and may legitimately be nil).
                (let ((dsh-emacs--history-page t))
                  (setq rendered
                        (dsh-emacs-render-history-events
                         entries nil dsh-emacs--history-earliest-seq
                         :insert-before
                         (and dsh-emacs--history-insert-marker
                              (marker-position dsh-emacs--history-insert-marker))
                         :follow-p nil))))
            (when (markerp dsh-emacs--history-insert-marker)
              (set-marker dsh-emacs--history-insert-marker nil))
            (setq dsh-emacs--history-insert-marker nil)))
        (if (and entries (integerp cursor))
            (progn
              (setq dsh-emacs--history-earliest-seq cursor)
              (setq dsh-emacs--history-has-more
                    (dsh-emacs-render--json-boolean
                     (dsh-emacs-render--aget "hasMore" page-value)))
              (when (fboundp 'dsh-emacs--seed-input-history)
                (dsh-emacs--seed-input-history
                 entries (or dsh-emacs--buffer-session
                             (dsh-emacs--active-session-id)) t))
              (message "Loaded %d older message%s%s"
                       rendered (if (= rendered 1) "" "s")
                       (if dsh-emacs--history-has-more " (more available)" "")))
          (setq dsh-emacs--history-has-more nil)
          (message "No older messages remain"))))))

(defun dsh-emacs-load-older-history ()
  "Load the next older page of this session's history into the transcript.
Reads one `session/page' window (`dsh-emacs-history-window' messages) before
the earliest event currently rendered and inserts it above the existing
transcript, keeping the visible text where it was.  `dsh-emacs--anchor-seq'
stays on the live frontier, so a reconnect's snapshot cannot replay the
newly loaded page.  The server's `hasMore' flag stops the command at the
beginning of the session."
  (interactive)
  (cond
   ((not (and (boundp 'dsh-emacs--buffer-session)
              dsh-emacs--buffer-session))
    (user-error "Older history is only available inside a chat buffer"))
   ((not (and (boundp 'dsh-emacs--input-marker)
              (markerp dsh-emacs--input-marker)))
    (message "This chat buffer has no transcript to extend"))
   (dsh-emacs--history-loading
    (message "Already loading older messages…"))
   ((null dsh-emacs--history-earliest-seq)
    (message "No earlier history is known for this session yet"))
   ((not dsh-emacs--history-has-more)
    (message "No older messages remain"))
   ((null dsh-emacs--history-cursor)
    (message "This session has no history cursor yet"))
   (t
    (setq dsh-emacs--history-loading t)
    (let ((session-id dsh-emacs--buffer-session)
          (before dsh-emacs--history-earliest-seq)
          (through dsh-emacs--history-cursor)
          (limit dsh-emacs-history-window)
          (buffer (current-buffer)))
      (message "Loading older messages…")
      (dsh-emacs--rpc-async
       "session/page"
       `((request . ((address . ((kind . "session")
                                 (sessionId . ,session-id)))
                     ;; `throughSeq' must be a real seq: the wire's -1 reads an
                     ;; empty page because the server slices
                     ;; events[0 .. min(throughSeq + 1, beforeSeq)).
                     (throughSeq . ,through)
                     (beforeSeq . ,before)
                     (maxMessages . ,limit))))
       (lambda (ok value)
         (if (and ok (listp value))
             (dsh-emacs--load-older-history-page buffer value)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (setq dsh-emacs--history-loading nil)))
           (message "Failed to load older messages: %S" value))))))))

(defun dsh-emacs-refresh ()
  "Refresh the current chat buffer's event stream.
Only meaningful inside a chat buffer: the stream must belong to the
buffer-local session's own buffer.  Refreshing tears the `session/follow'
connection down and reconnects, so the fresh snapshot reseeds whatever
the previous stream missed (records carry original seqs; the
`dsh-emacs--anchor-seq' gate renders only what is new).  Outside a chat
buffer this refuses with a message instead of touching an unrelated
buffer (the old global `dsh-emacs--current-buffer' target hid that bug by
always pointing at the last-opened chat buffer, which mixed sessions)."
  (interactive)
  (dsh-emacs-server-ensure)
  (cond
   ((and (boundp 'dsh-emacs--buffer-session) dsh-emacs--buffer-session)
    (dsh-emacs-events-disconnect)
    (dsh-emacs-events-connect (current-buffer)))
   ((dsh-emacs--active-session-id)
    (message "Refresh works inside a chat buffer (last session: %s)"
             (dsh-emacs--active-session-id)))
   (t
    (message "No session to refresh"))))

(defun dsh-emacs-list-sessions-display ()
  "Display the session list buffer."
  (interactive)
  (dsh-emacs-list-sessions)
  (let ((buf (get-buffer-create dsh-emacs-sessions-buffer)))
    (with-current-buffer buf
      (dsh-emacs-session-mode))
    (pop-to-buffer buf)))

(defun dsh-emacs--code-block-region-at (pos)
  "Return (START . END) of the source-block body containing POS, or nil.
The renderer tags every fenced-block body with the text property
`dsh-emacs-markdown-source-block-body'; the label above the block is not
part of the body (RET on the label already copies there)."
  (let ((prop 'dsh-emacs-markdown-source-block-body))
    (save-excursion
      (goto-char (point-min))
      (catch 'found
        (while (<= (point) (point-max))
          (let ((start (if (get-text-property (point) prop)
                           (point)
                         (next-single-property-change (point) prop nil
                                                      (point-max)))))
            ;; `next-single-property-change' returns its LIMIT, not nil, when
            ;; the property never occurs; treat that as "no block left" or the
            ;; loop below spins forever at `point-max'.
            (if (or (null start) (>= start (point-max)))
                (throw 'found nil)
              (let ((end (or (next-single-property-change start prop nil
                                                          (point-max))
                             (point-max))))
                (cond
                 ((<= start pos)
                  ;; REGION starts at/before POS: inside when POS < END,
                  ;; otherwise move past it and keep scanning.
                  (if (< pos end)
                      (throw 'found (cons start end))
                    (goto-char end)))
                 (t
                  ;; First region found starts after POS: POS is not inside
                  ;; any block; no later region can contain it either.
                  (throw 'found nil)))))))))))

;;;###autoload
(defun dsh-emacs-copy-code-block ()
  "Copy the source-code block containing point to the kill ring.
Point may be anywhere inside a rendered fenced block; the block face and
`dsh-emacs-markdown-source-block-body' tag survive even after a propertized
copy into another buffer (e.g. an image viewport)."
  (interactive)
  (let* ((region (dsh-emacs--code-block-region-at (point)))
         (text (and region
                    (buffer-substring-no-properties (car region) (cdr region)))))
    (if text
        (progn (kill-new text) (message "Copied code block"))
      (user-error "Point is not inside a code block"))))

(defun dsh-emacs--assistant-message-region-at (pos)
  "Return (START . END) of the assistant message body at POS, or nil.
POS counts as inside when it carries the `dsh-emacs-assistant-message'
property, or sits on whitespace immediately after such a body (a message's
trailing separator carries no identity of its own)."
  (let* ((prop 'dsh-emacs-assistant-message)
         (at (cond
              ((get-text-property pos prop) pos)
              ((and (> pos (point-min))
                    (memq (char-after pos) '(?\s ?\t ?\n))
                    (get-text-property (1- pos) prop))
               (1- pos)))))
    (when at
      (cons (or (previous-single-property-change (1+ at) prop nil (point-min))
                (point-min))
            (or (next-single-property-change at prop nil (point-max))
                (point-max))))))

(defun dsh-emacs--assistant-message-bodies ()
  "Return the chat transcript's assistant message bodies, in order.
Bodies are located by the `dsh-emacs-assistant-message' text property, so
user prompts, tool cards, thinking blocks and the rest of the transcript
chrome stay out.  Each body is trimmed; empty ones are dropped."
  (let ((prop 'dsh-emacs-assistant-message)
        (pos (point-min))
        bodies)
    (while (< pos (point-max))
      (let ((start (if (get-text-property pos prop)
                       pos
                     (next-single-property-change pos prop nil (point-max)))))
        (if (or (null start) (>= start (point-max)))
            (setq pos (point-max))
          (let* ((end (or (next-single-property-change start prop nil (point-max))
                          (point-max)))
                 (body (string-trim (buffer-substring-no-properties start end))))
            (unless (string-empty-p body)
              (push body bodies))
            (setq pos end)))))
    (nreverse bodies)))

;;;###autoload
(defun dsh-emacs-copy-assistant-message ()
  "Copy only the assistant messages of the current transcript."
  (interactive)
  (let ((bodies (dsh-emacs--assistant-message-bodies)))
    (if bodies
        (progn
          (kill-new (mapconcat #'identity bodies "\n\n"))
          (message "Copied %d assistant message%s"
                   (length bodies)
                   (if (= 1 (length bodies)) "" "s")))
      (user-error "No assistant messages in this transcript"))))

;;;###autoload
(defun dsh-emacs-copy-assistant-message-at-point ()
  "Copy the assistant message body containing point."
  (interactive)
  (let* ((region (dsh-emacs--assistant-message-region-at (point)))
         (body (and region
                    (string-trim (buffer-substring-no-properties
                                  (car region) (cdr region))))))
    (if (and body (not (string-empty-p body)))
        (progn (kill-new body) (message "Copied assistant message"))
      (user-error "Point is not inside an assistant message"))))

;;;###autoload
(defun dsh-emacs-copy-last-assistant-message ()
  "Copy the transcript's most recent assistant message."
  (interactive)
  (let ((bodies (dsh-emacs--assistant-message-bodies)))
    (if bodies
        (progn (kill-new (car (last bodies)))
               (message "Copied last assistant message"))
      (user-error "No assistant messages in this transcript"))))

;;;###autoload
(defun dsh-emacs-copy-dwim ()
  "Copy the smallest transcript unit point means.
An active region copies verbatim; otherwise a code block at point, else
the assistant message containing point, else the transcript's most recent
assistant message."
  (interactive)
  (cond
   ((use-region-p)
    (kill-new (buffer-substring-no-properties (region-beginning) (region-end)))
    (message "Region copied"))
   ((dsh-emacs--code-block-region-at (point))
    (dsh-emacs-copy-code-block))
   ((dsh-emacs--assistant-message-region-at (point))
    (dsh-emacs-copy-assistant-message-at-point))
   (t
    (dsh-emacs-copy-last-assistant-message))))

(defun dsh-emacs-copy-transcript ()
  "Copy the current visible transcript to the clipboard."
  (interactive)
  (let ((chat (current-buffer)))
    (when (buffer-live-p chat)
      (with-current-buffer chat
        (let ((transcript (buffer-substring-no-properties
                           (point-min) (point-max))))
          (kill-new transcript)
          (message "Transcript copied to clipboard"))))))

(defun dsh-emacs-modeline-toggle ()
  "Toggle the mode-line stats display."
  (interactive)
  (let ((chat (current-buffer)))
    (when (buffer-live-p chat)
      (with-current-buffer chat
        (setq dsh-emacs-modeline-enabled (not dsh-emacs-modeline-enabled))
        (dsh-emacs-modeline-update)))))

;;; ---------------------------------------------------------------------------
;;;  Main entry point
;;; ---------------------------------------------------------------------------

;;;###autoload
(defun dsh-emacs ()
  "Open the dsh session list.
This is the main entry command of dsh-emacs."
  (interactive)
  (dsh-emacs-list-sessions-display))

;;;###autoload
(defun dsh-emacs-health ()
  "Check the dsh web service status."
  (interactive)
  (dsh-emacs--rpc-async "session/list" (dsh-emacs--session-list-args)
                        (lambda (ok value)
                          (if ok
                              (message "dsh service is running")
                            (message "dsh service unreachable: %S" value)))))

;; ---------------------------------------------------------------------------
;;  User question/approval waterfall ($events) responses
;; ---------------------------------------------------------------------------
;; dsh's `ask' tool and sandbox approvals push waterfall frames
;; over the core connection's `$events' stream:
;; `user-questions/request' (questions) and `approval/request'
;; (approvals).  Each waterfall carries a host-assigned `eventId';
;; after reading the user's choice/decision the client answers
;; with an outcome via the unary endpoint POST /api/$events/result
;; (args {clientId, eventId, outcome}, where clientId comes from
;; the `$events' ready frame).  outcome.kind ∈ result (with a
;; value) / next (handed to the next taker) / rejected (with an
;; error).
;;
;; Question answer value = {answers: [{id, selected: string[],
;; custom?}]} (selected is a vector; empty when custom-only).
;; Match the host's validation rules exactly: single-select takes
;; one label or a custom (either/or), multi-select takes a set of
;; labels + optional custom, an option-less question can only give
;; a custom, and answers must cover the whole frame.  Approval
;; answer value = an ApprovalOutcome string: `allowed-once' or
;; `rejected' (rejection is the default — C-g/ESC answers with
;; rejection too; sending no decision leaves the host blocked
;; forever on the pending approval).
;;
;; Interaction: read every question in the MINIBUFFER in one pass —
;; options are completion candidates (numbered), multi-select is
;; comma-separated; text that matches no option is itself the
;; answer, and empty input skips the question.  Prompts carry the
;; Question N/M number; once all are answered, one outcome is
;; returned for the batch.
;; Skipping one question uses only the `dsh-emacs-question-skip-key'
;; shortcut = that question is overridden with an empty selected
;; (dsh web's per-question Skip); the rest are answered normally.
;; Empty input on an option-less question also skips it.
;; C-g abandons the whole batch: it returns outcome.kind `rejected'
;; with an error body (name/message, mirroring the cancelled intent
;; kept by the old protocol) — the host withdraws the ask and the
;; ask tool call aborts; the old behavior (no answer at all) left
;; the host pending forever and the turn stuck.
;;
;; Per waterfall generation (each $events reconnect mints a new
;; ready/clientId): when a new ready arrives this side retires all
;; pending frames of the previous generation (no answer — the old
;; clientId's result is a no-op); when the host cancels a waterfall
;; (cancel frame or session end) the pending frame is retired by
;; eventId.
;;
;; The minibuffer is a single global resource: with several
;; sessions live, other streams keep delivering waterfalls while
;; one frame is being answered.  Frames enter a global FIFO queue
;; and only one is answered at a time (nested completing-read calls
;; would stack different sessions' prompts in the same minibuffer
;; and overwrite each other); prompts carry the owning session's
;; identifier (the chat buffer name, e.g. [dsh-<title>]) so the user
;; knows which session asked.

(defvar dsh-emacs--question-queue nil
  "Pending `user-questions/request' waterfalls awaiting the single
interactive answering slot; each entry is (CHAT EVENT-ID SESSION-ID
QUESTIONS).")

(defvar dsh-emacs--question-active nil
  "The `user-questions/request' waterfall currently occupying the
interactive answering slot, or nil.  The slot is shared with the
approval flow (`dsh-emacs--approval-active'): only one prompt may own
the minibuffer at a time.")

;; Declared here — before `dsh-emacs--question-drain' references them in
;; the shared-slot handoff — because the byte-compiler reads the file
;; top-down; the answering logic itself lives in the approval section.
(defvar dsh-emacs--approval-queue nil
  "Pending `approval/request' waterfalls awaiting the single interactive
answering slot; each entry is (CHAT EVENT-ID SESSION-ID TOOL-NAME
REASON CALL-ID).")

(defvar dsh-emacs--approval-active nil
  "The `approval/request' waterfall currently occupying the interactive
answering slot, or nil.  The slot is shared with the question flow
(`dsh-emacs--question-active'): only one prompt may own the minibuffer
at a time.")

(defvar dsh-emacs--waterfall-cancelled-event-id nil
  "Waterfall event id cancelled while its minibuffer was active.
The drain that owns the id clears it and sends no stale outcome.")

(defvar dsh-emacs--waterfall-prompt-event-id nil
  "Event id owning the dynamically active waterfall minibuffer.")

(defun dsh-emacs--waterfall-cancel-active (event-id active)
  "Cancel the active waterfall when EVENT-ID matches ACTIVE.
ACTIVE is a question or approval frame whose event id is its second
element.  Mark the id before leaving the minibuffer so its drain can
distinguish remote resolution from the user's `C-g'."
  (when (and (consp active) (equal event-id (nth 1 active)))
    (setq dsh-emacs--waterfall-cancelled-event-id event-id)
    (when (and (equal event-id dsh-emacs--waterfall-prompt-event-id)
               (active-minibuffer-window))
      (abort-recursive-edit))))

(defun dsh-emacs--question-session-label (session-id)
  "Label identifying SESSION-ID in question prompts.
Prefers the live chat buffer's name (the title-based \"dsh-<title>\"
form); falls back to `dsh-emacs--chat-buffer-name', then to the raw id.
Long labels are truncated so the minibuffer prompt stays readable; a nil
SESSION-ID (direct test calls) yields an empty label."
  (let* ((buf (and session-id
                   (boundp 'dsh-emacs--chat-buffers)
                   (hash-table-p dsh-emacs--chat-buffers)
                   (gethash session-id dsh-emacs--chat-buffers)))
         (label (cond
                 ((and buf (buffer-live-p buf)) (buffer-name buf))
                 (session-id (dsh-emacs--chat-buffer-name session-id))
                 (t ""))))
    (if (> (length label) 40)
        (concat (substring label 0 37) "…")
      label)))

(defun dsh-emacs--events-result-async (client-id event-id outcome callback)
  "Answer a `$events' waterfall: send OUTCOME for EVENT-ID on CLIENT-ID.
OUTCOME is the wire `outcome' object (an alist whose `kind' is
`result' with a `value', `next', or `rejected' with an `error' body).
The answer goes as a one-shot unary RPC to POST /api/$events/result with
args {clientId, eventId, outcome} (rpc.md §3.3).  CALLBACK receives
(ok-p . value-or-error) like `dsh-emacs--rpc-async'."
  (dsh-emacs--rpc-async
   "$events/result"
   `((clientId . ,client-id)
     (eventId . ,event-id)
     (outcome . ,outcome))
   callback))

(defun dsh-emacs--question-drain ()
  "Answer queued question frames one at a time, in arrival order.
Minibuffer answering is a single global slot
(`dsh-emacs--question-active', shared with the approval flow's
`dsh-emacs--approval-active' — only one of the two may prompt at a
time): each frame is answered — or aborted — before the next one is
presented, so prompts from different sessions never nest inside the
same minibuffer.  Runs from whatever filter context delivered the
current frame; queued frames are collected in their own chat buffer
regardless of which stream they arrived on.
Each frame is keyed by its waterfall EVENT-ID; the answer goes to
`$events/result' carrying the current `$events' generation's client-id."
  (while (and (null dsh-emacs--question-active)
              (null dsh-emacs--approval-active)
              dsh-emacs--question-queue)
    (let* ((frame (pop dsh-emacs--question-queue))
           (chat (nth 0 frame))
           (event-id (nth 1 frame))
           (session-id (nth 2 frame))
           (questions (dsh-emacs--sequence-list (nth 3 frame))))
      (setq dsh-emacs--question-active frame)
      (let ((dsh-emacs--waterfall-prompt-event-id event-id))
        (condition-case err
            (let ((answers
                   (when (buffer-live-p chat)
                     (with-current-buffer chat
                       (dsh-emacs--collect-question-answers
                        questions session-id)))))
              (cond
               ((equal event-id dsh-emacs--waterfall-cancelled-event-id)
                (message "Question was answered elsewhere"))
               (answers
                (dsh-emacs--events-result-async
                 dsh-emacs-events--client-id
                 event-id
                 `((kind . "result")
                   (value . ((answers . ,answers))))
                 (lambda (ok value)
                   (if ok
                       (message "Answered %d question(s)" (length answers))
                     (message "Question response not accepted (%s)" value)))))
               (t
                ;; No choices collected (aborted via an empty no-option
                ;; input, or the chat buffer died): abandon the whole
                ;; waterfall — outcome kind `rejected' with an error body
                ;; (dsh web's "abandon questions") so the ask aborts
                ;; host-side and the run is never left blocked.
                (dsh-emacs--question-decline event-id))))
          (quit
           (unless (equal event-id dsh-emacs--waterfall-cancelled-event-id)
             (dsh-emacs--question-decline event-id)))
          (error (message "dsh question error: %S" err))))
      (when (equal event-id dsh-emacs--waterfall-cancelled-event-id)
        (setq dsh-emacs--waterfall-cancelled-event-id nil))
      (setq dsh-emacs--question-active nil)))
  ;; The question answering slot just freed up: hand queued approvals over
  ;; to their drain (which hands back when it is done, so the two never
  ;; stack prompts inside the minibuffer).
  (when (and (null dsh-emacs--question-active)
             (null dsh-emacs--approval-active)
             dsh-emacs--approval-queue)
    (dsh-emacs--approval-drain)))

;; Forward declaration of the $events generation's client-id, owned by
;; dsh-emacs-events.el.  The bare (defvar X) form asserts existence without
;; binding a default, so the owner's own defvar is not shadowed.
(defvar dsh-emacs-events--client-id)

(defconst dsh-emacs--question-skip-label "Skip this question"
  "Internal sentinel for skipping one question with an empty selection.
The skip command returns it directly; it is not a visible candidate.")

;; Bound by `dsh-emacs--question-choice' around its reader, so the helper
;; functions below stay parameterless and the reader sees one context.
(defvar dsh-emacs--question-where nil
  "Prompt prefix of the question being read (session and question number).")

(defvar dsh-emacs--question-text nil
  "Text of the question being read.")

(defvar dsh-emacs--question-hint nil
  "Input hint appended to the question prompt.")

(defvar dsh-emacs--question-roster nil
  "Plain option labels of the question being read.")

(defvar dsh-emacs--question-options nil
  "Option structs of the question being read.")

(defvar dsh-emacs--question-current nil
  "Protocol struct of the question being read.")

(defvar dsh-emacs--question-multi nil
  "Whether the question being read selects multiple options.")

(defun dsh-emacs--question-pick-labels (labels)
  "Return LABELS numbered from 1, the form the reader offers.
The number is part of the option, so a comma-separated answer can name
options by number as well as by label."
  (cl-loop for label in labels for n from 1
           collect (format "%d. %s" n label)))

(defun dsh-emacs--question-prefix-label (prefix labels)
  "Return the single LABELS entry PREFIX unambiguously starts, or nil.
Matching ignores case, so a typed `alph' finds `Alpha'.  `require-match' is
nil in the reader, so completion may hand back an unexpanded prefix instead
of the candidate; an ambiguous prefix stays unresolved on purpose, so the
text is never mapped to the wrong option."
  (let ((hits (cl-remove-if-not
               (lambda (label)
                 (and (<= (length prefix) (length label))
                      (eq t (compare-strings prefix 0 nil label 0 (length prefix)
                                             t))))
               labels)))
    (and (= 1 (length hits)) (car hits))))

(defun dsh-emacs--question-numbered-label (number labels)
  "Return the LABELS entry NUMBER refers to, or nil.
NUMBER is a bare option number.  The numbered candidates are matched in
order, so `2' finds `2. Version' even when the label itself is numeric, and
an out-of-range number matches nothing."
  (let (found)
    (dolist (candidate (dsh-emacs--question-pick-labels labels) found)
      (unless found
        (when (and (string-prefix-p (concat number ". ") candidate)
                   (string-match "\\`[0-9]+\\. \\(.+\\)\\'" candidate))
          ;; The numbered form was built from the label, so the tail is it.
          (setq found (match-string 1 candidate)))))))

(defun dsh-emacs--question-label-of (picked labels)
  "Return the plain LABELS entry PICKED names, or nil.
PICKED is a candidate string, a bare option number, a label, or an
unambiguous prefix of a label.  An exact label wins over an unambiguous
prefix, and both win over stripping a numbered prefix, so a label that
starts with \"<number>. \" still round-trips; a bare number addresses the
option at that position, because `completing-read-multiple' can hand back
an element the completion engine left unexpanded."
  (or (cl-find picked labels :test #'equal)
      (dsh-emacs--question-prefix-label picked labels)
      (let ((plain
             (cond
              ((string-match "\\`[0-9]+\\. \\(.+\\)\\'" picked)
               (match-string 1 picked))
              ((string-match "\\`\\([0-9]+\\)\\'" picked)
               (dsh-emacs--question-numbered-label picked labels)))))
        (and plain (cl-find plain labels :test #'equal)))))

(defvar-local dsh-emacs--question-echo-message nil
  "Last echo-area detail this question reader showed.")

(defun dsh-emacs--question-echo (text)
  "Show TEXT as this reader's echo-area help, without logging it.
Re-showing the same text stays quiet so repeated commands do not spam the
echo area; an empty TEXT clears help this reader owns."
  (cond
   ((or (null dsh-emacs-question-help-display) (string-empty-p text))
    (when (and dsh-emacs--question-echo-message
               (equal (current-message) dsh-emacs--question-echo-message))
      (message nil))
    (setq dsh-emacs--question-echo-message nil))
   ((equal text dsh-emacs--question-echo-message))
   (t
    (setq dsh-emacs--question-echo-message text)
    (let ((inhibit-message t)
          (message-log-max nil))
      (message "%s" text)))))

(defun dsh-emacs--question-echo-cleanup ()
  "Clear echo-area help this reader owns, leaving other messages alone."
  (when (and dsh-emacs--question-echo-message
             (equal (current-message) dsh-emacs--question-echo-message))
    (message nil))
  (setq dsh-emacs--question-echo-message nil))

(defun dsh-emacs--question-annotation (candidate)
  "Return CANDIDATE's option description, or an empty string.
The description rides along with its candidate, so it is visible in the
completion list without a tooltip, styled with `dsh-emacs-meta-face' — the
face the ask card gives the same description in the transcript.  The
annotation must carry a face of its own: a frontend adds
`completions-annotations' only to a suffix that has none, so a bare string
would be repainted by whatever default the user's UI applies."
  (let* ((label (or (dsh-emacs--question-label-of
                     candidate dsh-emacs--question-roster)
                    candidate))
         (option (cl-find label dsh-emacs--question-options
                          :key #'dsh-protocol-question-option-label
                          :test #'equal))
         (description (and option
                           (dsh-protocol-question-option-description option))))
    (if (or (null description) (string-empty-p description))
        ""
      (propertize (format "  %s" description)
                  'face 'dsh-emacs-meta-face))))

(defun dsh-emacs--question-skip-command ()
  "Skip the current question with an empty selection.
Bound from `dsh-emacs-question-skip-key' in the reader's minibuffer."
  (interactive)
  (throw 'dsh-emacs--question-command dsh-emacs--question-skip-label))

(defun dsh-emacs--question-reader-keymap ()
  "Return the reader's minibuffer keymap: the current local map plus the
skip shortcut (`dsh-emacs-question-skip-key', default `C-c C-s'), so
nothing leaks into unrelated `completing-read' prompts.  The typed text is the
answer itself (comma-separated options, see `crm-separator'), so no key
is remapped and completion keep working."
  (let ((map (copy-keymap (current-local-map))))
    (when dsh-emacs-question-skip-key
      (define-key map (if (stringp dsh-emacs-question-skip-key)
                          (kbd dsh-emacs-question-skip-key)
                        dsh-emacs-question-skip-key)
                  #'dsh-emacs--question-skip-command))
    map))

(defun dsh-emacs--question-reader-setup ()
  "Install the reader's keymap, candidate annotations and echo-area help.
Everything is minibuffer-local, so no other `completing-read' sees it.  The
prompt is preselected instead of the first candidate: an empty answer means
\"skip\", and a frontend that preselects the first row would otherwise turn
a bare RET into an answer.  The same setup also serves the nested free-text
read, where there is no question context to show."
  ;; Keep our own previous text out of the way, but never clear a message
  ;; this reader did not write.
  (when (and dsh-emacs--question-echo-message
             (equal (current-message) dsh-emacs--question-echo-message))
    (message nil))
  (setq-local dsh-emacs--question-echo-message nil)
  (when (boundp 'vertico-preselect)
    (setq-local vertico-preselect 'prompt))
  (setq-local completion-extra-properties
              (list :annotation-function #'dsh-emacs--question-annotation))
  (use-local-map (dsh-emacs--question-reader-keymap))
  (add-hook 'minibuffer-exit-hook #'dsh-emacs--question-echo-cleanup nil t)
  (dsh-emacs--question-echo
   (let ((question dsh-emacs--question-current)
         detail)
     (when (dsh-protocol-question-p question)
       (setq detail (dsh-protocol-question-detail question)))
     (if (or (null detail) (string-empty-p detail)) "" detail)))
  nil)

(defun dsh-emacs--question-answer-values (picked labels)
  "Return PICKED resolved to LABELS entries, in the question's option order.
Each element is a candidate, a bare number, a label, or a label prefix; an
element that names no option is left as the typed text, so the caller can
tell `every value is an option` from `the user is answering in text`, and
never silently drops part of the answer.  The answer follows the order the
question offered the options, not the order they were typed."
  (let ((values (mapcar (lambda (value)
                          (or (dsh-emacs--question-label-of value labels) value))
                        picked)))
    (cl-stable-sort values #'< :key (lambda (value)
                                      (or (cl-position value labels :test #'equal)
                                          most-positive-fixnum)))))

(defun dsh-emacs--question-read-multiple (labels)
  "Read one comma-separated answer over numbered LABELS.
Returns the selected candidate strings, the free-text sentinel, or nil for
an empty answer.  `require-match' is nil on purpose: the answer is typed
text, so an empty minibuffer must stay empty (a mandatory match lets a
frontend turn a bare RET into its preselected candidate) and an unknown
value is better treated as a free-text answer than rejected.  C-g
propagates.
The candidates carry identity sort metadata: the number in a candidate is
its position in the question, so a frontend must not reorder the list (the
default ranking is by history, length and alphabet, which scrambles the
numbered items and differs from question to question).  CRM hands the
collection on to the frontend through `crm--collection-fn', which passes
this metadata through."
  (catch 'dsh-emacs--question-command
    (minibuffer-with-setup-hook #'dsh-emacs--question-reader-setup
      (completing-read-multiple
       (concat dsh-emacs--question-where dsh-emacs--question-text
               (or dsh-emacs--question-hint "") ": ")
       (dsh-emacs--completion-table-with-metadata
        (dsh-emacs--question-pick-labels labels)
        '((display-sort-function . identity)
          (cycle-sort-function . identity)))
       nil nil nil nil nil))))

(defun dsh-emacs--question-choose (labels)
  "Read one answer over LABELS.
The prompt carries the question and the candidates carry their own
descriptions.  An empty input is a skip, and anything that names no option
is the user's own text."
  (catch 'answer
    (let ((picked (dsh-emacs--question-read-multiple labels)))
      (cond
       ((equal picked dsh-emacs--question-skip-label)
        (throw 'answer :skip))
       ((null picked) :skip)
       (t
        (let* ((values (dsh-emacs--question-answer-values picked labels))
               (options (cl-remove-if-not (lambda (value)
                                            (cl-member value labels :test #'equal))
                                          values)))
          (cond
           ((null options)
            ;; Names no option: the text is the answer, like an unmatched
            ;; input at any completion prompt.
            (throw 'answer (cons :custom (string-join picked ", "))))
           ((/= (length options) (length values))
            ;; Only part of it names options; treating it as a selection
            ;; would silently drop the rest, so the whole input is the text.
            (throw 'answer (cons :custom (string-join picked ", "))))
           (dsh-emacs--question-multi
            (cons :selected options))
           (t
            (cons :one (car options))))))))))

(defun dsh-emacs--question-choice (question &optional index total session-id)
  "Read one answer to QUESTION as ((id . ID) (selected . LABELS) ...).
QUESTION accepts a protocol struct or legacy wire alist.  INDEX/TOTAL
and SESSION-ID identify the question and its owning session in the prompt.
Multiple selection is one comma-separated answer (for example `2,3'):
the numbered options are the candidates, an empty input skips the
question, and any text that names no option is itself the answer (like an
unmatched input at any completion prompt).  Single selection uses the first
value when several are given.  Every question is answered by one minibuffer read, so the reader is
never reopened per key.  The skip key
(`dsh-emacs-question-skip-key') answers with an empty selection and C-g
abandons the whole waterfall.  Questions without options read free text,
with empty input meaning skip.  The question detail shows in the echo
area; each option's description rides along with its candidate."
  (let* ((question (dsh-protocol--struct
                    #'dsh-protocol-question-p
                    #'dsh-protocol-question--from-alist question))
         (id (dsh-protocol-question-id question))
         (text (or (dsh-protocol-question-text question) "Question"))
         (options (dsh-protocol-question-options question))
         (labels (mapcar #'dsh-protocol-question-option-label options))
         (dsh-emacs--question-roster labels)
         (dsh-emacs--question-current question)
         (dsh-emacs--question-options options)
         (dsh-emacs--question-multi
          (dsh-protocol-question-multi-select question))
         ;; The session label is redundant in the asking buffer.
         (same-buffer (and (boundp 'dsh-emacs--buffer-session)
                           (equal dsh-emacs--buffer-session session-id)))
         (dsh-emacs--question-where
          (concat
           (if (and session-id (not (string-empty-p session-id))
                    (not same-buffer))
               (format "[%s] " (dsh-emacs--question-session-label session-id))
             "")
           (if index (format "Question %d/%d — " index total) "")))
         (dsh-emacs--question-text text)
         (dsh-emacs--question-hint
          (if (null labels)
              " (empty input = skip)"
            (if dsh-emacs--question-multi
                " (2,3 or names, or your own text; empty = skip)"
              " (a name or your own text; empty = skip)"))))
    (if (null labels)
        (let ((custom
               (minibuffer-with-setup-hook #'dsh-emacs--question-reader-setup
                 (read-string (format "%s%s%s: "
                                      dsh-emacs--question-where text
                                      dsh-emacs--question-hint)))))
          (if (string-empty-p custom)
              `((id . ,id) (selected . []))
            `((id . ,id) (selected . []) (custom . ,custom))))
      (let ((answer (dsh-emacs--question-choose labels)))
        (pcase answer
          (:skip
           (when (and index total)
             (message "Question %d/%d skipped" index total))
           `((id . ,id) (selected . [])))
          (`(:custom . ,custom)
           `((id . ,id) (selected . []) (custom . ,custom)))
          (`(:selected . ,selected)
           `((id . ,id) (selected . ,selected)))
          (`(:one . ,label)
           `((id . ,id) (selected . (,label))))
          (_ (error "Unhandled question answer: %S" answer)))))))

(defun dsh-emacs--question-preview-item (id text detail multi options)
  "Build one local preview question; no wire payload is involved.
ID/TEXT/DETAIL are strings, MULTI says whether several options may be
picked, and OPTIONS is a list of (LABEL . DESCRIPTION) pairs.  Values go
in through the protocol accessors, so this local sample never spells a
wire field name."
  (let ((question (dsh-protocol-question--from-alist nil)))
    (setf (dsh-protocol-question-id question) id
          (dsh-protocol-question-text question) text
          (dsh-protocol-question-detail question) detail
          (dsh-protocol-question-multi-select question) multi
          (dsh-protocol-question-options question)
          (mapcar (pcase-lambda (`(,label . ,description))
                    (let ((option (dsh-protocol-question-option--from-alist nil)))
                      (setf (dsh-protocol-question-option-label option) label
                            (dsh-protocol-question-option-description option)
                            description)
                      option))
                  options))
    question))

(defun dsh-emacs--collect-question-answers (questions &optional session-id)
  "Answer QUESTIONS one at a time from the minibuffer: each question's
options are the completion candidates (`dsh-emacs--question-choice',
with its INDEX/TOTAL in the prompt), in frame order.  SESSION-ID (when
given) labels every prompt with the owning session.  Returns the answer
alists in frame order.  Empty free text skips an option-less question;
C-g propagates to the caller, which declines the waterfall."
  (let ((total (length questions))
        (answers nil)
        (n 0))
    (catch 'abort
      (dolist (q questions)
        (setq n (1+ n))
        (let ((answer (dsh-emacs--question-choice q n total session-id)))
          (if (null answer) (throw 'abort nil)
            (push answer answers))))
      (reverse answers))))

;;;###autoload
(defun dsh-emacs-question-preview ()
  "Try the ask reader locally, without sending an RPC.
Presents a three-question batch — a multi-select with option
descriptions, a single-select, and an option-less free-text question — so
one run shows every prompt shape and the \"Question N/M\" framing.  The
answers of the whole batch are echoed the way the RPC outcome would carry
them."
  (interactive)
  (message "Preview answers: %S"
           (dsh-emacs--collect-question-answers
            (list (dsh-emacs--question-preview-item
                   "preview-1" "What should this update include?"
                   "Multi-select: pick several (2,3), or type your own answer."
                   t
                   '(("UI" . "Show the current option's description here.")
                     ("Regression tests" . "Cover multi-select and free text.")
                     ("Docs" . "Update usage notes and the decision record.")))
                  (dsh-emacs--question-preview-item
                   "preview-2" "How should the change be verified?"
                   "Single select: pick one option, or type your own answer."
                   nil
                   '(("Run scripts/verify.sh" . "Parens, tests, compile pass.")
                     ("Click through the GUI only" . "Walk the path by hand.")))
                  (dsh-emacs--question-preview-item
                   "preview-3" "Anything else to add?"
                   "No options: empty input skips, text is the answer."
                   nil nil)))))

(defun dsh-emacs--question-requested (chat event-id session-id questions)
  "Queue a `user-questions/request' waterfall EVENT-ID of SESSION-ID and answer it.
The minibuffer is one global resource: with several chat buffers open, a
$events frame can deliver the next question while the previous one is
still being answered interactively.  Nested `completing-read' calls
would stack different sessions' prompts inside the same minibuffer, so
frames are queued (FIFO) and drained one at a time by
`dsh-emacs--question-drain'; each prompt carries the owning session's
label (see `dsh-emacs--question-session-label').  All questions of the
waterfall are then read one after another (options as completion
candidates plus a \"Type answer…\" free-text choice) and answered with a
single `$events/result' outcome (value = {answers: …}).  C-g abandons
the whole waterfall with outcome kind
`rejected' and an error body (dsh web's \"abandon questions\") so the host
withdraws the ask and the run is never left blocked; the quit is caught
here, so it cannot leak out of the process filter as \"error in process
filter: Quit\".
A waterfall whose EVENT-ID is already pending (queued or active) is
dropped instead of asked twice, mirroring the approval flow."
  (unless (or (and (consp dsh-emacs--question-active)
                   (equal event-id (nth 1 dsh-emacs--question-active)))
              (cl-some (lambda (entry)
                         (equal event-id (nth 1 entry)))
                       dsh-emacs--question-queue))
    (setq dsh-emacs--question-queue
          (nconc dsh-emacs--question-queue
                 (list (list chat event-id session-id questions))))
    ;; Desktop notice, turn-finish style (`dsh-emacs-enable-notifications'):
    ;; the answering prompt may wait behind another session's prompt, so
    ;; announce a pending question even when the user is away from the
    ;; chat.  Acceptance-gated: a replayed duplicate waterfall is dropped
    ;; above and must never re-notify.
    (when (buffer-live-p chat)
      (let* ((qs (dsh-emacs--sequence-list questions))
             (first-text
              (dsh-protocol-question-text
               (dsh-protocol--struct #'dsh-protocol-question-p
                                     #'dsh-protocol-question--from-alist
                                     (car qs))))
             (count (length qs))
             (body (format "Question%s%s"
                           (if (stringp first-text)
                               (format ": %s" first-text)
                             "")
                           (if (> count 1)
                               (format " (+%d more)" (1- count))
                             ""))))
        (dsh-emacs-notify--post session-id body chat))))
  (dsh-emacs--question-drain))

(defun dsh-emacs--question-decline (event-id)
  "Abandon a whole `user-questions/request' waterfall EVENT-ID.
Answers with outcome kind `rejected' and an error body (name/message)
mirroring the old protocol's reserved `cancelled' intent — the same wire
signal dsh web's \"abandon questions\" produces: the host resolves the
pending ask as cancelled and the ask tool call aborts, so the agent's
turn is never left blocked on an unanswered question.  The quit is
contained here so it cannot leak out of the process filter as \"error in
process filter: Quit\"."
  (dsh-emacs--events-result-async
   dsh-emacs-events--client-id
   event-id
   `((kind . "rejected")
     (error . ((name . "cancelled")
               (message . "User abandoned the questions"))))
   (lambda (ok value)
     (if ok
         (message "Question cancelled")
       (message "Question response not accepted (%s)" value)))))

(defun dsh-emacs--question-cancelled (event-id)
  "Retire the queued `user-questions/request' waterfall EVENT-ID.
A host `cancel' frame for EVENT-ID means the waterfall was withdrawn and
no longer needs answering; drop any still-queued copy so a replay never
re-asks a finished question.  When the matching waterfall owns the active
minibuffer, close it and let its drain retire without sending an outcome."
  (setq dsh-emacs--question-queue
        (cl-remove-if (lambda (entry)
                        (equal event-id (nth 1 entry)))
                      dsh-emacs--question-queue))
  (dsh-emacs--waterfall-cancel-active
   event-id dsh-emacs--question-active))

(defun dsh-emacs--waterfall-generation-retired ()
  "Retire all pending question/approval waterfalls of a dead generation.
Each `$events' reconnect hands out a NEW client-id; answering the old
generation's still-queued frames with it would be a no-op, so the pending
frames are dropped (a waterfall currently being prompted cannot be
aborted from here — its stale answer is likewise a no-op)."
  (message "dsh: new $events generation — retiring %d queued question(s) and %d approval(s)"
           (length dsh-emacs--question-queue)
           (length dsh-emacs--approval-queue))
  (setq dsh-emacs--question-queue nil
        dsh-emacs--approval-queue nil))

;; ---------------------------------------------------------------------------
;;  User approval (approval/request) responses
;; ---------------------------------------------------------------------------
;; Out-of-bounds requests from sandboxed tools push
;; `approval/request' waterfalls over the core connection's `$events'
;; stream: when bash/fs and friends need files outside the workspace,
;; the host first asks the user's permission (the same protocol as
;; dsh web's ApprovalPanel).  The client must show the request
;; (toolName + justification reason), read the user's approve/reject
;; decision, and answer with an outcome via the unary endpoint POST
;; /api/$events/result (value = ApprovalOutcome string: the client
;; gives only "allowed-once" | "rejected"; the wire has no
;; approvalId).
;;
;; Interaction: minibuffer y-or-n-p — y/the y key = allow once, n =
;; reject; C-g/ESC answers with rejection too (with no decision the
;; client sends nothing and the host blocks forever on the pending
;; approval; a waterfall the host already cancelled has a no-op
;; result and is dropped silently).  The minibuffer is a single
;; global resource: approvals and questions share one lock
;; (`dsh-emacs--approval-active' / `dsh-emacs--question-active', see
;; the defvars above); while either is active new frames queue up
;; serially, and the two drains hand off to each other as their
;; queues empty, never nesting two minibuffer prompts.

(defun dsh-emacs--approval-command-line (call-id)
  "One-line summary of the tool call CALL-ID from the live transcript.
Reads the buffer-local `dsh-emacs--tool-states' map, so it must run in
the chat buffer of the approving session.  For bash the rendered body is
the real command (\"$ cat /etc/hostname\"); other tools fall back to
\"Title — args\".  Returns nil when CALL-ID is unknown (e.g. the call
predates this window, or the approval replayed right after open)."
  (when (and call-id
             (boundp 'dsh-emacs--tool-states)
             (hash-table-p dsh-emacs--tool-states))
    (let* ((state (dsh-emacs-render--tool-state call-id))
           (title (and state (plist-get state :title)))
           (args (and state (plist-get state :args))))
      (cond
       ((and (stringp args) (string-match-p "\\`\\$ " args)) args)
       ((and (stringp args) (not (string-empty-p args)))
        (if (and (stringp title) (not (string-empty-p title)))
            (format "%s — %s" title args)
          args))
       ((and (stringp title) (not (string-empty-p title))) title)
       (t nil)))))

(defun dsh-emacs--approval-drain ()
  "Answer queued approval waterfalls one at a time, in arrival order.
The approval prompt owns the same single minibuffer slot as question
answering: while `dsh-emacs--question-active' or
`dsh-emacs--approval-active' is set, queued approvals wait.  Each frame
is decided before the next one is presented — a quit (C-g/ESC) counts
as a rejection so the host never stays blocked on a pending frame.
The decision goes out as a `$events/result' outcome (value =
ApprovalOutcome string) carrying the current generation's client-id and
the waterfall's EVENT-ID.  The prompt runs in the frame's chat buffer so
the tool-call lookup (`dsh-emacs--approval-command-line') can read the
buffer-local transcript state.  When the slot frees up, queued questions
are handed back to `dsh-emacs--question-drain'."
  (while (and (null dsh-emacs--approval-active)
              (null dsh-emacs--question-active)
              dsh-emacs--approval-queue)
    (let* ((frame (pop dsh-emacs--approval-queue))
           (chat (nth 0 frame))
           (event-id (nth 1 frame))
           (session-id (nth 2 frame))
           (tool-name (nth 3 frame))
           (reason (nth 4 frame))
           (call-id (nth 5 frame)))
      (setq dsh-emacs--approval-active frame)
      (let ((dsh-emacs--waterfall-prompt-event-id event-id))
        (condition-case err
            (let ((allow
                   (condition-case nil
                       (if (buffer-live-p chat)
                           (with-current-buffer chat
                             (dsh-emacs--approval-prompt
                              session-id tool-name reason call-id))
                         (dsh-emacs--approval-prompt
                          session-id tool-name reason call-id))
                     ;; A remote cancel must reach the outer handler without
                     ;; becoming the user's default rejection.
                     (quit
                      (if (equal event-id
                                 dsh-emacs--waterfall-cancelled-event-id)
                          (signal 'quit nil)
                        (message "Approval %s quit — rejecting" event-id)
                        nil)))))
              (if (equal event-id dsh-emacs--waterfall-cancelled-event-id)
                  (message "Approval was answered elsewhere")
                (dsh-emacs--events-result-async
                 dsh-emacs-events--client-id
                 event-id
                 `((kind . "result")
                   (value . ,(if allow "allowed-once" "rejected")))
                 (lambda (ok value)
                   (if ok
                       (message "%s %s for %s"
                                (if allow "Approved" "Rejected")
                                (or tool-name "tool") session-id)
                     (message "Approval response not accepted (%s)"
                              value))))))
          ;; Remote cancellation exits the prompt without answering again.
          (quit
           (unless (equal event-id dsh-emacs--waterfall-cancelled-event-id)
             (message "Approval %s cancelled" event-id)))
          (error (message "dsh approval error: %S" err))))
      (when (equal event-id dsh-emacs--waterfall-cancelled-event-id)
        (setq dsh-emacs--waterfall-cancelled-event-id nil))
      (setq dsh-emacs--approval-active nil)))
  ;; The approval answering slot just freed up: hand queued questions over
  ;; to their drain (which hands back when it is done).
  (when (and (null dsh-emacs--approval-active)
             (null dsh-emacs--question-active)
             dsh-emacs--question-queue)
    (dsh-emacs--question-drain)))

(defun dsh-emacs--avoid-minibuffer-prompt (&rest _)
  "Point-entered handler keeping point off the read-only prompt tail.
Same behavior as the obsolete `minibuffer-avoid-prompt' (deprecated
since 25.1): entering the prompt region moves point past it."
  (when (and (minibufferp) (< (point) (minibuffer-prompt-end)))
    (goto-char (minibuffer-prompt-end))))

(defun dsh-emacs--approval-prompt (session-id tool-name reason call-id)
  "Read the user's decision for one approval in the minibuffer.
The prompt is multi-line, untruncated and colored: the asker's full
justification REASON in `dsh-emacs-approval-justification-face' (light
orange), then a blank line and the actual tool call (the bash command
line, see `dsh-emacs--approval-command-line' — runs in the chat buffer,
so CALL-ID must be that session's) in `dsh-emacs-approval-command-face'
(gray).  The owning session, tool and call-id are logged to *Messages*.
Without any detail the prompt falls back to \"Allow TOOL?\".  The prompt
faces survive because `minibuffer-prompt-properties' is bound WITHOUT
its `face' slot around the read — the minibuffer prompt insertion would
otherwise replace every prompt face with `minibuffer-prompt'.  Returns t
to allow once, nil to reject; C-g signals `quit' and the caller answers
the same rejection (an unanswered frame would block the host forever)."
  (let* ((where (concat
                 (if (and session-id (not (string-empty-p session-id)))
                     (format "[%s] " (dsh-emacs--question-session-label
                                      session-id))
                   "")
                 (if (and call-id (not (string-empty-p call-id)))
                     (format "call %s " call-id)
                   "")))
         (just-line (and reason (not (string-empty-p reason))
                         (propertize reason
                                     'face
                                     'dsh-emacs-approval-justification-face)))
         (cmd-line (let ((line (dsh-emacs--approval-command-line call-id)))
                     (and line (propertize line
                                           'face
                                           'dsh-emacs-approval-command-face))))
         (lines (delq nil (list just-line cmd-line)))
         (prompt (if lines
                     (mapconcat #'identity lines "\n\n")
                   (format "Allow %s?" (or tool-name "tool")))))
    (when (and where (not (string-empty-p where)))
      (message "dsh approval, %s: %s%s"
               (or tool-name "tool") where
               (if (and reason (not (string-empty-p reason)))
                   (format " — %s" reason)
                 "")))
    (let ((minibuffer-prompt-properties
           ;; Keep the prompt non-editable and point-safe, but drop the
           ;; `face' slot: `read-from-minibuffer' applies these properties
           ;; over the prompt, and `add-text-properties' replaces an
           ;; existing `face' — with it bound the justification/command
           ;; colors above would be wiped by `minibuffer-prompt'.
           (list 'read-only t
                 'point-entered #'dsh-emacs--avoid-minibuffer-prompt)))
      (y-or-n-p prompt))))

(defun dsh-emacs--approval-requested (chat event-id session-id tool-name
                                             reason call-id)
  "Queue an `approval/request' waterfall EVENT-ID of SESSION-ID and answer it.
Mirrors `dsh-emacs--question-requested': the minibuffer is one global
resource, so frames are queued (FIFO) and drained one at a time by
`dsh-emacs--approval-drain', never nested inside another prompt.  A
waterfall whose EVENT-ID is already pending ($events replay of the same
request) is dropped instead of asked twice.  The decision — allow once
or reject — is sent as a single `$events/result' outcome (value =
ApprovalOutcome string) carrying the current generation's client-id and
the EVENT-ID; C-g answers the rejection too (default deny).  The quit is
caught here so it cannot leak out of the process filter as \"error in
process filter: Quit\"."
  (unless (or (and dsh-emacs--approval-active
                   (equal event-id (nth 1 dsh-emacs--approval-active)))
              (cl-some (lambda (entry)
                         (equal event-id (nth 1 entry)))
                       dsh-emacs--approval-queue))
    (setq dsh-emacs--approval-queue
          (nconc dsh-emacs--approval-queue
                 (list (list chat event-id session-id
                             tool-name reason call-id))))
    ;; Desktop notice, turn-finish style: the approval prompt may wait in
    ;; the queue while the user is in another buffer or app; the body
    ;; carries the tool call (else justification, else tool name) so the
    ;; decision can be made away from the minibuffer.  Acceptance-gated:
    ;; a replayed duplicate never re-notifies.  The command-line lookup
    ;; needs the chat buffer's transcript state, so it runs there.
    (when (buffer-live-p chat)
      (let* ((command (with-current-buffer chat
                        (dsh-emacs--approval-command-line call-id)))
             (detail (or command
                         (and (stringp reason)
                              (not (string-empty-p reason)) reason)
                         (and (stringp tool-name)
                              (not (string-empty-p tool-name)) tool-name)))
             (body (format "Approval%s"
                           (if detail (format ": %s" detail) ""))))
        (dsh-emacs-notify--post session-id body chat))))
  (dsh-emacs--approval-drain))

(defun dsh-emacs--approval-cancelled (event-id)
  "Retire the queued `approval/request' waterfall EVENT-ID.
A host `cancel' frame for EVENT-ID means the waterfall was withdrawn and
no longer needs answering; drop any still-queued copy so a replay never
re-asks a finished approval.  When the matching waterfall owns the active
minibuffer, close it and let its drain retire without sending an outcome."
  (setq dsh-emacs--approval-queue
        (cl-remove-if (lambda (entry)
                        (equal event-id (nth 1 entry)))
                      dsh-emacs--approval-queue))
  (dsh-emacs--waterfall-cancel-active
   event-id dsh-emacs--approval-active))

(provide 'dsh-emacs)

;;; dsh-emacs.el ends here
