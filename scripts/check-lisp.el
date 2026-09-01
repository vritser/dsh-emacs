;;; check-lisp.el --- 结构校验：read 级校验 + 详细诊断（不自动修复） -*- lexical-binding: t; -*-
;;; 用法: emacs -Q --batch -l scripts/check-lisp.el
;;;       或指定文件: emacs -Q --batch -l scripts/check-lisp.el -- t.el
;;; 退出码: 0 = 全部 read 通过; 1 = 存在失败; 2 = 用法错误
;;; 库加载(供测试): 先 (setq dsh-check--no-run t) 再 load 本文件即不自动运行
;;; 定位: 判官 + 侦探，不是医生。工具从不修改文件；对每个失败文件输出
;;;       结构化诊断：问题类型、行号、列号、绝对字符偏移、上下文片段；
;;;       缺闭合时给出完整 opener 栈（内→外，含各 opener 的坐标）。
;;;       修复是人力/agent 的工作——按报告坐标一次修完再重跑验证，
;;;       避免小步试错陷入修括号循环。
;;; 原理: 两段式逼近 load 语义。第一段 forward-sexp 逐顶层 form 前进，
;;;       配平类失衡抛 scan-error（报错自带肇事位置）；第二段用真正的
;;;       read 带哨兵复验，覆盖 reader 拒绝而 syntax 层无感的构造
;;;       （#| 块注释、`]'/`[' 交叉闭合、悬空的 #' 等）。诊断用
;;;       parse-partial-sexp 逐字符扫描，把全部问题一次列出。
;;; 诊断覆盖:
;;;   1. 多余 `)' / `]'  → 逐个列出（类型/行/列/偏移/字符/上下文）；直接删除该字符
;;;   2. 缺闭合到 EOF     → 列出缺失数与 opener 栈（内→外，含坐标）；
;;;      在哪儿补由意图决定——一律补在 EOF 会吞并后续顶层 form，报告
;;;      用 EXTEND 行号给吞并警示；修复时勿盲目堆在 EOF
;;;   3. 字符串未闭合     → 阻断项：其后内容都被视为字符串内，先修复它
;;;   4. 配平但 read 拒绝 → 单列（#| 块注释、交叉闭合、悬空 #' 等），与行号一并给出
;;;   5. 顶层 form 签名   → 每个文件打印 top-level 清单（行号+首符号）；
;;;      修复缺闭后对比签名，form 数量变少即发生了吞并（byte-compile 对此类伤害静默）
;;; 注意：配平但结构错误的代码（如 let* 绑定表提前闭合）read 本来就通过，
;;;       不在本工具射程内——那类问题靠 batch-byte-compile 的警告暴露。

(defvar dsh-check:files
  '("dsh-emacs.el" "dsh-emacs-protocol.el" "dsh-emacs-session.el"
    "dsh-emacs-markdown.el" "dsh-emacs-render.el" "dsh-emacs-events.el"
    "dsh-emacs-ui.el" "dsh-emacs-faces.el" "dsh-emacs-tokens.el"
    "dsh-emacs-modeline.el" "dsh-emacs-queue.el" "dsh-emacs-server.el"
    "dsh-emacs-command.el"
    "test/dsh-test.el" "test/dsh-e2e.el" "test/check-lisp-test.el")
  "默认检查的 elisp 文件（相对仓库根目录）。")

(defvar dsh-check--no-run nil
  "非 nil 时 `load' 本文件不自动执行 `dsh-check:main'（供测试库加载）。")

(defun dsh-check:read-ok (file)
  "若 FILE 通过 read 级校验则返回 t；否则抛错。
第一段 `forward-sexp' 逐 form 前进：缺闭合括号（EOF 处）与多余括号
都会抛 scan-error，报错自带肇事位置（比裸 `read' 可靠）。
第二段用真正的 `read' 带哨兵复验：syntax 层对 reader 拒绝的构造无感
（#| 块注释、`]'/`[' 交叉闭合、悬空的 #' 等），这一段补齐 load 语义。"
  (with-temp-buffer
    (insert-file-contents file)
    (emacs-lisp-mode)
    (goto-char (point-min))
    (while (not (eobp))
      (forward-sexp 1)
      (skip-chars-forward " \t\r\n"))
    ;; 哨兵复验：读到 (:dsh-check-end) 才算 reader 级完整。追加前先补一个
    ;; 换行，避免无结尾换行的行尾注释把哨兵吞进注释（那种文件 load 通过）。
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
                   '("read 复验失败：哨兵被吞，存在 reader 级不完整"))))))
    t))

