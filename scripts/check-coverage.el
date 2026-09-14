;;; check-coverage.el --- Instrument dsh-emacs and report per-definition test coverage
;;; Usage: emacs -Q --batch -l scripts/check-coverage.el
;;; Instrument the product files with testcover → load and run the tests →
;;; report per-definition coverage from the ratio of executed to unexecuted
;;; points in the edebug-coverage vector.
;;; How: testcover-start uses the Edebug behavior hooks to record each form's
;;; execution point in the symbol's `edebug-coverage' vector;
;;; edebug-ok-coverage = executed, edebug-unknown = never executed.  Prints a
;;; list of the first N uncovered functions to help fill in tests.

(require 'cl-lib)
(require 'testcover)

(defvar dsh-cov:root
  (let ((dir (file-name-directory
             (file-truename (or load-file-name default-directory)))))
    ;; The script lives in <root>/scripts/: go up one level to the repo root
    (if (string-suffix-p "/scripts/" dir)
        (file-name-directory (directory-file-name dir))
      dir)))

(defvar dsh-cov:product-files
  '("dsh-emacs.el" "dsh-emacs-session.el"
    "dsh-emacs-markdown.el" "dsh-emacs-render.el"
    "dsh-emacs-events.el" "dsh-emacs-ui.el"
    "dsh-emacs-faces.el" "dsh-emacs-tokens.el" "dsh-emacs-footer.el"
    "dsh-emacs-composer.el")
  "Product source files (relative to the repo root), each instrumented with
testcover-start.  Note: dsh-emacs-protocol.el is not listed — testcover's
edebug-after runs testcover--copy-object on cl-defstruct return values,
which breaks the struct type tag and makes the cl-struct type assertions in
the tests fail, so it is excluded.")

(defun dsh-cov:instrument ()
  "Use testcover to instrument every product file and return the sym list."
  ;; Make the repo root resolvable by inner requires on re-eval
  (add-to-list 'load-path dsh-cov:root)
  (let (syms)
    (dolist (f dsh-cov:product-files)
      (let ((file (expand-file-name f dsh-cov:root)))
        (when (file-exists-p file)
          (testcover-start file)
          (dolist (e edebug-form-data)
            (cl-pushnew (car e) syms :test 'eq)))))
    syms))

(defun dsh-cov:fn-coverage (sym)
  "Return (COVERED-POINTS . TOTAL-POINTS) for SYM from its coverage vector."
  (let ((vec (get sym 'edebug-coverage)))
    (if (not (vectorp vec))
        nil
      (let ((covered 0) (total 0))
        (dotimes (i (length vec))
          (let ((entry (aref vec i)))
            ;; Only unexecuted points are marked unknown; ok / a value /
            ;; testcover-1value all count as covered
            (unless (eq entry 'edebug-unknown)
              (cl-incf covered))
            (cl-incf total)))
        (cons covered total)))))

(defun dsh-cov:run-tests ()
  "Load and run the unit test file (same as the normal full-suite)."
  (load (expand-file-name "test/dsh-test.el" dsh-cov:root)))

(defun dsh-cov:report (syms threshold)
  "Print per-definition coverage summary for SYMS with THRESHOLD coverage."
  (let ((rows '())
        (total-pts 0) (covered-pts 0))
    (dolist (sym (cl-remove-if (lambda (s) (string-prefix-p "edebug-anon"
                                                     (symbol-name s)))
                              syms))
          (let* ((cov (dsh-cov:fn-coverage sym)))
            (when cov
              (cl-incf total-pts (cdr cov))
              (cl-incf covered-pts (car cov))
              (push (list sym
                          (if (zerop (cdr cov)) 0.0
                            (* 100.0 (/ (float (car cov)) (cdr cov))))
                          (car cov) (cdr cov))
                    rows))))
    (setq rows (sort rows (lambda (a b) (< (cadr a) (cadr b)))))
    (princ (format "\n=== coverage report (all defs) ===\n"))
    (dolist (r rows)
      (princ (format "  %5.1f%%  %3d/%-3d  %s\n"
                     (cadr r) (caddr r) (cadddr r) (car r))))
    (princ (format "TOTAL: %d/%d points covered (%.1f%%)\n"
                   covered-pts total-pts
                   (if (zerop total-pts) 0.0
                     (* 100.0 (/ (float covered-pts) total-pts)))))
    (princ (format "Defs with coverage < %.0f%%:\n" threshold))
    (dolist (r (seq-filter (lambda (x) (< (cadr x) threshold)) rows))
      (princ (format "  %5.1f%%  %s\n" (cadr r) (car r))))))

(defun dsh-cov:main ()
  (let ((threshold (if (and (cdr command-line-args-left)
                            (string-match-p "cover" (car command-line-args-left)))
                       (string-to-number (car command-line-args-left) 10)
                     80.0)))
    (let ((syms (dsh-cov:instrument)))
      (dsh-cov:run-tests)
      (dsh-cov:report syms threshold))
    (kill-emacs 0)))

(dsh-cov:main)
