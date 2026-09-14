;;; check-lisp.el --- read-level structural check; diagnostics only -*- lexical-binding: t; -*-
;;; Usage: emacs -Q --batch -l scripts/check-lisp.el
;;;        or with files: emacs -Q --batch -l scripts/check-lisp.el -- t.el
;;; Exit codes: 0 = all files read clean; 1 = some failed; 2 = usage error
;;; Library load (for tests): (setq dsh-check--no-run t) before loading this
;;;       file suppresses the automatic run.
;;; Role: judge + detective, not doctor.  The tool never modifies files; for
;;;       each failing file it prints a structured diagnosis: problem type,
;;;       line, column, absolute character offset, context snippet; when
;;;       closers are missing it prints the full opener stack (inner to
;;;       outer, with each opener's coordinates).  Fixing is human/agent
;;;       work -- fix everything from the reported coordinates in one pass
;;;       and re-run, instead of nudging parens by trial and error.
;;; How: two stages that approach `load' semantics.  Stage 1 walks
;;;       top-level forms with forward-sexp; a balance error signals
;;;       scan-error (with the offending position).  Stage 2 re-checks with
;;;       a real `read' plus a sentinel, covering constructs the reader
;;;       rejects but the syntax layer does not see (#| block comments, `]'
;;;       / `[' cross-closing, a dangling #', ...).  Diagnosis scans
;;;       character by character with parse-partial-sexp and lists every
;;;       problem at once.
;;; Diagnoses covered:
;;;   1. Stray `)' / `]'  -> listed one by one (type/line/col/offset/char/context); delete that char
;;;   2. Missing closers at EOF -> lists how many and the opener stack (inner to outer, with coordinates);
;;;      where to close is an intent judgment -- piling them all at EOF swallows
;;;      later top-level forms, which the report flags via the EXTEND line
;;;      number; do not blindly stack closers at EOF
;;;   3. Unterminated string    -> blocker: everything after it counts as
;;;      string content, so fix it first
;;;   4. Balanced but read-rejected -> listed separately (#| block comments, cross-closing, dangling #', ...) with line numbers
;;;   5. Top-level form signature -> each file prints a top-level list (line + first symbol);
;;;      compare the signature after fixing missing closers: fewer forms
;;;      means swallowing happened (byte-compile stays silent on that damage)
;;; Note: balanced but structurally wrong code (e.g. a let* binding list
;;;       closed early) reads fine and is out of scope here -- that class of
;;;       problem surfaces through batch-byte-compile warnings.

(defvar dsh-check:files
  '("dsh-emacs.el" "dsh-emacs-protocol.el" "dsh-emacs-session.el"
    "dsh-emacs-markdown.el" "dsh-emacs-render.el" "dsh-emacs-events.el"
    "dsh-emacs-ui.el" "dsh-emacs-faces.el" "dsh-emacs-tokens.el"
    "dsh-emacs-modeline.el" "dsh-emacs-queue.el" "dsh-emacs-server.el"
    "dsh-emacs-command.el" "dsh-emacs-reference.el" "dsh-emacs-composer.el"
    "dsh-emacs-shell.el"
    "test/dsh-test.el" "test/dsh-e2e.el" "test/check-lisp-test.el")
  "Default elisp files to check (relative to the repository root).")

(defvar dsh-check--no-run nil
  "When non-nil, `load'ing this file skips `dsh-check:main' (for test loading).")

(defun dsh-check:read-ok (file)
  "Return t if FILE passes the read-level check; otherwise signal an error.
Stage 1 walks form by form with `forward-sexp': missing closers (at EOF)
and stray parens both signal scan-error, which carries the offending
position (more reliable than a bare `read').
Stage 2 re-checks with a real `read' plus a sentinel: the syntax layer
does not see constructs the reader rejects (#| block comments, `]'/`['
cross-closing, a dangling #', ...), and this stage restores load
semantics."
  (with-temp-buffer
    (insert-file-contents file)
    (emacs-lisp-mode)
    (goto-char (point-min))
    (while (not (eobp))
      (forward-sexp 1)
      (skip-chars-forward " \t\r\n"))
    ;; Sentinel re-check: only reading (:dsh-check-end) means the file is
    ;; complete at reader level.  Add a newline first so a trailing line
    ;; comment without a final newline cannot swallow the sentinel (such
    ;; files do load fine).
    (goto-char (point-max))
    (insert "\n (:dsh-check-end)")
    (goto-char (point-min))
    (let ((seen nil))
      (condition-case nil
          (while (not seen)
            (when (equal (read (current-buffer)) '(:dsh-check-end))
              (setq seen t)))
        (end-of-file
         (unless seen
           (signal 'end-of-file
                   '("read re-check failed: sentinel swallowed, file is incomplete at reader level"))))))
    t))

(defun dsh-check:ctx (pos)
  "Return a compact text snippet around POS (newlines folded to spaces, for one-line output)."
  (let ((s (max (point-min) (- pos 12)))
        (e (min (point-max) (+ pos 13))))
    (replace-regexp-in-string "\n" " "
                              (buffer-substring s e))))

(defun dsh-check:loc (pos)
  "Return the (LINE COLUMN) pair for POS; both are 1-based."
  (list (line-number-at-pos pos)
        (save-excursion (goto-char pos) (1+ (current-column)))))

(defun dsh-check:diagnose-buffer ()
  "Scan the current buffer in one syntax pass and return every read-level
problem (not just the first):
  (stray LINE COL OFFSET CHAR SNIPPET)         stray closer, one entry each
  (unterminated LINE COL OFFSET SNIPPET)       unterminated string (blocker: the rest is string content)
  (missing LINE COL OFFSET N STACK EXTEND)    missing closers at EOF; LINE/COL/OFFSET = innermost
                                               unclosed opener; N = total missing;
                                               STACK = ((CHAR LINE COL OFFSET) ...)
                                               ordered inner to outer; EXTEND = line of the
                                               last open paren after the innermost opener
                                               (nil if none), used for the swallowing
                                               warning (closing at EOF swallows later forms)
  nil                                          balanced
Chains state character by character through `parse-partial-sexp': parens
inside comments/strings do not count toward depth, a negative depth means a
stray closer (consecutive ones are recorded one by one); a line comment
running to EOF is a normal end (valid load semantics), not an unclosed
form.  Returning every problem lets you fix them all in one pass."
  (goto-char (point-min))
  (let ((state nil) (prev 0) (stack '()) (items '()) (last-open 0))
    (while (not (eobp))
      (setq state (parse-partial-sexp (point) (1+ (point)) nil nil state))
      (let ((depth (car state)))
        (cond
         ((> depth prev)
          ;; Depth rose: only >= 1 counts as a real opened form (a `(' that
          ;; goes from negative depth back to 0 cancels a stray and does not
          ;; belong on the stack)
          (when (>= depth 1)
            (push (cons (char-before) (1- (point))) stack)
            ;; Record the last open paren seen (including already closed
            ;; ones): used for the swallowing warning
            (when (> (1- (point)) last-open)
              (setq last-open (1- (point))))))
         ((< depth prev)
          (when (>= prev 1)
            (setq stack (cdr stack)))
          ;; A closer pushing depth further below <= 0 is a stray closer; a
          ;; character at negative depth that does not change it (space,
          ;; symbol, string content) is not a stray
          (when (< depth 0)
            (let* ((pos (1- (point)))
                   (lc (dsh-check:loc pos))
                   (ch (char-after pos)))
              (push (list 'stray (nth 0 lc) (nth 1 lc) pos ch (dsh-check:ctx pos))
                    items)))))
        (setq prev depth)))
    (cond
     ((null state) nil)                     ; empty buffer, nothing to tell
     ((nth 3 state)                         ; unterminated string = root cause:
     ;; a blocker, since everything after it is invisible string content.
     ;; Report one entry, plus any strays collected before the string
      (nconc (let* ((pos (nth 8 state))
                    (lc (dsh-check:loc pos)))
               (list (list 'unterminated (nth 0 lc) (nth 1 lc)
                           pos (dsh-check:ctx pos))))
             (nreverse items)))
     ((> (car state) 0)                     ; missing closer = root cause: it swallows
      ;; later forms, so later reports may be skewed; list it first, fix it, then re-run
      (let* ((inner (car stack))
             (lc (dsh-check:loc (cdr inner))))
        (nconc (list (list 'missing (nth 0 lc) (nth 1 lc) (cdr inner) (length stack)
                           (mapcar (lambda (c)
                                     (let ((l (dsh-check:loc (cdr c))))
                                       (list (car c) (nth 0 l) (nth 1 l) (cdr c))))
                                   stack)
                           (when (> last-open (cdr inner))
                             (line-number-at-pos last-open))))
               (nreverse items))))
     (t (nreverse items)))))

(defun dsh-check:stack-str (stack)
  "Render the opener stack STACK (((CHAR LINE COL OFFSET) ...), inner to outer) as multi-line text."
  (mapconcat (lambda (e)
               (format "line %d column %d offset %d  ``%c''"
                       (nth 1 e) (nth 2 e) (nth 3 e) (nth 0 e)))
             stack "\n"))

(defun dsh-check:describe (item)
  "Render one ITEM from `dsh-check:diagnose-buffer' as human-readable text."
  (pcase item
    (`(stray ,line ,col ,off ,ch ,ctx)
     (format "[third] stray closer `%c': line %d column %d offset %d | context: %s"
             ch line col off ctx))
    (`(unterminated ,line ,col ,off ,ctx)
     (format "[first] unterminated string: line %d column %d offset %d | context: %s (everything after it is string content; fix it first, later problems are masked by it)"
             line col off ctx))
    (`(missing ,line ,col ,off ,n ,stack ,extend)
     (format "[second] EOF missing %d closer(s): innermost opener line %d column %d offset %d; unclosed stack (innermost first):\n%s\nnote: %s"
             n line col off (dsh-check:stack-str stack)
             (if extend
                 (format "unclosed content continues from line %d to line %d; closing at end of file swallows everything after it (including possibly independent top-level forms). Where to place the missing closers is an intent judgment -- check the real boundary against indentation/comments/call sites, and do not blindly stack closers at EOF."
                         line extend)
               "Where to place the missing closers is an intent judgment -- several placements make the file readable but with different semantics; check the real boundary against indentation/comments/call sites, and do not blindly pile closers at end of file.")))
    (_ (format "%S" item))))

(defun dsh-check:topforms ()
  "Return the top-level form signature of the current buffer: ((LINE . NAME) ...).
Based on `parse-partial-sexp' depth 0->1 crossings, it also works on
incomplete files (ones that would fail `read') -- this is the machine
basis for comparing swallowing before and after a fix: fewer forms means
some form was swallowed into the previous one.  Top-level forms starting
with a quote/#' do not count (no depth crossing)."
  (goto-char (point-min))
  (let ((state nil) (prev 0) (out '()))
    (while (not (eobp))
      (setq state (parse-partial-sexp (point) (1+ (point)) nil nil state))
      (let ((depth (car state)))
        (when (and (> depth prev) (= depth 1))
          (let* ((pos (1- (point)))
                 (name (save-excursion
                         (goto-char (1+ pos))
                         (skip-chars-forward " \t")
                         (let ((s (point)))
                           (condition-case nil
                               (progn (forward-sexp 1)
                                      (buffer-substring-no-properties s (point)))
                             (error "?"))))))
            (push (cons (line-number-at-pos pos) name) out)))
        (setq prev depth)))
    (nreverse out)))

(defun dsh-check:err-line (file err)
  "Extract the line where the check error ERR occurred in FILE, as \"line N \";
nil when there is no position.
scan-error data is (MESSAGE START END): the second element is the opener
start for balance errors (the offending character for a stray closer), an
absolute character offset, converted to a line by reading the file;
invalid-read-syntax data is (OBJECT LINE COLUMN), whose second element is
already the line number.  Other errors (file-missing, end-of-file, ...)
carry no numeric position, so nil is returned."
  (let ((num (nth 1 (cdr err))))
    (when (numberp num)
      (condition-case nil
          (if (eq (car err) 'invalid-read-syntax)
              (format "line %d " num)
            (with-temp-buffer
              (insert-file-contents file)
              (format "line %d " (line-number-at-pos num))))
        (error nil)))))

(defun dsh-check:main ()
  "Command-line entry point: parse `command-line-args-left', check each file
and print diagnostics.
Exit codes: 0 = all passed; 1 = some failed; 2 = usage error (missing
\"--\" or the removed --fix was passed).
Diagnoses only, never fixes -- each problem carries type/line/column/
offset/context, and you re-run after fixing.
Loading this file runs it automatically; tests suppress that with
`dsh-check--no-run'."
  (let* ((args command-line-args-left)
         (sep (member "--" args))
         (raw (cdr sep))
         (fix-mode (member "--fix" raw))
         (files (remove "--fix" (copy-sequence raw)))
         (failed 0))
    (setq command-line-args-left nil)
    ;; Positional args must come after `--': if it is missing we would
    ;; silently fall back to the default file list and exit green -- the most
    ;; dangerous false green, so refuse outright instead of guessing.
    (when (and args (null sep))
      (princ (format "check-lisp: positional argument %S is missing the \"--\" separator; refusing to check
usage: emacs -Q --batch -l scripts/check-lisp.el -- FILE...\n"
                     args))
      (kill-emacs 2))
    (when fix-mode
      (princ "check-lisp: --fix was removed: this tool only diagnoses, it never fixes; fix by hand from the reported line/column/offset and re-run\n")
      (kill-emacs 2))
    (when files
      (setq dsh-check:files files))
    (dolist (f dsh-check:files)
      (princ (format "read %-26s " f))
      (let ((ok nil) (fail-err nil))
        (condition-case err
            (progn (dsh-check:read-ok f) (setq ok t))
          (error (setq fail-err err)))
        (if ok
            (princ "OK\n")
          (setq failed (1+ failed))
          (princ "FAIL\n")
          (let ((items (condition-case nil
                           (with-temp-buffer
                             (insert-file-contents f)
                             (emacs-lisp-mode)
                             (dsh-check:diagnose-buffer))
                         (error nil))))
            (when (> (length items) 1)
              (princ "     Fix order: unterminated string (blocker) -> missing closers (root cause) -> stray closers; fix in this order and re-run after every edit (positions drift, errors appear/disappear), never batch-apply a stale report.\n"))
            (dolist (it items)
              (princ (format "     %s\n" (dsh-check:describe it))))
            (princ (format "     raw error: %s%S\n"
                           (or (dsh-check:err-line f fail-err) "")
                           fail-err))))
        ;; Top-level form signature: the machine basis for comparing
        ;; swallowing before and after fixing missing closers (also works
        ;; on incomplete files)
        (let* ((forms (condition-case nil
                           (with-temp-buffer
                             (insert-file-contents f)
                             (emacs-lisp-mode)
                             (dsh-check:topforms))
                         (error nil)))
               (n (length forms)))
          (when (and forms (> n 0))
            (princ (format "     top-level %d: %s"
                           n
                           (mapconcat (lambda (e)
                                        (format "L%d %s" (car e) (cdr e)))
                                      (seq-subseq forms 0 (min n 8)) " · ")))
            (when (> n 8)
              (princ (format " · …(+%d)" (- n 8))))
            (princ "\n")))))
    (princ (format "==> %d file(s) checked, %d passed, %d failed\n"
                   (length dsh-check:files)
                   (- (length dsh-check:files) failed)
                   failed))
    (kill-emacs (if (zerop failed) 0 1))))

(unless dsh-check--no-run
  (dsh-check:main))