(defun dsh-check:ctx (pos)
  "返回 POS 附近的紧凑文本片段（换行折为空格，便于单行输出）。"
  (let ((s (max (point-min) (- pos 12)))
        (e (min (point-max) (+ pos 13))))
    (replace-regexp-in-string "\n" " "
                              (buffer-substring s e))))

(defun dsh-check:loc (pos)
  "返回 POS 的 (行 列) 二元组：行、列均从 1 起算。"
  (list (line-number-at-pos pos)
        (save-excursion (goto-char pos) (1+ (current-column)))))

(defun dsh-check:diagnose-buffer ()
  "一趟 syntax 扫描当前 buffer，返回全部 read 级问题（不只第一个）：
  (stray LINE COL OFFSET CHAR SNIPPET)         多余的闭合括号，每个一条
  (unterminated LINE COL OFFSET SNIPPET)       字符串未闭合（阻断：其后皆字符串内容）
  (missing LINE COL OFFSET N STACK EXTEND)    EOF 缺闭合；LINE/COL/OFFSET = 最内层
                                               未闭合 opener；N = 缺失总数；
                                               STACK = ((CHAR LINE COL OFFSET) ...)
                                               按内→外排序；EXTEND = 最内层 opener
                                               之后最后一个开括号所在行（无则 nil），
                                               用于吞并警示（在 EOF 补闭会吞并后续 form）
  nil                                          配平
逐字符 `parse-partial-sexp' 串联状态：注释/字符串里的括号不参与深度，
负深度即多余闭合（连续多个逐个记录）；行注释延伸到 EOF 属正常结束
（load 语义合法），不算未闭合。返回全部问题，便于一次修完、不绕圈。"
  (goto-char (point-min))
  (let ((state nil) (prev 0) (stack '()) (items '()) (last-open 0))
    (while (not (eobp))
      (setq state (parse-partial-sexp (point) (1+ (point)) nil nil state))
      (let ((depth (car state)))
        (cond
         ((> depth prev)
          ;; 深度上涨：只有 >= 1 才算真正打开的 form（从负深度回 0 的
          ;; `(' 抵消的是 stray，不该进栈）
          (when (>= depth 1)
            (push (cons (char-before) (1- (point))) stack)
            ;; 记录最后出现的开括号（含随后已闭合的）：吞并警示用
            (when (> (1- (point)) last-open)
              (setq last-open (1- (point))))))
         ((< depth prev)
          (when (>= prev 1)
            (setq stack (cdr stack)))
          ;; 闭合字符把深度从 <= 0 继续下探 → 多余闭合；深度为负但
          ;; 未变化的字符（空格/符号/字符串内容）不是 stray
          (when (< depth 0)
            (let* ((pos (1- (point)))
                   (lc (dsh-check:loc pos))
                   (ch (char-after pos)))
              (push (list 'stray (nth 0 lc) (nth 1 lc) pos ch (dsh-check:ctx pos))
                    items)))))
        (setq prev depth)))
    (cond
     ((null state) nil)                     ; 空 buffer，无从谈起
     ((nth 3 state)                         ; 字符串未闭合 = 阻断根因：其后内容
      ;; 全被当作字符串看不穿。报一条，并附串前已收集的 stray（若有）
      (nconc (let* ((pos (nth 8 state))
                    (lc (dsh-check:loc pos)))
               (list (list 'unterminated (nth 0 lc) (nth 1 lc)
                           pos (dsh-check:ctx pos))))
             (nreverse items)))
     ((> (car state) 0)                     ; 缺闭合 = 根因：会吞并后续 form，
      ;; 其后的问题报告可能因此失真；排在前头先修，再重跑看剩余
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
  "把 opener 栈 STACK（((CHAR LINE COL OFFSET) ...) 内→外）渲染为多行文本。"
  (mapconcat (lambda (e)
               (format "行 %d 列 %d 偏移 %d  ``%c''"
                       (nth 1 e) (nth 2 e) (nth 3 e) (nth 0 e)))
             stack "\n"))

(defun dsh-check:describe (item)
  "把 `dsh-check:diagnose-buffer' 的单条 ITEM 渲染为人读文本。"
  (pcase item
    (`(stray ,line ,col ,off ,ch ,ctx)
     (format "[third] 多余闭合 `%c': 行 %d 列 %d 偏移 %d | 上下文: %s"
             ch line col off ctx))
    (`(unterminated ,line ,col ,off ,ctx)
     (format "[first] 未闭合字符串: 行 %d 列 %d 偏移 %d | 上下文: %s（此后内容都在字符串内，先修复它，其余问题会被它遮蔽）"
             line col off ctx))
    (`(missing ,line ,col ,off ,n ,stack ,extend)
     (format "[second] EOF 缺 %d 个闭合: 最内层 opener 行 %d 列 %d 偏移 %d；未闭合栈（内→外）:\n%s\n注意: %s"
             n line col off (dsh-check:stack-str stack)
             (if extend
                 (format "未闭合内容自第 %d 行延续至第 %d 行，在文件末尾补闭会把后续内容（含可能的独立顶层 form）全部并入。缺失闭合放哪儿是意图判断——请按缩进/注释/调用点核对真实边界，勿盲目堆在 EOF。"
                         line extend)
               "缺失闭合放哪儿是意图判断——多种补法都能让文件可读但语义不同；请按缩进/注释/调用点核对真实边界，勿盲目把闭合堆在文件末尾。")))
    (_ (format "%S" item))))

