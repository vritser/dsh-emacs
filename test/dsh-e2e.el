;;; dsh-e2e.el --- dsh-emacs 端到端测试（需要真实 dsh 服务） -*- lexical-binding: t; -*-
(setq debug-on-error t)
(add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name)))

(require 'dsh-emacs)

(defvar dsh-e2e-results '())

(defun e2e-pass (name)
  (push (cons name t) dsh-e2e-results)
  (princ (format "PASS: %s\n" name)))

(defun e2e-fail (name detail)
  (push (cons name nil) dsh-e2e-results)
  (princ (format "FAIL: %s -- %s\n" name detail)))

(defun e2e-wait (timeout-seconds)
  "等待 TIMEOUT-SECONDS 秒或直到 RPC 完成。"
  (let ((elapsed 0))
    (while (and (< elapsed (* timeout-seconds 10))
                (bound-and-true-p dsh-emacs--rpc-inflight)
                (> dsh-emacs--rpc-inflight 0))
      (accept-process-output nil 0.1)
      (sit-for 0.1)
      (setq elapsed (1+ elapsed)))))

;; --- 测试 1: 健康检查 ---
(dsh-emacs-health
 (lambda (healthy-p)
   (if healthy-p
       (e2e-pass "health-check")
     (e2e-fail "health-check" "dsh 服务不可达，跳过后续测试"))))
(e2e-wait 5)

;; --- 测试 2: 新建会话 ---
(defvar e2e-session-id nil)
(when (cdr (assq 'health-check dsh-e2e-results))
  (dsh-emacs-new-session
   (expand-file-name "~")
   (lambda (session-id error)
     (if error
         (e2e-fail "new-session" (format "错误: %S" error))
       (setq e2e-session-id session-id)
       (if session-id
           (e2e-pass "new-session")
         (e2e-fail "new-session" "未返回 session-id"))))))
(e2e-wait 5)

;; --- 测试 3: 打开会话 ---
(when e2e-session-id
  (dsh-emacs-open-session
   e2e-session-id
   (lambda (success error)
     (if success
         (e2e-pass "open-session")
       (e2e-fail "open-session" (format "错误: %S" error))))))
(e2e-wait 5)

;; --- 测试 4: 检查对话缓冲 ---
(when (and e2e-session-id dsh-emacs--current-buffer)
  (with-current-buffer dsh-emacs--current-buffer
    (when (eq major-mode 'dsh-emacs-mode)
      (e2e-pass "conversation-buffer_mode"))
    (when dsh-emacs--input-marker
      (e2e-pass "input_area_created"))
    (when (dsh-emacs-footer-format)
      (e2e-pass "footer_rendered"))))

;; --- 测试 5: 发送消息 ---
(when e2e-session-id
  (with-current-buffer dsh-emacs--current-buffer
    ;; 在输入区域插入文本
    (goto-char dsh-emacs--input-marker)
    (insert "测试消息")
    (dsh-emacs-send-or-stop)
    (e2e-wait 5)
    ;; 检查是否渲染了用户消息
    (let ((buf-str (buffer-string)))
      (if (string-match-p "测试消息" buf-str)
          (e2e-pass "send-message")
        (e2e-fail "send-message" "未渲染用户消息")))))

;; --- 测试 6: 会话列表 ---
(dsh-emacs-list-sessions-display)
(when (get-buffer dsh-emacs-sessions-buffer)
  (with-current-buffer dsh-emacs-sessions-buffer
    (when (eq major-mode 'dsh-emacs-session-mode)
      (e2e-pass "session_list_mode"))
    (when (string-match-p "Sessions" (buffer-string))
      (e2e-pass "session_list_rendered"))))

;; --- 测试 7: Footer 更新 ---
(when (and dsh-emacs--current-buffer
           (buffer-live-p dsh-emacs--current-buffer))
  (with-current-buffer dsh-emacs--current-buffer
    (let ((usage (dsh-emacs-make-usage 1000 500 0 0 0.05)))
      (dsh-emacs-footer-set-usage usage)
      (let ((footer (dsh-emacs-footer-format)))
        (if (and (stringp footer) (string-match-p "1.0k" footer))
            (e2e-pass "footer_update")
          (e2e-fail "footer_update" (format "footer: %S" footer)))))))

;; --- 测试 8: Footer 切换 ---
(when (and dsh-emacs--current-buffer
           (buffer-live-p dsh-emacs--current-buffer))
  (with-current-buffer dsh-emacs--current-buffer
    (let ((was-enabled dsh-emacs-footer-enabled))
      (dsh-emacs-footer-toggle)
      (if (eq dsh-emacs-footer-enabled (not was-enabled))
          (e2e-pass "footer_toggle")
        (e2e-fail "footer_toggle" "未成功切换"))
      ;; 恢复
      (when (eq dsh-emacs-footer-enabled was-enabled)
        (dsh-emacs-footer-toggle)))))

;; --- 测试 9: 复制转录 ---
(when (and dsh-emacs--current-buffer
           (buffer-live-p dsh-emacs--current-buffer))
  (with-current-buffer dsh-emacs--current-buffer
    (dsh-emacs-copy-transcript)
    (if (not (string-empty-p (current-kill 0)))
        (e2e-pass "copy_transcript")
      (e2e-fail "copy_transcript" "剪贴板为空"))))

;; --- 测试 10: 清理（删除测试会话） ---
(when e2e-session-id
  (dsh-emacs-delete-session
   e2e-session-id
   (lambda (success error)
     (if success
         (e2e-pass "delete-session")
       (e2e-fail "delete-session" (format "错误: %S" error))))))
(e2e-wait 5)

;; --- 总结 ---
(princ "\n===== E2E 测试总结 =====\n")
(let ((pass (cl-count-if (lambda (r) (cdr r)) dsh-e2e-results))
      (fail (cl-count-if (lambda (r) (not (cdr r))) dsh-e2e-results)))
  (princ (format "通过 %d 项，失败 %d 项\n" pass fail))
  (when (> fail 0)
    (princ "失败的测试:\n")
    (dolist (r (nreverse dsh-e2e-results))
      (unless (cdr r)
        (princ (format "  - %s: %s\n" (car r) (cdr r)))))))
