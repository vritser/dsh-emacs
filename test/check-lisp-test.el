;;; check-lisp-test.el --- scripts/check-lisp.el 的单元测试 -*- lexical-binding: t; -*-
;;; 用法: emacs -Q --batch -l test/check-lisp-test.el
;;; 以库形式加载 scripts/check-lisp.el（先绑定 dsh-check--no-run 抑制其
;;; 自动运行），用内存 fixture / temp file 断言 read-ok / diagnose-buffer /
;;; describe / err-line 的读级语义，最后用子进程冒烟 CLI 契约（退出码
;;; 0/1/2、诊断报告含行/列/偏移/上下文、--fix 已移除报用法错误）。
;;; 全部 fixture 走内存或 temp file，绝不触碰仓库文件。

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
    (dsh-check-t:fail name "断言不成立")))

(defvar dsh-check-t:root
  (file-name-directory
   (directory-file-name
    (file-name-directory (file-truename load-file-name))))
  "仓库根目录（本文件位于 <root>/test/ 下）。")

(defvar dsh-check-t:emacs (executable-find "emacs")
  "emacs 可执行文件全路径（子进程 CLI 冒烟用）。")

;; 以库形式加载被测脚本：必须在 load 之前绑定
(defvar dsh-check--no-run t)
(load (expand-file-name "scripts/check-lisp.el" dsh-check-t:root))

;; --- 工具 ---

(defun dsh-check-t:diag (str)
  "在含 STR 的临时 buffer 上跑 `dsh-check:diagnose-buffer'，返回问题列表或 nil。"
  (with-temp-buffer
    (insert str)
    (emacs-lisp-mode)
    (dsh-check:diagnose-buffer)))

(defun dsh-check-t:tmp (str)
  "把 STR 写进新 temp file 并返回其路径（调用方负责删除）。"
  (let ((f (make-temp-file "dsh-check-t" nil ".el")))
    (write-region str nil f)
    f))

(defun dsh-check-t:slurp (file)
  "读回 FILE 的完整内容。"
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun dsh-check-t:read-ok-p (str)
  "把 STR 写进 temp file 后跑 `dsh-check:read-ok'：通过返回 t，否则 nil。"
  (let ((f (make-temp-file "dsh-check-t-ok" nil ".el")))
    (unwind-protect
        (progn (write-region str nil f)
               (condition-case nil (progn (dsh-check:read-ok f) t) (error nil)))
      (delete-file f))))

(defun dsh-check-t:cli (argv)
  "以 ARGV（脚本 `-l' 之后的参数）跑 checker 子进程，返回 (退出码 . 输出串)。"
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
  "统计 NEEDLE 在 HAYSTACK 中的出现次数。"
  (let ((n 0) (i 0))
    (while (string-match needle haystack i)
      (setq n (1+ n)
            i (match-end 0)))
    n))

;; --- diagnose-buffer：全部问题一次报出 ---
(dsh-check-t:assert "diag: 空 buffer nil"
                    (null (dsh-check-t:diag "")))
(dsh-check-t:assert "diag: 配平 nil"
                    (null (dsh-check-t:diag "(a (b c) \"s\")")))
(dsh-check-t:assert "diag: 注释/字符串内括号 nil"
                    (null (dsh-check-t:diag "(a) ; )\n")))
(dsh-check-t:assert "diag: 交叉闭合 syntax 层不可见"
                    (null (dsh-check-t:diag "(a]")))

(let ((r (dsh-check-t:diag "(a))")))
  (dsh-check-t:assert "diag: 单个多余 ) 完整字段"
                      (and (= (length r) 1)
                           (eq (car (car r)) 'stray)
                           (equal (cdr (car r)) (list 1 4 4 ?\) "(a))")))))
