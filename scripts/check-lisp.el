;;; check-lisp.el --- 结构校验：read 级配平检查
;;; 用法: emacs -Q --batch -l scripts/check-lisp.el
;;;       或指定文件: emacs -Q --batch -l scripts/check-lisp.el -- t.el
;;; 退出码: 0 = 全部 read 通过; 1 = 存在失败
;;; 原理: 逐个 read 顶层 form，任何括号不平都会抛 read-syntax/end-of-file。
;;;       比 check-parens 更接近 load 语义，且不会被注释里的括号误导。

(defvar dsh-check:files
  '("dsh-emacs.el" "dsh-emacs-protocol.el" "dsh-emacs-session.el"
    "dsh-emacs-markdown.el" "dsh-emacs-render.el" "dsh-emacs-events.el"
    "dsh-emacs-ui.el" "dsh-emacs-faces.el" "dsh-emacs-tokens.el"
    "dsh-emacs-modeline.el" "dsh-emacs-server.el" "dsh-emacs-command.el"
    "test/dsh-test.el")
  "默认检查的 elisp 文件（相对仓库根目录）。")

(defun dsh-check:read-ok (file)
  "若 FILE 全部顶层 form 配平则返回 t；否则抛 scan-error。
用 `forward-sexp' 逐 form 前进：缺闭合括号（EOF 处）与多余
括号都会抛 scan-error，不会被误吞成正常结束（比裸 `read' 可靠）。"
  (with-temp-buffer
    (insert-file-contents file)
    (emacs-lisp-mode)
    (goto-char (point-min))
    (while (not (eobp))
      (forward-sexp 1)
      (skip-chars-forward " \t\r\n"))
    t))

(let ((files (cdr (member "--" command-line-args-left)))
      (failed 0))
  (when files
    (setq dsh-check:files files))
  (dolist (f dsh-check:files)
    (princ (format "read %-26s " f))
    (condition-case err
        (progn (dsh-check:read-ok f)
               (princ "OK\n"))
      (error
       (setq failed (1+ failed))
       (princ (format "FAIL %S\n" err)))))
  (princ (format "==> %d file(s) checked, %d passed, %d failed\n"
                 (length dsh-check:files)
                 (- (length dsh-check:files) failed)
                 failed))
  (kill-emacs (if (zerop failed) 0 1)))