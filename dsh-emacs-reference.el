;;; dsh-emacs-reference.el --- @ file/session references (web-style mentions) -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.7.0
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; dsh web's `@' directive: typing `@' in the input area pops a file and session
;; reference menu.  This file is the composer side of dsh-emacs — it shares one
;; wire with the web client:
;;
;;   - `fileReferences/list'              workspace file/directory path hints
;;                                        (typert Remote, HTTP POST
;;                                        /api/fileReferences/list)
;;   - `sessionReferenceResolver/candidates'
;;                                       session reference candidates (with
;;                                       canonical mention text, HTTP POST
;;                                       /api/sessionReferenceResolver/candidates)
;;
;; Both payloads are {args: {agentId, query}} and ride the same envelope as
;; `commands.list'.  The completion popup's session rows show a short label
;; (`@label', matching web rows); a pick keeps that short `@label' text in the
;; input area as an atomic chip — the canonical
;; `@[label](dsh-session:…)' hangs off the `dsh-emacs-reference-canonical' text
;; property, and reading the input (send/history) expands that span back into
;; the full mention, so `session.prompt' still receives the host-produced
;; canonical text; once delivered, the server's agent/pre-step listener parses
;; the mention, freezes the source session snapshot and injects the context (see
;; the harness's dsh-session-reference package) — all snapshot logic lives in
;; the host, and this file is only the composer, mirroring the responsibility of
;; web's dsh-client-ui-reference.
;;
;; Syntax and insertion rules align token for token with web's grammar.ts
;; (`dsh-emacs-reference--at-token' = activeAtToken,
;; `dsh-emacs-reference--format-file-mention' = formatFileMention): `@path' /
;; `@"path with spaces' tokens; paths containing spaces use the quoted form;
;; directory candidates carry a trailing slash and keep completion open; paths
;; containing control characters or quotes are unrepresentable and are skipped;
;; `@' inside another token (an email address, say) is not a trigger.
;;
;; Discovery never blocks completion: both remotes run asynchronously while
;; the live completion table filters the last settled cache.  A shared debounce
;; coalesces query changes for every frontend.  Fresh host results are matched
;; by search fields, not by their display labels or mention punctuation.
;; Corfu refreshes its active table in place, or opens cold results through its
;; own deferred path; other frontends read new results on the next TAB.
;;
;; Provides:
;;   - `dsh-emacs-reference--at-token'      input-area `@path' / `@"path' token parsing
;;   - `dsh-emacs-reference--format-file-mention'
;;                                          candidate → hint text (matches web rules)
;;   - `dsh-emacs-reference-completion-at-point'
;;                                         `completion-at-point-functions' entry
;;   - `dsh-emacs-reference-auto-trigger-setup'
;;                                         cooperative "@" auto-trigger (corfu)
;;   - `dsh-emacs-reference--auto-complete' corfu data-fetch watcher (post-command)
;;   - `dsh-emacs-reference-prefetch'       warm the bare-query cache when a session opens
;;   - `dsh-emacs-reference'                M-x menu: completing-read picks a reference

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'dsh-emacs-protocol)
(require 'dsh-emacs-server)

(declare-function dsh-emacs--completing-read-ordered
                  "dsh-emacs.el" (prompt collection &rest args))
;; Corfu's native auto path is the same integration seam installed by
;; `dsh-emacs-mode'; use it for async refreshes instead of generic CAPF
;; dispatch, which treats a sole non-exact candidate differently.
(declare-function corfu-auto--complete-deferred "corfu-auto" (&optional tick))
(declare-function dsh-emacs--active-session-id "dsh-emacs.el" ())
(declare-function dsh-emacs--sessions-index "dsh-emacs.el" ())
;; The session list owns the visible-session rule; @ suggestions mirror it.
(declare-function dsh-emacs-session--visible-p
                  "dsh-emacs-session.el" (session &optional current-session-id))

;; dsh-emacs.el's input-area anchor (buffer-local), borrowed read-only here
(defvar dsh-emacs--input-marker)
(defvar dsh-emacs--archived-sessions)
;; Optional corfu variables (corfu-auto-trigger is defined by corfu-auto.el).
;; The forward declarations only keep byte-compile quiet; at runtime they are
;; gated with `bound-and-true-p' / `boundp'.
(defvar corfu-auto)
(defvar corfu-auto-trigger)
(defvar corfu--input)
(declare-function corfu--exhibit "corfu" ())

(defgroup dsh-emacs-reference nil
  "@ file/session references (fileReferences.list /
sessionReferenceResolver.candidates)."
  :group 'dsh-emacs)

(defcustom dsh-emacs-reference-auto-complete t
  "Whether typing \"@\" in the input area auto-pops the reference list.
dsh-emacs is a completion backend only — it never enables a completion
front-end's auto mode by itself.  When this is non-nil it contributes
\"@\" to whichever front-end already has its own auto mode turned on:
corfu (`@' added buffer-locally to `corfu-auto-trigger' when
`corfu-auto' is enabled, so corfu's engine pops on \"@\" ignoring
`corfu-auto-prefix') and company (works through `company-capf' / its own
idle delay).  Stock `*Completions*' / vertico / icomplete have no auto
channel and complete on TAB only.  When nil no trigger is contributed.
TAB and `M-x dsh-emacs-reference' always work regardless."
  :type 'boolean
  :group 'dsh-emacs-reference)

(defcustom dsh-emacs-reference-prefetch t
  "Whether opening a chat pre-fetches its bare-query @ candidate lists.
Files and sessions load asynchronously after a short idle delay for every
completion frontend, including Corfu.  A query the user has already
started takes precedence over pre-fetching."
  :type 'boolean
  :group 'dsh-emacs-reference)

(defcustom dsh-emacs-reference-prefetch-delay 0.5
  "Idle delay (seconds) before the bare-query @ pre-fetch runs.
Keeps the pre-fetch from racing the session-history load that also
starts when the chat buffer opens."
  :type 'number
  :group 'dsh-emacs-reference)

(defcustom dsh-emacs-reference-fetch-delay 0.15
  "Idle delay (seconds) before a typed @ token triggers its async fetch.
A short debounce: fast typing re-arms the timer instead of stacking
one remote round trip per keystroke.  A newer query cancels the previous
timer; a running fetch hands off to the latest query when it settles."
  :type 'number
  :group 'dsh-emacs-reference)

(defcustom dsh-emacs-reference-max-files nil
  "Maximum file/directory candidates kept in the popup at once, or nil.
Nil includes every candidate returned by the host (the default).  When
set, the host-ranked list is truncated to this many entries."
  :type '(choice (const :tag "All candidates" nil) natnum)
  :group 'dsh-emacs-reference)

(defcustom dsh-emacs-reference-max-sessions nil
  "Maximum session candidates kept in the popup at once, or nil.
Nil includes every candidate returned by the host (the default); when
set, the host-ranked list is truncated to this many entries."
  :type '(choice (const :tag "All candidates" nil) natnum)
  :group 'dsh-emacs-reference)

(defcustom dsh-emacs-reference-inline-icons t
  "Whether @ menu rows carry a per-type icon prefix (consult-buffer
style), when nerd-icons or all-the-icons is available and the frame
is graphical.

The icon is drawn with the icon package's own glyphs: a `.ts' file
row shows the TypeScript icon, a directory row the folder icon, an
extension-less path the generic file glyph, and a session row the
`references' glyph (nerd-icons; a link glyph with all-the-icons).
It rides the completion `:affixation-function', a display-only
column: the inserted text is still the plain mention.  The column is
always drawn by this module itself — no `:company-kind' metadata is
sent for the @ menu, so margin icon layers (nerd-icons-corfu,
kind-icon) never replace it: their file/folder `:fn' glyphs lose the
nerd-font family face and can render as garbage symbols.  On
non-graphical frames no icon glyphs are emitted at all (nerd-font
codepoints render as garbage in terminals): rows stay plain text.
Set to nil to always keep the rows text-only."
  :type 'boolean
  :group 'dsh-emacs-reference)

;; ---------------------------------------------------------------------------
;; Cache state (buffer-local: one per chat buffer; cleared with
;; `kill-all-local-variables' on mode re-entry, and re-warmed by prefetch when
;; a session reopens)
;; ---------------------------------------------------------------------------

(defvar-local dsh-emacs--reference-candidates nil
  "Combined candidate cache: list of (TEXT . PROPS).
TEXT is the formatted mention inserted on pick (`@path', `@path/',
`@\"path with spaces\"', or the canonical `@[label](dsh-session:...)').
PROPS is a plist: `:kind' (`file'/`directory'/`session'), `:path' for
files, `:label'/`:session-id'/`:cwd'/`:same-workspace' for sessions.
Files precede directories, which precede sessions; each group keeps the
host's deterministic order.")

(defvar-local dsh-emacs--reference-query nil
  "The query whose results `dsh-emacs--reference-candidates' holds.
Nil means nothing has been fetched into this buffer yet.")

(defvar-local dsh-emacs--reference-requested nil
  "The query the UI currently wants (nil = none yet).
Settle paths install a fetch only when it matches this value, and a
superseded fetch re-arms for it, so fast typing catches up to the
latest query without replaying intermediate keystrokes.")

(defvar-local dsh-emacs--reference-inflight nil
  "Non-nil while a reference fetch is running.
Prevents duplicate fetches for the same desired query; the settle
path clears it and re-arms when the requested query moved on.")

(defvar-local dsh-emacs--reference-fetch-gen 0
  "Generation counter guarding slice callbacks.
A newer fetch bumps it; callbacks from an older generation are
dropped instead of overwriting the newer slices out of order.")

(defvar-local dsh-emacs--reference-files nil
  "File slice: pending, failed, or a settled candidate list (possibly nil).")

(defvar-local dsh-emacs--reference-sessions nil
  "Session slice: pending, failed, or a settled candidate list (possibly nil).")

(defvar-local dsh-emacs--reference-fetch-timer nil
  "Pending debounce timer for the latest reference query.")

(defvar-local dsh-emacs--reference-pop-token nil
  "The @ token that last drove a background reference fetch.
De-dup for the data-fetch watcher: a changed query re-fetches, so
keystrokes while an @ reference is in progress keep the cache warm.")

;; ---------------------------------------------------------------------------
;; Syntax (aligned with web's packages/context/file-reference/src/grammar.ts)
;; ---------------------------------------------------------------------------

(defun dsh-emacs-reference--at-token (start end)
  "Return the active @ token in buffer region START..END, or nil.
Mirrors the web composer grammar (`activeAtToken'): a `@path' or
`@\"path' token that starts at START or after
whitespace and runs to its end.  An `@' inside another token (e.g. an
email address) is not a trigger.  Returns (PREFIX QUERY QUOTED):
PREFIX the raw token span (\"@…\" or \"@\"…\"), QUERY the path text
after the marker, QUOTED non-nil for the quoted form.
Scan backward in the buffer and copy only the resulting token."
  (save-excursion
    (goto-char end)
    (let* ((quote (search-backward "\"" start t))
           ;; Only the last quote can open a quoted token reaching END.
           (quoted (and quote (> quote start)
                        (eq (char-before quote) ?@)
                        (or (= (1- quote) start)
                            (memq (char-before (1- quote))
                                  '(?\s ?\t ?\r ?\n ?\f)))
                        t)))
      (if quoted
          (backward-char)
        (goto-char end)
        (skip-chars-backward "^ \t\r\n\f" start))
      (when (and (< (point) end) (eq (char-after) ?@))
        (list (buffer-substring-no-properties (point) end)
              (buffer-substring-no-properties
               (+ (point) (if quoted 2 1)) end)
              quoted)))))

(defun dsh-emacs-reference--format-file-mention (path kind &optional preserve-quote)
  "Format file PATH (KIND is the wire string `file'/`directory') as prompt text.
Web `formatFileMention' semantics:
- directory paths gain a trailing \"/\" so completion can descend;
- paths containing whitespace are wrapped in the quoted form; a
  quoted directory keeps its quote open (\"@\"path/) so typing can
  drill another level;
- paths with control characters or a double quote are NOT
  representable: returns nil and the candidate is skipped.
PRESERVE-QUOTE keeps the quoted form even when unnecessary (the
user's own quote stays open)."
  (let ((path (if (equal kind "directory") (concat path "/") path)))
    (unless (string-match-p "[\000-\037\177-\237\"]" path)
      (let ((quoted (or preserve-quote
                        (string-match-p "[ \t\r\n\f]" path))))
        (cond
         ((not quoted) (concat "@" path))
         ((equal kind "directory") (concat "@\"" path))
         (t (concat "@\"" path "\"")))))))

;; ---------------------------------------------------------------------------
;; Candidate normalization (wire array → cache entries)
;; ---------------------------------------------------------------------------

(defun dsh-emacs-reference--collect-files (value)
  "Normalize a `fileReferences/list' VALUE into cache entries.
Each entry is (TEXT . (:kind file|directory :path PATH)); candidates
whose path the mention grammar cannot represent are skipped.  Rows
are grouped files-first, then directories (the host ranks directories
ahead of files on equal scores; the menu shows files before
directories), each kind group keeping the host's rank order."
  (let* ((entries (delq nil
                        (mapcar
                         (lambda (wire)
                           (let* ((candidate (dsh-protocol-file-reference-candidate--from-alist
                                              wire))
                                  (path (dsh-protocol-file-reference-candidate-path
                                         candidate))
                                  (kind (dsh-protocol-file-reference-candidate-kind
                                         candidate))
                                  (text (dsh-emacs-reference--format-file-mention
                                         path kind)))
                             (and text
                                  (cons text
                                        (list :kind (intern kind) :path path)))))
                         (dsh-protocol--list value))))
         (dir-p (lambda (entry)
                  (eq (plist-get (cdr entry) :kind) 'directory))))
    (append (cl-remove-if dir-p entries)
            (cl-remove-if-not dir-p entries))))

(defun dsh-emacs-reference--collect-sessions (value)
  "Normalize a `sessionReferenceResolver/candidates' VALUE into cache entries.
Each entry is (TEXT . (:kind session :label L :session-id ID :cwd CWD
:same-workspace SW)) with TEXT the host's canonical mention — the
exact prompt text the pick inserts.  A candidate without a mention is
skipped: the client must not invent references outside the canonical
URI encoding.  Host rank order is kept."
  (delq nil
        (mapcar
         (lambda (wire)
           (let* ((candidate (dsh-protocol-session-reference-candidate--from-alist
                              wire))
                  (mention (dsh-protocol-session-reference-candidate-mention
                            candidate)))
             (and (stringp mention)
                  (cons mention
                        (list :kind 'session
                              :label (dsh-protocol-session-reference-candidate-label
                                      candidate)
                              :session-id (dsh-protocol-session-reference-candidate-session-id
                                           candidate)
                              :cwd (dsh-protocol-session-reference-candidate-cwd
                                    candidate)
                              :same-workspace (dsh-protocol-session-reference-candidate-same-workspace
                                               candidate))))))
         (dsh-protocol--list value))))

(defun dsh-emacs-reference--combine (files sessions)
  "Deterministic cache order: files, directories, then SESSIONS.
Each group keeps its host order; a non-nil configured cap truncates it."
  (append (if dsh-emacs-reference-max-files
              (cl-subseq files 0
                         (min (length files) dsh-emacs-reference-max-files))
            files)
          (if dsh-emacs-reference-max-sessions
              (cl-subseq sessions 0
                         (min (length sessions)
                              dsh-emacs-reference-max-sessions))
            sessions)))

;; ---------------------------------------------------------------------------
;; Fetch state machine
;; ---------------------------------------------------------------------------

(defun dsh-emacs-reference--fetch-query (session-id query)
  "Fetch both reference slices for SESSION-ID and QUERY asynchronously.
Only one generation runs at a time; obsolete callbacks cannot alter a
newer generation.  Empty and failed replies are distinct from pending."
  (when (and session-id query
             (not (equal query dsh-emacs--reference-query))
             (not dsh-emacs--reference-inflight))
    (when (timerp dsh-emacs--reference-fetch-timer)
      (cancel-timer dsh-emacs--reference-fetch-timer))
    (setq dsh-emacs--reference-fetch-timer nil
          dsh-emacs--reference-inflight t
          dsh-emacs--reference-files 'pending
          dsh-emacs--reference-sessions 'pending)
    (let ((gen (cl-incf dsh-emacs--reference-fetch-gen)))
      (dsh-emacs--rpc-async
       "fileReferences/list"
       (dsh-protocol-reference-query-request session-id query)
       (lambda (ok value)
         (when (= gen dsh-emacs--reference-fetch-gen)
           (setq dsh-emacs--reference-files
                 (if ok (dsh-emacs-reference--collect-files value)
                   (message "Reference file discovery failed: %s" value)
                   'failed))
           (dsh-emacs-reference--fetch-settle session-id query))))
      (dsh-emacs--rpc-async
       "sessionReferenceResolver/candidates"
       (dsh-protocol-reference-query-request session-id query)
       (lambda (ok value)
         (when (= gen dsh-emacs--reference-fetch-gen)
           (setq dsh-emacs--reference-sessions
                 (if ok (dsh-emacs-reference--collect-sessions value)
                   (message "Reference session discovery failed: %s" value)
                   'failed))
           (dsh-emacs-reference--fetch-settle session-id query)))))
    t))

(defun dsh-emacs-reference--fetch-settle (session-id query)
  "Install QUERY only after both slices settle, or request the latest query.
A total failure keeps the old cache and allows the next trigger to retry."
  (unless (or (eq dsh-emacs--reference-files 'pending)
              (eq dsh-emacs--reference-sessions 'pending))
    (setq dsh-emacs--reference-inflight nil)
    (if (equal query dsh-emacs--reference-requested)
        (when (or (listp dsh-emacs--reference-files)
                  (listp dsh-emacs--reference-sessions))
          (setq dsh-emacs--reference-query query
                dsh-emacs--reference-candidates
                (dsh-emacs-reference--combine
                 (and (listp dsh-emacs--reference-files)
                      dsh-emacs--reference-files)
                 (and (listp dsh-emacs--reference-sessions)
                      dsh-emacs--reference-sessions)))
          (dsh-emacs-reference--schedule-popup-refresh))
      (when dsh-emacs--reference-requested
        (dsh-emacs-reference--require-cache
         session-id dsh-emacs--reference-requested)))))

(defun dsh-emacs-reference--schedule-popup-refresh ()
  "Let Corfu display newly settled results for the still-active @ token.
Refresh an existing reference table in place, retaining selection when
possible.  Cold results use Corfu's deferred path, never generic CAPF
insertion.  Other frontends see the new table on their next completion."
  (let ((buf (current-buffer)))
    (run-with-idle-timer
     0 nil
     (lambda ()
       (when (and (buffer-live-p buf)
                  (eq (window-buffer (selected-window)) buf)
                  (not (active-minibuffer-window))
                  (not (memq last-command
                             '(keyboard-quit keyboard-escape-quit corfu-quit))))
         (with-current-buffer buf
           (when-let* (((and dsh-emacs-reference-auto-complete
                             (bound-and-true-p corfu-auto)))
                       (token (dsh-emacs-reference--active-token))
                       ((equal (nth 1 token) dsh-emacs--reference-requested))
                       ((equal dsh-emacs--reference-query
                               dsh-emacs--reference-requested)))
             (if (bound-and-true-p completion-in-region-mode)
                 (when (and (fboundp 'corfu--exhibit)
                            (eq (completion-metadata-get
                                 (completion-metadata
                                  "" (nth 2 completion-in-region--data)
                                  (nth 3 completion-in-region--data))
                                 'category)
                                'dsh-emacs-reference))
                   ;; Corfu otherwise skips recomputation when text is unchanged.
                   (setq corfu--input nil)
                   (corfu--exhibit))
               (when (fboundp 'corfu-auto--complete-deferred)
                 (corfu-auto--complete-deferred))))))))))

(defun dsh-emacs-reference--require-cache (session-id query)
  "Request QUERY for SESSION-ID without blocking; return cache availability.
Keep serving the previous results while both remotes run asynchronously.
Repeated reads share one timer or in-flight request, independent of the
completion frontend.  Empty queries and directory drills start immediately."
  (unless (equal query dsh-emacs--reference-requested)
    (when (timerp dsh-emacs--reference-fetch-timer)
      (cancel-timer dsh-emacs--reference-fetch-timer))
    (setq dsh-emacs--reference-fetch-timer nil
          dsh-emacs--reference-requested query))
  (when (and session-id query
             (not (equal query dsh-emacs--reference-query))
             (not dsh-emacs--reference-inflight)
             (not dsh-emacs--reference-fetch-timer))
    (let* ((buf (current-buffer))
           (gen dsh-emacs--reference-fetch-gen)
           (timer nil))
      (setq timer
            (run-with-idle-timer
             (if (or (null dsh-emacs--reference-query)
                     (string-empty-p query) (string-suffix-p "/" query))
                 0
               dsh-emacs-reference-fetch-delay)
             nil
             (lambda ()
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   ;; Only this timer may drop the handle: a superseded
                   ;; callback must not unhook the timer that replaced it,
                   ;; and a live one must never leave a dead handle behind.
                   (when (eq timer dsh-emacs--reference-fetch-timer)
                     (setq dsh-emacs--reference-fetch-timer nil)
                     (when (and (= gen dsh-emacs--reference-fetch-gen)
                                (equal query dsh-emacs--reference-requested))
                       (dsh-emacs-reference--fetch-query session-id query)))))
               nil)))
      (setq dsh-emacs--reference-fetch-timer timer)))
  (not (null dsh-emacs--reference-query)))

;; ---------------------------------------------------------------------------
;; corfu data-fetch watcher: @ candidates come from the host dynamically per
;; query (unlike slash's static catalog).  The watcher only fetches in the
;; background when the @ token changes, and the popup is opened by the corfu
;; trigger / async refresh; dsh-emacs never drives the completion UI itself (see
;; the hookup in `dsh-emacs-mode').
;; ---------------------------------------------------------------------------

(defun dsh-emacs-reference--active-token ()
  "Return the active @ token ending at point, or nil.
Extracts the token from the editable input text (input marker to
point); nil outside a chat buffer or when no `@path' / `@\"path' token
is in progress at the cursor.  A COMPLETED host session mention
(`@[label](dsh-session:…)') is not an active token: the web keeps it
behind an atomic chip so typing after a pick never re-opens the menu,
and our M-x insert must not swallow it either.  Returns (PREFIX QUERY
QUOTED), see `dsh-emacs-reference--at-token'."
  (when (and dsh-emacs--input-marker
             (markerp dsh-emacs--input-marker)
             (eq (marker-buffer dsh-emacs--input-marker) (current-buffer))
             (>= (point) (marker-position dsh-emacs--input-marker)))
    (let ((token (dsh-emacs-reference--at-token
                  (marker-position dsh-emacs--input-marker) (point))))
      (and token
           ;; Completed canonical mention text (the host escapes `\` and `]`
           ;; in the label as `\\` / `\]`; see the harness's
           ;; formatSessionReferenceMention for the exact convention):
           ;; label area = any number of (escape pair `\X` | a char that is
           ;; neither `]` nor `\`), then the closing
           ;; `](dsh-session:<base64url>)`.
           (not (string-match-p
                 "\\`@\\[\\(?:\\\\.\\|[^]\\\\]\\)*\\](dsh-session:[A-Za-z0-9_-]+)\\'"
                 (nth 0 token)))
           ;; A completed file reference is an atomic chip in the buffer: it
           ;; has no session-style canonical form to exclude, but its `@path'
           ;; text is still recognized as an active token by the @-token
           ;; grammar.  A token whose start falls on a chip is a "completed
           ;; reference", not a token being typed — otherwise moving the cursor
           ;; back beside a previous reference would make the watcher re-fetch
           ;; by that reference's path and narrow the candidate cache again (the
           ;; next @ would only offer the previous one's candidates).
           (not (and (>= (point) (length (nth 0 token)))
                     (get-text-property
                      (- (point) (length (nth 0 token)))
                      'dsh-emacs-reference-chip)))
           token))))

(defun dsh-emacs-reference--auto-complete ()
  "Keep the current Corfu @ query warm through the shared async cache path."
  (when (and dsh-emacs-reference-auto-complete (bound-and-true-p corfu-auto))
    (let ((token (dsh-emacs-reference--active-token)))
      (unless (equal token dsh-emacs--reference-pop-token)
        (setq dsh-emacs--reference-pop-token token)
        (if token
            (dsh-emacs-reference--require-cache
             (dsh-emacs--active-session-id) (nth 1 token))
          (when (timerp dsh-emacs--reference-fetch-timer)
            (cancel-timer dsh-emacs--reference-fetch-timer))
          (setq dsh-emacs--reference-fetch-timer nil
                dsh-emacs--reference-requested nil))))))

(defun dsh-emacs-reference-prefetch (session-id)
  "Warm SESSION-ID's bare-query references after a short idle delay.
All completion frontends share this cache.  Do not supersede a query the
user has already started or a cache that is already populated."
  (when (and dsh-emacs-reference-prefetch session-id
             (null dsh-emacs--reference-query)
             (null dsh-emacs--reference-requested)
             (not dsh-emacs--reference-inflight))
    (let ((buf (current-buffer)))
      (run-with-idle-timer
       dsh-emacs-reference-prefetch-delay nil
       (lambda ()
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (when (and (equal (dsh-emacs--active-session-id) session-id)
                        (null dsh-emacs--reference-query)
                        (null dsh-emacs--reference-requested)
                        (not dsh-emacs--reference-inflight))
               (setq dsh-emacs--reference-requested "")
               (dsh-emacs-reference--fetch-query session-id "")))))))))

;; ---------------------------------------------------------------------------
;; Completion UI side
;; ---------------------------------------------------------------------------

(defun dsh-emacs-reference--visible-candidates ()
  "Return cached suggestions excluding the sessions the session list hides.
A session is hidden when it is archived, blank (never messaged) or of
subagent origin, mirroring the list's visible-session rule.  The synced
archive registry is consulted first, so an archived id disappears even
when the list cache does not know it; a candidate whose session is
unknown stays offered.  Keep the raw cache intact so unarchiving or a
first message restores candidates without a fetch."
  (let ((index (dsh-emacs--sessions-index)))
    (cl-remove-if
     (lambda (entry)
       (and (eq (plist-get (cdr entry) :kind) 'session)
            (let ((id (plist-get (cdr entry) :session-id)))
              (or (and dsh-emacs--archived-sessions
                       (gethash id dsh-emacs--archived-sessions))
                  (let ((session (and id (gethash id index))))
                    (and session
                         (not (dsh-emacs-session--visible-p session))))))))
     dsh-emacs--reference-candidates)))

(defun dsh-emacs-reference--session-rows (&optional entries)
  "Alist (ROW . MENTION) for every session cache entry, in cache order.
ENTRIES defaults to the current cache.  ROW is the short completion row
(`@label'; a repeated label gains a ` #n' suffix so every session stays
reachable); MENTION is the canonical text the pick inserts.  Every
final ROW is unique: a label that already reads like a suffixed row
(`same #2') cannot steal a generated one, so the exit lookup stays
unambiguous.  File/directory entries are their own row and never appear
here."
  (let ((seen (make-hash-table :test 'equal))
        (used (make-hash-table :test 'equal)))
    (delq nil
          (mapcar
           (lambda (entry)
             (when (eq (plist-get (cdr entry) :kind) 'session)
               (let* ((props (cdr entry))
                      (label (or (plist-get props :label)
                                 (plist-get props :session-id)))
                      (base (concat "@" label))
                      (n (1+ (gethash base seen 0)))
                      (row (if (= n 1) base (format "%s #%d" base n))))
                 (while (gethash row used)
                   (setq n (1+ n)
                         row (format "%s #%d" base n)))
                 (puthash base n seen)
                 (puthash row t used)
                 (cons row (car entry)))))
           (or entries dsh-emacs--reference-candidates)))))

(defun dsh-emacs-reference--entry-for (text)
  "The cache entry (MENTION . PROPS) behind completion row TEXT.
File/directory rows are their own mention; a session row (the short
`@label' display) resolves through `dsh-emacs-reference--session-rows'
to its canonical mention first."
  (or (assoc text dsh-emacs--reference-candidates)
      (let ((mention (cdr (assoc text (dsh-emacs-reference--session-rows)))))
        (and mention (assoc mention dsh-emacs--reference-candidates)))))

(defun dsh-emacs-reference--row-icon (path kind)
  "Type icon for a completion row of KIND, or nil when none can render.
KIND is `file', `directory' or `session'.  Prefers nerd-icons (its
`icon-for-file' picks the glyph by the file's extension,
`icon-for-dir' the folder glyph, and the codicon `references' marks
session mentions — the same glyph nerd-icons-corfu used for the
`reference' kind), then all-the-icons (a link glyph for sessions).
PATH is the file/directory path, ignored for sessions.  Returns nil
on non-graphic frames — nerd-font PUA codepoints render as garbage in
terminals, so icon-free setups get plain text rows there — and nil
when no icon provider is loaded."
  (when (display-graphic-p)
    (cond
     ((and (featurep 'nerd-icons)
           (fboundp 'nerd-icons-icon-for-file)
           (fboundp 'nerd-icons-icon-for-dir))
      (if (eq kind 'session)
          (nerd-icons-codicon "nf-cod-references")
        (funcall (symbol-function (if (eq kind 'directory)
                                      'nerd-icons-icon-for-dir
                                    'nerd-icons-icon-for-file))
                 path)))
     ((and (featurep 'all-the-icons)
           (fboundp 'all-the-icons-icon-for-file)
           (fboundp 'all-the-icons-icon-for-dir))
      (if (eq kind 'session)
          (all-the-icons-faicon "link")
        (funcall (symbol-function (if (eq kind 'directory)
                                      'all-the-icons-icon-for-dir
                                    'all-the-icons-icon-for-file))
                 path)))
     (t nil))))

(defun dsh-emacs-reference--snapshot-affix (entries rows)
  "Map completion rows to their (KIND . PATH) icon metadata.
ENTRIES is the cache snapshot the table renders, ROWS the session rows
that alias canonical mentions.  The returned hash owns its copy, so a
later cache reply cannot change it; building it is linear in the rows
instead of scanning the full cache for each one."
  (let ((map (make-hash-table :test 'equal)))
    (dolist (entry entries)
      (unless (gethash (car entry) map)
        (puthash (car entry)
                 (cons (plist-get (cdr entry) :kind)
                       (plist-get (cdr entry) :path))
                 map)))
    (dolist (row rows)
      (unless (gethash (car row) map)
        (puthash (car row) (gethash (cdr row) map) map)))
    map))

(defun dsh-emacs-reference--affixate-with (map cands)
  "Build the (CAND PREFIX SUFFIX) rows the popup renders.
PREFIX is the per-type icon (consult-buffer style, see
`dsh-emacs-reference--row-icon') resolved from MAP, the captured
TEXT -> (KIND . PATH) snapshot `dsh-emacs-reference--snapshot-affix'
took when the table was built: a file's extension glyph, the folder
glyph for directories, the `references'/link glyph for session rows.
Prefixes are empty on non-graphic frames, when
`dsh-emacs-reference-inline-icons' is nil or when no icon provider is
loaded.  The column is drawn by this module itself: no `:company-kind'
metadata is sent, so margin icon layers (nerd-icons-corfu, kind-icon)
never replace it — their file/folder `:fn' glyphs lose the nerd-font
family face and can render as garbage symbols.  SUFFIX is always empty:
completion rows show no annotation.  The icon column is display-only:
completion inserts the plain candidate regardless."
  (mapcar
   (lambda (cand)
     (let* ((kp (gethash cand map))
            (kind (car kp))
            (icon (and dsh-emacs-reference-inline-icons
                       kind
                       (dsh-emacs-reference--row-icon (cdr kp) kind))))
       (list cand
             (if icon (concat icon " ") "")
             "")))
   cands))

(defun dsh-emacs-reference--reset-fetch ()
  "Invalidate requests after a pick so the next @ can broaden its results."
  (when (timerp dsh-emacs--reference-fetch-timer)
    (cancel-timer dsh-emacs--reference-fetch-timer))
  (cl-incf dsh-emacs--reference-fetch-gen)
  (setq dsh-emacs--reference-fetch-timer nil
        dsh-emacs--reference-requested nil
        dsh-emacs--reference-query nil
        dsh-emacs--reference-inflight nil
        dsh-emacs--reference-pop-token nil))

(defun dsh-emacs-reference--exit (cand status rows)
  "Finish a picked @ candidate CAND in the composer.
The completion UI already inserted CAND's row text; ROWS maps session rows to
their canonical mention.  A session row is kept as its short `@label' text and
wrapped as an atomic composer chip that stores the canonical mention in a
`dsh-emacs-reference-canonical' text property — sending
(`dsh-emacs-reference--expanded-text') expands the span back to the wire form.
A file row stays editable but is styled as a composer link (RET/mouse opens
it); a directory row keeps its `@dir/' token and its children are fetched so
drilling can continue.  Only accepted STATUS values `finished' and
`sole' finalize a reference; an ambiguous `exact' remains editable."
  (let* ((entry (dsh-emacs-reference--entry-for cand))
         (props (cdr entry))
         (mention (cdr (assoc cand rows)))
         (start (- (point) (length cand))))
    (when (and (memq status '(finished sole))
               (>= start (point-min))
               (string= (buffer-substring-no-properties start (point)) cand))
      ;; A picked directory already ends in "/".  Fetch its children now, so
      ;; the settled callback re-enters the active @dir/ token for the next
      ;; level without another slash.
      (when (eq (plist-get props :kind) 'directory)
        (setq dsh-emacs--reference-requested
              (concat (plist-get props :path) "/")
              dsh-emacs--reference-query nil)
        (dsh-emacs-reference--fetch-query
         (dsh-emacs--active-session-id) dsh-emacs--reference-requested))
      (if mention
          (progn
            ;; The picked session row is the short `@label' the front-end
            ;; already inserted: keep that text and mark it an atomic chip that
            ;; carries the canonical mention as a text property for send-time
            ;; expansion (no delete + insert of the long mention, no `display'
            ;; folding).
            (dsh-emacs-reference--session-chip start (point) mention)
            ;; This mention consumed the @ token; forget the narrowed fetch so
            ;; the next `@' re-broadens to the full list.
            (dsh-emacs-reference--reset-fetch))
        ;; File pick: keep its text, style it as an atomic composer chip.
        (when (eq (plist-get props :kind) 'file)
          (dsh-emacs-reference--composer-file-chip
           start (point) (plist-get props :path))
          (dsh-emacs-reference--reset-fetch))))))

(defconst dsh-emacs-reference--table-action 'dsh-emacs-reference--search-fields
  "Completion-table action returning rows matched by reference search fields.
The `dsh-emacs-reference-search' style asks for it; the table built by
`dsh-emacs-reference-completion-at-point' owns the answering branch.")

(defun dsh-emacs-reference--all-completions (string table pred _point)
  "Complete STRING using TABLE's reference search fields and PRED."
  (let ((matches (funcall table string pred dsh-emacs-reference--table-action)))
    (when matches (nconc matches 0))))

(defun dsh-emacs-reference--try-completion (string table pred point)
  "Try STRING against reference TABLE with PRED, preserving POINT.
A multi-row answer is returned unchanged, so matching rows stay
visible instead of being expanded into a partial token."
  (let ((matches (funcall table string pred dsh-emacs-reference--table-action)))
    (cond
     ((null matches) nil)
     ((cdr matches) (cons string point))
     ((equal string (car matches)) t)
     (t (cons (car matches) (length (car matches)))))))

(defun dsh-emacs-reference--search-rows (string pred candidates snapshot
                                                session-id)
  "Rows of CANDIDATES matching the @ token STRING is completing.
PRED is the completion predicate, SNAPSHOT the cache entries parallel
to CANDIDATES whose search fields are matched, and SESSION-ID the
buffer session.  The table refreshes its snapshot before dispatching,
so the live cache query says whether the host already answered STRING:
when it did, its matches are returned unchanged; otherwise each query
character must appear in order in the path, label, session id or
workspace.  An @ token also requests a background fetch."
  (let* ((query (cond ((string-prefix-p "@\"" string)
                       (substring string 2))
                      ((string-prefix-p "@" string)
                       (substring string 1))
                      (t string)))
         (normalized (downcase (subst-char-in-string ?\\ ?/ query)))
         (fresh (equal query dsh-emacs--reference-query))
         (regexp (mapconcat
                  (lambda (char)
                    (regexp-quote (char-to-string char)))
                  normalized ".*"))
         (case-fold-search t))
    (when (string-prefix-p "@" string)
      (dsh-emacs-reference--require-cache session-id query))
    (all-completions
     ""
     (cl-loop for row in candidates
              for entry in snapshot
              for props = (cdr entry)
              when (or fresh (string-empty-p query)
                       (cl-some
                        (lambda (value)
                          (and (stringp value)
                               (string-match-p
                                regexp
                                (subst-char-in-string ?\\ ?/ value))))
                        (list (plist-get props :path)
                              (plist-get props :label)
                              (plist-get props :session-id)
                              (plist-get props :cwd))))
              collect row)
     pred)))

;; Match search fields, not mention syntax.  User category overrides still win.
(add-to-list 'completion-styles-alist
             '(dsh-emacs-reference-search
               dsh-emacs-reference--try-completion
               dsh-emacs-reference--all-completions
               "Host-ranked references with case-insensitive cached matching."))
(add-to-list 'completion-category-defaults
             '(dsh-emacs-reference (styles dsh-emacs-reference-search)))

(defun dsh-emacs-reference-completion-at-point ()
  "Complete the active @ token without waiting for the network.
The table follows asynchronous cache replacements.  Fresh host matches
are authoritative; while a query is loading, match cached paths and
session labels, IDs and directories case-insensitively.  Formatting
and quoting affect insertion only, not matching."
  (when-let* ((token (dsh-emacs-reference--active-token))
              (session-id (dsh-emacs--active-session-id)))
    (let* ((buf (current-buffer))
           (pos (point))
           (start (- pos (length (car token))))
           (quoted (nth 2 token))
           (source 'uninitialized)
           source-query source-archives snapshot rows candidates affix
           (table
            (lambda (string pred action)
              (when (buffer-live-p buf)
                (with-current-buffer buf
                  (unless (and (eq source dsh-emacs--reference-candidates)
                               (eq source-archives dsh-emacs--archived-sessions)
                               (equal source-query dsh-emacs--reference-query))
                    (setq source dsh-emacs--reference-candidates
                          source-query dsh-emacs--reference-query
                          source-archives dsh-emacs--archived-sessions
                          snapshot
                          (mapcar
                           (lambda (entry)
                             (let* ((props (cdr entry))
                                    (kind (plist-get props :kind)))
                               (cons (if (memq kind '(file directory))
                                         (dsh-emacs-reference--format-file-mention
                                          (plist-get props :path)
                                          (symbol-name kind) quoted)
                                       (car entry))
                                     props)))
                           (dsh-emacs-reference--visible-candidates)))
                    (let ((mention-to-row (make-hash-table :test 'equal)))
                      (setq rows (dsh-emacs-reference--session-rows snapshot))
                      (dolist (row rows)
                        (puthash (cdr row) (car row) mention-to-row))
                      (setq candidates
                            (mapcar (lambda (entry)
                                      (or (gethash (car entry) mention-to-row)
                                          (car entry)))
                                    snapshot)
                            affix (dsh-emacs-reference--snapshot-affix
                                   snapshot rows))))
                  (cond
                   ((eq action 'metadata)
                    '(metadata (category . dsh-emacs-reference)
                               (display-sort-function . identity)
                               (cycle-sort-function . identity)))
                   ((eq action dsh-emacs-reference--table-action)
                    (dsh-emacs-reference--search-rows
                     string pred candidates snapshot session-id))
                   (t (complete-with-action
                       action candidates string pred))))))))
      (dsh-emacs-reference--require-cache session-id (nth 1 token))
      ;; Build once now; subsequent table queries refresh this same snapshot.
      (funcall table "" nil 'metadata)
      (list start pos table
            :company-prefix-length t
            :display-sort-function #'identity
            :affixation-function
            (lambda (cands) (dsh-emacs-reference--affixate-with affix cands))
            :exit-function
            (lambda (cand status)
              ;; Resolve the displayed row against its snapshot, not a new reply.
              (let ((dsh-emacs--reference-candidates snapshot))
                (dsh-emacs-reference--exit cand status rows)))))))

;; ---------------------------------------------------------------------------
;; @ reference rendering: transcript / input lines show completed mentions as
;; colored clickable links (the canonical mention is still the buffer/sent
;; source text; only display and jump properties are added here).
;; ---------------------------------------------------------------------------

(defvar dsh-emacs-reference--mention-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'dsh-emacs-reference-open-at-point)
    (define-key map [return] #'dsh-emacs-reference-open-at-point)
    (define-key map [follow-link] #'dsh-emacs-reference-open-at-point)
    (define-key map [mouse-1] #'dsh-emacs-reference-open-at-point)
    (define-key map [mouse-2] #'dsh-emacs-reference-open-at-point)
    map)
  "Keymap on a rendered @ reference span: RET / mouse-1 / mouse-2 open it.
`[follow-link]' is bound so the `follow-link' text property resolves to this
command; without it a click would fall back to `mouse-yank-primary' and hit
the read-only transcript (`insert-for-yank: Text is read-only').")

(defconst dsh-emacs-reference--session-mention-re
  "@\\[\\(\\(?:\\\\.\\|[^]\\\\]\\)*\\)\\](dsh-session:\\([A-Za-z0-9_-]+\\))"
  "Regexp matching a completed session mention `@[label](dsh-session:…)'.
Group 1 is the raw label interior (possibly carrying `\\]' / `\\\\' escapes),
group 2 the base64url URI payload that encodes the session id (see
`dsh-protocol-session-uri--from-string') — not the id itself.")

(defconst dsh-emacs-reference--file-mention-re
  "\\(?:^\\|[ \t\r\n\f]\\)\\(@\"[^\"]*\"\\|@[^ \t\r\n\f@]+\\)"
  "Regexp matching a file reference `@path' or `@\"quoted path\"'.
The `@' must start the string or follow whitespace (group 1 is the token,
its left boundary is group 0) and be followed by at least one non-space
character, so a lone `@' and prose like `mail@example' are not linked.")

(defun dsh-emacs-reference--unescape-label (raw)
  "Unescape a raw session-label interior RAW into its display text.
Decodes the `\\\\X' escapes the host emits (`\\\\]' → `]', `\\\\\\\\' → `\\')."
  (replace-regexp-in-string
   "\\\\\\(.\\)" "\\1" raw t t))

(defun dsh-emacs-reference--link-spans (string &optional references)
  "Reference spans (BEG END KIND VALUE) in STRING, non-overlapping, by start.
KIND is `session' or `file'; VALUE is the session id or the relative file
path (quotes/`@' stripped).  A session mention's span covers the whole
`@[label](dsh-session:…)' text (labels may contain spaces); a file span the
`@…' token.  File tokens falling inside a session mention (its `@[label'
prefix) are not matched as files.
Optional REFERENCES (list of (LABEL . SESSION-ID)) additionally marks
readable `@LABEL' session tokens — dsh persists a referencing message with
its canonical mention collapsed to readable `@label' (id stripped) and
delivers the real id+label in the adjacent recall event, so the readable
token must be re-linked as a session (and must NOT fall through to the file
matcher)."
  (let ((spans '())
        (limit (length string))
        (sm dsh-emacs-reference--session-mention-re))
    ;; Canonical `@[label](dsh-session:…)' mentions.
    (let ((pos 0))
      (while (and (<= pos limit) (string-match sm string pos))
        (push (list (match-beginning 0) (match-end 0) 'session
                    (dsh-protocol-session-uri--from-string
                     (match-string 2 string)))
              spans)
        (setq pos (match-end 0))))
    ;; Readable `@label' session tokens recovered from the recall event.
    (when references
      (let ((readable (dsh-emacs-reference--reseed-session-spans string references)))
        (dolist (s readable)
          (unless (cl-some (lambda (x)
                             (and (eq (nth 2 x) 'session)
                                  (< (nth 0 s) (nth 1 x))
                                  (> (nth 1 s) (nth 0 x))))
                           spans)
            (push s spans)))))
    (let ((m dsh-emacs-reference--file-mention-re)
          (pos 0))
      (while (and (<= pos limit) (string-match m string pos))
        (let* ((b (match-beginning 1))
               (e (match-end 1))
               (tok (match-string 1 string))
               (quoted (string-prefix-p "@\"" tok))
               (path (if quoted (substring tok 2 -1) (substring tok 1)))
               (containing
                (cl-some (lambda (s)
                           (and (<= (nth 0 s) b) (>= (nth 1 s) e) s))
                         spans)))
          (cond
           (containing
            (setq pos (nth 1 containing)))
           (t
            (push (list b e 'file path) spans)
            (setq pos e))))))
    (sort spans (lambda (a b) (< (nth 0 a) (nth 0 b))))))

(defun dsh-emacs-reference--propertize-span (text kind value)
  "Return TEXT propertized as a clickable reference of KIND for VALUE."
  (let ((str (copy-sequence text)))
    (add-text-properties
     0 (length str)
     (list 'face 'dsh-emacs-reference-face
           'mouse-face 'highlight
           'follow-link t
           'keymap dsh-emacs-reference--mention-keymap
           'help-echo (if (eq kind 'session)
                          "RET/mouse-1: open this session"
                        "RET/mouse-1: open this file")
           'dsh-emacs-reference-ref (cons kind value))
     str)
    str))

(defun dsh-emacs-reference-file-link (path)
  "Return PATH propertized as a clickable file reference for display.
RET / mouse-1 opens the file resolved against the session working directory
(see `dsh-emacs-reference--open-ref').  A non-string or empty PATH is returned
unchanged."
  (if (and (stringp path) (not (string-empty-p path)))
      (dsh-emacs-reference--propertize-span path 'file path)
    (or path "")))

(defun dsh-emacs-reference-fontify (string &optional references)
  "Return a copy of STRING with completed @ references made clickable.
A session mention (`@[label](dsh-session:…)') is rewritten to display just
`@label' (the opaque id never shown) carrying its id; a file reference
(`@path' / `@\"quoted path\"') keeps its text.  Both gain
`dsh-emacs-reference-face', RET/mouse bindings and a
`dsh-emacs-reference-ref' property that `dsh-emacs-reference-open-at-point'
reads.  Non-matching text and any pre-existing properties are preserved.
The returned text is for display only — callers keep the raw canonical text
in the buffer / on the wire.
Optional REFERENCES (list of (LABEL . SESSION-ID)) from a `session-reference'
recall event lets a readable `@label' token (a server-persisted mention whose
canonical id was stripped) be re-linked as a session chip carrying its real
SESSION-ID."
  (let ((out '())
        (pos 0))
    (dolist (s (dsh-emacs-reference--link-spans string references))
      (let ((beg (nth 0 s)) (end (nth 1 s))
            (kind (nth 2 s)) (value (nth 3 s)))
        (push (substring string pos beg) out)
        (push (dsh-emacs-reference--propertize-span
               (if (and (eq kind 'session)
                        (dsh-emacs-reference--session-label-at string beg))
                   ;; Canonical `@[label](dsh-session:…)': collapse to `@label'.
                   (concat "@" (dsh-emacs-reference--session-label-at string beg))
                 ;; File reference, or a readable `@label' session token the
                 ;; server persisted with the canonical id stripped — keep the
                 ;; text as-is, only add the link/id properties.
                 (substring string beg end))
               kind value)
              out)
        (setq pos end)))
    (push (substring string pos) out)
    (apply #'concat (nreverse out))))

(defun dsh-emacs-reference--reseed-session-spans (string references)
  "Session spans (BEG END 'session SESSION-ID) in STRING for REFERENCES.
REFERENCES is a list of (LABEL . SESSION-ID) recovered from the adjacent
`session-reference' recall event.  dsh web persists a referencing user
message with its canonical session mention collapsed to the readable
`@LABEL' text (the id stripped), and delivers the real `{sessionId,
label}' pair only in the immediately-following recall event — so the
message text alone cannot be re-linked.  This locates each `@LABEL'
occurrence (longest label first, non-overlapping) and returns it as a
session span carrying the real SESSION-ID."
  (let ((spans '()))
    (dolist (ref (sort (copy-sequence references)
                       (lambda (a b) (> (length (car a)) (length (car b))))))
      (let* ((token (concat "@" (car ref)))
             (id (cdr ref))
             (pos 0))
        (when (> (length token) 0)
          (while (string-match (regexp-quote token) string pos)
            (let ((b (match-beginning 0))
                  (e (match-end 0)))
              ;; The overlap test reads B/E, so it must not share their `let':
              ;; a `let' runs its inits before binding, which leaves B/E free
              ;; to the compiler (and would break the closure outright).
              (let ((overlap (cl-some (lambda (s)
                                        (and (< b (nth 1 s)) (> e (nth 0 s))))
                                      spans)))
                (unless overlap
                  (push (list b e 'session id) spans))
                (setq pos e)))))))
    (sort spans (lambda (a b) (< (nth 0 a) (nth 0 b))))))

(defun dsh-emacs-reference--session-label-at (string beg)
  "Label display text of the session mention in STRING starting at BEG."
  (let ((m dsh-emacs-reference--session-mention-re))
    (and (string-match m string beg)
         (= (match-beginning 0) beg)
         (dsh-emacs-reference--unescape-label (match-string 1 string)))))

(defun dsh-emacs-reference--open-ref (kind value)
  "Open reference KIND (`session' / `file') with VALUE."
  (declare-function dsh-emacs-open-session "dsh-emacs.el"
                    (session-id &optional address other-window))
  (declare-function dsh-emacs--chat-cwd "dsh-emacs.el" (session-id))
  (pcase kind
    ('session
     (if value
         (dsh-emacs-open-session value)
       (user-error "No session id to open")))
    ('file
     (let* ((sid (dsh-emacs--active-session-id))
            (cwd (and sid (dsh-emacs--chat-cwd sid)))
            (abs (and cwd value (expand-file-name value cwd))))
       (if (and abs (file-exists-p abs))
           (find-file abs)
         (user-error "Reference file not found locally: %s"
                     (or value "")))))))

(defun dsh-emacs-reference--mention-label-id (text)
  "Return (LABEL . ID) of canonical session mention TEXT, else nil.
ID is the session id the mention's URI payload encodes, not the payload."
  (let ((m dsh-emacs-reference--session-mention-re))
    (and (string-match (concat "\\`" m "\\'") text)
         (cons (dsh-emacs-reference--unescape-label (match-string 1 text))
               (dsh-protocol-session-uri--from-string
                (match-string 2 text))))))

(defun dsh-emacs-reference-open-at-point ()
  "Open the @ reference under point: jump to its session or open its file.
The reference data rides the `dsh-emacs-reference-ref' text property set by
`dsh-emacs-reference-fontify' / the composer chip makers (`--session-chip',
`--composer-file-chip').  RET / mouse-1 on the span call this."
  (interactive)
  (let ((ref (get-text-property (point) 'dsh-emacs-reference-ref)))
    (if (null ref)
        (user-error "No @ reference here")
      (dsh-emacs-reference--open-ref (car ref) (cdr ref)))))

;; ---------------------------------------------------------------------------
;; Composer atomic chip: a completed session mention stores the short `@label'
;; text in the buffer, while the canonical source (the `@[label](dsh-session:…)'
;; needed for sending) hangs off the `dsh-emacs-reference-canonical' text
;; property; `dsh-emacs-reference--expanded-text' expands it back into the full
;; mention before the input is read (send/history).  `display' folding is no
;; longer used — the buffer text is the visible text, and the editing guards act
;; on the short text with no fold geometry to worry about.  A file chip's
;; `@path' is wire text already, so it has no canonical property and expands to
;; itself.
;; ---------------------------------------------------------------------------

(defun dsh-emacs-reference--session-chip (start end canonical)
  "Mark the short session label in START..END as an atomic composer chip.
The buffer keeps the short `@label' text a pick inserted; the canonical
`@[label](dsh-session:…)' MENTION is stored in the text property
`dsh-emacs-reference-canonical' so sending
(`dsh-emacs-reference--expanded-text') expands the span back to the wire form.
Marks the span with `dsh-emacs-reference-chip' (editing guard), a link face /
RET-mouse binding and the session id.  `rear-nonsticky' keeps the style from
bleeding onto text typed right after the chip.  No-op unless MENTION is a
complete session mention."
  (let ((li (dsh-emacs-reference--mention-label-id canonical)))
    (when (and li (< start end))
      (add-text-properties
       start end
       (list 'face 'dsh-emacs-reference-face
             'mouse-face 'highlight
             'follow-link t
             'keymap dsh-emacs-reference--mention-keymap
             'help-echo "RET/mouse-1: open this session"
             'dsh-emacs-reference-ref (cons 'session (cdr li))
             'dsh-emacs-reference-canonical canonical
             'dsh-emacs-reference-chip t
             'rear-nonsticky
             '(face mouse-face keymap follow-link help-echo
                    dsh-emacs-reference-ref dsh-emacs-reference-canonical
                    dsh-emacs-reference-chip)))
      (dsh-emacs-reference--chip-guard-install)
      t)))

(defun dsh-emacs-reference--expanded-text (start end)
  "Return buffer text START..END with composer session chips expanded.
A chip span (text carrying a `dsh-emacs-reference-canonical' property) is
replaced by its canonical mention; all other text — plain runs and file chips
whose `@path' is already the wire form — is copied verbatim, so a region with
no chips returns its plain substring unchanged.  Non-chip text properties are
stripped: the result is plain text, the exact form RPC / history expects."
  (let ((out '())
        (pos start))
    (while (< pos end)
      (let* ((canon (get-text-property pos 'dsh-emacs-reference-canonical))
             (next (or (next-single-property-change
                        pos 'dsh-emacs-reference-canonical nil end)
                       end)))
        (if canon
            (push canon out)
          (push (buffer-substring-no-properties pos next) out))
        (setq pos next)))
    (apply #'concat (nreverse out))))

(defun dsh-emacs-reference--chip-region (pos)
  "Chip (START . END) that POS sits on or immediately after; else nil.
POS on a chip character returns that chip; POS one past a chip's last
character also returns it, so backspace there can delete the whole chip."
  (cond
   ((get-text-property pos 'dsh-emacs-reference-chip)
    (cons (or (previous-single-property-change (1+ pos) 'dsh-emacs-reference-chip)
              (point-min))
          (or (next-single-property-change pos 'dsh-emacs-reference-chip)
              (point-max))))
   ((and (> pos (point-min))
         (get-text-property (1- pos) 'dsh-emacs-reference-chip))
    (cons (or (previous-single-property-change pos 'dsh-emacs-reference-chip)
              (point-min))
          pos))))

(defun dsh-emacs-reference--editing-command-p (cmd)
  "Whether CMD edits the buffer (and must never split a chip's canonical)."
  (memq cmd '(self-insert-command quoted-insert
              delete-backward-char backward-delete-char
              backward-delete-char-untabify delete-char
              kill-line kill-region yank yank-pop transpose-chars)))

(defun dsh-emacs-reference--chip-guard-before ()
  "Prevent a chip's canonical mention from being edited in the middle.
If point rests on a chip character and THIS-COMMAND would edit, hop to the
chip's end first so the edit lands after it and the wire text stays a valid
mention.  Deleting at a chip boundary removes the whole chip (handled by
`dsh-emacs-reference--chip-delete-guard').

A forward `kill-line' (C-k) that starts on a chip is different: it kills to
the end of the input, which normally covers the whole chip, so hopping to the
chip's end would leave the chip behind and C-k would appear unable to delete
it.  Instead point is pulled back to the chip's START, making C-k remove the
whole chip as one atomic unit (plus any trailing text) — never a fragment."
  (let ((pt (point)))
    (when (and (dsh-emacs-reference--editing-command-p this-command)
               (get-text-property pt 'dsh-emacs-reference-chip))
      (let ((chip (dsh-emacs-reference--chip-region pt)))
        (when (and chip (< pt (cdr chip)))
          (goto-char (if (eq this-command 'kill-line)
                         (car chip)
                       (cdr chip))))))))

(defun dsh-emacs-reference--delete-chip-at-boundary ()
  "Delete the composer chip at whose boundary point sits; return non-nil.
Covers both the trailing edge (backspace deletes the whole chip) and the
leading edge (forward-delete removes it).  Independent of the calling delete
command (does not read `this-command'), so it works interactively and from
calls."
  (let* ((region (dsh-emacs-reference--chip-region (point)))
         (trailing (and region (= (point) (cdr region))))
         (leading (and region (= (point) (car region))
                       (get-text-property (point) 'dsh-emacs-reference-chip)
                       (not (get-text-property (1- (point))
                                               'dsh-emacs-reference-chip)))))
    (when (or trailing leading)
      (delete-region (car region) (cdr region))
      t)))

(defun dsh-emacs-reference--chip-delete-backward (orig &optional arg killflag)
  "`delete-backward-char' advice: backspace at a chip deletes the whole chip."
  (if (dsh-emacs-reference--delete-chip-at-boundary)
      nil
    (funcall orig arg killflag)))

(defun dsh-emacs-reference--chip-delete-forward (orig &optional arg killflag)
  "`delete-char' advice: forward-delete at a chip deletes the whole chip."
  (if (dsh-emacs-reference--delete-chip-at-boundary)
      nil
    (funcall orig arg killflag)))

(defvar dsh-emacs-reference--chip-delete-guard-installed nil
  "Non-nil once the global delete-command advice has been added once.")

(defun dsh-emacs-reference--chip-guard-install ()
  "Install the composer chip editing guards (buffer-local, idempotent)."
  (add-hook 'pre-command-hook #'dsh-emacs-reference--chip-guard-before nil t)
  (unless dsh-emacs-reference--chip-delete-guard-installed
    (setq dsh-emacs-reference--chip-delete-guard-installed t)
    (advice-add 'delete-backward-char :around #'dsh-emacs-reference--chip-delete-backward)
    (advice-add 'delete-char :around #'dsh-emacs-reference--chip-delete-forward)))

(defun dsh-emacs-reference--composer-file-chip (start end path)
  "Wrap a completed file mention START..END as a composer chip.
Like a session chip it is one atomic unit: the buffer keeps the file's own
`@path' text (no `display' collapse — the path already is the wire text), a
backspace at its boundary removes the whole mention, typing on it hops the
cursor past it, and RET/mouse opens the file.  `rear-nonsticky' stops the
style from bleeding onto following typed text."
  (add-text-properties
   start end
   (list 'face 'dsh-emacs-reference-face
         'mouse-face 'highlight
         'follow-link t
         'keymap dsh-emacs-reference--mention-keymap
         'help-echo "RET/mouse-1: open this file"
         'dsh-emacs-reference-ref (cons 'file path)
         'dsh-emacs-reference-chip t
         'rear-nonsticky
         '(face mouse-face keymap follow-link help-echo
                dsh-emacs-reference-ref dsh-emacs-reference-chip)))
  (dsh-emacs-reference--chip-guard-install)
  t)

(defun dsh-emacs-reference--mention-relpath (text)
  "Relative path of a file/dir mention TEXT, else nil.
`@path' -> \"path\", `@\"quoted\"' -> \"quoted\", `@dir/' -> \"dir\"."
  (let ((p (cond ((string-prefix-p "@\"" text) (substring text 2 -1))
                 ((string-prefix-p "@" text) (substring text 1))
                 (t nil))))
    (and (stringp p) (> (length p) 0)
         (if (string-suffix-p "/" p) (substring p 0 -1) p))))

;; ---------------------------------------------------------------------------
;; M-x entry point
;; ---------------------------------------------------------------------------

(defun dsh-emacs-reference--display-pairs ()
  "Completion display pairs for the M-x menu: (DISPLAY . MENTION).
DISPLAY is the web-style row (file path / directory with slash /
session label); MENTION is the text inserted on pick."
  (mapcar
   (lambda (entry)
     (cons
      (pcase (plist-get (cdr entry) :kind)
        ('session (plist-get (cdr entry) :label))
        ('directory (concat (plist-get (cdr entry) :path) "/"))
        (_ (plist-get (cdr entry) :path)))
      (car entry)))
   (dsh-emacs-reference--visible-candidates)))

(defun dsh-emacs-reference--insert-at-point (mention)
  "Insert MENTION into the editable input area at point.
An @ token ending at point is replaced; the cursor is clamped into
the input area first.  A session MENTION is inserted as its short
`@label' text carrying the canonical mention in a
`dsh-emacs-reference-canonical' text property (send expands it back);
a file/directory MENTION inserts its own text, styled as an editable
composer chip."
  (let ((inhibit-read-only t))
    (when (and dsh-emacs--input-marker
               (markerp dsh-emacs--input-marker)
               (eq (marker-buffer dsh-emacs--input-marker) (current-buffer)))
      (when (< (point) (marker-position dsh-emacs--input-marker))
        (goto-char (marker-position dsh-emacs--input-marker)))
      (let* ((token (dsh-emacs-reference--active-token))
             (start (if token
                        (- (point) (length (nth 0 token)))
                      (point)))
             (li (dsh-emacs-reference--mention-label-id mention)))
        (delete-region start (point))
        (if li
            ;; Session mention -> short @label kept in the buffer, canonical
            ;; mention on a text property for send-time expansion.
            (progn
              (insert (concat "@" (car li)))
              (dsh-emacs-reference--session-chip start (point) mention))
          ;; File/directory mention: editable composer chip (path is wire text).
          (insert mention)
          (let ((path (dsh-emacs-reference--mention-relpath mention)))
            (and path
                 (dsh-emacs-reference--composer-file-chip
                  start (point) path))))
        ;; This pick consumed the @ token: forget the narrowed fetch so the
        ;; next `@' opens the full list again.
        (dsh-emacs-reference--reset-fetch)))))

(defun dsh-emacs-reference ()
  "Insert an @ file or session reference into the chat input, at point.
Requests reference candidates asynchronously for the current @ token
(or an empty query when none is active), then offers cached results via
`completing-read' (files, then directories, then sessions; rows show
plain candidate text) and replaces the active token — or
inserts at point when the cursor already sits inside the input area —
with the formatted mention.  On a cold cache, reports loading; invoke
again once results arrive.  Requires a chat buffer with a session."
  (interactive)
  (dsh-emacs-server-ensure)
  (let* ((session-id (dsh-emacs--active-session-id)))
    (unless session-id (user-error "Open or select a session first"))
    (let* ((token (dsh-emacs-reference--active-token))
           (query (or (and token (nth 1 token)) "")))
      (if (dsh-emacs-reference--require-cache session-id query)
          (progn
            (condition-case nil
                (let* ((pairs (dsh-emacs-reference--display-pairs))
                       (picked (dsh-emacs--completing-read-ordered
                                "Reference: " pairs nil t)))
                  (when picked
                    (dsh-emacs-reference--insert-at-point picked)))
              (quit nil)))
        (message "Reference candidates are still loading…")))))

;; ---------------------------------------------------------------------------
;; Cooperative auto-trigger (same as slash: contributes a trigger character
;; only, never enables a front-end's auto mode)
;; ---------------------------------------------------------------------------

(defun dsh-emacs-reference-auto-trigger-setup ()
  "Contribute \"@\" to the auto trigger in the current chat buffer.
`dsh-emacs-mode' calls this when a chat buffer opens.  dsh-emacs never
enables a completion front-end's auto mode itself; it only adds \"@\"
buffer-locally to `corfu-auto-trigger' when the user already enabled
corfu's auto completion (`corfu-auto' non-nil), so corfu's own engine
pops the @ reference list on \"@\" (ignoring `corfu-auto-prefix').
company needs no contribution (it reaches this buffer's capf via
`company-capf'), and stock completion has no auto channel (@ completes
on TAB).  No-op unless `dsh-emacs-reference-auto-complete' is non-nil."
  (when (and dsh-emacs-reference-auto-complete
             (bound-and-true-p corfu-auto)
             (require 'corfu-auto nil t)
             (boundp 'corfu-auto-trigger)
             (not (string-match-p "@" corfu-auto-trigger)))
    (setq-local corfu-auto-trigger (concat corfu-auto-trigger "@"))))

(provide 'dsh-emacs-reference)

;;; dsh-emacs-reference.el ends here