(defun dsh-check:topforms ()
  "返回当前 buffer 的顶层 form 签名：((LINE . NAME) ...)。
基于 `parse-partial-sexp' 深度 0→1 的跨越判定，残缺文件（会 read 失败）
同样可用——这是修复前后对比吞并的机器依据：form 数量变少 = 有 form
被吞进前一 form 里。引号/#' 开头的顶层形式不计（无深度跨越）。"
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
  "提取校验错误 ERR 在 FILE 上的肇事行号，返回 \"第 N 行 \"；无位置则 nil。
scan-error 的数据是 (消息 起点 终点)，第二个元素 = 配平类的 opener
起点（多余闭合时 = 肇事字符），是绝对字符偏移，读文件换算行号；
invalid-read-syntax 的数据是 (对象 行 列)，第二个元素就是行号。
其余错误（file-missing、end-of-file 等）无数字位置，返回 nil。"
  (let ((num (nth 1 (cdr err))))
    (when (numberp num)
      (condition-case nil
          (if (eq (car err) 'invalid-read-syntax)
              (format "第 %d 行 " num)
            (with-temp-buffer
              (insert-file-contents file)
              (format "第 %d 行 " (line-number-at-pos num))))
        (error nil)))))

(defun dsh-check:main ()
  "命令行入口：解析 `command-line-args-left'，逐个文件校验并输出诊断。
退出码：0 = 全部通过；1 = 存在失败；2 = 用法错误（缺 \"--\" 或传了已移除的 --fix）。
只诊断不修复——每个问题带类型/行/列/偏移/上下文，修复后重跑验证。
加载本文件默认自动调用；测试场景用 `dsh-check--no-run' 抑制自动运行。"
  (let* ((args command-line-args-left)
         (sep (member "--" args))
         (raw (cdr sep))
         (fix-mode (member "--fix" raw))
         (files (remove "--fix" (copy-sequence raw)))
         (failed 0))
    (setq command-line-args-left nil)
    ;; 位置参数必须经 `--' 传入：漏写时找不到 "--" 会静默落到默认文件列表
    ;; 并以绿色退出——正是最危险的假绿，直接拒绝而不是猜。
    (when (and args (null sep))
      (princ (format "check-lisp: 位置参数 %S 缺少 \"--\" 分隔，拒绝检查
用法: emacs -Q --batch -l scripts/check-lisp.el -- FILE...\n"
                     args))
      (kill-emacs 2))
    (when fix-mode
      (princ "check-lisp: --fix 已移除：本工具只诊断不自动修复；请按输出的行/列/偏移手工修复后重跑\n")
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
            (princ (format "     原始错误: %s%S\n"
                           (or (dsh-check:err-line f fail-err) "")
                           fail-err))))
        ;; 顶层 form 签名：修复缺闭前后对比吞并的机器依据（残缺文件同样可用）
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