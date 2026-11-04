;;; dsh-emacs-input.el --- Chat input editing and history -*- lexical-binding: t; -*-

;; Copyright (C) 2026 vritser
;; Author: vritser
;; Version: 0.7.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:
;; Owns input geometry, editing guards, consumed-text undo, completion and
;; prompt history.  The coordinator decides when to consume or restore a
;; draft and assembles the chat mode.  Setup runs only during mode entry.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'dsh-emacs-protocol)
(require 'dsh-emacs-ui)
(require 'dsh-emacs-faces)
(require 'dsh-emacs-command)
(require 'dsh-emacs-reference)

(declare-function dsh-emacs--active-session-id "dsh-emacs" ())
(declare-function dsh-emacs-render--input-anchor-pos "dsh-emacs-render" ())
(defvar dsh-emacs--modeline-overlay)

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

(defcustom dsh-emacs-composer-typing-commands
  '(self-insert-command
    newline newline-and-indent electric-newline-and-maybe-indent open-line
    indent-for-tab-command insert-char quoted-insert
    completion-at-point dabbrev-expand hippie-expand
    yank yank-pop insert-register dsh-emacs-paste
    delete-backward-char delete-forward-char
    backward-delete-char-untabify)
  "Commands that jump to the composer when invoked from the transcript.
When one of these commands runs while point is in the read-only history, the
cursor moves to the editable input first, so a mode-specific insertion command
does not signal `text-read-only'; the input line is also scrolled into view.
Append a command here when it edits at point and should use the same route.
Commands outside this list retain their usual read-only behavior."
  :type '(repeat symbol)
  :group 'dsh-emacs)

(defcustom dsh-emacs-word-completion-limit 100000
  "How many characters above the input word completion searches.
Input word completion offers words already present in the chat buffer —
the draft before point plus the transcript above it — so a term from an
earlier message or tool result completes without retyping.  Only this
many characters of buffer text directly above the input are scanned, so
a long transcript does not slow down every keystroke; nil searches the
whole buffer."
  :type '(choice (const :tag "Whole buffer" nil) integer)
  :group 'dsh-emacs)

(defvar-local dsh-emacs--input-marker nil
  "Marker for the start of the input area (buffer-local).")

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
  (when (or (null dsh-emacs--input-marker)
            (not (and (markerp dsh-emacs--input-marker)
                      (eq (marker-buffer dsh-emacs--input-marker)
                          (current-buffer)))))
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
  (when (and (memq this-command dsh-emacs-composer-typing-commands)
             (markerp dsh-emacs--input-marker)
             (eq (marker-buffer dsh-emacs--input-marker) (current-buffer))
             (or (< (point) (marker-position dsh-emacs--input-marker))
                 (> (point) (dsh-emacs--input-end))))
    (goto-char (if (< (point) (marker-position dsh-emacs--input-marker))
                   (marker-position dsh-emacs--input-marker)
                 (dsh-emacs--input-end)))
    ;; The reference hook ran at the old point.  Protect the new target
    ;; before the command reads its arguments or edits the draft.
    (dsh-emacs-reference--chip-guard-before)))

(defun dsh-emacs--reveal-input-when-typing ()
  "Immediately scroll the window to the input area when typing (self-insert /\nediting commands).\n
When the input line is not visible because the window was scrolled up to\nread history, starting to type scrolls the input line\nback to the bottom of the window, so the `❯ ' line being typed is visible."
  (when (and (window-live-p (get-buffer-window (current-buffer) t))
             (memq this-command dsh-emacs-composer-typing-commands)
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
  "`kill-region' advice: clip kills touching the composer to editable input.
Backward word kills can cross the read-only prompt when a draft starts with
punctuation such as `~/'; forward kills can cross the structural separator
newline.  Clamp both endpoints without changing their direction, so only
draft text reaches the kill ring.  If word motion has already moved point
past a boundary, bring it back into the input as well.  Empty clipped kills
do nothing.  Kills wholly above the input and in non-chat buffers retain
their standard behavior."
  (if-let* ((boundary (dsh-emacs--composer-boundary))
            (input-start (marker-position dsh-emacs--input-marker))
            ((>= (max start end) input-start)))
      (let ((clipped-start (max input-start (min start boundary)))
            (clipped-end (max input-start (min end boundary))))
        (when (<= (min start end) (point) (max start end))
          (goto-char (max input-start (min (point) boundary))))
        (unless (= clipped-start clipped-end)
          (apply orig clipped-start clipped-end args)))
    (apply orig start end args)))

(defun dsh-emacs--composer-delete-horizontal-space (orig &optional backward-only)
  "`delete-horizontal-space' advice: never delete the prompt's trailing space.
Point inside the composer is narrowed to the editable input, so the
electric-indent and `newline-and-indent' cleanup before a newline cannot
reach the read-only `❯ ' space just before the input marker."
  (let ((boundary (dsh-emacs--composer-boundary))
        (start (and (markerp dsh-emacs--input-marker)
                    (marker-position dsh-emacs--input-marker))))
    (if (and start boundary (<= start (point) boundary))
        (save-restriction
          (narrow-to-region start (point-max))
          (funcall orig backward-only))
      (funcall orig backward-only))))

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

(defun dsh-emacs--composer-delete-guard-install ()
  "Install the composer deletion boundary guards (global, idempotent).
Advises the deletion commands (`kill-region', which `C-k'/`kill-line' and
word/region kills route through, `delete-forward-char'/`C-d', and
`delete-horizontal-space' for electric-indent newlines) rather than the
`delete-region' primitive, because a native-compiled caller can bypass advice
on the primitive while the interactive command symbols are always reached
through advice."
  (pcase-dolist (`(,command . ,guard)
                '((delete-horizontal-space . dsh-emacs--composer-delete-horizontal-space)
                  (kill-region . dsh-emacs--composer-kill-region)
                  (delete-forward-char . dsh-emacs--composer-delete-forward)))
    (unless (advice-member-p guard command)
      (advice-add command :around guard))))

;;; ---------------------------------------------------------------------------
;;;  Undo (scoped to the input area)
;;; ---------------------------------------------------------------------------

;; A chat buffer is a live view of a session, not a document: everything
;; above the input is written by the renderer (history, streamed replies,
;; tool cards, Composer chrome), and only the text after `❯ ' is the user's.
;; `undo' therefore has to work on that input alone — undoing rendered
;; transcript text would corrupt the view, and `primitive-undo' binds
;; `inhibit-read-only' internally, so the transcript's read-only property is
;; no protection.  Two mechanisms keep the two apart:
;;
;; 1. Programmatic writes run under `buffer-undo-list' bound to t (every
;;    `(let ((inhibit-read-only t)) ...)' around transcript text carries the
;;    binding), so they leave no undo entry at all.
;; 2. A write above the input still SHIFTS it down, which invalidates the
;;    absolute positions in the entries already recorded for the draft;
;;    `dsh-emacs--note-undo-change' flags that, and
;;    `dsh-emacs--reset-undo-history' rebuilds the history before the next
;;    command can reach a stale entry.

(defvar-local dsh-emacs--undo-stale nil
  "Non-nil when a transcript write invalidated the input's undo records.
Set by `dsh-emacs--note-undo-change' from `after-change-functions';
`dsh-emacs--reset-undo-history' rebuilds the history from it before the next
command runs.")

(defvar-local dsh-emacs--undo-consumed nil
  "Last consumed input, with text properties, until the next input edit.
Together with the current input, this is the position-independent state
from which `dsh-emacs--input-undo-history' rebuilds one undo step.
Only `dsh-emacs--clear-input' saves it, for every submission kind; any
input edit, including undo restoring it or failure rollback, discards it.
It holds text only, never attachments or a stack of earlier submissions.")

(defvar-local dsh-emacs--undo-restored-end nil
  "End of the input text a running undo command re-inserted, or nil.
Set by `dsh-emacs--note-undo-change' while `undo-in-progress' is non-nil and
the restored text reaches the input's end; `dsh-emacs--park-point-after-undo'
consumes it in `post-command-hook'.")

(defun dsh-emacs--transcript-change-p (beg)
  "Whether the change starting at BEG belongs to the transcript, not the input.
Everything left of the editable input is transcript text or the Composer
chrome above it.  Without a live input marker nothing can be classified as
input, so every change counts as transcript."
  (let ((input-start (and (markerp dsh-emacs--input-marker)
                          (eq (marker-buffer dsh-emacs--input-marker)
                              (current-buffer))
                          (marker-position dsh-emacs--input-marker))))
    (or (null input-start) (< beg input-start))))

(defun dsh-emacs--note-undo-change (beg end &rest _)
  "`after-change-functions' hook: keep this buffer's undo state honest.
A change left of the input is a transcript write: it shifts the input down,
so the records made for the draft no longer point at it.  Runs for writes
kept out of the undo history as well — they still move the input.  A change
INSIDE the input while an undo runs is text that command just restored:
remember where it ends when it reaches the input's end, so the cursor can
follow it (see `dsh-emacs--park-point-after-undo')."
  (if (dsh-emacs--transcript-change-p beg)
      (setq dsh-emacs--undo-stale t)
    (setq dsh-emacs--undo-consumed nil)
    (when (and undo-in-progress
               (> end beg)
               (= end (dsh-emacs--input-end)))
      (setq dsh-emacs--undo-restored-end end))))

(defun dsh-emacs--input-undo-history ()
  "Return one undo step for the position-independent input state, or nil.
Nonempty input becomes an insertion record: undo clears the current draft.
Otherwise `dsh-emacs--undo-consumed' becomes a deletion record: undo restores
the last consumed input.  Input edits (including undo) invalidate that saved
consumption, so it cannot resurface after a new draft is edited away.
Both records use the live input marker; no live marker means no history."
  (when-let* ((start (and (markerp dsh-emacs--input-marker)
                          (eq (marker-buffer dsh-emacs--input-marker)
                              (current-buffer))
                          (marker-position dsh-emacs--input-marker)))
              (end (dsh-emacs--input-end)))
    (cond
     ((< start end) (list nil (cons start end)))
     (dsh-emacs--undo-consumed
      (list nil (cons dsh-emacs--undo-consumed (- start)))))))

(defun dsh-emacs--park-point-after-undo ()
  "`post-command-hook': leave point after input text an undo command restored.
`undo' re-inserts a restored region at the position it was deleted from and
parks point there, so a draft comes back with the cursor at its beginning —
while the next keystroke belongs at its end.  Consumes the position
`dsh-emacs--note-undo-change' recorded; a command that only removed input
text leaves point where that text was, which is where the user was editing."
  (when (and dsh-emacs--undo-restored-end
             (memq this-command '(undo undo-redo undo-only)))
    (goto-char dsh-emacs--undo-restored-end)
    (setq dsh-emacs--undo-restored-end nil)))

(defun dsh-emacs--reset-undo-history ()
  "Prepare this buffer's undo state at the start of a command.
Rebuild `buffer-undo-list' around the input area, the only undoable region,
once a transcript write has shifted the input (see `dsh-emacs--undo-stale'):
undo records hold absolute buffer positions, and Emacs does not adjust them
when text lands elsewhere, so records made for the draft before the write
point at transcript text now.  Rebuild from `dsh-emacs--input-undo-history':
the current draft or its last unclaimed consumption survives as one step;
earlier editing granularity and redo history do not.  The restored-text
position belongs only to the previous command and is cleared here too.

A native deletion record alone requires clearing AFTER the submit echo,
and even then cannot survive another transcript write.  Every submission
must consume through `dsh-emacs--clear-input', which saves the actual input
independently of its position.  That state survives echo/reply writes in
either order until an input edit takes ownership; callbacks must not
reinstall a previous consumption."
  (setq dsh-emacs--undo-restored-end nil)
  (when dsh-emacs--undo-stale
    (setq dsh-emacs--undo-stale nil
          buffer-undo-list (dsh-emacs--input-undo-history))))

;;; ---------------------------------------------------------------------------
;;; Input completion: local paths and words
;;;
;;; Two sources beyond the token owners.  Slash commands and @ references are
;;; served by their own CAPFs (dsh-emacs-command.el / dsh-emacs-reference.el);
;;; a path-like token completes against the local filesystem, and anything
;;; else completes as a word from the draft above point and the transcript
;;; above it instead of being retyped.
;;; ---------------------------------------------------------------------------

(defconst dsh-emacs--path-completion-chars "[:alnum:]_.~/+-"
  "Characters that make up a path token in the chat input.
The set stops at whitespace, quotes and punctuation, so completing
`see docs/rpc.md,' inside the input leaves the comma alone instead of
treating it as part of the file name.  The hyphen is last on purpose:
inside a `skip-chars' set a hyphen in the middle starts a range, which
would silently drop `.' and `-' from the token.")

(defun dsh-emacs--path-completion-start ()
  "Return the start of the path token before point in the input area, or nil.
A token counts as a path when it contains a slash — the separator the user
types to mean \"this is a path\" — so `~/…', `./src/' and absolute paths
qualify while a bare name (and a lone `~') stays with word completion.
Slash-command prefixes at the start of the input and @ reference tokens
belong to their own completion sources."
  (when-let* ((marker (and (boundp 'dsh-emacs--input-marker)
                           dsh-emacs--input-marker))
              ((markerp marker))
              ((eq (marker-buffer marker) (current-buffer)))
              (input-start (marker-position marker))
              ((>= (point) input-start)))
    (let* ((start (save-excursion
                    (skip-chars-backward dsh-emacs--path-completion-chars)
                    (point)))
           (token (and (>= start input-start) (< start (point))
                       (buffer-substring-no-properties start (point)))))
      (when (and token
                 (string-match-p "/" token)
                 (not (and (= start input-start)
                           (dsh-emacs-command--completion-prefix-p token)))
                 (not (dsh-emacs-reference--at-token input-start (point))))
        start))))

(defun dsh-emacs-path-completion-at-point ()
  "`completion-at-point-functions' entry: complete a local file path.
`docs/rp', `./src/', `~/…' and absolute paths complete through the stock
file-name completer against the chat buffer's `default-directory' — the
session workspace — so the rows and drill-down match `find-file'.  The
region includes the path suffix after point, and matching follows the
active completion styles, including abbreviated directory components.
Returns nil outside the input area, for an empty or non-path token, for a
slash-command prefix or @ reference, and when no path matches, so a word
token falls through to `dsh-emacs-word-completion-at-point'.

Completion reads the LOCAL filesystem, like the `!' shell lines and
`dsh-emacs-attach-file'; with a dsh server on another host, use an @
reference instead, which the server resolves in the agent's working
directory."
  (when-let* ((start (dsh-emacs--path-completion-start))
              (end (save-excursion
                     (skip-chars-forward dsh-emacs--path-completion-chars)
                     (point)))
              (token (buffer-substring-no-properties start end))
              ((completion-try-completion
                token #'completion-file-name-table nil (- (point) start))))
    ;; Matching is already style-aware above.  `:exclusive no' makes stock
    ;; CAPF dispatch repeat a prefix-only test and reject directory shorthand.
    (list start end #'completion-file-name-table)))

(defconst dsh-emacs--word-completion-chars "[:alnum:]_-"
  "Characters that make up one completion word in the chat input.
Hyphens join identifier-like words (`dsh-emacs-mode', `read-only'), so a
word is completed whole rather than one segment at a time.")

(defun dsh-emacs--word-completion-start ()
  "Return the start of the word before point in the input area, or nil.
A word must lie entirely inside the editable input (after
`dsh-emacs--input-marker') and be non-empty (point right after a
non-word character yields nil, so TAB does nothing there).
Slash-command prefixes and @ reference tokens belong to their own CAPFs."
  (when-let* ((marker (and (boundp 'dsh-emacs--input-marker)
                           dsh-emacs--input-marker))
              ((markerp marker))
              ((eq (marker-buffer marker) (current-buffer)))
              (input-start (marker-position marker))
              ((>= (point) input-start)))
    (let ((start (save-excursion
                   (skip-chars-backward dsh-emacs--word-completion-chars)
                   (point))))
      ;; An empty token would make the candidate regexp match the empty
      ;; string at every position, so point right after a non-word
      ;; character must yield nil.
      (when (and (>= start input-start) (< start (point))
                 (not (and (= start (1+ input-start))
                           (dsh-emacs-command--completion-prefix-p
                            (buffer-substring-no-properties
                             input-start (point)))))
                 (not (dsh-emacs-reference--at-token input-start (point))))
        start))))

(defun dsh-emacs--word-completion-candidates (prefix start)
  "Return buffer words starting with PREFIX, nearest to START first.
Searches backward from START over at most
`dsh-emacs-word-completion-limit' characters, so a term the user has just
seen wins over an older duplicate, and de-duplicates the result.  Matching
follows `completion-ignore-case', the same option the completion front-end
filters the returned candidates with."
  (let* ((limit dsh-emacs-word-completion-limit)
         (from (if limit (max (point-min) (- start limit)) (point-min)))
         (case-fold-search completion-ignore-case)
         (regexp (concat "\\(?:\\`\\|[^" dsh-emacs--word-completion-chars
                         "]\\)\\(" (regexp-quote prefix)
                         "[" dsh-emacs--word-completion-chars "]*\\)"))
         (seen (make-hash-table :test #'equal))
         (words nil))
    (save-excursion
      (goto-char start)
      (while (re-search-backward regexp from t)
        (let ((word (match-string-no-properties 1)))
          (unless (gethash word seen)
            (puthash word t seen)
            (push word words)))
        (goto-char (match-beginning 1))))
    ;; Backward scanning pushes the nearest occurrence first, so reverse to
    ;; return nearest-first.
    (nreverse words)))

(defun dsh-emacs-word-completion-at-point ()
  "`completion-at-point-functions' entry: complete a word from the buffer.
Offers words already present in this chat buffer — the draft before point
and, within `dsh-emacs-word-completion-limit' characters, the transcript
above it — so a term that appeared in an earlier message or tool result
completes without retyping.  Returns nil outside the input area, for an
empty word, for a slash command or @ reference, or when nothing matches.
The completion region includes any word suffix after point.  Completion
metadata preserves nearest-first ordering for display and cycling."
  (when-let* ((start (dsh-emacs--word-completion-start))
              (prefix (buffer-substring-no-properties start (point)))
              (candidates (dsh-emacs--word-completion-candidates prefix start)))
    (list start
          (save-excursion
            (skip-chars-forward dsh-emacs--word-completion-chars)
            (point))
          (dsh-emacs-ui--completion-table-with-metadata
           candidates '((display-sort-function . identity)
                        (cycle-sort-function . identity)))
          :exclusive 'no)))

(defun dsh-emacs--setup-input-area ()
  "Set up the input area (a read-only transcript plus a writable input box).
All welcome text is marked read-only; only the region after ❯ is writable.
The layout is buffer structure, not user input: it leaves no undo entry, and
the erase discards any history an earlier layout left behind."
  (let ((inhibit-read-only t)
        (buffer-undo-list t))
    ;; Clear the buffer
    (erase-buffer)
    ;; Add a minimal chat header
    (let ((welcome-start (point)))
      (insert (propertize "dsh  " 'face 'dsh-emacs-accent-face))
      (insert (propertize "DeepSeek Harness\n\n" 'face 'dsh-emacs-header-face))
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
    (setq dsh-emacs--input-marker (point-marker)))
  ;; The erase above invalidated any record an earlier layout left behind.
  (setq buffer-undo-list nil)
  (setq dsh-emacs--undo-stale nil))

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
  "Consume the input, keeping its text undoable and the mode-line newline.
Save actual input (including reference-chip properties), not the expanded
wire text or a synthesized attachment caption.  Save AFTER deletion, since
the input change hook invalidates the preceding consumption.  An empty
consumption replaces it with nil.  History navigation resets here, never
when an asynchronous completion arrives for an older draft."
  (when (and dsh-emacs--input-marker (marker-buffer dsh-emacs--input-marker))
    (dsh-emacs--reset-undo-history)
    (let ((inhibit-read-only t)
          (text (buffer-substring dsh-emacs--input-marker
                                  (dsh-emacs--input-end))))
      (delete-region dsh-emacs--input-marker (dsh-emacs--input-end))
      (setq dsh-emacs--undo-consumed (unless (string-empty-p text) text)
            dsh-emacs--input-history-pos nil
            dsh-emacs--input-history-pending nil)
      (goto-char dsh-emacs--input-marker))))

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
existing entries instead of treating the batch as a newer snapshot.

Only messages the user wrote are recorded: the host injects its own
model-facing `user/message' copies (workspace instructions, runtime-context
snapshots, goal and subagent notices) into the same surface, and recalling
one through `M-p' would paste a system-reminder wall of text back into the
input; see `dsh-emacs-render--user-authored-p'.  Only prompts whose content
is entirely text are recorded: a message carrying an image (or file) part
cannot be replayed as text — the images would be lost — and the paste
path's synthesized caption (`shot.png') must not come back as a prompt
either.  This mirrors the submit paths, which never record an
attachment-bearing prompt."
  (when (and events session-id)
    (let ((own (gethash session-id dsh-emacs--input-history-by-session))
          (missing nil))
      (dolist (entry (dsh-protocol--list events))
        (let ((text (dsh-protocol-input-prompt--from-alist entry)))
          (when (and text (not (string-empty-p text))
                     (not (member text own))
                     (not (member text missing)))
            (push text missing))))
      (setq own (if older (append own missing) (append missing own)))
      (when (> (length own) dsh-emacs-input-history-length)
        (setcdr (nthcdr (1- dsh-emacs-input-history-length) own) nil))
      (puthash session-id own dsh-emacs--input-history-by-session))))

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

(defun dsh-emacs-input-setup-completion ()
  "Install this chat buffer's input completion sources."
  ;; Complete a slash command or skill when a "/name" token ends at point —
  ;; at the input start or after any whitespace, the boundary the host's
  ;; gesture grammar uses (mid-message it is catalog-confirmed, so prose like
  ;; "see /usr" falls through to path completion); complete file/session
  ;; references while an "@" token is in progress (see dsh-emacs-command.el /
  ;; dsh-emacs-reference.el); complete a local file path when the token
  ;; carries a separator; otherwise complete an ordinary word from the draft
  ;; and the transcript above the input.
  (setq-local completion-at-point-functions
              '(dsh-emacs-command-completion-at-point
                dsh-emacs-reference-completion-at-point
                dsh-emacs-path-completion-at-point
                dsh-emacs-word-completion-at-point))
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
  ;; Category overrides stay with the user.  Token owners register their
  ;; default completion styles when their modules load.
  (add-hook 'post-command-hook #'dsh-emacs-reference--auto-complete nil t))

(defun dsh-emacs-input-setup-editing ()
  "Install this chat buffer's input editing and undo guards."
  ;; Lock the cursor to the input area (after `❯ ') when a session opens
  (add-hook 'post-command-hook #'dsh-emacs--lock-cursor-to-input nil t)
  ;; Undo/redo is scoped to the input area: flag the records a transcript
  ;; write invalidated, rebuild them before the next command runs, and leave
  ;; point after text an undo restores.
  (add-hook 'after-change-functions #'dsh-emacs--note-undo-change nil t)
  (add-hook 'pre-command-hook #'dsh-emacs--reset-undo-history nil t)
  (add-hook 'post-command-hook #'dsh-emacs--park-point-after-undo nil t)
  ;; Before insert/edit commands, move point back to the input
  ;; area if it sits in the read-only region
  (add-hook 'pre-command-hook #'dsh-emacs--route-typing-to-input nil t)
  ;; Scroll to the input area immediately when typing
  (add-hook 'post-command-hook #'dsh-emacs--reveal-input-when-typing nil t)
  ;; Word/region kills stay inside the editable input, protecting the prompt
  ;; on backward kills and the structural newline on forward kills.  `C-d'
  ;; also stops at the trailing boundary; `C-k' keeps standard line semantics.
  (dsh-emacs--composer-delete-guard-install))

(provide 'dsh-emacs-input)
;;; dsh-emacs-input.el ends here
