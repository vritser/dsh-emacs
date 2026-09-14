;;; check-lisp-test.el --- unit tests for scripts/check-lisp.el -*- lexical-binding: t; -*-
;;; Usage: emacs -Q --batch -l test/check-lisp-test.el
;;; Loads scripts/check-lisp.el as a library (binding dsh-check--no-run first
;;; to suppress its automatic run) and asserts the read-level semantics of
;;; read-ok / diagnose-buffer / describe / err-line against in-memory fixtures
;;; and temp files, then smoke-tests the CLI contract in a subprocess (exit
;;; codes 0/1/2, diagnostic report carrying line/column/offset/context, and
;;; --fix removed reporting a usage error).
;;; Every fixture lives in memory or a temp file and never touches repo files.

(setq debug-on-error t)
(require 'cl-lib)

(defvar dsh-check-t:results '())

(defun dsh-check-t:pass (name)
  (push (cons name t) dsh-check-t:results)
  (princ (format "PASS: %s\n" name)))

(defun dsh-check-t:fail (name detail)
  (push (cons name nil) dsh-check-t:results)
  (princ (format "FAIL: %s -- %s\n" name detail)))

(defun dsh-check-t:assert (name condition)
  (if condition (dsh-check-t:pass name)
    (dsh-check-t:fail name "assertion failed")))

(defvar dsh-check-t:root
  (file-name-directory
   (directory-file-name
    (file-name-directory (file-truename load-file-name))))
  "Repository root (this file lives under <root>/test/).")

(defvar dsh-check-t:emacs (executable-find "emacs")
  "Full path of the emacs executable (used for the CLI subprocess smoke test).")

;; Load the script under test as a library: must be bound before load
(defvar dsh-check--no-run t)
(load (expand-file-name "scripts/check-lisp.el" dsh-check-t:root))

;; --- helpers ---

(defun dsh-check-t:diag (str)
  "Run `dsh-check:diagnose-buffer' on a temp buffer holding STR; return the problem list or nil."
  (with-temp-buffer
    (insert str)
    (emacs-lisp-mode)
    (dsh-check:diagnose-buffer)))

(defun dsh-check-t:tmp (str)
  "Write STR to a new temp file and return its path (the caller deletes it)."
  (let ((f (make-temp-file "dsh-check-t" nil ".el")))
    (write-region str nil f)
    f))

(defun dsh-check-t:slurp (file)
  "Read back the full contents of FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun dsh-check-t:read-ok-p (str)
  "Write STR to a temp file, then run `dsh-check:read-ok': t if it passes, else nil."
  (let ((f (make-temp-file "dsh-check-t-ok" nil ".el")))
    (unwind-protect
        (progn (write-region str nil f)
               (condition-case nil (progn (dsh-check:read-ok f) t) (error nil)))
      (delete-file f))))

(defun dsh-check-t:cli (argv)
  "Run the checker subprocess with ARGV (args after the script's `-l'); return (EXIT-CODE . OUTPUT)."
  (let ((buf (generate-new-buffer " *dsh-check-t-cli*")))
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer)
          (let ((code (apply #'call-process dsh-check-t:emacs nil buf nil
                             "-Q" "--batch" "-l"
                             (expand-file-name "scripts/check-lisp.el"
                                               dsh-check-t:root)
                             argv)))
            (cons code (buffer-string))))
      (kill-buffer buf))))

(defun dsh-check-t:count (needle haystack)
  "Count occurrences of NEEDLE in HAYSTACK."
  (let ((n 0) (i 0))
    (while (string-match needle haystack i)
      (setq n (1+ n)
            i (match-end 0)))
    n))

;; --- diagnose-buffer: report every problem at once ---
(dsh-check-t:assert "diag: empty buffer nil"
                    (null (dsh-check-t:diag "")))
(dsh-check-t:assert "diag: balanced nil"
                    (null (dsh-check-t:diag "(a (b c) \"s\")")))
(dsh-check-t:assert "diag: parens in comment/string nil"
                    (null (dsh-check-t:diag "(a) ; )\n")))
