;;; dsh-test-jobs.el --- Jobs tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)

;;; --- Test 64: the job namespace (roster stream, output, kill) ---
;;
;; dsh 0.1.7 deleted the `session/control' `jobs' record, so the roster lives
;; only on the `job' namespace's own streams.  These cover the client's
;; plumbing for them: the generalized chat-socket stream router, the roster
;; mirror, the mode-line indicator, and the two-press kill confirmation.

;; The generic stream router must send a registered stream's frames to its
;; own handler and retire that handler on the server's `end` — while the
;; follow stream on the same socket keeps its frames.
(ert-deftest dsh-emacs-test-jobs-job-stream-routed-to-handler ()
  :tags '(dsh-unit)
  (let* ((proc (make-pipe-process :name "t-jobs-router" :buffer nil))
         (job-seen nil)
         (job-torn nil))
    (unwind-protect
        (progn
          (process-put proc 'dsh-emacs-follow-stream-id "follow-1")
          (process-put proc 'dsh-emacs-chat-buffer nil)
          (process-put proc 'dsh-emacs-stream-handlers
                       (list (cons "jobs-1"
                                   (cons "job/list"
                                         (lambda (value)
                                           (if value
                                               (setq job-seen value)
                                             (setq job-torn t)))))))
          (dsh-emacs-events--dispatch-json
           proc (concat "{\"type\":\"item\",\"streamId\":\"jobs-1\","
                        "\"value\":{\"type\":\"rows\",\"jobs\":[]}}"))
          (ert-info ((format "%s" "job-stream-routed-to-handler"))
            (should (equal "rows" (dsh-protocol--field "type" job-seen))))
          (setq job-seen nil)
          (dsh-emacs-events--dispatch-json
           proc (concat "{\"type\":\"item\",\"streamId\":\"follow-1\","
                        "\"value\":{\"type\":\"snapshot\"}}"))
          (ert-info ((format "%s" "follow-frame-not-sent-to-job"))
            (should (null job-seen)))
          (dsh-emacs-events--dispatch-json
           proc "{\"type\":\"end\",\"streamId\":\"jobs-1\"}")
          (ert-info ((format "%s" "stream-end-retires-handler"))
            (should (and job-torn
                         (null (assoc "jobs-1"
                                      (process-get proc 'dsh-emacs-stream-handlers)))))))
      (delete-process proc))))

;; A stream id nobody registered must not signal (the server can send a
;; frame for a stream this client already dropped).
(ert-deftest dsh-emacs-test-jobs-unknown-stream-frame-dropped ()
  :tags '(dsh-unit)
  (let ((proc (make-pipe-process :name "t-jobs-unknown" :buffer nil)))
    (unwind-protect
        (should-not
         (dsh-emacs-events--dispatch-json
          proc "{\"type\":\"item\",\"streamId\":\"gone\",\"value\":{}}"))
      (delete-process proc))))

;; Opening a stream registers its handler on the process and sends one `open'
;; frame carrying that same id, so the host can address its frames back to it;
;; a dead process yields no stream id rather than a subscription that can
;; never receive anything.
(ert-deftest dsh-emacs-test-jobs-open-stream-registers-its-id ()
  :tags '(dsh-unit)
  (let ((proc (make-pipe-process :name "t-jobs-open" :buffer nil))
        (sent nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'dsh-emacs-events--frame)
                     (lambda (_opcode payload) payload))
                    ((symbol-function 'process-send-string)
                     (lambda (_process payload)
                       (setq sent (json-read-from-string payload)))))
            (let ((id (dsh-emacs-events-open-stream
                       proc "job/list" '((request . ((sessionId . "s1"))))
                       "job/list" (lambda (_v) nil))))
              (ert-info ((format "%s" "open-stream-registers-its-id"))
                (should (and (stringp id)
                             (equal id (caar (process-get
                                              proc 'dsh-emacs-stream-handlers))))))
              (ert-info ((format "%s" "open-stream-sends-open-frame"))
                (should (and sent
                             (equal "open" (dsh-protocol--field "type" sent))
                             (equal "job/list"
                                    (dsh-protocol--field "endpoint" sent))
                             (equal id (dsh-protocol--field "streamId" sent))))))
            (ert-info ((format "%s" "open-stream-refuses-dead-process"))
              (should (null (dsh-emacs-events-open-stream
                             nil "job/list" nil "job/list" (lambda (_v) nil)))))))
      (delete-process proc))))

;; The open message must be the documented duplex envelope: endpoint at the
;; top level, args under `payload` with the request wrapper `job/list` wants.
(ert-deftest dsh-emacs-test-jobs-job-open-is-open-frame ()
  :tags '(dsh-unit)
  (let* ((json (dsh-protocol-mux-open-json
                "s1" "job/list" '((request . ((sessionId . "sess-1"))))))
         (msg (json-read-from-string json))
         (payload (dsh-protocol--field "payload" msg))
         (args (dsh-protocol--field "args" payload))
         (request (dsh-protocol--field "request" args)))
    (ert-info ((format "%s" "job-open-is-open-frame"))
      (should (equal "open" (dsh-protocol--field "type" msg))))
    (ert-info ((format "%s" "job-open-carries-endpoint"))
      (should (equal "job/list" (dsh-protocol--field "endpoint" msg))))
    (ert-info ((format "%s" "job-open-wraps-request-args"))
      (should (equal "sess-1" (dsh-protocol--field "sessionId" request))))))

;; A roster frame replaces the previous set wholesale (the host's frame is
;; the authoritative whole set), so a job that left the frame leaves the
;; mirror — the same last-writer-wins contract the queue mirror has.
(ert-deftest dsh-emacs-test-jobs-job-roster-first-frame-has-two ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *dsh-test-jobs-chat*"))
         (old-roster dsh-emacs-jobs--roster))
    (unwind-protect
        (progn
          (dsh-emacs-jobs--apply
           chat (dsh-protocol-job-list--from-alist
                 (json-read-from-string
                  (concat "{\"type\":\"rows\",\"jobs\":["
                          "{\"id\":\"bash-1\",\"kind\":\"bash\","
                          "\"status\":\"running\"},"
                          "{\"id\":\"bash-2\",\"kind\":\"bash\","
                          "\"status\":\"running\"}]}"))))
          (let ((first (length (buffer-local-value 'dsh-emacs-jobs--roster chat))))
            (dsh-emacs-jobs--apply
             chat (dsh-protocol-job-list--from-alist
                   (json-read-from-string
                    (concat "{\"type\":\"rows\",\"jobs\":["
                            "{\"id\":\"bash-2\",\"kind\":\"bash\","
                            "\"status\":\"completed\"}]}"))))
            (ert-info ((format "%s" "job-roster-first-frame-has-two"))
              (should (= first 2)))
            (with-current-buffer chat
              (ert-info ((format "%s" "job-roster-replaced-wholesale"))
                (should (and (= (length dsh-emacs-jobs--roster) 1)
                             (equal "bash-2" (dsh-protocol-job-id
                                              (car dsh-emacs-jobs--roster))))))
              (ert-info ((format "%s" "job-counts-split-live-settled"))
                (should (equal (dsh-emacs-jobs-counts) '(0 . 1)))))))
      (setq dsh-emacs-jobs--roster old-roster)
      (kill-buffer chat))))

;; The stop control is two-press: the first press only arms it, the second
;; kills.  This is dsh web's armed-stop semantics, and it is what keeps a
;; single stray `k' from killing the model's background work.
(ert-deftest dsh-emacs-test-jobs-job-kill-first-press-arms ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *dsh-test-jobs-kill*"))
         (job (dsh-protocol-job--from-alist
               (json-read-from-string
                (concat "{\"id\":\"bash-9\",\"kind\":\"bash\","
                        "\"status\":\"running\"}"))))
         (killed nil))
    (unwind-protect
        (with-current-buffer chat
          (cl-letf (((symbol-function 'dsh-emacs-jobs-kill)
                     (lambda (j) (setq killed (dsh-protocol-job-id j)))))
            (dsh-emacs-jobs--request-kill job)
            (ert-info ((format "%s" "job-kill-first-press-arms"))
              (should (and (equal dsh-emacs-jobs--kill-armed "bash-9")
                           (null killed))))
            (dsh-emacs-jobs--request-kill job)
            (ert-info ((format "%s" "job-kill-second-press-kills"))
              (should (equal killed "bash-9")))
            (ert-info ((format "%s" "job-kill-disarms-after-kill"))
              (should (null dsh-emacs-jobs--kill-armed)))))
      (with-current-buffer chat (dsh-emacs-jobs--disarm))
      (kill-buffer chat))))

;; A stream teardown leaves the roster as last seen, so a reconnect (whose
;; first frame is the whole truth) does not empty the job chooser.
(ert-deftest dsh-emacs-test-jobs-job-roster-survives-teardown ()
  :tags '(dsh-unit)
  (let ((kept (dsh-protocol-job-list--from-alist
               (json-read-from-string
                (concat "{\"type\":\"rows\",\"jobs\":["
                        "{\"id\":\"b1\",\"status\":\"running\"}]}")))))
    (dsh-emacs-jobs--apply (current-buffer) kept)
    (funcall (dsh-emacs-jobs--roster-handler (current-buffer)) nil)
    (ert-info ((format "%s" "job-roster-survives-teardown"))
      (should (= (length dsh-emacs-jobs--roster) 1)))
    (setq dsh-emacs-jobs--roster nil)))

;; The output buffer appends stream chunks and rewrites its header from the
;; `status` frame; a `lossy` batch announces the eviction instead of
;; silently dropping bytes.
(ert-deftest dsh-emacs-test-jobs-job-output-appends-chunks ()
  :tags '(dsh-unit)
  (let* ((job (dsh-protocol-job--from-alist
               (json-read-from-string
                (concat "{\"id\":\"bash-7\",\"kind\":\"bash\",\"label\":\"make\","
                        "\"status\":\"running\",\"startedAt\":1700000000000,"
                        "\"output\":{\"total\":0,\"earliest\":0}}"))))
         (buf (get-buffer-create " *dsh-test-job-out*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-jobs-output-mode)
          (let ((inhibit-read-only t)) (erase-buffer))
          (funcall (dsh-emacs-jobs--output-item buf)
                   (json-read-from-string
                    (concat "{\"type\":\"output\",\"next\":5,"
                            "\"chunks\":[{\"at\":0,\"text\":\"hello \","
                            "\"channel\":\"stdout\"},"
                            "{\"at\":6,\"text\":\"world\\n\","
                            "\"channel\":\"stderr\"}]}")))
          (ert-info ((format "%s" "job-output-appends-chunks"))
            (should (equal (buffer-string) "hello world\n")))
          (funcall (dsh-emacs-jobs--output-item buf)
                   (json-read-from-string
                    "{\"type\":\"output\",\"next\":9,\"lossy\":true,\"chunks\":[]}"))
          (ert-info ((format "%s" "job-output-marks-lossy-batch"))
            (should (string-match-p "reclaimed by the host" (buffer-string))))
          ;; A `gapBefore` chunk is the per-chunk loss marker the host sends when
          ;; bytes vanished at the producer or to retention: the notice must sit
          ;; immediately before that chunk's text, and the text must still land.
          (let ((gap-buf (generate-new-buffer " *dsh-test-gap*")))
            (unwind-protect
                (with-current-buffer gap-buf
                  (funcall (dsh-emacs-jobs--output-item gap-buf)
                           (json-read-from-string
                            (concat "{\"type\":\"output\",\"next\":19,"
                                    "\"chunks\":[{\"at\":15,\"text\":\"tail-here\","
                                    "\"channel\":\"stdout\",\"gapBefore\":true}]}")))
                  (ert-info ((format "%s" "job-output-marks-gap-before-chunk"))
                    (should (equal (buffer-string)
                                   "\n[dsh] output gap\ntail-here"))))
              (kill-buffer gap-buf)))
          (funcall (dsh-emacs-jobs--output-item buf)
                   (json-read-from-string
                    (concat "{\"type\":\"status\",\"job\":{\"id\":\"bash-7\","
                            "\"kind\":\"bash\",\"label\":\"make\","
                            "\"status\":\"completed\",\"detail\":\"exit code: 0\","
                            "\"output\":{}}}")))
          (ert-info ((format "%s" "job-output-header-follows-status"))
            (should (string-match-p "(done)" header-line-format))))
      (kill-buffer buf))))

;; A `%` in a job label must be doubled for the header line, which undergoes
;; `%`-sequence expansion — otherwise "50% done" renders as something else.
(ert-deftest dsh-emacs-test-jobs-job-header-escapes-percent ()
  :tags '(dsh-unit)
  (let ((text (dsh-emacs-jobs--header
               (dsh-protocol-job--from-alist
                (json-read-from-string
                 (concat "{\"id\":\"b\",\"kind\":\"bash\",\"label\":\"50% done\","
                         "\"status\":\"running\"}"))))))
    (ert-info ((format "%s" "job-header-escapes-percent"))
      (should (string-match-p "50%% done" text)))))

;; A settled job carries `startedAt` and `finishedAt` in the same epoch-ms
;; unit, so a 65s span must read `1m05s` — not a millisecond/second mix, which
;; lands in the millions of hours (the row the roster showed as
;; "496790621h40m" for a job that had just finished).
(ert-deftest dsh-emacs-test-jobs-job-elapsed-settled-span ()
  :tags '(dsh-unit)
  (let ((job (dsh-protocol-job--from-alist
              (json-read-from-string
               (concat "{\"id\":\"bash-8\",\"kind\":\"bash\",\"label\":\"verify.sh\","
                       "\"status\":\"completed\",\"startedAt\":1790236855396,"
                       "\"finishedAt\":1790236920396}")))))
    (ert-info ((format "%s" "job-elapsed-settled-span"))
      (should (equal (dsh-emacs-jobs--elapsed job) "1m05s")))))

;; Appending follows the tail only for a reader who is at the tail; a reader
;; parked mid-text keeps that position (`insert' at `point-max' never moves
;; point by itself, so the old "not displayed => jump to end" branch threw the
;; reading position away).
(ert-deftest dsh-emacs-test-jobs-job-append-follows-tail-at-tail ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *dsh-test-job-append-pos*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-jobs-output-mode)
          (let ((inhibit-read-only t)) (insert "one\ntwo\nthree\n"))
          (goto-char (point-max))
          (dsh-emacs-jobs--append buf "four\n")
          (ert-info ((format "%s" "job-append-follows-tail-at-tail"))
            (should (= (point) (point-max))))
          (goto-char 2)
          (dsh-emacs-jobs--append buf "five\n")
          (ert-info ((format "%s" "job-append-keeps-scrolled-back-point"))
            (should (= (point) 2))))
      (kill-buffer buf))))

;; The menu's `k' is the only place the two-press stop runs, so the arming
;; press must NOT close the menu: the confirming press is a second `k' on the
;; same menu, and exiting on the armed press leaves the user no way to reach
;; the confirmation inside the arm window.  The menu is exercised through its
;; command with the minibuffer boundary stubbed, since batch has no recursive
;; minibuffer edit to exit.
(ert-deftest dsh-emacs-test-jobs-job-menu-kill-arm-keeps-menu-open ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *dsh-test-job-menu-kill*"))
         (job (dsh-protocol-job--from-alist
               (json-read-from-string
                (concat "{\"id\":\"bash-11\",\"kind\":\"bash\","
                        "\"label\":\"verify.sh\",\"status\":\"running\"}"))))
         (exits 0)
         (killed nil))
    (unwind-protect
        (with-current-buffer chat
          (cl-letf (((symbol-function 'dsh-emacs-jobs--menu-chat) (lambda () chat))
                    ((symbol-function 'dsh-emacs-jobs--menu-item) (lambda () job))
                    ((symbol-function 'exit-minibuffer) (lambda () (setq exits (1+ exits))))
                    ((symbol-function 'dsh-emacs-jobs-kill)
                     (lambda (j) (setq killed (dsh-protocol-job-id j)))))
            (dsh-emacs-jobs--menu-kill)
            (ert-info ((format "%s" "job-menu-kill-arm-keeps-menu-open"))
              (should (and (equal dsh-emacs-jobs--kill-armed "bash-11")
                           (null killed)
                           (= exits 0))))
            (dsh-emacs-jobs--menu-kill)
            (ert-info ((format "%s" "job-menu-kill-second-press-kills"))
              (should (and (equal killed "bash-11") (= exits 1))))
            (ert-info ((format "%s" "job-menu-kill-disarms-after-confirm"))
              (should (null dsh-emacs-jobs--kill-armed)))))
      (with-current-buffer chat (dsh-emacs-jobs--disarm))
      (kill-buffer chat))))

;; `q' in an output buffer must cancel that buffer's subscription (the host
;; keeps the ring, so re-opening re-reads it) while leaving the text in place
;; for the user to keep reading.
(ert-deftest dsh-emacs-test-jobs-job-output-quit-cancels-stream ()
  :tags '(dsh-unit)
  (let* ((buf (get-buffer-create " *dsh-test-job-quit*"))
         (chat (get-buffer-create " *dsh-test-job-quit-chat*"))
         (proc (make-pipe-process :name "t-jobs-quit" :buffer nil))
         (cancelled nil))
    (unwind-protect
        (progn
          ;; The socket lives on the CHAT buffer, not on the output buffer: the
          ;; output buffer follows the job but has no connection of its own, so
          ;; reading a process here must find the chat's.
          (with-current-buffer chat
            (setq-local dsh-emacs--event-process proc))
          (with-current-buffer buf
            (dsh-emacs-jobs-output-mode)
            (let ((inhibit-read-only t)) (insert "kept text"))
            (setq dsh-emacs-jobs--popup-stream "job-1")
            (setq dsh-emacs-jobs--popup-chat chat)
            (cl-letf (((symbol-function 'dsh-emacs-events-close-stream)
                       (lambda (_process stream) (setq cancelled stream)))
                      ((symbol-function 'quit-window) (lambda (&optional _) nil)))
              (dsh-emacs-jobs--quit))
            (ert-info ((format "%s" "job-output-quit-cancels-stream"))
              (should (equal cancelled "job-1")))
            (ert-info ((format "%s" "job-output-quit-keeps-text"))
              (should (and (null dsh-emacs-jobs--popup-stream)
                           (equal (buffer-string) "kept text"))))))
      (delete-process proc)
      (kill-buffer buf)
      (kill-buffer chat))))

;; `q' cancels through the chat buffer's live process, and a chat that is
;; already gone (or whose socket died) still clears the local stream id
;; rather than erroring — the buffer must stay readable either way.
(ert-deftest dsh-emacs-test-jobs-job-output-quit-without-chat ()
  :tags '(dsh-unit)
  (let* ((buf (get-buffer-create " *dsh-test-job-quit-dead*"))
         (chat (get-buffer-create " *dsh-test-job-quit-dead-chat*"))
         (called nil))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-jobs-output-mode)
          (setq dsh-emacs-jobs--popup-stream "job-2")
          (setq dsh-emacs-jobs--popup-chat nil)
          (cl-letf (((symbol-function 'dsh-emacs-events-close-stream)
                     (lambda (&rest _) (setq called t)))
                    ((symbol-function 'quit-window) (lambda (&optional _) nil)))
            (dsh-emacs-jobs--quit))
          (ert-info ((format "%s" "job-output-quit-without-chat"))
            (should (and (null called) (null dsh-emacs-jobs--popup-stream)))))
      (kill-buffer buf)
      (kill-buffer chat))))

;; Menu labels must stay unique even when a job's description already looks
;; like a generated suffix: descriptions "same", "same", "same [2]" used to
;; yield two identical "[bash] (run) same [2]" labels, so a label lookup
;; could act on the second job instead of the third — a stop could hit the
;; wrong one.
(ert-deftest dsh-emacs-test-jobs-job-menu-labels-stay-unique-on-suffix-collision ()
  :tags '(dsh-unit)
  (let* ((jobs (mapcar
                (lambda (spec)
                  (dsh-protocol-job--from-alist
                   (json-read-from-string
                    (format (concat "{\"id\":\"%s\",\"kind\":\"bash\","
                                    "\"label\":\"%s\",\"status\":\"running\"}")
                            (nth 0 spec) (nth 1 spec)))))
                '(("job-1" "same") ("job-2" "same") ("job-3" "same [2]"))))
         (table (dsh-emacs-jobs--table jobs))
         (labels (mapcar #'car table)))
    (ert-info ((format "%s" "job-menu-labels-are-unique"))
      (should (= (length labels)
                 (length (delete-dups (copy-sequence labels))))))
    (ert-info ((format "%s" "job-menu-label-resolves-to-its-own-job"))
      (should (equal '("job-1" "job-2" "job-3")
                     (mapcar (lambda (entry)
                               (dsh-protocol-job-id
                                (cdr (assoc (car entry) table))))
                             table))))
    (ert-info ((format "%s" "job-menu-third-label-maps-to-third-job"))
      (should (equal "job-3"
                     (dsh-protocol-job-id
                      (cdr (assoc (nth 2 labels) table))))))))

;; Killing an output buffer directly (C-x k) must retire its `job/follow'
;; subscription too: only `q' cancelled it, so a direct `kill-buffer' left
;; the handler registered on the chat buffer's socket until the job settled
;; or the connection dropped.
(ert-deftest dsh-emacs-test-jobs-job-output-kill-buffer-cancels-stream ()
  :tags '(dsh-unit)
  (let* ((buf (get-buffer-create " *dsh-test-job-kill*"))
         (chat (get-buffer-create " *dsh-test-job-kill-chat*"))
         (proc (make-pipe-process :name "t-jobs-kill-buffer" :buffer nil))
         (closed nil)
         (stream-after-cleanup 'unset))
    (unwind-protect
        (progn
          ;; The socket lives on the CHAT buffer (as in the `q' test): the
          ;; output buffer follows the job but owns no connection.
          (with-current-buffer chat
            (setq-local dsh-emacs--event-process proc))
          (with-current-buffer buf
            (dsh-emacs-jobs-output-mode)
            (setq dsh-emacs-jobs--popup-chat chat)
            (setq dsh-emacs-jobs--popup-stream "job-kill-1")
            ;; Appended at depth 100 so it runs after the mode's own cleanup
            ;; hook and can observe the stream id that cleanup left behind.
            (add-hook 'kill-buffer-hook
                      (lambda ()
                        (setq stream-after-cleanup
                              dsh-emacs-jobs--popup-stream))
                      100 t)
            (cl-letf (((symbol-function 'dsh-emacs-events-close-stream)
                       (lambda (process stream)
                         (setq closed (cons process stream)))))
              (kill-buffer buf)))
          (ert-info ((format "%s" "job-output-kill-buffer-cancels-stream"))
            (should (equal closed (cons proc "job-kill-1"))))
          (ert-info ((format "%s" "job-output-kill-buffer-clears-stream-id"))
            (should (null stream-after-cleanup))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (delete-process proc)
      (when (buffer-live-p chat) (kill-buffer chat)))))

(provide 'dsh-test-jobs)
;;; dsh-test-jobs.el ends here
