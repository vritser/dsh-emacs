;;; dsh-emacs-command.el --- Slash commands via commands/list / commands/execute -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.5.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; dsh slash commands are a host-side registry (`commands/list' /
;; `commands/execute', typert Remote, HTTP paths /api/commands/list and
;; /api/commands/execute, payload {args: {...}}).  This file provides:
;;
;;   - `dsh-emacs-command-parse'      whether a line is a slash command by the
;;                                    same syntax as the dsh registry (pure)
;;   - `dsh-emacs-command-execute'     submit one command line to `commands/execute'
;;   - `dsh-emacs-command-catalog'     per-session cached command catalog (read)
;;   - `dsh-emacs-command-catalog-fetch' / `dsh-emacs-command-catalog-sync'
;;                                     async / sync fetch and cache of the catalog
;;   - `dsh-emacs-command'             M-x slash menu: completing-read picks a
;;                                     command or a skill — a command runs (its
;;                                     argument text is read when it declares an
;;                                     input hint), a skill inserts its "/name "
;;                                     gesture; a prefix argument opens the
;;                                     picked skill's SKILL.md instead
;;   - `dsh-emacs-command-completion-at-point'
;;                                     `completion-at-point-functions' entry:
;;                                     completes the "/name " token ending at
;;                                     point — at the input start or after any
;;                                     whitespace — over the command catalog AND
;;                                     the skill catalog (`skills/list', see
;;                                     dsh-emacs-skill.el), so one "/" menu lists
;;                                     both; mid-sentence it claims only a token
;;                                     the catalogs actually complete
;;   - `dsh-emacs-slash-auto-complete' / `dsh-emacs-command-auto-trigger-setup'
;;                                     cooperative "/" auto-trigger: contributes a
;;                                     trigger, never enables a front-end
;;
;; The send path (`dsh-emacs--submit-prompt') hands a "/name" line to
;; `commands/execute' and falls back to an ordinary message on an admission
;; miss — same behavior as dsh web.  Results render from the `command/run' +
;; `command/done' session events (see `dsh-emacs-render-command' in
;; dsh-emacs-render.el).  A skill gesture takes the same path: a skill name is
;; not a registered command, so `commands/execute' declines it and the
;; fallback prompt is what the host's skill tool expands (dsh-emacs-skill.el
;; owns the skill catalog; this file owns the "/" token, so the menu and the
;; completion live here).
;;
;; Wire shape of attachments (since dsh 0.1.5): the third wire field of
;; `commands/execute' is `submittedAttachments' (called `images' in 0.1.2,
;; renamed and upgraded to a tagged union in 0.1.5); every item must carry a
;; `type' discriminant field:
;;   `((type . "image") (mediaType . M) (data . B64) [name?])'
;;   `((type . "file") (receiptId . R))'   ← file receipt (prompt upload product)
;; This module handles a single image attachment only: `dsh-emacs-command-execute'
;; takes one "attachment alist" (nil = no attachment), wrapped by
;; `dsh-emacs-command--submitted-attachments' into a one-element tagged array.
;; Note that `((mediaType . M) (data . B64))' is both "one attachment alist"
;; and "a list of two dotted pairs" — mapping over it item by item would split
;; it into two attachments (on the wire: a dotted structure like
;; `((type . "image") mediaType . M)'), so no "attachment list" inference is
;; done here.

;;; Code:

(require 'cl-lib)
(require 'dsh-emacs-protocol)

(declare-function dsh-emacs--rpc-async "dsh-emacs.el" (method params callback))
(declare-function dsh-emacs--rpc-request "dsh-emacs.el" (method params))
(declare-function dsh-emacs--active-session-id "dsh-emacs.el" ())
(declare-function dsh-emacs-server-ensure "dsh-emacs-server.el" ())
;; The "/" completion and the slash menu also list the skill catalog (see
;; dsh-emacs-skill.el).
(declare-function dsh-emacs-skill-catalog "dsh-emacs-skill.el"
                  (&optional session-id))
(declare-function dsh-emacs-skill-catalog-sync "dsh-emacs-skill.el"
                  (session-id))
(declare-function dsh-emacs-skill-label "dsh-emacs-skill.el" (skill))
(declare-function dsh-emacs-skill-open "dsh-emacs-skill.el" (skill))
;; The completion table carries the "/" category (see `dsh-emacs-mode'); the
;; helper lives in dsh-emacs.el (Emacs 31 built-in, else a table lambda).
(declare-function dsh-emacs--completion-table-with-metadata
                  "dsh-emacs.el" (collection metadata))

;; Buffer-local in dsh-emacs.el: the start of the editable input area.
(defvar dsh-emacs--input-marker)

;; Optional completion-frontend variables: corfu-auto-trigger is defined by
;; corfu-auto.el and only matters when the user enables corfu's auto.  These
;; forward declarations only keep byte-compilation quiet; at runtime we gate on
;; `bound-and-true-p' / `boundp', so absent corfu reads nil / is skipped.
(defvar corfu-auto)
(defvar corfu-auto-trigger)

(defgroup dsh-emacs-command nil
  "Slash commands (commands/list / commands/execute)."
  :group 'dsh-emacs)

(defcustom dsh-emacs-slash-auto-complete t
  "Whether typing \"/\" auto-pops the slash-command completion list.
dsh-emacs is a completion backend only — it never enables a completion
front-end's auto mode by itself.  When this is non-nil it contributes
\"/\" to the auto trigger of whichever front-end already has its own
auto mode turned on:
- corfu: with `corfu-auto' enabled, \"/\" is added buffer-locally to
  `corfu-auto-trigger', so corfu's own engine pops on \"/\" (ignoring
  `corfu-auto-prefix');
- company: no action needed — company reaches this buffer's capf via
  `company-capf' and auto-shows by its own idle delay (subject to
  `company-minimum-prefix-length');
- stock `*Completions*' / vertico / icomplete: no auto channel exists,
  so nothing is contributed and \"/\" completes on TAB only.
When this is nil no trigger is contributed anywhere.  TAB and
`M-x dsh-emacs-command' always work regardless."
  :type 'boolean
  :group 'dsh-emacs-command)

(defcustom dsh-emacs-command-prefetch t
  "Whether opening a session pre-fetches its `commands/list' catalog.
The fetch runs on a short timer after the chat buffer opens, so
the catalog is already cached by the time the first \"/\" or TAB is
typed — no synchronous round trip on the first completion.  The
prefetch is a no-op when the catalog is already cached."
  :type 'boolean
  :group 'dsh-emacs-command)

(defcustom dsh-emacs-command-prefetch-delay 0.5
  "Delay (seconds) before the `commands/list' pre-fetch runs.
Keeps the prefetch from racing the session-history load that also
starts when the chat buffer opens.  A plain timer is used (not an idle
one), so the catalog still lands while a reply streams — an idle timer
would be starved by the pending event-stream output."
  :type 'number
  :group 'dsh-emacs-command)

(defvar dsh-emacs--command-catalogs nil
  "Alist of (SESSION-ID . ITEMS) caching `commands/list' catalogs.
ITEMS is a list of `dsh-protocol-command' structs, name-sorted by the
host.  Reset per session reload; entries stay until the session closes.")

(defvar dsh-emacs--command-fetch-inflight nil
  "List of SESSION-IDs whose `commands/list' fetch is still in flight.
Guards the completion warm-up so repeated TAB presses do not stack
requests; drained by the fetch callback.")

(defvar dsh-emacs--command-fetch-generation 0
  "Monotonic counter stamping each `commands/list' fetch.
Only the response whose stamp is still its session's current one may
write the cache or clear the in-flight flag, so a fetch superseded by
`dsh-emacs-command-catalog-invalidate' cannot repopulate a cache that
was just dropped.")

(defvar dsh-emacs--command-fetch-stamps nil
  "Alist of (SESSION-ID . STAMP) naming each session's current fetch.
A session absent from this list has no admissible response in flight.")

;; ---------------------------------------------------------------------------
;; Parse and execute
;; ---------------------------------------------------------------------------

(defun dsh-emacs-command-parse (line)
  "Parse LINE as a slash-command line.

Returns (NAME . REST) when LINE starts with \"/NAME\" where NAME is
`[a-z][a-z0-9_-]*' immediately followed by whitespace or end of
line — the same admission syntax as the dsh command registry — and nil
otherwise.  REST is the raw tail after the name (leading whitespace
kept, nil when the line is exactly \"/NAME\")."
  (when (stringp line)
    (let ((case-fold-search nil)
          (trimmed (string-trim line)))
      (when (string-match "\\`/\\([a-z][a-z0-9_-]*\\)" trimmed)
        (let ((end (match-end 0)))
          (when (or (= end (length trimmed))
                    (string-match-p "[ \t\r\n]"
                                    (substring trimmed end (1+ end))))
            (cons (match-string 1 trimmed)
                  (substring trimmed end))))))))

(defun dsh-emacs-command--submitted-attachments (attachment)
  "Return ATTACHMENT as the wire `submittedAttachments' array.

ATTACHMENT is one wire-ready image alist
\((mediaType . M) (data . B64) (name? . N)), or nil for a text-only
command (the host field is required, so nil becomes the empty vector).
The result holds exactly one tagged union member:
\((type . \"image\") (mediaType . M) (data . B64) [name?])."
  (vconcat (when attachment
             (list (append (list (cons 'type "image")) attachment)))))

(defun dsh-emacs-command-execute (session-id line &optional attachment on-done)
  "Execute slash-command LINE (e.g. \"/compact\") in SESSION-ID.

Line goes to `commands/execute' — the host admits only registered
commands.  ATTACHMENT, when given, is one wire-ready image alist
\((mediaType . M) (data . B64) (name? . N)); it rides the required
`submittedAttachments' field as one `{type: \"image\"}' member.
Text-only commands pass nil.

ON-DONE is called as (funcall ON-DONE OK EXECUTION ERR) once the RPC
settles: EXECUTION is a `dsh-protocol-command-execution' for an
admitted command, nil on admission miss (unknown/malformed), OK is
nil on transport failure (`dsh-emacs--rpc-async' already reported it),
and ERR is the raw RPC error value on failure (nil otherwise).  Runs
asynchronously; returns nil."
  (dsh-emacs--rpc-async
   "commands/execute"
   `((agentId . ,session-id)
     (line . ,line)
     (submittedAttachments . ,(dsh-emacs-command--submitted-attachments
                               attachment)))
   (lambda (ok value)
     (let ((execution (and ok value
                           (dsh-protocol-command-execution--from-alist
                            value))))
       (when (functionp on-done)
         ;; The callback may run inside a process filter: swallow the C-g quit.
         (condition-case nil
             (funcall on-done ok execution (and (null ok) value))
           (quit nil)))))))

;; ---------------------------------------------------------------------------
;; Command catalog (commands/list)
;; ---------------------------------------------------------------------------

(defun dsh-emacs-command-catalog (&optional session-id)
  "Return the cached command catalog (list of `dsh-protocol-command') for
SESSION-ID (default: the active session), or nil when not yet fetched."
  (cdr (assoc (or session-id (dsh-emacs--active-session-id))
              dsh-emacs--command-catalogs)))

(defun dsh-emacs-command--cache-catalog (session-id items)
  "Store ITEMS as the cached catalog of SESSION-ID."
  (setq dsh-emacs--command-catalogs
        (cons (cons session-id items)
              (assoc-delete-all session-id dsh-emacs--command-catalogs))))

(defun dsh-emacs-command-catalog-invalidate (session-id)
  "Drop the cached catalog (and any in-flight fetch flag) of SESSION-ID.
A later `dsh-emacs-command-catalog' / completion trigger re-fetches from
the server.  Used by the manual refresh command and by pre-fetch after a
server restart.  A response still in flight for SESSION-ID is
superseded: it can no longer repopulate the dropped cache nor clear a
newer fetch's flag."
  (setq dsh-emacs--command-catalogs
        (assoc-delete-all session-id dsh-emacs--command-catalogs)
        dsh-emacs--command-fetch-inflight
        (delete session-id dsh-emacs--command-fetch-inflight)
        dsh-emacs--command-fetch-stamps
        (assoc-delete-all session-id dsh-emacs--command-fetch-stamps)))

(defun dsh-emacs-command-catalog-fetch (session-id &optional callback)
  "Fetch the `commands/list' catalog of SESSION-ID asynchronously.
Caches the result; CALLBACK (optional) receives the item list (nil on
failure — the error is already reported).  A fetch already in flight
for SESSION-ID is not duplicated, and a response whose fetch
`dsh-emacs-command-catalog-invalidate' superseded is dropped instead of
overwriting the newer catalog."
  (unless (member session-id dsh-emacs--command-fetch-inflight)
    (setq dsh-emacs--command-fetch-inflight
          (cons session-id dsh-emacs--command-fetch-inflight))
    (let ((stamp (setq dsh-emacs--command-fetch-generation
                       (1+ dsh-emacs--command-fetch-generation))))
      (setq dsh-emacs--command-fetch-stamps
            (cons (cons session-id stamp)
                  (assoc-delete-all session-id dsh-emacs--command-fetch-stamps)))
      (dsh-emacs--rpc-async
       "commands/list"
       `((agentId . ,session-id))
       (lambda (ok value)
         (when (equal stamp
                      (cdr (assoc session-id dsh-emacs--command-fetch-stamps)))
           (setq dsh-emacs--command-fetch-inflight
                 (delete session-id dsh-emacs--command-fetch-inflight))
           (let ((items (and ok
                             (mapcar #'dsh-protocol-command--from-alist
                                     (dsh-protocol--list value)))))
             (when items
               (dsh-emacs-command--cache-catalog session-id items))
             (when (functionp callback)
               (condition-case nil
                   (funcall callback items)
                 (quit nil))))))))))

(defun dsh-emacs-command-catalog-sync (session-id)
  "Fetch and cache the `commands/list' catalog of SESSION-ID synchronously.
Returns the item list, or nil on failure (a message is emitted)."
  (or (dsh-emacs-command-catalog session-id)
      (let* ((res (dsh-emacs--rpc-request
                   "commands/list"
                   `((agentId . ,session-id))))
             (items (and (car res)
                         (mapcar #'dsh-protocol-command--from-alist
                                 (dsh-protocol--list (cdr res))))))
        (if items
            (progn
              (dsh-emacs-command--cache-catalog session-id items)
              items)
          (message "Failed to list commands: %S" (cdr res))
          nil))))

(defun dsh-emacs-command-catalog-prefetch (session-id)
  "Pre-fetch the `commands/list' catalog of SESSION-ID lazily.
Called when a chat buffer opens: the catalog is fetched on a short
timer (see `dsh-emacs-command-prefetch-delay') so the first
\"/\" completion does not block on the network.  No-op unless
`dsh-emacs-command-prefetch' is enabled, the catalog is not yet
cached and no fetch is already in flight.  Returns the timer, or nil."
  (when (and dsh-emacs-command-prefetch
             session-id
             (not (dsh-emacs-command-catalog session-id)))
    (unless (member session-id dsh-emacs--command-fetch-inflight)
      (run-at-time
       dsh-emacs-command-prefetch-delay nil
       (lambda (sid)
         (dsh-emacs-command-catalog-fetch sid))
       session-id))))

(defun dsh-emacs-command-catalog-refresh (&optional session-id)
  "Re-fetch and re-cache the `commands/list' catalog, then report.
Refreshes SESSION-ID (default: the active session), which is useful
after the host has registered new commands while a session stays
open.  Runs asynchronously; the result is shown via message."
  (interactive)
  (let ((sid (or session-id (dsh-emacs--active-session-id))))
    (unless sid (user-error "Open or select a session first"))
    (dsh-emacs-command-catalog-invalidate sid)
    (dsh-emacs-command-catalog-fetch
     sid
     (lambda (items)
       (message (if items
                    "Slash commands refreshed: %d available"
                  "Slash command refresh failed (see *Messages*)")
                (if items (length items) 0))))))

;; ---------------------------------------------------------------------------
;; Interactive entry points
;; ---------------------------------------------------------------------------

(defun dsh-emacs-command--input-hint (command)
  "Return the argument hint of COMMAND (nil when it takes no input)."
  (let ((input (dsh-protocol-command-input command)))
    (and input (dsh-protocol-command-input-hint input))))

(defun dsh-emacs-command--insert-gesture (name)
  "Insert \"/NAME \" at point, replacing a \"/\" completion token.
Point is clamped into the chat input area first.  When point sits in a
\"/token\" — the same token completion replaces, at the input start or after
whitespace — that token is replaced; otherwise the gesture is inserted at
point, prefixed with a space when the cursor sits right after non-whitespace:
the host's gesture grammar only accepts `(^|\\s)' before the slash, so a
mid-word insertion would otherwise never fire.  Leaves point after the
trailing space.  Signals `user-error' when the current buffer is not a chat
buffer."
  (let ((marker dsh-emacs--input-marker))
    (unless (and (markerp marker)
                 (eq (marker-buffer marker) (current-buffer)))
      (user-error "Open a chat buffer to insert a command or skill"))
    (let ((inhibit-read-only t))
      (when (< (point) (marker-position marker))
        (goto-char (marker-position marker)))
      (let* ((input-start (marker-position marker))
             (token-start (dsh-emacs-command--completion-token-start))
             (start (or token-start (point)))
             (lead (if (or token-start
                           (= start input-start)
                           (memq (char-before start) '(?\s ?\t ?\n)))
                       ""
                     " ")))
        (delete-region start (point))
        (insert lead "/" name " ")))))

(defun dsh-emacs-command--run (session-id command)
  "Prompt for COMMAND's arguments (when it declares a hint) and run it.
SESSION-ID is the agent the line is submitted to; the outcome is
reported through `dsh-emacs-command-execute'."
  (let* ((name (format "/%s" (dsh-protocol-command-name command)))
         (hint (dsh-emacs-command--input-hint command))
         (args (and hint (read-string (format "Args (%s): " hint)))))
    (dsh-emacs-command-execute
     session-id
     (if (and args (not (string-empty-p args)))
         (format "%s %s" name args)
       name)
     nil
     (lambda (ok execution _err)
       (cond
        ((null ok) nil) ; rpc-async already printed the transport error
        ((null execution)
         (message "Unknown or malformed command: %s" name))
        ((equal (dsh-protocol-command-execution-kind execution) "error")
         (message "Command failed: %s"
                  (or (dsh-protocol-command-execution-text execution)
                      name))))))))

(defun dsh-emacs-command (&optional open-skill)
  "Pick a slash command or skill from the live catalogs and act on it.

Reads the `commands/list' and `skills/list' catalogs of the current
session and offers both in one `completing-read' (commands first, then
skills; a user-only skill is marked in its row).  A picked command runs
immediately: its argument text is read when it declares an input hint,
then the line goes to `commands/execute'.  A picked skill instead
inserts its \"/name \" gesture at point, ready for arguments — the host
expands the gesture from the prompt text rather than executing it (see
dsh-emacs-skill.el).

With prefix argument, a picked skill's `SKILL.md' is opened instead of
inserting the gesture; commands ignore the prefix.  Requires a running
server."
  (interactive "P")
  (dsh-emacs-server-ensure)
  (let ((session-id (dsh-emacs--active-session-id)))
    (unless session-id (user-error "Open or select a session first"))
    (let* ((commands (dsh-emacs-command-catalog-sync session-id))
           (skills (dsh-emacs-skill-catalog-sync session-id))
           (candidates
            (append
             (mapcar
              (lambda (command)
                (let* ((name (format "/%s"
                                     (dsh-protocol-command-name command)))
                       (desc (dsh-protocol-command-description command))
                       (hint (dsh-emacs-command--input-hint command)))
                  (cons (propertize
                         name 'display
                         (if hint
                             (format "%s — %s (%s)" name desc hint)
                           (format "%s — %s" name desc)))
                        command)))
              commands)
             (mapcar
              (lambda (skill)
                (let ((name (format "/%s" (dsh-protocol-skill-name skill))))
                  (cons (propertize
                         name 'display
                         (format "%s — %s" name (dsh-emacs-skill-label skill)))
                        skill)))
              skills))))
      (if (null candidates)
          (message "No slash commands or skills available")
        (condition-case nil
            (let* ((picked (completing-read "Slash command or skill: "
                                            candidates nil t))
                   (item (cdr (assoc picked candidates))))
              (when item
                (cond
                 ((dsh-protocol-command-p item)
                  (dsh-emacs-command--run session-id item))
                 ((dsh-protocol-skill-p item)
                  (if open-skill
                      (dsh-emacs-skill-open item)
                    (dsh-emacs-command--insert-gesture
                     (dsh-protocol-skill-name item)))))))
          (quit nil))))))

(defconst dsh-emacs-command--completion-token-regexp
  "\\(?:\\`\\|[[:space:]]\\)\\(/[a-z0-9_-]*\\)\\'"
  "Regexp matching the `/name' token at the end of a piece of input text.
Group 1 is the token.  The slash must begin the text or follow whitespace —
the boundary the host's own gesture scan requires — so a slash inside a word
(`and/or') or inside a path (`/usr/bin') is not a token, and the name has the
lowercase `[a-z0-9_-]' shape the command and skill grammars share.  Unlike
the host grammar the trailing boundary is not checked: the user is still
typing the name.")

(defun dsh-emacs-command--completion-token-start ()
  "Return the position of the `/name' token that ends at point, or nil.
The token must lie inside the editable input area (after
`dsh-emacs--input-marker') and start at the input start or right after
whitespace, so it may sit anywhere in the message rather than only at its
beginning — the boundary the host's gesture scan uses.  Point may sit inside
the name.  This is the one token grammar shared by completion and gesture
insertion."
  (when-let* ((marker (and (boundp 'dsh-emacs--input-marker)
                           dsh-emacs--input-marker))
              ((markerp marker))
              ((eq (marker-buffer marker) (current-buffer)))
              (input-start (marker-position marker))
              ((>= (point) input-start))
              (offset (let ((case-fold-search nil))
                        (when (string-match
                               dsh-emacs-command--completion-token-regexp
                               (buffer-substring-no-properties
                                input-start (point)))
                          (match-beginning 1)))))
    (+ input-start offset)))

(defun dsh-emacs-command--completion-prefix-p (text)
  "Return non-nil when TEXT is one bare slash-command completion prefix.
That is, the whole of TEXT is a `/name' token starting at its first
character.  Path and word completion use this to leave the whole input to
command completion even when the command catalog is empty; this grammar owns
the token."
  (let ((case-fold-search nil))
    (and (string-match dsh-emacs-command--completion-token-regexp text)
         (zerop (match-beginning 1)))))

;; The "/" completion category's styles are registered the standard way for a
;; package: defaults go in `completion-category-defaults' at load time (as
;; `eglot-capf' and `ecomplete' do), while `completion-category-overrides'
;; stays the user's knob — a user override for this category wins.
;; `basic' comes first so ordinary prefixes keep stock prefix completion.
;; `flex' then matches a word inside a long name
;; (`/probe' → `/dsh-emacs-skill-probe'), which no prefix does.  Every other
;; completion keeps the user's own styles.
(add-to-list 'completion-category-defaults
             '(dsh-emacs-command (styles basic flex)))

(defun dsh-emacs-command--completion-exit (_candidate status)
  "Separate a completed slash name from its arguments when STATUS is final.
An `exact' match can still grow into a longer name, so leave it editable.
Reuse a space already after point instead of adding a second separator."
  (when (memq status '(finished sole))
    (if (eq (char-after) ?\s)
        (forward-char 1)
      (insert " "))))

(defun dsh-emacs-command-completion-at-point ()
  "`completion-at-point-functions' entry for slash commands and skills.

Completes the \"/name\" token ending at point — at the start of the input or
after any whitespace, the boundary the host's gesture grammar uses — over the
command catalog and the skill catalog (`skills/list'): a bare \"/\" names
both lists, a partial name (typing \"/go\") filters them.  When a catalog has
not been fetched yet it is fetched synchronously, so the very first trigger
(typing \"/\" or TAB) already shows the full list.  Returns nil outside the
input area or when no \"/name\" token ends at point.

A token in the middle of a message is claimed only when the catalogs really
complete it, so prose or a path such as `see /usr' falls through to path and
word completion; a token at the input start always belongs to this source
(see `dsh-emacs-command--completion-prefix-p').

The candidate table carries the `dsh-emacs-command' completion category, whose
defaults include the built-in `flex' style, the same way `@' references match
across a path: a word inside a long name completes
(`/probe' → `/dsh-emacs-skill-probe') even though this module never matches
anything itself.  Flex comes after ordinary prefix matching, so an ambiguous
prefix still lists its candidates instead of completing, and the user's own
`completion-styles' apply after both.  Candidates are plain \"/name\" strings;
the exit function adds a space only after a complete name is accepted, so
ambiguous flex matches cannot merge a shared separator into an unfinished
gesture.  The description rides the
frontend-standard `:annotation-function' metadata (dimmed right-hand
column) and `:company-kind' (a function of the candidate returning the
kind — icon column for nerd-icons-corfu / kind-icon users), so the
popup lays out exactly like other modes instead of wide `display'-text
rows that overflow the popup width.  A user-only skill (no
`modelInvocable') is marked in its annotation."
  (when-let* ((start (dsh-emacs-command--completion-token-start)))
    (let* ((session-id (dsh-emacs--active-session-id))
           (items (or (dsh-emacs-command-catalog session-id)
                      (and session-id
                           (dsh-emacs-command-catalog-sync
                            session-id))))
           (skills (or (dsh-emacs-skill-catalog session-id)
                       (and session-id
                            (dsh-emacs-skill-catalog-sync session-id))))
           (pairs
            (append
             (mapcar
              (lambda (command)
                (cons (format "/%s"
                              (dsh-protocol-command-name command))
                      (dsh-protocol-command-description command)))
              items)
             (mapcar
              (lambda (skill)
                (cons (format "/%s" (dsh-protocol-skill-name skill))
                      (dsh-emacs-skill-label skill)))
              skills)))
           (candidates (mapcar #'car pairs))
           ;; The category lives in the table metadata (not the CAPF plist):
           ;; that is what `completion--nth-completion' reads when a style is
           ;; picked, and what corfu's in-region backend sees.  The claim gate
           ;; below passes this same table, so it matches under exactly the
           ;; styles the front-end will use.
           (table (and candidates
                       (dsh-emacs--completion-table-with-metadata
                        candidates '((category . dsh-emacs-command)))))
           (token (buffer-substring-no-properties start (point))))
      (when (and table
                 (completion-try-completion
                  token table nil (- (point) start)))
        (let* ((describe (lambda (cand)
                           (cdr (assoc cand pairs))))
               ;; nerd-icons-corfu / kind-icon read `:company-kind' as a
               ;; *function* of the candidate returning the kind symbol
               ;; (`(funcall kindfunc cand)' in
               ;; `nerd-icons-corfu-formatter'), not a bare kind
               (kind (lambda (_cand) 'command)))
          (list start (point) table
                :annotation-function describe
                :company-kind kind
                :exit-function #'dsh-emacs-command--completion-exit))))))

;; ---------------------------------------------------------------------------
;; Slash gestures in the transcript
;; ---------------------------------------------------------------------------
;; A `/name' line the user sends is a gesture: a host command when the name is
;; in `commands/list', a skill when it is in `skills/list' (see
;; dsh-emacs-skill.el), and plain text otherwise.  The transcript chips the two
;; actionable kinds, with the catalog description on the tooltip.
;;
;; Classification is **catalog-confirmed**, never shape-alone, so `/usr/bin',
;; `5/8' and `http://…' are never mistaken for gestures — the same rule dsh
;; web's user-text projection applies.  It reads the per-session caches only:
;; a render path must never fetch, so a message rendered before a catalog
;; lands stays plain and the host's own `skill-invocation' injection re-chips
;; it later (`dsh-emacs-command-decorate-skill-gesture', called from
;; dsh-emacs-render.el).

(defconst dsh-emacs-command--gesture-regexp
  "\\(?:^\\|[[:space:]]\\)\\(/[a-z0-9][a-z0-9_-]*\\)\\(?:[[:space:]]\\|\\'\\)"
  "Regexp matching a word-bounded `/name' gesture; group 1 is the token.
Both boundaries are consumed and the scan resumes at the token's end (see
`dsh-emacs-command--gesture-spans'), so one whitespace cannot hide the next
token.  The boundaries keep file paths (`/usr/bin'), fractions (`5/8'),
URLs (`http://…') and punctuation-suffixed prose (`/goal,') out — the same
shape the host's own skill scan uses.  The name shape is the union of the
command and skill grammars; a cached catalog decides whether a match is a
command, a skill or plain text.")

(defun dsh-emacs-command--gesture-presentation (name &optional confirmed-skill)
  "Return (FACE . HELP) for gesture NAME, or nil when no catalog has it.
Reads the cached `commands/list' / `skills/list' catalogs of the current
session and never fetches; a render path must not block on the network.
A name in both catalogs defaults to a command.  CONFIRMED-SKILL overrides
that classification and supplies a name-only tooltip if the skill is uncached."
  (let ((command (and (not confirmed-skill)
                      (cl-find name (dsh-emacs-command-catalog)
                               :key #'dsh-protocol-command-name
                               :test #'equal))))
    (if command
        (cons 'dsh-emacs-slash-command-face
              (format "Slash command /%s — %s" name
                      (or (dsh-protocol-command-description command) "")))
      (let ((skill (cl-find name (dsh-emacs-skill-catalog)
                            :key #'dsh-protocol-skill-name
                            :test #'equal)))
        (when (or skill confirmed-skill)
          (cons 'dsh-emacs-slash-skill-face
                (if skill
                    (format "Skill /%s — %s" name
                            (dsh-emacs-skill-label skill))
                  (format "Skill /%s" name))))))))

(defun dsh-emacs-command--gesture-spans (text)
  "Return (BEG END FACE HELP NAME) for every catalog-confirmed gesture in TEXT.
NAME is the bare skill/command name (the token minus its slash), which is
what the catalogs and the `dsh-emacs-slash-gesture' property carry."
  (let ((pos 0)
        (spans '()))
    (while (string-match dsh-emacs-command--gesture-regexp text pos)
      (let* ((name (substring (match-string 1 text) 1))
             (presentation (dsh-emacs-command--gesture-presentation name)))
        (when presentation
          (push (list (match-beginning 1) (match-end 1)
                      (car presentation) (cdr presentation) name)
                spans)))
      (setq pos (match-end 1)))
    (nreverse spans)))

(defun dsh-emacs-command-fontify-gestures (string)
  "Return a copy of STRING with catalog-confirmed `/name' gestures chipped.
The token text is never changed: each command or skill gesture gains
`dsh-emacs-slash-command-face' / `dsh-emacs-slash-skill-face', a
`dsh-emacs-slash-gesture' property naming it, and a `help-echo' carrying the
catalog description.  A message rendered before its catalog was fetched comes
back unchanged; see `dsh-emacs-command-decorate-skill-gesture' for the
host-evidence path that covers it."
  (let ((out (copy-sequence string)))
    (dolist (span (dsh-emacs-command--gesture-spans string) out)
      (add-face-text-property (nth 0 span) (nth 1 span) (nth 2 span) nil out)
      (put-text-property (nth 0 span) (nth 1 span)
                         'dsh-emacs-slash-gesture (nth 4 span) out)
      (put-text-property (nth 0 span) (nth 1 span) 'help-echo (nth 3 span)
                         out))))

(defun dsh-emacs-command-decorate-skill-gesture (beg end name)
  "Chip NAME's `/name' gesture occurrences inside BEG..END.
Called when the host's hidden `skill-invocation' copy arrives: that is
authoritative evidence the gesture in this message was a skill, so the chip
is applied even when no skill catalog is cached yet — a replayed transcript
rendered before the fetch landed.  Replace any command styling while
preserving the surrounding faces.  An existing skill chip keeps its richer
tooltip, and the token text is never changed.  Returns non-nil when at least
one gesture was chipped."
  (let ((text (buffer-substring-no-properties beg end))
        (presentation (dsh-emacs-command--gesture-presentation name t))
        (inhibit-read-only t)
        (pos 0)
        (chipped nil))
    (while (string-match dsh-emacs-command--gesture-regexp text pos)
      (let ((token-beg (+ beg (match-beginning 1)))
            (token-end (+ beg (match-end 1))))
        (when (equal name (substring (match-string 1 text) 1))
          (let ((start token-beg))
            (while (< start token-end)
              (let ((next (next-single-property-change
                           start 'face nil token-end))
                    (faces (ensure-list (get-text-property start 'face))))
                (unless (memq 'dsh-emacs-slash-skill-face faces)
                  (put-text-property
                   start next 'face
                   (cons (car presentation)
                         (remq 'dsh-emacs-slash-command-face faces)))
                  (put-text-property start next 'help-echo (cdr presentation))
                  (setq chipped t))
                (setq start next))))
          (put-text-property token-beg token-end
                             'dsh-emacs-slash-gesture name)))
      (setq pos (match-end 1)))
    chipped))

(defun dsh-emacs-command-auto-trigger-setup ()
  "Make slash-command completion auto-pop in the current buffer.
`dsh-emacs-mode' calls this when a chat buffer opens.  dsh-emacs never
enables a completion front-end's auto mode itself; it only contributes
\"/\" to the auto trigger of a front-end the user has already turned on,
and that front-end's own engine pops the command list when \"/\" is
typed.  Currently that is corfu only: when `corfu-auto' is enabled,
\"/\" is added buffer-locally to `corfu-auto-trigger' so corfu's own
engine pops immediately on \"/\" (ignoring `corfu-auto-prefix') — without
setting `corfu-auto'/`corfu-mode' or hooking corfu's post-command.
company needs no contribution (it reaches this buffer's capf via
`company-capf' and auto-shows on its own idle delay), and stock
`*Completions*' / vertico / icomplete have no auto channel.  See
`dsh-emacs-slash-auto-complete'.  No-op unless that option is non-nil."
  (when (and dsh-emacs-slash-auto-complete
             (bound-and-true-p corfu-auto)
             (require 'corfu-auto nil t)
             (boundp 'corfu-auto-trigger)
             (not (string-match-p "/" corfu-auto-trigger)))
    (setq-local corfu-auto-trigger (concat corfu-auto-trigger "/"))))

(provide 'dsh-emacs-command)

;;; dsh-emacs-command.el ends here
