;;; dsh-test-workspace.el --- Workspace tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)

(defvar ivy-mode)

;; --- Test 51g: opening a warm list costs no RPC; a cold one fetches ---
;; The list is kept live by the core `$events' stream and by the cache
;; updates session creation already does, so re-opening it must not fetch
;; `session/list' (nor re-baseline workspaces).
(ert-deftest dsh-emacs-test-workspace-warm-open-costs-no-rpc ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--sessions-buffer (generate-new-buffer-name " *dsh-workspace-test*"))
        (dsh-emacs--sessions nil)
        (calls 0)
        (dsh-emacs--current-session "warm")
        (dsh-emacs--workspaces nil)
        (dsh-emacs--archived-sessions nil))
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (&rest _) (setq calls (1+ calls))))
                  ((symbol-function 'dsh-emacs-server-start)
                   (lambda (&optional _) t))
                  ((symbol-function 'dsh-emacs-events-host-connect) #'ignore)
                  ((symbol-function 'dsh-emacs-events-host-disconnect) #'ignore)
                  ((symbol-function 'dsh-emacs-events--host-refresh-begin)
                   #'ignore))
          ;; warm cache: a row is already known
          (let ((dsh-emacs--sessions
                 (dsh-emacs-test--session-items
                  (list (list (cons 'sessionId "warm") (cons 'updatedAt 10)
                              (cons 'cwd "/tmp/ws-a")
                              (cons 'projections
                                    (list (cons 'values
                                                (list (cons 'title "Warm"))))))))))
            (dsh-emacs-list-sessions-display)
            (ert-info ((format "%s" "warm-open-costs-no-rpc"))
              (should (zerop calls)))
            (ert-info ((format "%s" "warm-open-renders-and-jumps"))
              (should (with-current-buffer dsh-emacs--sessions-buffer
                        (equal "warm" (dsh-emacs-session-id-at-point))))))
          ;; cold cache: nothing to show, so it fetches
          (setq calls 0
                dsh-emacs--sessions nil)
          (dsh-emacs-list-sessions-display)
          (ert-info ((format "%s" "cold-open-fetches"))
            (should (= 1 calls))))
      (when (get-buffer dsh-emacs--sessions-buffer)
        (kill-buffer dsh-emacs--sessions-buffer)))))

;; C-c C-l belongs to the invoking chat even when another chat was opened
;; more recently.  Exercise the keymap and real window switch, including a
;; cold cache whose rows arrive after the command returns.
(ert-deftest dsh-emacs-test-workspace-chat-list-cold-jump-keeps-caller-target ()
  :tags '(dsh-unit)
  (dolist (cold '(nil t))
    (let* ((dsh-emacs--sessions-buffer
            (generate-new-buffer-name " *dsh-chat-list-jump*"))
           (dsh-emacs--current-session "last-opened")
           (dsh-emacs--workspaces nil)
           (dsh-emacs--archived-sessions nil)
           (sessions
            (dsh-emacs-test--session-items
             '(((sessionId . "last-opened") (updatedAt . 20)
                (projections (values (title . "Last opened"))))
               ((sessionId . "invoking-chat") (updatedAt . 10)
                (projections (values (title . "Invoking chat")))))))
           (dsh-emacs--sessions (unless cold sessions)))
      (unwind-protect
          (save-window-excursion
            (cl-letf (((symbol-function 'dsh-emacs-events-host-connect) #'ignore)
                      ((symbol-function 'dsh-emacs-events-host-disconnect) #'ignore)
                      ((symbol-function 'dsh-emacs-list-sessions) #'ignore))
              (with-temp-buffer
                (dsh-emacs-mode)
                (setq-local dsh-emacs--buffer-session "invoking-chat")
                (switch-to-buffer (current-buffer))
                (execute-kbd-macro (kbd "C-c C-l"))
                (with-current-buffer dsh-emacs--sessions-buffer
                  (when cold
                    (ert-info ((format "%s" "chat-list-cold-jump-keeps-caller-target"))
                      (should (equal dsh-emacs-session--auto-jump-session "invoking-chat")))
                    (setq dsh-emacs--sessions sessions)
                    (dsh-emacs-session--render))
                  (ert-info ((format "%s" (format "chat-list-jumps-to-caller-cold-%s" cold)))
                    (should (eq (window-buffer) (current-buffer)))
                    (should (equal (dsh-emacs-session-id-at-point) "invoking-chat"))
                    (should (null dsh-emacs-session--auto-jump-session)))
                  (dsh-emacs-session--render)
                  (ert-info ((format "%s" (format "chat-list-refresh-keeps-caller-cold-%s" cold)))
                    (should (equal (dsh-emacs-session-id-at-point) "invoking-chat")))))))
        (when (get-buffer dsh-emacs--sessions-buffer)
          (kill-buffer dsh-emacs--sessions-buffer))))))

;; Project entry captures the caller's directory before displaying the list.
(ert-deftest dsh-emacs-test-workspace-project-entry-captures-caller-directory ()
  :tags '(dsh-unit)
  (let ((seen nil)
        (detected nil)
        (dsh-emacs-base-url "http://127.0.0.1:3000"))
    (cl-letf (((symbol-function 'dsh-emacs-list-sessions-display)
               (lambda (&optional root) (setq seen root)))
              ((symbol-function 'dsh-emacs--project-root)
               (lambda (dir) (setq detected dir) "/tmp/project")))
      (with-temp-buffer
        (setq default-directory "/tmp/project/src/")
        (dsh-emacs)
        (ert-info ((format "%s" "project-entry-captures-caller-directory"))
          (should (equal seen "/tmp/project"))
          (should (equal detected "/tmp/project/src/")))
        (dolist (mode '(dsh-emacs-mode dsh-emacs-session-mode))
          (setq major-mode mode detected nil)
          (dsh-emacs)
          (ert-info ((format "%s" (format "project-entry-preserves-%s-navigation" mode)))
            (should (null seen))
            (should (null detected))))
        (setq major-mode 'fundamental-mode detected nil)
        (let ((dsh-emacs-base-url "https://remote.example"))
          (dsh-emacs)
          (ert-info ((format "%s" "project-entry-skips-remote-server"))
            (should (null seen))
            (should (null detected))))
        (setq default-directory "/ssh:example:/project/")
        (dsh-emacs)
        (ert-info ((format "%s" "project-entry-skips-remote-directory"))
          (should (null seen))
          (should (null detected)))))))

;; Use the real entry, renderer and canonical matcher with a cold workspace
;; cache, then deliver its data through the ordinary repaint path.
(ert-deftest dsh-emacs-test-workspace-project-entry-missing-workspace-keeps-session ()
  :tags '(dsh-unit)
  (let* ((root (make-temp-file "dsh-entry-project-" t))
         (dsh-emacs--sessions-buffer " *dsh-project-entry*")
         (dsh-emacs-base-url "http://127.0.0.1:3000")
         (dsh-emacs--current-session "previous")
         (dsh-emacs--archived-sessions nil)
         (dsh-emacs--workspaces nil)
         (dsh-emacs--sessions
          (dsh-emacs-test--session-items
           '(((sessionId . "previous") (updatedAt . 1)
              (projections . ((values . ((title . "Previous session"))))))))))
    (unwind-protect
        (save-window-excursion
          (make-directory (expand-file-name ".git" root))
          (make-directory (expand-file-name "src" root))
          (cl-letf (((symbol-function 'dsh-emacs-events-host-connect) #'ignore)
                    ((symbol-function 'dsh-emacs-events-host-disconnect) #'ignore)
                    ((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (&rest _) (error "Unexpected entry RPC")))
                    ((symbol-function 'dsh-emacs--rpc-request)
                     (lambda (&rest _) (error "Unexpected workspace creation"))))
            (with-temp-buffer
              (setq default-directory (file-name-as-directory
                                       (expand-file-name "src" root)))
              (dsh-emacs))
            (with-current-buffer dsh-emacs--sessions-buffer
              (ert-info ((format "%s" "project-entry-missing-workspace-keeps-session"))
                (should (equal "previous" (dsh-emacs-session-id-at-point))))
              (ert-info ((format "%s" "project-entry-retains-root-until-workspace-arrives"))
                (should (equal root dsh-emacs-session--auto-jump-project)))
              (setq dsh-emacs--workspaces
                    (mapcar #'dsh-protocol-workspace--from-alist
                            `(((workspaceId . "other") (title . "Other")
                               (path . "/tmp/unrelated")
                               (sessionIds . ["previous"]))
                              ((workspaceId . "project") (title . "Project")
                               (path . ,(concat root "/src/../"))
                               (sessionIds . [])))))
              (setq dsh-emacs-session--workspace-fold-default t
                    dsh-emacs-session--filter-ws-id "other"
                    dsh-emacs-session--filter-ws-title "Other")
              (dsh-emacs-session--render)
              (ert-info ((format "%s" "project-entry-jumps-to-empty-workspace-header"))
                (should (equal "project" (dsh-emacs-workspace-id-at-point)))
                (should (null (dsh-emacs-session-id-at-point)))
                (should (null dsh-emacs-session--filter-ws-id))
                (should (not (dsh-emacs-session--workspace-collapsed-p "project")))
                (should (dsh-emacs-session--workspace-collapsed-p "other"))
                (should (null dsh-emacs-session--auto-jump-project)))
              (goto-char (dsh-emacs-session--row-pos
                          'dsh-emacs-workspace-group-id "other"))
              (dsh-emacs-session--render)
              (ert-info ((format "%s" "project-entry-refresh-keeps-user-focus"))
                (should (equal "other" (dsh-emacs-workspace-id-at-point)))))
            ;; A warm cache must jump immediately and override the old session.
            (with-temp-buffer
              (setq default-directory (file-name-as-directory root))
              (dsh-emacs))
            (with-current-buffer dsh-emacs--sessions-buffer
              (ert-info ((format "%s" "project-entry-warm-cache-prefers-project"))
                (should (equal "project" (dsh-emacs-workspace-id-at-point)))
                (should (null dsh-emacs-session--auto-jump-session))))
            ;; Opening without a project replaces an earlier pending target.
            (dsh-emacs-list-sessions-display "/tmp/missing-project")
            (dsh-emacs-list-sessions-display)
            (with-current-buffer dsh-emacs--sessions-buffer
              (ert-info ((format "%s" "project-entry-normal-open-clears-pending-project"))
                (should (null dsh-emacs-session--auto-jump-project))
                (should (equal "previous" (dsh-emacs-session-id-at-point)))))))
      (when (get-buffer dsh-emacs--sessions-buffer)
        (kill-buffer dsh-emacs--sessions-buffer))
      (delete-directory root t))))

;; Explicit list interaction supersedes an unfinished project/session jump.
(ert-deftest dsh-emacs-test-workspace-project-open-selects-list-before-centering ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--sessions-buffer " *dsh-project-navigation*")
         (dsh-emacs--current-session nil)
         (dsh-emacs--archived-sessions nil)
         (dsh-emacs--sessions nil)
         (workspaces
          (cl-loop for i from 1 to 60
                   collect (dsh-protocol-workspace--from-alist
                            `((workspaceId . ,(format "w%d" i))
                              (title . ,(format "Workspace %d" i))
                              (path . ,(format "/tmp/dsh-navigation-%d" i))))))
         (dsh-emacs--workspaces workspaces))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (cl-letf (((symbol-function 'dsh-emacs-events-host-connect) #'ignore)
                    ((symbol-function 'dsh-emacs-events-host-disconnect) #'ignore)
                    ((symbol-function 'dsh-emacs-list-sessions) #'ignore))
            (dsh-emacs-list-sessions-display "/tmp/dsh-navigation-45")
            (ert-info ((format "%s" "project-open-selects-list-before-centering"))
              (should (eq (window-buffer) (get-buffer dsh-emacs--sessions-buffer)))
              (should (equal "w45" (dsh-emacs-workspace-id-at-point)))
              (should (<= (abs (- (count-screen-lines (window-start) (point))
                                  (/ (window-body-height) 2))) 1)))
            ;; Anchor on a header: empty-workspace placeholders share its row
            ;; id, so the existing row restore cannot distinguish those lines.
            (set-window-start
             (selected-window)
             (dsh-emacs-session--row-pos 'dsh-emacs-workspace-group-id "w44"))
            (let ((start (window-start)))
              (dsh-emacs-session--render)
              (ert-info ((format "%s" "project-refresh-preserves-manual-viewport"))
                (should (= start (window-start)))))
            (setq dsh-emacs--workspaces nil)
            (dsh-emacs-list-sessions-display "/tmp/dsh-navigation-45")
            (setq dsh-emacs--workspaces workspaces)
            (dsh-emacs-session--render)
            (ert-info ((format "%s" "project-late-workspace-centers-selected-window"))
              (should (equal "w45" (dsh-emacs-workspace-id-at-point)))
              (should (<= (abs (- (count-screen-lines (window-start) (point))
                                  (/ (window-body-height) 2))) 1)))
            (dsh-emacs-list-sessions-display "/tmp/dsh-navigation-1")
            (ert-info ((format "%s" "project-near-start-centering-clamps"))
              (should (equal "w1" (dsh-emacs-workspace-id-at-point)))
              (should (= (window-start) (point-min))))
            ;; A second view must keep its own row and viewport.
            (let* ((target (selected-window))
                   (other (split-window-right)))
              (set-window-point other (point-min))
              (set-window-start other (point-min))
              (dsh-emacs-list-sessions-display "/tmp/dsh-navigation-35")
              (ert-info ((format "%s" "project-center-preserves-other-window"))
                (should (eq target (selected-window)))
                (should (= (window-point other) (point-min)))
                (should (= (window-start other) (point-min))))
              ;; A late result must not recenter a list in an unselected window.
              (select-window other)
              (switch-to-buffer (get-buffer-create " *dsh-project-other*"))
              (let ((recenters 0))
                (cl-letf (((symbol-function 'recenter)
                           (lambda (&rest _) (setq recenters (1+ recenters)))))
                  (with-current-buffer dsh-emacs--sessions-buffer
                    (setq dsh-emacs-session--auto-jump-project
                          "/tmp/dsh-navigation-55")
                    (dsh-emacs-session--render)))
                (ert-info ((format "%s" "project-background-result-does-not-recenter"))
                  (should (zerop recenters))
                  (should (eq other (selected-window)))))
              (select-window target)
              (delete-other-windows))
            (dolist (key '("n" "TAB"))
              (setq dsh-emacs--workspaces (list (car workspaces)))
              (dsh-emacs-list-sessions-display "/tmp/dsh-navigation-45")
              (goto-char (dsh-emacs-session--row-pos
                          'dsh-emacs-workspace-group-id "w1"))
              (setq dsh-emacs-session--auto-jump-session "missing-session")
              (execute-kbd-macro (kbd key))
              (ert-info ((format "%s" (format "project-user-%s-cancels-pending-jumps" key)))
                (should (null dsh-emacs-session--auto-jump-project))
                (should (null dsh-emacs-session--auto-jump-session)))
              (setq dsh-emacs--workspaces workspaces)
              (dsh-emacs-session--render)
              (ert-info ((format "%s" (format "project-arrival-after-%s-keeps-focus" key)))
                (should (equal "w1" (dsh-emacs-workspace-id-at-point)))))
            ;; A plain reopen has neither target and retains the current row.
            (dsh-emacs-list-sessions-display)
            (ert-info ((format "%s" "project-no-jump-open-keeps-row"))
              (should (equal "w1" (dsh-emacs-workspace-id-at-point))))))
      (dolist (name (list dsh-emacs--sessions-buffer " *dsh-project-other*"))
        (when (get-buffer name) (kill-buffer name))))))

;; 4) Non-workspace context: no workspaceId (ungrouped), only cwd
;; (automatic project attribution is covered separately in test 80b;
;; disabled here so the local repo is not detected as a project and
;; the assertions are not rewritten)
(ert-deftest dsh-emacs-test-workspace-new-session-outside-workspace-ungrouped ()
  :tags '(dsh-unit)
  (let ((calls nil)
        (buf (generate-new-buffer " *dsh-plain-create*"))
        (dsh-emacs-new-session-auto-project nil))
    (unwind-protect
        (with-current-buffer buf
          (insert "plain text\n")
          (goto-char (point-min))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t `((sessionId . ,(cdr (assq 'sessionId
                                                                (cdr (assq 'request params)))))))))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (buffer &rest _) buffer))
                    ((symbol-function 'dsh-emacs--activate-chat-buffer)
                     (lambda (sid buffer &optional _address)
                       (puthash sid buffer dsh-emacs--chat-buffers)
                       (with-current-buffer buffer
                         (setq-local dsh-emacs--buffer-session sid)
                         (dsh-emacs--chat-buffer-sync sid)
                         (dsh-emacs-mode)))))
            (call-interactively #'dsh-emacs-new-session)
            (let* ((call (car calls))
                   (params (cadr call)))
              (ert-info ((format "%s" "new-session-outside-workspace-ungrouped"))
                (should (and (string= "session/create" (car call))
                             (null (assq 'workspaceId (cdr (assq 'request params))))
                             (assq 'cwd (cdr (assq 'request params)))))))))
      (kill-buffer buf))))

;; 5) Called in a chat buffer (session): the new session belongs to
;; the workspace of the current session
(ert-deftest dsh-emacs-test-workspace-new-session-in-chat-uses-session-workspace ()
  :tags '(dsh-unit)
  (let ((calls nil)
        (buf (generate-new-buffer " *dsh-chat-create*"))
        (w1 (dsh-protocol-workspace--from-alist
             (list (cons 'workspaceId "w-here")
                   (cons 'title "Here")
                   (cons 'path "/tmp/dsh-here")
                   (cons 'sessionIds ["s-here" "s-other"])
                   (cons 'createdAt "x") (cons 'updatedAt "x")))))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "s-here")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t `((sessionId . ,(cdr (assq 'sessionId
                                                                (cdr (assq 'request params)))))))))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (buffer &rest _) buffer))
                    ((symbol-function 'dsh-emacs--activate-chat-buffer)
                     (lambda (sid buffer &optional _address)
                       (puthash sid buffer dsh-emacs--chat-buffers)
                       (with-current-buffer buffer
                         (setq-local dsh-emacs--buffer-session sid)
                         (dsh-emacs--chat-buffer-sync sid)
                         (dsh-emacs-mode))))
                    (dsh-emacs--workspaces (list w1)))
            (call-interactively #'dsh-emacs-new-session)
            (let* ((call (car calls))
                   (params (cadr call)))
              (ert-info ((format "%s" "new-session-in-chat-uses-session-workspace"))
                (should (and (string= "session/create" (car call))
                             (string= "w-here"
                                      (cdr (assq 'workspaceId (cdr (assq 'request params)))))
                             (null (assq 'cwd (cdr (assq 'request params))))))))))
      (kill-buffer buf))))

;; 6) In a chat buffer, but the current session is in no workspace:
;; still cwd (ungrouped) (same as test 62-4: automatic project
;; attribution off, see test 80b)
(ert-deftest dsh-emacs-test-workspace-new-session-in-ungrouped-chat-uses-cwd ()
  :tags '(dsh-unit)
  (let ((calls nil)
        (buf (generate-new-buffer " *dsh-chat-create-ungrouped*"))
        (dsh-emacs-new-session-auto-project nil))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "s-lonely")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t `((sessionId . ,(cdr (assq 'sessionId
                                                                (cdr (assq 'request params)))))))))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (buffer &rest _) buffer))
                    ((symbol-function 'dsh-emacs--activate-chat-buffer)
                     (lambda (sid buffer &optional _address)
                       (puthash sid buffer dsh-emacs--chat-buffers)
                       (with-current-buffer buffer
                         (setq-local dsh-emacs--buffer-session sid)
                         (dsh-emacs--chat-buffer-sync sid)
                         (dsh-emacs-mode))))
                    (dsh-emacs--workspaces nil))
            (call-interactively #'dsh-emacs-new-session)
            (let* ((call (car calls))
                   (params (cadr call)))
              (ert-info ((format "%s" "new-session-in-ungrouped-chat-uses-cwd"))
                (should (and (string= "session/create" (car call))
                             (null (assq 'workspaceId (cdr (assq 'request params))))
                             (assq 'cwd (cdr (assq 'request params)))))))))
      (kill-buffer buf))))

;; --- Test 65: pressing c on any session line inside a workspace group
;; creates in that workspace ---
;; Regression: the workspace-id property was only added to the group
;; header / empty-group New Session line; actual session lines inside a
;; group lacked it -> pressing c on those lines took the cwd branch and
;; created an ungrouped session.
(ert-deftest dsh-emacs-test-workspace-session-row-carries-workspace-context ()
  :tags '(dsh-unit)
  (let* ((old-sessions dsh-emacs--sessions)
         (old-workspaces dsh-emacs--workspaces)
         (ws (dsh-protocol-workspace--from-alist
              (list (cons 'workspaceId "w-mid")
                    (cons 'title "Mid WS")
                    (cons 'path "/tmp/dsh-mid-ws")
                    (cons 'sessionIds ["s-inside"]))))
         (s-inside (dsh-protocol-session--from-alist
                    (list (cons 'sessionId "s-inside")
                          (cons 'blank :json-false)
                          (cons 'projections
                                (list (cons 'values
                                            (list (cons 'title "existing"))))))))
         (buf (generate-new-buffer " *dsh-ws-row-create*")))
    (unwind-protect
        (progn
          (setq dsh-emacs--sessions (list s-inside))
          (setq dsh-emacs--workspaces (list ws))
          (with-current-buffer buf
            ;; Render the groups: the session lines of the Mid WS group should
            ;; carry the workspace-id property
            (let ((dsh-emacs--sessions dsh-emacs--sessions)
                  (dsh-emacs--workspaces dsh-emacs--workspaces)
                  (dsh-emacs--archived-sessions nil)
                  (dsh-emacs--current-session nil)
                  (dsh-emacs-session--filter-ws-id nil)
                  (dsh-emacs-session--filter-ws-title nil))
              (dsh-emacs-session--render)
              ;; Find the session line (containing the title text) and check its
              ;; workspace-id
              (goto-char (point-min))
              (let ((row-ok nil))
                (while (and (not row-ok)
                            (search-forward "existing" nil t))
                  (setq row-ok
                        (equal "w-mid"
                               (dsh-emacs-workspace-id-at-point))))
                (ert-info ((format "%s" "session-row-carries-workspace-context"))
                  (should row-ok))))
            ;; Press c on that session line: creation should pass workspaceId
            ;; rather than cwd
            (let ((calls nil))
              (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                         (lambda (method params cb)
                           (push (list method params) calls)
                           (funcall cb t `((sessionId . ,(cdr (assq 'sessionId
                                                                    (cdr (assq 'request params)))))))))
                        ((symbol-function 'pop-to-buffer)
                         (lambda (buffer &rest _) buffer))
                        ((symbol-function 'dsh-emacs--activate-chat-buffer)
                         (lambda (sid buffer &optional _address)
                           (puthash sid buffer dsh-emacs--chat-buffers)
                           (with-current-buffer buffer
                             (setq-local dsh-emacs--buffer-session sid)
                             (dsh-emacs--chat-buffer-sync sid)
                             (dsh-emacs-mode))))
                        ((symbol-value 'dsh-emacs--current-buffer) buf))
                (goto-char (point-min))
                (search-forward "existing" nil t)
                (call-interactively #'dsh-emacs-new-session))
              (let* ((call (car calls))
                     (params (cadr call)))
                (ert-info ((format "%s" "new-session-on-workspace-session-row-uses-workspace-id"))
                  (should (and (string= "session/create" (car call))
                               (string= "w-mid"
                                        (cdr (assq 'workspaceId (cdr (assq 'request params)))))
                               (null (assq 'cwd (cdr (assq 'request params)))))))))))
      (setq dsh-emacs--sessions old-sessions)
      (setq dsh-emacs--workspaces old-workspaces)
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; --- Test 66: the core stream ($events + workspace/follow) updates
;; the cache live ---
;; workspace/session/archive changes are broadcast over the core
;; connection (mirroring dsh web's WorkspaceBrowser live subscription).
;; Frame envelope: {type:'item', value:{...}} (the /api/remote.mux
;; logical stream frame, same as mux).
(ert-deftest dsh-emacs-test-workspace-host-workspace-changed-upserts ()
  :tags '(dsh-unit)
  (let* ((old-sessions dsh-emacs--sessions)
         (old-workspaces dsh-emacs--workspaces)
         (old-archived dsh-emacs--archived-sessions)
         (old-sessions-buffer dsh-emacs--sessions-buffer)
         (list-buf (get-buffer-create " *dsh-host-test-list*")))
    (unwind-protect
        (progn
          (setq dsh-emacs--sessions
                (dsh-emacs-test--session-items
                 (list (list (cons 'sessionId "s-live")
                             (cons 'blank :json-false)))))
          (setq dsh-emacs--workspaces nil)
          (setq dsh-emacs--archived-sessions nil)
          (with-current-buffer list-buf
            (erase-buffer)
            (insert "placeholder"))
          (setq dsh-emacs--sessions-buffer (buffer-name list-buf))

          ;; 1) workspace/follow upsert: a new workspace enters the cache
          ;; (including sessionIds)
          (dsh-emacs-events--host-dispatch
           'host-proc
           (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                   "\"value\":{\"type\":\"upsert\","
                   "\"workspace\":{\"workspaceId\":\"w-live\","
                   "\"path\":\"/tmp/live\",\"title\":\"Live WS\","
                   "\"sessionIds\":[],\"createdAt\":\"2026-01-01\","
                   "\"updatedAt\":\"2026-01-01\"}}}"))
          (let ((ws (car dsh-emacs--workspaces)))
            (ert-info ((format "%s" "host-workspace-changed-upserts"))
              (should (and ws
                           (equal "w-live" (dsh-protocol-workspace-workspace-id ws))
                           (equal "Live WS" (dsh-protocol-workspace-title ws))))))
          ;; upsert also triggers a list redraw (the placeholder has been
          ;; overwritten by real content)
          (ert-info ((format "%s" "host-workspace-changed-repaints"))
            (should (not (string-match-p "placeholder"
                                         (with-current-buffer list-buf
                                           (buffer-string))))))

          ;; 2) workspace/follow upsert: replaces an existing workspace (members change)
          (dsh-emacs-events--host-dispatch
           'host-proc
           (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                   "\"value\":{\"type\":\"upsert\","
                   "\"workspace\":{\"workspaceId\":\"w-live\","
                   "\"path\":\"/tmp/live\",\"title\":\"Live WS\","
                   "\"sessionIds\":[\"s-1\"],\"createdAt\":\"2026-01-01\","
                   "\"updatedAt\":\"2026-01-02\"}}}"))
          (let ((ws (car dsh-emacs--workspaces)))
            (ert-info ((format "%s" "host-workspace-changed-replaces-members"))
              (should (and ws
                           (equal "w-live" (dsh-protocol-workspace-workspace-id ws))
                           (equal '("s-1")
                                  (dsh-protocol-workspace-session-ids ws))))))

          ;; 3) workspace/follow remove: deletes the cache entry
          (dsh-emacs-events--host-dispatch
           'host-proc
           (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                   "\"value\":{\"type\":\"remove\",\"workspaceId\":\"w-live\"}}"))
          (ert-info ((format "%s" "host-workspace-removed-drops"))
            (should (null dsh-emacs--workspaces)))

          ;; 4) workspace/follow archived: replaces the archive set
          (setq dsh-emacs--sessions
                (dsh-emacs-test--session-items
                 (list (list (cons 'sessionId "s-archive")
                             (cons 'blank :json-false)))))
          (dsh-emacs-events--host-dispatch
           'host-proc
           (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                   "\"value\":{\"type\":\"archived\","
                   "\"archivedSessionIds\":[\"s-archive\"]}}"))
          (let ((archived dsh-emacs--archived-sessions))
            (ert-info ((format "%s" "host-archived-sessions-changed"))
              (should (and (hash-table-p archived)
                           (gethash "s-archive" archived)))))

          ;; 5) $events api-session/added: the new session enters the cache
          ;; (blank placeholder)
          (setq dsh-emacs--sessions nil)
          (dsh-emacs-events--host-dispatch
           'host-proc
           (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                   "\"value\":{\"type\":\"emit\",\"event\":\"api-session/added\","
                   "\"args\":[{\"sessionId\":\"s-new\",\"blank\":true,"
                   "\"cwd\":\"/tmp/new\"}]}}"))
          (let ((item (dsh-emacs--chat-session-item "s-new")))
            (ert-info ((format "%s" "host-session-added-caches"))
              (should (and item (equal t (dsh-protocol-session-blank item))))))
          ;; api-session/added is idempotent: broadcasting again produces no
          ;; duplicate row
          (dsh-emacs-events--host-dispatch
           'host-proc
           (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                   "\"value\":{\"type\":\"emit\",\"event\":\"api-session/added\","
                   "\"args\":[{\"sessionId\":\"s-new\",\"blank\":true}]}}"))
          (ert-info ((format "%s" "host-session-added-idempotent"))
            (should (= 1 (length dsh-emacs--sessions))))

          ;; 6) $events api-session/status: updates the running flag and redraws
          (dsh-emacs-events--host-dispatch
           'host-proc
           (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                   "\"value\":{\"type\":\"emit\",\"event\":\"api-session/status\","
                   "\"args\":[\"s-new\",true]}}"))
          (let ((item (dsh-emacs--chat-session-item "s-new")))
            (ert-info ((format "%s" "host-session-status-updates"))
              (should (and item (equal t (dsh-protocol-session-running item))))))

          ;; 7) $events api-session/removed: deletes the cache row
          (dsh-emacs-events--host-dispatch
           'host-proc
           (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                   "\"value\":{\"type\":\"emit\",\"event\":\"api-session/removed\","
                   "\"args\":[\"s-new\"]}}"))
          (ert-info ((format "%s" "host-session-removed-drops"))
            (should (null dsh-emacs--sessions)))

          ;; 8) workspace/follow order: reorders to the server order
          (setq dsh-emacs--workspaces
                (list (dsh-protocol-workspace--from-alist
                       (list (cons 'workspaceId "w-a") (cons 'title "A")
                             (cons 'path "/a") (cons 'sessionIds [])))
                      (dsh-protocol-workspace--from-alist
                       (list (cons 'workspaceId "w-b") (cons 'title "B")
                             (cons 'path "/b") (cons 'sessionIds [])))))
          (dsh-emacs-events--host-dispatch
           'host-proc
           (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                   "\"value\":{\"type\":\"order\","
                   "\"workspaceIds\":[\"w-b\",\"w-a\"]}}"))
          (let ((order (mapcar #'dsh-protocol-workspace-workspace-id
                               dsh-emacs--workspaces)))
            (ert-info ((format "%s" "host-workspace-order-changed"))
              (should (equal '("w-b" "w-a") order))))

          ;; 9) Unknown logical frame type (an unrecognized emit / other) is safely ignored
          (dsh-emacs-events--host-dispatch
           'host-proc
           (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                   "\"value\":{\"type\":\"emit\",\"event\":\"some.event\","
                   "\"args\":[]}}"))
          (ert-info ((format "%s" "host-unknown-frame-ignored"))
            (should (= 2 (length dsh-emacs--workspaces))))

          ;; 10) Full dispatch-json gating: only the host-stream property goes
          ;; through host dispatch
          (setq dsh-emacs--sessions nil)
          (let ((host-props (list (cons 'dsh-emacs-host-stream t))))
            (cl-letf (((symbol-function 'processp)
                       (lambda (_p) t))
                      ((symbol-function 'process-get)
                       (lambda (_p prop)
                         (cdr (assq prop host-props))))
                      ;; Avoid a real connection: the host-lost reconnect logic tries
                      ;; open-network-stream
                      ((symbol-function 'dsh-emacs-events--host-lost)
                       (lambda (_p) nil)))
              (dsh-emacs-events--dispatch-json
               'host-proc
               (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                       "\"value\":{\"type\":\"emit\",\"event\":\"api-session/added\","
                       "\"args\":[{\"sessionId\":\"s-gated\",\"blank\":true}]}}")))
            (ert-info ((format "%s" "host-dispatch-gated-by-property"))
              (should (dsh-emacs--chat-session-item "s-gated"))))
          (setq dsh-emacs--sessions old-sessions)
          (setq dsh-emacs--workspaces old-workspaces)
          (setq dsh-emacs--archived-sessions old-archived)
          (setq dsh-emacs--sessions-buffer old-sessions-buffer)
          (when (buffer-live-p list-buf) (kill-buffer list-buf))))))

(ert-deftest dsh-emacs-test-workspace-session-notices-replay-original-summary ()
  :tags '(dsh-unit)
  (dolist (decoded '(nil t))
    (let ((dsh-emacs--sessions-buffer
           (generate-new-buffer-name " *session-notices*"))
          (dsh-emacs--sessions nil)
          (dsh-emacs--chat-buffers (make-hash-table :test 'equal))
          (dsh-emacs--subagent-catalogs (make-hash-table :test 'equal))
          (dsh-emacs--host-refresh-depth 0)
          (dsh-emacs--host-refresh-frames nil))
      (dsh-emacs-events--host-refresh-begin)
      (dolist (frame
               '(((type . "emit") (event . "api-session/added")
                  (args . [((sessionId . "a") (title . "Original A")
                            (updatedAt . 9) (running . t))]))
                 ((type . "emit") (event . "api-session/status")
                  (args . ["a" :json-false]))
                 ((type . "emit") (event . "api-session/added")
                  (args . [((sessionId . "b") (title . "B"))]))
                 ((type . "emit") (event . "api-session/activity")
                  (args . ["a" 123]))))
        (dsh-emacs-events--host-item
         nil (if decoded (dsh-protocol-core-item--from-alist frame) frame)))
      (should (equal '("a" "b")
                     (mapcar #'dsh-protocol-session-session-id
                             dsh-emacs--sessions)))
      (should-not (dsh-protocol-session-running (car dsh-emacs--sessions)))
      (should (= 123 (dsh-protocol-session-updated-at (car dsh-emacs--sessions))))
      (let ((frame '((type . "emit") (event . "api-session/removed")
                     (args . ["b"]))))
        (dsh-emacs-events--host-item
         nil (if decoded (dsh-protocol-core-item--from-alist frame) frame)))
      (should (equal '("a")
                     (mapcar #'dsh-protocol-session-session-id
                             dsh-emacs--sessions)))
      ;; Cache mutations must not rewrite the original added-notice payload.
      (setf (dsh-protocol-session-title (car dsh-emacs--sessions)) "Cache only")
      (should (= 5 (length dsh-emacs--host-refresh-frames)))
      (setq dsh-emacs--sessions nil)
      (dsh-emacs-events--host-refresh-drain)
      (should (equal '("a")
                     (mapcar #'dsh-protocol-session-session-id
                             dsh-emacs--sessions)))
      (should (equal "Original A"
                     (dsh-protocol-session-title (car dsh-emacs--sessions))))
      (should (= 123 (dsh-protocol-session-updated-at (car dsh-emacs--sessions))))
      (should-not (dsh-protocol-session-running (car dsh-emacs--sessions)))
      (should-not dsh-emacs--host-refresh-frames)
      (should (= 0 dsh-emacs--host-refresh-depth)))))

(ert-deftest dsh-emacs-test-workspace-stream-changes-survive-refresh ()
  :tags '(dsh-unit)
  (dolist (decoded '(nil t))
    (let* ((dsh-emacs--sessions-buffer
            (generate-new-buffer-name " *workspace-stream*"))
           (dsh-emacs--sessions nil)
           (dsh-emacs--workspaces nil)
           (dsh-emacs--archived-sessions nil)
           (dsh-emacs--host-refresh-depth 0)
           (dsh-emacs--host-refresh-frames nil)
           (baseline '((type . "baseline")
                       (value . ((items . [((workspaceId . "a") (title . "Old A"))
                                           ((workspaceId . "b") (title . "B"))])
                                 (archivedSessionIds . ["old"]))))))
      (dsh-emacs-events--host-item
       nil (if decoded (dsh-protocol-core-item--from-alist baseline) baseline))
      (let ((snapshot dsh-emacs--workspaces))
        (dsh-emacs-events--host-refresh-begin)
        (dolist (frame
                 '(((type . "upsert")
                    (workspace . ((workspaceId . "a") (title . "New A")
                                  (sessionIds . ["new-member"]))))
                   ((type . "upsert")
                    (workspace . ((workspaceId . "c") (title . "C"))))
                   ((type . "remove") (workspaceId . "b"))
                   ((type . "order") (workspaceIds . ["c" "a"]))
                   ((type . "archived") (archivedSessionIds . []))))
          (dsh-emacs-events--host-item
           nil (if decoded (dsh-protocol-core-item--from-alist frame) frame)))
        (should (equal '("c" "a")
                       (mapcar #'dsh-protocol-workspace-workspace-id
                               dsh-emacs--workspaces)))
        (should (= 0 (hash-table-count dsh-emacs--archived-sessions)))
        ;; A late response restores the old snapshot; recorded stream changes
        ;; must restore the new row, membership, order and empty archive set.
        (setq dsh-emacs--workspaces snapshot
              dsh-emacs--archived-sessions
              (dsh-emacs--normalize-archived '("old")))
        (dsh-emacs-events--host-refresh-drain)
        (should (equal '("c" "a")
                       (mapcar #'dsh-protocol-workspace-workspace-id
                               dsh-emacs--workspaces)))
        (should (equal "New A"
                       (dsh-protocol-workspace-title
                        (cadr dsh-emacs--workspaces))))
        (should (equal '("new-member")
                       (dsh-protocol-workspace-session-ids
                        (cadr dsh-emacs--workspaces))))
        (should (= 0 (hash-table-count dsh-emacs--archived-sessions)))
        (should (= 0 dsh-emacs--host-refresh-depth))
        (should-not dsh-emacs--host-refresh-frames)))))

(ert-deftest dsh-emacs-test-workspace-baseline-retains-routing-and-empty-arrays ()
  :tags '(dsh-unit)
  (dolist (case '((((projections)) ("keep") ("old"))
                  (((items . nil) (archivedSessionIds . ["ignored"]))
                   ("keep") ("old"))
                  (((items . []) (archivedSessionIds . [])) nil nil)
                  ((("items" . []) ("archivedSessionIds" . ["new"]))
                   nil ("new"))))
    (pcase-let* ((`(,payload ,ids ,archived) case)
                 (dsh-emacs--sessions-buffer
                  (generate-new-buffer-name " *workspace-baseline*"))
                 (dsh-emacs--sessions nil)
                 (dsh-emacs--workspaces
                  (list (dsh-protocol-workspace--from-alist
                         '((workspaceId . "keep")))))
                 (dsh-emacs--archived-sessions
                  (dsh-emacs--normalize-archived '("old"))))
      (dsh-emacs-events--host-item
       nil `((type . "baseline") (value . ,payload)))
      (should (equal ids (mapcar #'dsh-protocol-workspace-workspace-id
                                dsh-emacs--workspaces)))
      (should (= (length archived)
                 (hash-table-count dsh-emacs--archived-sessions)))
      (dolist (id archived)
        (should (gethash id dsh-emacs--archived-sessions))))))

;; --- Test 66b: workspace/follow + session/control baseline frames
;; dispatch correctly by real nesting ---
;; Regression: the baseline frames of `workspace/follow' and
;; `session/control' differ from their incremental frames (upsert/order/
;; queue/projection put the fields at the top level of the frame) -- the
;; logical frame is `{type:'baseline', value:{...}}', with the payload
;; nested one level deeper (workspace/follow:
;; value.items + value.archivedSessionIds; session/control: value.queues/jobs/
;; projections). host-item used to look for `items' only at the frame
;; top level (always nil), so every baseline was misdispatched to
;; session/control and `dsh-emacs--workspaces' was never seeded -- the
;; session list was therefore not grouped by workspace (all landed in
;; Ungrouped).
(ert-deftest dsh-emacs-test-workspace-host-workspace-baseline-seeds-workspaces ()
  :tags '(dsh-unit)
  (let* ((old-workspaces dsh-emacs--workspaces)
         (old-archived dsh-emacs--archived-sessions)
         (old-sessions-buffer dsh-emacs--sessions-buffer))
    (unwind-protect
        (progn
          (setq dsh-emacs--workspaces nil)
          (setq dsh-emacs--archived-sessions nil)
          (setq dsh-emacs--sessions-buffer nil) ; host-repaint skips without a list buffer
          ;; 1) workspace/follow baseline (real wire shape: payload under value)
          (dsh-emacs-events--host-dispatch
           'host-proc
           (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                   "\"value\":{\"type\":\"baseline\",\"value\":{\"items\":"
                   "[{\"workspaceId\":\"w-b1\",\"path\":\"/x\","
                   "\"title\":\"B WS\",\"sessionIds\":[\"s1\",\"s2\"],"
                   "\"createdAt\":\"2026-01-01\",\"updatedAt\":\"2026-01-01\"}],"
                   "\"archivedSessionIds\":[\"s-arch\"]}}}"))
          (let ((ws (car dsh-emacs--workspaces)))
            (ert-info ((format "%s" "host-workspace-baseline-seeds-workspaces"))
              (should ws)
              (should (equal "w-b1" (dsh-protocol-workspace-workspace-id ws)))
              (should (equal '("s1" "s2") (dsh-protocol-workspace-session-ids ws)))
              (should (equal "B WS" (dsh-protocol-workspace-title ws))))
            (ert-info ((format "%s" "host-workspace-baseline-seeds-archived"))
              (should (gethash "s-arch" dsh-emacs--archived-sessions))))
          ;; 2) session/control baseline (`projections` only since dsh 0.1.7)
          ;; no longer swallows the workspace baseline by mistake: the workspace
          ;; cache stays unchanged (not cleared/rewritten)
          (dsh-emacs-events--host-dispatch
           'host-proc
           (concat "{\"type\":\"item\",\"streamId\":\"c2\","
                   "\"value\":{\"type\":\"baseline\",\"value\":"
                   "{\"projections\":{}}}}}"))
          (let ((ids (mapcar #'dsh-protocol-workspace-workspace-id
                             dsh-emacs--workspaces)))
            (ert-info ((format "%s" "host-control-baseline-leaves-workspaces"))
              (should (equal '("w-b1") ids)))))
      (setq dsh-emacs--workspaces old-workspaces)
      (setq dsh-emacs--archived-sessions old-archived)
      (setq dsh-emacs--sessions-buffer old-sessions-buffer))))

;; --- Test 67: workspace ordering move-workspace (insertBefore) ---
;; The web side's drag-to-reorder calls workspace/insertBefore (always
;; RPC); emacs performs the same ordering with an M key command.
;; A missing beforeWorkspaceId = move to the end.
(ert-deftest dsh-emacs-test-workspace-move-workspace-sends-before-workspace-id ()
  :tags '(dsh-unit)
  (let* ((old-workspaces dsh-emacs--workspaces)
         (old-sessions dsh-emacs--sessions)
         (ws-a (dsh-protocol-workspace--from-alist
                (list (cons 'workspaceId "w-a") (cons 'title "A WS")
                      (cons 'path "/tmp/a") (cons 'sessionIds []))))
         (ws-b (dsh-protocol-workspace--from-alist
                (list (cons 'workspaceId "w-b") (cons 'title "B WS")
                      (cons 'path "/tmp/b") (cons 'sessionIds []))))
         (ws-c (dsh-protocol-workspace--from-alist
                (list (cons 'workspaceId "w-c") (cons 'title "C WS")
                      (cons 'path "/tmp/c") (cons 'sessionIds [])))))
    (unwind-protect
        (progn
          (setq dsh-emacs--workspaces (list ws-a ws-b ws-c))
          (setq dsh-emacs--sessions nil)

          ;; 1) Move w-c before w-a: insertBefore carries beforeWorkspaceId
          (let ((calls nil))
            (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (method params cb)
                         (push (list method params) calls)
                         (funcall cb t '((workspaceIds
                                          . ["w-c" "w-a" "w-b"])))))
                      ((symbol-function 'dsh-emacs-list-workspaces)
                       (lambda () nil)))
              (dsh-emacs-move-workspace "w-c" "w-a"))
            (let* ((call (car calls))
                   (params (cadr call)))
              (ert-info ((format "%s" "move-workspace-sends-before-workspace-id"))
                (should (and (string= "workspace/insertBefore" (car call))
                             (string= "w-c" (cdr (assq 'workspaceId (cdr (assq 'request params)))))
                             (string= "w-a" (cdr (assq 'beforeWorkspaceId
                                                       (cdr (assq 'request params)))))))))
            ;; The callback reorders the cache by the response workspaceIds
            ;; (w-c to the top)
            (let ((order (mapcar #'dsh-protocol-workspace-workspace-id
                                 dsh-emacs--workspaces)))
              (ert-info ((format "%s" "move-workspace-reorders-cache"))
                (should (equal '("w-c" "w-a" "w-b") order)))))

          ;; 2) Move to the end: no beforeWorkspaceId
          (let ((calls nil))
            (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (method params cb)
                         (push (list method params) calls)
                         (funcall cb t '((workspaceIds
                                          . ["w-b" "w-c" "w-a"])))))
                      ((symbol-function 'dsh-emacs-list-workspaces)
                       (lambda () nil)))
              (dsh-emacs-move-workspace "w-a" nil))
            (let* ((call (car calls))
                   (params (cadr call)))
              (ert-info ((format "%s" "move-workspace-to-end-omits-before"))
                (should (and (string= "workspace/insertBefore" (car call))
                             (string= "w-a" (cdr (assq 'workspaceId (cdr (assq 'request params)))))
                             (null (assq 'beforeWorkspaceId (cdr (assq 'request params))))))))
            (let ((order (mapcar #'dsh-protocol-workspace-workspace-id
                                 dsh-emacs--workspaces)))
              (ert-info ((format "%s" "move-workspace-to-end-reorders-cache"))
                (should (equal '("w-b" "w-c" "w-a") order))))))
      (setq dsh-emacs--workspaces old-workspaces)
      (setq dsh-emacs--sessions old-sessions))))

;; --- Test 68: a refresh snapshot does not roll back in-flight
;; host/mux frames (refreshFrames mirror) ---
;; dsh web records frames arriving during `refresh' and replays them on
;; top of the snapshot; emacs's list-sessions/list-workspaces responses
;; are snapshots taken at request time, so if frames advance the cache
;; while the response is in flight (another client renaming/archiving/
;; changing status), a plain whole setq rolls back. The begin/drain
;; pairing ensures that when the last refresh ends, all recorded frames
;; are replayed in arrival order.
(ert-deftest dsh-emacs-test-workspace-refresh-replays-workspace-frames ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--sessions-buffer (generate-new-buffer-name " *dsh-workspace-test*"))
         (old-sessions dsh-emacs--sessions)
         (old-workspaces dsh-emacs--workspaces)
         (old-archived dsh-emacs--archived-sessions)
         (old-refresh-depth dsh-emacs--host-refresh-depth)
         (old-frames dsh-emacs--host-refresh-frames))
    (unwind-protect
        (progn
          ;; Baseline: two workspaces + one session
          (setq dsh-emacs--sessions
                (dsh-emacs-test--session-items
                 (list (list (cons 'sessionId "s-a")
                             (cons 'blank :json-false)))))
          (setq dsh-emacs--workspaces
                (list (dsh-protocol-workspace--from-alist
                       (list (cons 'workspaceId "w1") (cons 'title "One")
                             (cons 'path "/one") (cons 'sessionIds ["s-a"])))
                      (dsh-protocol-workspace--from-alist
                       (list (cons 'workspaceId "w2") (cons 'title "Two")
                             (cons 'path "/two") (cons 'sessionIds [])))))

          ;; Scenario 1: the workspace/follow upsert/remove frames arrive while a
          ;; refresh is in flight; the late snapshot does not contain them -> after
          ;; drain the new workspace is still there and the deleted one does not
          ;; reappear.
          (setq dsh-emacs--host-refresh-depth 0
                dsh-emacs--host-refresh-frames nil)
          (dsh-emacs-events--host-refresh-begin)   ; list-workspaces dispatched
          ;; Frames arrive first: add w3 + remove w2
          (dsh-emacs-events--host-frame-record
           (list :upsert-workspace
                 (dsh-protocol-workspace--from-alist
                  (list (cons 'workspaceId "w3") (cons 'title "Three")
                        (cons 'path "/three") (cons 'sessionIds [])))))
          (dsh-emacs-events--host-frame-record
           (list :remove-workspace "w2"))
          ;; Late snapshot: still only w1, w2 (the request-time state) -- models the
          ;; wholesale setq of the list-workspaces callback.
          (setq dsh-emacs--workspaces
                (list (dsh-protocol-workspace--from-alist
                       (list (cons 'workspaceId "w1") (cons 'title "One")
                             (cons 'path "/one") (cons 'sessionIds ["s-a"])))
                      (dsh-protocol-workspace--from-alist
                       (list (cons 'workspaceId "w2") (cons 'title "Two")
                             (cons 'path "/two") (cons 'sessionIds [])))))
          (dsh-emacs-events--host-refresh-drain)
          (let ((ids (mapcar #'dsh-protocol-workspace-workspace-id
                             dsh-emacs--workspaces)))
            (ert-info ((format "%s" "refresh-replays-workspace-frames"))
              (should (and (equal '("w1" "w3") ids)
                           (null (member "w2" ids))))))

          ;; Scenario 2: session-status + title frames in flight; the late snapshot
          ;; rolls them back -> drain restores them
          (setq dsh-emacs--host-refresh-depth 0
                dsh-emacs--host-refresh-frames nil)
          (dsh-emacs-events--host-refresh-begin)
          (dsh-emacs-events--host-frame-record (list :session-status "s-a" t))
          (dsh-emacs-events--host-frame-record
           (list :apply-title "s-a" "renamed"))
          ;; Late snapshot (old running + old title)
          (setq dsh-emacs--sessions
                (dsh-emacs-test--session-items
                 (list (list (cons 'sessionId "s-a")
                             (cons 'blank :json-false)
                             (cons 'running :json-false)))))
          (dsh-emacs-events--host-refresh-drain)
          (let ((item (dsh-emacs--chat-session-item "s-a")))
            (ert-info ((format "%s" "refresh-replays-session-status-title"))
              (should (and item
                           (equal t (dsh-protocol-session-running item))
                           (equal "renamed" (dsh-protocol-session-title-value item))))))

          ;; Scenario 3: nested refresh (list-workspaces called inside list-sessions)
          ;; -- no replay before depth reaches zero; only the final drain replays all
          ;; frames.
          (setq dsh-emacs--host-refresh-depth 0
                dsh-emacs--host-refresh-frames nil)
          (dsh-emacs-events--host-refresh-begin)   ; list-sessions
          (dsh-emacs-events--host-frame-record
           (list :upsert-workspace
                 (dsh-protocol-workspace--from-alist
                  (list (cons 'workspaceId "w9") (cons 'title "Nine")
                        (cons 'path "/nine") (cons 'sessionIds [])))))
          (dsh-emacs-events--host-refresh-begin)   ; Inner list-workspaces
          (dsh-emacs-events--host-refresh-drain)   ; Inner complete: depth 1, no replay
          (let ((ids-before (mapcar #'dsh-protocol-workspace-workspace-id
                                    dsh-emacs--workspaces)))
            (ert-info ((format "%s" "nested-refresh-holds-frames"))
              (should (= dsh-emacs--host-refresh-depth 1))))
          (dsh-emacs-events--host-refresh-drain)   ; Outer complete: replay
          (let ((ids (mapcar #'dsh-protocol-workspace-workspace-id
                             dsh-emacs--workspaces)))
            (ert-info ((format "%s" "nested-refresh-replays-at-outer-end"))
              (should (member "w9" ids))))

          ;; Scenario 4: a failed refresh (RPC error) also drains,
          ;; leaving no dangling depth
          (setq dsh-emacs--host-refresh-depth 0)
          (dsh-emacs-events--host-refresh-begin)
          (dsh-emacs-events--host-refresh-drain)
          (ert-info ((format "%s" "refresh-drain-always-restores-depth"))
            (should (= dsh-emacs--host-refresh-depth 0)))
          ;; Scenario 5: replaying a batch of recorded frames renders the list
          ;; ONCE, not once per frame.  A `session/control' baseline that lands
          ;; during a session-list refresh records one `:apply-title' frame per
          ;; session (hundreds on a large host); replaying them repainted the
          ;; whole list per frame, which is what made the first open block for
          ;; seconds before any row appeared.  The list buffer must be live:
          ;; without one `--host-repaint' is a no-op and this proves nothing.
          (setq dsh-emacs--host-refresh-depth 0
                dsh-emacs--host-refresh-frames nil)
          (dsh-emacs-events--host-refresh-begin)
          (let ((n 0))
            (while (< n 200)
              (dsh-emacs-events--host-frame-record
               (list :apply-title "s-a" (format "title-%d" n)))
              (setq n (1+ n))))
          (setq dsh-emacs--sessions
                (dsh-emacs-test--session-items
                 (list (list (cons 'sessionId "s-a") (cons 'blank :json-false)))))
          (let ((buf (get-buffer-create dsh-emacs--sessions-buffer))
                (renders 0))
            (unwind-protect
                (progn
                  (with-current-buffer buf (dsh-emacs-session-mode))
                  (cl-letf (((symbol-function 'dsh-emacs-session--render)
                             (lambda (&rest _) (setq renders (1+ renders)))))
                    (dsh-emacs-events--host-refresh-drain)
                    (ert-info ((format "refresh-drain-renders-once: replayed 200 frames with %d renders" renders))
                      (should (= renders 1)))))
              (when (buffer-live-p buf) (kill-buffer buf)))))
      (setq dsh-emacs--sessions old-sessions)
      (setq dsh-emacs--workspaces old-workspaces)
      (setq dsh-emacs--archived-sessions old-archived)
      (setq dsh-emacs--host-refresh-depth old-refresh-depth)
      (setq dsh-emacs--host-refresh-frames old-frames))))

;; --- Test 80b: new-session auto-detects the project and assigns its
;; workspace ---
;; The detection chain depends on project.el (built in since Emacs 28+); when
;; the require returns nil on 27 the whole section is skipped without
;; affecting the other tests. Layered coverage:
;;   1) `dsh-emacs--project-root': project.el first -> VC root -> .git walk;
;;      project → nil;
;;     2) `dsh-emacs--workspace-id-by-path': matched by the same canonical path
;;        as the server (trailing slash / symlinks both resolved);
;;     3) `dsh-emacs--new-session-project-workspace' orchestration: option
;;        on/off, local/remote server, cache hit skips RPC, a miss goes through
;;        the idempotent workspace/create and is cached immediately, RPC failure
;;        falls back to nil;
;;     4) end-to-end call-interactively: plain buffer -> session/create with
;;        workspaceId and no cwd; creation failure -> cwd is still sent.
(require 'project nil t)

(require 'vc nil t)

(ert-deftest dsh-emacs-test-workspace-project-root-prefers-project-el ()
  :tags '(dsh-unit)
  (skip-unless (and (fboundp 'project-current) (fboundp 'project-root)
                    (fboundp 'vc-root-dir)))
  ;; project.el branch first: returns its root
  ;; (plus `~' / trailing-slash normalization)
  (let ((root (directory-file-name (make-temp-file "dsh-pj1-" t)))
        (fake (list 'vc "fake-project")))
    (unwind-protect
        (cl-letf (((symbol-function 'project-current) (lambda (&rest _) fake))
                  ((symbol-function 'project-root) (lambda (_pr) root)))
          (ert-info ((format "%s" "project-root-prefers-project-el"))
            (should (equal (dsh-emacs--project-root
                            (expand-file-name "inside" root))
                           root))))
      (delete-directory root t)))
  ;; fallback chain: project.el no result + VC root no result
  ;; -> .git walk; all miss -> nil
  (let* ((root (directory-file-name (make-temp-file "dsh-pj2-" t)))
         (empty (make-temp-file "dsh-pj3-" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" root))
          (make-directory (expand-file-name "nested" root))
          (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                    ((symbol-function 'project-root) (lambda (&rest _) nil))
                    ((symbol-function 'vc-root-dir) (lambda (&rest _) nil)))
            (ert-info ((format "%s" "project-root-walks-git-marker"))
              (should (equal (dsh-emacs--project-root
                              (expand-file-name "nested" root))
                             root)))
            (ert-info ((format "%s" "project-root-nil-outside-any-project"))
              (should (null (dsh-emacs--project-root empty))))))
      (delete-directory root t)
      (delete-directory empty t))))

;; workspace path matching (canonical): trailing slash,
;; symlink, different directory
(ert-deftest dsh-emacs-test-workspace-workspace-id-by-path-matches-trailing-slash ()
  :tags '(dsh-unit)
  (let* ((root (directory-file-name (make-temp-file "dsh-wsp-" t)))
         (sym (expand-file-name
               (format "dsh-link-%d" (random 99999))
               (directory-file-name temporary-file-directory)))
         (ws (dsh-protocol-workspace--from-alist
              (list (cons 'workspaceId "w-root")
                    (cons 'path root)
                    (cons 'sessionIds [])))))
    (unwind-protect
        (let ((dsh-emacs--workspaces (list ws)))
          (ert-info ((format "%s" "workspace-id-by-path-matches-trailing-slash"))
            (should (equal (dsh-emacs--workspace-id-by-path
                            (concat root "/") dsh-emacs--workspaces)
                           "w-root")))
          (ert-info ((format "%s" "workspace-id-by-path-misses-different-dir"))
            (should (null (dsh-emacs--workspace-id-by-path
                           (expand-file-name "elsewhere" root)
                           dsh-emacs--workspaces))))
          (ignore-errors (delete-file sym))
          (make-symbolic-link root sym)
          (ert-info ((format "%s" "workspace-id-by-path-resolves-symlink"))
            (should (equal (dsh-emacs--workspace-id-by-path
                            sym dsh-emacs--workspaces) "w-root"))))
      (ignore-errors (delete-file sym))
      (delete-directory root t))))

;; Delayed responses must preserve each draft and never steal another window.
(ert-deftest dsh-emacs-test-workspace-draft-only-creates-before-activation ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--sessions nil)
        (dsh-emacs--workspaces nil)
        (dsh-emacs--chat-buffers (make-hash-table :test #'equal))
        (dsh-emacs--current-session "old-session")
        (dsh-emacs--current-buffer nil)
        (dsh-emacs-new-session-auto-project nil)
        (dsh-emacs--sessions-buffer " *draft-test-list*")
        (requests nil)
        (connected nil)
        (drafts nil)
        (other (generate-new-buffer " *draft-test-other*")))
    (save-window-excursion
      (unwind-protect
          (cl-letf (((symbol-function 'dsh-emacs-server-ensure)
                     (lambda () (error "Creation must not use a blocking guard")))
                    ((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params callback)
                       (ert-info ((format "%s" "draft-only-creates-before-activation"))
                         (should (equal method "session/create")))
                       (push (list (cdr (assq 'sessionId (cdr (assq 'request params))))
                                   callback) requests)))
                    ((symbol-function 'dsh-emacs-command-catalog-prefetch) #'ignore)
                    ((symbol-function 'dsh-emacs-skill-prefetch) #'ignore)
                    ((symbol-function 'dsh-emacs-reference-prefetch) #'ignore)
                    ((symbol-function 'dsh-emacs-events-connect)
                     (lambda (buf) (push buf connected))))
            (let* ((first (dsh-emacs-new-session "/tmp/first" nil "ptc"))
                   (request-one (car requests))
                   (second (dsh-emacs-new-session "/tmp/second" nil "ptc"))
                   (request-two (car requests)))
              (setq drafts (list first second))
              (with-current-buffer first
                (insert "第一份 draft")
                (goto-char 3)
                (narrow-to-region 2 5)
                (ert-info ((format "%s" "draft-send-is-unavailable"))
                  (should (condition-case nil
                              (progn (dsh-emacs-send-or-stop) nil)
                            (user-error t)))))
              (with-current-buffer second (insert "second draft"))
              (switch-to-buffer other)
              (funcall (cadr request-two) t
                       `((sessionId . ,(car request-two)) (agentPreset . "ptc")))
              (funcall (cadr request-one) t
                       '((sessionId . "server-assigned") (agentPreset . "ptc")))
              (ert-info ((format "%s" "draft-responses-do-not-steal-focus"))
                (should (eq (window-buffer (selected-window)) other))
                (should (equal dsh-emacs--current-session "old-session"))
                (should (null dsh-emacs--current-buffer)))
              (ert-info ((format "%s" "draft-responses-connect-their-own-buffers"))
                (should (equal connected (list first second)))
                (should (eq (gethash "server-assigned" dsh-emacs--chat-buffers) first))
                (should-not (gethash (car request-one) dsh-emacs--chat-buffers))
                (should (dsh-emacs--chat-session-item "server-assigned"))
                (should (eq (gethash (car request-two) dsh-emacs--chat-buffers) second)))
              (with-current-buffer first
                (ert-info ((format "%s" "draft-activation-preserves-text-point-and-directory"))
                  (should (derived-mode-p 'dsh-emacs-mode))
                  (should (equal (dsh-emacs--get-input) "第一份 draft"))
                  (should (= (point) (+ dsh-emacs--input-marker 2)))
                  (should (equal default-directory "/tmp/first/"))))
              (with-current-buffer second
                (ert-info ((format "%s" "drafts-keep-separate-text-and-identities"))
                  (should (equal (dsh-emacs--get-input) "second draft"))
                  (should (equal dsh-emacs--buffer-session (car request-two))))))
            (let* ((draft (dsh-emacs-new-session "/tmp" nil "ptc"))
                   (old (car requests)))
              (push draft drafts)
              (insert "retry me")
              (funcall (cadr old) nil "offline")
              (ert-info ((format "%s" "draft-failure-keeps-text-and-allows-retry"))
                (should (derived-mode-p 'dsh-emacs-draft-mode))
                (should (equal (buffer-string) "retry me"))
                (should (null dsh-emacs--creation-pending))
                (should (string-match-p "offline" header-line-format)))
              (dsh-emacs-retry-session-creation)
              (let ((new (car requests)))
                (funcall (cadr old) t
                         `((sessionId . ,(car old)) (agentPreset . "ptc")))
                (ert-info ((format "%s" "draft-retry-reuses-id-and-rejects-stale-callback"))
                  (should (equal (car old) (car new)))
                  (should (derived-mode-p 'dsh-emacs-draft-mode))
                  (should dsh-emacs--creation-pending))
                (let ((dsh-emacs-mode-hook
                       (list (lambda () (error "test activation failure")))))
                  (funcall (cadr new) t
                           '((sessionId . "server-retry") (agentPreset . "ptc"))))
                (ert-info ((format "%s" "draft-activation-error-restores-editable-text"))
                  (should (derived-mode-p 'dsh-emacs-draft-mode))
                  (should (equal (buffer-string) "retry me"))
                  (should (null dsh-emacs--creation-pending))
                  (should dsh-emacs--creation-context)
                  (should (null (gethash "server-retry" dsh-emacs--chat-buffers))))
                (dsh-emacs-retry-session-creation)
                (should (equal (caar requests) "server-retry"))
                (funcall (cadar requests) t
                         `((sessionId . ,(caar requests)) (agentPreset . "ptc")))
                (ert-info ((format "%s" "draft-retry-activates-without-sending"))
                  (should (derived-mode-p 'dsh-emacs-mode))
                  (should (equal (dsh-emacs--get-input) "retry me"))
                  (should (equal dsh-emacs--current-session "server-retry")))))
            (let* ((draft (dsh-emacs-new-session "/tmp" nil "ptc"))
                   (request (car requests)))
              (kill-buffer draft)
              (funcall (cadr request) t
                       `((sessionId . ,(car request)) (agentPreset . "ptc")))
              (ert-info ((format "%s" "closed-draft-is-not-resurrected"))
                (should (not (buffer-live-p draft)))
                (should (null (gethash (car request) dsh-emacs--chat-buffers)))))
            (let* ((draft (dsh-emacs-new-session "/tmp" nil "ptc"))
                   (request (car requests))
                   (dsh-emacs-base-url "http://different-server:3080"))
              (push draft drafts)
              (funcall (cadr request) t
                       `((sessionId . ,(car request)) (agentPreset . "ptc")))
              (ert-info ((format "%s" "draft-server-change-rejects-old-response"))
                (should (derived-mode-p 'dsh-emacs-draft-mode))
                (should (null dsh-emacs--creation-pending))
                (should (null (gethash (car request) dsh-emacs--chat-buffers))))))
        (dolist (buf (cons other drafts))
          (when (buffer-live-p buf) (kill-buffer buf)))))))

;; Workspace discovery is asynchronous and never silently changes placement.
(ert-deftest dsh-emacs-test-workspace-draft-workspace-create-precedes-session-create ()
  :tags '(dsh-unit)
  (dolist (scenario '(cached create failed disabled remote))
    (let* ((dsh-emacs--sessions nil)
           (dsh-emacs--chat-buffers (make-hash-table :test #'equal))
           (dsh-emacs-new-session-auto-project (not (eq scenario 'disabled)))
           (dsh-emacs--workspaces
            (when (eq scenario 'cached)
              (list (dsh-protocol-workspace--from-alist
                     '((workspaceId . "ws") (path . "/tmp/project"))))))
           (requests nil)
           (draft nil)
           (detections nil))
      (save-window-excursion
        (unwind-protect
            (cl-letf (((symbol-function 'dsh-emacs--server-local-host-p)
                       (lambda () (not (eq scenario 'remote))))
                      ((symbol-function 'dsh-emacs--project-root)
                       (lambda (dir) (push dir detections) "/tmp/project"))
                      ((symbol-function 'dsh-emacs--rpc-request)
                       (lambda (&rest _) (error "Synchronous workspace request")))
                      ((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (method params cb)
                         (push (list method params cb) requests))))
              (with-temp-buffer
                (setq default-directory "/tmp/project/subdir/")
                (setq draft (dsh-emacs-new-session nil nil "ptc")))
              (when (memq scenario '(create failed))
                (ert-info ((format "%s" "draft-workspace-create-precedes-session-create"))
                  (should (equal (caar requests) "workspace/create"))
                  (should (equal (cdr (assq 'path (cdr (assq 'request (cadar requests)))))
                                 "/tmp/project")))
                (funcall (nth 2 (car requests)) (eq scenario 'create)
                         '((workspace . ((workspaceId . "ws")
                                         (path . "/tmp/project"))))))
              (pcase scenario
                ('failed
                 (ert-info ((format "%s" "draft-workspace-failure-does-not-create-ungrouped"))
                   (should (= (length requests) 1))
                   (should (with-current-buffer draft
                             (and (null dsh-emacs--creation-pending)
                                  (string-match-p "Workspace" header-line-format))))))
                (_
                 (let ((args (cdr (assq 'request (cadar requests)))))
                   (ert-info ((format "%s" (format "draft-workspace-placement-%s" scenario)))
                     (should (equal (caar requests) "session/create"))
                     (should (if (memq scenario '(disabled remote))
                                 (and (null detections)
                                      (equal (cdr (assq 'cwd args)) "/tmp/project/subdir/")
                                      (null (assq 'workspaceId args)))
                               (and (equal detections '("/tmp/project/subdir/"))
                                    (equal (cdr (assq 'workspaceId args)) "ws")
                                    (null (assq 'cwd args))))))))))
          (when (buffer-live-p draft) (kill-buffer draft)))))))

;; --- Test 80d: absolute-cwd precedence ---
;; cwd argument > current buffer default-directory > `dsh-emacs-default-cwd'.
(ert-deftest dsh-emacs-test-workspace-absolute-cwd-precedence ()
  :tags '(dsh-unit)
  (let ((flat (directory-file-name (make-temp-file "dsh-cwd-flat-" t))))
    (unwind-protect
        (ert-info ((format "%s" "absolute-cwd-precedence"))
          (should (let ((default-directory (concat flat "/buf/"))
                        (dsh-emacs-default-cwd (concat flat "/cfg/")))
                    (equal (expand-file-name (concat flat "/x/"))
                           (dsh-emacs--absolute-cwd (concat flat "/x/")))
                    (equal (expand-file-name (concat flat "/buf/"))
                           (dsh-emacs--absolute-cwd nil))))
          (should (let ((default-directory nil)
                        (dsh-emacs-default-cwd (concat flat "/cfg/")))
                    (equal (expand-file-name (concat flat "/cfg/"))
                           (dsh-emacs--absolute-cwd nil)))))
      (delete-directory flat t))))

;; --- Test 102: dsh-emacs--workspace-sessions ---
(ert-deftest dsh-emacs-test-workspace-workspace-sessions-filters-and-sorts ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--sessions nil)
        (dsh-emacs--workspaces nil)
        (dsh-emacs--archived-sessions nil)
        (dsh-emacs--current-session nil)
        (s1 (dsh-protocol-session--from-alist
             (list (cons 'sessionId "s1") (cons 'title "First")
                   (cons 'updatedAt 2000) (cons 'blank :json-false))))
        (s2 (dsh-protocol-session--from-alist
             (list (cons 'sessionId "s2") (cons 'title "Second")
                   (cons 'updatedAt 1000) (cons 'blank :json-false))))
        (s3 (dsh-protocol-session--from-alist
             (list (cons 'sessionId "s3") (cons 'title "Blank")
                   (cons 'blank t))))
        (s4 (dsh-protocol-session--from-alist
             (list (cons 'sessionId "s4") (cons 'title "Stray")
                   (cons 'blank :json-false))))
        (s5 (dsh-protocol-session--from-alist
             (list (cons 'sessionId "s5") (cons 'title "Subagent")
                   (cons 'origin "subagent") (cons 'blank :json-false))))
        (w1 (dsh-protocol-workspace--from-alist
             (list (cons 'workspaceId "w1") (cons 'title "MyWS")
                   (cons 'path "/tmp/ws")
                   (cons 'sessionIds ["s1" "s2" "s3" "s5"])
                   (cons 'createdAt "x") (cons 'updatedAt "x")))))
    (setq dsh-emacs--workspaces (list w1)
          dsh-emacs--sessions (list s1 s2 s3 s4 s5)
          dsh-emacs--archived-sessions nil)
    (let ((result (dsh-emacs--workspace-sessions "w1")))
      (ert-info ((format "%s" "workspace-sessions-filters-and-sorts"))
        (should (and (= (length result) 2)
                     (string= "s1" (dsh-protocol-session-session-id (car result)))
                     (string= "s2" (dsh-protocol-session-session-id (cadr result)))))))))

;; --- Test 103: dsh-emacs--workspace-sessions empty workspace ---
(ert-deftest dsh-emacs-test-workspace-workspace-sessions-empty-returns-nil ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--sessions nil)
         (dsh-emacs--workspaces nil)
         (dsh-emacs--archived-sessions nil)
         (dsh-emacs--current-session nil)
         (w-empty (dsh-protocol-workspace--from-alist
                   (list (cons 'workspaceId "empty-ws")
                         (cons 'title "Empty")
                         (cons 'path "/tmp/empty")
                         (cons 'sessionIds [])
                         (cons 'createdAt "x")
                         (cons 'updatedAt "x"))))
         (sessions (list (dsh-protocol-session--from-alist
                          (list (cons 'sessionId "s99")
                                (cons 'title "Stray")
                                (cons 'blank :json-false)))))
         (workspaces (list w-empty)))
    (setq dsh-emacs--workspaces workspaces
          dsh-emacs--sessions sessions
          dsh-emacs--archived-sessions nil)
    (ert-info ((format "%s" "workspace-sessions-empty-returns-nil"))
      (should (null (dsh-emacs--workspace-sessions "empty-ws"))))))

;; --- Test 104: dsh-emacs--workspace-sessions unknown workspace ---
(ert-deftest dsh-emacs-test-workspace-workspace-sessions-unknown-returns-nil ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--sessions nil)
         (dsh-emacs--workspaces nil)
         (dsh-emacs--archived-sessions nil)
         (dsh-emacs--current-session nil)
         (w1 (dsh-protocol-workspace--from-alist
              (list (cons 'workspaceId "w1")
                    (cons 'title "WS")
                    (cons 'path "/tmp/ws")
                    (cons 'sessionIds ["s1"])
                    (cons 'createdAt "x")
                    (cons 'updatedAt "x"))))
         (sessions (list (dsh-protocol-session--from-alist
                          (list (cons 'sessionId "s1")
                                (cons 'title "One")
                                (cons 'blank :json-false)))))
         (workspaces (list w1)))
    (setq dsh-emacs--workspaces workspaces
          dsh-emacs--sessions sessions
          dsh-emacs--archived-sessions nil)
    (ert-info ((format "%s" "workspace-sessions-unknown-returns-nil"))
      (should (null (dsh-emacs--workspace-sessions "unknown-ws"))))))

;; --- Test 105: dsh-emacs-switch-workspace-session excludes the current
;; session ---
(ert-deftest dsh-emacs-test-workspace-switch-session-excludes-current ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--sessions nil)
         (dsh-emacs--workspaces nil)
         (dsh-emacs--archived-sessions nil)
         (dsh-emacs--current-session nil)
         (w1 (dsh-protocol-workspace--from-alist
              (list (cons 'workspaceId "w1")
                    (cons 'title "WS")
                    (cons 'path "/tmp/ws")
                    (cons 'sessionIds ["s1" "s2"])
                    (cons 'createdAt "x")
                    (cons 'updatedAt "x"))))
         (s1 (dsh-protocol-session--from-alist
              (list (cons 'sessionId "s1") (cons 'title "Cur")
                    (cons 'blank :json-false))))
         (s2 (dsh-protocol-session--from-alist
              (list (cons 'sessionId "s2") (cons 'title "Other")
                    (cons 'blank :json-false))))
         (collection nil)
         (opened nil))
    (setq dsh-emacs--workspaces (list w1)
          dsh-emacs--sessions (list s1 s2)
          dsh-emacs--archived-sessions nil
          dsh-emacs--current-session "s1")
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt coll &rest _)
                 (setq collection coll)
                 ;; Choose the first candidate (after the current session is excluded only
                 ;; s2 remains)
                 (car (dsh-test-completion-items coll))))
              ((symbol-function 'dsh-emacs-open-session)
               (lambda (sid) (setq opened sid))))
      (dsh-emacs-switch-workspace-session))
    (ert-info ((format "%s" "switch-session-excludes-current"))
      (should (and (equal opened "s2")
                   (= (length (dsh-test-completion-items collection)) 1))))))

;; --- Test 106: dsh-emacs-switch-workspace-session shows a prompt when
;; there are no other sessions ---
(ert-deftest dsh-emacs-test-workspace-switch-session-no-others-message ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--sessions nil)
         (dsh-emacs--workspaces nil)
         (dsh-emacs--archived-sessions nil)
         (dsh-emacs--current-session nil)
         (w1 (dsh-protocol-workspace--from-alist
              (list (cons 'workspaceId "w1")
                    (cons 'title "WS")
                    (cons 'path "/tmp/ws")
                    (cons 'sessionIds ["s1"])
                    (cons 'createdAt "x")
                    (cons 'updatedAt "x"))))
         (s1 (dsh-protocol-session--from-alist
              (list (cons 'sessionId "s1") (cons 'title "Solo")
                    (cons 'blank :json-false))))
         (prompted nil)
         (msgs nil))
    (setq dsh-emacs--workspaces (list w1)
          dsh-emacs--sessions (list s1)
          dsh-emacs--archived-sessions nil
          dsh-emacs--current-session "s1")
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) (setq prompted t) nil))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) msgs))))
      (dsh-emacs-switch-workspace-session))
    (ert-info ((format "%s" "switch-session-no-others-message"))
      (should (and (not prompted)
                   (member "No other sessions in this workspace" msgs))))))

;; --- Test 107: dsh-emacs-switch-workspace-session candidates sorted by
;; activity time (ungrouped fallback) ---
(ert-deftest dsh-emacs-test-workspace-switch-session-sorts-by-recency ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--sessions nil)
        (dsh-emacs--workspaces nil)
        (dsh-emacs--archived-sessions nil)
        (dsh-emacs--current-session nil)
        (s-old (dsh-protocol-session--from-alist
                (list (cons 'sessionId "s-old") (cons 'title "Old")
                      (cons 'updatedAt 1000) (cons 'blank :json-false))))
        (s-new (dsh-protocol-session--from-alist
                (list (cons 'sessionId "s-new") (cons 'title "New")
                      (cons 'updatedAt 2000) (cons 'blank :json-false))))
        (collection nil)
        (opened nil))
    (setq dsh-emacs--workspaces nil
          dsh-emacs--sessions (list s-old s-new) ; Cache order ≠ activity order
          dsh-emacs--archived-sessions nil
          dsh-emacs--current-session "s-cur")
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt coll &rest _)
                 (setq collection coll)
                 ;; Choose the first item; sorted by activity time it should be s-new
                 (car (dsh-test-completion-items coll))))
              ((symbol-function 'dsh-emacs-open-session)
               (lambda (sid) (setq opened sid))))
      (dsh-emacs-switch-workspace-session))
    (ert-info ((format "%s" "switch-session-sorts-by-recency"))
      (should (and (equal opened "s-new") ; first after sorting = s-new (larger updatedAt)
                   (= (length (dsh-test-completion-items collection)) 2))))))

;; --- Test 108: switch-session completion carries order-preserving
;; metadata (framework-independent) ---
(ert-deftest dsh-emacs-test-workspace-switch-session-attaches-preserve-order-metadata ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--sessions nil)
        (dsh-emacs--workspaces nil)
        (dsh-emacs--archived-sessions nil)
        (dsh-emacs--current-session nil)
        (s1 (dsh-protocol-session--from-alist
             (list (cons 'sessionId "s1") (cons 'title "One")
                   (cons 'updatedAt 1000) (cons 'blank :json-false))))
        (sort-fn 'unset))
    (setq dsh-emacs--workspaces nil
          dsh-emacs--sessions (list s1)
          dsh-emacs--archived-sessions nil
          dsh-emacs--current-session "s0")
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt coll &rest _)
                 (setq sort-fn (completion-metadata-get
                                (completion-metadata "" coll nil)
                                'display-sort-function))
                 "s1")))
      (dsh-emacs-switch-workspace-session))
    (ert-info ((format "%s" "switch-session-attaches-preserve-order-metadata"))
      (should (eq sort-fn 'identity)))))

;; --- Test 109: switch-session disables ivy sorting under ivy-mode ---
(ert-deftest dsh-emacs-test-workspace-switch-session-disables-ivy-sort ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--sessions nil)
        (dsh-emacs--workspaces nil)
        (dsh-emacs--archived-sessions nil)
        (dsh-emacs--current-session nil)
        (s1 (dsh-protocol-session--from-alist
             (list (cons 'sessionId "s1") (cons 'title "One")
                   (cons 'updatedAt 1000) (cons 'blank :json-false))))
        (ivy-mode t)
        (ivy-alist-seen 'unset))
    (setq dsh-emacs--workspaces nil
          dsh-emacs--sessions (list s1)
          dsh-emacs--archived-sessions nil
          dsh-emacs--current-session "s0")
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt _coll &rest _)
                 (setq ivy-alist-seen ivy-sort-functions-alist)
                 "s1")))
      (dsh-emacs-switch-workspace-session))
    (ert-info ((format "%s" "switch-session-disables-ivy-sort"))
      (should (and (consp ivy-alist-seen)
                   (eq (car (car ivy-alist-seen)) t)
                   (null (cdr (car ivy-alist-seen))))))))

;; --- Test 110: dsh-emacs-session--visible-p visible-session rules ---
(ert-deftest dsh-emacs-test-workspace-visible-p-mirrors-dsh-web-rule ()
  :tags '(dsh-unit)
  (let ((h-arch (make-hash-table :test 'equal)))
    (puthash "s-arch" t h-arch)
    (let ((s-ok (dsh-protocol-session--from-alist
                 (list (cons 'sessionId "s-ok") (cons 'blank :json-false))))
          (s-archived (dsh-protocol-session--from-alist
                       (list (cons 'sessionId "s-arch") (cons 'blank :json-false))))
          (s-sub (dsh-protocol-session--from-alist
                  (list (cons 'sessionId "s-sub") (cons 'origin "subagent")
                        (cons 'blank :json-false))))
          (s-blank (dsh-protocol-session--from-alist
                    (list (cons 'sessionId "s-blank") (cons 'blank t))))
          (s-blank-cur (dsh-protocol-session--from-alist
                        (list (cons 'sessionId "s-blank-cur") (cons 'blank t)))))
      (let ((dsh-emacs--archived-sessions h-arch)
            (dsh-emacs--current-session "s-blank-cur"))
        (ert-info ((format "%s" "visible-p-mirrors-dsh-web-rule"))
          (should (and (dsh-emacs-session--visible-p s-ok)
                       (not (dsh-emacs-session--visible-p s-archived))
                       (not (dsh-emacs-session--visible-p s-sub))
                       (not (dsh-emacs-session--visible-p s-blank))
                       ;; blank but currently open → visible
                       (dsh-emacs-session--visible-p s-blank-cur))))))))

;; --- Test 110b: group-sessions follows visible-p to pick members
;; (regression) ---
;; `unless' and `when' were once swapped: the list only collected
;; archived/subagent/blank sessions and dropped normal sessions. This case
;; asserts group membership directly, so a wrong direction disappears
;; silently.
(ert-deftest dsh-emacs-test-workspace-group-sessions-filters-by-visible-rule ()
  :tags '(dsh-unit)
  (let* ((h-arch (make-hash-table :test 'equal))
         (ws (list (dsh-protocol-workspace--from-alist
                    (list (cons 'workspaceId "w1")
                          (cons 'title "WS1")
                          (cons 'path "/tmp/ws1")
                          (cons 'sessionIds
                                ["s-ok" "s-arch" "s-sub" "s-blank" "s-blank-cur"])
                          (cons 'createdAt "x")
                          (cons 'updatedAt "x")))))
         (sessions (list (dsh-protocol-session--from-alist
                          (list (cons 'sessionId "s-ok")
                                (cons 'blank :json-false)))
                         (dsh-protocol-session--from-alist
                          (list (cons 'sessionId "s-arch")
                                (cons 'blank :json-false)))
                         (dsh-protocol-session--from-alist
                          (list (cons 'sessionId "s-sub")
                                (cons 'origin "subagent")
                                (cons 'blank :json-false)))
                         (dsh-protocol-session--from-alist
                          (list (cons 'sessionId "s-blank")
                                (cons 'blank t)))
                         (dsh-protocol-session--from-alist
                          (list (cons 'sessionId "s-blank-cur")
                                (cons 'blank t)))))
         (dsh-emacs--archived-sessions (progn (puthash "s-arch" t h-arch) h-arch))
         (dsh-emacs--current-session "s-blank-cur")
         (grouped (dsh-emacs-session--group-sessions sessions ws))
         (group (cl-find-if (lambda (g)
                              (equal "WS1" (plist-get g :label)))
                            grouped))
         (ids (sort (mapcar (lambda (s)
                              (dsh-protocol-session-session-id s))
                            (plist-get group :sessions))
                    #'string<)))
    (ert-info ((format "%s" "group-sessions-filters-by-visible-rule"))
      (should (equal ids '("s-blank-cur" "s-ok"))))))

;; --- Test 111: dsh-emacs-switch-session candidates across all workspaces ---
(ert-deftest dsh-emacs-test-workspace-switch-session-all-spans-workspaces ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--sessions nil)
         (dsh-emacs--workspaces nil)
         (dsh-emacs--archived-sessions nil)
         (dsh-emacs--current-session nil)
         (w1 (dsh-protocol-workspace--from-alist
              (list (cons 'workspaceId "w1") (cons 'title "WS1")
                    (cons 'path "/tmp/ws1")
                    (cons 'sessionIds ["s1" "s2" "s-arch"])
                    (cons 'createdAt "x") (cons 'updatedAt "x"))))
         (w2 (dsh-protocol-workspace--from-alist
              (list (cons 'workspaceId "w2") (cons 'title "WS2")
                    (cons 'path "/tmp/ws2")
                    (cons 'sessionIds ["s3"])
                    (cons 'createdAt "x") (cons 'updatedAt "x"))))
         (s1 (dsh-protocol-session--from-alist
              (list (cons 'sessionId "s1")
                    (cons 'projections
                          (list (cons 'values (list (cons 'title "Cur")))))
                    (cons 'updatedAt 4000) (cons 'blank :json-false))))
         (s2 (dsh-protocol-session--from-alist
              (list (cons 'sessionId "s2")
                    (cons 'projections
                          (list (cons 'values (list (cons 'title "In W1")))))
                    (cons 'updatedAt 3000) (cons 'blank :json-false))))
         (s3 (dsh-protocol-session--from-alist
              (list (cons 'sessionId "s3")
                    (cons 'projections
                          (list (cons 'values (list (cons 'title "In W2")))))
                    (cons 'updatedAt 2000) (cons 'blank :json-false))))
         (s4 (dsh-protocol-session--from-alist
              (list (cons 'sessionId "s4")
                    (cons 'projections
                          (list (cons 'values (list (cons 'title "Ungrouped")))))
                    (cons 'updatedAt 1000) (cons 'blank :json-false))))
         (s-arch (dsh-protocol-session--from-alist
                  (list (cons 'sessionId "s-arch") (cons 'title "Archived")
                        (cons 'updatedAt 3500) (cons 'blank :json-false))))
         (s-sub (dsh-protocol-session--from-alist
                 (list (cons 'sessionId "s-sub") (cons 'title "Sub")
                       (cons 'origin "subagent") (cons 'updatedAt 3800)
                       (cons 'blank :json-false))))
         (s-blank (dsh-protocol-session--from-alist
                   (list (cons 'sessionId "s-blank") (cons 'title "Blank")
                         (cons 'blank t))))
         (h-arch (make-hash-table :test 'equal))
         (collection nil)
         (opened nil)
         (label-by-title nil))
    (puthash "s-arch" t h-arch)
    (setq dsh-emacs--workspaces (list w1 w2)
          dsh-emacs--sessions (list s1 s2 s3 s4 s-arch s-sub s-blank)
          dsh-emacs--archived-sessions h-arch
          dsh-emacs--current-session "s1")
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt coll &rest _)
                 (setq collection coll)
                 ;; Record each candidate label, pick the first item (most recent activity
                 ;; = s2)
                 (dolist (item (dsh-test-completion-items coll))
                   (when (string-search "In W1" item)
                     (setq label-by-title item)))
                 (car (dsh-test-completion-items coll))))
              ((symbol-function 'dsh-emacs-open-session)
               (lambda (sid) (setq opened sid))))
      (dsh-emacs-switch-session))
    (ert-info ((format "%s" "switch-session-all-spans-workspaces"))
      (should (and (equal opened "s2")
                   ;; Candidates = all visible sessions except the current one (across
                   ;; workspaces + Ungrouped), archived / subagent / blank do not appear;
                   ;; workspace does not participate in the label or filtering.
                   (= (length (dsh-test-completion-items collection)) 3)
                   (equal (mapcar #'substring-no-properties
                                  (dsh-test-completion-items collection))
                          (list "In W1" "In W2" "Ungrouped"))
                   (string-search "In W1" (or label-by-title "")))))))

;; --- Test 112: dsh-emacs-switch-workspace-session prefix argument = all
;; workspaces ---
(ert-deftest dsh-emacs-test-workspace-switch-session-prefix-arg-covers-all-workspaces ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--sessions nil)
         (dsh-emacs--workspaces nil)
         (dsh-emacs--archived-sessions nil)
         (dsh-emacs--current-session nil)
         (w1 (dsh-protocol-workspace--from-alist
              (list (cons 'workspaceId "w1") (cons 'title "WS1")
                    (cons 'path "/tmp/ws1")
                    (cons 'sessionIds ["s1"])
                    (cons 'createdAt "x") (cons 'updatedAt "x"))))
         (w2 (dsh-protocol-workspace--from-alist
              (list (cons 'workspaceId "w2") (cons 'title "WS2")
                    (cons 'path "/tmp/ws2")
                    (cons 'sessionIds ["s2"])
                    (cons 'createdAt "x") (cons 'updatedAt "x"))))
         (s1 (dsh-protocol-session--from-alist
              (list (cons 'sessionId "s1") (cons 'title "Cur")
                    (cons 'updatedAt 2000) (cons 'blank :json-false))))
         (s2 (dsh-protocol-session--from-alist
              (list (cons 'sessionId "s2") (cons 'title "Elsewhere")
                    (cons 'updatedAt 1000) (cons 'blank :json-false))))
         (opened nil))
    (setq dsh-emacs--workspaces (list w1 w2)
          dsh-emacs--sessions (list s1 s2)
          dsh-emacs--archived-sessions nil
          dsh-emacs--current-session "s1")
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt coll &rest _)
                 (car (dsh-test-completion-items coll))))
              ((symbol-function 'dsh-emacs-open-session)
               (lambda (sid) (setq opened sid))))
      ;; C-u C-c C-s: sessions outside the workspace (w2) should also appear
      ;; among the candidates
      (dsh-emacs-switch-workspace-session t))
    (ert-info ((format "%s" "switch-session-prefix-arg-covers-all-workspaces"))
      (should (equal opened "s2")))))

;; --- Test 113: switch-session-all is bound in the chat keymap ---
(ert-deftest dsh-emacs-test-workspace-switch-session-all-keybinding ()
  :tags '(dsh-unit)
  (let ((keys (where-is-internal 'dsh-emacs-switch-session
                                 dsh-emacs-mode-map)))
    (ert-info ((format "%s" "switch-session-all-keybinding"))
      (should (and keys (equal (car keys) (kbd "C-c M-s")))))))

;; --- Test 114: with no candidates at all, the all scope gives a
;; dedicated prompt ---
(ert-deftest dsh-emacs-test-workspace-switch-session-all-no-others-message ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--sessions nil)
        (dsh-emacs--workspaces nil)
        (dsh-emacs--archived-sessions nil)
        (dsh-emacs--current-session nil)
        (s1 (dsh-protocol-session--from-alist
             (list (cons 'sessionId "s1") (cons 'title "Solo")
                   (cons 'blank :json-false))))
        (prompted nil)
        (msgs nil))
    (setq dsh-emacs--workspaces nil
          dsh-emacs--sessions (list s1)
          dsh-emacs--archived-sessions nil
          dsh-emacs--current-session "s1")
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) (setq prompted t) nil))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) msgs))))
      (dsh-emacs-switch-session))
    (ert-info ((format "%s" "switch-session-all-no-others-message"))
      (should (and (not prompted)
                   (member "No other sessions" msgs))))))

;; --- Test 115: switch candidate list bounded on empty input (rg-style
;; consumption, recency first) ---
(ert-deftest dsh-emacs-test-workspace-switch-table-bounds-empty-input ()
  :tags '(dsh-unit)
  (let* ((vec (vconcat (cl-loop for i below 300 collect
                                (cons (format "Session %d title" i)
                                      (format "s-%d" i)))))
         (table (dsh-emacs--switch-table vec 100))
         (items (all-completions "" table)))
    (ert-info ((format "%s" "switch-table-bounds-empty-input"))
      (should (= 100 (length items)))
      (should (equal (car items) "Session 0 title"))
      (should (equal (nth 99 items) "Session 99 title")))))

;; --- Test 116: with input, give the full universe, narrowing does not
;; drop old sessions ---
(ert-deftest dsh-emacs-test-workspace-switch-table-full-universe-on-input ()
  :tags '(dsh-unit)
  (let* ((vec (vconcat (cl-loop for i below 300 collect
                                (cons (format "Session %d title" i)
                                      (format "s-%d" i)))))
         (table (dsh-emacs--switch-table vec 100))
         (all-str (all-completions "Session" table))
         (narrowed (all-completions "Session 25" table)))
    (ert-info ((format "%s" "switch-table-full-universe-on-input"))
      (should (= 300 (length all-str)))
      (should (cl-every (lambda (s)
                          (string-prefix-p "Session 25" s))
                        narrowed))
      (should (> (length narrowed) 0)))))

;; --- Test 117: the chosen label can find the session id back ---
(ert-deftest dsh-emacs-test-workspace-switch-id-table-roundtrip ()
  :tags '(dsh-unit)
  (let* ((vec (vconcat (list (cons "In W1 · WS1" "s1")
                             (cons "Ungrouped" "s2"))))
         (id-table (dsh-emacs--switch-id-table vec)))
    (ert-info ((format "%s" "switch-id-table-roundtrip"))
      (should (equal "s1" (gethash "In W1 · WS1" id-table)))
      (should (equal "s2" (gethash "Ungrouped" id-table))))))

;; --- Test 118: workspace does not participate in filtering, only
;; duplicate titles use workspace for disambiguation ---
(ert-deftest dsh-emacs-test-workspace-switch-labels-workspace-free-filtering ()
  :tags '(dsh-unit)
  (let* ((w1 (dsh-protocol-workspace--from-alist
              (list (cons 'workspaceId "w1") (cons 'title "WS1")
                    (cons 'path "/tmp/ws1")
                    (cons 'sessionIds ["s-uniq" "s-dup1"])
                    (cons 'createdAt "x") (cons 'updatedAt "x"))))
         (w2 (dsh-protocol-workspace--from-alist
              (list (cons 'workspaceId "w2") (cons 'title "WS2")
                    (cons 'path "/tmp/ws2")
                    (cons 'sessionIds ["s-dup2"])
                    (cons 'createdAt "x") (cons 'updatedAt "x"))))
         (dsh-emacs--workspaces (list w1 w2))
         (dsh-emacs--sessions
          (list (dsh-protocol-session--from-alist
                 (list (cons 'sessionId "s-uniq")
                       (cons 'projections
                             (list (cons 'values
                                         (list (cons 'title "Unique one")))))
                       (cons 'blank :json-false)))
                (dsh-protocol-session--from-alist
                 (list (cons 'sessionId "s-dup1")
                       (cons 'projections
                             (list (cons 'values
                                         (list (cons 'title "Shared")))))
                       (cons 'blank :json-false)))
                (dsh-protocol-session--from-alist
                 (list (cons 'sessionId "s-dup2")
                       (cons 'projections
                             (list (cons 'values
                                         (list (cons 'title "Shared")))))
                       (cons 'blank :json-false)))))
         (index (dsh-emacs--sessions-index))
         (ws-idx (dsh-emacs--workspaces-by-session))
         (cache (make-hash-table :test 'equal))
         (ws-label (lambda (wid)
                     (or (gethash wid cache)
                         (puthash wid (dsh-emacs--workspace-label wid) cache))))
         (entries (dsh-emacs--switch-entry-labels
                   dsh-emacs--sessions index ws-idx ws-label))
         (labels (mapcar #'car entries))
         (table (dsh-emacs--switch-table (vconcat entries) 200)))
    (ert-info ((format "%s" "switch-labels-workspace-free-filtering"))
      (should (member "Unique one" labels))
      (should (member "Shared (WS1)" labels))
      (should (member "Shared (WS2)" labels))
      (should (equal "s-uniq" (cdr (assoc "Unique one" entries))))
      (should (equal "s-dup2" (cdr (assoc "Shared (WS2)" entries))))
      (should (null (all-completions "WS1" table)))
      (should (null (all-completions "Workspace" table))))))

(ert-deftest dsh-emacs-test-workspace-control-baseline-distinguishes-missing-cells ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--chat-buffers (make-hash-table :test #'equal))
        (dsh-emacs--subagent-catalogs (make-hash-table :test #'equal))
        (dsh-emacs--sessions-buffer (generate-new-buffer-name " *absent-list*"))
        (goal (dsh-protocol-goal--from-alist
               '((objective . "Keep this goal") (phase . "active"))))
        (items (list (dsh-emacs-test--queue-item "keep" "queued" "Keep this input"))))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "baseline-cells")
      (puthash "baseline-cells" (current-buffer) dsh-emacs--chat-buffers)
      (dsh-emacs-composer-set-goal goal)
      (dsh-emacs-queue-apply (current-buffer) 'old-process items)
      (dsh-emacs-events--host-control-baseline
       'new-process
       '((projections . ((baseline-cells . ((asOfSeq . 7) (values)))))))
      (should (eq goal dsh-emacs--composer-goal))
      (should (eq items dsh-emacs--queue-items))
      (should (eq 'old-process dsh-emacs--queue-process))
      (should (string-match-p "Keep this goal" (buffer-string)))
      (dsh-emacs-events--host-control-baseline
       'new-process
       '((projections . ((baseline-cells
                          . ((asOfSeq . 8)
                             (values . ((goal . nil) (inbox . nil)))))))))
      (should-not dsh-emacs--composer-goal)
      (should-not dsh-emacs--queue-items)
      (should (eq 'new-process dsh-emacs--queue-process))
      (should-not (string-match-p "Keep this goal" (buffer-string))))))

(ert-deftest dsh-emacs-test-workspace-control-baseline-retains-earlier-sessions-on-error ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--chat-buffers (make-hash-table :test #'equal))
         (dsh-emacs--subagent-catalogs (make-hash-table :test #'equal))
         (dsh-emacs--sessions-buffer (generate-new-buffer-name " *absent-list*"))
         (first (dsh-protocol-session--from-alist '((sessionId . "before"))))
         (later (dsh-protocol-session--from-alist '((sessionId . "migration"))))
         (dsh-emacs--sessions (list first later)))
    (should-error
     (dsh-emacs-events--host-control-baseline
      nil
      '((projections
         . ((before . ((asOfSeq . 7) (values . ((title . "Already applied")))))
            (migration . ((kind . "migration-required")
                          (values . ((title . "Must not apply")))))))))
     :type 'dsh-protocol-migration-required)
    (should (equal "Already applied" (dsh-protocol-session-title-value first)))
    (should-not (dsh-protocol-session-title-value later))
    (should (gethash "before" dsh-emacs--subagent-catalogs))
    (should-not (gethash "migration" dsh-emacs--subagent-catalogs))))

;; A host baseline is one UI update, regardless of the number of sessions.
(ert-deftest dsh-emacs-test-workspace-session-baseline-repaints-once-after-all-caches ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--sessions-buffer (generate-new-buffer-name " *dsh-list-batch*"))
         (buffer (get-buffer-create dsh-emacs--sessions-buffer))
         (dsh-emacs--subagent-catalogs (make-hash-table :test #'equal))
         (dsh-emacs--chat-buffers (make-hash-table :test #'equal))
         (dsh-emacs--workspaces nil)
         (dsh-emacs--archived-sessions nil)
         (dsh-emacs--current-session nil)
         (dsh-emacs--sessions
          (cl-loop for i below 32 collect
                   (dsh-protocol-session--from-alist
                    `((sessionId . ,(format "batch-%d" i))))))
         (baseline
          `((projections .
                         ,(cl-loop for i below 32 collect
                                   (cons (intern (format "batch-%d" i))
                                         `((asOfSeq . 1)
                                           (values (subagentCatalog . [])
                                                   (title . ,(format "Title %d" i)))))))))
         (apply-subagents (symbol-function 'dsh-emacs-subagent-apply))
         batches snapshots)
    (unwind-protect
        (with-current-buffer buffer
          (setq major-mode 'dsh-emacs-session-mode)
          (cl-letf (((symbol-function 'dsh-emacs-subagent-apply)
                     (lambda (session cells)
                       (push (cons session (mapcar #'dsh-protocol-subagent-cell-key
                                                  cells))
                             batches)
                       (funcall apply-subagents session cells)))
                    ((symbol-function 'dsh-emacs-session--render)
                     (lambda ()
                       (push (list (hash-table-count dsh-emacs--subagent-catalogs)
                                   (dsh-protocol-session-title-value
                                    (car (last dsh-emacs--sessions))))
                             snapshots))))
            (dsh-emacs-events--host-control-baseline nil baseline)
            (should (equal (nreverse batches)
                           (cl-loop for i below 32 collect
                                    (list (format "batch-%d" i)
                                          'subagentCatalog 'subagent
                                          'subagentTiming 'tokenUsage))))
            (ert-info ((format "%s" "session-baseline-repaints-once-after-all-caches"))
              (should (equal snapshots '((32 "Title 31")))))
            (setq snapshots nil)
            (dsh-emacs-events--apply-title nil "batch-31" "Live title")
            (ert-info ((format "%s" "session-title-increment-still-repaints-immediately"))
              (should (equal snapshots '((32 "Live title")))))
            (setq snapshots nil)
            (dsh-emacs-subagent-apply
             "new-parent"
             (dsh-protocol-subagent-baseline--from-alist
              '((asOfSeq . 2) (values (subagentCatalog . [])))))
            (ert-info ((format "%s" "session-catalog-increment-still-repaints-immediately"))
              (should (equal snapshots '((33 "Live title"))))))
          (dsh-emacs-session--render)
          (goto-char (dsh-emacs-session--row-pos 'dsh-emacs-session-id "batch-0"))
          (let ((departure (point-marker))
                (diff (symbol-function 'replace-buffer-contents))
                (diffs 0))
            ;; Equal text can still carry stale command targets; refresh props.
            (let ((inhibit-read-only t))
              (put-text-property (point) (1+ (point))
                                 'dsh-emacs-subagent 'stale))
            (cl-letf (((symbol-function 'replace-buffer-contents)
                       (lambda (&rest args)
                         (cl-incf diffs)
                         (apply diff args))))
              (dsh-emacs-session--render))
            (ert-info ((format "%s" "session-unchanged-text-skips-diff-keeps-current-metadata"))
              (should (= diffs 0))
              (should (equal (get-text-property departure 'dsh-emacs-session-id)
                             "batch-0"))
              (should (null (get-text-property departure 'dsh-emacs-subagent))))
            (set-marker departure nil)))
      (kill-buffer buffer))))

(provide 'dsh-test-workspace)
;;; dsh-test-workspace.el ends here
