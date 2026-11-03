;;; dsh-test-model-selection.el --- Model selection tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)

(defvar vertico-mode)
(defvar vertico-group-format)

;; --- Test 47: model catalog expansion + sorting + selectModel call ---
(ert-deftest dsh-emacs-test-model-selection-model-candidates-flattened ()
  :tags '(dsh-unit)
  (let* ((g1 '((id . "g1") (name . "DeepSeek")
               (models . [((id . "m1") (name . "Model One"))
                          ((id . "m2"))])))
         (g2 '((id . "g2") (name . "qwen-token-plan")
               (models . [((id . "m3") (name . "Qwen-M"))])))
         (directory (dsh-protocol-model-directory--from-alist
                     `((groups . [,g1 ,g2]))))
         (cands (dsh-emacs--model-candidates directory)))
    ;; Each entry carries (id provider group name), where provider is the id of the
    ;; owning group; the list sorts by provider name + model id (m1 < m2 within a
    ;; group, group names case-insensitive)
    (ert-info ((format "%s" "model-candidates-flattened"))
      (should (equal cands '(("m1" "g1" "DeepSeek" "Model One" nil)
                             ("m2" "g1" "DeepSeek" "m2" nil)
                             ("m3" "g2" "qwen-token-plan" "Qwen-M" nil)))))))

;; Sorting: groups out of order + entries out of order → lexicographic order by
;; provider name + model id (case-insensitive)
(ert-deftest dsh-emacs-test-model-selection-model-candidates-sorted-provider-then-name ()
  :tags '(dsh-unit)
  (let* ((g1 '((id . "g1") (name . "Zeta")
               (models . [((id . "m1") (name . "beta"))
                          ((id . "m2") (name . "Alpha"))])))
         (g2 '((id . "g2") (name . "Alpha-Group")
               (models . [((id . "m3") (name . "gamma"))])))
         (directory (dsh-protocol-model-directory--from-alist
                     `((groups . [,g1 ,g2]))))
         (cands (dsh-emacs--model-candidates directory)))
    (ert-info ((format "%s" "model-candidates-sorted-provider-then-name"))
      (should (equal cands '(("m3" "g2" "Alpha-Group" "gamma" nil)
                             ("m1" "g1" "Zeta" "beta" nil)
                             ("m2" "g1" "Zeta" "Alpha" nil)))))))

(ert-deftest dsh-emacs-test-model-selection-select-model-sends-selectmodel ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--current-session nil)
        (buf (generate-new-buffer " *dsh-model-test*"))
        (calls nil))
    (unwind-protect
        (with-current-buffer buf
          (setq dsh-emacs--current-session "sess-m")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (when (string= method "session/modelCatalog")
                         (funcall cb
                                  t
                                  '((current . ((provider . "p1") (model . "m0")))
                                    (groups . [((id . "g1") (name . "DeepSeek")
                                                (models . [((id . "m1")
                                                            (name . "Model One"))]))]))))))
                    ((symbol-function 'completing-read)
                     ;; The key the user selects is the model row's full key (with the
                     ;; embedded
                     ;; provider, shaped like "m1 [g1|DeepSeek]"; invisible when rendered
                     ;; through
                     ;; the display property)
                     (lambda (&rest _)
                       "m1 [g1|DeepSeek]")))
            (dsh-emacs-select-model)
            (let* ((call (car calls))
                   (params (cadr call)))
              (ert-info ((format "%s" "select-model-sends-selectModel"))
                (should (and (string= "session/selectModel" (car call))
                             (string= "m1" (cdr (assq 'model (cdr (assq 'request params)))))
                             (string= "g1" (cdr (assq 'provider (cdr (assq 'request params)))))
                             (string= "sess-m" (cdr (assq 'sessionId
                                                          (cdr (assq 'request params)))))))))))
      (kill-buffer buf))))

;; --- Test 47b: C-g in select-model cancels cleanly (the quit must not leak
;; into the process filter) ---
(ert-deftest dsh-emacs-test-model-selection-select-model-c-g-aborts-cleanly ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--current-session nil)
        (buf (generate-new-buffer " *dsh-model-quit-test*"))
        (leaked nil))
    (unwind-protect
        (with-current-buffer buf
          (setq dsh-emacs--current-session "sess-q")
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _) (signal 'quit nil))))
            (condition-case err
                (dsh-emacs--select-model-prompt
                 "sess-q"
                 '((current . ((provider . "p1") (model . "m0")))
                   (groups . [((id . "g1") (name . "DeepSeek")
                               (models . [((id . "m1") (name . "Model One"))]))])))
              (quit (setq leaked t)))))
      (kill-buffer buf))
    (ert-info ((format "%s" "select-model-c-g-aborts-cleanly"))
      (should (not leaked)))))

