;;; dsh-test-modeline.el --- Modeline tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)

(defvar motion-line-current-time-function)
(defvar motion-line-visible-p-function)
(defvar motion-line--timer)
(defvar motion-line--buffers)

;; --- Test 5c: mode-line event accumulation and rendering ---
(ert-deftest dsh-emacs-test-modeline-modeline-note-event-accumulates-assistant-message-usage ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let (txt)
      (setq dsh-emacs--modeline-usage nil)
      (dsh-emacs-modeline-note-event
       '(("type" . "assistant/message")
         ("data" . (("usage" . (("inputTokens" . 100) ("outputTokens" . 20)))))))
      (dsh-emacs-modeline-note-event
       '(("type" . "assistant/message")
         ("data" . (("usage" . (("inputTokens" . 200)
                                ("outputTokens" . 40)
                                ("cacheReadTokens" . 3500)))))))
      ;; Non-message events must not touch the accumulator.
      (dsh-emacs-modeline-note-event
       '(("type" . "user/message") ("data" . (("content" . "hi")))))
      (ert-info ((format "%s" "modeline-note-event accumulates assistant/message usage"))
        (should (and dsh-emacs--modeline-usage
                     (= 300 (dsh-emacs-usage-input dsh-emacs--modeline-usage))
                     (= 60 (dsh-emacs-usage-output dsh-emacs--modeline-usage))
                     (= 3500 (dsh-emacs-usage-cache-read dsh-emacs--modeline-usage)))))
      (let ((dsh-emacs-modeline-format-spec '(:separator " " :segments (tokens))))
        (setq txt (dsh-emacs-modeline-format))
        (ert-info ((format "%s" "modeline-format renders accumulated tokens"))
          (should (and (string-match "↑300" txt) (string-match "↓60" txt)
                       (string-match "CH92%" txt))))))))

;; --- Test 5d: request/context feeds model (window arrives via
;; session/projection frames) ---
(ert-deftest dsh-emacs-test-modeline-note-request-feeds-model ()
  :tags '(dsh-unit)
  (let ((rc '(("type" . "request/context")
              ("seq" . 42)
              ("data" . (("provider" . "qwen-token-plan")
                         ("model" . "deepseek-v4-flash-0731")
                         ("contextWindow" . 1000000)))))
        (before (or (bound-and-true-p dsh-emacs--modeline-model) "none")))
    (dsh-emacs-modeline-note-request rc)
    (ert-info ((format "%s" "note-request feeds model"))
      (should (and (equal "deepseek-v4-flash-0731" dsh-emacs--modeline-model)
                   (equal "qwen-token-plan" dsh-emacs--modeline-provider))))))

(ert-deftest dsh-emacs-test-modeline-note-request-keeps-provider-when-event-omits-it ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((rc '(("type" . "request/context") ("seq" . 43) ("data" . (("model" . "m9"))))))
      ;; When provider is missing, the previous provider must not linger (cross-provider
      ;; disambiguation of the same id relies on it)
      (setq dsh-emacs--modeline-provider "stale")
      (dsh-emacs-modeline-note-request rc)
      (ert-info ((format "%s" "note-request keeps provider when event omits it"))
        (should (equal "stale" dsh-emacs--modeline-provider)))
      (setq dsh-emacs--modeline-provider nil))))

;; --- Test 5e: three independent model/effort/preset segments +
;; modeinline parens ---
(ert-deftest dsh-emacs-test-modeline-model-effort-preset-render-as-separate-segments ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((dsh-emacs-modeline-format-spec '(:separator " " :segments (model effort preset)))
          (txt (progn
                 (setq dsh-emacs--modeline-model "m1"
                       dsh-emacs--modeline-effort "max"
                       dsh-emacs--modeline-preset "standard")
                 (dsh-emacs-modeline-format))))
      (ert-info ((format "%s" "model effort preset render as separate segments"))
        (should (and (string-match "m1" txt)
                     (string-match "max" txt)
                     (string-match "standard" txt)
                     (not (string-match "m1-standard" txt))))))))

;; --- Test 5f: the permission segment draws the dsh-web shield icons ---
;; `icon' style (default) prefers the SVG shield, then the Nerd Font shield
;; glyph, then a short token — never an emoji (`char-width' 1 and the
;; segment's face color are the reasons).  A batch run has no graphical
;; frame and no `nerd-icons', so it pins the text fallback.
(ert-deftest dsh-emacs-test-modeline-permission-segment-renders-beside-preset ()
  :tags '(dsh-unit)
  (let ((txt (with-temp-buffer
               (dsh-emacs-mode)
               (let ((dsh-emacs-modeline-format-spec
                      '(:separator " " :segments (preset permission))))
                 (setq-local dsh-emacs--modeline-preset "standard"
                             dsh-emacs--modeline-permission "workspace-write")
                 (dsh-emacs-modeline-format)))))
    (ert-info ((format "%s" "permission-segment-renders-beside-preset"))
      (should (string-match-p "standard" txt))
      (should (string-match-p " ws" txt))
      (should (not (string-match-p "standard-ws" txt))))))

(ert-deftest dsh-emacs-test-modeline-permission-segment-text-style-shows-preset-name ()
  :tags '(dsh-unit)
  (let ((txt (with-temp-buffer
               (dsh-emacs-mode)
               (let ((dsh-emacs-modeline-format-spec
                      '(:separator " " :segments (permission)))
                     (dsh-emacs-modeline-permission-style 'text))
                 (setq-local dsh-emacs--modeline-permission "danger-full-access")
                 (dsh-emacs-modeline-format)))))
    (ert-info ((format "%s" "permission-segment-text-style-shows-preset-name"))
      (should (string-match-p "danger-full-access" txt)))))

(ert-deftest dsh-emacs-test-modeline-permission-segment-hidden-when-unset ()
  :tags '(dsh-unit)
  (let ((txt (with-temp-buffer
               (dsh-emacs-mode)
               (let ((dsh-emacs-modeline-format-spec
                      '(:separator " " :segments (permission))))
                 (setq-local dsh-emacs--modeline-permission nil)
                 (dsh-emacs-modeline-format)))))
    (ert-info ((format "%s" "permission-segment-hidden-when-unset"))
      (should (string-empty-p txt)))))

;; The inline stats string is cached on its inputs: a permission change (the
;; projection frame path, which does NOT call the setter's cache reset here)
;; must re-render instead of freezing the previous shield/token.
(ert-deftest dsh-emacs-test-modeline-permission-change-invalidates-modeinline-cache ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((dsh-emacs-modeline-format-spec '(:separator " " :segments (permission))))
      (setq-local dsh-emacs--modeline-permission "workspace-write")
      (let ((first (dsh-emacs-modeline--modeinline)))
        (setq-local dsh-emacs--modeline-permission "danger-full-access")
        (ert-info ((format "%s" "permission-change-invalidates-modeinline-cache"))
          (should (string-match-p "ws" first))
          (should (let ((second (dsh-emacs-modeline--modeinline)))
                    (string-match-p "full" second)
                    (not (equal first second)))))))))

(ert-deftest dsh-emacs-test-modeline-permission-svg-covers-the-design-set ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "permission-svg-covers-the-design-set"))
    (should (= 3 (length dsh-emacs--permission-icon-svgs)))
    (should (equal '("read-only" "workspace-write" "danger-full-access")
                   (mapcar #'car dsh-emacs--permission-icon-svgs)))))

(ert-deftest dsh-emacs-test-modeline-permission-svg-tints-and-leaves-no-placeholder ()
  :tags '(dsh-unit)
  (let ((svg (dsh-emacs-modeline--permission-svg "workspace-write" "#123456")))
    (ert-info ((format "%s" "permission-svg-tints-and-leaves-no-placeholder"))
      (should (stringp svg))
      (should (string-prefix-p "<svg" svg))
      (should (string-match-p "#123456" svg))
      (should (not (string-match-p "__C__" svg)))
      (should (not (string-match-p "currentColor" svg))))))

(ert-deftest dsh-emacs-test-modeline-permission-svg-only-for-the-design-set ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "permission-svg-only-for-the-design-set"))
    (should (null (dsh-emacs-modeline--permission-svg "auto" "#123456")))
    (should (null (dsh-emacs-modeline--permission-svg "custom" "#123456")))
    (should (null (dsh-emacs-modeline--permission-svg "host-preset" "#123456")))))

(ert-deftest dsh-emacs-test-modeline-permission-nerd-icon-uses-the-matching-shield ()
  :tags '(dsh-unit)
  (let ((selected nil))
    (cl-letf (((symbol-function 'nerd-icons-mdicon)
               (lambda (name &rest args)
                 (setq selected (list name args))
                 "<glyph>")))
      (ert-info ((format "%s" "permission-nerd-icon-uses-the-matching-shield"))
        (should (equal "<glyph>"
                       (dsh-emacs-modeline--permission-nerd-icon
                        "danger-full-access" 'dsh-emacs-modeline-permission-warn-face)))
        (should (equal '("nf-md-shield_alert"
                         (:face dsh-emacs-modeline-permission-warn-face))
                       selected)))
      ;; No shield name outside the design set: the caller shows text instead.
      (ert-info ((format "%s" "permission-nerd-icon-none-for-unknown-values"))
        (should (null (dsh-emacs-modeline--permission-nerd-icon "auto" 'default)))
        (should (null (dsh-emacs-modeline--permission-nerd-icon "custom" 'default)))))))

(ert-deftest dsh-emacs-test-modeline-doom-file-icon-skipped-for-fileless-dsh-buffer ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((called nil))
      (ert-info ((format "%s" "doom-file-icon-skipped-for-fileless-dsh-buffer"))
        (should (null
                 (dsh-emacs-modeline--doom-buffer-file-icon
                  (lambda (&rest _args)
                    (setq called t)
                    (signal 'wrong-type-argument '(stringp nil))))))
        (should (not called))))))

(ert-deftest dsh-emacs-test-modeline-doom-file-icon-delegates-for-other-buffers ()
  :tags '(dsh-unit)
  (let ((called nil))
    (ert-info ((format "%s" "doom-file-icon-delegates-for-other-buffers"))
      (should (eq 'delegated
                  (with-temp-buffer
                    (dsh-emacs-modeline--doom-buffer-file-icon
                     (lambda (&rest _args)
                       (setq called t)
                       'delegated)))))
      (should called))))

(ert-deftest dsh-emacs-test-modeline-nerd-icons-dsh-mode-bypasses-cached-generic-icon ()
  :tags '(dsh-unit)
  (let ((cached-icon (lambda (&rest _args) "cached generic icon")))
    (ert-info ((format "%s" "nerd-icons-dsh-mode-bypasses-cached-generic-icon"))
      (should (equal "DSH"
                     (dsh-emacs-modeline--nerd-icon-for-mode
                      cached-icon 'dsh-emacs-mode)))
      (should (equal "cached generic icon"
                     (dsh-emacs-modeline--nerd-icon-for-mode
                      cached-icon 'fundamental-mode))))))

(ert-deftest dsh-emacs-test-modeline-permission-short-fallback-bounded ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "permission-short-fallback-bounded"))
    (should (equal "ws" (dsh-emacs-modeline--permission-short "workspace-write")))
    (should (equal "full" (dsh-emacs-modeline--permission-short "danger-full-access")))
    (should (equal "custom" (dsh-emacs-modeline--permission-short "custom")))
    (should (<= (string-width (dsh-emacs-modeline--permission-short "verylonghostname")) 8))
    (should (not (equal "verylonghostname"
                        (dsh-emacs-modeline--permission-short "verylonghostname"))))))

(ert-deftest dsh-emacs-test-modeline-permission-face-warns-only-when-unrestricted ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "permission-face-warns-only-when-unrestricted"))
    (should (eq 'dsh-emacs-modeline-permission-face
                (dsh-emacs-modeline--permission-face "workspace-write")))
    (should (eq 'dsh-emacs-modeline-permission-face
                (dsh-emacs-modeline--permission-face "read-only")))
    (should (eq 'dsh-emacs-modeline-permission-face
                (dsh-emacs-modeline--permission-face "auto")))
    (should (eq 'dsh-emacs-modeline-permission-warn-face
                (dsh-emacs-modeline--permission-face "danger-full-access")))
    (should (eq 'dsh-emacs-modeline-permission-warn-face
                (dsh-emacs-modeline--permission-face "custom")))))

(ert-deftest dsh-emacs-test-modeline-permission-display-text-style-faces-the-value ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-modeline-permission-style 'text))
    ;; The style must be bound before the display call: a sibling `let' init
    ;; runs in the outer environment.
    (let ((s (dsh-emacs-modeline--permission-display "workspace-write")))
      (ert-info ((format "%s" "permission-display-text-style-faces-the-value"))
        (should (equal "workspace-write" s))
        (should (eq 'dsh-emacs-modeline-permission-face (get-text-property 0 'face s)))))))

