;;; dsh-test-history.el --- History tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)

;; imenu: user message index
(ert-deftest dsh-emacs-test-history-imenu-preserves-authored-prompt ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-render-user-message
     '((type . "user/message") (seq . 1)
       (data . ((content . [((type . "text") (text . "❯ literal"))])))))
    (should (string-suffix-p ": ❯ literal"
                             (caar (dsh-emacs-imenu-create-user-index))))))

(ert-deftest dsh-emacs-test-history-imenu-user-index ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((inhibit-read-only t))
      (insert "dsh  DeepSeek Harness\n\n")
      (insert "\u276f hello world\n")
      (insert "\u276f second message here\n")
      ;; Simulate the user-message property
      (let ((start1 (string-match "\u276f hello" (buffer-string)))
            (start2 (string-match "\u276f second" (buffer-string))))
        (when start1
          (put-text-property (+ (point-min) start1) (+ (point-min) start1 12)
                             'dsh-emacs-user-message t))
        (when start2
          (put-text-property (+ (point-min) start2) (+ (point-min) start2 20)
                             'dsh-emacs-user-message t))))
    (let ((index (dsh-emacs-imenu-create-user-index)))
      (ert-info ((format "%s" "imenu-user-index"))
        (should (and (= (length index) 2)
                     (string-match-p "hello world" (car (car index)))
                     (string-match-p "second" (car (cadr index)))))))))

;; A question at point-min belongs in the directory, and menu targets must
;; continue pointing at that question after a page is prepended.
(ert-deftest dsh-emacs-test-history-history-index-includes-buffer-start ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (insert (propertize "FIRST QUESTION\n" 'dsh-emacs-user-message t)
            "answer\n"
            (propertize "SECOND QUESTION\n" 'dsh-emacs-user-message t))
    (let ((index (dsh-emacs-imenu-create-user-index)))
      (ert-info ((format "%s" "history-index-includes-buffer-start"))
        (should (and (= (length index) 2)
                     (string-match-p "FIRST QUESTION" (caar index)))))
      (goto-char (point-min))
      (insert "older page\n")
      (ert-info ((format "%s" "history-index-targets-follow-insertions"))
        (should (and (markerp (cdar index))
                     (save-excursion
                       (goto-char (cdar index))
                       (looking-at "FIRST QUESTION"))))))))

;; --- Test: load earlier history forward (session/page prepend) ---
;; Record the assistant body as markdown so render order can be asserted by
;; position:
;;   index: 1=USER-1 2=ASSIST-1 3=ASSIST-2 4=ASSIST-3 5=USER-2 6=ASSIST-4
;;   initial session window = seq 3~6 (anchor already at 6), the earlier page =
;; seq 1~2.
(defun dsh-test--history-fixture (type seq text)
  "One wire-shaped history record \"{type:event, event:{TYPE,SEQ …}}\".
TYPE is `user/message' or `assistant/message'; TEXT is its body."
  (list (cons "type" "event")
        (cons "event" (dsh-test--history-event type seq text))))

(defun dsh-test--history-event (type seq text)
  "One wire-shaped event of TYPE at SEQ carrying TEXT.
Content blocks are vectors, exactly as `json-read' decodes a JSON array."
  (let ((blocks (vector (list (cons "type" "text") (cons "text" text)))))
    (if (equal type "user/message")
        (list (cons "type" type) (cons "seq" seq)
              (cons "data" (list (cons "content" blocks))))
      (list (cons "type" type) (cons "seq" seq)
            (cons "data" (list (cons "message"
                                     (list (cons "content" blocks)))))))))

(defun dsh-test--history-text-pos (needle)
  "Position of NEEDLE in the current buffer, or nil."
  (save-excursion
    (goto-char (point-min))
    (when (search-forward needle nil t)
      (match-beginning 0))))

(defun dsh-test--history-event-record (type seq data)
  "One wire-shaped history record for TYPE at SEQ carrying DATA.
DATA is the raw `data' alist, for event types beyond user/assistant
messages (e.g. `command/done')."
  (list (cons "type" "event")
        (cons "event" (list (cons "type" type) (cons "seq" seq)
                            (cons "data" data)))))

;; Skill evidence in an older page belongs to that page's preceding message,
;; even when the newest message contains the same uncached gesture.
(ert-deftest dsh-emacs-test-history-history-skill-evidence-decorates-prepended-message ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs--buffer-session "sess-history-gesture")
    (let ((dsh-emacs--command-catalogs nil)
          (dsh-emacs--skill-catalogs nil))
      (dsh-emacs-render-event
       (dsh-test--history-event "user/message" 10 "recent /audit"))
      (setq dsh-emacs--history-earliest-seq 10)
      (dsh-emacs--load-older-history-page
       (current-buffer)
       `((records . ,(vector
                      (dsh-test--history-fixture
                       "user/message" 1 "older /audit")
                      (dsh-test--history-event-record
                       "user/message" 2
                       '((content . [((type . "text") (text . "instructions"))])
                         (source . ((kind . "skill-invocation")
                                    (name . "audit")))))))
         (hasMore . :json-false)))
      (let ((older (+ 6 (dsh-test--history-text-pos "older /audit")))
            (recent (+ 7 (dsh-test--history-text-pos "recent /audit"))))
        (ert-info ((format "%s" "history-skill-evidence-decorates-prepended-message"))
          (should (equal "audit" (get-text-property older 'dsh-emacs-slash-gesture)))
          (should (memq 'dsh-emacs-slash-skill-face (dsh-test--faces-at older)))
          (should (equal "Skill /audit" (get-text-property older 'help-echo))))
        (ert-info ((format "%s" "history-skill-evidence-leaves-newer-message-alone"))
          (should (null (get-text-property recent 'dsh-emacs-slash-gesture)))
          (should (not (memq 'dsh-emacs-slash-skill-face (dsh-test--faces-at recent))))
          (should (null (get-text-property recent 'help-echo))))))))

;; 100: prepend inserts the earlier page above the old content and does not move
;; the anchor.
(ert-deftest dsh-emacs-test-history-history-prepend-orders-old-above-new ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (let ((newer (list (dsh-test--history-fixture "assistant/message" 3 "ASSIST-2")
                       (dsh-test--history-fixture "assistant/message" 4 "ASSIST-3")
                       (dsh-test--history-fixture "user/message" 5 "USER-2")
                       (dsh-test--history-fixture "assistant/message" 6 "ASSIST-4")))
          (older (list (dsh-test--history-fixture "user/message" 1 "USER-1")
                       (dsh-test--history-fixture "assistant/message" 2 "ASSIST-1"))))
      (dsh-emacs-render-history-events newer)
      (let ((marker (dsh-emacs-render--history-prepend-marker)))
        (setq dsh-emacs--history-insert-marker marker)
        (unwind-protect
            (dsh-emacs-render-history-events
             older nil 3 :insert-before (marker-position marker) :follow-p nil)
          (set-marker marker nil)
          (setq dsh-emacs--history-insert-marker nil))
        (let ((text (buffer-substring-no-properties (point-min) (point-max)))
              (p1 (dsh-test--history-text-pos "ASSIST-1"))
              (p3 (dsh-test--history-text-pos "ASSIST-2"))
              (p6 (dsh-test--history-text-pos "ASSIST-4")))
          (ert-info ((format "%s" "history-prepend-orders-old-above-new"))
            (should p1)
            (should p3)
            (should p6)
            (should (< p1 p3 p6))
            (should (string-match "USER-1" text))
            (should (< (dsh-test--history-text-pos "USER-1") p1))))
        (ert-info ((format "%s" "history-prepend-keeps-live-anchor"))
          (should (= dsh-emacs--anchor-seq 6)))))))

;; 101: prepend does not render events above the cap (updates) in a batch.
(ert-deftest dsh-emacs-test-history-history-prepend-respects-seq-cap ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (let ((marker (progn (insert "HEADER\n")
                         (dsh-emacs-render-event
                          (dsh-test--history-event "user/message" 1 "NEWER"))
                         (copy-marker (point-min) nil))))
      (setq dsh-emacs--history-insert-marker marker)
      (unwind-protect
          (dsh-emacs-render-history-events
           (list (dsh-test--history-fixture "assistant/message" 0 "OLD")
                 (dsh-test--history-fixture "assistant/message" 5 "BEYOND"))
           nil 5 :insert-before (marker-position marker) :follow-p nil)
        (set-marker marker nil)
        (setq dsh-emacs--history-insert-marker nil))
      (ert-info ((format "%s" "history-prepend-respects-seq-cap"))
        (should (string-match "OLD" (buffer-string)))
        (should (not (string-match "BEYOND" (buffer-string))))))))

;; 102: the prepend marker points above the oldest fragment (skipping the blank
;; line and welcome area above it).
(ert-deftest dsh-emacs-test-history-history-prepend-marker-above-oldest ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (insert "WELCOME\n")
    (dsh-emacs-render-event
     (dsh-test--history-event "assistant/message" 1 "FIRST-REPLY"))
    (let ((marker (dsh-emacs-render--history-prepend-marker)))
      (ert-info ((format "%s" "history-prepend-marker-above-oldest"))
        (should (markerp marker))
        (should (<= (marker-position marker) (dsh-test--history-text-pos "FIRST-REPLY"))))
      (when (markerp marker) (set-marker marker nil)))))

;; 103: the follow snapshot records the pagination frontier (oldest seq + hasMore).
(ert-deftest dsh-emacs-test-history-history-window-records-frontier ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (dsh-emacs-render--note-history-window
     (list (dsh-test--history-fixture "user/message" 4 "A")
           (dsh-test--history-fixture "assistant/message" 5 "B"))
     nil)
    (ert-info ((format "%s" "history-window-records-frontier"))
      (should (= dsh-emacs--history-earliest-seq 4))
      (should (null dsh-emacs--history-has-more)))
    (dsh-emacs-render--note-history-window
     (list (dsh-test--history-fixture "user/message" 1 "A")) t)
    (ert-info ((format "%s" "history-window-records-has-more"))
      (should (= dsh-emacs--history-earliest-seq 1))
      (should (eq dsh-emacs--history-has-more t)))
    ;; A reconnect snapshot whose tail starts later must not move the cursor
    ;; past pages this buffer already loaded.
    (dsh-emacs-render--note-history-window
     (list (dsh-test--history-fixture "user/message" 9 "A")) t)
    (ert-info ((format "%s" "history-window-frontier-only-moves-earlier"))
      (should (= dsh-emacs--history-earliest-seq 1)))))

;; 104: `dsh-emacs-load-older-history' pulls one page and prepends it, advancing
;; the cursor.
(ert-deftest dsh-emacs-test-history-load-older-history-request ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *dsh-history-load*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (dsh-emacs-mode)
            (dsh-emacs-modeline-setup)
            (setq-local dsh-emacs--buffer-session "session-history")
            (dsh-emacs-render-history-events
             (list (dsh-test--history-fixture "assistant/message" 3 "ASSIST-2")
                   (dsh-test--history-fixture "user/message" 4 "USER-2")))
            (setq-local dsh-emacs--history-earliest-seq 3)
            (setq-local dsh-emacs--history-has-more t)
            ;; The follow snapshot's inclusive cursor; `throughSeq' must carry a
            ;; real seq (the wire's -1 reads an empty page on the server).
            (setq-local dsh-emacs--history-cursor 4))
          (let ((captured nil)
                (callback nil))
            (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (_method params cb)
                         (setq captured params callback cb))))
              (with-current-buffer buf
                (dsh-emacs-load-older-history)))
            (ert-info ((format "%s" "load-older-history-request"))
              (should captured)
              (should (integerp (cdr (assq 'throughSeq
                                           (cdr (assq 'request captured))))))
              (should (not (equal -1 (cdr (assq 'throughSeq
                                                (cdr (assq 'request captured)))))))
              (should (equal 4 (cdr (assq 'throughSeq
                                          (cdr (assq 'request captured)))))))
            (ert-info ((format "%s" "load-older-history-params"))
              (should (equal "session-history"
                             (cdr (assq 'sessionId
                                        (cdr (assq 'address
                                                   (cdr (assq 'request captured))))))))
              (should (= 3 (cdr (assq 'beforeSeq (cdr (assq 'request captured))))))
              (should (= dsh-emacs-history-window
                         (cdr (assq 'maxMessages (cdr (assq 'request captured)))))))
            (funcall callback t
                     (list (cons "records"
                                 (vector
                                  (dsh-test--history-fixture "user/message" 1 "USER-1")
                                  (dsh-test--history-fixture
                                   "assistant/message" 2 "ASSIST-1")))
                           (cons "hasMore" :json-false)))
            (with-current-buffer buf
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (ert-info ((format "%s" "load-older-history-prepends"))
                  (should (string-match "ASSIST-1" text))
                  (should (string-match "USER-1" text))
                  (should (< (dsh-test--history-text-pos "USER-1")
                             (dsh-test--history-text-pos "ASSIST-1")
                             (dsh-test--history-text-pos "ASSIST-2")))))
              (ert-info ((format "%s" "load-older-history-advances-cursor"))
                (should (= dsh-emacs--history-earliest-seq 1))
                (should (null dsh-emacs--history-has-more))
                (should (null dsh-emacs--history-loading))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; 105: no request is sent when hasMore=nil.
(ert-deftest dsh-emacs-test-history-load-older-history-stops-at-start ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *dsh-history-nomore*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (dsh-emacs-mode)
            (dsh-emacs-modeline-setup)
            (setq-local dsh-emacs--buffer-session "session-history")
            (setq-local dsh-emacs--history-earliest-seq 1)
            (setq-local dsh-emacs--history-has-more nil))
          (let ((called nil))
            (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (&rest _) (setq called t))))
              (with-current-buffer buf
                (dsh-emacs-load-older-history)))
            (ert-info ((format "%s" "load-older-history-stops-at-start"))
              (should (null called)))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; 106: calling it outside a chat buffer is a user-error.
(ert-deftest dsh-emacs-test-history-load-older-history-requires-chat ()
  :tags '(dsh-unit)
  (let ((other (generate-new-buffer " *dsh-nonchat*")))
    (unwind-protect
        (with-current-buffer other
          (ert-info ((format "%s" "load-older-history-requires-chat"))
            (should (condition-case nil
                        (progn (dsh-emacs-load-older-history) nil)
                      (user-error t)))))
      (when (buffer-live-p other) (kill-buffer other)))))

;; Older pages use real stateful renderers, but cannot change the live turn.
(ert-deftest dsh-emacs-test-history-history-page-settles-tools-case ()
  :tags '(dsh-unit)
  (dolist (busy '(nil t))
    (with-temp-buffer
      (dsh-emacs-mode)
      (dsh-emacs-modeline-setup)
      (setq-local dsh-emacs--buffer-session "history-isolation")
      (dsh-emacs-render-history-events
       (list (dsh-test--history-fixture "assistant/message" 20 "RECENT")))
      (setq dsh-emacs--history-earliest-seq 20
            dsh-emacs--modeline-model "current-model"
            dsh-emacs--modeline-step '(7 8)
            dsh-emacs--turn-awaiting t
            dsh-emacs--todo-list '(("Current plan" . "pending")))
      (dsh-emacs--ml-busy-set busy)
      (let* ((step dsh-emacs--modeline-step)
             (todo dsh-emacs--todo-list)
             (notifications 0)
             (stream (dsh-emacs-render--start-assistant-stream
                      '((data . ((turn . 7) (step . 8)))) "LIVE-BODY"))
             (start (marker-position (plist-get stream :start)))
             (timer (progn
                      (dsh-emacs-render--start-assistant-stream
                       '((data . ((turn . 7) (step . 8)))) "-PENDING")
                      (plist-get stream :timer)))
             (page (json-read-from-string
                    "{\"hasMore\":false,\"records\":[
{\"type\":\"event\",\"event\":{\"type\":\"turn/start\",\"seq\":1,\"data\":{\"turn\":1}}},
{\"type\":\"event\",\"event\":{\"type\":\"request/context\",\"seq\":2,\"data\":{\"model\":\"old-model\"}}},
{\"type\":\"event\",\"event\":{\"type\":\"step/start\",\"seq\":3,\"data\":{\"turn\":1,\"step\":1}}},
{\"type\":\"event\",\"event\":{\"type\":\"tool/call\",\"seq\":4,\"data\":{\"callId\":\"old-call\",\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"echo history\\\"}\"}}},
{\"type\":\"event\",\"event\":{\"type\":\"tool/result\",\"seq\":5,\"data\":{\"message\":{\"callId\":\"old-call\",\"content\":[{\"type\":\"tool-result\",\"exitCode\":0,\"content\":[{\"type\":\"text\",\"text\":\"HISTORICAL-OUTPUT\"}]}]}}}},
{\"type\":\"event\",\"event\":{\"type\":\"tool/call\",\"seq\":6,\"data\":{\"callId\":\"old-todo\",\"name\":\"todo_write\",\"arguments\":\"{\\\"todos\\\":[{\\\"content\\\":\\\"Old plan\\\",\\\"status\\\":\\\"completed\\\"}]}\"}}},
{\"type\":\"event\",\"event\":{\"type\":\"turn/end\",\"seq\":7,\"data\":{\"turn\":1,\"reason\":{\"kind\":\"completed\"}}}}]}")))
        (cl-letf (((symbol-function 'dsh-emacs-notify--post)
                   (lambda (&rest _) (cl-incf notifications))))
          (dsh-emacs--load-older-history-page (current-buffer) page))
        (ert-info ((format "%s" (format "history-page-settles-tools-%s" busy)))
          (should (eq 'success (plist-get (dsh-emacs-render--tool-state "old-call")
                                          :state)))
          (let ((block (dsh-emacs-ui-find-block
                        (dsh-emacs-render--make-namespace) "tool-old-call")))
            (should block)
            (save-excursion
              (goto-char (car block))
              (should (map-elt (get-text-property (point) 'dsh-emacs-ui-state)
                               :collapsed))
              (dsh-emacs-ui-toggle-fragment))
            (should (string-match-p "HISTORICAL-OUTPUT" (buffer-string)))))
        (ert-info ((format "%s" (format "history-page-preserves-live-state-%s" busy)))
          (should (eq dsh-emacs--ml-busy busy))
          (should (equal dsh-emacs--modeline-model "current-model"))
          (should (equal dsh-emacs--modeline-step step))
          (should (equal dsh-emacs--todo-list todo))
          (should dsh-emacs--turn-awaiting)
          (should (= notifications 0))
          (should (= dsh-emacs--anchor-seq 20)))
        (ert-info ((format "%s" (format "history-page-preserves-live-stream-%s" busy)))
          (should (eq dsh-emacs--streaming-assistant stream))
          (should (eq (plist-get stream :timer) timer))
          (should (memq timer timer-list))
          (should (equal (plist-get stream :pending) '("-PENDING")))
          (should (marker-buffer (plist-get stream :start)))
          (should (> (marker-position (plist-get stream :start)) start))
          (should (equal "LIVE-BODY" (buffer-substring-no-properties
                                      (plist-get stream :start)
                                      (plist-get stream :end)))))
        (dsh-emacs--ml-busy-clear)))))

;; The in-render "this is a settled page" flag decides page-vs-live on its
;; own, independent of whether an insertion marker could be computed.
(ert-deftest dsh-emacs-test-history-history-page-predicate-unset ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "history-page-predicate-unset"))
    (should (not (dsh-emacs-render--history-page-p)))))

(ert-deftest dsh-emacs-test-history-history-page-predicate-set ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((dsh-emacs--history-page t))
      (ert-info ((format "%s" "history-page-predicate-set"))
        (should (dsh-emacs-render--history-page-p))))
    (ert-info ((format "%s" "history-page-predicate-cleared"))
      (should (not (dsh-emacs-render--history-page-p))))
    ;; A marker alone no longer means "page": it is positioning state only.
    (let ((marker (copy-marker (point-min) t)))
      (setq dsh-emacs--history-insert-marker marker)
      (ert-info ((format "%s" "history-page-predicate-ignores-marker"))
        (should (not (dsh-emacs-render--history-page-p))))
      (set-marker marker nil)
      (setq dsh-emacs--history-insert-marker nil))))

;; A page renders settled text synchronously and never joins the live idle
;; Markdown queue (whose jobs format the streaming tail).
(ert-deftest dsh-emacs-test-history-history-page-renders-markdown-synchronously ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-stream-markdown-limit 40))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "history-markdown")
      (setq-local dsh-emacs--history-earliest-seq 5)
      (let ((body (concat "**bold** word " (make-string 120 ?x))))
        (dsh-emacs--load-older-history-page
         (current-buffer)
         (list (cons "hasMore" :json-false)
               (cons "records"
                     (vector (dsh-test--history-event-record
                              "assistant/message" 4
                              (list (cons "message"
                                          (list (cons "content"
                                                      (vector
                                                       (list (cons "type" "text")
                                                             (cons "text" body))))))))))))
        (ert-info ((format "%s" "history-page-renders-markdown-synchronously"))
          (should (null dsh-emacs--markdown-pending))
          (should (null dsh-emacs--markdown-timer))
          (should (string-match-p "bold" (buffer-string)))
          (should (let ((face (get-text-property
                               (1+ (dsh-test--history-text-pos "bold")) 'face)))
                    (memq 'dsh-emacs-markdown-bold
                          (if (listp face) face (list face))))))))))

;; Control: the same body on the live path still defers, so the page gate
;; narrows the idle queue instead of disabling it.
(ert-deftest dsh-emacs-test-history-live-path-still-defers-markdown ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-stream-markdown-limit 40))
    (with-temp-buffer
      (dsh-emacs-mode)
      (dsh-emacs-render-history-events
       (list (dsh-test--history-event-record
              "assistant/message" 4
              (list (cons "message"
                          (list (cons "content"
                                      (vector (list (cons "type" "text")
                                                    (cons "text"
                                                          (concat "**b** "
                                                                  (make-string 100 ?x))))))))))))
      (ert-info ((format "%s" "live-path-still-defers-markdown"))
        (should dsh-emacs--markdown-pending)
        (should dsh-emacs--markdown-timer))
      (dsh-emacs-render--cancel-markdown))))

(ert-deftest dsh-emacs-test-history-history-page-command-keeps-pending ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs--buffer-session "history-command")
    (setq-local dsh-emacs--history-earliest-seq 5)
    (let* ((block-id "cmd-old-cmd")
           (ns (dsh-emacs-render--make-namespace))
           (pending '(("cmd-temp-local" "compile"))))
      (puthash "old-cmd" (list ns block-id "compile" nil)
               dsh-emacs--command-blocks)
      (setq dsh-emacs--pending-command pending)
      (dsh-emacs--load-older-history-page
       (current-buffer)
       (list (cons "hasMore" :json-false)
             (cons "records"
                   (vector
                    (dsh-test--history-event-record
                     "command/done" 4
                     '((commandId . "old-cmd")
                       (name . "compile")
                       (kind . "success")
                       (text . "COMPILE-DONE")))))))
      (ert-info ((format "%s" "history-page-command-keeps-pending"))
        (should (equal dsh-emacs--pending-command pending))
        (should (string-match-p "compile" (buffer-string)))
        (should (string-match-p "✓ done" (buffer-string)))))))

;; Backfill keeps newest-first recall, including when the list is full.
(ert-deftest dsh-emacs-test-history-history-page-keeps-recall-order-limit-case ()
  :tags '(dsh-unit)
  (dolist (limit '(3 5))
    (let ((dsh-emacs-input-history-length limit)
          (dsh-emacs--input-history-by-session (make-hash-table :test 'equal)))
      (with-temp-buffer
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "history-recall")
        (dsh-emacs-render-history-events
         (list (dsh-test--history-fixture "user/message" 20 "LATEST")))
        (setq dsh-emacs--history-earliest-seq 20)
        (puthash "history-recall" '("LATEST" "RECENT")
                 dsh-emacs--input-history-by-session)
        (dsh-emacs--load-older-history-page
         (current-buffer)
         (list (cons "hasMore" :json-false)
               (cons "records"
                     (vector (dsh-test--history-fixture "user/message" 1 "ANCIENT")
                             (dsh-test--history-fixture "user/message" 2 "RECENT")
                             (dsh-test--history-fixture "user/message" 3 "OLDER")))))
        (ert-info ((format "%s" (format "history-page-keeps-recall-order-limit-%s" limit)))
          (should (equal (gethash "history-recall" dsh-emacs--input-history-by-session)
                         (if (= limit 3)
                             '("LATEST" "RECENT" "OLDER")
                           '("LATEST" "RECENT" "OLDER" "ANCIENT")))))))))

;; Repeated pages retain a reading window and draft, even after header trim.
(ert-deftest dsh-emacs-test-history-history-pages-preserve-window-and-draft ()
  :tags '(dsh-unit)
  (save-window-excursion
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "history-window")
      (dsh-emacs-render-history-events
       (list (dsh-test--history-fixture "user/message" 10 "TAIL-USER")
             (dsh-test--history-fixture "assistant/message" 11 "TAIL-REPLY")))
      (setq dsh-emacs--history-earliest-seq 10)
      (let ((inhibit-read-only t))
        (delete-region (point-min)
                       (text-property-any (point-min) (point-max)
                                          'dsh-emacs-transcript-block t)))
      (goto-char dsh-emacs--input-marker)
      (insert "DRAFT")
      (switch-to-buffer (current-buffer))
      (let ((draft-point (copy-marker (point) t))
            (reading-point (copy-marker (dsh-test--history-text-pos "TAIL-REPLY") t)))
        (set-window-start (selected-window) reading-point t)
        (dolist (seq '(5 1))
          (dsh-emacs--load-older-history-page
           (current-buffer)
           (list (cons "hasMore" t)
                 (cons "records"
                       (vector (dsh-test--history-fixture
                                "user/message" seq (format "PAGE-%d" seq)))))))
        (ert-info ((format "%s" "history-pages-preserve-window-and-draft"))
          (should (= (point) draft-point))
          (should (= (window-start) reading-point))
          (should (equal (buffer-substring-no-properties dsh-emacs--input-marker
                                                         (point-max)) "DRAFT"))
          (should (< (dsh-test--history-text-pos "PAGE-1")
                     (dsh-test--history-text-pos "PAGE-5")
                     (dsh-test--history-text-pos "TAIL-USER")
                     (dsh-test--history-text-pos "TAIL-REPLY"))))
        (set-marker draft-point nil)
        (set-marker reading-point nil)))))

;; Each history reader keeps its own text, including at the prepend boundary.
(ert-deftest dsh-emacs-test-history-history-prepend-preserves-boundary-and-second-reader ()
  :tags '(dsh-unit)
  (save-window-excursion
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "history-readers")
      (let ((dsh-emacs-max-buffer-size nil))
        (dsh-emacs-render-history-events
         (list (dsh-test--history-fixture "user/message" 20 "CURRENT QUESTION")
               (dsh-test--history-fixture
                "assistant/message" 21
                (mapconcat (lambda (n) (format "retained line %d" n))
                           (number-sequence 1 100) "\n")))))
      (setq dsh-emacs--history-earliest-seq 20)
      (switch-to-buffer (current-buffer))
      (delete-other-windows)
      (let* ((first (selected-window))
             (second (split-window-below))
             (boundary (dsh-emacs-render--history-prepend-marker))
             (inside (copy-marker (dsh-test--history-text-pos "retained line 20") t)))
        (set-window-start first boundary t)
        (set-window-point first boundary)
        (set-window-buffer second (current-buffer))
        (set-window-start second inside t)
        (set-window-point second inside)
        (dsh-emacs--load-older-history-page
         (current-buffer)
         `((records . ,(vector (dsh-test--history-fixture "user/message" 10 "OLDER")
                               (dsh-test--history-fixture "assistant/message" 11 "OLD REPLY")))
           (hasMore . t)))
        (ert-info ((format "%s" "history-prepend-preserves-boundary-and-second-reader"))
          (should (= (window-start first) boundary))
          (should (= (window-point first) boundary))
          (should (= (window-start second) inside))
          (should (= (window-point second) inside)))
        (set-marker boundary nil)
        (set-marker inside nil)))))

;; Explicitly requested history must survive the normal transcript size cap.
(ert-deftest dsh-emacs-test-history-history-prepend-does-not-trim-requested-page ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs--buffer-session "history-over-cap")
    (let ((dsh-emacs-max-buffer-size nil))
      (dsh-emacs-render-history-events
       (list (dsh-test--history-fixture "user/message" 20 "NEWER QUESTION"))))
    (setq dsh-emacs--history-earliest-seq 20)
    (let ((dsh-emacs-max-buffer-size 80))
      (dsh-emacs--load-older-history-page
       (current-buffer)
       `((records . ,(vector (dsh-test--history-fixture
                              "user/message" 10 (concat "OLDER QUESTION " (make-string 150 ?x)))))
         (hasMore . t))))
    (ert-info ((format "%s" "history-prepend-does-not-trim-requested-page"))
      (should (dsh-test--history-text-pos "OLDER QUESTION"))
      (should (dsh-test--history-text-pos "NEWER QUESTION")))))

(ert-deftest dsh-emacs-test-history-history-reader-defers-destructive-trimming ()
  :tags '(dsh-unit)
  (save-window-excursion
    (with-temp-buffer
      (dsh-emacs-mode)
      (let ((dsh-emacs-max-buffer-size nil))
        (dsh-emacs-render-history-events
         (list (dsh-test--history-fixture "user/message" 10 "READING HERE")
               (dsh-test--history-fixture "assistant/message" 11 (make-string 500 ?x)))))
      (switch-to-buffer (current-buffer))
      (goto-char (dsh-test--history-text-pos "READING HERE"))
      (set-window-start (selected-window) (line-beginning-position) t)
      (let ((before (buffer-string)) (dsh-emacs-max-buffer-size 80))
        (dsh-emacs-render--trim-buffer)
        (ert-info ((format "%s" "history-reader-defers-destructive-trimming"))
          (should (equal-including-properties before (buffer-string))))))))

(ert-deftest dsh-emacs-test-history-history-latest-resumes-only-this-window ()
  :tags '(dsh-unit)
  (save-window-excursion
    (with-temp-buffer
      (dsh-emacs-mode)
      (switch-to-buffer (current-buffer))
      (delete-other-windows)
      (dsh-emacs-render-history-events
       (list (dsh-test--history-fixture "user/message" 10 "FIRST")
             (dsh-test--history-fixture "assistant/message" 11 "FIRST ANSWER")
             (dsh-test--history-fixture "user/message" 20 "SECOND")))
      (goto-char (point-max))
      (insert "KEEP DRAFT")
      (let* ((index (dsh-emacs-imenu-create-user-index))
             (first (cdar index))
             (reader (split-window-below)))
        (set-window-buffer reader (current-buffer))
        (set-window-point reader first)
        (set-window-start reader first t)
        (goto-char first)
        (call-interactively (key-binding (kbd "C-c >")))
        (ert-info ((format "%s" "history-latest-resumes-only-this-window"))
          (should (= (point) (point-max)))
          (should (equal (dsh-emacs-render--following-windows) (list (selected-window))))
          (should (= (window-point reader) first))
          (should (= (window-start reader) first))
          (should (equal (buffer-substring-no-properties dsh-emacs--input-marker
                                                         (point-max)) "KEEP DRAFT")))
        (ert-info ((format "%s" "history-imenu-index-installed"))
          (should (eq imenu-create-index-function #'dsh-emacs-imenu-create-user-index))
          (should imenu-auto-rescan))
        ;; Even a reader close enough to see the bottom must not follow cards.
        (let ((start (copy-marker (window-start reader) t)))
          (dsh-emacs-ui-update-fragment
           '((:namespace-id . "test") (:block-id . "live-card")
             (:label-left . "Tool") (:body . "new output"))
           :create-new t :insert-before (dsh-emacs-render--input-insert-point))
          (ert-info ((format "%s" "history-secondary-reader-does-not-follow-cards"))
            (should (= (window-start reader) start))
            (should (= (window-point reader) first)))
          (set-marker start nil))))))

;; Deferral must not accidentally disable the cap once the reader returns.
(ert-deftest dsh-emacs-test-history-history-trimming-resumes-and-protects-long-draft ()
  :tags '(dsh-unit)
  (save-window-excursion
    (with-temp-buffer
      (dsh-emacs-mode)
      (switch-to-buffer (current-buffer))
      (delete-other-windows)
      (let ((dsh-emacs-max-buffer-size nil))
        (dsh-emacs-render-history-events
         (list (dsh-test--history-fixture "user/message" 10 "OLD QUESTION")
               (dsh-test--history-fixture "assistant/message" 11 (make-string 500 ?x)))))
      (goto-char (point-max))
      (insert (make-string 100 ?d))
      (dsh-emacs-goto-latest)
      (let ((before (buffer-size)) (dsh-emacs-max-buffer-size 80))
        (dsh-emacs-render--trim-buffer)
        (ert-info ((format "%s" "history-trimming-resumes-and-protects-long-draft"))
          (should (< (buffer-size) before))
          (should (equal (buffer-substring-no-properties dsh-emacs--input-marker
                                                         (point-max)) (make-string 100 ?d)))
          (should (dsh-emacs-render--input-anchor-pos)))))))

;; A buffer whose input boundary cannot be located is left alone: without a
;; known cut point, trimming could destroy the draft instead of signalling.
(ert-deftest dsh-emacs-test-history-history-trimming-defers-without-input-anchor ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((dsh-emacs-max-buffer-size nil))
      (dsh-emacs-render-history-events
       (list (dsh-test--history-fixture "assistant/message" 10 (make-string 500 ?x)))))
    (goto-char (point-max))
    (insert (make-string 100 ?d))
    (let ((before (buffer-string)) (dsh-emacs-max-buffer-size 80) failure)
      (condition-case err
          (cl-letf (((symbol-function 'dsh-emacs-render--input-insert-point)
                     (lambda () nil)))
            (dsh-emacs-render--trim-buffer))
        (error (setq failure err)))
      (ert-info ((format "%s" "history-trimming-defers-without-input-anchor"))
        (should (null failure))
        (should (equal-including-properties before (buffer-string)))))))

(ert-deftest dsh-emacs-test-history-opening-completes-one-round-without-moving-draft ()
  :tags '(dsh-unit)
  (dolist (subagent '(nil t))
    (save-window-excursion
      (with-temp-buffer
        (switch-to-buffer (current-buffer))
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "opening-rounds")
        (when subagent
          (setq-local dsh-emacs--buffer-subagent
                      (dsh-protocol-subagent-address-create
                       "parent" "opening-rounds" "continuable")))
        (goto-char (point-max))
        (insert "UNSENT DRAFT")
        (let ((dsh-emacs-history-rounds 3)
              (dsh-emacs-history-window 2)
              (draft (copy-marker (point) t))
              (dsh-emacs--input-history-by-session (make-hash-table :test 'equal))
              requests callbacks)
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params callback)
                       (should (equal method "session/page"))
                       (push (alist-get 'request params) requests)
                       (setq callbacks (append callbacks (list callback))))))
            (dsh-emacs-events--follow-snapshot
             (current-buffer)
             `((cursor . 95) (hasMore . t)
               (records . ,(vector
                            (dsh-test--history-fixture "assistant/message" 80 "ROUND-8 TAIL")))))
            (should (= (length requests) 1))
            (should (= (alist-get 'minTurns (alist-get 'turnWindow (car requests))) 1))
            (should (= (alist-get 'maxMessages (car requests)) 2))
            (should (= (alist-get 'throughSeq (car requests)) 95))
            (should (= (alist-get 'beforeSeq (car requests)) 80))
            (should (equal (alist-get 'address (car requests))
                           (dsh-protocol-session-address-json
                            "opening-rounds" dsh-emacs--buffer-subagent)))
            (funcall (pop callbacks) t
                     `((hasMore . t)
                       (records . ,(vector (dsh-test--history-fixture
                                            "assistant/message" 75 "ROUND-8 MIDDLE")))))
            (should-not (string-match-p "ROUND-8 MIDDLE" (buffer-string)))
            (should (= dsh-emacs--history-earliest-seq 80))
            ;; Live output must remain independent of the backward-page cursor.
            (dsh-emacs-events--follow-event
             (current-buffer) (dsh-test--history-event "assistant/message" 96 "LIVE REPLY"))
            (funcall (pop callbacks) t
                     `((hasMore . t)
                       (records . ,(vector
                                    (dsh-test--history-event-record "turn/start" 60 '((turn . 7)))
                                    (dsh-test--history-fixture "user/message" 61 "ROUND-7 QUESTION")
                                    (dsh-test--history-event-record "turn/start" 70 '((turn . 8)))
                                    (dsh-test--history-fixture "user/message" 71 "ROUND-8 QUESTION")))))
            (should-not callbacks)
            (should-not dsh-emacs--history-loading)
            (should (= dsh-emacs--history-earliest-seq 70))
            (should (= dsh-emacs--anchor-seq 96))
            (should (= (point) draft))
            (should (string-suffix-p "UNSENT DRAFT" (buffer-string)))
            (should-not (dsh-test--history-text-pos "ROUND-7 QUESTION"))
            (should (< (dsh-test--history-text-pos "ROUND-8 QUESTION")
                       (dsh-test--history-text-pos "ROUND-8 MIDDLE")
                       (dsh-test--history-text-pos "ROUND-8 TAIL")
                       (dsh-test--history-text-pos "LIVE REPLY")))
            (set-marker draft nil)))))))

(ert-deftest dsh-emacs-test-history-opening-cancel-or-failure-keeps-tail ()
  :tags '(dsh-unit)
  (dolist (finish '(cancel failure))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "opening-cancel")
      (let ((snapshot
             `((cursor . 20) (hasMore . t)
               (records . ,(vector (dsh-test--history-fixture
                                    "assistant/message" 19 "OPENING TAIL")))))
            callbacks request before)
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method _params callback)
                     (setq callbacks (append callbacks (list callback))))))
          (dsh-emacs-events--follow-snapshot (current-buffer) snapshot)
          (setq request dsh-emacs--history-loading before (buffer-string))
          (should (= (length callbacks) 1))
          (funcall (pop callbacks) t
                   `((hasMore . t)
                     (records . ,(vector (dsh-test--history-fixture
                                          "assistant/message" 18 "STAGED PREFIX")))))
          (should (= (length callbacks) 1))
          (when (eq finish 'cancel) (dsh-emacs-load-older-history))
          (funcall (pop callbacks) (eq finish 'cancel)
                   '((records . []) (hasMore . :json-false)))
          (should-not dsh-emacs--history-loading)
          (should-not (marker-buffer (plist-get request :point)))
          (should (= dsh-emacs--history-earliest-seq 19))
          (should (equal-including-properties before (buffer-string)))
          (dsh-emacs-events--follow-snapshot (current-buffer) snapshot)
          (should-not callbacks)
          (should-not dsh-emacs--history-loading))))))

(ert-deftest dsh-emacs-test-history-opening-skips-unneeded-pages ()
  :tags '(dsh-unit)
  (dolist (case '(complete exhausted empty reconnect))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "opening-done")
      (when (eq case 'reconnect)
        (setq dsh-emacs--history-earliest-seq 1))
      (let ((dsh-emacs-history-rounds 5)
            requests)
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (&rest args) (push args requests))))
          (dsh-emacs-events--follow-snapshot
           (current-buffer)
           `((cursor . 10)
             (hasMore . ,(if (memq case '(exhausted empty)) :json-false t))
             (records . ,(pcase case
                           ('empty [])
                           ('complete (vector
                                      (dsh-test--history-event-record
                                       "turn/start" 9 '((turn . 4)))
                                      (dsh-test--history-fixture
                                       "user/message" 10 "VISIBLE QUESTION")))
                           (_ (vector (dsh-test--history-fixture
                                       "user/message" 9 "VISIBLE QUESTION"))))))))
        (should-not requests)
        (should-not dsh-emacs--history-loading)
        (should (= dsh-emacs--anchor-seq 10))))))

;; A long round must cross transport pages without exposing a partial batch.
(ert-deftest dsh-emacs-test-history-history-round-request-target-and-budget ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs--buffer-session "round-loading")
    (dsh-emacs-render-history-events
     (list (dsh-test--history-fixture "assistant/message" 90 "ROUND-9 TAIL")))
    (setq dsh-emacs--history-earliest-seq 90
          dsh-emacs--history-cursor 95 dsh-emacs--history-has-more t)
    (let ((before (buffer-string)) requests callbacks feedback)
      (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                 (lambda (_method params callback)
                   (push (alist-get 'request params) requests)
                   (setq callbacks (append callbacks (list callback)))))
                ((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq feedback (apply #'format format-string args)))))
        (dsh-emacs-load-older-history)
        (ert-info ((format "%s" "history-round-request-target-and-budget"))
          (should (= (alist-get 'minTurns (alist-get 'turnWindow (car requests))) 3))
          (should (= (alist-get 'maxMessages (car requests)) dsh-emacs-history-window)))
        (funcall (pop callbacks) t
                 `((records . ,(vector (dsh-test--history-fixture
                                        "assistant/message" 80 "ROUND-9 MIDDLE")))
                   (hasMore . t)))
        (ert-info ((format "%s" "history-round-partial-page-is-staged"))
          (should (equal-including-properties before (buffer-string)))
          (should (= dsh-emacs--history-earliest-seq 90))
          (should (= (alist-get 'beforeSeq (car requests)) 80))
          (should (= (alist-get 'minTurns (alist-get 'turnWindow (car requests))) 3)))
        (funcall (pop callbacks) t
                 `((records . ,(vector
                                (dsh-test--history-event-record "turn/start" 60 '((turn . 8)))
                                (dsh-test--history-fixture "user/message" 61 "ROUND-8 QUESTION")
                                (dsh-test--history-event-record "turn/start" 70 '((turn . 9)))
                                (dsh-test--history-fixture "user/message" 71 "ROUND-9 QUESTION")))
                   (hasMore . t)))
        (ert-info ((format "%s" "history-round-request-remaining-count"))
          (should (equal-including-properties before (buffer-string)))
          (should (= (alist-get 'beforeSeq (car requests)) 60))
          (should (= (alist-get 'minTurns (alist-get 'turnWindow (car requests))) 1)))
        (funcall (pop callbacks) t
                 `((records . ,(vector
                                (dsh-test--history-event-record "turn/start" 50 '((turn . 7)))
                                (dsh-test--history-fixture "user/message" 51 "ROUND-7 QUESTION")))
                   (hasMore . t)))
        (ert-info ((format "%s" "history-rounds-complete-range-is-rendered-once"))
          (should (null callbacks))
          (should (null dsh-emacs--history-loading))
          (should (= (length requests) 3))
          (should (= dsh-emacs--history-earliest-seq 50))
          (should (= dsh-emacs--anchor-seq 90))
          (should dsh-emacs--history-has-more)
          (should (string-match-p "Loaded rounds 7–9 (3 rounds)" feedback))
          (should (not (string-match-p "^Round [0-9]+" (buffer-string))))
          (should (< (dsh-test--history-text-pos "ROUND-7 QUESTION")
                     (dsh-test--history-text-pos "ROUND-8 QUESTION")
                     (dsh-test--history-text-pos "ROUND-9 QUESTION")
                     (dsh-test--history-text-pos "ROUND-9 MIDDLE")
                     (dsh-test--history-text-pos "ROUND-9 TAIL"))))))))

;; A smaller requested range discards the server's extra prefix, so it can
;; be fetched next time; exhaustion reports the actual number of rounds.
(ert-deftest dsh-emacs-test-history-history-round-count-case ()
  :tags '(dsh-unit)
  (dolist (target '(1 3))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "round-count")
      (setq dsh-emacs--history-earliest-seq 90
            dsh-emacs--history-cursor 95 dsh-emacs--history-has-more t)
      (let (feedback captured)
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method params callback)
                     (setq captured params)
                     (funcall callback t
                              `((records . ,(vector
                                             (dsh-test--history-event-record "turn/start" 10 '((turn . 1)))
                                             (dsh-test--history-fixture "user/message" 11 "FIRST ROUND")
                                             (dsh-test--history-event-record "turn/start" 20 '((turn . 2)))
                                             (dsh-test--history-fixture "user/message" 21 "SECOND ROUND")))
                                (hasMore . :json-false)))))
                  ((symbol-function 'message)
                   (lambda (format-string &rest args)
                     (setq feedback (apply #'format format-string args)))))
          (dsh-emacs-load-older-history target)
          (ert-info ((format "%s" (format "history-round-count-%d" target)))
            (should (= (alist-get 'minTurns (alist-get 'turnWindow (alist-get 'request captured))) target))
            (should (= dsh-emacs--history-earliest-seq (if (= target 1) 20 10)))
            (should (eq (not (null dsh-emacs--history-has-more)) (= target 1)))
            (should (eq (not (null (dsh-test--history-text-pos "FIRST ROUND"))) (= target 3)))
            (should (string-match-p (if (= target 1) "Loaded rounds 2–2 (1 round)"
                                      "Loaded rounds 1–2 (2 rounds).*beginning") feedback))))))))

;; A human round is user+assistant: a leading child/goal turn belongs to the
;; previous round and must not become the top of a loaded page.
(ert-deftest dsh-emacs-test-history-rounds-start-at-user-turn ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs--buffer-session "human-round-boundary")
    (setq dsh-emacs--history-earliest-seq 90
          dsh-emacs--history-cursor 100
          dsh-emacs--history-has-more t)
    (let (feedback)
      (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                 (lambda (_method _params callback)
                   (funcall callback
                            t
                            `((records . ,(vector
                                           (dsh-test--history-event-record
                                            "turn/start" 10 '((turn . 1)))
                                           (dsh-test--history-event-record
                                            "user/message" 11
                                            '((content . [((type . "text")
                                                           (text . "CHILD-1"))])
                                              (source . ((kind . "agent-message")))))
                                           (dsh-test--history-fixture
                                            "assistant/message" 12 "ASSIST-1")
                                           (dsh-test--history-event-record
                                            "turn/start" 20 '((turn . 2)))
                                           (dsh-test--history-event-record
                                            "user/message" 21
                                            '((content . [((type . "text")
                                                           (text . "HUMAN-2"))])
                                              (source . ((kind . "user")))))
                                           (dsh-test--history-fixture
                                            "assistant/message" 22 "ASSIST-2")
                                           (dsh-test--history-event-record
                                            "turn/start" 30 '((turn . 3)))
                                           (dsh-test--history-event-record
                                            "user/message" 31
                                            '((content . [((type . "text")
                                                           (text . "CHILD-3"))])
                                              (source . ((kind . "agent-message")))))
                                           (dsh-test--history-fixture
                                            "assistant/message" 32 "ASSIST-3")
                                           (dsh-test--history-event-record
                                            "turn/start" 40 '((turn . 4)))
                                           (dsh-test--history-event-record
                                            "user/message" 41
                                            '((content . [((type . "text")
                                                           (text . "HUMAN-4"))])
                                              (source . ((kind . "user")))))
                                           (dsh-test--history-fixture
                                            "assistant/message" 42 "ASSIST-4")))
                              (hasMore . :json-false)))))
                ((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq feedback (apply #'format format-string args)))))
        (dsh-emacs-load-older-history 2)
        (should (= dsh-emacs--history-earliest-seq 20))
        (should dsh-emacs--history-has-more)
        (should (string-match-p "Loaded rounds 2–4 (2 rounds)" feedback))
        (should-not (dsh-test--history-text-pos "ASSIST-1"))
        (should (< (dsh-test--history-text-pos "HUMAN-2")
                   (dsh-test--history-text-pos "ASSIST-2")
                   (dsh-test--history-text-pos "ASSIST-3")
                   (dsh-test--history-text-pos "HUMAN-4")
                   (dsh-test--history-text-pos "ASSIST-4")))))))

;; A page with no round boundaries at the transcript start reports exhaustion,
;; even when a display-only inbox splice is its only rendered record.
(ert-deftest dsh-emacs-test-history-roundless-beginning-reports-exhaustion ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs--buffer-session "roundless-beginning")
    (setq dsh-emacs--history-earliest-seq 5
          dsh-emacs--history-cursor 10
          dsh-emacs--history-has-more t)
    (let (feedback)
      (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                 (lambda (_method _params callback)
                   (funcall callback
                            t
                            `((records . ,(vector
                                           (dsh-test--history-event-record
                                            "permission/preset" 0
                                            '((preset . "workspace-write")))
                                           (dsh-test--history-event-record
                                            "sandbox/mode" 1
                                            '((mode . "workspace-write")))
                                           (dsh-test--history-event-record
                                            "approval/policy" 2
                                            '((policy . "ask")))
                                           (dsh-test--history-event-record
                                            "model/selection" 3
                                            '((provider . "p")))
                                           (dsh-test--history-event-record
                                            "agent/inbox/spliced" 4
                                            '((target . "next-turn")
                                              (start . 0)
                                              (inserted . [])))))
                              (hasMore . :json-false)))))
                ((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq feedback (apply #'format format-string args)))))
        (dsh-emacs-load-older-history)
        (should (equal feedback "Beginning of history"))
        (should (= dsh-emacs--history-earliest-seq 0))
        (should-not dsh-emacs--history-has-more)))))

;; Cancellation and errors never advance the cursor or publish staged pages.
(ert-deftest dsh-emacs-test-history-history-round-case-keeps-frontier ()
  :tags '(dsh-unit)
  (dolist (finish '(cancel failure stalled changed))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "round-cancel")
      (setq dsh-emacs--history-earliest-seq 90
            dsh-emacs--history-cursor 95 dsh-emacs--history-has-more t)
      (let ((before (buffer-string)) callbacks request feedback)
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method _params callback)
                     (setq callbacks (append callbacks (list callback)))))
                  ((symbol-function 'message)
                   (lambda (format-string &rest args)
                     (setq feedback (apply #'format format-string args)))))
          (dsh-emacs-load-older-history)
          (setq request dsh-emacs--history-loading)
          (funcall (pop callbacks) t
                   `((records . ,(vector (dsh-test--history-fixture "user/message" 80 "STAGED")))
                     (hasMore . t)))
          (pcase finish
            ('cancel (dsh-emacs-load-older-history))
            ('changed (setq dsh-emacs--history-earliest-seq 70)))
          (funcall (pop callbacks) (not (eq finish 'failure))
                   (if (eq finish 'stalled)
                       `((records . ,(vector (dsh-test--history-fixture "user/message" 80 "DUPLICATE")))
                         (hasMore . t))
                     '((records . []) (hasMore . :json-false))))
          (ert-info ((format "%s" (format "history-round-%s-keeps-frontier" finish)))
            (should (null dsh-emacs--history-loading))
            (should (null (marker-buffer (plist-get request :point))))
            (should (= dsh-emacs--history-earliest-seq (if (eq finish 'changed) 70 90)))
            (should (equal-including-properties before (buffer-string)))
            (should (string-match-p (if (eq finish 'cancel) "canceled" "Could not load") feedback))))))))

;; Automatic summaries are inspectable transcript events, not user messages or
;; proof that checkpoint application succeeded.  Counts describe old context.
(ert-deftest dsh-emacs-test-history-compaction-summary-decodes-text-and-actual-item-count ()
  :tags '(dsh-unit)
  (let* ((event
          '(("type" . "compaction/summary") ("seq" . 11)
            ("data" . (("compactionId" . "auto")
                       ("summary" . [(("type" . "text")
                                      ("text" . "## Retained notes\n"))
                                     (("type" . "reasoning")
                                      ("text" . "HIDDEN REASONING"))
                                     (("type" . "text")
                                      ("text" . "Keep the API stable."))])
                       ("rawOutput" . [(("type" . "text")
                                        ("text" . "HIDDEN RAW OUTPUT"))])
                       ("shadowedRange" . (("start" . 40) ("end" . 21)))
                       ("shadowedSeqs" . [40 3 21])
                       ("shadowedTokenCount" . 42000)))))
         (summary (dsh-protocol-compaction-summary--from-alist event)))
    (ert-info ((format "%s" "compaction-summary-decodes-text-and-actual-item-count"))
      (should (= (dsh-protocol-compaction-summary-seq summary) 11))
      (should (equal (dsh-protocol-compaction-summary-id summary) "auto"))
      (should (null (dsh-protocol-compaction-summary-command-id summary)))
      (should (equal (dsh-protocol-compaction-summary-text summary)
                     "## Retained notes\nKeep the API stable."))
      (should (= (dsh-protocol-compaction-summary-item-count summary) 3))
      (should (= (dsh-protocol-compaction-summary-token-count summary) 42000)))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "compaction-render")
      (dsh-emacs-render-event
       '((type . "user/message") (seq . 1)
         (data . ((content . [((type . "text") (text . "Original conversation"))])))))
      (dsh-emacs-render-event
       '((type . "compaction/start") (seq . 10)
         (data . ((compactionId . "auto") (turn . 1)))))
      (dsh-emacs-events--dispatch-event (current-buffer) event)
      (let* ((ns (dsh-emacs-render--make-namespace))
             (block (dsh-emacs-ui-find-block ns "compaction-summary-auto"))
             (state (and block (get-text-property (car block) 'dsh-emacs-ui-state))))
        (ert-info ((format "%s" "compaction-summary-folded-without-ending-live-status"))
          (should (= dsh-emacs--anchor-seq 11))
          (should (equal (dsh-protocol-execution-event-id dsh-emacs--modeline-compaction)
                         "auto"))
          (should (string-match-p "Original conversation" (buffer-string)))
          (should (string-match-p "Automatic compaction" (buffer-string)))
          (should (string-match-p "3 history items · ~42k tokens" (buffer-string)))
          (should (eq (map-elt state :status) 'compaction-summary))
          (should (null (map-elt state :header-face)))
          (should (map-elt state :collapsed))
          (should (not (string-match-p "Keep the API stable" (buffer-string)))))
        (goto-char (car block))
        (dsh-emacs-ui-toggle-fragment)
        (dsh-emacs-render-event event)
        (ert-info ((format "%s" "compaction-summary-expand-and-replay-preserve-one-row"))
          (should (= (how-many "Automatic compaction" (point-min) (point-max)) 1))
          (should (string-match-p "Keep the API stable" (buffer-string)))
          (should (not (string-match-p "HIDDEN" (buffer-string)))))
        (dsh-emacs-render-event
         '((type . "compaction/end") (seq . 12)
           (data . ((compactionId . "auto") (turn . 1)
                    (error . "Checkpoint could not be applied")))))
        (ert-info ((format "%s" "compaction-summary-keeps-later-application-failure"))
          (should (null dsh-emacs--modeline-compaction))
          (should (string-match-p "Automatic compaction" (buffer-string)))
          (should (string-match-p "Checkpoint could not be applied" (buffer-string))))))
    (with-temp-buffer
      (dsh-emacs-mode)
      (let ((dsh-emacs--history-page t))
        (dsh-emacs-render-history-events (list (list (cons 'event event))) nil 20))
      (ert-info ((format "%s" "compaction-summary-only-history-page-renders-without-status"))
        (should (string-match-p "Automatic compaction" (buffer-string)))
        (should (null dsh-emacs--modeline-compaction))
        (should (not dsh-emacs--ml-busy))))))

(ert-deftest dsh-emacs-test-history-compaction-manual-summary-uses-command-card ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (ert-info ((format "%s" "compaction-manual-summary-uses-command-card"))
      (should (= (dsh-emacs-render-event
                  '((type . "compaction/summary") (seq . 2)
                    (data . ((compactionId . "manual") (sourceCommandId . "cmd")
                             (summary . [((type . "text") (text . "Manual summary"))])))))
                 2))
      (should (not (string-match-p "Automatic compaction\\|Manual summary" (buffer-string)))))
    (dsh-emacs-render-event
     '((type . "compaction/summary") (seq . 3)
       (data . ((compactionId . "partial") (summary . [])))))
    (let* ((block (dsh-emacs-ui-find-block (dsh-emacs-render--make-namespace)
                                           "compaction-summary-partial"))
           (state (and block (get-text-property (car block) 'dsh-emacs-ui-state))))
      (ert-info ((format "%s" "compaction-summary-unknown-counts-stay-unknown"))
        (should block)
        (should (map-elt state :non-foldable))
        (should (null (map-elt state :body)))
        (should (null (map-elt state :label-right)))))))

(provide 'dsh-test-history)
;;; dsh-test-history.el ends here