;; --- Test 47c: neither an empty RET nor unknown input may trigger selectModel
;; (the implementation no longer passes DEF) ---
;; Empty RET ("") → keep the current model: no selectModel is sent, message
;; "Kept ..."
(ert-deftest dsh-emacs-test-model-selection-select-model-empty-pick-keeps-current ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--current-session nil)
        (buf (generate-new-buffer " *dsh-model-empty-test*"))
        (calls nil)
        (msgs nil))
    (unwind-protect
        (with-current-buffer buf
          (setq dsh-emacs--current-session "sess-e")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (when (string= method "session/modelCatalog")
                         (funcall
                          cb t
                          '((current . ((provider . "g1") (model . "m1")))
                            (groups . [((id . "g1") (name . "DeepSeek")
                                        (models . [((id . "m1")
                                                    (name . "Model One"))]))]))))))
                    ((symbol-function 'completing-read)
                     (lambda (&rest _) ""))
                    ((symbol-function 'message)
                     (lambda (fmt &rest args)
                       (push (apply #'format fmt args) msgs))))
            (dsh-emacs-select-model)
            (let ((methods (mapcar #'car calls)))
              (ert-info ((format "%s" "select-model-empty-pick-keeps-current"))
                (should (and (member "session/modelCatalog" methods)
                             (not (member "session/selectModel" methods))
                             (cl-some (lambda (m) (string-prefix-p "Kept" m))
                                      msgs)))))))
      (kill-buffer buf))))

;; Unknown string → rejected: no selectModel is sent, message "Unknown model"
(ert-deftest dsh-emacs-test-model-selection-select-model-unknown-pick-rejected ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--current-session nil)
        (buf (generate-new-buffer " *dsh-model-unknown-test*"))
        (calls nil)
        (msgs nil))
    (unwind-protect
        (with-current-buffer buf
          (setq dsh-emacs--current-session "sess-u")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (when (string= method "session/modelCatalog")
                         (funcall
                          cb t
                          '((current . ((provider . "g1") (model . "m1")))
                            (groups . [((id . "g1") (name . "DeepSeek")
                                        (models . [((id . "m1")
                                                    (name . "Model One"))]))]))))))
                    ((symbol-function 'completing-read)
                     (lambda (&rest _) "bogus"))
                    ((symbol-function 'message)
                     (lambda (fmt &rest args)
                       (push (apply #'format fmt args) msgs))))
            (dsh-emacs-select-model)
            (let ((methods (mapcar #'car calls)))
              (ert-info ((format "%s" "select-model-unknown-pick-rejected"))
                (should (and (member "session/modelCatalog" methods)
                             (not (member "session/selectModel" methods))
                             (cl-some (lambda (m) (string-prefix-p "Unknown" m))
                                      msgs)))))))
      (kill-buffer buf))))

;; --- Test 47d: the picker's current comes from the session modelSelection
;; projection, not the catalog default ---
;; Regression: modelCatalog is session-independent and its current/default is
;; the host default; the model the session actually runs is in the cached row's
;; modelSelection.lastUsed projection (the same authoritative source as the
;; mode-line). The picker's "current" prompt and the "Kept current model" of an
;; empty RET must use the projection value (here the catalog default is m0 and
;; the projection is m9), otherwise the prompt disagrees with the model really
;; running.
(ert-deftest dsh-emacs-test-model-selection-select-model-current-from-session-projection ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--current-session nil)
         (old-sessions dsh-emacs--sessions)
         (buf (get-buffer-create " *dsh-model-proj-test*"))
         (calls nil)
         (msgs nil)
         (prompts nil)
         (item (dsh-protocol-session--from-alist
                '((sessionId . "sess-proj")
                  (projections . ((values
                                   . ((modelSelection
                                       . ((lastUsed
                                           . ((provider . "g1")
                                              (model . "m9")))))))))))))
    (unwind-protect
        (with-current-buffer buf
          (setq dsh-emacs--current-session "sess-proj")
          (setq dsh-emacs--sessions (list item))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (when (string= method "session/modelCatalog")
                         (funcall
                          cb t
                          '((current . ((provider . "g1") (model . "m0")))
                            (groups . [((id . "g1") (name . "DeepSeek")
                                        (models . [((id . "m0") (name . "m0"))
                                                   ((id . "m1") (name . "Model One"))
                                                   ((id . "m9") (name . "m9"))]))]))))))
                    ((symbol-function 'completing-read)
                     (lambda (prompt &rest _)
                       (push prompt prompts)
                       ""))
                    ((symbol-function 'message)
                     (lambda (fmt &rest args)
                       (push (apply #'format fmt args) msgs))))
            (dsh-emacs-select-model)
            (let ((has-m9 (cl-some (lambda (p) (string-match-p "(current DeepSeek/m9)" p)) prompts))
                  (has-m0 (cl-some (lambda (p) (string-match-p "(current DeepSeek/m0)" p)) prompts))
                  (kept-m9 (cl-some (lambda (m) (string-match-p "Kept current model m9" m)) msgs)))
              (ert-info ((format "%s" "select-model-current-from-session-projection"))
                (should (and has-m9 (not has-m0) kept-m9))))))
      (setq dsh-emacs--sessions old-sessions)
      (kill-buffer buf))))

;; --- Test 47e: each provider shows once and its models are indented under it
;; (grouped display) ---
;; Row key = "id [provider-id|Provider Name]": the key embeds the provider id
;; and display name, so the same id across providers (m2 under Qwen and
;; Anthropic) yields two unique rows and an exact assoc hit; the key starts with
;; the id (prefix filtering works); when rendered the display property hides
;; [provider|Name] so the list only shows "  id" (prefix input still matches).
(ert-deftest dsh-emacs-test-model-selection-model-entries-groups-by-provider ()
  :tags '(dsh-unit)
  (let* ((cands '(("m1" "g1" "DeepSeek" "Model One")
                  ("m2b" "g1" "DeepSeek" "Model Two")
                  ("m0" "g2" "Qwen" "m0")
                  ("m2" "g2" "Qwen" "Qwen-M")
                  ("m2" "g3" "Anthropic" "Same-M")))
         (entries (dsh-emacs--model-entries cands))
         (key (lambda (id provider name) (format "%s [%s|%s]" id provider name)))
         (expect `(("DeepSeek" :header . "DeepSeek")
                   (,(funcall key "m1" "g1" "DeepSeek") . ("m1" "g1" "DeepSeek" "Model One"))
                   (,(funcall key "m2b" "g1" "DeepSeek") . ("m2b" "g1" "DeepSeek" "Model Two"))
                   ("Qwen" :header . "Qwen")
                   (,(funcall key "m0" "g2" "Qwen") . ("m0" "g2" "Qwen" "m0"))
                   (,(funcall key "m2" "g2" "Qwen") . ("m2" "g2" "Qwen" "Qwen-M"))
                   ("Anthropic" :header . "Anthropic")
                   (,(funcall key "m2" "g3" "Anthropic") . ("m2" "g3" "Anthropic" "Same-M"))))
         ;; Rendering: a unique id stays a bare "  id"; a duplicate id (same id across
         ;; providers) shows the provider name, because filtering drops the group header
         ;; and bare-id rows would be indistinguishable
         (shown (mapcar (lambda (e)
                          (if (eq :header (car (cdr e)))
                              (car e)
                            (get-text-property 0 'display (car e))))
                        entries))
         (shown-expect (list "DeepSeek" "  m1" "  m2b" "Qwen" "  m0"
                             "  m2 (Qwen)" "Anthropic" "  m2 (Anthropic)")))
    (ert-info ((format "%s" "model-entries-groups-by-provider"))
      (should (and (equal entries expect)
                   (equal shown shown-expect)
                   ;; All model row keys are unique → the key returned by completion is
                   ;; unambiguous
                   (= (length entries)
                      (length (cl-remove-duplicates (mapcar #'car entries)))))))))

;; --- Test 47e: selecting a provider header row → message instead of a switch
;; (no selectModel) ---
(ert-deftest dsh-emacs-test-model-selection-select-model-header-pick-rejected ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--current-session nil)
        (buf (generate-new-buffer " *dsh-model-header-test*"))
        (calls nil))
    (unwind-protect
        (with-current-buffer buf
          (setq dsh-emacs--current-session "sess-h")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (when (string= method "session/modelCatalog")
                         (funcall cb
                                  t
                                  '((current . ((provider . "g1") (model . "m1")))
                                    (groups . [((id . "g1") (name . "DeepSeek")
                                                (models . [((id . "m1")
                                                            (name . "Model One"))]))]))))))
                    ((symbol-function 'completing-read)
                     (lambda (&rest _) "DeepSeek")))
            (dsh-emacs-select-model)
            (let ((methods (mapcar #'car calls)))
              (ert-info ((format "%s" "select-model-header-pick-rejected"))
                (should (and (member "session/modelCatalog" methods)
                             (not (member "session/selectModel" methods))))))))
      (kill-buffer buf))))

;; --- Test 47f: same id under several providers → the key embeds the provider,
;; so the selected row is the right provider ---
;; Row key = "m2 [g2|Qwen]" (invisible under the display property, the list
;; still shows "  m2"). The key returned by completing-read is the row the
;; user selected, and assoc hits the correct payload directly: choosing the Qwen
;; row → provider g2 and confirmation message "Dup-2 (Qwen)"; one selection
;; throughout, no second confirmation.
(ert-deftest dsh-emacs-test-model-selection-select-model-dup-id-picks-own-provider ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--current-session nil)
        (buf (generate-new-buffer " *dsh-model-dup-test*"))
        (calls nil)
        (msgs nil)
        (cr-count 0))
    (unwind-protect
        (with-current-buffer buf
          (setq dsh-emacs--current-session "sess-d")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       ;; After a successful model switch the product follows with a
                       ;; session/list
                       ;; refresh (fetching the new model's contextPressure snapshot); it
                       ;; does not go
                       ;; into the calls used by the assertions, otherwise (car calls) would
                       ;; no longer
                       ;; point at selectModel.
                       (unless (string= method "session/list")
                         (push (list method params) calls))
                       (cond
                        ((string= method "session/modelCatalog")
                         (funcall
                          cb t
                          '((current . ((provider . "g1") (model . "m1")))
                            (groups . [((id . "g1") (name . "DeepSeek")
                                        (models . [((id . "m2")
                                                    (name . "Dup-1"))]))
                                       ((id . "g2") (name . "Qwen")
                                        (models . [((id . "m2")
                                                    (name . "Dup-2"))]))]))))
                        ((string= method "session/selectModel")
                         ;; The success callback triggers the confirmation message ("Model
                         ;; switched to
                         ;; ...")
                         (funcall cb t nil)))))
                    ;; The user picked the Qwen row: return that row's full key (with the
                    ;; hidden
                    ;; provider)
                    ((symbol-function 'completing-read)
                     (lambda (&rest _)
                       (setq cr-count (1+ cr-count))
                       "m2 [g2|Qwen]"))
                    ((symbol-function 'message)
                     (lambda (fmt &rest args)
                       (push (apply #'format fmt args) msgs))))
            (dsh-emacs-select-model)
            (let* ((call (car calls))
                   (params (cadr call)))
              (ert-info ((format "%s" "select-model-dup-id-picks-own-provider"))
                (should (and (string= "session/selectModel" (car call))
                             (string= "m2" (cdr (assq 'model (cdr (assq 'request params)))))
                             (string= "g2" (cdr (assq 'provider (cdr (assq 'request params)))))
                             (= 1 cr-count)
                             (cl-some (lambda (m)
                                        (string-match-p (regexp-quote "Dup-2 (Qwen)") m))
                                      msgs)))))))
      (kill-buffer buf))))

;; Pick the DeepSeek row (key "m2 [g1|DeepSeek]") → provider is g1 and the
;; confirmation message shows Dup-1
(ert-deftest dsh-emacs-test-model-selection-select-model-dup-id-other-row-its-provider ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--current-session nil)
        (buf (generate-new-buffer " *dsh-model-dup2*"))
        (calls nil)
        (msgs nil))
    (unwind-protect
        (with-current-buffer buf
          (setq dsh-emacs--current-session "sess-d2")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (unless (string= method "session/list")
                         (push (list method params) calls))
                       (cond
                        ((string= method "session/modelCatalog")
                         (funcall
                          cb t
                          '((current . ((provider . "g1") (model . "m1")))
                            (groups . [((id . "g1") (name . "DeepSeek")
                                        (models . [((id . "m2")
                                                    (name . "Dup-1"))]))
                                       ((id . "g2") (name . "Qwen")
                                        (models . [((id . "m2")
                                                    (name . "Dup-2"))]))]))))
                        ((string= method "session/selectModel")
                         (funcall cb t nil)))))
                    ;; The user picked the DeepSeek row
                    ((symbol-function 'completing-read)
                     (lambda (&rest _) "m2 [g1|DeepSeek]"))
                    ((symbol-function 'message)
                     (lambda (fmt &rest args)
                       (push (apply #'format fmt args) msgs))))
            (dsh-emacs-select-model)
            (let* ((call (car calls))
                   (params (cadr call)))
              (ert-info ((format "%s" "select-model-dup-id-other-row-its-provider"))
                (should (and (string= "session/selectModel" (car call))
                             (string= "g1" (cdr (assq 'provider (cdr (assq 'request params)))))
                             (cl-some (lambda (m)
                                        (string-match-p (regexp-quote "Dup-1 (DeepSeek)") m))
                                      msgs)))))))
      (kill-buffer buf))))

;; --- Test 47g: vertico-group path → grouping is kept by group-function
;; metadata ---
;; Candidates are bare model rows (no :header candidates) and the row key
;; "  id [provider]" renders a bare id; the group-function metadata maps the
;; key back to the provider display name — so while filtering the framework
;; keeps each provider's group header. assoc still hits the selected row
;; exactly.
(ert-deftest dsh-emacs-test-model-selection-model-grouped-collection-keeps-group-metadata ()
  :tags '(dsh-unit)
  (let* ((cands '(("m1" "g1" "DeepSeek" "Model One")
                  ("m2" "g2" "Qwen" "Qwen-M")
                  ("m2" "g3" "Anthropic" "Same")))
         (pair (dsh-emacs--model-grouped-collection cands))
         (rows (cdr pair))
         (md (funcall (car pair) "" nil 'metadata))
         (gf (alist-get 'group-function (cdr md))))
    (ert-info ((format "%s" "model-grouped-collection-keeps-group-metadata"))
      (should (and (eq 'dsh-model (alist-get 'category (cdr md)))
                   (= 3 (length rows))
                   (cl-every (lambda (e) (not (eq :header (car (cdr e))))) rows)
                   (string= "DeepSeek" (funcall gf "m1 [g1|DeepSeek]" nil))
                   (string= "Qwen" (funcall gf "m2 [g2|Qwen]" nil))
                   (string= "Anthropic" (funcall gf "m2 [g3|Anthropic]" nil))

                   ;; transform returns the visible string (id prefix + migrated match
                   ;; highlight)
                   ;; for vertico to render
                   (string= "m2" (substring-no-properties
                                  (funcall gf "m2 [g2|Qwen]" t)))
                   (string= "  m2" (get-text-property 0 'display (car (nth 1 rows))))
                   (string= "  m2" (get-text-property 0 'display (car (nth 2 rows)))))))))

;; --- Test 47h: the completion-table-with-metadata compatibility shim ---
;; Session/model pickers, ask multi-select and @ references all hand sort
;; metadata to the completion frontend through this table.  The built-in is
;; Emacs 31-only, so the 28.1 baseline must take the local fallback branch
;; with identical behavior: answer metadata verbatim, complete normally for
;; every other ACTION.  Removing the built-in forces that branch, which
;; otherwise never runs on Emacs 31.
(ert-deftest dsh-emacs-test-model-selection-completion-table-metadata-fallback ()
  :tags '(dsh-unit)
  (let ((saved (and (fboundp 'completion-table-with-metadata)
                    (symbol-function 'completion-table-with-metadata))))
    (unwind-protect
        (progn
          (when saved (fmakunbound 'completion-table-with-metadata))
          (let ((table (dsh-emacs-ui--completion-table-with-metadata
                        '("alpha" "beta" "gamma")
                        '((display-sort-function . identity)
                          (cycle-sort-function . identity)
                          (category . dsh-test)))))
            (ert-info ((format "%s" "completion-table-metadata-fallback"))
              (should (equal '(metadata (display-sort-function . identity)
                                        (cycle-sort-function . identity)
                                        (category . dsh-test))
                             (funcall table "" nil 'metadata)))
              (should (eq #'identity
                          (completion-metadata-get
                           (completion-metadata "" table nil) 'display-sort-function)))
              (should (eq 'dsh-test
                          (completion-metadata-get
                           (completion-metadata "" table nil) 'category)))
              (should (equal '("alpha" "beta" "gamma") (all-completions "" table nil)))
              (should (equal "alpha" (try-completion "a" table nil)))
              (should (equal '("beta") (all-completions "b" table nil))))))
      (when saved (fset 'completion-table-with-metadata saved)))))

;; 47g2: modern vertico (native group-function metadata support, no
;; vertico-group-mode) → takes the grouped path and the selected row is the
;; right provider
(ert-deftest dsh-emacs-test-model-selection-model-grouped-pick-exact-provider ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--current-session nil)
        (buf (generate-new-buffer " *dsh-model-grouped*"))
        (calls nil)
        (msgs nil))
    (unwind-protect
        (with-current-buffer buf
          (setq dsh-emacs--current-session "sess-g")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (unless (string= method "session/list")
                         (push (list method params) calls))
                       (cond
                        ((string= method "session/modelCatalog")
                         (funcall
                          cb t
                          '((current . ((provider . "g1") (model . "m1")))
                            (groups . [((id . "g1") (name . "DeepSeek")
                                        (models . [((id . "m2")
                                                    (name . "Dup-1"))]))
                                       ((id . "g2") (name . "Qwen")
                                        (models . [((id . "m2")
                                                    (name . "Dup-2"))]))]))))
                        ((string= method "session/selectModel")
                         (funcall cb t nil)))))
                    ((symbol-function 'completing-read)
                     (lambda (&rest _) "m2 [g2|Qwen]"))
                    ((symbol-function 'message)
                     (lambda (fmt &rest args)
                       (push (apply #'format fmt args) msgs))))
            (let ((vertico-mode t) (vertico-group-format "%s"))
              (dsh-emacs-select-model))
            (let* ((call (car calls))
                   (params (cadr call)))
              (ert-info ((format "%s" "model-grouped-pick-exact-provider"))
                (should (and (string= "session/selectModel" (car call))
                             (string= "g2" (cdr (assq 'provider (cdr (assq 'request params)))))
                             (cl-some (lambda (m)
                                        (string-match-p (regexp-quote "Dup-2 (Qwen)") m))
                                      msgs)))))))
      (kill-buffer buf))))

;; --- Test 47h: the key starts with the id → filtering still matches in the
;; default prefix-completion style ---
;; Key = "m2 [g2|Qwen]" (no leading space): in basic (prefix) style "m2"
;; matches; the key embeds the provider display name so substring style also
;; matches "qwen"; the display property still hides [provider|Name] and renders
;; "  m2".
(ert-deftest dsh-emacs-test-model-selection-model-row-prefix-filterable ()
  :tags '(dsh-unit)
  (let* ((cands '(("m2" "g2" "Qwen" "Qwen-M")
                  ("m2" "g3" "Anthropic" "Same")))
         (rows (mapcar (lambda (c) (dsh-emacs--model-row-entry c nil)) cands))
         (raw0 (substring-no-properties (car (nth 0 rows))))
         (raw1 (substring-no-properties (car (nth 1 rows)))))
    (ert-info ((format "%s" "model-row-prefix-filterable"))
      (should (and (string-prefix-p "m2" raw0)
                   (string-match-p (regexp-quote "Qwen") raw0)
                   (string= "  m2" (get-text-property 0 'display (car (nth 0 rows))))
                   (string-prefix-p "m2" raw1)
                   (string-match-p (regexp-quote "Anthropic") raw1)
                   ;; All keys are unique → assoc hits unambiguously
                   (= 2 (length (cl-remove-duplicates (mapcar #'car rows)))))))))

;; --- Test 47i: locally style the vertico group header inside the picker (the
;; long separator is dropped by default) ---
(ert-deftest dsh-emacs-test-model-selection-model-select-local-group-format ()
  :tags '(dsh-unit)
  (let ((vertico-group-format "GLOBAL-FORMAT"))
    (let ((buf (generate-new-buffer " *dsh-group-fmt*")))
      (unwind-protect
          (with-current-buffer buf
            (dsh-emacs--model-select-setup-hook t)
            (ert-info ((format "%s" "model-select-local-group-format"))
              (should (and (equal (buffer-local-value 'vertico-group-format buf)
                                  dsh-emacs-model-group-format)
                           ;; The global default is not polluted
                           (string= "GLOBAL-FORMAT"
                                    (default-value 'vertico-group-format))
                           ;; The default format contains a %s placeholder
                           (string-match-p "%s" dsh-emacs-model-group-format)))))
        (kill-buffer buf)))
    ;; When grouped is nil (no grouping UI) vertico-group-format is left alone
    (let ((buf (generate-new-buffer " *dsh-group-fmt2*")))
      (unwind-protect
          (with-current-buffer buf
            (dsh-emacs--model-select-setup-hook nil)
            (ert-info ((format "%s" "model-select-nongrouped-leaves-format"))
              (should-not (assq 'vertico-group-format (buffer-local-variables buf)))))
        (kill-buffer buf)))))

;; --- Test 47j: transform moves the match highlight to the id area of the
;; display string, so the row only highlights the id ---
;; Key = "m2 [g2|Qwen]" (display hides the [provider] part); with input "m2",
;; orderless/basic puts completion-match-face on the key's head [0,2). transform
;; returns "  m2" (no display property, the face lands on [2,4), the id area) —
;; neither a full-row background nor a lost highlight; assoc still hits by the
;; original key.
(ert-deftest dsh-emacs-test-model-selection-model-grouped-transform-keeps-id-highlight ()
  :tags '(dsh-unit)
  (let* ((pair (dsh-emacs--model-grouped-collection
                '(("m2" "g2" "Qwen" "Qwen-M"))))
         (md (funcall (car pair) "" nil 'metadata))
         (gf (alist-get 'group-function (cdr md)))
         (key (caar (cdr pair)))
         ;; Simulate the orderless/basic match highlight: the match area is at the key's
         ;; head ("m2")
         (hl (copy-sequence key))
         (shown (progn (add-face-text-property 0 2 'completion-match-face t hl)
                       (funcall gf hl t))))
    (ert-info ((format "%s" "model-grouped-transform-keeps-id-highlight"))
      (should (and (string= "m2" (substring-no-properties shown))
                   ;; The highlight moves to the id area [0,2) (no leading space)
                   (get-text-property 0 'face shown)
                   (null (get-text-property 2 'face shown))
                   ;; The display text itself carries the display, no longer relying on a hidden
                   ;; part
                   (null (get-text-property 0 'display shown))
                   ;; assoc still hits the original key (with properties)
                   (assoc hl (cdr pair)))))))

;; --- Test 47k: category=dsh-model + identity affixation ---
;; nerd-icons-completion inserts an icon at the head of a candidate row (nil
;; category → right arrow); declaring category as a private symbol → the icon
;; table has no entry → empty string, clean row head;
;; --- Test 47k: metadata carries identity affixation → third-party annotation
;; injection is blocked ---
;; marginalia/cape and friends inject an affixation-function through metadata
;; advice and add an annotation at the end of the row (commonly "->"); we
;; declare identity affixation with no prefix/suffix in the metadata, and
;; vertico--affixate prefers it, so the row stays clean.
(ert-deftest dsh-emacs-test-model-selection-model-grouped-empty-affixation-blocks-annotations ()
  :tags '(dsh-unit)
  (let* ((pair (dsh-emacs--model-grouped-collection
                '(("m1" "g1" "DeepSeek" "Model One")
                  ("m2" "g2" "Qwen" "Qwen-M"))))
         (md (funcall (car pair) "" nil 'metadata))
         (aff (alist-get 'affixation-function (cdr md)))
         ;; Simulate third-party injection: some affixation that adds a suffix comes
         ;; first
         (rows (funcall aff '("m1 [g1|DeepSeek]" "m2 [g2|Qwen]"))))
    (ert-info ((format "%s" "model-grouped-empty-affixation-blocks-annotations"))
      (should (and aff
                   ;; Every row has an empty prefix and suffix
                   (cl-every (lambda (r) (and (string= "" (nth 1 r))
                                              (string= "" (nth 2 r))))
                             rows)
                   (= 2 (length rows))
                   (string= "m1 [g1|DeepSeek]" (car (nth 0 rows))))))))

;; --- Test 47l: effort catalog parsing + default precedence ---
(ert-deftest dsh-emacs-test-model-selection-model-effort-choices-parses-options ()
  :tags '(dsh-unit)
  (let* ((reasoning '((efforts . [((id . "off") (name . "Off"))
                                  ((id . "high") (name . "High"))
                                  ((id . "max") (name . "Max"))])
                      (defaultEffort . "high")))
         (choices (dsh-emacs--model-effort-choices reasoning)))
    (ert-info ((format "%s" "model-effort-choices-parses-options"))
      (should (equal choices '(("Off" . "off")
                               ("High" . "high")
                               ("Max" . "max")))))))

(ert-deftest dsh-emacs-test-model-selection-model-effort-default-priority ()
  :tags '(dsh-unit)
  (let* ((reasoning '((efforts . [((id . "off") (name . "Off"))
                                  ((id . "high") (name . "High"))
                                  ((id . "max") (name . "Max"))])
                      (defaultEffort . "high")))
         (prefer (dsh-emacs--model-effort-default-id reasoning "max"))
         (default (dsh-emacs--model-effort-default-id reasoning nil))
         (bogus (dsh-emacs--model-effort-default-id reasoning "low")))
    (ert-info ((format "%s" "model-effort-default-priority"))
      (should (and (string= "max" prefer)      ;; The current effort is valid → keep it
                   (string= "high" default)     ;; Otherwise defaultEffort
                   (string= "high" bogus))))))

;; An effort entry with no display name → fall back to showing the id
(ert-deftest dsh-emacs-test-model-selection-model-effort-choice-name-falls-back-to-id ()
  :tags '(dsh-unit)
  (let* ((reasoning '((efforts . [((id . "t0"))])))
         (choices (dsh-emacs--model-effort-choices reasoning)))
    (ert-info ((format "%s" "model-effort-choice-name-falls-back-to-id"))
      (should (equal choices '(("t0" . "t0")))))))

;; --- Test 47m: selectModel carries reasoningEffort ---
;; Helper: simulate one round of model selection (completing-read is given
;; PICK2 on the second prompt) and returns reasoningEffort from the selectModel
;; request (:no-call when no request was sent)
(defun dsh-emacs-test--model-effort-run (dir pick2)
  (let ((dsh-emacs--current-session nil)
        (buf (generate-new-buffer " *dsh-effort-*"))
        (calls nil)
        (cr-n 0))
    (unwind-protect
        (with-current-buffer buf
          (setq dsh-emacs--current-session "sess-t")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (unless (string= method "session/list")
                         (push (list method params) calls)
                         ;; After a successful model switch a session/list refresh follows
                         ;; (fetching the
                         ;; new model's contextPressure snapshot): it is outside this
                         ;; test's assertions,
                         ;; so it neither goes into calls nor invokes the callback (the
                         ;; callback would
                         ;; empty the session cache and pollute the global state of later
                         ;; tests).
                         (funcall cb t
                                  (if (string= method "session/modelCatalog")
                                      dir
                                    '((selected . ((provider . "p1")
                                                   (model . "m1"))))))))))
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (&rest _)
                         (setq cr-n (1+ cr-n))
                         (if (eq cr-n 1) "m1 [g1|DeepSeek]" pick2))))
              (dsh-emacs-select-model)
              (let* ((call (car calls))
                     (params (cadr call)))
                (if (and (string= "session/selectModel" (car call))
                         (string= "m1" (cdr (assq 'model (cdr (assq 'request params))))))
                    (cdr (assq 'reasoningEffort (cdr (assq 'request params))))
                  :no-call)))))
      (kill-buffer buf))))

;; Target model has reasoning: picking Max manually on the second level
;; (different from the default High) → pass max
(ert-deftest dsh-emacs-test-model-selection-select-model-sends-reasoning-effort ()
  :tags '(dsh-unit)
  (let* ((dir '((current . ((provider . "p1") (model . "m0")))
                (groups . [((id . "g1") (name . "DeepSeek")
                            (models . [((id . "m1") (name . "One")
                                        (reasoning . ((efforts . [((id . "off") (name . "Off"))
                                                                  ((id . "high") (name . "High"))
                                                                  ((id . "max") (name . "Max"))])
                                                      (defaultEffort . "high"))))]))])))
         (eff (dsh-emacs-test--model-effort-run dir "Max")))
    (ert-info ((format "%s" "select-model-sends-reasoning-effort"))
      (should (string= "max" eff)))))

;; Empty input (RET) → completing-read returns the default → pass the default
;; effort (defaultEffort)
(ert-deftest dsh-emacs-test-model-selection-select-model-empty-effort-pick-default ()
  :tags '(dsh-unit)
  (let* ((dir '((current . ((provider . "p1") (model . "m0")))
                (groups . [((id . "g1") (name . "DeepSeek")
                            (models . [((id . "m1") (name . "One")
                                        (reasoning . ((efforts . [((id . "off") (name . "Off"))
                                                                  ((id . "high") (name . "High"))
                                                                  ((id . "max") (name . "Max"))])
                                                      (defaultEffort . "high"))))]))])))
         (eff (dsh-emacs-test--model-effort-run dir "")))
    (ert-info ((format "%s" "select-model-empty-effort-pick-default"))
      (should (string= "high" eff)))))

;; Reselecting the current model (current.reasoningEffort=max, the m1 option
;; includes max) → keep max
(ert-deftest dsh-emacs-test-model-selection-select-model-repick-keeps-current-effort ()
  :tags '(dsh-unit)
  (let* ((dir '((current . ((provider . "p1") (model . "m1") (reasoningEffort . "max")))
                (groups . [((id . "g1") (name . "DeepSeek")
                            (models . [((id . "m1") (name . "One")
                                        (reasoning . ((efforts . [((id . "off") (name . "Off"))
                                                                  ((id . "max") (name . "Max"))])
                                                      (defaultEffort . "high"))))]))])))
         (eff (dsh-emacs-test--model-effort-run dir "")))
    (ert-info ((format "%s" "select-model-repick-keeps-current-effort"))
      (should (string= "max" eff)))))

;; The target model has no reasoning option → the request has no
;; reasoningEffort key
(ert-deftest dsh-emacs-test-model-selection-select-model-no-reasoning-omits-effort ()
  :tags '(dsh-unit)
  (let* ((dir '((current . ((provider . "p1") (model . "m0")))
                (groups . [((id . "g1") (name . "DeepSeek")
                            (models . [((id . "m1") (name . "One"))]))])))
         (eff (dsh-emacs-test--model-effort-run dir "x")))
    (ert-info ((format "%s" "select-model-no-reasoning-omits-effort"))
      (should (null eff)))))

;; --- Test 47n: select-effort reuses the running model/provider (no model
;; re-pick) ---
;; The dedicated effort command reads the session's live `modelSelection'
;; (provider/model/effort), finds that model's `reasoning' options in the live
;; catalog, pre-selects the current effort and sends selectModel with the same
;; provider/model plus the chosen reasoningEffort.
(ert-deftest dsh-emacs-test-model-selection-select-effort-sends-running-model-and-chosen-effort ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--current-session nil)
        (buf (generate-new-buffer " *dsh-effort-cmd*"))
        (calls nil)
        (effort-def :unset)
        (cached-effort "low")
        (selected-effort "low"))
    (unwind-protect
        (with-current-buffer buf
          (setq dsh-emacs--current-session "sess-e")
          (cl-letf (((symbol-function 'dsh-emacs--session-model-selection)
                     (lambda (_id)
                       (dsh-protocol-model-selection--from-alist
                        `((provider . "p1") (model . "m1")
                          (reasoningEffort . ,cached-effort)))))
                    ((symbol-function 'dsh-emacs-list-sessions--fetch)
                     (lambda () (setq cached-effort selected-effort)))
                    ((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (if (string= method "session/modelCatalog")
                           (funcall
                            cb t
                            '((groups . [((id . "p1") (name . "DeepSeek")
                                          (models . [((id . "m1") (name . "One")
                                                      (reasoning . ((efforts . [((id . "low") (name . "Low"))
                                                                                ((id . "max") (name . "Max"))])
                                                                    (defaultEffort . "low"))))]))])))
                         (setq selected-effort
                               (cdr (assq 'reasoningEffort
                                          (cdr (assq 'request params)))))
                         (funcall cb t `((selected . ((provider . "p1")
                                                      (model . "m1")
                                                      (reasoningEffort
                                                       . ,selected-effort))))))))
                    ((symbol-function 'completing-read)
                     (lambda (_prompt _coll &optional _pred _req _initial _hist def
                                      &rest _)
                       (setq effort-def def)
                       "Max")))
            (dsh-emacs-select-effort)
            (let* ((call (car calls))
                   (req (cdr (assq 'request (cadr call)))))
              (ert-info ((format "%s" "select-effort-sends-running-model-and-chosen-effort"))
                (should (string= "session/selectModel" (car call)))
                (should (equal "sess-e" (cdr (assq 'sessionId req))))
                (should (equal "p1" (cdr (assq 'provider req))))
                (should (equal "m1" (cdr (assq 'model req))))
                (should (equal "max" (cdr (assq 'reasoningEffort req))))
                (should (equal "Low" effort-def)))
              (ert-info ((format "%s" "select-effort-updates-mode-line"))
                (should (equal "max" dsh-emacs--modeline-effort)))
              (ert-info ((format "%s" "select-effort-keybinding"))
                (should (eq (lookup-key dsh-emacs-mode-map (kbd "C-c C-e"))
                            #'dsh-emacs-select-effort))))
            ;; A second invocation must default to the successful selection,
            ;; not the effort cached before the first invocation.
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt _coll &optional _pred _req _initial
                                        _hist def &rest _)
                         (setq effort-def def)
                         def)))
              (dsh-emacs-select-effort))
            (ert-info ((format "%s" "select-effort-repeat-keeps-new-effort"))
              (should (equal "Max" effort-def))
              (should (equal "max" selected-effort)))))
      (kill-buffer buf))))

;; --- Test 47o: a model without reasoning options reports and sends nothing ---
(ert-deftest dsh-emacs-test-model-selection-select-effort-no-reasoning-reports ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *dsh-effort-noopt*"))
        (calls nil)
        (msgs nil))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'dsh-emacs--session-model-selection)
                     (lambda (_id)
                       (dsh-protocol-model-selection--from-alist
                        '((provider . "p1") (model . "m1")))))
                    ((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params _cb)
                       (push (list method params) calls)))
                    ((symbol-function 'message)
                     (lambda (fmt &rest args)
                       (push (apply #'format fmt args) msgs))))
            (dsh-emacs--select-effort-prompt
             "sess-e"
             '((groups . [((id . "p1") (name . "DeepSeek")
                           (models . [((id . "m1") (name . "One"))]))])))
            (ert-info ((format "%s" "select-effort-no-reasoning-reports"))
              (should (cl-some (lambda (m)
                                 (string-match-p "no reasoning-effort options" m))
                               msgs))
              (should (null calls)))))
      (kill-buffer buf))))

(ert-deftest dsh-emacs-test-model-selection-select-effort-missing-model-reports ()
  :tags '(dsh-unit)
  (let (messages calls)
    (cl-letf (((symbol-function 'dsh-emacs--session-model-selection)
               (lambda (_id)
                 (dsh-protocol-model-selection--from-alist
                  '((provider . "p1") (model . "removed-model")))))
              ((symbol-function 'completing-read)
               (lambda (&rest _)
                 (ert-fail "Missing model must not open an effort reader")))
              ((symbol-function 'dsh-emacs--rpc-async)
               (lambda (&rest args) (push args calls)))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages))))
      (dsh-emacs--select-effort-prompt
       "sess-e"
       '((groups . [((id . "p1") (name . "DeepSeek")
                     (models . [((id . "m1") (name . "One"))]))]))))
    (should (equal messages '("Model removed-model is not in the live catalog")))
    (should-not calls)))

;; --- Test 47p: C-g in select-effort cancels cleanly (the quit must not reach
;; the command boundary) ---
(ert-deftest dsh-emacs-test-model-selection-select-effort-c-g-aborts-cleanly ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *dsh-effort-quit*"))
        (leaked nil))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'dsh-emacs--session-model-selection)
                     (lambda (_id)
                       (dsh-protocol-model-selection--from-alist
                        '((provider . "p1") (model . "m1")))))
                    ((symbol-function 'dsh-emacs--rpc-async) #'ignore)
                    ((symbol-function 'completing-read)
                     (lambda (&rest _) (signal 'quit nil))))
            (condition-case nil
                (dsh-emacs--select-effort-prompt
                 "sess-e"
                 '((groups . [((id . "p1") (name . "DeepSeek")
                               (models . [((id . "m1") (name . "One")
                                           (reasoning . ((efforts . [((id . "low") (name . "Low"))]))))]))])))
              (quit (setq leaked t)))))
      (kill-buffer buf))
    (ert-info ((format "%s" "select-effort-c-g-aborts-cleanly"))
      (should (not leaked)))))

;; --- Test 47q: no cached modelSelection → the catalog host default is the
;; reference (same fallback the model picker uses) ---
(ert-deftest dsh-emacs-test-model-selection-select-effort-falls-back-to-catalog-default ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *dsh-effort-default*"))
        (sent nil))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'dsh-emacs--session-model-selection)
                     (lambda (_id) nil))
                    ((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params _cb)
                       (when (string= method "session/selectModel")
                         (setq sent (cdr (assq 'request params))))))
                    ((symbol-function 'completing-read)
                     (lambda (&rest _) "Max")))
            (dsh-emacs--select-effort-prompt
             "sess-e"
             '((current . ((provider . "p1") (model . "m1")
                           (reasoningEffort . "low")))
               (groups . [((id . "p1") (name . "DeepSeek")
                           (models . [((id . "m1") (name . "One")
                                       (reasoning . ((efforts . [((id . "low") (name . "Low"))
                                                                 ((id . "max") (name . "Max"))])
                                                     (defaultEffort . "low"))))]))])))
            (ert-info ((format "%s" "select-effort-falls-back-to-catalog-default"))
              (should (equal "m1" (cdr (assq 'model sent))))
              (should (equal "p1" (cdr (assq 'provider sent))))
              (should (equal "max" (cdr (assq 'reasoningEffort sent)))))))
      (kill-buffer buf))))

;; --- Test 74: agentPresets/list protocol structs (thinking preset
;; candidates for a new session) ---
;; wire alist (presets array as a vector) -> struct: presets normalized to a
;; list, all fields read through accessors; broken/missing fields do not
;; break the conversion.
(ert-deftest dsh-emacs-test-model-selection-agent-preset-list-protocol-struct ()
  :tags '(dsh-unit)
  (let* ((v (dsh-protocol-agent-preset-list--from-alist
             '((presets . [((id . "standard") (isDefault . t)
                            (name . "Standard mode"))
                           ((id . "broken-agent") (broken . "load failed"))])
               (modeSelectionEnabled . t))))
         (presets (dsh-protocol-agent-preset-list-presets v))
         (p0 (car presets))
         (p1 (cadr presets)))
    (ert-info ((format "%s" "agent-preset-list-protocol-struct"))
      (should (and (dsh-protocol-agent-preset-p p0)
                   (equal "standard" (dsh-protocol-agent-preset-id p0))
                   (eq t (dsh-protocol-agent-preset-is-default p0))
                   (equal "Standard mode" (dsh-protocol-agent-preset-name p0))
                   (null (dsh-protocol-agent-preset-broken p0))
                   (equal 2 (length presets))
                   (equal "broken-agent" (dsh-protocol-agent-preset-id p1))
                   (equal "load failed" (dsh-protocol-agent-preset-broken p1))
                   (eq t (dsh-protocol-agent-preset-list-mode-selection-enabled v)))))))

;; --- Test 74b: preset / command `false' booleans normalize at the struct
;; --- boundary ---
;; `AgentPresetRow.isDefault' and the roster's `modeSelectionEnabled' are
;; required JSON booleans, so `json-read' hands back the truthy
;; `:json-false' for every false value.  Kept raw, `isDefault' made
;; `dsh-emacs--preset-default-id' (a `cl-some' over the roster) return the
;; FIRST preset instead of the host's real default whenever
;; `dsh-emacs-default-preset' was unset.
(ert-deftest dsh-emacs-test-model-selection-agent-preset-wire-false-is-default-normalizes-to-nil ()
  :tags '(dsh-unit)
  (let* ((roster (dsh-protocol-agent-preset-list--from-alist
                  '((presets . [((id . "alpha") (isDefault . :json-false))
                                ((id . "beta") (isDefault . t))])
                    (modeSelectionEnabled . :json-false))))
         (presets (dsh-protocol-agent-preset-list-presets roster)))
    (ert-info ((format "%s" "agent-preset-wire-false-is-default-normalizes-to-nil"))
      (should (null (dsh-protocol-agent-preset-is-default (car presets)))))
    (ert-info ((format "%s" "agent-preset-wire-true-is-default-normalizes-to-t"))
      (should (eq t (dsh-protocol-agent-preset-is-default (cadr presets)))))
    (ert-info ((format "%s" "agent-preset-roster-wire-false-flag-normalizes"))
      (should (null (dsh-protocol-agent-preset-list-mode-selection-enabled roster))))))

(ert-deftest dsh-emacs-test-model-selection-command-input-wire-false-attachments-normalizes-to-nil ()
  :tags '(dsh-unit)
  (let ((input (dsh-protocol-command-input--from-alist
                '((hint . "<x>") (attachments . :json-false)))))
    (ert-info ((format "%s" "command-input-wire-false-attachments-normalizes-to-nil"))
      (should (null (dsh-protocol-command-input-attachments input))))))

;; --- Test 75: new-session preset candidate table (published name or id) ---
;; A preset uses its published `name'; one without a name shows its id. Rows
;; that would render identically append their id. Broken entries are dropped.
;; No cache -> no choices; `dsh-emacs--read-preset' ensures the server, fetches
;; a cold roster synchronously, and only then prompts with those choices.
(ert-deftest dsh-emacs-test-model-selection-preset-choices-name-or-id ()
  :tags '(dsh-unit)
  (let ((old-cache dsh-emacs--agent-presets))
    (unwind-protect
        (progn
          (setq dsh-emacs--agent-presets nil)
          (ert-info ((format "%s" "preset-choices-empty-before-roster"))
            (should-not (dsh-emacs--preset-choices)))
          (setq dsh-emacs--agent-presets
                (dsh-protocol-agent-preset-list--from-alist
                 '((presets . [((id . "standard") (isDefault . t))
                               ((id . "minimal") (name . "Legacy name"))
                               ((id . "ptc"))
                               ((id . "my-agent") (name . "My Agent"))
                               ((id . "my-standard") (name . "standard"))
                               ((id . "broken-agent") (broken . "x"))]))))
          (ert-info ((format "%s" "preset-choices-name-or-id"))
            (should (equal '(("standard (standard)" . "standard")
                             ("Legacy name" . "minimal")
                             ("ptc" . "ptc")
                             ("My Agent" . "my-agent")
                             ("standard (my-standard)" . "my-standard"))
                           (dsh-emacs--preset-choices)))))
      (setq dsh-emacs--agent-presets old-cache))))

;; --- Test 76: preset preselected id (config > roster isDefault > none) ---
(ert-deftest dsh-emacs-test-model-selection-preset-default-id-roster-is-default ()
  :tags '(dsh-unit)
  (let ((old-cache dsh-emacs--agent-presets))
    (unwind-protect
        (progn
          (setq dsh-emacs--agent-presets
                (dsh-protocol-agent-preset-list--from-alist
                 '((presets . [((id . "minimal") (isDefault . :json-false))
                               ((id . "standard") (isDefault . t))]))))
          (ert-info ((format "%s" "preset-default-id-roster-is-default"))
            (should (equal "standard" (dsh-emacs--preset-default-id nil))))
          (ert-info ((format "%s" "preset-default-id-configured-wins"))
            (should (equal "minimal" (dsh-emacs--preset-default-id "minimal"))))
          (ert-info ((format "%s" "preset-default-id-invalid-config-falls-back"))
            (should (equal "standard" (dsh-emacs--preset-default-id "ghost")))))
      (setq dsh-emacs--agent-presets old-cache))))

;; --- Test 77: read-preset interactive read (candidates + preselect + host
;; default + C-g) ---
;; Pick by display name -> its id; empty RET accepts the preselect (models
;; completing-read returning DEF); with no preselect an empty RET -> nil
;; (host default, no agentPreset sent); C-g bubbles up to cancel the whole
;; creation (quit is not swallowed by read-preset). A warm read triggers one
;; background refresh; a cold read fetches the roster synchronously and a
;; failed fetch signals instead of prompting.
(ert-deftest dsh-emacs-test-model-selection-read-preset-pick-by-display-name ()
  :tags '(dsh-unit)
  (let ((old-cache dsh-emacs--agent-presets)
        (calls nil))
    (unwind-protect
        (progn
          (setq dsh-emacs--agent-presets
                (dsh-protocol-agent-preset-list--from-alist
                 '((presets . [((id . "standard") (isDefault . t)
                                (name . "Standard mode"))
                               ((id . "minimal") (name . "Minimal mode"))]))))
          ;; pick by display name -> its id;
          ;; one roster refresh is also sent to the backend
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _) "Standard mode"))
                    ((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method _params _cb)
                       (push method calls))))
            (ert-info ((format "%s" "read-preset-pick-by-display-name"))
              (should (and (equal "standard" (dsh-emacs--read-preset nil))
                           (member "agentPresets/list" calls)))))
          ;; empty RET -> accept the preselected default
          ;; (roster isDefault = standard)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt _table &optional _pred _req _init _hist
                                      def _inherit)
                       (or def "")))
                    ((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (&rest _) nil)))
            (ert-info ((format "%s" "read-preset-empty-ret-accepts-default"))
              (should (equal "standard" (dsh-emacs--read-preset nil)))))
          ;; no isDefault and no config -> empty RET returns nil (host default)
          (setq dsh-emacs--agent-presets
                (dsh-protocol-agent-preset-list--from-alist
                 '((presets . [((id . "standard")
                                (name . "Standard mode"))]))))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt _table &optional _pred _req _init _hist
                                      def _inherit)
                       (or def "")))
                    ((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (&rest _) nil)))
            (ert-info ((format "%s" "read-preset-no-default-keeps-host-default"))
              (should (null (dsh-emacs--read-preset nil)))))
          ;; C-g -> quit bubbles up to interactive (not swallowed by read-preset)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _) (signal 'quit nil)))
                    ((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (&rest _) nil)))
            (should (eq 'quit
                        (condition-case nil
                            (progn (dsh-emacs--read-preset nil) nil)
                          (quit 'quit)))))
          ;; cold read: ensure the server, fetch the roster synchronously,
          ;; then prompt with the fetched choices
          (setq dsh-emacs--agent-presets nil)
          (let ((ensured nil)
                (prompted nil)
                (fetched nil)
                (offered nil))
            (cl-letf (((symbol-function 'dsh-emacs-server-ensure)
                       (lambda () (setq ensured t)))
                      ((symbol-function 'completing-read)
                       (lambda (_prompt collection &rest _)
                         (setq prompted t offered collection)
                         "standard"))
                      ((symbol-function 'dsh-emacs--rpc-request)
                       (lambda (method _params)
                         (setq fetched method)
                         (cons t '((presets . [((id . "standard"))])))))
                      ((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (&rest _)
                         (ert-fail "cold read must not wait for the async refresh"))))
              (ert-info ((format "%s" "read-preset-fetches-roster-before-prompt"))
                (should (equal "standard" (dsh-emacs--read-preset nil)))
                (should ensured)
                (should prompted)
                (should (equal "agentPresets/list" fetched))
                (should (equal '(("standard" . "standard")) offered)))))
          ;; failed cold fetch: signal, never prompt or create with a default
          (setq dsh-emacs--agent-presets nil)
          (let ((prompted nil))
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (&rest _) (setq prompted t) ""))
                      ((symbol-function 'dsh-emacs--rpc-request)
                       (lambda (&rest _) (cons nil nil))))
              (ert-info ((format "%s" "read-preset-fails-without-roster"))
                (should-error (dsh-emacs--read-preset nil) :type 'user-error)
                (should-not prompted)))))
      (setq dsh-emacs--agent-presets old-cache))))

;; --- Test 95b: permissionPresets/catalog parses and the switch runs the
;; `/permission' slash command (dsh 0.1.6; the namespace has no write Remote) ---
(ert-deftest dsh-emacs-test-model-selection-permission-catalog-parses-options ()
  :tags '(dsh-unit)
  (let* ((catalog (dsh-protocol-permission-catalog--from-alist
                   '((options . [((value . "workspace-write")
                                  (name . "Workspace write")
                                  (description . "Write inside the workspace"))
                                 ((value . "danger-full-access")
                                  (name . "Full access"))]))))
         (options (dsh-protocol-permission-catalog-options catalog)))
    (ert-info ((format "%s" "permission-catalog-parses-options"))
      (should (= 2 (length options)))
      (should (equal "workspace-write" (dsh-protocol-permission-option-value (car options))))
      (should (equal "Workspace write" (dsh-protocol-permission-option-name (car options))))
      (should (equal "Write inside the workspace"
                     (dsh-protocol-permission-option-description (car options))))
      (should (null (dsh-protocol-permission-option-description (cadr options)))))))

(ert-deftest dsh-emacs-test-model-selection-permission-prompt-offers-catalog-options ()
  :tags '(dsh-unit)
  (let ((offered nil)
        (executed nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _args)
                 (setq offered (mapcar #'car collection))
                 (caar collection)))
              ((symbol-function 'dsh-emacs-command-execute)
               (lambda (session-id line _attachment _on-done)
                 (setq executed (list session-id line)))))
      (dsh-emacs--set-permission-prompt
       "sess-perm"
       '((options . [((value . "workspace-write") (name . "Workspace write")
                      (description . "Write inside the workspace"))
                     ((value . "danger-full-access") (name . "Full access"))]))))
    (ert-info ((format "%s" "permission-prompt-offers-catalog-options"))
      (should (= 2 (length offered)))
      (should (string-match-p "Workspace write" (car offered)))
      (should (string-match-p "Write inside the workspace" (car offered)))
      (should (equal "Full access" (cadr offered))))
    (ert-info ((format "%s" "permission-prompt-runs-permission-command"))
      (should (equal '("sess-perm" "/permission workspace-write") executed)))))

(ert-deftest dsh-emacs-test-model-selection-permission-set-fetches-catalog-and-switches ()
  :tags '(dsh-unit)
  (let ((methods nil)
        (executed nil)
        (buf (generate-new-buffer " *dsh-permission-cmd*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-perm")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method _params cb)
                       (push method methods)
                       (funcall cb t '((options . [((value . "workspace-write")
                                                    (name . "Workspace write"))])))))
                    ((symbol-function 'completing-read)
                     (lambda (_prompt collection &rest _args) (caar collection)))
                    ((symbol-function 'dsh-emacs-command-execute)
                     (lambda (_session-id line _attachment _on-done)
                       (setq executed line))))
            (dsh-emacs-set-permission)))
      (when (buffer-live-p buf) (kill-buffer buf)))
    (ert-info ((format "%s" "permission-set-fetches-catalog-and-switches"))
      (should (equal '("permissionPresets/catalog") methods))
      (should (equal "/permission workspace-write" executed)))))

;; The picker groups only when Vertico will actually apply `group-function',
;; which is gated on the option's VALUE (nil = no group titles).  The fallback
;; keeps provider headers and suffixes duplicate ids so they stay distinct.
(defun dsh-test--model-picker-rows (group-format)
  "Return the model picker's candidate keys when GROUP-FORMAT is in effect."
  (let ((buf (generate-new-buffer " *dsh-model-rows*"))
        (rows nil))
    (unwind-protect
        (with-current-buffer buf
          (setq dsh-emacs--current-session "sess-g")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (unless (string= method "session/list")
                         (funcall
                          cb t
                          (cond
                           ((string= method "session/modelCatalog")
                            '((current . ((provider . "g1") (model . "m1")))
                              (groups
                               . [((id . "g1") (name . "DeepSeek")
                                   (models . [((id . "m2") (name . "Dup-1"))]))
                                  ((id . "g2") (name . "Qwen")
                                   (models . [((id . "m2") (name . "Dup-2"))]))])))
                           (t nil))))))
                    ((symbol-function 'completing-read)
                     (lambda (_prompt collection &rest _)
                       (setq rows (all-completions "" collection nil))
                       (signal 'quit nil)))
                    ((symbol-function 'message) (lambda (&rest _) nil)))
            (let ((vertico-mode t)
                  (vertico-group-format group-format))
              (condition-case nil (dsh-emacs-select-model) (quit nil)))))
      (kill-buffer buf))
    rows))

(ert-deftest dsh-emacs-test-model-selection-grouped-rows-with-group-format ()
  :tags '(dsh-unit)
  (let ((rows (dsh-test--model-picker-rows "%s")))
    (ert-info ("model-grouped-rows-have-no-header-candidates")
      (should-not (member "Qwen" rows))
      (should-not (member "DeepSeek" rows)))
    (ert-info ("model-grouped-rows-show-bare-ids")
      (should (cl-some (lambda (row)
                         (equal "  m2" (get-text-property 0 'display row)))
                       rows)))))

(ert-deftest dsh-emacs-test-model-selection-fallback-rows-without-group-format ()
  :tags '(dsh-unit)
  (let ((rows (dsh-test--model-picker-rows nil)))
    (ert-info ("model-fallback-rows-carry-provider-headers")
      (should (member "Qwen" rows))
      (should (member "DeepSeek" rows)))
    (ert-info ("model-fallback-rows-suffix-duplicate-ids")
      (should (cl-some (lambda (row)
                         (equal "  m2 (Qwen)"
                                (get-text-property 0 'display row)))
                       rows)))))

(provide 'dsh-test-model-selection)
;;; dsh-test-model-selection.el ends here