(ert-deftest dsh-emacs-test-modeline-permission-display-icon-style-falls-back-to-warn-text ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-modeline-permission-style 'icon))
    (let ((s (dsh-emacs-modeline--permission-display "custom")))
      (ert-info ((format "%s" "permission-display-icon-style-falls-back-to-warn-text"))
        (should (equal "custom" s))
        (should (eq 'dsh-emacs-modeline-permission-warn-face (get-text-property 0 'face s)))))))

;; modeinline rendering requires the current buffer to be in dsh-emacs-mode, and
;; all modeline state is buffer-local — it must be setq-local'd in the same buffer
;; before rendering, otherwise the value is never available (this test previously
;; never fired and silently vanished).
(ert-deftest dsh-emacs-test-modeline-modeinline-wraps-stats-in-parens-and-escapes-percent ()
  :tags '(dsh-unit)
  (let ((txt (with-temp-buffer
               (dsh-emacs-mode)
               (let ((dsh-emacs-modeline-format-spec
                      '(:separator " " :segments (model tokens ctx))))
                 (setq-local dsh-emacs--modeline-usage nil)
                 (dsh-emacs-modeline-note-event
                  '(("type" . "assistant/message")
                    ("data" . (("usage" . (("inputTokens" . 100)
                                           ("outputTokens" . 20)))))))
                 (dsh-emacs-modeline-note-event
                  '(("type" . "assistant/message")
                    ("data" . (("usage" . (("inputTokens" . 200)
                                           ("outputTokens" . 40)
                                           ("cacheReadTokens" . 3500)))))))
                 (setq-local dsh-emacs--modeline-model "m1"
                             dsh-emacs--modeline-preset "standard")
                 (dsh-emacs-modeline-set-effort nil)
                 (dsh-emacs-modeline--modeinline)))))
    (ert-info ((format "%s" "modeinline wraps stats in parens and escapes percent"))
      (should (string-prefix-p "(" txt))
      (should (string-match-p ") *$" txt))
      (should (string-match "CH92%%" txt)))))