(let ((r (dsh-check-t:diag "(a)))")))
  (dsh-check-t:assert "diag: 连续多余闭合逐个报"
                      (and (= (length r) 2)
                           (= (nth 3 (nth 0 r)) 4)
                           (= (nth 3 (nth 1 r)) 5))))
(let ((r (dsh-check-t:diag "(a)) (b")))
  (dsh-check-t:assert "diag: 多余闭合并行存在时只报闭合"
                      (and (= (length r) 1)
                           (eq (car (car r)) 'stray)
                           (= (nth 3 (car r)) 4))))
(let ((r (dsh-check-t:diag "(a) )")))
  (dsh-check-t:assert "diag: 空格不是 stray"
                      (and (= (length r) 1)
                           (= (nth 2 (car r)) 5)
                           (eq (nth 4 (car r)) ?\)))))
(let* ((r (dsh-check-t:diag "(a [b"))
       (m (car r)))
  (dsh-check-t:assert "diag: 缺闭合数量与最内层位置"
                      (and (= (length r) 1)
                           (eq (car m) 'missing)
                           (= (nth 3 m) 4)      ; 最内层 `[' 偏移
                           (= (nth 4 m) 2)))    ; 缺 2 个
  (dsh-check-t:assert "diag: opener 栈内→外排序含坐标"
                      (equal (nth 5 m)
                             '((?\[ 1 4 4) (?\( 1 1 1)))))
(let* ((r (dsh-check-t:diag "(a)) ((b"))
       (types (mapcar #'car r)))
  (dsh-check-t:assert "diag: stray 与 missing 并存一次报出"
                      (and (memq 'stray types) (memq 'missing types))
                      )
  (dsh-check-t:assert "diag: 并存时根因（missing）在前"
                      (and (eq (car types) 'missing)
                           (eq (car (nth 1 r)) 'stray)
                           (= (nth 4 (car r)) 1)             ; 缺 1 个
                           (equal (nth 5 (car r)) '((?\( 1 7 7))))))
(let* ((r (dsh-check-t:diag "(f \"x) (g"))
       (u (car r)))
  (dsh-check-t:assert "diag: 未闭合字符串阻断报出"
                      (and (= (length r) 1)
                           (eq (car u) 'unterminated)
                           (= (nth 3 u) 4))))    ; 引号偏移
(let* ((r (dsh-check-t:diag "(a)) \"x"))
       (types (mapcar #'car r)))
  (dsh-check-t:assert "diag: 阻断根因（unterminated）在前"
                      (and (equal types '(unterminated stray))
                           (= (nth 3 (car r)) 6))))  ; 引号在 6

;; --- describe：可读渲染 ---
(dsh-check-t:assert "describe: stray 含坐标"
                    (and (string-match-p "多余闭合" (dsh-check:describe
                                                     (car (dsh-check-t:diag "(a))"))))
                         (string-match-p "行 1 列 4 偏移 4" (dsh-check:describe
                                                              (car (dsh-check-t:diag "(a))"))))))
(dsh-check-t:assert "describe: missing 含栈"
                    (let ((d (dsh-check:describe (car (dsh-check-t:diag "(a [b")))))
                      (and (string-match-p "缺 2 个闭合" d)
                           (string-match-p "偏移 1" d))))
(dsh-check-t:assert "describe: unterminated 提示串"
                    (string-match-p "未闭合字符串" (dsh-check:describe
                                                    (car (dsh-check-t:diag "(f \"x")))))

;; --- 吞并警示（EXTEND 字段）与顶层 form 签名 ---
(let* ((r (dsh-check-t:diag "(defun a () (list 1\n(defun b () (list 2)))"))
       (m (car r)))
  (dsh-check-t:assert "diag: 归并 case 的 EXTEND 行号"
                      (and (eq (car m) 'missing)
                           (= (nth 4 m) 1)
                           (= (nth 6 m) 2))))
(let* ((r (dsh-check-t:diag "(a [b"))
       (m (car r)))
  (dsh-check-t:assert "diag: 尾缺闭无 EXTEND（低吞并风险）"
                      (and (eq (car m) 'missing)
                           (null (nth 6 m)))))
(dsh-check-t:assert "describe: 归并警示含延续行与吞并提示"
                    (let ((d (dsh-check:describe
                              (car (dsh-check-t:diag
                                    "(defun a () (list 1\n(defun b () (list 2)))")))))
                      (and (string-match-p "延续至第 2 行" d)
                           (string-match-p "吞并\\|并入" d))))
(dsh-check-t:assert "describe: 尾缺闭给意图裁决提示"
                    (let ((d (dsh-check:describe (car (dsh-check-t:diag "(a [b")))))
                      (string-match-p "意图判断" d)))
(dsh-check-t:assert "topforms: 两个顶层 defun"
                    (equal (with-temp-buffer
                             (insert "(defun a () 1)\n(defun b () 2)\n")
                             (emacs-lisp-mode)
                             (dsh-check:topforms))
                           '((1 . "defun") (2 . "defun"))))
(dsh-check-t:assert "topforms: 吞并 case 只剩一个顶层 form"
                    (equal (with-temp-buffer
                             (insert "(defun a () (list 1\n(defun b () (list 2)))")
                             (emacs-lisp-mode)
                             (dsh-check:topforms))
                           '((1 . "defun"))))

;; --- read-ok：两段式（forward-sexp + 哨兵 read）的通过/拒绝 ---
(dsh-check-t:assert "read-ok: 空文件通过"
                    (dsh-check-t:read-ok-p ""))
(dsh-check-t:assert "read-ok: 简单通过"
                    (dsh-check-t:read-ok-p "(a)\n"))
(dsh-check-t:assert "read-ok: 尾部行注释无换行通过（哨兵防吞）"
                    (dsh-check-t:read-ok-p "(a) ; c"))
(dsh-check-t:assert "read-ok: 纯注释无换行通过"
                    (dsh-check-t:read-ok-p ";; c"))
(dsh-check-t:assert "read-ok: 字符串内括号通过"
                    (dsh-check-t:read-ok-p "(a \"))\")\n"))
(dsh-check-t:assert "read-ok: 多余 ) 拒绝"
                    (null (dsh-check-t:read-ok-p "(a))")))
(dsh-check-t:assert "read-ok: 缺闭合拒绝"
                    (null (dsh-check-t:read-ok-p "(a")))
(dsh-check-t:assert "read-ok: 未闭合字符串拒绝"
                    (null (dsh-check-t:read-ok-p "\"x")))
(dsh-check-t:assert "read-ok: #| 块注释拒绝"
                    (null (dsh-check-t:read-ok-p "#| x |# (a)")))
(dsh-check-t:assert "read-ok: 交叉闭合拒绝"
                    (null (dsh-check-t:read-ok-p "(a]")))
(dsh-check-t:assert "read-ok: 悬空 #' 拒绝"
                    (null (dsh-check-t:read-ok-p "(f #')")))

;; --- err-line：两种错误数据结构的行号提取 ---
(let* ((f (dsh-check-t:tmp (concat (make-string 49 ?x) "\n"
                                   (make-string 49 ?y) "\n"
                                   (make-string 49 ?z) "\n"))))
  (unwind-protect
      (dsh-check-t:assert "err-line: scan-error 偏移换算行号"
                          (equal (dsh-check:err-line
                                  f '(scan-error "Unbalanced parentheses" 55 99))
                                 "第 2 行 "))
    (delete-file f)))
(dsh-check-t:assert "err-line: invalid-read-syntax 直接用行列号"
                    (equal (dsh-check:err-line "dummy.el"
                                               '(invalid-read-syntax "]" 3 5))
                           "第 3 行 "))
(dsh-check-t:assert "err-line: file-missing 无位置"
                    (null (dsh-check:err-line "nope.el"
                                              '(file-missing "cannot open" "/x"))))
(dsh-check-t:assert "err-line: end-of-file 无位置"
                    (null (dsh-check:err-line "nope.el" '(end-of-file))))

;; --- CLI 子进程冒烟：退出码契约与诊断报告 ---
(let* ((f (dsh-check-t:tmp "(a)"))
       (res (dsh-check-t:cli (list "--" f))))
  (unwind-protect
      (dsh-check-t:assert "cli: 好文件退出码 0"
                          (and (equal (car res) 0)
                               (string-match-p "1 passed" (cdr res))))
    (delete-file f)))
(let* ((f (dsh-check-t:tmp "(a))"))
       (res (dsh-check-t:cli (list "--" f))))
  (unwind-protect
      (dsh-check-t:assert "cli: 多余闭合报告含行/列/偏移"
                          (and (equal (car res) 1)
                               (string-match-p "多余闭合" (cdr res))
                               (string-match-p "偏移 4" (cdr res))
                               (string-match-p "原始错误" (cdr res))))
    (delete-file f)))
(let* ((f (dsh-check-t:tmp "(a [b"))
       (res (dsh-check-t:cli (list "--" f))))
  (unwind-protect
      (dsh-check-t:assert "cli: 缺闭合报告含 opener 栈"
                          (and (equal (car res) 1)
                               (string-match-p "缺 2 个闭合" (cdr res))
                               (string-match-p "未闭合栈" (cdr res))))
    (delete-file f)))
(let* ((f (dsh-check-t:tmp "(a]"))
       (res (dsh-check-t:cli (list "--" f))))
  (unwind-protect
      (dsh-check-t:assert "cli: 配平但 read 拒绝单列"
                          (and (equal (car res) 1)
                               (not (string-match-p "多余闭合" (cdr res)))
                               (string-match-p "原始错误" (cdr res))))
    (delete-file f)))
(let* ((f (dsh-check-t:tmp "(a))) ((b("))
       (res (dsh-check-t:cli (list "--" f))))
  (unwind-protect
      (dsh-check-t:assert "cli: 多问题一次报全（2 stray + 1 missing）"
                          (and (equal (car res) 1)
                               (= (dsh-check-t:count "third] 多余闭合" (cdr res)) 2)
                               (= (dsh-check-t:count "缺 1 个闭合" (cdr res)) 1)
                               (string-match-p "Fix order" (cdr res))))
    (delete-file f)))
(let* ((f (dsh-check-t:tmp "(a)"))
       (res (dsh-check-t:cli (list "--" "--fix" f))))
  (unwind-protect
      (dsh-check-t:assert "cli: --fix 已移除报用法错误"
                          (and (equal (car res) 2)
                               (string-match-p "已移除" (cdr res))))
    (delete-file f)))
(let* ((f (dsh-check-t:tmp "(a)"))
       (res (dsh-check-t:cli (list f))))  ; 位置参数缺 "--"
  (unwind-protect
      (dsh-check-t:assert "cli: 缺 -- 退出码 2"
                          (and (equal (car res) 2)
                               (string-match-p "缺少" (cdr res))))
    (delete-file f)))
(let* ((f (dsh-check-t:tmp "(defun a () (list 1\n(defun b () (list 2)))"))
       (res (dsh-check-t:cli (list "--" f))))
  (unwind-protect
      (dsh-check-t:assert "cli: 吞并警示与顶层签名同出"
                          (and (equal (car res) 1)
                               (string-match-p "注意" (cdr res))
                               (string-match-p "top-level 1" (cdr res))))
    (delete-file f)))

;; --- 汇总 ---
(let* ((passed (cl-count-if (lambda (r) (cdr r)) dsh-check-t:results))
       (failed (- (length dsh-check-t:results) passed)))
  (princ (format "==> %d passed, %d failed\n" passed failed))
  (kill-emacs (if (zerop failed) 0 1)))