(dsh-check-t:assert "diag: cross-closing invisible to syntax layer"
                    (null (dsh-check-t:diag "(a]")))

(let ((r (dsh-check-t:diag "(a))")))
  (dsh-check-t:assert "diag: single stray ) full fields"
                      (and (= (length r) 1)
                           (eq (car (car r)) 'stray)
                           (equal (cdr (car r)) (list 1 4 4 ?\) "(a))")))))
(let ((r (dsh-check-t:diag "(a)))")))
  (dsh-check-t:assert "diag: consecutive stray closers reported one by one"
                      (and (= (length r) 2)
                           (= (nth 3 (nth 0 r)) 4)
                           (= (nth 3 (nth 1 r)) 5))))
(let ((r (dsh-check-t:diag "(a)) (b")))
  (dsh-check-t:assert "diag: stray with following opener reports only the stray"
                      (and (= (length r) 1)
                           (eq (car (car r)) 'stray)
                           (= (nth 3 (car r)) 4))))
(let ((r (dsh-check-t:diag "(a) )")))
  (dsh-check-t:assert "diag: space is not a stray"
                      (and (= (length r) 1)
                           (= (nth 2 (car r)) 5)
                           (eq (nth 4 (car r)) ?\)))))
(let* ((r (dsh-check-t:diag "(a [b"))
       (m (car r)))
  (dsh-check-t:assert "diag: missing count and innermost position"
                      (and (= (length r) 1)
                           (eq (car m) 'missing)
                           (= (nth 3 m) 4)      ; innermost `[' offset
                           (= (nth 4 m) 2)))    ; 2 missing
  (dsh-check-t:assert "diag: opener stack ordered innermost first with coordinates"
                      (equal (nth 5 m)
                             '((?\[ 1 4 4) (?\( 1 1 1)))))
(let* ((r (dsh-check-t:diag "(a)) ((b"))
       (types (mapcar #'car r)))
  (dsh-check-t:assert "diag: stray and missing reported together in one pass"
                      (and (memq 'stray types) (memq 'missing types))
                      )
  (dsh-check-t:assert "diag: root cause (missing) comes first when both present"
                      (and (eq (car types) 'missing)
                           (eq (car (nth 1 r)) 'stray)
                           (= (nth 4 (car r)) 1)             ; 1 missing
                           (equal (nth 5 (car r)) '((?\( 1 7 7))))))
(let* ((r (dsh-check-t:diag "(f \"x) (g"))
       (u (car r)))
  (dsh-check-t:assert "diag: unterminated string reported as blocker"
                      (and (= (length r) 1)
                           (eq (car u) 'unterminated)
                           (= (nth 3 u) 4))))    ; quote offset
(let* ((r (dsh-check-t:diag "(a)) \"x"))
       (types (mapcar #'car r)))
  (dsh-check-t:assert "diag: blocking root cause (unterminated) comes first"
                      (and (equal types '(unterminated stray))
                           (= (nth 3 (car r)) 6))))  ; quote at 6

;; --- describe: human-readable rendering ---
(dsh-check-t:assert "describe: stray includes coordinates"
                    (and (string-match-p "stray closer" (dsh-check:describe
                                                     (car (dsh-check-t:diag "(a))"))))
                         (string-match-p "line 1 column 4 offset 4" (dsh-check:describe
                                                              (car (dsh-check-t:diag "(a))"))))))
(dsh-check-t:assert "describe: missing includes stack"
                    (let ((d (dsh-check:describe (car (dsh-check-t:diag "(a [b")))))
                      (and (string-match-p "missing 2 closer" d)
                           (string-match-p "offset 1" d))))
(dsh-check-t:assert "describe: unterminated hint text"
                    (string-match-p "unterminated string" (dsh-check:describe
                                                    (car (dsh-check-t:diag "(f \"x")))))

;; --- swallowing warning (EXTEND field) and top-level form signature ---
(let* ((r (dsh-check-t:diag "(defun a () (list 1\n(defun b () (list 2)))"))
       (m (car r)))
  (dsh-check-t:assert "diag: EXTEND line for the swallowing case"
                      (and (eq (car m) 'missing)
                           (= (nth 4 m) 1)
                           (= (nth 6 m) 2))))
(let* ((r (dsh-check-t:diag "(a [b"))
       (m (car r)))
  (dsh-check-t:assert "diag: trailing missing closer has no EXTEND (low swallowing risk)"
                      (and (eq (car m) 'missing)
                           (null (nth 6 m)))))
(dsh-check-t:assert "describe: swallowing warning has extend line and swallow hint"
                    (let ((d (dsh-check:describe
                              (car (dsh-check-t:diag
                                    "(defun a () (list 1\n(defun b () (list 2)))")))))
                      (and (string-match-p "continues from line 1 to line 2" d)
                           (string-match-p "swallow" d))))
(dsh-check-t:assert "describe: trailing missing closer gives intent-judgment hint"
                    (let ((d (dsh-check:describe (car (dsh-check-t:diag "(a [b")))))
                      (string-match-p "intent judgment" d)))
(dsh-check-t:assert "topforms: two top-level defuns"
                    (equal (with-temp-buffer
                             (insert "(defun a () 1)\n(defun b () 2)\n")
                             (emacs-lisp-mode)
                             (dsh-check:topforms))
                           '((1 . "defun") (2 . "defun"))))
(dsh-check-t:assert "topforms: swallowing case leaves one top-level form"
                    (equal (with-temp-buffer
                             (insert "(defun a () (list 1\n(defun b () (list 2)))")
                             (emacs-lisp-mode)
                             (dsh-check:topforms))
                           '((1 . "defun"))))

;; --- read-ok: pass/reject of the two stages (forward-sexp + sentinel read) ---
(dsh-check-t:assert "read-ok: empty file passes"
                    (dsh-check-t:read-ok-p ""))
(dsh-check-t:assert "read-ok: simple form passes"
                    (dsh-check-t:read-ok-p "(a)\n"))
(dsh-check-t:assert "read-ok: trailing line comment without newline passes (sentinel guards swallowing)"
                    (dsh-check-t:read-ok-p "(a) ; c"))
(dsh-check-t:assert "read-ok: comment-only file without newline passes"
                    (dsh-check-t:read-ok-p ";; c"))
(dsh-check-t:assert "read-ok: parens inside string pass"
                    (dsh-check-t:read-ok-p "(a \"))\")\n"))
(dsh-check-t:assert "read-ok: stray ) rejected"
                    (null (dsh-check-t:read-ok-p "(a))")))
(dsh-check-t:assert "read-ok: missing closer rejected"
                    (null (dsh-check-t:read-ok-p "(a")))
(dsh-check-t:assert "read-ok: unterminated string rejected"
                    (null (dsh-check-t:read-ok-p "\"x")))
(dsh-check-t:assert "read-ok: #| block comment rejected"
                    (null (dsh-check-t:read-ok-p "#| x |# (a)")))
(dsh-check-t:assert "read-ok: cross-closing rejected"
                    (null (dsh-check-t:read-ok-p "(a]")))
(dsh-check-t:assert "read-ok: dangling #' rejected"
                    (null (dsh-check-t:read-ok-p "(f #')")))

;; --- err-line: line extraction for the two error data shapes ---
(let* ((f (dsh-check-t:tmp (concat (make-string 49 ?x) "\n"
                                   (make-string 49 ?y) "\n"
                                   (make-string 49 ?z) "\n"))))
  (unwind-protect
      (dsh-check-t:assert "err-line: scan-error offset converted to line"
                          (equal (dsh-check:err-line
                                  f '(scan-error "Unbalanced parentheses" 55 99))
                                 "line 2 "))
    (delete-file f)))
(dsh-check-t:assert "err-line: invalid-read-syntax uses line/column directly"
                    (equal (dsh-check:err-line "dummy.el"
                                               '(invalid-read-syntax "]" 3 5))
                           "line 3 "))
(dsh-check-t:assert "err-line: file-missing has no position"
                    (null (dsh-check:err-line "nope.el"
                                              '(file-missing "cannot open" "/x"))))
(dsh-check-t:assert "err-line: end-of-file has no position"
                    (null (dsh-check:err-line "nope.el" '(end-of-file))))

;; --- CLI subprocess smoke test: exit-code contract and diagnostic report ---
(let* ((f (dsh-check-t:tmp "(a)"))
       (res (dsh-check-t:cli (list "--" f))))
  (unwind-protect
      (dsh-check-t:assert "cli: good file exits 0"
                          (and (equal (car res) 0)
                               (string-match-p "1 passed" (cdr res))))
    (delete-file f)))
(let* ((f (dsh-check-t:tmp "(a))"))
       (res (dsh-check-t:cli (list "--" f))))
  (unwind-protect
      (dsh-check-t:assert "cli: stray closer report has line/column/offset"
                          (and (equal (car res) 1)
                               (string-match-p "stray closer" (cdr res))
                               (string-match-p "offset 4" (cdr res))
                               (string-match-p "raw error" (cdr res))))
    (delete-file f)))
(let* ((f (dsh-check-t:tmp "(a [b"))
       (res (dsh-check-t:cli (list "--" f))))
  (unwind-protect
      (dsh-check-t:assert "cli: missing closer report has opener stack"
                          (and (equal (car res) 1)
                               (string-match-p "missing 2 closer" (cdr res))
                               (string-match-p "unclosed stack" (cdr res))))
    (delete-file f)))
(let* ((f (dsh-check-t:tmp "(a]"))
       (res (dsh-check-t:cli (list "--" f))))
  (unwind-protect
      (dsh-check-t:assert "cli: balanced but read-rejected listed separately"
                          (and (equal (car res) 1)
                               (not (string-match-p "stray closer" (cdr res)))
                               (string-match-p "raw error" (cdr res))))
    (delete-file f)))
(let* ((f (dsh-check-t:tmp "(a))) ((b("))
       (res (dsh-check-t:cli (list "--" f))))
  (unwind-protect
      (dsh-check-t:assert "cli: all problems reported in one pass (2 stray + 1 missing)"
                          (and (equal (car res) 1)
                               (= (dsh-check-t:count "third] stray closer" (cdr res)) 2)
                               (= (dsh-check-t:count "missing 1 closer" (cdr res)) 1)
                               (string-match-p "Fix order" (cdr res))))
    (delete-file f)))
(let* ((f (dsh-check-t:tmp "(a)"))
       (res (dsh-check-t:cli (list "--" "--fix" f))))
  (unwind-protect
      (dsh-check-t:assert "cli: removed --fix reports usage error"
                          (and (equal (car res) 2)
                               (string-match-p "was removed" (cdr res))))
    (delete-file f)))
(let* ((f (dsh-check-t:tmp "(a)"))
       (res (dsh-check-t:cli (list f))))  ; positional arg without "--"
  (unwind-protect
      (dsh-check-t:assert "cli: missing -- exits 2"
                          (and (equal (car res) 2)
                               (string-match-p "missing" (cdr res))))
    (delete-file f)))
(let* ((f (dsh-check-t:tmp "(defun a () (list 1\n(defun b () (list 2)))"))
       (res (dsh-check-t:cli (list "--" f))))
  (unwind-protect
      (dsh-check-t:assert "cli: swallowing warning and top-level signature both printed"
                          (and (equal (car res) 1)
                               (string-match-p "note" (cdr res))
                               (string-match-p "top-level 1" (cdr res))))
    (delete-file f)))

;; --- summary ---
(let* ((passed (cl-count-if (lambda (r) (cdr r)) dsh-check-t:results))
       (failed (- (length dsh-check-t:results) passed)))
  (princ (format "==> %d passed, %d failed\n" passed failed))
  (kill-emacs (if (zerop failed) 0 1)))