(ert-deftest dsh-emacs-test-modeline-modeline-unchanged-stats-render-once ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (setq major-mode 'dsh-emacs-mode)
    (let ((dsh-emacs-modeline-format-spec
           (list :separator " " :segments (list 'model 'ctx)))
          (model (copy-sequence "model-A"))
          (calls 0)
          (render (symbol-function 'dsh-emacs-modeline--render-segment)))
      (setq dsh-emacs--modeline-model model)
      (cl-letf (((symbol-function 'dsh-emacs-modeline--render-segment)
                 (lambda (sym) (cl-incf calls) (funcall render sym))))
        (dotimes (_ 100) (dsh-emacs-modeline--modeinline)))
      (ert-info ((format "%s" "modeline-unchanged-stats-render-once"))
        (should (= calls 2)))
      (aset model 6 ?B)
      (ert-info ((format "%s" "modeline-cache-sees-mutated-model"))
        (should (string-match-p "model-B" (dsh-emacs-modeline--modeinline))))
      (dsh-emacs-modeline-set-context-snapshot 2500 10000)
      (ert-info ((format "%s" "modeline-cache-sees-context-update"))
        (should (string-match-p "25.0%%" (dsh-emacs-modeline--modeinline))))
      (setcar (plist-get dsh-emacs-modeline-format-spec :segments) 'effort)
      (setq dsh-emacs--modeline-effort "high")
      (ert-info ((format "%s" "modeline-cache-sees-mutated-format-spec"))
        (should (string-match-p "high" (dsh-emacs-modeline--modeinline)))
        (should (not (string-match-p "model-B" (dsh-emacs-modeline--modeinline)))))
      (let ((dsh-emacs-modeline-enabled nil))
        (ert-info ((format "%s" "modeline-cache-honors-disabled"))
          (should (equal "" (dsh-emacs-modeline--modeinline))))))))

;; --- Test 5e+1: mode-line segments carry help-echo tooltips, empty values
;; pass through ---
(ert-deftest dsh-emacs-test-modeline-modeline-segments-carry-help-echo ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((dsh-emacs-modeline-format-spec '(:separator " " :segments (model effort preset ctx))))
      (setq dsh-emacs--modeline-model "m1"
            dsh-emacs--modeline-effort "max"
            dsh-emacs--modeline-preset "standard"
            dsh-emacs--modeline-context-pressure 1234
            dsh-emacs--modeline-context-window-server 10000)
      (let* ((txt (dsh-emacs-modeline-format))
             (model-pos (string-match "m1" txt))
             (ctx-pos (string-match "12\\.3%" txt))
             (model-tip (and model-pos (get-text-property model-pos 'help-echo txt)))
             (effort-tip (and (string-match "max" txt)
                              (get-text-property (match-beginning 0) 'help-echo txt)))
             (ctx-tip (and ctx-pos (get-text-property ctx-pos 'help-echo txt))))
        (ert-info ((format "%s" "modeline-segments-carry-help-echo"))
          (should (and (string-match-p "Model: m1" model-tip)
                       (string-match-p "Reasoning effort: max" effort-tip)
                       (string-match-p "1\\.2k" ctx-tip)
                       (string-match-p "10k" ctx-tip)
                       (eq 'mode-line-highlight
                           (get-text-property model-pos 'mouse-face txt))))))
      (setq dsh-emacs--modeline-context-pressure nil
            dsh-emacs--modeline-context-window-server nil))))

(ert-deftest dsh-emacs-test-modeline-annotate-passes-nil-and-empty-through ()
  :tags '(dsh-unit)
  (let ((nil-tip (dsh-emacs-modeline--annotate nil "x"))
        (empty-tip (dsh-emacs-modeline--annotate "" "x")))
    (ert-info ((format "%s" "annotate-passes-nil-and-empty-through"))
      (should (and (null nil-tip) (equal "" empty-tip))))))

;; --- Test 5f: request/header feeds model and reasoningEffort (rc.1 event
;; shape) ---
(ert-deftest dsh-emacs-test-modeline-note-header-feeds-model-and-reasoning-effort ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((hdr '(("type" . "request/header")
                 ("seq" . 11)
                 ("data" . (("header" . (("config" . (("provider" . "opencode-go")
                                                      ("model" . "deepseek-v4-flash")
                                                      ("reasoningEffort" . "high"))))))))))
      (setq dsh-emacs--modeline-model nil
            dsh-emacs--modeline-effort nil)
      (dsh-emacs-modeline-note-header hdr)
      (ert-info ((format "%s" "note-header feeds model and reasoning effort"))
        (should (and (equal "deepseek-v4-flash" dsh-emacs--modeline-model)
                     (equal "high" dsh-emacs--modeline-effort)
                     (equal "opencode-go" dsh-emacs--modeline-provider))))
      (setq dsh-emacs--modeline-model nil
            dsh-emacs--modeline-effort nil))))

;; --- Test 5f+0: the model segment falls back to the default model for an empty
;; session (no request/projection feed) ---
;; For a freshly created session with no request events yet, the mode-line's
;; per-buffer model is nil; the model segment must fall back to
;; `dsh-emacs-default-model' rather than stay empty.
(ert-deftest dsh-emacs-test-modeline-blank-session-model-falls-back-to-default ()
  :tags '(dsh-unit)
  (let ((old-default dsh-emacs-default-model))
    (unwind-protect
        (let ((txt (with-temp-buffer
                     (dsh-emacs-mode)
                     (let ((dsh-emacs-modeline-format-spec
                            '(:separator " " :segments (model))))
                       (setq dsh-emacs-default-model "fallback-model-7")
                       (setq-local dsh-emacs--modeline-model nil)
                       (dsh-emacs-modeline-format)))))
          (ert-info ((format "%s" "blank-session-model-falls-back-to-default"))
            (should (string-match-p "fallback-model-7" txt))))
      (setq dsh-emacs-default-model old-default))))

;; --- Test 5f+1: opening a session syncs the authoritative model from the cache
;; row's modelSelection projection ---
;; The default model is only a segment-level fallback: syncing must overwrite the
;; buffer-local value with the `lastUsed' triple (the projection arrives with
;; session/list rows and follow/control projection frames, with no extra RPC).
(ert-deftest dsh-emacs-test-modeline-chat-buffer-model-sync-lands-provider-model-effort ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let* ((old-sessions dsh-emacs--sessions)
           (buf (get-buffer-create " *t5f1-chat*"))
           (calls nil)
           (item (dsh-protocol-session--from-alist
                  '((sessionId . "sess-modelsync")
                    (projections . ((values
                                     . ((modelSelection
                                         . ((lastUsed
                                             . ((provider . "zhipu")
                                                (model . "glm-5.3-flash")
                                                (reasoningEffort . "max")))))))))))))
      (unwind-protect
          (progn
            (setq dsh-emacs--sessions (list item))
            (with-current-buffer buf
              (setq-local dsh-emacs--buffer-session "sess-modelsync")
              (setq dsh-emacs--modeline-model "stale-model"
                    dsh-emacs--modeline-effort "stale-effort"
                    dsh-emacs--modeline-provider "stale-provider"))
            (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (&rest _) (push t calls))))
              (dsh-emacs--chat-buffer-model-sync "sess-modelsync" buf))
            (with-current-buffer buf
              (ert-info ((format "%s" "chat-buffer-model-sync-lands-provider-model-effort"))
                (should (and (equal "glm-5.3-flash" dsh-emacs--modeline-model)
                             (equal "max" dsh-emacs--modeline-effort)
                             (equal "zhipu" dsh-emacs--modeline-provider)
                             (null calls))))))
        (setq dsh-emacs--sessions old-sessions)
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest dsh-emacs-test-modeline-chat-buffer-model-sync-ignores-foreign-session ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let* ((old-sessions dsh-emacs--sessions)
           (buf (get-buffer-create " *t5f2-chat*"))
           (item (dsh-protocol-session--from-alist
                  '((sessionId . "sess-modelsync")
                    (projections . ((values
                                     . ((modelSelection
                                         . ((lastUsed
                                             . ((provider . "p9") (model . "m9")))))))))))))
      ;; Session mismatch (the sync target row belongs to another session) must not land
      ;; in this buffer (prevents cross-talk)
      (unwind-protect
          (progn
            (setq dsh-emacs--sessions (list item))
            (with-current-buffer buf
              (setq-local dsh-emacs--buffer-session "sess-other")
              (setq dsh-emacs--modeline-model nil
                    dsh-emacs--modeline-provider nil))
            (dsh-emacs--chat-buffer-model-sync "sess-modelsync" buf)
            (with-current-buffer buf
              (ert-info ((format "%s" "chat-buffer-model-sync-ignores-foreign-session"))
                (should (and (null dsh-emacs--modeline-model)
                             (null dsh-emacs--modeline-provider))))))
        (setq dsh-emacs--sessions old-sessions)
        (when (buffer-live-p buf) (kill-buffer buf))))))

;; --- Regression: the mode-line preset segment reads the session's agentPreset
;; projection ---
;; dsh 0.1.2 moved agentPreset from a top-level session-row field to a
;; projection (projections.values.agentPreset).  The protocol used to read only
;; the top-level field, so a real server row yielded no preset and the preset
;; segment never appeared; it must now be read from the projection (keeping the
;; top-level field as the optimistic session/create fallback).
(ert-deftest dsh-emacs-test-modeline-link-session-preset-reads-agentpreset-projection ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let* ((old-sessions dsh-emacs--sessions)
           (buf (get-buffer-create " *t5f3-chat*"))
           (item (dsh-protocol-session--from-alist
                  '((sessionId . "sess-presetproj")
                    (projections . ((values . ((agentPreset . "ptc")))))))))
      (unwind-protect
          (progn
            (setq dsh-emacs--sessions (list item))
            (with-current-buffer buf
              (setq-local dsh-emacs--buffer-session "sess-presetproj")
              (setq dsh-emacs--modeline-preset nil)
              (dsh-emacs--link-session-preset "sess-presetproj")
              (ert-info ((format "%s" "link-session-preset-reads-agentpreset-projection"))
                (should (equal "ptc" dsh-emacs--modeline-preset)))))
        (setq dsh-emacs--sessions old-sessions)
        (when (buffer-live-p buf) (kill-buffer buf))))))

;; Protocol layer: both sources (the projection and the optimistic top-level
;; cache row) parse into agent-preset.
(ert-deftest dsh-emacs-test-modeline-session-agent-preset-projection-and-top-level ()
  :tags '(dsh-unit)
  (let ((proj (dsh-protocol-session--from-alist
               '((sessionId . "s1")
                 (projections . ((values . ((agentPreset . "minimal"))))))))
        (top (dsh-protocol-session--from-alist
              '((sessionId . "s2") (agentPreset . "standard")))))
    (ert-info ((format "%s" "session-agent-preset-projection-and-top-level"))
      (should (and (equal "minimal" (dsh-protocol-session-agent-preset proj))
                   (equal "standard" (dsh-protocol-session-agent-preset top)))))))

;; --- Test: a cache refresh syncs the agentPreset projection into the mode-line
;; preset (the same cadence as model) ---
;; `dsh-emacs--chat-buffers-sync-all' now re-feeds the preset segment on a
;; session.list refresh through the same per-buffer sync as model/ctx, so an
;; already-open session no longer captures its preset only once at open.
(ert-deftest dsh-emacs-test-modeline-chat-buffer-preset-sync-lands-from-projection ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let* ((old-sessions dsh-emacs--sessions)
           (buf (get-buffer-create " *t5f4-chat*"))
           (item (dsh-protocol-session--from-alist
                  '((sessionId . "sess-presetsync")
                    (projections . ((values . ((agentPreset . "ptc")))))))))
      (unwind-protect
          (progn
            (setq dsh-emacs--sessions (list item))
            (with-current-buffer buf
              (setq-local dsh-emacs--buffer-session "sess-presetsync")
              (setq dsh-emacs--modeline-preset nil))
            (dsh-emacs--chat-buffer-preset-sync "sess-presetsync" buf)
            (with-current-buffer buf
              (ert-info ((format "%s" "chat-buffer-preset-sync-lands-from-projection"))
                (should (equal "ptc" dsh-emacs--modeline-preset)))))
        (setq dsh-emacs--sessions old-sessions)
        (when (buffer-live-p buf) (kill-buffer buf))))))

;; The synced session does not match this buffer's session -> the preset must
;; not land in it (guard against cross-session leakage).
(ert-deftest dsh-emacs-test-modeline-chat-buffer-preset-sync-ignores-foreign-session ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let* ((old-sessions dsh-emacs--sessions)
           (buf (get-buffer-create " *t5f5-chat*"))
           (item (dsh-protocol-session--from-alist
                  '((sessionId . "sess-presetsync")
                    (projections . ((values . ((agentPreset . "ptc")))))))))
      (unwind-protect
          (progn
            (setq dsh-emacs--sessions (list item))
            (with-current-buffer buf
              (setq-local dsh-emacs--buffer-session "sess-other")
              (setq dsh-emacs--modeline-preset nil))
            (dsh-emacs--chat-buffer-preset-sync "sess-presetsync" buf)
            (with-current-buffer buf
              (ert-info ((format "%s" "chat-buffer-preset-sync-ignores-foreign-session"))
                (should (null dsh-emacs--modeline-preset)))))
        (setq dsh-emacs--sessions old-sessions)
        (when (buffer-live-p buf) (kill-buffer buf))))))

;; The tooltip carries provider (the model segment disambiguates the same id
;; across providers)
(ert-deftest dsh-emacs-test-modeline-model-tooltip-carries-provider ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((dsh-emacs-modeline-format-spec '(:separator " " :segments (model))))
      (setq dsh-emacs--modeline-model "m1"
            dsh-emacs--modeline-provider "zhipu")
      (let* ((txt (dsh-emacs-modeline-format))
             (tip (get-text-property 0 'help-echo txt)))
        (ert-info ((format "%s" "model-tooltip-carries-provider"))
          (should (and (string-match-p "Model: m1 (provider zhipu)" tip)
                       (string-match-p "switch with C-c C-m" tip)))))
      (setq dsh-emacs--modeline-provider nil))))

;; --- Test 5f+2: provider as its own segment (segment order: provider before
;; model) ---
(ert-deftest dsh-emacs-test-modeline-provider-segment-renders-before-model ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((dsh-emacs-modeline-format-spec '(:separator " " :segments (provider model))))
      (setq dsh-emacs--modeline-provider "zhipu"
            dsh-emacs--modeline-model "glm-5.3-flash")
      (let* ((txt (dsh-emacs-modeline-format))
             (ppos (string-match "zhipu" txt))
             (tip (and ppos (get-text-property ppos 'help-echo txt))))
        (ert-info ((format "%s" "provider-segment-renders-before-model"))
          (should (and ppos
                       (string-match-p "glm-5.3-flash" txt)
                       (< ppos (string-match "glm-5.3-flash" txt))
                       (string-match-p "Provider: zhipu" tip)
                       (eq 'mode-line-highlight (get-text-property ppos 'mouse-face txt))))))
      (setq dsh-emacs--modeline-provider nil
            dsh-emacs--modeline-model "m1"))))

;; Unknown provider → the segment disappears entirely (there is no
;; default-provider guess to fall back on)
(ert-deftest dsh-emacs-test-modeline-provider-segment-hidden-when-unknown ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-modeline-format-spec '(:separator " " :segments (provider model)))
        (dsh-emacs--modeline-model "m1")
        (dsh-emacs--modeline-provider nil))
    (let ((txt (dsh-emacs-modeline-format)))
      (ert-info ((format "%s" "provider-segment-hidden-when-unknown"))
        (should (and (string-match-p "m1" txt)
                     (not (string-match-p "zhipu" txt))))))))

;; The default spec has no provider segment (hidden by default; shown only when
;; opted in, while provider still disambiguates through the model segment's
;; tooltip)
(ert-deftest dsh-emacs-test-modeline-default-format-spec-excludes-provider ()
  :tags '(dsh-unit)
  (let ((segs (plist-get (default-value 'dsh-emacs-modeline-format-spec)
                         :segments)))
    (ert-info ((format "%s" "default-format-spec-excludes-provider"))
      (should (and (not (memq 'provider segs))
                   (memq 'model segs))))))

;; The fallback segment table used when the spec lacks :segments also omits
;; provider (it stays hidden even when provider is set)
(ert-deftest dsh-emacs-test-modeline-fallback-segments-exclude-provider ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((dsh-emacs-modeline-format-spec '(:separator " ")))
      (setq dsh-emacs--modeline-provider "zhipu"
            dsh-emacs--modeline-model "m1")
      (let ((txt (dsh-emacs-modeline-format)))
        (ert-info ((format "%s" "fallback-segments-exclude-provider"))
          (should (and (string-match-p "m1" txt)
                       (not (string-match-p "zhipu" txt))))))
      (setq dsh-emacs--modeline-provider nil))))

;; --- Test 5g: render dispatch forwards request/header to the mode-line feed ---
(ert-deftest dsh-emacs-test-modeline-render-dispatches-request-header-to-mode-line ()
  :tags '(dsh-unit)
  (let ((fired 0))
    (cl-letf (((symbol-function 'dsh-emacs-modeline-note-header)
               (lambda (_event) (setq fired (1+ fired)))))
      (dsh-emacs-render-event '(("type" . "request/header") ("seq" . 5)))
      (dsh-emacs-render-event '(("type" . "request/context") ("seq" . 6))))
    (ert-info ((format "%s" "render-dispatches-request-header-to-mode-line"))
      (should (= 1 fired)))))

;; --- Test 5m: session/projection frames update mode-line ctx% in real time
;; (push model) ---
;; Aligned with dsh web's session-projection push: the host pushes contextPressure
;; frames ({projectedTokens, pressureTokens, contextWindow}) along the event
;; stream, and the client routes them to the chat buffer by session and lands them
;; straight in the mode-line. Semantics: projected ?? pressure.
(ert-deftest dsh-emacs-test-modeline-session-projection-frame-updates-ctx-mode-line ()
  :tags '(dsh-unit)
  (let* ((buf (get-buffer-create " *t5m-chat*"))
         (seen nil))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local dsh-emacs--buffer-session "sess-proj"))
          (puthash "sess-proj" buf dsh-emacs--chat-buffers)
          (with-current-buffer buf
            (setq-local dsh-emacs--modeline-context-pressure nil
                        dsh-emacs--modeline-context-window-server nil))
          ;; Real frame payload → routed by session to the chat buffer's mode-line
          ;; (the projection frame handler reads key/value/sessionId from the payload)
          (dsh-emacs--events-apply-context-projection
           "sess-proj"
           '((projectedTokens . 354257)
             (pressureTokens . 350000)
             (contextWindow . 1000000)))
          (let ((p (buffer-local-value 'dsh-emacs--modeline-context-pressure buf))
                (w (buffer-local-value 'dsh-emacs--modeline-context-window-server buf)))
            (ert-info ((format "%s" "session-projection-frame-updates-ctx-mode-line"))
              (should (and (= 354257 p) (= 1000000 w))))
            (setq seen (list p w)))
          ;; Falls back to pressureTokens when projectedTokens is absent
          (dsh-emacs--events-apply-context-projection
           "sess-proj"
           '((pressureTokens . 13067) (contextWindow . 1000000)))
          (let ((p (buffer-local-value 'dsh-emacs--modeline-context-pressure buf)))
            (ert-info ((format "%s" "session-projection-falls-back-to-pressure"))
              (should (= 13067 p))))
          ;; Dispatch level: the full frame reaches the handler through --dispatch-json
          ;; (host-stream gate)
          (with-current-buffer buf
            (setq-local dsh-emacs--modeline-context-pressure nil
                        dsh-emacs--modeline-context-window-server nil))
          (let ((host-props (list (cons 'dsh-emacs-host-stream t))))
            (cl-letf (((symbol-function 'processp)
                       (lambda (_p) t))
                      ((symbol-function 'process-get)
                       (lambda (_p prop)
                         (cdr (assq prop host-props)))))
              (dsh-emacs-events--dispatch-json
               'host-proc
               (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                       "\"value\":{\"type\":\"projection\","
                       "\"sessionId\":\"sess-proj\","
                       "\"key\":\"contextPressure\",\"seq\":50,"
                       "\"value\":{\"projectedTokens\":88345,"
                       "\"pressureTokens\":88000,"
                       "\"contextWindow\":1000000}}}"))))
          (let ((p (buffer-local-value 'dsh-emacs--modeline-context-pressure buf)))
            (ert-info ((format "%s" "session-projection-frame-dispatch"))
              (should (= 88345 p)))))
      (remhash "sess-proj" dsh-emacs--chat-buffers)
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; --- Test 5i: the session struct parses the contextPressure projection
;; (pressure+window as a pair) ---
(ert-deftest dsh-emacs-test-modeline-session-struct-parses-context-pressure ()
  :tags '(dsh-unit)
  (let* ((session (dsh-protocol-session--from-alist
                   (list (cons 'sessionId "ctx-1")
                         (cons 'projections
                               (list (cons 'values
                                           (list (cons 'contextPressure
                                                       (list (cons 'pressureTokens 129946)
                                                             (cons 'projectedTokens 130028)
                                                             (cons 'contextWindow 262144)))))))))))
    (ert-info ((format "%s" "session-struct-parses-context-pressure"))
      (should (and (= 129946 (dsh-protocol-session-context-pressure session))
                   (= 262144 (dsh-protocol-session-context-window session)))))))

;; --- Test 5j: the ctx segment prefers the server snapshot (pressure/window
;; divided as a pair from one snapshot) ---
;; Simulates a real session: pressure 129.9k / window 262k ≈ 49.6%; the old formula
;; counted cumulative cacheRead (millions) as 100% full red — the server snapshot
;; path must give 49.6%.
(ert-deftest dsh-emacs-test-modeline-ctx-segment-uses-server-snapshot ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((dsh-emacs-modeline-format-spec '(:separator " " :segments (ctx))))
      (setq dsh-emacs--modeline-context-pressure 129946
            dsh-emacs--modeline-context-window-server 262144
            dsh-emacs--modeline-usage (dsh-emacs-make-usage 295045 90220 7020928 0))
      (let ((txt (dsh-emacs-modeline-format)))
        (ert-info ((format "%s" "ctx-segment-uses-server-snapshot"))
          (should (and (string-match "49.6%" txt)
                       (not (string-match "100.0%" txt))))))
      (setq dsh-emacs--modeline-context-pressure nil
            dsh-emacs--modeline-context-window-server nil
            dsh-emacs--modeline-usage nil))))

;; --- Test 5l: the ctx segment is hidden when there is no server snapshot
;; (cumulative usage no longer doubles as ctx% ---
(ert-deftest dsh-emacs-test-modeline-ctx-hidden-without-server-snapshot ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((dsh-emacs-modeline-format-spec '(:separator " " :segments (ctx))))
      ;; With only cumulative usage and no server pressure snapshot → the ctx segment
      ;; must not render. Cumulative cacheRead is the session total (several times the
      ;; window); treating it as "occupied" computes 100% full red — ctx% trusts only
      ;; the server's pressureTokens.
      (setq dsh-emacs--modeline-context-pressure nil
            dsh-emacs--modeline-context-window-server nil
            dsh-emacs--modeline-usage (dsh-emacs-make-usage 1000 500 8000000 0))
      (let ((txt (dsh-emacs-modeline-format)))
        (ert-info ((format "%s" "ctx-hidden-without-server-snapshot"))
          (should (string-empty-p txt))))
      (setq dsh-emacs--modeline-usage nil))))

;; --- Test 9: Mode-line functions exist ---
(ert-deftest dsh-emacs-test-modeline-mode-line-format-function-exists ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "mode-line-format function exists"))
    (should (fboundp 'dsh-emacs-modeline-format))))

(ert-deftest dsh-emacs-test-modeline-mode-line-setup-function-exists ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "mode-line-setup function exists"))
    (should (fboundp 'dsh-emacs-modeline-setup))))

(ert-deftest dsh-emacs-test-modeline-mode-line-update-function-exists ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "mode-line-update function exists"))
    (should (fboundp 'dsh-emacs-modeline-update))))

(ert-deftest dsh-emacs-test-modeline-mode-line-set-usage-function-exists ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "mode-line-set-usage function exists"))
    (should (fboundp 'dsh-emacs-modeline-set-usage))))

(ert-deftest dsh-emacs-test-modeline-modeline-percent-preserves-properties-and-match-data ()
  :tags '(dsh-unit)
  (let* ((input (concat (propertize "%中" 'face 'bold)
                        (propertize "%%" 'face 'italic)))
         (expected (concat (propertize "%%中" 'face 'bold)
                           (propertize "%%%%" 'face 'italic))))
    (string-match "b" "abc")
    (let ((saved (match-data)))
      (ert-info ((format "%s" "modeline-percent-preserves-properties-and-match-data"))
        (should (equal-including-properties
                 (dsh-emacs-modeline--escape-percent input) expected))
        (should (equal saved (match-data)))
        (should (equal (dsh-emacs-modeline--escape-percent "") ""))
        (should (equal (dsh-emacs-modeline--escape-percent "plain") "plain"))))))

(ert-deftest dsh-emacs-test-modeline-step-start-is-mode-line-only ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (let ((dsh-emacs-modeline-show-step t))
      (dsh-emacs-render-event
       (json-read-from-string
        "{\"type\":\"turn/start\",\"seq\":1,\"time\":900,\"data\":{\"turn\":1}}"))
      (dsh-emacs-render-event
       (json-read-from-string
        "{\"type\":\"step/start\",\"seq\":2,\"time\":1000,\"data\":{\"turn\":1,\"step\":2}}"))
      (ert-info ((format "%s" "step-start-is-mode-line-only"))
        (should (not (string-match-p "step"
                                     (buffer-substring-no-properties (point-min) (point-max)))))
        (should (equal "step 2" (dsh-emacs-modeline--step-indicator))))
      (dsh-emacs-render-event
       (json-read-from-string
        "{\"type\":\"step/end\",\"seq\":3,\"time\":3000,\"data\":{\"turn\":1,\"step\":2}}"))
      (ert-info ((format "%s" "step-end-keeps-badge-without-fake-elapsed"))
        (should (equal "step 2" (dsh-emacs-modeline--step-indicator))))
      (dsh-emacs-render-event
       (json-read-from-string
        "{\"type\":\"turn/end\",\"seq\":4,\"time\":4000,\"data\":{\"turn\":1,\"reason\":{\"kind\":\"completed\"}}}"))
      (ert-info ((format "%s" "turn-end-clears-step-badge"))
        (should (null dsh-emacs--modeline-step))
        (should (equal "" (dsh-emacs-modeline--step-indicator)))))))

;; The option gates the badge: off (the default) leaves the mode line alone.
(ert-deftest dsh-emacs-test-modeline-step-badge-off-by-default ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"turn/start\",\"seq\":1,\"time\":900,\"data\":{\"turn\":1}}"))
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"step/start\",\"seq\":2,\"time\":1000,\"data\":{\"turn\":1,\"step\":2}}"))
    (ert-info ((format "%s" "step-badge-off-by-default"))
      (should (null dsh-emacs-modeline-show-step))
      (should (equal 2 (plist-get dsh-emacs--modeline-step :step)))
      (should (equal "" (dsh-emacs-modeline--step-indicator))))
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"turn/end\",\"seq\":3,\"time\":3000,\"data\":{\"turn\":1,\"reason\":{\"kind\":\"completed\"}}}"))))

;; The badge shows the elapsed wall-clock time of a step over a second.
(ert-deftest dsh-emacs-test-modeline-step-badge-shows-frozen-elapsed ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (let ((dsh-emacs-modeline-show-step t))
      (setq dsh-emacs--ml-busy t
            dsh-emacs--modeline-step (list :turn 1 :step 2 :start 100.0 :end 103.0))
      (ert-info ((format "%s" "step-badge-shows-frozen-elapsed"))
        (should (equal "step 2 · 3s" (dsh-emacs-modeline--step-indicator)))))))

;; A step recorded while idle is not a status; the badge stays hidden.
(ert-deftest dsh-emacs-test-modeline-step-badge-hidden-when-idle ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (let ((dsh-emacs-modeline-show-step t))
      (dsh-emacs-modeline-note-step 1 3 t)
      (ert-info ((format "%s" "step-badge-hidden-when-idle"))
        (should (null dsh-emacs--ml-busy))
        (should (equal "" (dsh-emacs-modeline--step-indicator)))))))

;; A stray step/end for another step leaves the current badge alone.
(ert-deftest dsh-emacs-test-modeline-step-end-only-closes-its-own-step ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (dsh-emacs-modeline-note-step 1 2 t)
    (dsh-emacs-modeline-note-step 1 1 nil)
    (ert-info ((format "%s" "step-end-only-closes-its-own-step"))
      (should (equal 2 (plist-get dsh-emacs--modeline-step :step)))
      (should (null (plist-get dsh-emacs--modeline-step :end))))))

;; assistant/attempt: replay renders the collapsed diagnostic card.
(ert-deftest dsh-emacs-test-modeline-attempt-history-renders-collapsed-card ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/attempt\",\"seq\":4,\"time\":1000,\"data\":{\"turn\":2,\"step\":3,\"stream\":[{\"type\":\"reasoning-chunks\",\"time0\":1,\"index\":0,\"dt\":[1],\"texts\":[\"why it failed\"]},{\"type\":\"text-chunks\",\"time0\":2,\"index\":1,\"dt\":[1],\"texts\":[\"partial reply\"]}]}}"))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (ert-info ((format "%s" "attempt-history-renders-collapsed-card"))
        (should (string-match-p "Incomplete reply" text))
        (should (string-match-p "turn 2 · step 3" text))))))

;; --- Test 42: format-spec customize type is checkbox-editable (round-trips) ---
(require 'cus-edit)

(ert-deftest dsh-emacs-test-modeline-mode-line-format-spec-widget-roundtrip ()
  :tags '(dsh-unit)
  (let* ((spec (custom-variable-type 'dsh-emacs-modeline-format-spec))
         (buf (generate-new-buffer " *dsh-widget-test*")))
    (with-current-buffer buf
      (let ((w (widget-create spec)))
        (widget-value-set w '(:separator " • " :segments (model tokens)))
        (ert-info ((format "%s" "mode-line-format-spec-widget-roundtrip"))
          (should (equal '(:separator " • " :segments (model tokens))
                         (widget-value w))))
        ;; Unchecking a segment (subset) also round-trips
        (widget-value-set w '(:separator " " :segments (model)))
        (ert-info ((format "%s" "mode-line-format-spec-widget-subset"))
          (should (equal '(:separator " " :segments (model))
                         (widget-value w))))))
    (kill-buffer buf)))

;; --- Test 45: the doom segment includes the busy animation (regression: the
;; animation used to exist only in the vanilla splice, and the doom-modeline
;; branch's segment missed it, so the animation never showed) ---
;; doom-segment requires a dsh-emacs-mode buffer + buffer-local modeline state,
;; and the segment content is decided by format-spec (no effort/preset by
;; default, they must be given explicitly) — otherwise the test never fires
;; and silently disappears.
(ert-deftest dsh-emacs-test-modeline-doom-segment-includes-running-caption ()
  :tags '(dsh-unit)
  (let ((txt (with-temp-buffer
               (dsh-emacs-mode)
               (let ((dsh-emacs-modeline-format-spec
                      '(:separator " " :segments (model effort preset))))
                 (setq-local dsh-emacs--modeline-usage
                             (dsh-emacs-make-usage 100 50)
                             dsh-emacs--modeline-model "deepseek-v4-flash-0731"
                             dsh-emacs--modeline-effort "max"
                             dsh-emacs--modeline-preset "standard")
                 (dsh-emacs--ml-busy-set t)
                 (dsh-emacs-modeline--doom-segment)))))
    (ert-info ((format "%s" "doom-segment-includes-running-caption"))
      (should (string-match-p "deepseek-v4-flash-0731" txt))
      (should (string-match-p "max" txt))
      (should (string-match-p "standard" txt))
      (should (string-match-p "Deep diving" txt))
      (should (let ((caption (string-match "Deep diving" txt))
                    (model (string-match "deepseek-v4" txt)))
                (and caption model (< caption model)))))))

(ert-deftest dsh-emacs-test-modeline-doom-segment-idle-has-no-spinner ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--ml-busy nil)
        (dsh-emacs--modeline-usage nil))
    ;; When idle the doom segment shows the model segment but no progress-bar
    ;; animation
    (ert-info ((format "%s" "doom-segment-idle-has-no-spinner"))
      (should (not (string-match-p "█" (dsh-emacs-modeline--doom-segment)))))))

;; Register through Doom's layout API for custom layouts too, including a
;; layout defined after another chat has installed the segments already.
(ert-deftest dsh-emacs-test-modeline-doom-custom-layout-receives-whale-and-stats ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-modeline--doom-segment-installed nil))
    (cl-progv '(features doom-modeline--modelines doom-modeline--fn-alist)
        (list (cons 'doom-modeline features)
              (copy-tree '((main (buffer-info) (major-mode))
                           (custom (buffer-info) (major-mode))))
              '((dsh-emacs-whale . defined) (dsh-emacs-stats . defined)))
      (cl-letf (((symbol-function 'doom-modeline-def-segment) #'ignore)
                ((symbol-function 'doom-modeline-add-segment)
                 (lambda (segment anchor &optional position modeline)
                   (dolist (layout (symbol-value 'doom-modeline--modelines))
                     (when (or (null modeline) (eq modeline (car layout)))
                       (setcdr layout
                               (mapcar
                                (lambda (side)
                                  (cl-loop for item in side append
                                           (if (eq item anchor)
                                               (if (eq position :before)
                                                   (list segment item)
                                                 (list item segment))
                                             (list item))))
                                (cdr layout))))))))
        (dsh-emacs-modeline--install-doom-segment)
        (ert-info ((format "%s" "doom-custom-layout-receives-whale-and-stats"))
          (should (equal (assq 'custom (symbol-value 'doom-modeline--modelines))
                         '(custom (dsh-emacs-whale buffer-info)
                                  (major-mode dsh-emacs-stats)))))
        (set 'doom-modeline--modelines
             (append (symbol-value 'doom-modeline--modelines)
                     '((late-custom (buffer-info) (major-mode)))))
        (dsh-emacs-modeline--install-doom-segment)
        (dsh-emacs-modeline--install-doom-segment)
        (ert-info ((format "%s" "doom-late-layout-installed-without-duplicates"))
          (should (equal (cdr (assq 'late-custom
                                    (symbol-value 'doom-modeline--modelines)))
                         '((dsh-emacs-whale buffer-info) (major-mode dsh-emacs-stats))))
          (should (cl-every
                   (lambda (layout)
                     (and (= 1 (cl-count 'dsh-emacs-whale (cadr layout)))
                          (= 1 (cl-count 'dsh-emacs-stats (caddr layout)))))
                   (symbol-value 'doom-modeline--modelines))))))))

;; --- Test 73: mode-line pure-logic reinforcement (shorten-cwd / branch
;; cache) ---
;; mode-line--shorten-cwd's ~ prefix, non-home paths verbatim; cached-branch's
;; freshness logic (keeps the old value within the cache window, re-queries
;; once stale). detect-branch goes through real git, so it is mocked here to
;; pin down the remaining branches.
(ert-deftest dsh-emacs-test-modeline-mode-line-shorten-cwd-home-prefix ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((old-cache dsh-emacs--modeline-branch-cache))
      (unwind-protect
          (progn
            ;; shorten-cwd: home prefix shortened to a ~ prefix
            ;; (home-dir cut, relative part kept)
            (ert-info ((format "%s" "mode-line-shorten-cwd-home-prefix"))
              (should (equal (format "~%s" "proj")
                             (dsh-emacs-modeline--shorten-cwd
                              (format "%s/proj" (getenv "HOME"))))))
            (ert-info ((format "%s" "mode-line-shorten-cwd-non-home"))
              (should (equal "/opt/app" (dsh-emacs-modeline--shorten-cwd "/opt/app"))))
            ;; cached-branch: keeps the old value while the cache is fresh
            ;; (even if the mock changed it)
            (setq dsh-emacs--modeline-branch-cache nil)
            (cl-letf (((symbol-function 'dsh-emacs-modeline--detect-branch)
                       (lambda () "feature/x"))
                      (dsh-emacs-modeline-branch-refresh-interval 60))
              (let ((b1 (dsh-emacs-modeline--cached-branch)))
                (cl-letf (((symbol-function 'dsh-emacs-modeline--detect-branch)
                           (lambda () "other")))
                  (let ((b2 (dsh-emacs-modeline--cached-branch)))
                    (ert-info ((format "%s" "mode-line-cached-branch-fresh-keeps-value"))
                      (should (and (equal "feature/x" b1)
                                   (equal "feature/x" b2))))
                    ;; cache stale -> re-query the new value
                    (setf (cdr dsh-emacs--modeline-branch-cache)
                          (- (float-time) 999))
                    (ert-info ((format "%s" "mode-line-cached-branch-stale-refetches"))
                      (should (equal "other" (dsh-emacs-modeline--cached-branch))))))))
            ;; segment-branch: a branch renders wrapped in parentheses
            (cl-letf (((symbol-function 'dsh-emacs-modeline--cached-branch)
                       (lambda () "main")))
              (let ((seg (dsh-emacs-modeline--segment-branch)))
                (ert-info ((format "%s" "mode-line-segment-branch-renders"))
                  (should (equal "(main)" seg))
                  (should (equal "Git branch: main"
                                 (get-text-property 0 'help-echo seg))))))
            ;; segment-cwd: propertize face
            (let ((seg (dsh-emacs-modeline--segment-cwd)))
              (ert-info ((format "%s" "mode-line-segment-cwd-face"))
                (should (get-text-property 0 'face seg)))))
        (setq dsh-emacs--modeline-branch-cache old-cache)))))

;; Pending text paints the shared animation's cached frame without an extra pass.
;; Motion Line exposes its clock and visibility as variables (postmortem/002 in
;; that repository), so the engine needs no `cl-letf' on built-in subrs -- a
;; stub there cannot reach compiled code.  dsh's own elapsed clock still reads
;; `float-time', which is our interpreted code.
(ert-deftest dsh-emacs-test-modeline-busy-case-shares-text-redraw ()
  :tags '(dsh-unit)
  (skip-unless (featurep 'motion-line))
  (progn
    (unless (boundp 'motion-line-current-time-function)
      (error "Motion Line on the load path predates the clock/visibility seams"))
    (dolist (kind '(assistant thinking))
      (with-temp-buffer
        (let* ((now 100.0)
               (motion-line--timer nil)
               (motion-line--buffers nil)
               (redraws 0)
               (motion-line-current-time-function (lambda () now))
               (motion-line-visible-p-function (lambda () t)))
          (unwind-protect
              (cl-letf (((symbol-function 'float-time) (lambda (&rest _) now))
                        ((symbol-function 'dsh-emacs-modeline--running-frame)
                         (lambda (seconds) (format "frame-%.1f" seconds))))
                (dsh-emacs--ml-busy-set t)
                (set (make-local-variable
                      (if (eq kind 'assistant) 'dsh-emacs--streaming-assistant
                        'dsh-emacs--streaming-thinking))
                     (list :timer 'pending))
                (cl-letf (((symbol-function 'force-mode-line-update)
                           (lambda (&rest _) (cl-incf redraws))))
                  (setq now 100.5)
                  (cancel-timer motion-line--timer)
                  (with-temp-buffer (motion-line--tick))
                  (ert-info ((format "%s" (format "busy-%s-shares-text-redraw" kind)))
                    (should (equal (dsh-emacs--ml-busy-indicator) "frame-0.5 Deep diving · 0s"))
                    (should (zerop redraws)))
                  (setq dsh-emacs--streaming-assistant nil
                        dsh-emacs--streaming-thinking nil
                        now 101.0)
                  (cancel-timer motion-line--timer)
                  (motion-line--tick)
                  (ert-info ((format "%s" (format "busy-%s-redraws-during-text-silence" kind)))
                    (should (equal (dsh-emacs--ml-busy-indicator) "frame-1.0 Deep diving · 1s"))
                    (should (= redraws 1)))))
            (dsh-emacs--ml-busy-clear)))))))

(ert-deftest dsh-emacs-test-modeline-modeline-joins-status-without-pending-queue ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let* ((dsh-emacs-jobs--roster
            (list (dsh-protocol-job--from-alist
                   '((id . "running-job") (status . "running")))))
           (dsh-emacs--queue-items
            (list (dsh-emacs-test--queue-item "q" "queued" "Next turn")
                  (dsh-emacs-test--queue-item "s" "steering" "Next step")))
           (image '(image :type svg :data "test-svg"))
           (map (make-sparse-keymap))
           (children (propertize (concat " " (propertize " " 'display image) "3")
                                 'local-map map 'help-echo "3 children")))
      (cl-letf (((symbol-function 'dsh-emacs--ml-busy-indicator) (lambda () "█"))
                ((symbol-function 'dsh-emacs-modeline--step-indicator) (lambda () ""))
                ((symbol-function 'dsh-emacs-modeline--plan-indicator) (lambda () " Plan "))
                ((symbol-function 'dsh-emacs-subagent-indicator) (lambda () children))
                ((symbol-function 'dsh-emacs-modeline--modeinline) (lambda () "(model CH24%%) ")))
        (let* ((text (dsh-emacs-modeline--doom-segment))
               (icon-pos (string-match " 3" text)))
          (ert-info ((format "%s" "modeline-joins-status-without-pending-queue"))
            (should (equal (substring-no-properties text)
                           " █ Plan  3 (model CH24%%) ")))
          (ert-info ((format "%s" "modeline-spacing-preserves-svg-and-mouse-properties"))
            (should icon-pos)
            (should (equal (get-text-property icon-pos 'display text) image))
            (should (eq (get-text-property (1+ icon-pos) 'local-map text) map))
            (should (equal (get-text-property (1+ icon-pos) 'help-echo text) "3 children"))))
        (ert-info ((format "%s" "native-modeline-uses-the-same-composition-as-doom"))
          (should (equal (dsh-emacs-modeline--splice '("left" mode-line-modes "right"))
                         '("left" mode-line-modes
                           (:eval (dsh-emacs-modeline--doom-segment)) "right"))))
        (cl-letf (((symbol-function 'dsh-emacs-modeline--ml-indicator) (lambda () ""))
                  ((symbol-function 'dsh-emacs-subagent-indicator) (lambda () "")))
          (ert-info ((format "%s" "modeline-empty-indicators-add-no-extra-gaps"))
            (should (equal (dsh-emacs-modeline--doom-segment) " (model CH24%%) ")))
          (cl-letf (((symbol-function 'dsh-emacs-modeline--modeinline) (lambda () "")))
            (ert-info ((format "%s" "modeline-empty-composition-has-no-padding"))
              (should (equal (dsh-emacs-modeline--doom-segment) "")))))))))

(ert-deftest dsh-emacs-test-modeline-native-text-with-combined-activity ()
  :tags '(dsh-unit)
  (skip-unless (featurep 'motion-line))
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((dsh-emacs-modeline--doom-segment-installed nil)
          (motion-line--timer nil)
          (motion-line--buffers nil)
          (now 100.0)
          (motion-line-current-time-function (lambda () 100.0)))
      (unwind-protect
          (cl-letf (((symbol-function 'float-time) (lambda (&rest _) now))
                    ((symbol-function 'display-graphic-p) (lambda (&rest _) nil))
                    ((symbol-function 'dsh-emacs-modeline--whale-label)
                     (lambda () (propertize "DSH" 'display 'static-whale)))
                    ((symbol-function 'dsh-emacs-modeline--running-frame)
                     (lambda (phase)
                       (propertize "DSH" 'display (list 'frame phase)))))
            (should (equal-including-properties
                     (dsh-emacs-modeline--mode-name) "DSH"))
            (should (equal (dsh-emacs-modeline--ml-indicator) ""))
            (dsh-emacs--ml-busy-set t)
            (setq now 105.0)
            (motion-line-seek 'dsh-running 1.5)
            (let ((activity (dsh-emacs-modeline--ml-indicator)))
              (should (equal-including-properties
                       (dsh-emacs-modeline--mode-name) "DSH"))
              (should (equal activity " DSH Deep diving · 5s "))
              (should (equal (get-text-property 1 'display activity)
                             '(frame 1.5))))
            (dsh-emacs-modeline-note-execution
             (dsh-protocol-execution-event--from-alist
              '((type . "compaction/start") (seq . 1)
                (data . ((compactionId . "native"))))))
            (let ((activity (dsh-emacs-modeline--ml-indicator)))
              (should (equal-including-properties
                       (dsh-emacs-modeline--mode-name) "DSH"))
              (should (equal activity " DSH Compacting · 0s "))
              (should (get-text-property 1 'display activity))
              (should (eq (get-text-property 5 'local-map activity)
                          dsh-emacs-modeline--status-map)))
            (let ((dsh-emacs-modeline--doom-segment-installed t))
              (should (eq (get-text-property
                           0 'display (dsh-emacs-modeline--mode-name))
                          'static-whale))
              (should (equal (dsh-emacs-modeline--ml-indicator) ""))
              (should (equal (dsh-emacs-modeline--whale-tail-label)
                             "DSH Compacting · 0s")))
            (dsh-emacs--ml-busy-clear)
            (should (equal-including-properties
                     (dsh-emacs-modeline--mode-name) "DSH"))
            (should (equal (dsh-emacs-modeline--ml-indicator) "")))
        (dsh-emacs--ml-busy-clear)))))

;; A source-only installation can omit an installed Motion Line.
;; Use a fresh Emacs so this suite's already-loaded engine cannot mask failures.
(ert-deftest dsh-emacs-test-modeline-modeline-without-motion-line ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let* ((root (file-name-directory (locate-library "dsh-emacs")))
           (copy (make-temp-file "dsh-no-motion-line-" t))
           (probe (expand-file-name "probe.el" copy)))
      (unwind-protect
          (progn
            (dolist (file (directory-files root t "\\`dsh-emacs.*\\.el\\'"))
              (copy-file file (expand-file-name (file-name-nondirectory file) copy)))
            (with-temp-file probe
              (insert ";;; -*- lexical-binding: t; -*-\n")
              (prin1
               '(progn
                  (require 'cl-lib)
                  (require 'dsh-emacs)
                  (cl-assert (not (featurep 'motion-line)))
                  (cl-assert (not (fboundp 'motion-line-play)))
                  ;; A source-only install contains no assets directory.  The mask
                  ;; is decoded lazily, cached unchanged, and copied before tinting.
                  (cl-assert (null dsh-emacs-modeline--whale-tail-gif-data))
                  (let* ((data (dsh-emacs-modeline--whale-tail-animation-data "#000"))
                         (cached dsh-emacs-modeline--whale-tail-gif-data))
                    (cl-assert (not (multibyte-string-p data)))
                    (cl-assert (equal (substring data 16 19) (unibyte-string 0 0 0)))
                    (cl-assert (equal (secure-hash 'sha256 cached)
                                      "9bf571e538386cef0a76d4e741cae9c3df0a8dbaafa915be71119ea685d8826f"))
                    (dsh-emacs-modeline--whale-tail-animation-data "#000")
                    (cl-assert (eq cached dsh-emacs-modeline--whale-tail-gif-data)))
                  (with-temp-buffer
                    (dsh-emacs-mode)
                    (let ((redraws 0)
                          (dsh-emacs-modeline-show-step t))
                      (cl-letf (((symbol-function 'run-at-time)
                                 (lambda (&rest _) (error "Unexpected timer")))
                                ((symbol-function 'dsh-emacs-modeline--running-frame)
                                 (lambda (&rest _) (error "Unexpected animation")))
                                ((symbol-function 'dsh-emacs-modeline--whale-label)
                                 (lambda ()
                                   (propertize "DSH" 'display 'static-whale)))
                                ((symbol-function 'force-mode-line-update)
                                 (lambda (&rest _) (cl-incf redraws))))
                        (dsh-emacs--ml-busy-set nil)
                        (cl-assert (equal (dsh-emacs--ml-busy-indicator) ""))
                        (cl-assert (equal-including-properties
                                    (dsh-emacs-modeline--mode-name) "DSH"))
                        (setq redraws 0)
                        (dsh-emacs--ml-busy-set t)
                        (cl-assert dsh-emacs--ml-busy)
                        (cl-assert (> redraws 0))
                        (cl-assert (equal (dsh-emacs--ml-busy-indicator)
                                          "Deep diving"))
                        (cl-assert (equal-including-properties
                                    (dsh-emacs-modeline--mode-name) "DSH"))
                        (cl-assert (equal (dsh-emacs-modeline--ml-indicator)
                                          " Deep diving "))
                        (let ((start dsh-emacs--modeline-run-start))
                          (dsh-emacs--ml-busy-set t)
                          (cl-assert (= start dsh-emacs--modeline-run-start)))
                        (setq dsh-emacs--modeline-step '(:turn 1 :step 2))
                        (cl-assert (string-match-p
                                    "Deep diving.*step 2"
                                    (dsh-emacs-modeline--ml-indicator)))
                        (let* ((dsh-emacs-modeline--doom-segment-installed t)
                               (label (dsh-emacs-modeline--doom-major-mode
                                       (propertize " DSH " 'face 'mode-line))))
                          (cl-assert (equal label "Deep diving"))
                          (cl-assert (eq (get-text-property 0 'local-map label)
                                         mode-line-major-mode-keymap))
                          (cl-assert (not (string-match-p
                                           "Deep diving"
                                           (dsh-emacs-modeline--ml-indicator)))))
                        (dsh-emacs-modeline-note-execution
                         (dsh-protocol-execution-event--from-alist
                          '((type . "compaction/start") (seq . 1)
                            (data . ((compactionId . "static") (turn . 1))))))
                        (cl-assert (equal (dsh-emacs--ml-busy-indicator)
                                          "Compacting"))
                        (cl-assert (equal-including-properties
                                    (dsh-emacs-modeline--mode-name) "DSH"))
                        (cl-assert (equal (dsh-emacs-modeline--ml-indicator)
                                          " Compacting step 2 "))
                        (cl-assert
                         (not (get-text-property
                               0 'local-map (dsh-emacs-modeline--mode-name))))
                        (let* ((dsh-emacs-modeline--doom-segment-installed t)
                               (label (dsh-emacs-modeline--doom-major-mode
                                       (propertize " DSH " 'face 'mode-line))))
                          (cl-assert (equal label "Compacting"))
                          (cl-assert (eq (get-text-property 0 'local-map label)
                                         dsh-emacs-modeline--status-map))
                          (cl-assert (not (string-match-p
                                           "Compacting"
                                           (dsh-emacs-modeline--ml-indicator)))))
                        (setq redraws 0)
                        (dsh-emacs--ml-busy-clear)
                        (cl-assert (> redraws 0))
                        (cl-assert (not dsh-emacs--ml-busy))
                        (cl-assert (not dsh-emacs--modeline-step))
                        (cl-assert (not dsh-emacs--modeline-run-start))
                        (cl-assert (not dsh-emacs--modeline-compaction))
                        (cl-assert (not dsh-emacs--modeline-compaction-start))
                        (cl-assert (equal (dsh-emacs--ml-busy-indicator) ""))
                        (dsh-emacs-modeline-note-execution
                         (dsh-protocol-execution-event--from-alist
                          '((type . "compaction/start") (seq . 1)
                            (data . ((compactionId . "standalone"))))))
                        (cl-assert (not dsh-emacs--ml-busy))
                        (cl-assert (equal (dsh-emacs--ml-busy-indicator)
                                          "Compacting"))
                        (dsh-emacs-modeline-note-execution
                         (dsh-protocol-execution-event--from-alist
                          '((type . "compaction/end") (seq . 2)
                            (data . ((compactionId . "standalone"))))))
                        (cl-assert (not dsh-emacs--modeline-compaction-start))
                        (cl-assert (equal (dsh-emacs--ml-busy-indicator) "")))))
                  (princ "fallback-ok"))
               (current-buffer)))
            (with-temp-buffer
              (let ((status (call-process
                             (expand-file-name invocation-name invocation-directory)
                             nil t nil "-Q" "--batch" "-L" copy "-l" probe)))
                (ert-info ((format "%s" "modeline-without-motion-line"))
                  (should (equal status 0))
                  (should (string-match-p "fallback-ok" (buffer-string))))
                (unless (equal status 0) (princ (buffer-string))))))
        (delete-directory copy t)))))

;; Running images are indexed frames, never image-animate side effects.
(ert-deftest dsh-emacs-test-modeline-whale-uses-sixty-web-frames-at-50ms ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-modeline--whale-tail-frames nil)
        (created 0)
        (background 'dark))
    (with-temp-buffer
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                ((symbol-function 'image-type-available-p) (lambda (_) t))
                ((symbol-function 'frame-parameter) (lambda (&rest _) background))
                ((symbol-function 'color-values)
                 (lambda (color)
                   (pcase color
                     ("#4d6bfe" '(#x4d4d #x6b6b #xfefe))
                     ("#000" '(0 0 0))
                     (_ (error "Unexpected whale color: %s" color)))))
                ((symbol-function 'create-image)
                 (lambda (data type data-p &rest props)
                   (cl-incf created)
                   (append (list 'image :type type :data data :data-p data-p) props))))
        (let* ((first (dsh-emacs-modeline--running-frame 0))
               (next (dsh-emacs-modeline--running-frame 0.05))
               (last (dsh-emacs-modeline--running-frame 2.99))
               (image (get-text-property 0 'display first))
               (data (plist-get (cdr image) :data)))
          (ert-info ((format "%s" "whale-uses-sixty-web-frames-at-50ms"))
            (should (= created 60))
            (should (= (plist-get (cdr image) :index) 0))
            (should (= (plist-get (cdr (get-text-property 0 'display next)) :index) 1))
            (should (= (plist-get (cdr (get-text-property 0 'display last)) :index) 59))
            (should (= (plist-get (cdr image) :width) 18))
            (should (= (plist-get (cdr image) :height) 18))
            (should (equal (substring data 16 19) (unibyte-string #x4d #x6b #xfe))))
          (ert-info ((format "%s" "whale-asset-clears-all-sixty-frames-without-trails"))
            (should (= 60 (cl-loop with start = 0
                                   with gce = (regexp-quote
                                               (unibyte-string #x21 #xf9 4 9 5 0 0 0))
                                   while (string-match gce data start)
                                   do (setq start (match-end 0)) count t))))
          (setq background 'light)
          (let* ((changed (dsh-emacs-modeline--running-frame 0.5))
                 (changed-image (get-text-property 0 'display changed)))
            (ert-info ((format "%s" "whale-rebuilds-theme-color-without-resetting-time"))
              (should (= created 120))
              (should (= (plist-get (cdr changed-image) :index) 10))
              (should (equal (substring (plist-get (cdr changed-image) :data) 16 19)
                             (unibyte-string 0 0 0))))))))))

(ert-deftest dsh-emacs-test-modeline-whale-running-snapshot-keeps-playback-position ()
  :tags '(dsh-unit)
  (skip-unless (featurep 'motion-line))
  (with-temp-buffer
    (let ((now 100.0)
          (motion-line--timer nil)
          (motion-line--buffers nil))
      (cl-letf (((symbol-function 'float-time) (lambda (&rest _) now))
                ((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
        (unwind-protect
            (progn
              (dsh-emacs--ml-busy-set t)
              (setq now 101.5)
              (motion-line-seek 'dsh-running 1.5)
              (dsh-emacs--ml-busy-set t)
              (ert-info ((format "%s" "whale-running-snapshot-keeps-playback-position"))
                (should (equal (dsh-emacs--ml-busy-indicator) "DSH..  Deep diving · 1s")))
              (let ((dsh-emacs-modeline--doom-segment-installed nil))
                (should (equal-including-properties
                         (dsh-emacs-modeline--mode-name) "DSH"))
                (should (equal (dsh-emacs-modeline--ml-indicator)
                               " DSH..  Deep diving · 1s ")))
              (let ((dsh-emacs-modeline--doom-segment-installed t)
                    (dsh-emacs-modeline-show-step t)
                    (dsh-emacs--modeline-step '(:turn 1 :step 2 :start 100)))
                (ert-info ((format "%s" "doom-has-one-running-tail-and-keeps-step"))
                  (should (not (string-match-p "DSH" (dsh-emacs-modeline--ml-indicator))))
                  (should (string-match-p "step 2" (dsh-emacs-modeline--ml-indicator)))
                  (should (equal (dsh-emacs-modeline--whale-tail-label)
                                 "DSH..  Deep diving · 1s"))))
              (cl-letf (((symbol-function 'motion-line-play)
                         (lambda (&rest _) (error "Playback during redisplay"))))
                (dotimes (_ 3) (dsh-emacs-modeline--whale-tail-label)))
              (dsh-emacs--ml-busy-clear)
              (ert-info ((format "%s" "whale-stops-and-restores-idle-label"))
                (should (not (motion-line-playing-p 'dsh-running)))
                (should (equal (dsh-emacs--ml-busy-indicator) ""))
                (should (equal (dsh-emacs-modeline--whale-tail-label) "DSH"))))
          (dsh-emacs--ml-busy-clear))))))

;; The running caption counts local busy time independently of its visual loop.
(ert-deftest dsh-emacs-test-modeline-running-caption-starts-at-zero ()
  :tags '(dsh-unit)
  (skip-unless (featurep 'motion-line))
  (with-temp-buffer
    (let ((now 100.0)
          (motion-line--timer nil)
          (motion-line--buffers nil))
      (cl-letf (((symbol-function 'float-time) (lambda (&rest _) now))
                ((symbol-function 'display-graphic-p) (lambda (&rest _) nil))
                ((symbol-function 'dsh-emacs-modeline--running-frame)
                 (lambda (_) "tail")))
        (unwind-protect
            (progn
              (dsh-emacs--ml-busy-set t)
              (ert-info ((format "%s" "running-caption-starts-at-zero"))
                (should (equal (dsh-emacs--ml-busy-indicator) "tail Deep diving · 0s")))
              (setq now 112.9)
              (motion-line-seek 'dsh-running 12.9)
              (dsh-emacs--ml-busy-set t)
              (ert-info ((format "%s" "running-caption-survives-loops-and-snapshots"))
                (should (= dsh-emacs--modeline-run-start 100.0))
                (should (equal (dsh-emacs--ml-busy-indicator) "tail Deep diving · 12s")))
              (setq now 165.0)
              (motion-line-seek 'dsh-running 65.0)
              (ert-info ((format "%s" "running-caption-formats-long-turns"))
                (should (equal (dsh-emacs--ml-busy-indicator) "tail Deep diving · 1m05s")))
              (dsh-emacs--ml-busy-clear)
              (ert-info ((format "%s" "running-caption-clears-clock-and-text"))
                (should (null dsh-emacs--modeline-run-start))
                (should (equal (dsh-emacs--ml-busy-indicator) "")))
              (setq now 200.0)
              (dsh-emacs--ml-busy-set t)
              (ert-info ((format "%s" "running-caption-restarts-for-next-turn"))
                (should (= dsh-emacs--modeline-run-start 200.0))
                (should (equal (dsh-emacs--ml-busy-indicator) "tail Deep diving · 0s"))))
          (dsh-emacs--ml-busy-clear))))))

;; Compaction takes over one activity slot without replacing the turn clock.
(ert-deftest dsh-emacs-test-modeline-compaction-caption-replaces-running-status ()
  :tags '(dsh-unit)
  (skip-unless (featurep 'motion-line))
  (with-temp-buffer
    (dsh-emacs-mode)
    (let* ((now 100.0)
           (motion-line--timer nil)
           (motion-line--buffers nil)
           (motion-line-current-time-function (lambda () now))
           (compact (dsh-protocol-execution-event--from-alist
                     (dsh-test--execution-event
                      "compaction/start" 1
                      '((compactionId . "auto") (turn . 1))))))
      (cl-letf (((symbol-function 'float-time) (lambda (&rest _) now))
                ((symbol-function 'display-graphic-p) (lambda (&rest _) nil))
                ((symbol-function 'dsh-emacs-modeline--running-frame)
                 (lambda (phase) (format "tail-%.1f" phase))))
        (unwind-protect
            (progn
              (dsh-emacs--ml-busy-set t)
              (setq now 112.0)
              (dsh-emacs-modeline-note-execution compact)
              (let* ((native (dsh-emacs-modeline--ml-indicator))
                     (position (string-match "Compacting" native)))
                (ert-info ((format "%s" "compaction-caption-replaces-running-status"))
                  (should (equal (string-trim native) "tail-0.0 Compacting · 0s"))
                  (should (eq (get-text-property position 'local-map native)
                              dsh-emacs-modeline--status-map))
                  (should (string-match-p "turn 1"
                                          (get-text-property position 'help-echo native)))
                  (should (= dsh-emacs--modeline-run-start 100.0))
                  (should (= dsh-emacs--modeline-compaction-start 112.0))))
              (setq now 117.0)
              (motion-line-seek 'dsh-running 5.0)
              (dsh-emacs-modeline-reset-execution (list compact))
              (dsh-emacs-modeline-note-execution
               (dsh-protocol-execution-event--from-alist
                (dsh-test--execution-event
                 "compaction/start" 2
                 '((compactionId . "auto") (turn . 1)))))
              (ert-info ((format "%s" "compaction-clock-survives-snapshots-and-starts"))
                (should (= dsh-emacs--modeline-compaction-start 112.0))
                (should (equal (dsh-emacs--ml-busy-indicator)
                               "tail-2.0 Compacting · 5s")))
              (let* ((dsh-emacs-modeline--doom-segment-installed t)
                     (doom (dsh-emacs-modeline--doom-major-mode
                            (propertize " DSH " 'face 'mode-line)))
                     (position (string-match "Compacting" doom)))
                (ert-info ((format "%s" "compaction-doom-has-one-caption-and-details"))
                  (should (equal doom "tail-2.0 Compacting · 5s"))
                  (should (string-empty-p (dsh-emacs-modeline--ml-indicator)))
                  (should (eq (get-text-property position 'local-map doom)
                              dsh-emacs-modeline--status-map))
                  (should (string-match-p "turn 1"
                                          (get-text-property position 'help-echo doom)))))
              (setq now 120.0)
              (dsh-emacs-modeline-note-execution
               (dsh-protocol-execution-event--from-alist
                (dsh-test--execution-event
                 "compaction/end" 3 '((compactionId . "auto") (turn . 1)))))
              (ert-info ((format "%s" "compaction-end-restores-original-turn-clock"))
                (should (null dsh-emacs--modeline-compaction-start))
                (should (= dsh-emacs--modeline-run-start 100.0))
                (should (equal (dsh-emacs--ml-busy-indicator)
                               "tail-0.0 Deep diving · 20s")))
              (dsh-emacs--ml-busy-set nil)
              (dsh-emacs-modeline-note-execution
               (dsh-protocol-execution-event--from-alist
                (dsh-test--execution-event
                 "compaction/start" 4 '((compactionId . "standalone")))))
              (dsh-emacs--ml-busy-set nil)
              (ert-info ((format "%s" "compaction-standalone-owns-activity-slot"))
                (should (not dsh-emacs--ml-busy))
                (should (null dsh-emacs--modeline-run-start))
                (should (motion-line-playing-p 'dsh-running))
                (should (equal (dsh-emacs--ml-busy-indicator)
                               "tail-0.0 Compacting · 0s")))
              (dsh-emacs-modeline-note-execution
               (dsh-protocol-execution-event--from-alist
                (dsh-test--execution-event
                 "compaction/end" 5 '((compactionId . "standalone")))))
              (ert-info ((format "%s" "compaction-standalone-end-releases-animation"))
                (should (null dsh-emacs--modeline-compaction))
                (should (null dsh-emacs--modeline-compaction-start))
                (should (not (motion-line-playing-p 'dsh-running)))
                (should (not (assq 'dsh-running motion-line--players)))
                (should (string-empty-p (dsh-emacs--ml-busy-indicator)))))
          (dsh-emacs--ml-busy-clear))))))

;; Doom must append its face without overwriting the caption's sweep.
(ert-deftest dsh-emacs-test-modeline-running-caption-sweep-changes-properties-only ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((dsh-emacs--modeline-run-start 100.0)
          (image '(image :type gif :index 30))
          (dsh-emacs--ml-busy t))
      (cl-letf (((symbol-function 'float-time) (lambda (&rest _) 112.0))
                ((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                ((symbol-function 'face-foreground) (lambda (face &rest _) face))
                ((symbol-function 'color-name-to-rgb)
                 (lambda (face)
                   (if (eq face 'dsh-emacs-modeline-running-face)
                       '(0.25 0.25 0.25) '(0.75 0.75 0.75))))
                ((symbol-function 'dsh-emacs-modeline--running-frame)
                 (lambda (_) (propertize "tail" 'display image))))
        (let* ((rest (dsh-emacs-modeline--running-status 0))
               (sweep (dsh-emacs-modeline--running-status 1.5))
               (pos (+ (string-match "Deep diving" sweep) 5))
               (face (get-text-property pos 'face sweep)))
          (ert-info ((format "%s" "running-caption-sweep-changes-properties-only"))
            (should (equal (substring-no-properties rest) "tail Deep diving · 12s"))
            (should (equal rest sweep))
            (should (not (equal-including-properties rest sweep)))
            (should (equal (plist-get face :foreground) "#9f9f9f"))
            (should (equal (get-text-property 0 'display sweep) image)))
          (cl-letf (((symbol-function 'dsh-emacs-modeline--whale-tail-label)
                     (lambda () sweep)))
            (let ((formatted (dsh-emacs-modeline--doom-major-mode
                              (propertize " DSH " 'face 'mode-line))))
              (ert-info ((format "%s" "doom-keeps-shimmer-face-and-major-mode-menu"))
                (should (member face (get-text-property pos 'face formatted)))
                (should (equal (get-text-property 0 'display formatted) image))
                (should (eq (get-text-property pos 'local-map formatted)
                            mode-line-major-mode-keymap))
                (should (equal (get-text-property pos 'face sweep) face))))))))))

;; Doom pads both the mode name and its neighboring segments.
(ert-deftest dsh-emacs-test-modeline-doom-major-mode-shows-runtime-whale-tail ()
  :tags '(dsh-unit)
  (let* ((image '(image :type svg :data "whale-tail"))
         (map (make-sparse-keymap))
         (face '(:inherit (doom-modeline doom-modeline-buffer-major-mode)))
         (label (propertize "DSH" 'display image 'local-map map
                            'help-echo "Major mode" 'face face
                            'mouse-face 'highlight))
         (padded (concat " " label " ")))
    (with-temp-buffer
      (dsh-emacs-mode)
      (cl-letf (((symbol-function 'dsh-emacs-modeline--whale-tail-label)
                 (lambda () label)))
        (let ((right (dsh-emacs-modeline--doom-major-mode padded)))
          (ert-info ((format "%s" "doom-major-mode-shows-runtime-whale-tail"))
            (should (and (fboundp 'dsh-emacs-modeline--doom-major-mode)
                         (equal right "DSH")
                         (eq (get-text-property 0 'display right) image)
                         (equal (get-text-property 0 'face right) face)
                         (eq (get-text-property 0 'mouse-face right)
                             'highlight)
                         (equal (get-text-property 0 'help-echo right)
                                "Major mode")
                         (eq (get-text-property 0 'local-map right)
                             mode-line-major-mode-keymap)))))))
    (with-temp-buffer
      (ert-info ((format "%s" "doom-major-mode-preserves-other-buffers"))
        (should (and (fboundp 'dsh-emacs-modeline--doom-major-mode)
                     (eq (dsh-emacs-modeline--doom-major-mode padded)
                         padded)))))))

;; A running direct child keeps the whale and its clock alive after the
;; parent turn ends, without marking the session busy.
(ert-deftest dsh-emacs-test-modeline-running-child-keeps-whale-alive ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((dsh-emacs--ml-busy nil)
          (dsh-emacs--modeline-subagent-active nil)
          (dsh-emacs--modeline-run-start nil)
          (dsh-emacs--modeline-compaction nil))
      (cl-letf (((symbol-function 'float-time) (lambda (&optional _) 100.0)))
        (dsh-emacs-modeline-set-subagent-activity t)
        (ert-info ((format "%s" "running-child-lights-the-whale"))
          (should dsh-emacs--modeline-subagent-active)
          (should (= dsh-emacs--modeline-run-start 100.0))
          (should-not dsh-emacs--ml-busy)
          (should (string-match-p "Deep diving"
                                  (dsh-emacs--ml-busy-indicator))))
        ;; The parent turn ending must not stop a child's activity.
        (dsh-emacs--ml-busy-set nil)
        (ert-info ((format "%s" "parent-turn-end-keeps-child-animation"))
          (should (= dsh-emacs--modeline-run-start 100.0))
          (should (string-match-p "Deep diving"
                                  (dsh-emacs--ml-busy-indicator))))
        (dsh-emacs-modeline-set-subagent-activity nil)
        (ert-info ((format "%s" "last-child-settles-stops-the-whale"))
          (should-not dsh-emacs--modeline-subagent-active)
          (should-not dsh-emacs--modeline-run-start)
          (should (equal (dsh-emacs--ml-busy-indicator) "")))))))

(ert-deftest dsh-emacs-test-modeline-disconnect-clears-child-activity ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-set-subagent-activity t)
    (should dsh-emacs--modeline-run-start)
    (dsh-emacs-events-disconnect)
    (should-not dsh-emacs--modeline-subagent-active)
    (should-not dsh-emacs--modeline-run-start)
    (should (equal (dsh-emacs--ml-busy-indicator) ""))
    (when (featurep 'motion-line)
      (should-not (motion-line-playing-p 'dsh-running)))))

(provide 'dsh-test-modeline)
;;; dsh-test-modeline.el ends here
