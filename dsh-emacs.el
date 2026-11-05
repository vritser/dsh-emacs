;;; dsh-emacs.el --- Main entry point for dsh-emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.8.0
;; Package-Requires: ((emacs "28.1"))
;; URL: https://github.com/vritser/dsh-emacs
;; License: GPL-3.0-or-later
;; Keywords: ai, tools, convenience

;;; Commentary:

;; dsh-emacs is a UI for using DeepSeek Harness inside Emacs.
;; It talks to a running dsh web service over HTTP in an Emacs-native way.
;;
;; Main features:
;; - Session list (card view)
;; - Chat buffer (with tool-call and thinking folding)
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

;; Protocol and HTTP/RPC transport precede their feature consumers.
(require 'dsh-emacs-protocol)
(require 'dsh-emacs-server)

;; Fragment UI precedes its presentation consumers.
(require 'dsh-emacs-ui)

;; Assemble presentation and feature modules.
(require 'dsh-emacs-faces)
(require 'dsh-emacs-tokens)
(require 'dsh-emacs-markdown)
(require 'dsh-emacs-plan)
(require 'dsh-emacs-render)
(require 'dsh-emacs-history)
(declare-function dsh-emacs-render--cancel-markdown "dsh-emacs-render" ())
(declare-function dsh-emacs-render--insert-user-block "dsh-emacs-render"
                  (event references))
(require 'dsh-emacs-input)
(require 'dsh-emacs-attachments)
(require 'dsh-emacs-composer)
(require 'dsh-emacs-interaction)
(require 'dsh-emacs-events)
(require 'dsh-emacs-modeline)
(require 'dsh-emacs-queue)
(require 'dsh-emacs-jobs)
(require 'dsh-emacs-provider)
(require 'dsh-emacs-model)
(require 'dsh-emacs-command)
(require 'dsh-emacs-skill)
(require 'dsh-emacs-reference)
(require 'dsh-emacs-shell)
(require 'dsh-emacs-session)
(require 'dsh-emacs-reload)
(declare-function dsh-emacs-session--ancestors "dsh-emacs-session" (id))
(declare-function dsh-emacs-subagent--cell "dsh-emacs-subagent" (id key))
(declare-function dsh-emacs-subagent--value "dsh-emacs-subagent" (id key))
(defvar dsh-emacs--subagent-catalogs)

;;; ---------------------------------------------------------------------------
;;;  Customization options
;;; ---------------------------------------------------------------------------

(defgroup dsh-emacs nil
  "Emacs UI for DeepSeek Harness (dsh)."
  :group 'applications
  :prefix "dsh-emacs-")

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

(defcustom dsh-emacs-default-preset nil
  "Default agent preset (agentPreset id) for new sessions.

nil lets the host pick its own default preset (no `agentPreset' field is
sent to `session/create').  Known values are the built-in preset ids
\"standard\", \"minimal\", \"ptc\" and \"cordis\", or the id of a user
preset listed by `agentPresets/list'.  Interactively,
`dsh-emacs-new-session' with a prefix argument asks for the preset
instead of using this value."
  :type '(choice (const :tag "Host default" nil) string)
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

;;; ---------------------------------------------------------------------------
;;;  Internal variables
;;; ---------------------------------------------------------------------------

(defvar dsh-emacs--sessions nil
  "Cache of the session list.
Nil until the first `session/list' read; the list stays the only
non-nil value, so readers may iterate it directly.")

(defvar dsh-emacs--chat-buffers (make-hash-table :test 'equal)
  "Registry of session id -> live chat buffer.

Chat buffers are named `dsh: <list title>' (matching the session list, with
dsh prepended), and sessions with the same title need unique names, so a
buffer cannot be looked up by title; this table provides stable reuse and
renaming by session ID.")

(defvar dsh-emacs--workspaces nil
  "Cache of the workspace list.")

(defvar dsh-emacs--agent-presets nil
  "Cached `agentPresets/list' response (a `dsh-protocol-agent-preset-list'
struct), used by the new-session preset picker.  Refreshed lazily by
`dsh-emacs--agent-presets-refresh'; `dsh-emacs--read-preset' fetches it
synchronously when nil, so the picker has no choices until such a fetch
succeeds.")

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

(defvar-local dsh-emacs--pending-user-messages nil
  "Text of messages the user sent but that are not yet rendered in the transcript.")

(defvar-local dsh-emacs--pending-user-echoes nil
  "Optimistic transcript echoes awaiting their submit's acceptance.
An alist of (TEXT START-MARKER . END-MARKER) recorded by
`dsh-emacs--render-user-message-optimistic'.  An entry is dropped when the
canonical `user/message' consumes the pending text (the echo stays on
screen), or deleted from the buffer when the submit's RPC fails, so a
rejected prompt never lingers as a phantom message.")

(defvar-local dsh-emacs--buffer-subagent nil
  "Durable direct-parent address, or nil for an ordinary conversation.")
(put 'dsh-emacs--buffer-subagent 'permanent-local t)
(defvar-local dsh-emacs--subagent-input-read-only nil
  "Non-nil when the addressed child cannot accept input.")
(defvar-local dsh-emacs--subagent-departure nil
  "Source marker awaiting successful child follow before entering xref history.")

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

;;; ---------------------------------------------------------------------------
;;;  Session management
;;; ---------------------------------------------------------------------------

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
  (cl-find session-id dsh-emacs--sessions
           :test #'equal :key #'dsh-protocol-session-session-id))

(defun dsh-emacs--chat-title (session-id)
  "Display title for SESSION-ID, identical to the session list row, or nil."
  (let ((item (dsh-emacs--chat-session-item session-id)))
    (and item (dsh-emacs-session--display-title item))))

(defun dsh-emacs--workspace-by-id (workspace-id)
  "Return the cached workspace struct with WORKSPACE-ID, or nil."
  (cl-find workspace-id dsh-emacs--workspaces
           :test #'equal :key #'dsh-protocol-workspace-workspace-id))

(defun dsh-emacs--workspace-containing (session-id)
  "Return the cached workspace struct listing SESSION-ID, or nil."
  (cl-find-if (lambda (ws)
                (member session-id
                        (dsh-protocol-workspace-session-ids ws)))
              dsh-emacs--workspaces))

(defun dsh-emacs--chat-cwd (session-id)
  "Directory of SESSION-ID: the session's `cwd' from session/list.
Falls back to the path of the workspace that accounts for the session
(a freshly created workspace session may not be in the session cache yet
but is already in `dsh-emacs--workspaces').  Returns nil when the session
is not known at all."
  (or (when-let* ((item (dsh-emacs--chat-session-item session-id)))
        (dsh-protocol-session-cwd item))
      (when-let* ((ws (dsh-emacs--workspace-containing session-id)))
        (dsh-protocol-workspace-path ws))))

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

`dsh: <list title>' when the session list has a display title for the session
(so the modeline matches the list), otherwise `dsh: <session-id>'."
  (let ((title (dsh-emacs--chat-title session-id)))
    (if (and title (not (string-empty-p title)))
        (concat "dsh: " (dsh-emacs--sanitize-buffer-name title))
      (format "dsh: %s" session-id))))

(defun dsh-emacs--chat-buffer-untrack ()
  "Remove the current chat buffer from `dsh-emacs--chat-buffers' when killed.
Leaves the entry alone when it already points at another buffer, so a stale
kill or mode change cannot deregister a replacement chat for the session."
  (when (and dsh-emacs--buffer-session
             (eq (gethash dsh-emacs--buffer-session dsh-emacs--chat-buffers)
                 (current-buffer)))
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
        (let ((name (if dsh-emacs--buffer-subagent
                        (format "dsh: %s/%s"
                                (dsh-emacs--sanitize-buffer-name
                                 (or (dsh-emacs--chat-title
                                      (dsh-protocol-subagent-address-parent dsh-emacs--buffer-subagent))
                                     (dsh-protocol-subagent-address-parent dsh-emacs--buffer-subagent)))
                                (dsh-emacs--sanitize-buffer-name
                                 (dsh-emacs-subagent-label dsh-emacs--buffer-subagent)))
                      (dsh-emacs--chat-buffer-name session-id))))
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
Reads the session row's decoded `modelSelection' projection (`lastUsed')
as a `dsh-protocol-model-selection' so business code reads
`provider'/'model'/'reasoning-effort' through accessors (the wire
`lastUsed' alist keys stay inside the protocol layer).  Nil when the row
is unknown or has no projection yet (fresh session before its first run)."
  (let ((item (dsh-emacs--chat-session-item session-id)))
    (when item
      (let ((selection (dsh-protocol-session-model-selection item)))
        (and selection
             (dsh-protocol--struct
              #'dsh-protocol-model-selection-p
              #'dsh-protocol-model-selection--from-alist selection))))))

(defun dsh-emacs--chat-buffer-model-sync (session-id buf &optional selection)
  "Feed BUF's mode-line model/effort/provider for SESSION-ID.
The authoritative (provider, model, reasoningEffort) triple comes from
the cached session row's `modelSelection' projection (`lastUsed'); the
row may not carry one yet (fresh session before its first run), in which
case nothing is touched and `dsh-emacs-default-model' remains the
segment-level fallback — genuinely right for a session just created
with it.  The projection rides `session/list' rows and the follow/control
projection frames, so the feed is re-run by
`dsh-emacs--chat-buffers-sync-all' whenever the cache refreshes.
An explicit decoded SELECTION also works before the session row is cached."
  (when (and (buffer-live-p buf)
             (equal session-id
                    (buffer-local-value 'dsh-emacs--buffer-session buf)))
    (when-let* ((sel (or selection
                        (dsh-emacs--session-model-selection session-id))))
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

(defvar dsh-emacs--session-list-fetch-generation 0
  "Generation of the latest `session/list' fetch.
Every fetch increments it and keeps the value it started with; only the
response whose token still matches this variable may install its snapshot.
Concurrent refreshes can complete out of order, so an older response must
not roll the cache back below a newer one.")

;;;###autoload
(defun dsh-emacs-list-sessions--fetch ()
  "Fetch the session list via RPC and populate `dsh-emacs--sessions'."
  ;; This callback owns global caches, not the lifetime of the caller's chat.
  (dsh-emacs--server-capture-owner)
  (with-current-buffer (get-buffer-create " *dsh-session-cache*")
    (setq-local dsh-emacs--server-buffer-owner (dsh-emacs--server-capture-owner))
    (setq dsh-emacs--connection-session-status 'loading)
    (dsh-emacs-events--host-refresh-begin)
    (let ((generation (setq dsh-emacs--session-list-fetch-generation
                            (1+ dsh-emacs--session-list-fetch-generation))))
      (dsh-emacs--rpc-async "session/list" (dsh-protocol-session-list-request)
                            (lambda (ok value)
                              (unwind-protect
                                  (when (= generation
                                           dsh-emacs--session-list-fetch-generation)
                                    (setq dsh-emacs--connection-session-status
                                          (cond ((not ok) 'failed)
                                                ((and dsh-emacs-events--host-ready
                                                      dsh-emacs-events--host-process
                                                      dsh-emacs-events--client-id
                                                      (process-get dsh-emacs-events--host-process
                                                                   'dsh-control-baseline)
                                                      (process-get dsh-emacs-events--host-process
                                                                   'dsh-workspace-baseline)) 'ready)
                                                (t 'stale)))
                                    (if ok
                                        (progn
                                          ;; JSON arrays arrive as vectors; normalize
                                          ;; them before the session list renderer uses
                                          ;; `dolist', and wrap each item in a
                                          ;; `dsh-protocol-session' struct so field
                                          ;; access is centralized (protoco.el).
                                          (setq dsh-emacs--sessions
                                                (dsh-protocol-session-list--from-alist value))
                                          ;; Title/workspace may have drifted
                                          ;; (auto summary/rename/session move):
                                          ;; re-sync all live chat buffers' name and
                                          ;; default-directory.
                                          (dsh-emacs--chat-buffers-sync-all)
                                          ;; Refresh workspaces in parallel so the
                                          ;; session list can group by workspace.
                                          ;; This fetch can outlive the chat that
                                          ;; triggered it (the lazy preset link):
                                          ;; keep the installed cache, but do not
                                          ;; create a core connection when no list
                                          ;; or chat is left to own and close it.
                                          (when (dsh-emacs-events--host-needed-p)
                                            (dsh-emacs-list-workspaces)))
                                      (message "Failed to fetch session list: %s"
                                               (dsh-emacs-rpc-error-text value))))
                                ;; End the refresh span even for a superseded
                                ;; response: the depth must balance and frames
                                ;; recorded mid-flight must replay, but the stale
                                ;; snapshot must not touch the caches.
                                (dsh-emacs-events--host-refresh-drain)))))))

(defun dsh-emacs-list-sessions--fetch-when-ready (deadline generation base)
  "Poll until the server is alive, then fetch the session list.
DEADLINE is a `float-time' value: retry every 0.5 s until it passes,
then report why the list stayed empty.  The chain is non-blocking (a
`run-at-time' timer per retry), so a cold server boot never freezes the
UI, and the grace period is the same `dsh-emacs-server-wait-seconds' a
blocking start uses — a first `dsh web' boot composes the profile and
loads the plugin tree, which does not fit in a fixed few seconds.
GENERATION and BASE capture the startup that this poll belongs to."
  (when (dsh-emacs--server-current-p generation base)
    (if (dsh-emacs--server-alive-p)
        (dsh-emacs-list-sessions--fetch)
      (if (< (float-time) deadline)
          (dsh-emacs--server-run-later 0.5 nil #'dsh-emacs-list-sessions--fetch-when-ready
                                       deadline generation base)
        (message "dsh: server did not become ready within %ds%s — retry with M-x dsh-emacs"
                 dsh-emacs-server-wait-seconds
                 (if (and dsh-emacs--server-process
                          (not (process-live-p dsh-emacs--server-process)))
                     " (the server process this package started has exited; see `*dsh-server*')"
                   " (see `*dsh-server*')"))))))

(defun dsh-emacs-list-sessions ()
  "Fetch the session list and refresh workspaces.
With `dsh-emacs-server-auto-start' nil this never starts or installs a
server: an unreachable server signals a `user-error' with startup
instructions instead.  A managed process already being started by the
user is still awaited; an explicit `dsh-emacs-server-start' is
unaffected."
  (interactive)
  (dsh-emacs--server-capture-owner)
  ;; Non-blocking: launch the server in the background if auto-start is
  ;; allowed.  When the server is starting, poll until it is ready before
  ;; firing the RPC to avoid a 404 race.
  (when (and (not dsh-emacs-server-auto-start)
             (not (dsh-emacs--server-alive-p))
             (not (dsh-emacs--server-managed-p)))
    (dsh-emacs--server-unreachable-error))
  (let* ((generation dsh-emacs--server-generation)
         (base (dsh-emacs--server-base-url))
         (alive (dsh-emacs-server-start)))
    (if alive
        (dsh-emacs-list-sessions--fetch)
      ;; Server just launched — wait for it within the same grace period a
      ;; blocking start would use (see `dsh-emacs-server-wait-seconds'); a
      ;; cold boot regularly outlives a fixed few seconds.
      (dsh-emacs-list-sessions--fetch-when-ready
       (+ (float-time) dsh-emacs-server-wait-seconds) generation base))))

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
(for directories project.el does not recognize).  Any failure in the
chain yields nil (no detection)."
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

(defun dsh-emacs--workspace-id-by-path (dir workspaces)
  "Id from WORKSPACES whose canonical path equals DIR, or nil."
  (when-let* ((want (dsh-emacs--workspace-canonical-path dir))
              (ws (cl-find want workspaces
                           :test #'equal
                           :key (lambda (workspace)
                                  (dsh-emacs--workspace-canonical-path
                                   (dsh-protocol-workspace-path workspace))))))
    (dsh-protocol-workspace-workspace-id ws)))

(declare-function dsh-emacs-events--host-upsert-workspace
                  "dsh-emacs-events" (workspace))
(declare-function dsh-emacs-events-open-stream
                  "dsh-emacs-events" (process endpoint args name handler))
(declare-function dsh-emacs-events-close-stream
                  "dsh-emacs-events" (process stream-id))

(defvar-local dsh-emacs--creation-context nil
  "Creation arguments (DIRECTORY WORKSPACE PRESET SERVER ID) for a draft.")

(defvar-local dsh-emacs--creation-pending nil
  "Identity of the pending creation attempt, or nil after failure.")

(defvar dsh-emacs-draft-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'dsh-emacs-retry-session-creation)
    map)
  "Keymap for a draft awaiting session creation.")

(define-derived-mode dsh-emacs-draft-mode text-mode "DSH Draft"
  "Edit a draft while its session is being created.
Sending and session commands are unavailable until creation succeeds.
After failure, `\\[dsh-emacs-retry-session-creation]' retries without
clearing the draft, using the last session identity confirmed by the server."
  (setq-local dsh-emacs--server-buffer-owner (dsh-emacs--server-capture-owner))
  (setq-local header-line-format nil))

(defun dsh-emacs-retry-session-creation ()
  "Create the current draft's session, or retry after a failed attempt."
  (interactive)
  (unless (and (derived-mode-p 'dsh-emacs-draft-mode)
               dsh-emacs--creation-context)
    (user-error "Not in a pending session draft"))
  (when dsh-emacs--creation-pending
    (user-error "Session is still being created; draft preserved"))
  (pcase-let* ((`(,dir ,workspace ,preset ,server ,id)
                dsh-emacs--creation-context)
               (context dsh-emacs--creation-context)
               (buf (current-buffer))
               (attempt (list id)))
    (setq dsh-emacs--creation-pending attempt
          header-line-format nil)
    (cl-labels
        ((fail (reason)
           (setq dsh-emacs--creation-pending nil
                 header-line-format
                 (concat "Creation failed — C-c C-c retries: "
                         (replace-regexp-in-string "%" "%%" reason t t)))
           (message "Failed to create session: %s" reason))
         (step (fn &rest args)
           ;; Every continuation belongs to this draft and this attempt.
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (when (and (derived-mode-p 'dsh-emacs-draft-mode)
                          (eq attempt dsh-emacs--creation-pending))
                 (condition-case err
                     (if (equal server (dsh-emacs--server-base-url))
                         (apply fn args)
                       (fail "Server changed; restore the original server to retry"))
                   ((error quit) (fail (error-message-string err))))))))
         (created (ok value)
           (if (not ok)
               (if (and preset
                        (dsh-emacs--agent-preset-unavailable-p value))
                   (progn
                     ;; The server no longer has the preset this draft asked
                     ;; for (removed or renamed, e.g. a stale
                     ;; `dsh-emacs-default-preset').  The web applies the same
                     ;; recovery when restoring a saved blank Session; here
                     ;; every create carries the preset, so retry once under
                     ;; the host default and keep the fallback for manual
                     ;; retries.
                     (let ((missing preset))
                       (setq preset nil
                             context (list dir workspace nil server id)
                             dsh-emacs--creation-context context)
                       (message "Preset %s unavailable; using the host default"
                                missing))
                     (create))
                 (fail (dsh-emacs-rpc-error-text value)))
             (widen)
             (let* ((session (dsh-protocol-session--from-alist value))
                    (sid (dsh-protocol-session-session-id session))
                    (text (buffer-substring-no-properties (point-min) (point-max)))
                    (offset (- (point) (point-min)))
                    (windows (mapcar
                              (lambda (win)
                                (cons win (- (window-point win) (point-min))))
                              (get-buffer-window-list buf nil t))))
               (unless (and (stringp sid) (not (string-empty-p sid)))
                 (error "Server returned no session identity"))
               ;; A used candidate may be replaced by the server.  Preserve
               ;; its authoritative ID if activation fails and we retry.
               (setq context (list dir workspace preset server sid)
                     dsh-emacs--creation-context context)
               (when-let* ((other (gethash sid dsh-emacs--chat-buffers))
                           ((buffer-live-p other))
                           ((not (eq other buf))))
                 (user-error "Session already opened elsewhere; draft preserved"))
               (dsh-emacs--cache-new-session
                sid workspace (dsh-protocol-session-agent-preset session))
               ;; Activation replaces the draft layout.  Recover its text even
               ;; if a user mode hook or connection setup signals an error.
               (condition-case err
                   (progn
                     (dsh-emacs--activate-chat-buffer sid buf)
                     (dsh-emacs--replace-input text)
                     (goto-char (+ dsh-emacs--input-marker offset))
                     (dolist (entry windows)
                       (when (and (window-live-p (car entry))
                                  (eq (window-buffer (car entry)) buf))
                         (set-window-point
                          (car entry) (+ dsh-emacs--input-marker (cdr entry)))))
                     (when (eq (window-buffer (selected-window)) buf)
                       (setq dsh-emacs--current-session sid
                             dsh-emacs--current-buffer buf)))
                 ((error quit)
                  (remhash sid dsh-emacs--chat-buffers)
                  (let ((inhibit-read-only t))
                    (dsh-emacs-draft-mode)
                    (setq-local dsh-emacs--buffer-session nil
                                dsh-emacs--creation-context context
                                dsh-emacs--creation-pending attempt)
                    (erase-buffer)
                    (insert text)
                    (goto-char (1+ offset)))
                  (signal (car err) (cdr err)))))))
         (create ()
           (dsh-emacs--rpc-async
            "session/create"
            (dsh-protocol-session-create-request id dir workspace preset)
            (lambda (ok value) (step #'created ok value))))
         (workspace-created (ok value)
           (if (not ok)
               (fail (format "Workspace creation: %s"
                             (dsh-emacs-rpc-error-text value)))
             (let ((ws (dsh-protocol-workspace-result-workspace
                        (dsh-protocol-workspace-result--from-alist value))))
               (unless ws (error "Workspace creation returned no workspace"))
               (setq workspace (dsh-protocol-workspace-workspace-id ws))
               (dsh-emacs-events--host-upsert-workspace ws)
               (create))))
         (ready (reason)
           (if reason
               (fail reason)
             (let ((root (and (not workspace)
                              dsh-emacs-new-session-auto-project
                              (dsh-emacs--server-local-host-p)
                              (dsh-emacs--project-root dir))))
               (when root
                 (setq workspace
                       (dsh-emacs--workspace-id-by-path
                        root dsh-emacs--workspaces)))
               (if (and root (not workspace))
                   (dsh-emacs--rpc-async
                    "workspace/create" (dsh-protocol-workspace-create-request root)
                    (lambda (ok value) (step #'workspace-created ok value)))
                 (create))))))
      (step (lambda ()
              (dsh-emacs-server-ensure-async
               (lambda (reason) (step #'ready reason))))))))

;;;###autoload
(defun dsh-emacs-new-session (&optional cwd workspace-id preset)
  "Open an editable draft and create its session asynchronously.
CWD defaults to the current buffer's directory.  WORKSPACE-ID takes
precedence; otherwise a local project's workspace is resolved when
`dsh-emacs-new-session-auto-project' is non-nil.  PRESET is the agent
preset, or nil for the host default.

Interactively use the workspace under point or of the current chat.
A prefix argument selects a preset; otherwise use
`dsh-emacs-default-preset'.  Sending is unavailable until creation
succeeds.  Failures preserve the draft; C-c C-c retries.  Closing the
draft never reopens it, but a creation already accepted by the server
may still appear in the session list.  Return the draft buffer."
  (interactive
   (list nil (dsh-emacs--new-session-workspace)
         (if current-prefix-arg
             (dsh-emacs--read-preset dsh-emacs-default-preset)
           dsh-emacs-default-preset)))
  (let ((dir (dsh-emacs--absolute-cwd cwd))
        (buf (generate-new-buffer "dsh-new-session"))
        (server (dsh-emacs--server-base-url))
        (id (concat "session-emacs-"
                    (secure-hash 'sha256
                                 (format "%s:%s:%s" (float-time)
                                         (emacs-pid) (random))))))
    (with-current-buffer buf
      (dsh-emacs-draft-mode)
      (setq-local default-directory (file-name-as-directory dir)
                  dsh-emacs--creation-context
                  (list dir workspace-id preset server id)))
    (dsh-emacs-ui-navigate (point-marker) #'pop-to-buffer buf)
    (with-current-buffer buf (dsh-emacs-retry-session-creation))
    buf))

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
               dsh-emacs--sessions-buffer
               (get-buffer dsh-emacs--sessions-buffer))
      (with-current-buffer (get-buffer dsh-emacs--sessions-buffer)
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

(defun dsh-emacs--preset-choices ()
  "((DISPLAY . ID) ...) preset choices for the new-session picker.
From the cached `agentPresets/list' roster (broken entries excluded).
DISPLAY is the preset's published `name', or its id when the declaration
carries none — shipped presets publish no name.  When two preset rows
render identically, each adds its id in parentheses so that picking one
still selects a single preset.  Nil before the first roster arrives."
  (let* ((presets (and dsh-emacs--agent-presets
                       (dsh-protocol-agent-preset-list-presets
                        dsh-emacs--agent-presets)))
         (rows (delq nil
                     (mapcar
                      (lambda (p)
                        (unless (dsh-protocol-agent-preset-broken p)
                          (cons (or (dsh-protocol-agent-preset-name p)
                                    (dsh-protocol-agent-preset-id p))
                                (dsh-protocol-agent-preset-id p))))
                      presets)))
         (seen (make-hash-table :test #'equal)))
    (dolist (row rows)
      (puthash (car row) (1+ (gethash (car row) seen 0)) seen))
    (mapcar (lambda (row)
              (if (> (gethash (car row) seen) 1)
                  (cons (format "%s (%s)" (car row) (cdr row)) (cdr row))
                row))
            rows)))

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

(defun dsh-emacs--agent-preset-unavailable-p (value)
  "Non-nil when RPC error VALUE says the requested preset is unusable.
Covers `agent-preset/not-found' (the id no longer exists) and
`agent-preset/invalid' (the id resolves but cannot compose), the two
codes the dsh web drops a restored blank's preset for."
  (member (dsh-protocol-rpc-error-code
           (dsh-protocol-rpc-error--from-alist value))
          '("agent-preset/not-found" "agent-preset/invalid")))

(defun dsh-emacs--read-preset (&optional default)
  "Read an agent preset id for a new session; nil keeps the host default.
Choices come from the cached `agentPresets/list' roster; a cached roster is
refreshed in the background, while a missing one is fetched synchronously
after ensuring the server is ready, so the picker never opens without
choices.  A failed fetch signals `user-error' instead of creating with an
unchosen preset.  Pre-selects DEFAULT (the configured
`dsh-emacs-default-preset') when it is a valid choice, else the host's
`isDefault' preset — an empty RET accepts the pre-selection; without any
pre-selection picking is required (unknown input is rejected).  C-g
cancels the whole session creation."
  (if dsh-emacs--agent-presets
      (dsh-emacs--agent-presets-refresh)
    (dsh-emacs-server-ensure)
    (let ((res (dsh-emacs--rpc-request "agentPresets/list" nil)))
      (unless (car res)
        (user-error "Could not load the agent preset list: %s"
                    (dsh-emacs-rpc-error-text (cdr res))))
      (setq dsh-emacs--agent-presets
            (dsh-protocol-agent-preset-list--from-alist (cdr res)))))
  (let ((choices (dsh-emacs--preset-choices)))
    (unless choices
      (user-error "No agent presets are available"))
    (let* ((default-id (dsh-emacs--preset-default-id default))
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
            (t nil)))))

;;;###autoload
(defun dsh-emacs-open-session (session-id &optional address other-window)
  "Open SESSION-ID, optionally with subagent ADDRESS in OTHER-WINDOW.
If its chat buffer is live, just select it: transcript, draft, point and
realtime stream are preserved, and no other chat is touched.  Otherwise
initialize a new buffer and connect its per-session mux stream.  ADDRESS
applies only to that initialization; a live buffer was addressed when it
was created.  Reopening never reconnects a live buffer; use
\\[dsh-emacs-refresh] to force a resync."
  (interactive)
  (dsh-emacs--server-capture-owner)
  (when (and address
             (equal (dsh-protocol-subagent-address-mode address) "external"))
    (user-error "External subagents have no local conversation"))
  (let* ((departure (point-marker))
         (existing (gethash session-id dsh-emacs--chat-buffers))
         (live (buffer-live-p existing))
         (buf (if live
                  existing
                (dsh-emacs-server-ensure)
                ;; First open, or the buffer was killed: use the list title,
                ;; with an <N> suffix so same-titled sessions can coexist.
                (get-buffer-create
                 (generate-new-buffer-name
                  (dsh-emacs--chat-buffer-name session-id))))))
    (setq dsh-emacs--current-session session-id
          dsh-emacs--current-buffer buf)
    (unless live
      (dsh-emacs--activate-chat-buffer session-id buf address))
    (if (and address (not live))
        (prog1
            (pop-to-buffer buf
                           (when other-window '(display-buffer-pop-up-window)))
          (setq dsh-emacs--subagent-departure departure))
      (dsh-emacs-ui-navigate
       departure #'pop-to-buffer buf
       (when other-window '(display-buffer-pop-up-window))))))

(defun dsh-emacs--activate-chat-buffer (session-id buf &optional address)
  "Initialize BUF and connect it to SESSION-ID, optionally at ADDRESS.
The caller owns server readiness and window selection."
  (puthash session-id buf dsh-emacs--chat-buffers)
  (with-current-buffer buf
    (setq-local dsh-emacs--buffer-session session-id
                dsh-emacs--buffer-subagent (or address dsh-emacs--buffer-subagent))
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
    (unless dsh-emacs--buffer-subagent
      (dsh-emacs--link-session-preset session-id))
    ;; Fresh buffers start at anchor 0; the follow snapshot seeds the
    ;; transcript, so no separate history fetch precedes the connect.
    (unless dsh-emacs--buffer-subagent
      (dsh-emacs-command-catalog-prefetch session-id))
    ;; Pre-warm the skill catalog (`skills/list') too: the same "/" popup
    ;; lists commands and skills, so its first trigger should not block on
    ;; two synchronous round trips (see dsh-emacs-skill.el).
    (unless dsh-emacs--buffer-subagent
      (dsh-emacs-skill-prefetch session-id))
    ;; Pre-warm the @ reference candidate cache (files + session roster) so
    ;; the first "@" popup reads warm cache.  Buffer-local cache, so it must
    ;; run in the chat buffer (see dsh-emacs-reference.el).
    (unless dsh-emacs--buffer-subagent
      (dsh-emacs-reference-prefetch session-id))
    ;; Mode-line setup appends its anchor newline at point-max.  Return point
    ;; to the editable prompt so the cursor stays on the `❯' line.
    (goto-char dsh-emacs--input-marker)
    ;; Connect: the first `session/follow' item is the snapshot that seeds
    ;; the transcript (see `dsh-emacs-events--follow-snapshot'), followed by
    ;; gapless live event frames — no history/stream hand-off gap exists.
    (dsh-emacs--subagent-input-update)
    ;; The core connection is client-wide, not list-owned: a chat opened
    ;; directly (M-x dsh-emacs-open-session, or a new session after
    ;; `session/create') must start it too, or its queue projections,
    ;; questions and approvals never arrive.  A live connection is a no-op.
    (dsh-emacs-events-host-connect)
    (dsh-emacs-events-connect buf))
  buf)

(defun dsh-emacs-open-subagent (parent entry &optional other-window)
  "Open catalog ENTRY through its direct PARENT, optionally in OTHER-WINDOW."
  (let ((address (dsh-emacs-subagent-address parent entry)))
    (dsh-emacs-open-session (dsh-protocol-subagent-entry-id entry) address other-window)
    (dsh-emacs-subagent--refresh-summaries)))

(defun dsh-emacs-notify--open (session-id instance generation &optional endpoint-key)
  "Open SESSION-ID's chat after its desktop notification was clicked.
Reuse a live chat or resolve a closed child's direct parent from the catalog.
Raise and focus the selected frame when Emacs is graphical.
ENDPOINT-KEY is the endpoint fingerprint captured with the action; a nil
fingerprint (an action created before fingerprints existed) has expired."
  (condition-case err
      (progn
        (unless (and (equal instance dsh-emacs--connection-instance)
                     (equal endpoint-key
                            (secure-hash 'sha256 (dsh-emacs--server-base-url)))
                     (dsh-emacs--server-current-p generation (dsh-emacs--server-base-url)))
          (user-error "This dsh notification has expired"))
        (let* ((live (buffer-live-p (gethash session-id dsh-emacs--chat-buffers)))
               (owner
                (unless live
                  (catch 'found
                    (maphash
                     (lambda (parent _state)
                       (when-let* ((entry
                                    (cl-find session-id
                                             (dsh-emacs-subagent--value
                                              parent 'subagentCatalog)
                                             :test #'equal
                                             :key #'dsh-protocol-subagent-entry-id)))
                         (throw 'found (cons parent entry))))
                     dsh-emacs--subagent-catalogs)
                    nil)))
               (session (unless (or live owner)
                          (dsh-emacs--chat-session-item session-id))))
          (if (or live owner
                  (and session
                       (not (equal (dsh-protocol-session-origin session)
                                   "subagent"))))
              (progn
                (if owner
                    (dsh-emacs-open-subagent (car owner) (cdr owner))
                  (dsh-emacs-open-session session-id))
                (when (display-graphic-p)
                  (select-frame-set-input-focus (selected-frame))))
            (message "dsh: the notified session is no longer available"))))
    (error (message "dsh: cannot open the notified session (%s)"
                    (error-message-string err)))))

(defun dsh-emacs--subagent-input-update ()
  "Apply child input presentation; command guards independently enforce policy."
  (when dsh-emacs--buffer-subagent
    (setq dsh-emacs--subagent-input-read-only
          (and (dsh-emacs-subagent-input-reason dsh-emacs--buffer-subagent) t)
          buffer-read-only dsh-emacs--subagent-input-read-only)
    (dsh-emacs-composer-render)))

;; ---------------------------------------------------------------------------
;;  Switch session within the same workspace (directly from a chat buffer)
;; ---------------------------------------------------------------------------

(defun dsh-emacs--workspace-sessions (workspace-id)
  "Return SESSIONS belonging to WORKSPACE-ID, excluding archived,
subagent and blank rows.  Returns a list of session structs in recency
order."
  (when-let* ((ws (dsh-emacs--workspace-by-id workspace-id)))
    (let ((session-ids (dsh-protocol-workspace-session-ids ws)))
      (dsh-emacs-session--sort-by-recency
       (cl-remove-if
        (lambda (s)
          (or (not (dsh-emacs-session--visible-p s))
              (not (member (dsh-protocol-session-session-id s)
                           session-ids))))
        dsh-emacs--sessions)))))

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
  (when-let* ((ws (dsh-emacs--workspace-by-id workspace-id)))
    (dsh-protocol-workspace-title ws)))

(defun dsh-emacs--workspace-path (workspace-id)
  "Return the path of the workspace with WORKSPACE-ID, or nil."
  (when-let* ((ws (dsh-emacs--workspace-by-id workspace-id)))
    (dsh-protocol-workspace-path ws)))

(defun dsh-emacs--workspace-for-session (session-id)
  "Return the workspace id SESSION-ID belongs to, or nil when ungrouped."
  (when-let* ((ws (dsh-emacs--workspace-containing session-id)))
    (dsh-protocol-workspace-workspace-id ws)))


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
             (picked (dsh-emacs-ui--completing-read-ordered
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

(defun dsh-emacs--fork-failure-text (value)
  "Explain a failed `session/fork' with error VALUE.
An unavailable-preset error also lists the preset ids the server does
provide; every other failure uses the generic RPC error text."
  (let ((preset-error
         (dsh-protocol-agent-preset-error--from-alist value)))
    (if (and preset-error (cdr preset-error))
        (format "%s; available presets: %s"
                (dsh-emacs-rpc-error-text value)
                (string-join (cdr preset-error) ", "))
      (dsh-emacs-rpc-error-text value))))

;;;###autoload
(defun dsh-emacs-fork-session (session-id &optional at-seq)
  "Fork SESSION-ID into a new child session that inherits its history.
AT-SEQ selects an exact inclusive event boundary.  When omitted, the child
inherits through the latest completed turn.  After the RPC confirms, the
list refreshes and the child buffer opens with the same workspace path."
  (interactive (list (dsh-emacs--completing-session-id "Fork session: ")))
  (unless (or (null at-seq) (and (integerp at-seq) (>= at-seq 0)))
    (user-error "Invalid fork event sequence: %S" at-seq))
  (dsh-emacs-subagent-require 'mutate session-id)
  (dsh-emacs-server-ensure)
  (dsh-emacs--rpc-async "session/fork"
                        (dsh-protocol-session-fork-request session-id at-seq)
                        (lambda (ok value)
                          (if (not ok)
                              (message "Failed to fork session: %s"
                                       (dsh-emacs--fork-failure-text value))
                            (let ((child-id
                                   (dsh-protocol-session-session-id
                                    (dsh-protocol-session--from-alist value))))
                              (unless child-id
                                (user-error "session/fork returned no sessionId"))
                              (dsh-emacs-list-sessions)
                              (message "Forked %s -> %s" session-id child-id)
                              (dsh-emacs-open-session child-id))))))

(defun dsh-emacs-fork-message-at-point ()
  "Fork this conversation through the committed assistant reply at point.
The new session includes this reply and excludes later events.  Uncommitted
streams, user messages and transcript controls are not fork boundaries."
  (interactive)
  (unless (and (derived-mode-p 'dsh-emacs-mode) dsh-emacs--buffer-session)
    (user-error "No chat session in this buffer"))
  (let* ((region (dsh-emacs--assistant-message-region-at (point)))
         (seq (and region (get-text-property (car region)
                                             'dsh-emacs-message-seq))))
    (unless (and (integerp seq) (>= seq 0))
      (user-error "Point is not on a committed assistant reply"))
    (dsh-emacs-fork-session dsh-emacs--buffer-session seq)))

(defun dsh-emacs--session-preset (session-id)
  "Return the agentPreset cached for SESSION-ID, or nil when unknown."
  (when-let* ((item (dsh-emacs--chat-session-item session-id)))
    (dsh-protocol-session-agent-preset item)))

(defun dsh-emacs--link-session-preset (session-id)
  "Fill the mode-line agent preset for SESSION-ID.
Uses the cached session list when possible; otherwise refreshes
`session/list' once through `dsh-emacs-list-sessions--fetch' and lets the sync
feed the preset from the response.  SAFE outside a chat buffer: that fetch
runs from the hidden session-cache buffer, so a killed caller cannot drop the
callback, and it brackets the round trip with the refresh replay so a live
status/title frame that lands mid-flight survives the stale snapshot.
The lazy fetch also covers the ctx% snapshot on first open: a session
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
    ;; No cached row/preset yet: use the shared, replay-protected refresh
    ;; rather than installing a raw `session/list' response.  A brand-new
    ;; session on first open is missing from the cache, and a stale response
    ;; must not roll back state the core stream already delivered.
    (dsh-emacs-list-sessions--fetch)))

(defun dsh-emacs-archive-session (session-id)
  "Archive SESSION-ID: remove it from its workspace view.
`workspace/archiveSession' (still the only session-removal RPC; there is
no `session.delete'); `dsh-emacs-unarchive-session' is its dsh 0.1.6
inverse.  Refreshes the archived set and the session list on success."
  (interactive (list (dsh-emacs--completing-session-id "Archive session: ")))
  (dsh-emacs-subagent-require 'mutate session-id)
  (dsh-emacs-server-ensure)
  (dsh-emacs--rpc-async "workspace/archiveSession"
                        (dsh-protocol-workspace-archive-session-request session-id)
                        (lambda (ok value)
                          (if ok
                              (progn
                                (setq dsh-emacs--archived-sessions
                                      (dsh-emacs--normalize-archived
                                       (dsh-protocol-archived-set-archived-session-ids
                                        (dsh-protocol-archived-set--from-alist value))))
                                (dsh-emacs-list-sessions)
                                (message "Session archived"))
                            (message "Failed to archive: %s"
                                     (dsh-emacs-rpc-error-text value))))))

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
  (dsh-emacs-subagent-require 'mutate session-id)
  (dsh-emacs-server-ensure)
  (dsh-emacs--rpc-async "workspace/unarchiveSession"
                        (dsh-protocol-workspace-archive-session-request session-id)
                        (lambda (ok value)
                          (if ok
                              (progn
                                (setq dsh-emacs--archived-sessions
                                      (dsh-emacs--normalize-archived
                                       (dsh-protocol-archived-set-archived-session-ids
                                        (dsh-protocol-archived-set--from-alist value))))
                                (dsh-emacs-list-sessions)
                                (message "Session restored"))
                            (message "Failed to restore session: %s"
                                     (dsh-emacs-rpc-error-text value))))))

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
  (dsh-emacs-subagent-require 'mutate session-id)
  (dsh-emacs-server-ensure)
  (dsh-emacs--rpc-async "session/rename"
                        (dsh-protocol-session-rename-request session-id new-title)
                        (lambda (ok value)
                          (if ok
                              (progn
                                (dsh-emacs-list-sessions)
                                (message "Session renamed"))
                            (message "Failed to rename: %s"
                                     (dsh-emacs-rpc-error-text value))))))

;;; ---------------------------------------------------------------------------
;;;  Workspace management
;;; ---------------------------------------------------------------------------

(defun dsh-emacs--normalize-archived (archived)
  "Normalize ARCHIVED (JSON array) into a hash table of session ids."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (id (dsh-protocol--list archived))
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
When no core connection is open it is started, and the connect's own
`workspace/follow' baseline (opened by `dsh-emacs-events--host-open' once
the handshake completes) repaints — no immediate re-baseline is attempted
on a not-yet-handshaken socket."
  (interactive)
  (dsh-emacs-server-ensure)
  (unless (dsh-emacs-events--core-workspace-rebaseline)
    (dsh-emacs-events-host-connect)))

;;;###autoload
(defun dsh-emacs-create-workspace (path)
  "Create a workspace.  PATH is the path of an existing directory."
  (interactive "DWorkspace directory: ")
  (dsh-emacs-server-ensure)
  (dsh-emacs--rpc-async "workspace/create"
                        (dsh-protocol-workspace-create-request (expand-file-name path))
                        (lambda (ok value)
                          (if ok
                              (progn
                                (dsh-emacs-list-workspaces)
                                (message "Workspace created"))
                            (message "Failed to create workspace: %s"
                                     (dsh-emacs-rpc-error-text value))))))

;;;###autoload
(defun dsh-emacs-rename-workspace (workspace-id new-title)
  "Rename workspace."
  (interactive
   (list (read-string "Workspace id: ")
         (read-string "New workspace title: ")))
  (dsh-emacs-server-ensure)
  (dsh-emacs--rpc-async "workspace/rename"
                        (dsh-protocol-workspace-rename-request workspace-id new-title)
                        (lambda (ok value)
                          (if ok
                              (progn
                                (dsh-emacs-list-workspaces)
                                (message "Workspace renamed"))
                            (message "Failed to rename: %s"
                                     (dsh-emacs-rpc-error-text value))))))

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
                        (dsh-protocol-workspace-delete-request workspace-id)
                        (lambda (ok value)
                          (if ok
                              (progn
                                (dsh-emacs-list-workspaces)
                                (message "Workspace deleted"))
                            (message "Failed to delete: %s"
                                     (dsh-emacs-rpc-error-text value))))))

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
                        (dsh-protocol-workspace-insert-before-request
                         workspace-id before-workspace-id)
                        (lambda (ok value)
                          (if ok
                              (progn
                                (let* ((ids (dsh-protocol-workspace-order--from-alist value))
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
                            (message "Failed to reorder: %s"
                                     (dsh-emacs-rpc-error-text value))))))

;;; ---------------------------------------------------------------------------
;;;  Chat mode
;;; ---------------------------------------------------------------------------

(defvar dsh-emacs-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'dsh-emacs-send-or-stop)
    (define-key map (kbd "C-c C-b") #'dsh-emacs-interrupt-turn)
    (define-key map (kbd "C-c C-q") #'dsh-emacs-list-queue)
    (define-key map (kbd "C-c C-j") #'dsh-emacs-list-jobs)
    (define-key map (kbd "C-c C-p") #'dsh-emacs-answer-question)
    (define-key map (kbd "C-c C-r") #'dsh-emacs-refresh)
    (define-key map (kbd "C-c C-o") #'dsh-emacs-load-older-history)
    (define-key map (kbd "C-c >") #'dsh-emacs-goto-latest)
    (define-key map (kbd "C-c C-l") #'dsh-emacs-list-sessions-display)
    (define-key map (kbd "C-c C-s") #'dsh-emacs-switch-workspace-session)
    (define-key map (kbd "C-c M-s") #'dsh-emacs-switch-session)
    (define-key map (kbd "C-c C-w") #'dsh-emacs-copy-dwim)
    (define-key map (kbd "C-c C-y") #'dsh-emacs-fork-message-at-point)
    (define-key map (kbd "C-c C-f") #'dsh-emacs-modeline-toggle)
    (define-key map (kbd "C-c C-a") #'dsh-emacs-attach-file)
    (define-key map (kbd "C-c C-v") #'dsh-emacs-attach-clipboard-image)
    (define-key map (kbd "C-c C-d") #'dsh-emacs-clear-attachments)
    ;; `s-v' pastes the clipboard image when there is one, else text;
    ;; stock Emacs maps the key to `yank' globally.
    (define-key map (kbd "s-v") #'dsh-emacs-paste)
    (define-key map (kbd "C-c C-m") #'dsh-emacs-select-model)
    (define-key map (kbd "C-c C-e") #'dsh-emacs-select-effort)
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

(define-derived-mode dsh-emacs-mode fundamental-mode "DSH"
  "DeepSeek Harness chat mode.
\\{dsh-emacs-mode-map}"
  (setq-local dsh-emacs--server-buffer-owner (dsh-emacs--server-capture-owner))
  (setq-local mode-name '(:eval (dsh-emacs-modeline--mode-name)))
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
  (buffer-enable-undo)
  (setq-local comment-start "// ")
  (setq-local comment-end "")
  (dsh-emacs-input-setup-completion)
  ;; imenu: index by user message, so M-x imenu jumps to any past input.
  ;; Auto-rescan rebuilds that directory once a history page has landed.  No
  ;; `require' of imenu is needed: the command is autoloaded and both variables
  ;; it owns take buffer-local values set here.
  (setq-local imenu-create-index-function #'dsh-emacs-imenu-create-user-index)
  (setq-local imenu-auto-rescan t)
  ;; Cards and fragments answer "is this window following new output?" through
  ;; the renderer's input-anchor policy, not the UI's generic bottom check.
  (setq-local dsh-emacs-ui--following-windows-function
              #'dsh-emacs-render--following-windows)

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
  ;; A job output buffer follows this chat's socket; closing the chat closes
  ;; it too, so no window is left showing a stream nobody serves.
  (add-hook 'kill-buffer-hook #'dsh-emacs-jobs--chat-closed nil t)
  (add-hook 'kill-buffer-hook #'dsh-emacs--chat-buffer-untrack nil t)
  ;; The core connection outlives one chat; close it only when the last
  ;; owner (list or chat) is gone.  Append so the untrack hook above has
  ;; already removed this buffer from the registry.
  (add-hook 'kill-buffer-hook #'dsh-emacs-events--host-maybe-disconnect t t)
  ;; Leaving the chat mode releases ownership.  The hook runs before the
  ;; local session variable is killed, so untrack first; the owner check
  ;; then closes the core stream when this was the last owner (a failed
  ;; activation leaves the buffer in draft mode the same way).
  (add-hook 'change-major-mode-hook #'dsh-emacs-events--host-maybe-disconnect
            nil t)
  (add-hook 'change-major-mode-hook #'dsh-emacs--chat-buffer-untrack nil t)
  ;; Chat buffers are never "modified": the session transcript
  ;; is not written to disk, so closing must not prompt to save
  (add-hook 'kill-buffer-query-functions #'dsh-emacs--chat-buffer-clear-modified nil t)
  (add-hook 'after-change-functions #'dsh-emacs--chat-buffer-keep-clean nil t)
  (dsh-emacs-input-setup-editing)
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
  (dsh-emacs--subagent-input-update)
  ;; Reset Composer chrome with the buffer; the next projection or snapshot
  ;; rebuilds the chrome rows and their top marker.
  (dsh-emacs-composer-reset)
  (dsh-emacs--setup-attachments))

(defun dsh-emacs--active-session-id ()
  "Return the session id the current command context belongs to.
Resolves in this order:
1. the buffer-local `dsh-emacs--buffer-session' of the current chat buffer;
2. the global `dsh-emacs--current-session' as a fallback for list-buffer \ncommands and other contexts with no session ownership.
Interactive commands (send, interrupt, refresh, model picker) must resolve
here rather than reading the global directly: with several session buffers
open, the global points at the last-opened session while the user may be
editing inside an earlier one.  Pending drafts never use that fallback."
  (unless (derived-mode-p 'dsh-emacs-draft-mode)
    (dsh-emacs--server-capture-owner)
    (or dsh-emacs--buffer-session dsh-emacs--current-session)))

(defun dsh-emacs-current-session ()
  "Return this buffer's active session id, or the last selected id.
Return nil for an unconnected client or a pending draft.  Retired buffer
contexts signal `user-error'; this accessor never starts network work."
  (unless (memq dsh-emacs--connection-status '(disconnected disconnecting failed))
    (dsh-emacs--active-session-id)))

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

  (dsh-emacs-subagent-require 'stop)
  (let ((session-id (dsh-emacs--active-session-id)))
    (when (null session-id)
      (user-error "No session is open"))
    (dsh-emacs--rpc-async (if dsh-emacs--buffer-subagent
                              "subagents/interruptByParent" "session/cancel")
                          (if dsh-emacs--buffer-subagent
                              (dsh-protocol-subagent-stop-request dsh-emacs--buffer-subagent)
                            (dsh-protocol-session-cancel-request session-id))
                          (lambda (ok value)
                            (if ok
                                (progn
                                  ;; User-initiated stop: suppress the
                                  ;; finished-run notification.
                                  (setq dsh-emacs--turn-awaiting nil)
                                  (unless dsh-emacs--buffer-subagent
                                    (dsh-emacs--ml-busy-set nil))
                                  (message (if dsh-emacs--buffer-subagent
                                               "⏸ Stop requested"
                                             "⏸ Turn interrupted")))
                              (message "Failed to interrupt: %s"
                                       (dsh-emacs-rpc-error-text value)))))))

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
`inbox' projection frame; `\\[dsh-emacs-interrupt-turn]'
(`C-c C-b') interrupts regardless of the behavior.

Staged attachments (`C-c C-v' clipboard image, `C-c C-a' file, drop) ride
this send: they are consumed at submit time, an empty caption falls back
to the staged file names (or a count when none are named), and a `!'
line carrying attachments is ordinary caption text (the attachments reach
the model, as `dsh-emacs--submit-prompt' documents).  A staged file is
uploaded when the send starts, so the send completes after that round
trip.  A prompt carrying attachments is never recorded for `M-p' recall —
replaying it as text would drop them."
  (interactive)
  (when (derived-mode-p 'dsh-emacs-draft-mode)
    (user-error "Session is not ready; draft preserved"))
  (when dsh-emacs--buffer-subagent
    (when (or (dsh-emacs-shell-parse (dsh-emacs--get-input))
              (dsh-emacs-command-parse (dsh-emacs--get-input)))
      (user-error "Commands are unavailable in subagent conversations"))
    (unless (and (dsh-emacs--busy-p)
                 (or (string-empty-p (string-trim (dsh-emacs--get-input)))
                     (and (null current-prefix-arg)
                          (eq dsh-emacs-busy-enter-behavior 'stop))))
      (dsh-emacs-subagent-require 'send)))

  (let* ((input (dsh-emacs--get-input))
         (attachments (dsh-emacs-pending-attachments)))
    (if-let* ((command (and (null attachments)
                            (dsh-emacs-shell-parse input))))
        (dsh-emacs-shell-submit input command)
      (dsh-emacs-server-ensure)
      (let* ((busy (dsh-emacs--busy-p))
             (steer-p (consp current-prefix-arg))
             (blank-p (string-empty-p (string-trim input)))
             (empty-p (and blank-p (null attachments)))
             (text (if (and attachments blank-p)
                       (dsh-emacs--attachments-summary attachments)
                     input)))
        ;; Consume staging before submitting so even a synchronous failure
        ;; can restore this draft.  The submit path owns clearing the input:
        ;; after the echo for ordinary messages, before uploading for files.
        ;; A synchronous exception restores the exact original caption.
        (cl-labels ((submit (mode)
                      (dsh-emacs--submit-track
                       (lambda (complete)
                         (condition-case err
                             (progn
                               (when (dsh-emacs-pending-attachments)
                                 (dsh-emacs--set-pending-attachments nil))
                               (dsh-emacs--submit-prompt text attachments mode))
                           ((error quit)
                            (dsh-emacs--replace-input input)
                            (when attachments
                              (dsh-emacs--set-pending-attachments attachments))
                            (signal (car err) (cdr err))))
                         (funcall complete))
                       #'ignore)))
          (cond
           ((and steer-p (not empty-p)) (submit 'steer))
           (busy
            (if (or empty-p (eq dsh-emacs-busy-enter-behavior 'stop))
                (dsh-emacs-interrupt-turn)
              (submit dsh-emacs-busy-enter-behavior)))
           (empty-p (message "Please enter a message"))
           (t (submit nil))))))))

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

(defvar-local dsh-emacs--pending-submissions nil
  "Identities of this buffer's unsettled upload and submission steps.
Steps remain registered while their callbacks run, so handing an upload
or slash admission result to another request never exposes an idle gap.")

(defun dsh-emacs--submit-track (start callback)
  "Run START with a tracked completion callback in the originating buffer.
START receives one callback accepting the arguments expected by CALLBACK.
Register before START can consume input or yield.  Release only this step
after CALLBACK finishes, including errors and quits; synchronous startup
failures also release it and propagate.  Ignore repeated completions and
completions whose originating buffer no longer owns the step."
  (let ((origin (current-buffer))
        (step (list t))
        (finished nil))
    (push step dsh-emacs--pending-submissions)
    (cl-labels
        ((finish ()
           (setq finished t)
           (when (buffer-live-p origin)
             (with-current-buffer origin
               (setq dsh-emacs--pending-submissions
                     (delq step dsh-emacs--pending-submissions))))))
      (condition-case err
          (funcall start
                   (lambda (&rest args)
                     (unless finished
                       (setq finished t)
                       (unwind-protect
                           (when (buffer-live-p origin)
                             (with-current-buffer origin
                               (when (memq step dsh-emacs--pending-submissions)
                                 (apply callback args))))
                         (finish)))))
        ((error quit)
         (finish)
         (signal (car err) (cdr err)))))))

(defun dsh-emacs--restore-draft (text attachments)
  "Restore TEXT and the STAGED attachments of a failed submit.
Leave a newer draft alone if either its text or staged attachments is
nonempty.  A restored file entry still carries its path, so the next
submit uploads it again and never reuses a spent receipt."
  (when (and (string-empty-p (or (dsh-emacs--get-input) ""))
             (null (dsh-emacs-pending-attachments)))
    (dsh-emacs--replace-input text)
    (when attachments
      (dsh-emacs--set-pending-attachments attachments))))

(defun dsh-emacs--submit-prompt (message &optional attachments mode)
  "Submit MESSAGE to the current session.

Non-nil MODE (\"queue\" or \"steer\") submits the message into a
RUNNING turn's inbox instead of starting one — the deferred path of
`dsh-emacs--submit-deferred', which neither renders a transcript card
nor touches the spinner.  With MODE nil while the session is already
busy, the configured `dsh-emacs-busy-enter-behavior' picks the mode;
with `stop' the deferred path is never taken (`C-c C-c' interrupts
before reaching this function).

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
`dsh-emacs--submit-plain' unchanged.

ATTACHMENTS, when given, is a list of staged attachment entries: an
image alist \((mediaType . M) (data . B64) (name? . N)), or a local file
entry \((file . PATH) (name . N) (bytes . B)).  An image's bytes ride the
prompt inline; a file's bytes are uploaded to the host first and the
prompt carries the returned one-time receipt (see
`dsh-emacs--upload-file' and RPC reference §4.17), so this function may
return before anything reaches the model.  A prompt carrying attachments
is not recorded for `M-p' recall: every submit path skips it."

  (dsh-emacs-subagent-require 'send)
  (when (and dsh-emacs--buffer-subagent attachments)
    (user-error "Attachments are unavailable in subagent conversations"))
  (if (cl-some #'dsh-emacs--attachment-file-p attachments)
      ;; Own a copy for this upload's display metadata.  Clear the draft
      ;; before the first round trip, then leave later edits alone.
      (let ((staged (copy-tree attachments)))
        (dsh-emacs--submit-track
         (lambda (complete)
           (dsh-emacs--clear-input)
           (dsh-emacs--upload-attachments
            (dsh-emacs--active-session-id) staged complete))
         (lambda (ok parts err)
           (if ok
               (dsh-emacs--submit-dispatch
                message :parts parts :staged staged :mode mode
                :input-consumed t)
             ;; Nothing reached the model: restore the original staging,
             ;; unless a newer draft has taken its place.
             (dsh-emacs--restore-draft message attachments)
             (message "File upload failed: %s"
                      (if err (dsh-emacs-rpc-error-text err)
                        "transport error"))))))
    (dsh-emacs--submit-dispatch
     message :parts (delq nil (mapcar #'dsh-protocol-image-content-part
                                      attachments))
     :staged attachments :mode mode)))

(cl-defun dsh-emacs--submit-dispatch
    (message &key parts staged mode input-consumed)
  "Dispatch MESSAGE with resolved wire PARTS as MODE.
PARTS are tagged `session/prompt' content parts (image bytes inline, file
receipts) and STAGED the staged attachment entries they were resolved
from — the rollback record of this submit.  INPUT-CONSUMED means the
upload already cleared the original draft; subsequent edits belong to
another message.  This is the routing body of `dsh-emacs--submit-prompt'
once every staged file has become a receipt."
  (let ((command (and (null parts) (dsh-emacs-shell-parse message))))
    (cond
     (dsh-emacs--buffer-subagent
      (when (or command (dsh-emacs-command-parse message))
        (user-error "Commands are unavailable in subagent conversations"))
      (dsh-emacs--submit-deferred
       message :parts parts :mode (or mode 'queue) :staged staged
       :input-consumed input-consumed))
     ;; A `!' line with no attachments is a local action;
     ;; attachment captions do not go to the shell.
     (command
      (dsh-emacs-shell-submit message command))
     ((or mode
          (and (dsh-emacs--busy-p)
               (not (eq dsh-emacs-busy-enter-behavior 'stop))))
      (dsh-emacs--submit-deferred
       message :parts parts :mode mode :staged staged
       :input-consumed input-consumed))
     ((dsh-emacs-command-parse message)
      (let ((session-id (dsh-emacs--active-session-id))
            (input-buffer (current-buffer)))
        (dsh-emacs--submit-track
         (lambda (complete)
           ;; Clear the input and record it in history on submit —
           ;; without waiting for the RPC round trip (the same feel as
           ;; the web UI): whether the host admits the command is decided
           ;; by the `commands.execute' response, and the result is
           ;; rendered from the command/run + command/done session events.
           (unless parts
             (dsh-emacs--push-input-history (string-trim message)))
           (unless input-consumed
             (when (buffer-live-p input-buffer)
               (with-current-buffer input-buffer
                 (dsh-emacs--clear-input))))
           ;; Render the command line immediately (optimistic path) —
           ;; without waiting for the RPC round trip.
           (when (buffer-live-p input-buffer)
             (with-current-buffer input-buffer
               (dsh-emacs-render-command-optimistic message)))
           (dsh-emacs-command-execute
            session-id (string-trim message) parts complete))
         (lambda (ok execution err)
           ;; The callback may run inside a process filter: swallow C-g's quit.
           (condition-case nil
               (cond
                ((null ok)
                 ;; Transport failure (HTTP/parse error): clear the optimistic
                 ;; row and restore the original text and staged attachments.
                 (when (buffer-live-p input-buffer)
                   (with-current-buffer input-buffer
                     (dsh-emacs-render-command-cleanup-optimistic)
                     (dsh-emacs--restore-draft message staged)))
                 (message "Command failed to run: %s"
                          (if err (dsh-emacs-rpc-error-text err)
                            "transport error")))
                ((null execution)
                 ;; Not in the registry → clear the optimistic row and send
                 ;; it as an ordinary message (browser semantics); history was
                 ;; already recorded at submit time, so do not record it again.
                 (when (buffer-live-p input-buffer)
                   (with-current-buffer input-buffer
                     (dsh-emacs-render-command-cleanup-optimistic)))
                 (dsh-emacs--submit-plain
                  message :parts parts :staged staged
                  :history-recorded t :input-consumed t))
                (t nil))        ; accepted: the command/run event replaces it
             (quit nil))))))
     (t (dsh-emacs--submit-plain
         message :parts parts :staged staged
         :input-consumed input-consumed)))))

(cl-defun dsh-emacs--submit-deferred
    (message &key parts mode staged input-consumed)
  "Submit MESSAGE into the running turn's inbox as MODE.
MODE is `queue' (line up as the next turn) or `steer' (wake the running
agent before its next step); nil means resolve from
`dsh-emacs-busy-enter-behavior'.  The wire call is `session/prompt' with
the mode field.  Unlike `dsh-emacs--submit-plain' this renders NO
optimistic transcript card and does not touch the spinner: the item is
not part of the conversation until the host claims it (the durable
`user/message' event renders then), and the queue/steer feedback rides
the `inbox' projection frame the host pushes on the splice.  PARTS is the
resolved attachment list `dsh-emacs--submit-dispatch' carries (wire
content parts), STAGED the entries it was resolved from, for draft
rollback.  INPUT-CONSUMED skips clearing a draft already consumed before
uploading; the host admits images by the session's current model at claim
time.  Slash lines are NOT routed to `commands.execute' here — busy input
is queued as literal text, the same semantics as dsh web's busyEnter.  A
prompt carrying attachments is not recorded for `M-p' recall.
MESSAGE stays unchanged for failure recovery; outgoing text and history use
its trimmed form.
With nothing already pending in the mirror, the submit arms
`dsh-emacs-queue--mark-submit-suppress': the splice+claim transient of
this own message gets no `queued:' / `running:' echo (nothing to order
against); genuinely parked items keep their feedback."

  (dsh-emacs-subagent-require 'send)
  (when (and dsh-emacs--buffer-subagent parts)
    (user-error "Attachments are unavailable in subagent conversations"))
  (let* ((text (string-trim message))
         (mode (pcase mode
                 ((or "queue" "steer") mode)
                 ((or 'queue 'steer) (symbol-name mode))
                 ('stop "queue")
                 (_ (if (eq dsh-emacs-busy-enter-behavior 'steer) "steer" "queue"))))
         (session-id (dsh-emacs--active-session-id))
         (input-buffer (current-buffer))
         (content (dsh-protocol-prompt-content text parts))
         (payload (if dsh-emacs--buffer-subagent
                      (dsh-protocol-subagent-prompt-request
                       dsh-emacs--buffer-subagent (dsh-emacs--rpc-id) mode text
                       (dsh-emacs--client-time-zone))
                    (dsh-protocol-session-prompt-request
                     session-id (dsh-emacs--rpc-id) mode content
                     (dsh-emacs--client-time-zone)))))
    (dsh-emacs--submit-track
     (lambda (complete)
       ;; Same web-style feel as the immediate path: the draft leaves the
       ;; input area and lands in history right away, before the RPC settles.
       (unless parts
         (dsh-emacs--push-input-history text))
       (unless input-consumed
         (when (buffer-live-p input-buffer)
           (with-current-buffer input-buffer
             (dsh-emacs--clear-input))))
       ;; Queue-empty submit (busy or idle): the host still splices the message
       ;; into the inbox and claims it at the turn start; with nothing already
       ;; parked those frames do not carry any ordering information, so their
       ;; `queued:' / `running:' echoes are noise the submit path's own render
       ;; already covers (see `dsh-emacs-queue--mark-submit-suppress').
       (when (null (dsh-emacs-queue-items))
         (dsh-emacs-queue--mark-submit-suppress))
       ;; A queued message is real but its host `inbox' projection frame is still a
       ;; round trip away; show it in the Next Message row now so the send does
       ;; not feel sticky.  The host's frame or the failure branch clears it.
       (dsh-emacs-queue--optimistic-submit-show text)
       (dsh-emacs--rpc-async (if dsh-emacs--buffer-subagent
                                 "subagents/prompt" "session/prompt") payload
                                 complete))
     (lambda (ok value)
       (if ok
           ;; Enqueue/steer feedback arrives via the
           ;; `inbox' projection frame diff — and the
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
         (message "Failed to submit: %s"
                  (dsh-emacs-rpc-error-text value))
         ;; Nothing will consume the text, put it back
         ;; (same restore as the command path).
         (when (buffer-live-p input-buffer)
           (with-current-buffer input-buffer
             (dsh-emacs--restore-draft
              message staged))))))))

(cl-defun dsh-emacs--submit-plain
    (message &key parts staged history-recorded input-consumed)
  "Submit MESSAGE (a plain string) to the current session.

PARTS, when given, is the resolved attachment list
`dsh-emacs--submit-dispatch' carries: tagged wire content parts
\(`{type: \"image\", …}' with inline bytes, `{type: \"file\", receiptId}'),
appended to `content' after the caption — there is no top-level
attachment field on `session/prompt'.  STAGED is the staged attachment
list those parts were resolved from, kept for the failure branch's draft
restore (a re-submit re-uploads a staged file).  The optimistic echo is
built from STAGED, so a file attachment shows its name and size before
the host's durable reference arrives.
On acceptance the message is echoed into the transcript (when non-empty),
the running spinner lights up while the run is still awaited (a fast run
that already finished on the stream before the callback repeats must not
re-light it), and the watchdog starts.  Non-nil
HISTORY-RECORDED suppresses the input-history push: used by the slash-command
fallback after the line was already recorded at submit time.
INPUT-CONSUMED means the original draft was already cleared; leave any
subsequent input alone.
Submitting with an empty queue arms
`dsh-emacs-queue--mark-submit-suppress': the host's append+claim splice of
this prompt (the wire has no direct mode) is rendered directly and
silently, without the `queued:' / `running:' flashes.
The draft leaves the input area at submit time — the same web-style feel
as the command and deferred paths — so a second submit keypress during
the RPC round-trip reads an empty input instead of sending the message
twice; on a transport failure the draft is restored only when both the
input and staged attachments are empty (a newer draft is left alone).
MESSAGE stays unchanged for recovery; outgoing text, echo and history use
its trimmed form."

  (dsh-emacs-subagent-require 'mutate)
  (let* ((text (string-trim message))
         (session-id (dsh-emacs--active-session-id))
         (chat-buffer (and (boundp 'dsh-emacs--buffer-session)
                           dsh-emacs--buffer-session
                           (current-buffer)))
         (input-buffer (current-buffer))
         (content (dsh-protocol-prompt-content text parts))
         (payload (dsh-protocol-session-prompt-request
                   session-id (dsh-emacs--rpc-id) "queue" content
                   (dsh-emacs--client-time-zone)))
         ;; This submit's own rollback record (nil for an empty message), kept
         ;; for the failure branch: the echo is tied to the submit that made it,
         ;; not re-found by text.
         (echo-entry nil))
    (dsh-emacs--submit-track
     (lambda (complete)
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
           (unless (string-empty-p text)
             (setq dsh-emacs--pending-user-messages
                   (append dsh-emacs--pending-user-messages (list text)))
             ;; Echo the message NOW, not in the response callback: the user
             ;; pressed C-c C-c and the input is about to clear, so the
             ;; transcript must show it without waiting for the HTTP round trip
             ;; (a rejected prompt rolls the echo back, see the failure branch).
             (setq echo-entry
                   (dsh-emacs--render-user-message-optimistic
                    text staged)))
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
       (when (and (not input-consumed) (buffer-live-p input-buffer))
         (with-current-buffer input-buffer
           (dsh-emacs--clear-input)))
       (dsh-emacs--rpc-async "session/prompt" payload complete))
     (lambda (ok value)
       (if ok
           (progn
             (unless (or history-recorded parts)
               (dsh-emacs--push-input-history text))
             (when (buffer-live-p chat-buffer)
               (with-current-buffer chat-buffer
                 ;; A fast turn can end before HTTP accepts it.
                 ;; Never relight an already-finished turn.
                 (when dsh-emacs--turn-awaiting
                   (dsh-emacs--ml-busy-set t))
                 (dsh-emacs-render--follow-stream)
                 (dsh-emacs-events-ensure-follow))))
         (message "Failed to send: %s"
                  (dsh-emacs-rpc-error-text value))
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
                   (delq text
                         dsh-emacs--pending-user-messages))
             ;; A failed prompt never produces the
             ;; splice/claim frames that would settle
             ;; the suppression: clear it here
             ;; (idempotent).
             (dsh-emacs-queue--submit-suppress-clear)))
         ;; The input was cleared on submit: on a
         ;; transport failure put the draft back into
         ;; the input area.  Restore only when the input
         ;; and staged attachments are still empty — a
         ;; newer draft composed during the RPC is left
         ;; alone (matching the failure restore in
         ;; `dsh-emacs--submit-deferred').
         (when (buffer-live-p input-buffer)
           (with-current-buffer input-buffer
             (dsh-emacs--restore-draft
              message staged))))))))

;;; ---------------------------------------------------------------------------
;;;  Permission, input history and chat commands
;;; ---------------------------------------------------------------------------

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
  (dsh-emacs-subagent-require 'mutate)
  (dsh-emacs-server-ensure)
  (let ((session-id (dsh-emacs--active-session-id)))
    (unless session-id (user-error "Open or select a session first"))
    (dsh-emacs--rpc-async
     "permissionPresets/catalog" nil
     (lambda (ok value)
       (if (not ok)
           (message "Failed to list permission presets: %s"
                    (dsh-emacs-rpc-error-text value))
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
                   (message "Permission switch failed: %s"
                            (if err (dsh-emacs-rpc-error-text err)
                              "transport error")))
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

(defun dsh-emacs--render-user-message-optimistic (message attachments)
  "Render MESSAGE's transcript echo immediately, before its RPC settles.
ATTACHMENTS is a list of staged attachment entries.  An image becomes a
`{type: \"image\"}' block carrying its already-local base64, so the
renderer shows it inline with no `session/attachment' round trip.  A
staged file becomes the `{type: \"file\", attachment}'-shaped block the
host will persist, using its uploaded name and size when available.
The chip is display-only (the durable reference carries no local path).
The inserted region is recorded in `dsh-emacs--pending-user-echoes' so
`dsh-emacs--discard-user-message-echo' can roll it back when the submit is
rejected."
  (let* ((blocks (delq nil (mapcar
                            (lambda (attachment)
                              (if (dsh-emacs--attachment-file-p attachment)
                                  (let ((file (cdr (assq 'uploaded-file attachment))))
                                    `((type . "file")
                                      (attachment
                                       (name . ,(if file
                                                    (dsh-protocol-file-ref-name file)
                                                  (cdr (assq 'name attachment))))
                                       (bytes . ,(if file
                                                     (dsh-protocol-file-ref-bytes file)
                                                   (cdr (assq 'bytes attachment)))))))
                                (dsh-protocol-image-content-part attachment)))
                            attachments)))
         (event `((type . "user/message")
                  (data . ((content . ,(dsh-protocol-prompt-content
                                        message blocks))))))
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
        (dsh-emacs-render-delete-user-message start end)))
    (when (markerp start) (set-marker start nil))
    (when (markerp end) (set-marker end nil))))

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
    ;; Connect owns teardown and saves busy before disconnect clears it.
    (dsh-emacs-events-connect (current-buffer)))
   ((dsh-emacs--active-session-id)
    (message "Refresh works inside a chat buffer (last session: %s)"
             (dsh-emacs--active-session-id)))
   (t
    (message "No session to refresh"))))

(defun dsh-emacs-list-sessions-display (&optional project-root)
  "Display the session list buffer.
With PROJECT-ROOT, expand its workspace and center its header when space
permits, only while the list's window is selected.
Matching waits for the workspace cache when necessary; no workspace is
created.  Without a match, retain the active-session navigation below.

The cursor lands on the invoking chat's session row (the last opened
session outside a chat), not on whatever row the buffer was showing.
`dsh-emacs-session-jump-target' chooses its Recents or workspace occurrence:
opening the list is an explicit
\"where am I\" request, whereas a plain refresh (`g', events,
auto-refresh) keeps the row you are on.  The list is populated
asynchronously, so when that session is not in the cache yet the jump
stays pending until it is; if it sits in a folded group, that group is
expanded to show the row.  An active `w' workspace filter is cleared when
it would hide the row.

Opening reuses the cache: the session list is kept live by the core
`$events' stream (added/removed/title/archive frames) and by the local
cache update session creation already does, so a warm list is already
current and re-opening it needs no session-list round trip or
`workspace/follow' re-baseline.  Opening from a child expands its ancestors
and fetches any missing catalogs.  A cold session cache is fetched as before;
`g' and `dsh-emacs-list-sessions' remain the explicit refresh."
  (interactive)
  (let ((session-id (dsh-emacs--active-session-id))
        (buf (get-buffer-create dsh-emacs--sessions-buffer)))
    ;; Re-opening a live list must not re-run the major mode: that runs
    ;; `kill-all-local-variables', which wipes the buffer's fold overrides
    ;; (so groups the user folded with TAB come back expanded), its workspace
    ;; filter and its host-stream binding — the last one orphaned the live
    ;; stream and forced a reconnect on every open.  Keep the state and just
    ;; make sure the stream is up (an already-live stream is a no-op).
    (with-current-buffer buf
      (if (derived-mode-p 'dsh-emacs-session-mode)
          (dsh-emacs-events-host-connect)
        (dsh-emacs-session-mode)))
    ;; A warm cache is the whole state the list needs; only a cold one
    ;; (nothing fetched yet) has to be fetched.
    (unless (consp dsh-emacs--sessions)
      (dsh-emacs-list-sessions))
    ;; Select before arming/rendering: the jump excludes this window from
    ;; row restoration, and centering must operate on the window just opened.
    ;; Without a jump, the render restores this window's existing row.
    (dsh-emacs-ui-navigate (point-marker) #'pop-to-buffer buf)
    (with-current-buffer buf
      ;; Arm the target after the mode/connect step: entering a major mode
      ;; would erase a buffer-local target armed earlier.
      (setq dsh-emacs-session--auto-jump-session session-id
            dsh-emacs-session--auto-jump-project project-root)
      ;; Repaint now: a warm cache already holds the target row and the list
      ;; may be on screen, so the jump must not wait for the snapshot's own
      ;; repaint (which is a round-trip away).  A cold cache finds no row and
      ;; keeps the target armed for that repaint.
      (dsh-emacs-session--render)
      ;; A child opened elsewhere may have only summary lineage cached.
      ;; Fetch its ancestors' catalogs here; rendering itself stays read-only.
      (dolist (parent (dsh-emacs-session--ancestors session-id))
        (let ((cell (dsh-emacs-subagent--cell parent 'subagentCatalog)))
          (unless (and cell (dsh-protocol-subagent-cell-present cell))
            (dsh-emacs-subagent-refresh parent)))))
    buf))

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

(defun dsh-emacs-copy-session-id ()
  "Copy the current session id to the kill ring.
In a chat buffer this is the chat's session id.  In the session list it is
the session on the current row; a subagent row copies the child's own id."
  (interactive)
  (let ((session-id
         (cond
          ((derived-mode-p 'dsh-emacs-session-mode)
           (or (dsh-emacs-session-id-at-point)
               (user-error "No session at point")))
          ((derived-mode-p 'dsh-emacs-mode)
           (or dsh-emacs--buffer-session
               (user-error "No session is open")))
          (t (user-error "Not in a dsh chat or session list")))))
    (kill-new session-id)
    (message "Copied session id: %s" session-id)))

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
(defun dsh-emacs (&optional reconnect)
  "Open the dsh session list.
From a local project buffer, locate and expand its existing workspace.
Chat and session-list buffers retain active-session navigation.  Project
matching runs only for a local server and a non-remote directory.
With RECONNECT non-nil, reconnect to the configured service after disconnect
or a failed connection, then display the list once initialization succeeds.
Interactive calls set RECONNECT.  The service must already be running."
  (interactive (list t))
  (let ((project-root
         (and (not (derived-mode-p 'dsh-emacs-mode 'dsh-emacs-session-mode))
              (not (file-remote-p default-directory))
              (dsh-emacs--server-local-host-p)
              (dsh-emacs--project-root default-directory))))
    (cond
     ((and reconnect (eq dsh-emacs--connection-status 'connecting))
      (user-error "A dsh connection is already in progress"))
     ((and reconnect
           (memq dsh-emacs--connection-status '(disconnected failed)))
      ;; Interactive dispatch must not revive an expired callback or buffer.
      (when (or dsh-emacs--server-work-owner dsh-emacs--server-buffer-owner)
        (dsh-emacs--server-capture-owner))
      (dsh-emacs-connect
       dsh-emacs-base-url
       :callback (lambda (ok result)
                   (if ok
                       (dsh-emacs-list-sessions-display project-root)
                     (message "dsh connection failed: %s"
                              (plist-get result :message))))))
     (t (dsh-emacs-list-sessions-display project-root)))))

;;;###autoload
(defun dsh-emacs-health ()
  "Check the dsh web service status."
  (interactive)
  (dsh-emacs--rpc-async "session/list" (dsh-protocol-session-list-request)
                        (lambda (ok value)
                          (if ok
                              (message "dsh service is running")
                            (message "dsh service unreachable: %s"
                                     (dsh-emacs-rpc-error-text value))))))

(defun dsh-emacs--connection-buffers ()
  "Return the service buffers that disconnect must retire."
  (cl-remove-if-not
   (lambda (buffer)
     (with-current-buffer buffer
       (or dsh-emacs--server-buffer-owner
           (derived-mode-p 'dsh-emacs-mode 'dsh-emacs-draft-mode
                           'dsh-emacs-session-mode 'dsh-emacs-plan-mode
                           'dsh-emacs-jobs-output-mode)
           (member (buffer-name) '(" *dsh-session-cache*" " *dsh-subagent-state*"
                                   " *dsh-host*" " *dsh-connection*")))))
   (buffer-list)))

(defun dsh-emacs--connection-preflight (buffers)
  "Reject disconnect without changes when BUFFERS or active work need input."
  (let (problems)
    (when (or (active-minibuffer-window) dsh-emacs--interaction-active)
      (push "active minibuffer, question or approval" problems))
    (when (or dsh-emacs--server-callback-active dsh-emacs--server-sync-active
              dsh-emacs-events--dispatching)
      (push "a response is currently being processed" problems))
    (dolist (request dsh-emacs--server-requests)
      (when (plist-get request :write)
        (push (format "pending server write in %s"
                      (or (buffer-name (plist-get request :origin)) "closed buffer"))
              problems)))
    (dolist (buffer buffers)
      (with-current-buffer buffer
        (let (reasons)
          (when (if (derived-mode-p 'dsh-emacs-draft-mode)
                    (> (buffer-size) 0)
                  (not (string-empty-p (or (dsh-emacs--get-input) ""))))
            (push "unsent input" reasons))
          (when (and dsh-emacs--input-history-pending
                     (not (string-empty-p dsh-emacs--input-history-pending)))
            (push "recalled draft" reasons))
          (when dsh-emacs--pending-attachments (push "staged attachments" reasons))
          (when dsh-emacs--creation-pending (push "session creation" reasons))
          (when dsh-emacs--pending-submissions (push "submission or upload" reasons))
          (when (cl-some (lambda (entry) (process-live-p (cdr entry)))
                         dsh-emacs--shell-procs)
            (push "running local shell command" reasons))
          (when reasons
            (push (format "%s: %s" (buffer-name) (string-join (nreverse reasons) ", "))
                  problems)))))
    (when problems
      (user-error "Cannot disconnect: %s" (string-join (nreverse problems) "; ")))))

(defun dsh-emacs--connection-cleanup ()
  "Retire recorded buffers and clear state owned by each service module."
  ;; Stop transport before feature hooks can deliver more events or hand off work.
  (dsh-emacs-events--disconnect-state)
  (dsh-emacs--waterfall-generation-retired)
  (while dsh-emacs--connection-retiring
    (let ((buffer (car dsh-emacs--connection-retiring)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (dsh-emacs-session--auto-refresh-stop)
          (dsh-emacs-reference--reset-fetch)
          (dsh-emacs-queue--disconnect)
          (dsh-emacs-events-disconnect)
          (dsh-emacs-subagent--stop-animation)
          (dsh-emacs-render--cancel-markdown)
          (unless (kill-buffer buffer)
            (error "Buffer refused connection cleanup: %s" (buffer-name buffer)))))
      ;; Remove only completed work, so errors and quits can retry the rest.
      (pop dsh-emacs--connection-retiring)))
  (dsh-emacs-events--disconnect-state)
  (dsh-emacs-command--disconnect)
  (dsh-emacs-skill--disconnect)
  (dsh-emacs-subagent--disconnect)
  (dsh-emacs-input--disconnect)
  (cl-incf dsh-emacs--session-list-fetch-generation)
  (setq dsh-emacs--sessions nil dsh-emacs--workspaces nil
        dsh-emacs--agent-presets nil dsh-emacs--archived-sessions nil
        dsh-emacs--current-session nil dsh-emacs--current-buffer nil)
  (clrhash dsh-emacs--chat-buffers)
  (clrhash dsh-emacs--tool-calls)
  (clrhash dsh-emacs--activity-groups))

(defun dsh-emacs--connection-initialize (callback)
  "Install a cold session snapshot and core baselines, then call CALLBACK."
  (let ((owner (dsh-emacs--server-capture-owner)))
    (with-current-buffer (get-buffer-create " *dsh-connection*")
      (setq-local dsh-emacs--server-buffer-owner owner)
      (dsh-emacs-events--host-refresh-begin)
      (dsh-emacs-events-host-connect)
      (dsh-emacs--rpc-async
       "session/list" (dsh-protocol-session-list-request)
       (lambda (ok value)
         (if (not ok)
             (progn (dsh-emacs-events--host-refresh-drain) (funcall callback nil))
           (setq dsh-emacs--sessions (dsh-protocol-session-list--from-alist value))
           (dsh-emacs-events--host-refresh-drain)
           (let ((record (list :origin (current-buffer) :write nil)) timer)
             (cl-labels
                 ((cancel ()
                    (when timer (cancel-timer timer))
                    (setq dsh-emacs--server-requests
                          (delq record dsh-emacs--server-requests)))
                  (ready ()
                    (if (not (dsh-emacs--server-current-p (car owner) (cdr owner)))
                        (cancel)
                      (when-let* ((process dsh-emacs-events--host-process)
                                  ((process-get process 'dsh-control-baseline))
                                  ((process-get process 'dsh-workspace-baseline))
                                  (dsh-emacs-events--client-id))
                        (cancel)
                        (funcall callback t)))))
               (setf (plist-get record :cancel) #'cancel)
               (push record dsh-emacs--server-requests)
               (setq timer (run-at-time 0 0.05 #'ready))))))))))

(provide 'dsh-emacs)

;;; dsh-emacs.el ends here
