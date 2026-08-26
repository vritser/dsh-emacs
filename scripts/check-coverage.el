;;; check-coverage.el --- Instrument dsh-emacs and report per-definition test coverage
;;; 用法: emacs -Q --batch -l scripts/check-coverage.el
;;; 以 testcover 对产品文件插桩 → 加载并运行测试 → 逐函数统计
;;; edebug-coverage 向量中已执行/未执行 point 的比例，输出覆盖汇总。
;;; 原理: testcover-start 用 Edebug 行为钩子把每个 form 的执行点记录到
;;; 符号的 `edebug-coverage' 向量; edebug-ok-coverage = 已执行,
;;; edebug-unknown = 从未执行。统计一个前 N 未覆盖函数清单,帮助补测试。

(require 'cl-lib)
(require 'testcover)

(defvar dsh-cov:root
  (let ((dir (file-name-directory
             (file-truename (or load-file-name default-directory)))))
    ;; 脚本位于 <root>/scripts/ 下：向上退一级得到仓库根
    (if (string-suffix-p "/scripts/" dir)
        (file-name-directory (directory-file-name dir))
      dir)))

(defvar dsh-cov:product-files
  '("dsh-emacs.el" "dsh-emacs-session.el"
    "dsh-emacs-markdown.el" "dsh-emacs-render.el"
    "dsh-emacs-events.el" "dsh-emacs-ui.el"
    "dsh-emacs-faces.el" "dsh-emacs-tokens.el" "dsh-emacs-footer.el")
  "产品源码文件（相对仓库根）。脚本会逐个 testcover-start 插桩。
注意: dsh-emacs-protocol.el 不在列表中——testcover 的 edebug-after
会对 cl-defstruct 返回值做 testcover--copy-object 复制，破坏 struct
类型标签，导致测试中的 cl-struct 类型断言失败，故排除。")

(defun dsh-cov:instrument ()
  "Use testcover to instrument every product file and return the sym list."
  ;; 保证 re-eval 时的内部 require 能解析到仓库根
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
            ;; 只有未执行的才标记 unknown; ok / 值 / testcover-1value 都算已覆盖
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
