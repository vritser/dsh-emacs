;;; dsh-test-questions.el --- Questions tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)

(defvar vertico-preselect)

;; --- Test 31f: an ask row renders dsh web's question card — the questions
;; and their numbered options with descriptions replace the argument JSON, and
;; the settled answers check the chosen options and carry free-text answers ---
(defconst dsh-emacs-test--ask-args
  (json-encode
   '((questions . [((id . "q1") (header . "Layout")
                    (question . "Which layout?")
                    (options . [((label . "Stacked")
                                 (description . "Classic rhythm."))
                                ((label . "Compact"))])
                    (multi_select . :json-false))
                   ((id . "q2") (question . "Which details?")
                    (options . [((label . "Chip"))])
                    (multi_select . t))])))
  "Wire arguments of a two-question `ask_user_question' call.")

(ert-deftest dsh-emacs-test-questions-ask-tool-uses-question-variant ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "ask-tool-uses-question-variant"))
    (should (equal "question" (car (dsh-emacs-render--tool-variant "ask_user_question"))))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'image-type-available-p) (lambda (&rest _) t))
              ((symbol-function 'create-image) (lambda (svg &rest _) svg)))
      (should (string-match-p
               "M12.5757 7.00012"
               (get-text-property
                0 'display
                (cdr (dsh-emacs-render--tool-variant "ask_user_question"))))))
    (let ((dsh-emacs-render-style 'simple))
      (should (equal "●" (substring-no-properties
                          (cdr (dsh-emacs-render--tool-variant
                                "ask_user_question"))))))
    (should (stringp (cdr (assoc "question" dsh-emacs--tool-icon-svgs))))))

(ert-deftest dsh-emacs-test-questions-ask-pending-card-shows-questionnaire ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs-tool-expand-by-default t)
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event 1 "k1" "ask_user_question"
                                      dsh-emacs-test--ask-args))
    (let ((block (dsh-emacs-test--tool-block-text
                  (dsh-emacs-render--make-namespace) "tool-k1")))
      (ert-info ((format "%s" "ask-pending-card-shows-questionnaire"))
        (should (string-match-p "Ask question · waiting" block))
        (should (string-match-p "^  Q1 · Layout — Which layout\\?$" block))
        (should (string-match-p "^  Q2 · Which details\\?$" block))
        (should (string-match-p "^   1\\.   Stacked$" block))
        (should (string-match-p "^        Classic rhythm\\.$" block))
        (should (string-match-p "^   1\\.   Chip$" block))
        (should (not (string-match-p "^  IN" block)))
        (should (not (string-match-p "^  OUT" block)))))))

(ert-deftest dsh-emacs-test-questions-ask-answered-card-marks-choices-and-free-text ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs-tool-expand-by-default t)
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event 1 "k2" "ask_user_question"
                                      dsh-emacs-test--ask-args))
    (dsh-emacs-render-tool-result
     (dsh-emacs-test--tool-result-event
      2 "k2" nil 0
      (json-encode '((answers . [((id . "q1") (selected . ["Stacked"]))
                                 ((id . "q2") (selected . [])
                                  (custom . "and a summary"))])))))
    (let ((block (dsh-emacs-test--tool-block-text
                  (dsh-emacs-render--make-namespace) "tool-k2")))
      (ert-info ((format "%s" "ask-answered-card-marks-choices-and-free-text"))
        (should (string-match-p "Ask question · 2/2 answered" block))
        (should (string-match-p "^   1\\. ✓ Stacked$" block))
        (should (string-match-p "^   2\\.   Compact$" block))
        (should (string-match-p "^  → and a summary$" block))))))

(ert-deftest dsh-emacs-test-questions-ask-settled-empty-question-reads-not-answered ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs-tool-expand-by-default t)
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event 1 "k3" "ask_user_question"
                                      dsh-emacs-test--ask-args))
    (dsh-emacs-render-tool-result
     (dsh-emacs-test--tool-result-event
      2 "k3" nil 0
      (json-encode '((answers . [((id . "q1") (selected . []))])))))
    (let ((block (dsh-emacs-test--tool-block-text
                  (dsh-emacs-render--make-namespace) "tool-k3")))
      (ert-info ((format "%s" "ask-settled-empty-question-reads-not-answered"))
        (should (string-match-p "Ask question · 0/1 answered" block))
        (should (string-match-p "^  Not answered$" block))))))

;; An abandoned ask is the user's own decision: the row interrupts instead of
;; failing red, like dsh web's ASK_ABORTED state.
(ert-deftest dsh-emacs-test-questions-ask-aborted-row-interrupts-instead-of-failing ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs-tool-expand-by-default t)
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event 1 "k4" "ask_user_question"
                                      dsh-emacs-test--ask-args))
    (dsh-emacs-render-tool-result
     (dsh-emacs-test--tool-result-event
      2 "k4" t nil "Error: ask_user_question was aborted before the user answered"
      '((name . "UserQuestionError") (code . "ASK_ABORTED")
        (reason . "User abandoned the questions"))))
    (let ((block (dsh-emacs-test--tool-block-text
                  (dsh-emacs-render--make-namespace) "tool-k4")))
      (ert-info ((format "%s" "ask-aborted-row-interrupts-instead-of-failing"))
        (should (string-match-p "◐ Ask question · interrupted" block))
        (should (string-match-p
                 (regexp-quote
                  "This question set was interrupted before answers were submitted.")
                 block))
        (should (not (string-match-p (regexp-quote "✗ failed") block)))))))

;; A dismissed ask (ASK_CANCELLED) is the user's own decision too: the row
;; settles green with the outcome, and the questionnaire stays as the record.
(ert-deftest dsh-emacs-test-questions-ask-cancelled-row-settles-instead-of-failing ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs-tool-expand-by-default t)
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event 1 "k8" "ask_user_question"
                                      dsh-emacs-test--ask-args))
    (dsh-emacs-render-tool-result
     (dsh-emacs-test--tool-result-event
      2 "k8" t nil "the user cancelled ask_user_question"
      '((name . "UserQuestionError") (code . "ASK_CANCELLED")
        (reason . "the user cancelled ask_user_question"))))
    (let ((block (dsh-emacs-test--tool-block-text
                  (dsh-emacs-render--make-namespace) "tool-k8")))
      (ert-info ((format "%s" "ask-cancelled-row-settles-instead-of-failing"))
        (should (string-match-p "Ask question · cancelled" block))
        (should (string-match-p "^  Q1 · Layout — Which layout\\?$" block))
        (should (string-match-p
                 (regexp-quote
                  "This question set was cancelled before answers were submitted.")
                 block))
        (should (not (string-match-p (regexp-quote "✗ failed") block)))))))

;; A malformed option element (a string or a number where the wire promised
;; an object) is dropped at the protocol boundary: the question still renders
;; and nothing signals out of the event stream.
(ert-deftest dsh-emacs-test-questions-ask-malformed-option-elements-are-dropped ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs-tool-expand-by-default t)
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event
      1 "k7" "ask_user_question"
      "{\"questions\":[{\"id\":\"q1\",\"header\":\"Layout\",\"question\":\"Which?\",\"options\":[\"Yes\",42,{\"label\":\"Stacked\"}]}]}"))
    (let ((block (dsh-emacs-test--tool-block-text
                  (dsh-emacs-render--make-namespace) "tool-k7")))
      (ert-info ((format "%s" "ask-malformed-option-elements-are-dropped"))
        (should (string-match-p "Ask question · waiting" block))
        (should (string-match-p "^  Layout — Which\\?$" block))
        (should (string-match-p "^   1\\.   Stacked$" block))
        (should (not (string-match-p "Yes" block)))))))

;; A call the ask card cannot describe (no usable questions) keeps the ioCard.
(ert-deftest dsh-emacs-test-questions-ask-unusable-arguments-keep-the-iocard ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs-tool-expand-by-default t)
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event 1 "k5" "ask_user_question" "{}"))
    (dsh-emacs-render-tool-result
     (dsh-emacs-test--tool-result-event 2 "k5" nil 0 "no questions given"))
    (let ((block (dsh-emacs-test--tool-block-text
                  (dsh-emacs-render--make-namespace) "tool-k5")))
      (ert-info ((format "%s" "ask-unusable-arguments-keep-the-iocard"))
        (should (string-match-p "^  OUT no questions given$" block))))))

;; A malformed question element (a string or a number where the wire promised
;; an object) must decline instead of signalling out of the event stream.
(ert-deftest dsh-emacs-test-questions-ask-malformed-question-elements-keep-the-iocard ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs-tool-expand-by-default t)
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event 1 "k6" "ask_user_question"
                                      "{\"questions\":[\"oops\",42,null]}"))
    (let ((block (dsh-emacs-test--tool-block-text
                  (dsh-emacs-render--make-namespace) "tool-k6")))
      (ert-info ((format "%s" "ask-malformed-question-elements-keep-the-iocard"))
        (should (string-match-p "Ask question" block))
        (should (string-match-p "oops" block))
        (should (not (string-match-p "Q1" block)))))))

;; the question protocol preserves the description text
;; and the raw option labels,
;; and treats only JSON true as multiple select.
(ert-deftest dsh-emacs-test-questions-question-protocol-keeps-details-and-option-order ()
  :tags '(dsh-unit)
  (let* ((wire '((id . "q-details") (question . "Which routes?")
                 (header . "Routes") (detail . "Choose every required route.")
                 (options . [((label . "A,B") (description . "Comma label."))
                             ((label . "C"))])
                 (multiSelect . t)))
         (question (dsh-protocol-question--from-alist wire)))
    (ert-info ((format "%s" "question-protocol-keeps-details-and-option-order"))
      (should (equal "q-details" (dsh-protocol-question-id question)))
      (should (equal "Which routes?" (dsh-protocol-question-text question)))
      (should (equal "Routes" (dsh-protocol-question-header question)))
      (should (equal "Choose every required route."
                     (dsh-protocol-question-detail question)))
      (should (listp (dsh-protocol-question-options question)))
      (should (equal '("A,B" "C")
                     (mapcar #'dsh-protocol-question-option-label
                             (dsh-protocol-question-options question))))
      (should (equal "Comma label."
                     (dsh-protocol-question-option-description
                      (car (dsh-protocol-question-options question)))))
      (should (null (dsh-protocol-question-option-description
                     (cadr (dsh-protocol-question-options question)))))
      (should (dsh-protocol-question-multi-select question))
      (should (eq question (dsh-protocol--struct #'dsh-protocol-question-p
                                                 #'dsh-protocol-question--from-alist
                                                 question))))
    (dolist (false-value '(nil :json-false))
      (ert-info ((format "%s" (format "question-protocol-single-for-%s" false-value)))
        (should (not (dsh-protocol-question-multi-select
                      (dsh-protocol-question--from-alist
                       `((multiSelect . ,false-value))))))))))

;; The ask tool's own arguments spell the flag `multi_select' where the ask
;; request spells it `multiSelect'; both decode to the same struct.
(ert-deftest dsh-emacs-test-questions-question-protocol-decodes-tool-argument-spelling ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "question-protocol-decodes-tool-argument-spelling"))
    (should (dsh-protocol-question-multi-select
             (dsh-protocol-question--from-alist '((id . "q") (multi_select . t)))))
    (should (not (dsh-protocol-question-multi-select
                  (dsh-protocol-question--from-alist
                   '((id . "q") (multi_select . :json-false))))))))

;; A malformed option element declines at the wire boundary instead of
;; signalling out of the constructor's `assq'.
(ert-deftest dsh-emacs-test-questions-question-protocol-drops-malformed-option-elements ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "question-protocol-drops-malformed-option-elements"))
    (should (equal '("Stacked")
                   (mapcar #'dsh-protocol-question-option-label
                           (dsh-protocol-question-options
                            (dsh-protocol-question--from-alist
                             '((id . "q") (question . "Which?")
                               (options . ["oops" ((label . "Stacked")) 42])))))))))

;; session identifier: prefer the active chat buffer's name; with no buffer
;; fall back to dsh: <id>, truncated; empty when there is no session-id (a
;; direct call in a test adds no prefix)
(ert-deftest dsh-emacs-test-questions-question-session-label-uses-chat-buffer-name ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *dsh-test-label-buf*")))
    (unwind-protect
        (progn
          (ert-info ((format "%s" "question-session-label-uses-chat-buffer-name"))
            (should (equal " *dsh-test-label-buf*"
                           (let ((dsh-emacs--chat-buffers
                                  (make-hash-table :test 'equal)))
                             (puthash "sess-l" buf dsh-emacs--chat-buffers)
                             (dsh-emacs--question-session-label "sess-l")))))
          (ert-info ((format "%s" "question-session-label-truncates-long"))
            (should (equal (concat "dsh: " (make-string 32 ?x) "…")
                           (let ((dsh-emacs--chat-buffers
                                  (make-hash-table :test 'equal))
                                 (dsh-emacs--sessions nil))
                             (dsh-emacs--question-session-label
                              (make-string 50 ?x))))))
          (ert-info ((format "%s" "question-session-label-nil-id-empty"))
            (should (equal ""
                           (let ((dsh-emacs--chat-buffers
                                  (make-hash-table :test 'equal)))
                             (dsh-emacs--question-session-label nil))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; candidates: numbered from 1, all of them the options themselves (no extra
;; "type an answer" sentinel -- typing text directly is the answer). The
;; number belongs to the option, so a comma-separated answer may use either
;; numbers or labels.
(ert-deftest dsh-emacs-test-questions-question-candidates-are-numbered-options ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "question-candidates-are-numbered-options"))
    (should (equal '("1. Yes" "2. No")
                   (dsh-emacs--question-pick-labels '("Yes" "No"))))))

;; answer values may be numeric candidates, bare labels,
;; or labels that already carry a numeric prefix;
;; all must be restored to the original label.
(ert-deftest dsh-emacs-test-questions-question-label-of-accepts-number-or-label ()
  :tags '(dsh-unit)
  (let ((labels '("Yes" "2. Version" "[x] Literal" "A,B")))
    (ert-info ((format "%s" "question-label-of-accepts-number-or-label"))
      (should (equal "Yes" (dsh-emacs--question-label-of "1. Yes" labels)))
      (should (equal "Yes" (dsh-emacs--question-label-of "Yes" labels)))
      (should (equal "2. Version" (dsh-emacs--question-label-of "2. 2. Version" labels)))
      (should (equal "2. Version" (dsh-emacs--question-label-of "2. Version" labels)))
      (should (equal "[x] Literal" (dsh-emacs--question-label-of "3. [x] Literal" labels)))
      (should (equal "A,B" (dsh-emacs--question-label-of "4. A,B" labels)))
      (should (equal "Yes" (dsh-emacs--question-label-of "1" labels)))
      (should (equal "2. Version" (dsh-emacs--question-label-of "2" labels)))
      (should (equal "[x] Literal" (dsh-emacs--question-label-of "3" labels)))
      (should (null (dsh-emacs--question-label-of "0" labels)))
      (should (null (dsh-emacs--question-label-of "9" labels)))
      (should (null (dsh-emacs--question-label-of "9. Nope" labels)))
      (should (null (dsh-emacs--question-label-of "Nope" labels))))))

;; unexpanded prefix: parse only when it is uniquely decidable
;; (case-insensitive); an ambiguous prefix stays literal.
(ert-deftest dsh-emacs-test-questions-question-label-of-resolves-unambiguous-prefix ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "question-label-of-resolves-unambiguous-prefix"))
    (should (equal "Alpha" (dsh-emacs--question-label-of "alph" '("Alpha" "Beta" "Gamma"))))
    (should (equal "Alpha" (dsh-emacs--question-label-of "ALPH" '("Alpha" "Beta" "Gamma"))))
    (should (equal "Beta" (dsh-emacs--question-label-of "be" '("Alpha" "Beta" "Gamma"))))
    (should (null (dsh-emacs--question-label-of "A" '("Alpha" "Alphabet"))))
    (should (null (dsh-emacs--question-label-of "Al" '("Alpha" "Alphabet"))))
    (should (equal "Alpha" (dsh-emacs--question-label-of "Alpha" '("Alpha" "Alphabet"))))
    (should (equal "2" (dsh-emacs--question-label-of "1" '("2" "Version"))))
    (should (equal "2" (dsh-emacs--question-label-of "2" '("2" "Version"))))
    (should (equal "Version" (dsh-emacs--question-label-of "2" '("Alpha" "Version"))))
    (should (equal "x" (dsh-emacs--question-label-of "10" (make-list 10 "x"))))
    (should (null (dsh-emacs--question-label-of "0" '("Alpha" "Beta"))))))

;; each candidate's description travels with the candidate
;; (annotation), no longer a tooltip that follows the highlight.
(ert-deftest dsh-emacs-test-questions-question-annotation-carries-description ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--question-current
          (dsh-protocol-question--from-alist
           '((id . "ann") (question . "Choose?")
             (options . [((label . "Alpha") (description . "Safe route."))
                         ((label . "Beta"))]))))
         (dsh-emacs--question-options
          (dsh-protocol-question-options dsh-emacs--question-current))
         (dsh-emacs--question-roster '("Alpha" "Beta")))
    (ert-info ((format "%s" "question-annotation-carries-description"))
      (should (equal "  Safe route." (dsh-emacs--question-annotation "1. Alpha")))
      (should (equal "  Safe route." (dsh-emacs--question-annotation "Alpha")))
      (should (equal "" (dsh-emacs--question-annotation "2. Beta")))
      (should (equal "" (dsh-emacs--question-annotation "something else")))
      (should (eq 'dsh-emacs-meta-face
                  (get-text-property 0 'face (dsh-emacs--question-annotation "Alpha")))))))

;; single select: likewise one read (CRM takes only one value),
;; numeric candidate -> original label.
(ert-deftest dsh-emacs-test-questions-question-choice-single-label ()
  :tags '(dsh-unit)
  (let ((reads '(("1. Yes"))))
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (&rest _) (or (pop reads) (error "Unexpected read")))))
      (ert-info ((format "%s" "question-choice-single-label"))
        (should (equal '((id . "q1") (selected "Yes"))
                       (dsh-emacs--question-choice
                        '((id . "q1") (question . "Proceed?")
                          (options . (((label . "Yes")) ((label . "No"))))))))))))

;; multiple select: the whole answer is read in one go; answers come back in
;; **the question's option order**, not input order (type 2 then 1 and A is
;; still first). Elements may be either a completed candidate or a bare
;; number CRM left unexpanded.
(ert-deftest dsh-emacs-test-questions-question-choice-multi-follows-option-order ()
  :tags '(dsh-unit)
  (let ((reads '(("3. Gamma" "1"))))
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (&rest _) (or (pop reads) (error "Unexpected read")))))
      (ert-info ((format "%s" "question-choice-multi-follows-option-order"))
        (should (equal '((id . "q2") (selected "Alpha" "Gamma"))
                       (dsh-emacs--question-choice
                        '((id . "q2") (question . "Pick?") (multiSelect . t)
                          (options . (((label . "Alpha")) ((label . "Beta"))
                                      ((label . "Gamma"))))))))))))

;; empty input = skip that question; skipping does not depend on any candidate.
(ert-deftest dsh-emacs-test-questions-question-choice-multi-empty-input-skips ()
  :tags '(dsh-unit)
  (let ((reads '(nil)))
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (&rest _) (pop reads))))
      (ert-info ((format "%s" "question-choice-multi-empty-input-skips"))
        (should (equal '((id . "q3") (selected . []))
                       (dsh-emacs--question-choice
                        '((id . "q3") (question . "Pick?") (multiSelect . t)
                          (options . (((label . "A")) ((label . "B"))))))))))))

;; no "type an answer" candidate: typing text directly is the answer, same
;; for multiple and single select, and there is only one read (no more
;; "choose Type answer... then read again" -- reads are taken only once).
(ert-deftest dsh-emacs-test-questions-question-choice-typed-text-is-the-answer ()
  :tags '(dsh-unit)
  (let ((served 0))
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (&rest _) (cl-incf served) '("my own note"))))
      (ert-info ((format "%s" "question-choice-typed-text-is-the-answer"))
        (should (equal '((id . "q4") (selected . []) (custom . "my own note"))
                       (dsh-emacs--question-choice
                        '((id . "q4") (question . "Pick?") (multiSelect . t)
                          (options . (((label . "A")) ((label . "B"))))))))
        (should (equal '((id . "q5") (selected . []) (custom . "my own note"))
                       (dsh-emacs--question-choice
                        '((id . "q5") (question . "Proceed?")
                          (options . (((label . "Yes")) ((label . "No"))))))))
        (should (= 2 served))))))

;; partly parseable, partly not -> treat the whole input as text: never keep
;; only the parseable part and silently drop the rest (e.g. typing 2,3 when
;; only two options remain).
(ert-deftest dsh-emacs-test-questions-question-choice-partially-matched-input-stays-text ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "question-choice-partially-matched-input-stays-text"))
    (should (equal '((id . "q6a") (selected . []) (custom . "2, 3"))
                   (cl-letf (((symbol-function 'completing-read-multiple)
                              (lambda (&rest _) '("2" "3"))))
                     (dsh-emacs--question-choice
                      '((id . "q6a") (question . "Pick?") (multiSelect . t)
                        (options . (((label . "Alpha")) ((label . "Beta")))))))))
    (should (equal '((id . "q6b") (selected . []) (custom . "1, nonsense"))
                   (cl-letf (((symbol-function 'completing-read-multiple)
                              (lambda (&rest _) '("1" "nonsense"))))
                     (dsh-emacs--question-choice
                      '((id . "q6b") (question . "Pick?") (multiSelect . t)
                        (options . (((label . "Alpha")) ((label . "Beta")))))))))))

;; cannot recall the options, just type text -> that text is the answer (the
;; Emacs completion convention), rather than an error or a silent drop.
(ert-deftest dsh-emacs-test-questions-question-choice-unmatched-input-is-free-text ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "question-choice-unmatched-input-is-free-text"))
    (should (equal '((id . "q6") (selected . []) (custom . "just do it"))
                   (cl-letf (((symbol-function 'completing-read-multiple)
                              (lambda (&rest _) (list "just do it"))))
                     (dsh-emacs--question-choice
                      '((id . "q6") (question . "Pick?") (multiSelect . t)
                        (options . (((label . "A")) ((label . "B")))))))))
    (should (equal '((id . "q6b") (selected . []) (custom . "one, two"))
                   (cl-letf (((symbol-function 'completing-read-multiple)
                              (lambda (&rest _) (list "one" "two"))))
                     (dsh-emacs--question-choice
                      '((id . "q6b") (question . "Pick?") (multiSelect . t)
                        (options . (((label . "A")) ((label . "B")))))))))))

;; No-option questions are still free text: empty input = skip, non-empty = custom.
(ert-deftest dsh-emacs-test-questions-question-choice-no-options-custom ()
  :tags '(dsh-unit)
  (let ((customs '("free text" "")))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) (pop customs))))
      (ert-info ((format "%s" "question-choice-no-options-custom"))
        (should (equal '((id . "q7") (selected . []) (custom . "free text"))
                       (dsh-emacs--question-choice
                        '((id . "q7") (question . "Say?"))))))
      (ert-info ((format "%s" "question-choice-no-options-empty-skips"))
        (should (equal '((id . "q7") (selected . []))
                       (dsh-emacs--question-choice
                        '((id . "q7") (question . "Say?")))))))))

;; The Skip command hands the action straight back to the reader (triggered by
;; dsh-emacs-question-skip-key).
(ert-deftest dsh-emacs-test-questions-question-skip-command-returns-skip-action ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "question-skip-command-returns-skip-action"))
    (should (equal "Skip this question"
                   (catch 'dsh-emacs--question-command
                     (dsh-emacs--question-skip-command))))))

;; reader-local keymap: default C-c C-s -> skip (a bare letter cannot be used, or
;; that letter could not be typed in the answer); rebinding takes effect; bare
;; letters stay typeable.
(ert-deftest dsh-emacs-test-questions-question-reader-binds-default-skip-key ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (use-local-map (make-sparse-keymap))
    (use-local-map (dsh-emacs--question-reader-keymap))
    (ert-info ((format "%s" "question-reader-binds-default-skip-key"))
      (should (eq (lookup-key (current-local-map) (kbd "C-c C-s"))
                  'dsh-emacs--question-skip-command))
      (should (null (lookup-key (current-local-map) (kbd "s"))))
      (should (null (lookup-key (current-local-map) (kbd "t")))))))

(ert-deftest dsh-emacs-test-questions-question-reader-honors-rebound-skip-key ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-question-skip-key "C-c s"))
    (with-temp-buffer
      (use-local-map (make-sparse-keymap))
      (use-local-map (dsh-emacs--question-reader-keymap))
      (ert-info ((format "%s" "question-reader-honors-rebound-skip-key"))
        (should (eq (lookup-key (current-local-map) (kbd "C-c s"))
                    'dsh-emacs--question-skip-command))
        (should (null (lookup-key (current-local-map) (kbd "C-c C-s"))))))))

(ert-deftest dsh-emacs-test-questions-question-reader-skip-key-can-be-disabled ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-question-skip-key nil))
    (with-temp-buffer
      (use-local-map (make-sparse-keymap))
      (ert-info ((format "%s" "question-reader-skip-key-can-be-disabled"))
        (should (not (eq (lookup-key (dsh-emacs--question-reader-keymap)
                                     (kbd "C-c C-s"))
                         'dsh-emacs--question-skip-command)))))))

;; reader setup: candidate annotations + question detail into the echo area (both
;; scoped to this minibuffer).
(ert-deftest dsh-emacs-test-questions-question-reader-setup-annotations-and-echo ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--question-current
          (dsh-protocol-question--from-alist
           '((id . "q8") (question . "Proceed?") (detail . "Context here")
             (options . [((label . "Yes") (description . "Go ahead"))
                         ((label . "No"))]))))
         (dsh-emacs--question-options
          (dsh-protocol-question-options dsh-emacs--question-current))
         (dsh-emacs--question-roster '("Yes" "No"))
         (echoed nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (setq echoed (apply #'format fmt args)))))
      (with-temp-buffer
        (use-local-map (make-sparse-keymap))
        (dsh-emacs--question-reader-setup)
        (let ((annotation (plist-get completion-extra-properties
                                     :annotation-function)))
          (ert-info ((format "%s" "question-reader-setup-annotations-and-echo"))
            (should (equal "  Go ahead" (funcall annotation "1. Yes")))
            (should (equal "  Go ahead" (funcall annotation "Yes")))
            (should (equal "" (funcall annotation "2. No")))
            (should (equal "Context here" echoed))))))))

;; the reader must preselect prompt, not the first item: a frontend preselecting the
;; first item inserts it into the input box, turning "empty input = skip" into
;; "accept the first item" (vertico-measured).
(ert-deftest dsh-emacs-test-questions-question-reader-preselects-the-prompt ()
  :tags '(dsh-unit)
  (let ((vertico-preselect 'first))
    (with-temp-buffer
      (use-local-map (make-sparse-keymap))
      (cl-letf (((symbol-function 'dsh-emacs--question-echo) #'ignore))
        (dsh-emacs--question-reader-setup))
      (ert-info ((format "%s" "question-reader-preselects-the-prompt"))
        (should (eq 'prompt vertico-preselect))))))

;; The multi-select prompt carries a separator hint.
(ert-deftest dsh-emacs-test-questions-question-reader-multi-prompt-hint ()
  :tags '(dsh-unit)
  (let ((prompt nil))
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (p &rest _) (setq prompt p) '("1. Yes"))))
      (dsh-emacs--question-choice
       '((id . "q8b") (question . "Proceed?") (multiSelect . t)
         (options . (((label . "Yes") (description . "Go ahead"))
                     ((label . "No"))))))
      (ert-info ((format "%s" "question-reader-multi-prompt-hint"))
        (should (equal "Proceed? (2,3 or names, or your own text; empty = skip): "
                       prompt))))))

;; Single select also explains the meaning of empty input in the prompt.
(ert-deftest dsh-emacs-test-questions-question-reader-single-prompt-hint ()
  :tags '(dsh-unit)
  (let ((prompt nil))
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (p &rest _) (setq prompt p) '("1. Yes"))))
      (dsh-emacs--question-choice
       '((id . "q9") (question . "Proceed?")
         (options . (((label . "Yes")) ((label . "No"))))))
      (ert-info ((format "%s" "question-reader-single-prompt-hint"))
        (should (equal "Proceed? (a name or your own text; empty = skip): "
                       prompt))))))

;; candidate order = the question's original option order: for numbered options
;; ("1. ...") the number is the order, and the completion frontend must not reorder.
;; Only an identity `display-sort-function'/`cycle-sort-function' on the collection
;; makes that possible -- otherwise vertico reorders by history/length/alphabet by
;; default (and across several questions the list order of the same question batch
;; even differs). CRM passes this metadata through `crm-completion-table' to the
;; frontend's collection (`crm--collection-fn'), so assertions must go through it
;; to cover the table the frontend actually sees.
(ert-deftest dsh-emacs-test-questions-question-reader-pins-option-order ()
  :tags '(dsh-unit)
  (let ((seen 'unset))
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (_prompt collection &rest _)
                 (setq seen collection)
                 '("2. Alpha"))))
      (dsh-emacs--question-choice
       '((id . "q-order") (question . "Pick?") (multiSelect . t)
         (options . (((label . "Zulu")) ((label . "Alpha"))
                     ((label . "Mike"))))))
      (let* ((crm-completion-table seen)
             (metadata (completion-metadata "" #'crm--collection-fn nil)))
        (ert-info ((format "%s" "question-reader-pins-option-order"))
          (should (eq #'identity
                      (completion-metadata-get metadata 'display-sort-function)))
          (should (eq #'identity
                      (completion-metadata-get metadata 'cycle-sort-function)))
          (should (equal '("1. Zulu" "2. Alpha" "3. Mike")
                         (all-completions "" #'crm--collection-fn nil))))))))

;; The preview command demos a whole batch of questions (multi-select + single
;; select + no-option): each question goes through the same reader, answers are
;; collected in frame order, then echoed as a whole (local demo, no RPC).
(ert-deftest dsh-emacs-test-questions-question-preview-batch-covers-every-shape ()
  :tags '(dsh-unit)
  (let ((option-reads 0)
        (echoed 'unset))
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (_prompt collection &rest _)
                 (setq option-reads (1+ option-reads))
                 (list (car (all-completions "" collection)))))
              ((symbol-function 'read-string)
               (lambda (&rest _) "my own addition"))
              ;; Capture only the preview's summary line: reader echo/cleanup also use
              ;; `message'.
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (when (equal fmt "Preview answers: %S")
                   (setq echoed (car args))))))
      (dsh-emacs-question-preview)
      (ert-info ((format "%s" "question-preview-batch-covers-every-shape"))
        (should (= 2 option-reads))
        (should (equal '("preview-1" "preview-2" "preview-3")
                       (mapcar (lambda (answer) (cdr (assq 'id answer))) echoed)))
        (should (equal '("UI")
                       (cdr (assq 'selected (nth 0 echoed)))))
        (should (equal "Run scripts/verify.sh"
                       (cadr (assq 'selected (nth 1 echoed)))))
        (should (equal "my own addition" (cdr (assq 'custom (nth 2 echoed)))))))))

;; Frame level: one question answered + one skipped -> answers cover the frame
;; (the skipped question has an empty selected).
(ert-deftest dsh-emacs-test-questions-question-skip-covers-frame-with-empty-selected ()
  :tags '(dsh-unit)
  (let ((picks '(("1. Yes") nil)))
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (&rest _) (pop picks))))
      (ert-info ((format "%s" "question-skip-covers-frame-with-empty-selected"))
        (should (equal '(((id . "qa") (selected "Yes"))
                         ((id . "qb") (selected . [])))
                       (dsh-emacs--collect-question-answers
                        '(((id . "qa") (question . "A?") (multiSelect . t)
                           (options . (((label . "Yes")))))
                          ((id . "qb") (question . "B?") (multiSelect . t)
                           (options . (((label . "Only")))))))))))))

;; 3b) frame dispatch: waterfall frame (user-questions/request) -> minibuffer answer
;; (no card rendered). Via `dsh-emacs-events--host-item' it goes through the full
;; `$events' dispatch surface: the host hands the waterfall with agentId to this
;; client, the events layer resolves the active chat buffer by agentId in
;; `dsh-emacs--chat-buffers' and then calls `dsh-emacs--question-requested'; the
;; answer goes back as a unary $events/result outcome (value = {answers: ...}, echoing
;; the eventId).
(ert-deftest dsh-emacs-test-questions-question-frame-answers-with-result-outcome ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *dsh-test-question*"))
         (responds nil))
    (unwind-protect
        (let ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
              (dsh-emacs-events--client-id "c1")
              (dsh-emacs-enable-notifications nil))
          (puthash "sess-q" chat dsh-emacs--chat-buffers)
          (with-current-buffer chat
            (setq-local dsh-emacs--buffer-session "sess-q"))
          (cl-letf (((symbol-function 'dsh-emacs--events-result-async)
                     (lambda (client-id event-id outcome cb)
                       (push (list client-id event-id outcome) responds)
                       (funcall cb t nil)))
                    ((symbol-function 'completing-read-multiple)
                     (lambda (&rest _) '("Yes"))))
            (dsh-emacs-events--host-item
             'process
             '((type . "waterfall")
               (event . "user-questions/request")
               (eventId . "rpc-q")
               (agentId . "sess-q")
               (request . ((questions .
                                      (((id . "q1") (question . "Proceed?")
                                        (options . (((label . "Yes"))
                                                    ((label . "No")))))))))))
            (let ((r (car responds)))
              (ert-info ((format "%s" "question-frame-answers-with-result-outcome"))
                (should (and (equal "c1" (nth 0 r))
                             (equal "rpc-q" (nth 1 r))
                             (equal '((kind . "result")
                                      (value . ((answers .
                                                         (((id . "q1")
                                                           (selected "Yes")))))))
                                    (nth 2 r))))))
            ;; No tab is inserted any more: after the answer the buffer has no question card
            (let ((text (with-current-buffer chat (buffer-string))))
              (ert-info ((format "%s" "question-frame-inserts-no-card"))
                (should (not (string-match-p "Question" text)))))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

;; 4) multi-question frame: sequential per-question minibuffer selection, only one
;; $events/result outcome sent after all answers
(ert-deftest dsh-emacs-test-questions-question-multi-answers-in-one-result ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *dsh-test-question-multi*"))
         (responds nil)
         (queue '("1. Yes" "1. X")))
    (unwind-protect
        (let ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
              (dsh-emacs-events--client-id "c1")
              (dsh-emacs-enable-notifications nil))
          (puthash "sess-m" chat dsh-emacs--chat-buffers)
          (with-current-buffer chat
            (setq-local dsh-emacs--buffer-session "sess-m"))
          (cl-letf (((symbol-function 'dsh-emacs--events-result-async)
                     (lambda (client-id event-id outcome cb)
                       (push (list client-id event-id outcome) responds)
                       (funcall cb t nil)))
                    ((symbol-function 'completing-read-multiple)
                     (lambda (&rest _)
                       (let ((row (pop queue)))
                         (and row (list row))))))
            (dsh-emacs-events--host-item
             'process
             '((type . "waterfall")
               (event . "user-questions/request")
               (eventId . "rpc-m")
               (agentId . "sess-m")
               (request . ((questions .
                                      (((id . "q1") (question . "One?")
                                        (options . (((label . "Yes")) ((label . "No")))))
                                       ((id . "q2") (question . "Two?")
                                        (multiSelect . t)
                                        (options . (((label . "X")) ((label . "Y")))))))))))
            (let ((r (car responds)))
              (ert-info ((format "%s" "question-multi-answers-in-one-result"))
                (should (= 1 (length responds)))
                (should (equal "c1" (nth 0 r)))
                (should (equal "rpc-m" (nth 1 r)))
                (should (equal '((kind . "result")
                                 (value . ((answers .
                                                    (((id . "q1") (selected "Yes"))
                                                     ((id . "q2") (selected "X")))))))
                               (nth 2 r)))))
            ;; Still no card is inserted (pure minibuffer answering)
            (let ((text (with-current-buffer chat (buffer-string))))
              (ert-info ((format "%s" "question-multi-inserts-no-card"))
                (should (not (string-match-p "Question" text)))))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

;; 5) frame dispatch: C-g/ESC -> abandon the whole question group: answered with
;; outcome kind `rejected' + error body (name/message = the kept cancelled intent,
;; the same signal as dsh web's abandon); the host withdraws that ask as cancelled.
;; Regression: the old code never answered, the host stayed pending,
;; and the agent turn hung forever.
(ert-deftest dsh-emacs-test-questions-question-frame-c-g-declines-waterfall ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *dsh-test-question-cg*"))
         (responds nil))
    (unwind-protect
        (let ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
              (dsh-emacs-events--client-id "c1")
              (dsh-emacs-enable-notifications nil))
          (puthash "sess-qc" chat dsh-emacs--chat-buffers)
          (with-current-buffer chat
            (setq-local dsh-emacs--buffer-session "sess-qc"))
          (cl-letf (((symbol-function 'dsh-emacs--events-result-async)
                     (lambda (client-id event-id outcome cb)
                       (push (list client-id event-id outcome) responds)
                       (funcall cb t nil)))
                    ((symbol-function 'completing-read-multiple)
                     (lambda (&rest _) (signal 'quit nil))))
            (dsh-emacs-events--host-item
             'process
             '((type . "waterfall")
               (event . "user-questions/request")
               (eventId . "rpc-qc")
               (agentId . "sess-qc")
               (request . ((questions .
                                      (((id . "q1") (question . "Proceed?")
                                        (options . (((label . "Yes")))))))))))
            (ert-info ((format "%s" "question-frame-c-g-declines-waterfall"))
              (should (equal (list (list "c1" "rpc-qc"
                                         '((kind . "rejected")
                                           (error . ((name . "cancelled")
                                                     (message . "User abandoned the questions"))))))
                             responds)))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

;; 6) frame dispatch: must answer while history is loading too (pending questions
;; replayed by the mux arrive when opened)
(ert-deftest dsh-emacs-test-questions-question-frame-during-history-load-answered ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *dsh-test-question-load*"))
         (responds nil))
    (unwind-protect
        (let ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
              (dsh-emacs-events--client-id "c1")
              (dsh-emacs-enable-notifications nil))
          (puthash "sess-ql" chat dsh-emacs--chat-buffers)
          (with-current-buffer chat
            (setq-local dsh-emacs--buffer-session "sess-ql")
            (setq-local dsh-emacs--event-history-loading t))
          (cl-letf (((symbol-function 'dsh-emacs--events-result-async)
                     (lambda (_client-id event-id _outcome cb)
                       (push event-id responds)
                       (funcall cb t nil)))
                    ((symbol-function 'completing-read-multiple)
                     (lambda (&rest _) '("Yes"))))
            (dsh-emacs-events--host-item
             'process
             '((type . "waterfall")
               (event . "user-questions/request")
               (eventId . "rpc-ql")
               (agentId . "sess-ql")
               (request . ((questions .
                                      (((id . "q1") (question . "Proceed?")
                                        (options . (((label . "Yes")))))))))))
            (ert-info ((format "%s" "question-frame-during-history-load-answered"))
              (should (equal '("rpc-ql") responds)))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

;; 7) waterfall for a session with no open chat buffer (foreign / other client) ->
;; this client does not answer and does not prompt; the events layer just hands it to
;; the next taker (outcome kind `next'). Retirement semantics now live in the
;; `$events' cancel frame (see tests 10 and 78e).
(ert-deftest dsh-emacs-test-questions-foreign-no-chat-waterfalls-handed-on ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *dsh-test-question-other*"))
         (responds nil)
         (prompted nil))
    (unwind-protect
        (let ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
              (dsh-emacs-events--client-id "c1")
              (dsh-emacs-enable-notifications nil))
          ;; Register only this client's session "mine"; the foreign session is absent (no
          ;; active chat buffer)
          (puthash "mine" chat dsh-emacs--chat-buffers)
          (with-current-buffer chat
            (setq-local dsh-emacs--buffer-session "mine"))
          (cl-letf (((symbol-function 'dsh-emacs--events-result-async)
                     (lambda (client-id event-id outcome cb)
                       (push (list client-id event-id outcome) responds)
                       (funcall cb t nil)))
                    ((symbol-function 'completing-read-multiple)
                     (lambda (&rest _) (setq prompted t) '("Yes")))
                    ((symbol-function 'dsh-emacs--approval-prompt)
                     (lambda (&rest _) (setq prompted t) t)))
            ;; Question waterfall for an unopened session -> handed to next taker, no prompt
            (dsh-emacs-events--host-item
             'process
             '((type . "waterfall")
               (event . "user-questions/request")
               (eventId . "rpc-o")
               (agentId . "other-session")
               (request . ((questions .
                                      (((id . "q1") (question . "Proceed?")
                                        (options . (((label . "Yes")))))))))))
            ;; Approval waterfall for an unopened session -> likewise next, no prompt
            (dsh-emacs-events--host-item
             'process
             '((type . "waterfall")
               (event . "approval/request")
               (eventId . "rpc-ao")
               (agentId . "other-session")
               (request . ((toolName . "fs") (reason . "outside")))))
            (ert-info ((format "%s" "foreign-no-chat-waterfalls-handed-on"))
              (should (null prompted))
              (should (= 2 (length responds)))
              (should (cl-every (lambda (r)
                                  (and (equal "c1" (nth 0 r))
                                       (equal '((kind . "next")) (nth 2 r))))
                                responds))
              (should (equal '("rpc-ao" "rpc-o")
                             (mapcar (lambda (r) (nth 1 r)) responds))))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

;; 8) concurrent questions from several sessions: the minibuffer is one global resource,
;; so frames from other sessions arriving mid-answer must queue
;; (FIFO) and be answered serially, and the prompt must carry the owning session
;; identifier
(ert-deftest dsh-emacs-test-questions-question-queue-serial-first ()
  :tags '(dsh-unit)
  (let* ((chat-a (get-buffer-create " *dsh-test-question-a*"))
         (chat-b (get-buffer-create " *dsh-test-question-b*"))
         (responds nil)
         (prompts nil)
         (b-pushed nil))
    (unwind-protect
        (let ((dsh-emacs--sessions nil)
              (dsh-emacs--chat-buffers (make-hash-table :test 'equal))
              (dsh-emacs-enable-notifications nil))
          (setq dsh-emacs--question-queue nil
                dsh-emacs--interaction-active nil)
          (with-current-buffer chat-a
            (setq-local dsh-emacs--buffer-session "sess-a"))
          (with-current-buffer chat-b
            (setq-local dsh-emacs--buffer-session "sess-b"))
          (cl-letf (((symbol-function 'dsh-emacs--events-result-async)
                     (lambda (_client-id event-id outcome cb)
                       (push (list event-id outcome) responds)
                       (funcall cb t nil)))
                    ((symbol-function 'completing-read-multiple)
                     (lambda (prompt candidates &rest _)
                       (push prompt prompts)
                       ;; While A's minibuffer waits, session B's question frame arrives: it
                       ;; must queue,
                       ;; not nest a prompt in the same minibuffer
                       (unless b-pushed
                         (setq b-pushed t)
                         (dsh-emacs--question-requested
                          chat-b "rpc-b" "sess-b"
                          (list (list (cons 'id "qb")
                                      (cons 'question "B asks?")
                                      (cons 'options
                                            (list (list (cons 'label "Only"))))))))
                       ;; COLLECTION is the completion table (read-order metadata); take the
                       ;; first item
                       ;; way the UI does, do not destructure directly.
                       (list (car (all-completions "" candidates))))))
            ;; A's frame arrives first (idle -> into the answer slot); while A is answering,
            ;; B's frame queues. questions shape matches the event dispatch: a list of
            ;; question
            ;; alists (an array on the wire, given directly as a list here).
            (dsh-emacs--question-requested
             chat-a "rpc-a" "sess-a"
             (list (list (cons 'id "qa")
                         (cons 'question "A asks?")
                         (cons 'options
                               (list (list (cons 'label "Yes")))))))
            ;; After A is answered B moves into the answer slot and continues;
            ;; $events/result
            ;; matches arrival order
            (let ((r2 (pop responds))
                  (r1 (pop responds)))
              (ert-info ((format "%s" "question-queue-serial-first"))
                (should (equal (list "rpc-a"
                                     '((kind . "result")
                                       (value . ((answers .
                                                          (((id . "qa")
                                                            (selected "Yes"))))))))
                               r1)))
              (ert-info ((format "%s" "question-queue-serial-second"))
                (should (equal (list "rpc-b"
                                     '((kind . "result")
                                       (value . ((answers .
                                                          (((id . "qb")
                                                            (selected "Only"))))))))
                               r2))))
            ;; Every prompt in the serial queue carries the Question N/M frame and its
            ;; question text
            (ert-info ((format "%s" "question-serial-prompts-framed"))
              (should (cl-some (lambda (p)
                                 (string-match-p "Question 1/1 — A asks?" p))
                               prompts))
              (should (cl-some (lambda (p)
                                 (string-match-p "Question 1/1 — B asks?" p))
                               prompts)))
            ;; After answering ends both the answer slot and the queue are empty (no leak
            ;; into
            ;; later tests)
            (ert-info ((format "%s" "question-queue-drained-clean"))
              (should (and (null dsh-emacs--interaction-active)
                           (null dsh-emacs--question-queue))))))
      (when (buffer-live-p chat-a) (kill-buffer chat-a))
      (when (buffer-live-p chat-b) (kill-buffer chat-b)))))

;; 9) duplicate frames for the same event-id (mux replay) must not ask again: while the
;; first frame is being answered, an arriving duplicate must be dropped, not
;; queued and not re-asked.
;; Regression: the same question used to be asked twice (after the first frame was
;; answered the copy entered the queue and popped up again).
(ert-deftest dsh-emacs-test-questions-question-replay-duplicate-asked-once ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *dsh-test-question-dup*"))
         (responds nil)
         (prompts 0)
         (dup-sent nil))
    (unwind-protect
        (let ((dsh-emacs--sessions nil)
              (dsh-emacs--chat-buffers (make-hash-table :test 'equal))
              (dsh-emacs-enable-notifications nil))
          (setq dsh-emacs--question-queue nil
                dsh-emacs--interaction-active nil)
          (with-current-buffer chat
            (setq-local dsh-emacs--buffer-session "sess-dup"))
          (cl-letf (((symbol-function 'dsh-emacs--events-result-async)
                     (lambda (_client-id event-id outcome cb)
                       (push (list event-id outcome) responds)
                       (funcall cb t nil)))
                    ((symbol-function 'completing-read-multiple)
                     (lambda (_prompt &rest _)
                       (setq prompts (1+ prompts))
                       ;; While the first frame is answered, a replay copy with the same
                       ;; event-id arrives
                       ;; -> must be dropped. The copy is injected once (pre-fix code
                       ;; answered it
                       ;; again and triggered this stub once more, a re-ask loop -- the very
                       ;; symptom
                       ;; this regression kills).
                       (unless dup-sent
                         (setq dup-sent t)
                         (dsh-emacs--question-requested
                          chat "rpc-dup" "sess-dup"
                          (list (list (cons 'id "qd")
                                      (cons 'question "Dup?")
                                      (cons 'options
                                            (list (list (cons 'label "Yes"))))))))
                       '("Yes"))))
            (dsh-emacs--question-requested
             chat "rpc-dup" "sess-dup"
             (list (list (cons 'id "qd")
                         (cons 'question "Dup?")
                         (cons 'options
                               (list (list (cons 'label "Yes")))))))
            (ert-info ((format "%s" "question-replay-duplicate-asked-once"))
              (should (= 1 prompts))
              (should (= 1 (length responds)))
              (should (equal '("rpc-dup") (mapcar #'car responds))))
            (ert-info ((format "%s" "question-replay-duplicate-drained-clean"))
              (should (and (null dsh-emacs--interaction-active)
                           (null dsh-emacs--question-queue))))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

;; 10) cancel frame (host withdraws a waterfall) -> the queued frame with the same
;; eventId retires, and a replayed requested->cancel pair no longer re-asks a settled
;; question. Retirement semantics live in the `$events' cancel frame (eventId);
;; the wire has no question/resolved push-only envelope.
;; Regression: cancel was ignored and the queued copy kept popping up to the user.
(ert-deftest dsh-emacs-test-questions-question-cancel-retires-queued-frame ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *dsh-test-question-cancel*"))
         (responds nil)
         (prompted nil))
    (unwind-protect
        (let ((dsh-emacs--sessions nil)
              (dsh-emacs--chat-buffers (make-hash-table :test 'equal))
              (dsh-emacs-events--client-id "c1")
              (dsh-emacs-enable-notifications nil))
          (puthash "sess-res" chat dsh-emacs--chat-buffers)
          (setq dsh-emacs--question-queue nil
                dsh-emacs--interaction-active '(question . "occupied"))
          (with-current-buffer chat
            (setq-local dsh-emacs--buffer-session "sess-res"))
          (cl-letf (((symbol-function 'dsh-emacs--events-result-async)
                     (lambda (_client-id _event-id _outcome cb)
                       (push t responds)
                       (funcall cb t nil)))
                    ((symbol-function 'completing-read-multiple)
                     (lambda (&rest _) (setq prompted t) '("Yes"))))
            ;; The copy arrives first (queued), then the host withdraws that eventId with a
            ;; cancel
            ;; frame (same replay order)
            (dsh-emacs-events--host-item
             'process
             '((type . "waterfall")
               (event . "user-questions/request")
               (eventId . "rpc-rs")
               (agentId . "sess-res")
               (request . ((questions .
                                      (((id . "q1") (question . "Proceed?")
                                        (options . (((label . "Yes")))))))))))
            (dsh-emacs-events--host-item
             'process
             '((type . "cancel") (eventId . "rpc-rs")))
            (ert-info ((format "%s" "question-cancel-retires-queued-frame"))
              (should (null dsh-emacs--question-queue)))
            ;; After the answer slot is cleared the queue is empty too -> no more popping
            ;; up, no more answering
            (setq dsh-emacs--interaction-active nil)
            (dsh-emacs--interaction-drain 'question)
            (ert-info ((format "%s" "question-cancel-never-prompts"))
              (should (null prompted))
              (should (null responds))
              (should (null dsh-emacs--question-queue)))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

;; --- Test 78a: approval/request frame dispatch -> approval -> answer (incl. while
;; history is loading) ---
;; When a sandbox tool needs a file outside the workspace, the host pushes a waterfall
;; over the `$events' stream
;; (approval/request, eventId + agentId + request.toolName/reason/callId).
;; The client shows the approval, reads the decision, and posts the outcome to the
;; unary endpoint POST /api/$events/result (value = ApprovalOutcome string). Like
;; questions, approvals are not gated on history loading.
(ert-deftest dsh-emacs-test-questions-approval-frame-answered ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *dsh-test-approval-dispatch*"))
         (responds nil))
    (unwind-protect
        (let ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
              (dsh-emacs-events--client-id "c1")
              (dsh-emacs-enable-notifications nil))
          (puthash "sess-ap" chat dsh-emacs--chat-buffers)
          (with-current-buffer chat
            (setq-local dsh-emacs--buffer-session "sess-ap"))
          (cl-letf (((symbol-function 'dsh-emacs--approval-prompt)
                     (lambda (&rest _) t))
                    ((symbol-function 'dsh-emacs--events-result-async)
                     (lambda (client-id event-id outcome cb)
                       (push (list client-id event-id outcome) responds)
                       (funcall cb t nil))))
            (dsh-emacs-events--host-item
             'process
             '((type . "waterfall")
               (event . "approval/request")
               (eventId . "rpc-ap")
               (agentId . "sess-ap")
               (request . ((toolName . "fs")
                           (reason . "read outside workspace")
                           (callId . "call-x")))))
            (let ((entry (car responds)))
              (ert-info ((format "%s" "approval-frame-answered"))
                (should (and (equal "c1" (nth 0 entry))
                             (equal "rpc-ap" (nth 1 entry))
                             (equal '((kind . "result") (value . "allowed-once"))
                                    (nth 2 entry))))))
            ;; Approvals must also be answered while history is loading (the mux replays
            ;; pending
            ;; approvals when opened)
            (with-current-buffer chat
              (setq-local dsh-emacs--event-history-loading t))
            (setq responds nil)
            (dsh-emacs-events--host-item
             'process
             '((type . "waterfall")
               (event . "approval/request")
               (eventId . "rpc-ap2")
               (agentId . "sess-ap")
               (request . ((toolName . "bash")))))
            (ert-info ((format "%s" "approval-frame-during-history-load-answered"))
              (should (and responds (equal "rpc-ap2" (nth 1 (car responds))))))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

;; Localized reasons travel through dispatch, queue, notification and the
;; ordinary decision reader.  Every expected string differs from raw reason.
(ert-deftest dsh-emacs-test-questions-approval-localization-preserves-audit-and-call-identity ()
  :tags '(dsh-unit)
  (let* ((wire '(("toolName" . "bash") ("callId" . "call-localized")
                 ("reason" . "Audit reason")
                 ("displayReason" . (("en" . "Display reason")
                                     ("zh" . "显示理由")))))
         (original (copy-tree wire))
         (request (dsh-protocol-approval-request--from-alist wire))
         (dsh-emacs-approval-language "zh"))
    (ert-info ((format "%s" "approval-localization-preserves-audit-and-call-identity"))
      (should (equal (dsh-protocol-approval-request-tool-name request) "bash"))
      (should (equal (dsh-protocol-approval-request-call-id request) "call-localized"))
      (should (equal (dsh-protocol-approval-request-reason request) "Audit reason"))
      (should (equal (dsh-emacs--approval-display-reason request) "显示理由"))
      (should (equal wire original)))))

(ert-deftest dsh-emacs-test-questions-approval-localized-queued ()
  :tags '(dsh-unit)
  (dolist (case
           '(("explicit-region" "ZH_cn.UTF-8" "en_US.UTF-8" nil
              ((en . "English") (zh . "中文") (zh-CN . "简体")) "简体")
             ("base-language" "zh-TW" nil nil
              ((en . "English") (zh . "中文")) "中文")
             ("message-locale" nil "zh_CN.UTF-8" "en_US.UTF-8"
              ((en . "English") (zh . "中文")) "中文")
             ("environment-locale" nil nil "zh_CN.UTF-8"
              ((en . "English") (zh . "中文")) "中文")
             ("lc-all-precedence" nil nil
              (("LC_ALL" . "zh_CN.UTF-8") ("LC_MESSAGES" . "en_US.UTF-8")
               ("LANG" . "en_US.UTF-8"))
              ((en . "English") (zh . "中文")) "中文")
             ("lc-messages-precedence" nil nil
              (("LC_ALL" . "") ("LC_MESSAGES" . "zh_CN.UTF-8")
               ("LANG" . "en_US.UTF-8"))
              ((en . "English") (zh . "中文")) "中文")
             ("english-fallback" "fr-FR" nil nil
              ((en . "English") (zh . "中文")) "English")
             ("blank-translation" "zh" nil nil
              ((en . "English") (zh . "  \n")) "English")
             ("malformed-translation" "zh" nil nil
              ((en . "English") (zh . 7)) "English")
             ("raw-fallback" "fr" nil nil ((zh . "中文")) "Raw reason")
             ("legacy" "zh" nil nil nil "Raw reason")
             ("malformed-map" "zh" nil nil :json-false "Raw reason")
             ("string-keys" "zh-CN" nil nil
              (("en" . "English") ("ZH_cn" . "简体")) "简体")))
    (pcase-let ((`(,name ,language ,messages ,environment ,translations ,expected)
                 case))
      (let ((chat (generate-new-buffer " *dsh-test-localized-approval*"))
            (dsh-emacs-approval-language language)
            (system-messages-locale messages)
            (process-environment (copy-sequence process-environment))
            (dsh-emacs--chat-buffers (make-hash-table :test 'equal))
            (dsh-emacs--interaction-active '(question . "occupied"))
            (dsh-emacs--question-queue nil)
            (dsh-emacs--approval-queue nil)
            (dsh-emacs-events--client-id "localized-client")
            prompted notified response)
        (unwind-protect
            (progn
              (dolist (variable '("LC_ALL" "LC_MESSAGES" "LANG"))
                (setenv variable nil))
              (if (listp environment)
                  (dolist (entry environment) (setenv (car entry) (cdr entry)))
                (setenv "LANG" environment))
              (puthash "localized-session" chat dsh-emacs--chat-buffers)
              (cl-letf (((symbol-function 'y-or-n-p)
                         (lambda (prompt) (setq prompted prompt) nil))
                        ((symbol-function 'dsh-emacs-notify--post)
                         (lambda (_session body _chat) (setq notified body)))
                        ((symbol-function 'dsh-emacs--events-result-async)
                         (lambda (client event outcome callback)
                           (setq response (list client event outcome))
                           (funcall callback t nil))))
                (dsh-emacs-events--host-item
                 'process
                 `((type . "waterfall") (event . "approval/request")
                   (eventId . "localized-event") (agentId . "localized-session")
                   (request . ((toolName . "bash") (callId . "localized-call")
                               (reason . "Raw reason")
                               (displayReason . ,translations)))))
                (ert-info ((format "%s" (concat "approval-localized-queued-" name)))
                  (should (null prompted))
                  (should (equal (nth 4 (car dsh-emacs--approval-queue)) expected))
                  (should (equal notified (concat "Approval: " expected))))
                ;; Changing language after queueing does not make the prompt
                ;; disagree with the notification already shown.
                (setq dsh-emacs--interaction-active nil
                      dsh-emacs-approval-language "de")
                (dsh-emacs--interaction-drain 'approval)
                (ert-info ((format "%s" (concat "approval-localized-reader-" name)))
                  (should (equal (substring-no-properties prompted) expected))
                  (should (eq (get-text-property 0 'face prompted)
                              'dsh-emacs-approval-justification-face))
                  (should (equal response '("localized-client" "localized-event"
                                            ((kind . "result") (value . "rejected")))))
                  (should (null dsh-emacs--approval-queue))
                  (should (null dsh-emacs--interaction-active)))))
          (kill-buffer chat))))))

;; --- Test 78a1: cancel closes a displayed question, no stale outcome sent back ---
(ert-deftest dsh-emacs-test-questions-question-active-cancel-closes-without-response ()
  :tags '(dsh-unit)
  (let ((chat (get-buffer-create " *dsh-test-question-active-cancel*"))
        (responds nil)
        (aborted nil))
    (unwind-protect
        (let ((dsh-emacs--question-queue nil)
              (dsh-emacs--interaction-active nil)
              (dsh-emacs--approval-queue nil)
              (dsh-emacs--waterfall-cancelled-event-id nil)
              (dsh-emacs-enable-notifications nil))
          (cl-letf (((symbol-function 'dsh-emacs--events-result-async)
                     (lambda (&rest args) (push args responds)))
                    ((symbol-function 'active-minibuffer-window)
                     (lambda () t))
                    ((symbol-function 'abort-recursive-edit)
                     (lambda () (setq aborted t) (signal 'quit nil)))
                    ((symbol-function 'completing-read-multiple)
                     (lambda (&rest _)
                       (dsh-emacs--question-cancelled "wf-active-q")
                       '("Yes"))))
            (dsh-emacs--question-requested
             chat "wf-active-q" "sess-q"
             '(((id . "q1") (question . "Proceed?")
                (options . (((label . "Yes")))))))
            (ert-info ((format "%s" "question-active-cancel-closes-without-response"))
              (should aborted)
              (should (null responds))
              (should (null dsh-emacs--interaction-active))
              (should (null dsh-emacs--waterfall-cancelled-event-id)))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

;; --- Test 78b: approval allow-once / reject decision -> $events/result outcome ---
(ert-deftest dsh-emacs-test-questions-approval-allow-once-outcome ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *dsh-test-approval-decision*"))
         (dsh-emacs-events--client-id "approval-client")
         (responds nil))
    (unwind-protect
        (let ((dsh-emacs-enable-notifications nil))
          (with-current-buffer chat
            (setq-local dsh-emacs--buffer-session "sess-ad"))
          (cl-letf (((symbol-function 'dsh-emacs--approval-prompt)
                     (lambda (&rest _) t))
                    ((symbol-function 'dsh-emacs--events-result-async)
                     (lambda (client-id event-id outcome cb)
                       (push (list client-id event-id outcome) responds)
                       (funcall cb t nil))))
            (dsh-emacs--approval-requested
             chat "rpc-ad1" "sess-ad" "bash"
             "needs /etc/passwd" "call-1")
            (ert-info ((format "%s" "approval-allow-once-outcome"))
              (should (equal responds
                             '(("approval-client" "rpc-ad1"
                                ((kind . "result")
                                 (value . "allowed-once"))))))))
          (setq responds nil)
          (cl-letf (((symbol-function 'dsh-emacs--approval-prompt)
                     (lambda (&rest _) nil))
                    ((symbol-function 'dsh-emacs--events-result-async)
                     (lambda (client-id event-id outcome cb)
                       (push (list client-id event-id outcome) responds)
                       (funcall cb t nil))))
            (dsh-emacs--approval-requested
             chat "rpc-ad2" "sess-ad" "fs"
             "write outside workspace" "call-2")
            (ert-info ((format "%s" "approval-reject-outcome"))
              (should (equal responds
                             '(("approval-client" "rpc-ad2"
                                ((kind . "result")
                                 (value . "rejected")))))))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

;; --- Test 78h: approval prompt over multiple lines: full justification + concrete
;; bash command ---
;; The prompt reads `dsh-emacs--tool-states' in the chat buffer context (the rendered
;; tool/call tracked by callId in the render layer), bash shows the real command line;
;; the justification is shown in full, untruncated, separated from the command by a
;; blank line. The two parts are colored separately: justification light orange
;; (dsh-emacs-approval-justification-face), command gray
;; (dsh-emacs-approval-command-face).
(ert-deftest dsh-emacs-test-questions-approval-prompt-full-justification-and-command ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *dsh-test-approval-command*"))
         (captured nil)
         (just "the command reads /etc/hostname outside the workspace so we can identify this machine"))
    (unwind-protect
        (let ((dsh-emacs--approval-queue nil)
              (dsh-emacs--interaction-active nil)
              (dsh-emacs-enable-notifications nil))
          (with-current-buffer chat
            (setq dsh-emacs--tool-states (make-hash-table :test 'equal))
            (puthash "call-1"
                     (list :state 'pending :variant "bash" :icon ">_"
                           :title "Bash" :summary "cat /etc/os-release"
                           :args "$ cat /etc/os-release" :call-time nil :ns nil)
                     dsh-emacs--tool-states))
          (cl-letf (((symbol-function 'y-or-n-p)
                     (lambda (prompt) (setq captured prompt) t))
                    ((symbol-function 'dsh-emacs--events-result-async)
                     (lambda (&rest _) nil)))
            ;; Read transcript state in the chat buffer context via drain
            (dsh-emacs--approval-requested
             chat "rpc-h" "sess-h" "bash" just "call-1")
            (ert-info ((format "%s" "approval-prompt-full-justification-and-command"))
              (should (equal (concat just "\n\n$ cat /etc/os-release")
                             (substring-no-properties captured))))
            (ert-info ((format "%s" "approval-prompt-justification-face"))
              (should (eq 'dsh-emacs-approval-justification-face
                          (get-text-property 0 'face captured))))
            (ert-info ((format "%s" "approval-prompt-command-face"))
              (should (eq 'dsh-emacs-approval-command-face
                          (get-text-property (+ 2 (length just)) 'face captured))))
            ;; callId not found (replay before the tool/call render) -> show justification
            ;; only
            (setq captured nil)
            (dsh-emacs--approval-requested
             chat "rpc-h2" "sess-h" "bash" just "call-unknown")
            (ert-info ((format "%s" "approval-prompt-falls-back-to-justification"))
              (should (equal just (substring-no-properties captured))))
            (ert-info ((format "%s" "approval-prompt-fallback-still-colored"))
              (should (eq 'dsh-emacs-approval-justification-face
                          (get-text-property 0 'face captured))))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

;; --- Test 78c: approval aborted with C-g -> answered as default rejection (with no
;; answer the host blocks forever on the pending approval), slot and queue cleared ---
(ert-deftest dsh-emacs-test-questions-approval-c-g-answers-rejected ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *dsh-test-approval-cg*"))
         (responds nil))
    (unwind-protect
        (let ((dsh-emacs-enable-notifications nil))
          (with-current-buffer chat
            (setq-local dsh-emacs--buffer-session "sess-cg"))
          (cl-letf (((symbol-function 'dsh-emacs--approval-prompt)
                     (lambda (&rest _) (signal 'quit nil)))
                    ((symbol-function 'dsh-emacs--events-result-async)
                     (lambda (_client-id event-id outcome cb)
                       (push (list event-id outcome) responds)
                       (funcall cb t nil))))
            (dsh-emacs--approval-requested
             chat "rpc-cg" "sess-cg" "bash" nil nil)
            (ert-info ((format "%s" "approval-c-g-answers-rejected"))
              (should (and (equal responds
                                  (list (list "rpc-cg"
                                              '((kind . "result")
                                                (value . "rejected")))))
                           (null dsh-emacs--interaction-active)
                           (null dsh-emacs--approval-queue))))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

;; --- Test 78d: mux replays the same approval (same eventId) -> ask only once ---
(ert-deftest dsh-emacs-test-questions-approval-replay-dedup-single-prompt ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *dsh-test-approval-dedup*")))
    (unwind-protect
        (let ((dsh-emacs--approval-queue
               (list (list chat "wf-d0" "sess-d" "bash" "reason" nil)))
              (dsh-emacs--interaction-active '(approval . "wf-d1")))
          ;; mux replay of the same eventId: already queued -> not enqueued again
          (dsh-emacs--approval-requested
           chat "wf-d0" "sess-d" "bash" "reason" nil)
          ;; same eventId currently being answered -> not enqueued either
          (dsh-emacs--approval-requested
           chat "wf-d1" "sess-d" "bash" "reason" nil)
          (ert-info ((format "%s" "approval-replay-dedup-single-prompt"))
            (should (= 1 (length dsh-emacs--approval-queue)))))
      (kill-buffer chat))))

;; --- Test 78e: cancel frame withdraws the same queued approval frame ---
(ert-deftest dsh-emacs-test-questions-approval-cancel-drops-only-matching-frame ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *dsh-test-approval-cancel*")))
    (unwind-protect
        (progn
          (setq dsh-emacs--approval-queue
                (list (list chat "wf-e1" "sess-e" "bash" "reason" nil)
                      (list chat "wf-e2" "sess-e" "fs" "r" nil)))
          (dsh-emacs--approval-cancelled "wf-e1")
          (ert-info ((format "%s" "approval-cancel-drops-only-matching-frame"))
            (should (and (= 1 (length dsh-emacs--approval-queue))
                         (equal "wf-e2" (nth 1 (car dsh-emacs--approval-queue)))))))
      (setq dsh-emacs--approval-queue nil)
      (when (buffer-live-p chat) (kill-buffer chat)))))

;; --- Test 78e1: cancel closes a displayed approval, no stale reject sent back ---
(ert-deftest dsh-emacs-test-questions-approval-active-cancel-closes-without-response ()
  :tags '(dsh-unit)
  (let ((chat (get-buffer-create " *dsh-test-approval-active-cancel*"))
        (responds nil)
        (after-question-cancel nil)
        (aborted nil))
    (unwind-protect
        (let ((dsh-emacs--question-queue nil)
              (dsh-emacs--interaction-active nil)
              (dsh-emacs--approval-queue nil)
              (dsh-emacs--waterfall-cancelled-event-id nil)
              (dsh-emacs-enable-notifications nil))
          (cl-letf (((symbol-function 'dsh-emacs--events-result-async)
                     (lambda (&rest args) (push args responds)))
                    ((symbol-function 'active-minibuffer-window)
                     (lambda () t))
                    ((symbol-function 'abort-recursive-edit)
                     (lambda () (setq aborted t) (signal 'quit nil)))
                    ((symbol-function 'dsh-emacs--approval-prompt)
                     (lambda (&rest _)
                       ;; Host cancel dispatch checks questions first.  The
                       ;; matching id alone must not abort an approval reader.
                       (dsh-emacs--question-cancelled "wf-active-a")
                       (setq after-question-cancel
                             (list aborted
                                   dsh-emacs--waterfall-cancelled-event-id
                                   dsh-emacs--interaction-active))
                       (dsh-emacs--approval-cancelled "wf-active-a")
                       t)))
            (dsh-emacs--approval-requested
             chat "wf-active-a" "sess-a" "bash" "reason" nil)
            (ert-info ((format "%s" "approval-active-cancel-closes-without-response"))
              (should (equal after-question-cancel
                             '(nil nil (approval . "wf-active-a"))))
              (should aborted)
              (should (null responds))
              (should (null dsh-emacs--interaction-active))
              (should (null dsh-emacs--waterfall-cancelled-event-id)))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

;; --- Test 78f: approvals and questions share one minibuffer slot (question first ->
;; approval queues and takes over) ---
;; An approval frame arriving while a question occupies the slot must queue (never
;; nest y-or-n-p in a running completing-read); only after the question queue is
;; empty does drain take over the approval frame.
(ert-deftest dsh-emacs-test-questions-approval-queued-while-question-active ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *dsh-test-approval-slot-qfirst*"))
         (trace nil))
    (unwind-protect
        (let ((dsh-emacs--question-queue nil)
              (dsh-emacs--interaction-active '(question . "occupied"))
              (dsh-emacs--approval-queue nil)
              (dsh-emacs-enable-notifications nil))
          (cl-letf (((symbol-function 'dsh-emacs--approval-prompt)
                     (lambda (&rest _) (push :approval-prompt trace) t))
                    ((symbol-function 'completing-read-multiple)
                     (lambda (&rest _) (push :question-prompt trace) '("Yes")))
                    ((symbol-function 'dsh-emacs--events-result-async)
                     (lambda (_client-id event-id _outcome cb)
                       (push (list :respond event-id) trace)
                       (funcall cb t nil))))
            ;; An approval arriving during a question -> only enqueued, no prompt
            (dsh-emacs--approval-requested
             chat "rpc-ap" "sess-s" "bash" "outside" nil)
            (ert-info ((format "%s" "approval-queued-while-question-active"))
              (should (and (null trace)
                           (= 1 (length dsh-emacs--approval-queue)))))
            ;; Question finished (queue empty) -> handoff takes over the queued approval
            (setq dsh-emacs--interaction-active nil)
            (setq dsh-emacs--question-queue
                  (list (list chat "rpc-q" "sess-q"
                              (list (list (cons 'id "q1")
                                          (cons 'question "Proceed?")
                                          (cons 'options
                                                (list (list (cons 'label "Yes")))))))))
            (dsh-emacs--interaction-drain 'question)
            (ert-info ((format "%s" "approval-handoff-after-question-drain"))
              (should (equal '(:question-prompt
                               (:respond "rpc-q")
                               :approval-prompt
                               (:respond "rpc-ap"))
                             (nreverse trace))))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

;; --- Test 78g: approvals and questions share one minibuffer slot (approval first ->
;; question queues and takes over) ---
(ert-deftest dsh-emacs-test-questions-question-queued-while-approval-active ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *dsh-test-approval-slot-afirst*"))
         (trace nil))
    (unwind-protect
        (let ((dsh-emacs--question-queue nil)
              (dsh-emacs--approval-queue nil)
              (dsh-emacs--interaction-active '(approval . "rpc-ax"))
              (dsh-emacs-enable-notifications nil))
          (cl-letf (((symbol-function 'dsh-emacs--approval-prompt)
                     (lambda (&rest _) (push :approval-prompt trace) t))
                    ((symbol-function 'completing-read-multiple)
                     (lambda (&rest _) (push :question-prompt trace) '("Yes")))
                    ((symbol-function 'dsh-emacs--events-result-async)
                     (lambda (_client-id event-id _outcome cb)
                       (push (list :respond event-id) trace)
                       (funcall cb t nil))))
            ;; A question arriving during an approval -> only enqueued, no prompt
            (dsh-emacs--question-requested
             chat "rpc-qx" "sess-qx"
             (list (list (cons 'id "q1")
                         (cons 'question "Proceed?")
                         (cons 'options (list (list (cons 'label "Yes")))))))
            (ert-info ((format "%s" "question-queued-while-approval-active"))
              (should (and (null trace)
                           (= 1 (length dsh-emacs--question-queue)))))
            ;; Approval answered -> handoff takes over the queued question
            (setq dsh-emacs--interaction-active nil)
            (dsh-emacs--interaction-drain 'approval)
            (ert-info ((format "%s" "question-handoff-after-approval-drain"))
              (should (equal '(:question-prompt (:respond "rpc-qx"))
                             (nreverse trace))))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

(ert-deftest dsh-emacs-test-questions-interaction-drains-own-kind-before-handoff ()
  :tags '(dsh-unit)
  (dolist (first-kind '(question approval))
    (dolist (reader-error '(nil t))
      (with-temp-buffer
        (let* ((chat (current-buffer))
               (dsh-emacs--interaction-active nil)
               (dsh-emacs--question-queue
                (list (list chat "q1" "q1" nil nil)
                      (list chat "q2" "q2" nil nil)))
               (dsh-emacs--approval-queue
                (list (list chat "a1" "a1" "bash" nil nil)
                      (list chat "a2" "a2" "bash" nil nil)))
               (expected (if (eq first-kind 'question)
                             '("q1" "q2" "a1" "a2")
                           '("a1" "a2" "q1" "q2")))
               order responses)
          (cl-letf (((symbol-function 'dsh-emacs--collect-question-answers)
                     (lambda (_questions session)
                       (push session order)
                       (when (and reader-error (equal session (car expected)))
                         (error "Question reader failed"))
                       '(((id . "answer") (selected . ["Yes"])))))
                    ((symbol-function 'dsh-emacs--approval-prompt)
                     (lambda (session &rest _)
                       (push session order)
                       (when (and reader-error (equal session (car expected)))
                         (error "Approval reader failed"))
                       t))
                    ((symbol-function 'dsh-emacs--events-result-async)
                     (lambda (_client event-id _outcome callback)
                       (push event-id responses)
                       (funcall callback t nil))))
            (dsh-emacs--interaction-drain first-kind))
          (ert-info ((format "first=%s reader-error=%s" first-kind reader-error))
            (should (equal (nreverse order) expected))
            ;; A reader error declines that frame as well, so the host is
            ;; never left waiting; every frame still gets an answer.
            (should (equal (nreverse responses) expected))
            (should-not dsh-emacs--interaction-active)
            (should-not dsh-emacs--question-queue)
            (should-not dsh-emacs--approval-queue)))))))

;; --- Test 78i: desktop notification for questions/approvals (turn-finish style) ---
;; Notify once, when the frame enters the queue; replay copies (dropped as
;; duplicates) do not notify again. The notification body carries the question text /
;; the command line that triggered the call, to help decide while away from the
;; minibuffer.
(ert-deftest dsh-emacs-test-questions-question-notify-on-accept ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *dsh-test-interaction-notify*"))
         (posted nil))
    (unwind-protect
        (let ((dsh-emacs--sessions nil)
              (dsh-emacs--chat-buffers (make-hash-table :test 'equal)))
          (setq dsh-emacs--question-queue nil
                dsh-emacs--interaction-active nil
                dsh-emacs--approval-queue nil)
          (with-current-buffer chat
            (setq-local dsh-emacs--buffer-session "sess-nt"))
          (cl-letf (((symbol-function 'dsh-emacs-notify--post)
                     (lambda (_session body _buffer) (push body posted)))
                    ((symbol-function 'dsh-emacs--events-result-async)
                     (lambda (&rest _) nil))
                    ((symbol-function 'completing-read-multiple)
                     (lambda (_prompt candidates &rest _)
                       (list (car (all-completions "" candidates)))))
                    ((symbol-function 'read-string)
                     (lambda (&rest _) "free answer"))
                    ((symbol-function 'dsh-emacs--approval-prompt)
                     (lambda (&rest _) t)))
            ;; Question frame accepted into the queue -> one notification, body carries its
            ;; text
            (dsh-emacs--question-requested
             chat "rpc-n1" "sess-nt"
             (list (list (cons 'id "q1")
                         (cons 'question "Which dir?")
                         (cons 'options (list (list (cons 'label "a")))))))
            (ert-info ((format "%s" "question-notify-on-accept"))
              (should (equal '("Question: Which dir?") posted)))
            ;; A copy with the same event-id is still queued (mux replay) -> dropped, no
            ;; notify
            (setq posted nil)
            (setq dsh-emacs--question-queue
                  (list (list chat "rpc-n1" "sess-nt"
                              (list (list (cons 'id "q1")
                                          (cons 'question "Which dir?"))))))
            (dsh-emacs--question-requested
             chat "rpc-n1" "sess-nt"
             (list (list (cons 'id "q1") (cons 'question "Which dir?"))))
            (ert-info ((format "%s" "question-notify-replay-dropped"))
              (should (null posted)))
            ;; Approval frame -> notification body carries the triggering command line
            ;; (the chat buffer's transcript)
            (setq posted nil)
            (with-current-buffer chat
              (setq dsh-emacs--tool-states (make-hash-table :test 'equal))
              (puthash "call-n"
                       (list :state 'pending :variant "bash" :icon ">_"
                             :title "Bash" :summary "cat x"
                             :args "$ cat /etc/hostname" :call-time nil :ns nil)
                       dsh-emacs--tool-states))
            (dsh-emacs--approval-requested
             chat "rpc-n2" "sess-nt" "bash" "needs outside" "call-n")
            (ert-info ((format "%s" "approval-notify-body-carries-command"))
              (should (equal '("Approval: $ cat /etc/hostname") posted)))
            ;; A copy with the same event-id is still queued -> dropped, no notify
            (setq posted nil)
            (setq dsh-emacs--approval-queue
                  (list (list chat "rpc-n3" "sess-nt" "bash" "x" nil)))
            (dsh-emacs--approval-requested
             chat "rpc-n3" "sess-nt" "bash" "needs outside" "call-n")
            (ert-info ((format "%s" "approval-notify-replay-dropped"))
              (should (null posted)))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

;; --- Test 31g: timed `ask_user_question' support (dsh 0.2.0) ---
;;
;; A timed question the user does not answer inside the foreground window
;; stays answerable: the host publishes it as the `userQuestions' projection
;; and the answer goes through `userQuestions/answer'.  These pin the protocol
;; decoding, the projection dispatch into chat-local state, the foreground-wait
;; claim held around the reader, the late-answer RPC, and the pending row.
(ert-deftest dsh-emacs-test-questions-protocol-user-questions-decodes ()
  :tags '(dsh-unit)
  (let* ((view (dsh-protocol-user-questions--from-alist
                '((active . [((callId . "c1")
                              (state . "continued")
                              (questions . [((id . "q1")
                                             (question . "Which?"))
                                            "oops"
                                            ((id . "q2")
                                             (question . "And?")
                                             (options . [((label . "A"))]))]))])
                  (settled . [((callId . "c0")
                               (answers . [((id . "q1")
                                            (selected . ["A"])
                                            (custom . "note"))
                                           ((id . "q2")
                                            (selected . []))]))]))))
         (active (dsh-protocol-user-questions-active view))
         (settled (dsh-protocol-user-questions-settled view)))
    (ert-info ((format "%s" "protocol-user-questions-decodes"))
      (should (= 1 (length active)))
      (should (eq 'continued (dsh-protocol-pending-question-state (car active))))
      (should (equal "c1" (dsh-protocol-pending-question-call-id (car active))))
      (should (= 2 (length (dsh-protocol-pending-question-questions (car active)))))
      (should (= 1 (length settled)))
      (should (equal '("A")
                     (dsh-protocol-question-answer-selected
                      (car (dsh-protocol-settled-question-answers (car settled))))))
      (should (equal "note"
                     (dsh-protocol-question-answer-custom
                      (car (dsh-protocol-settled-question-answers (car settled)))))))
    (let ((open (dsh-protocol-pending-question--from-alist
                 '((callId . "c2") (state . "open") (questions . [])))))
      (ert-info ((format "%s" "protocol-pending-question-open-state"))
        (should (eq 'open (dsh-protocol-pending-question-state open)))))))

(ert-deftest dsh-emacs-test-questions-protocol-user-questions-empty-decodes ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "protocol-user-questions-empty-decodes"))
    (should (let ((empty (dsh-protocol-user-questions--from-alist nil)))
              (null (dsh-protocol-user-questions-active empty))
              (null (dsh-protocol-user-questions-settled empty))))))

(ert-deftest dsh-emacs-test-questions-protocol-question-wait-flags-timed ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "protocol-question-wait-flags-timed"))
    (should (let ((timed (dsh-protocol-question-wait--from-alist
                          '((callId . "c9") (timed . t))))
                  (untimed (dsh-protocol-question-wait--from-alist '((callId . "c9")))))
              (equal "c9" (dsh-protocol-question-wait-call-id timed))
              (dsh-protocol-question-wait-timed timed)
              (not (dsh-protocol-question-wait-timed untimed))))))

(ert-deftest dsh-emacs-test-questions-userquestions-projection-stores-chat-state ()
  :tags '(dsh-unit)
  (let* ((old-chats dsh-emacs--chat-buffers)
         (chat (get-buffer-create " *t-uq-dispatch*"))
         (neutral (get-buffer-create " *t-uq-neutral*"))
         (proc (make-pipe-process :name "t-uq-proc" :buffer nil)))
    (unwind-protect
        (progn
          (setq dsh-emacs--chat-buffers
                (let ((h (make-hash-table :test 'equal)))
                  (puthash "sess-uq" chat h)
                  h))
          (with-current-buffer chat
            (dsh-emacs-mode)
            (setq-local dsh-emacs--buffer-session "sess-uq"))
          (dsh-emacs-events--host-apply-projection
           proc '((sessionId . "sess-uq") (key . "userQuestions")
                  (value . ((active . [((callId . "c1") (state . "continued")
                                       (questions . [((id . "q1")
                                                      (question . "Which?"))]))])
                            (settled . [])))))
          (with-current-buffer chat
            (ert-info ((format "%s" "userQuestions-projection-stores-chat-state"))
              (should (equal '("c1")
                             (mapcar #'dsh-protocol-pending-question-call-id
                                     (dsh-protocol-user-questions-active
                                      dsh-emacs--session-questions))))))
          (with-current-buffer neutral
            (dsh-emacs-events--host-apply-projection
             proc '((sessionId . "sess-other") (key . "userQuestions")
                    (value . ((active . [((callId . "x") (state . "continued")
                                         (questions . []))])
                              (settled . [])))))
            (ert-info ((format "%s" "userQuestions-foreign-session-cell-dropped"))
              (should (null dsh-emacs--session-questions)))))
      (setq dsh-emacs--chat-buffers old-chats)
      (when (buffer-live-p chat) (kill-buffer chat))
      (when (buffer-live-p neutral) (kill-buffer neutral))
      (delete-process proc))))

(ert-deftest dsh-emacs-test-questions-question-claim-held-until-answer-acknowledged ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *t-uq-claim*"))
         (proc (make-pipe-process :name "t-uq-claim-proc" :buffer nil))
         (opened nil) (closed nil) (reply nil) (readers nil))
    (unwind-protect
        (progn
          (with-current-buffer chat
            (dsh-emacs-mode)
            (setq-local dsh-emacs--buffer-session "sess-uq")
            (setq-local dsh-emacs--event-process proc))
          (let ((dsh-emacs-events--client-id "gen-uq")
                (dsh-emacs--question-queue nil)
                (dsh-emacs--approval-queue nil)
                (dsh-emacs--interaction-active nil)
                (dsh-emacs-enable-notifications nil))
            (cl-letf (((symbol-function 'dsh-emacs-events-open-stream)
                       (lambda (_p endpoint args _name _handler)
                         (setq opened (cons endpoint args)) "stream-uq"))
                      ((symbol-function 'dsh-emacs-events-close-stream)
                       (lambda (_p id) (push id closed)))
                      ((symbol-function 'dsh-emacs--collect-question-answers)
                       (lambda (_questions _session)
                         (push 'question readers)
                         '(((id . "q1") (selected . [])))))
                      ((symbol-function 'dsh-emacs--approval-prompt)
                       (lambda (&rest _)
                         (push 'approval readers)
                         t))
                      ((symbol-function 'dsh-emacs--events-result-async)
                       (lambda (_client event _outcome callback)
                         (if (equal event "ev-uq")
                             (setq reply callback)
                           (funcall callback t nil)))))
              (dsh-emacs--question-requested
               chat "ev-uq" "sess-uq"
               (list (dsh-protocol-question--from-alist
                      '((id . "q1") (question . "Which?"))))
               (dsh-protocol-question-wait--from-alist
                '((callId . "c1") (timed . t))))
              (ert-info ((format "%s" "question-claim-held-until-answer-acknowledged"))
                (should reply)
                (should (null closed)))
              ;; The wait claim outlives its reader; a new prompt can use the
              ;; shared minibuffer slot before the first answer is acknowledged.
              (dsh-emacs--approval-requested
               chat "ev-next" "sess-next" "bash" "Check next" nil)
              (should (equal (nreverse readers) '(question approval)))
              (should-not closed)
              (should-not dsh-emacs--interaction-active)
              (funcall reply t nil)))
          (ert-info ((format "%s" "question-drain-claims-timed-wait"))
            (should (equal "userQuestions/attachWait" (car opened)))
            (should (equal '((agentId . "sess-uq") (callId . "c1")) (cdr opened)))
            (should (equal '("stream-uq") closed))))
      (when (buffer-live-p chat) (kill-buffer chat))
      (delete-process proc))))

(ert-deftest dsh-emacs-test-questions-question-drain-does-not-claim-untimed-wait ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *t-uq-untimed*"))
         (proc (make-pipe-process :name "t-uq-untimed-proc" :buffer nil))
         (opened nil))
    (unwind-protect
        (progn
          (with-current-buffer chat
            (dsh-emacs-mode)
            (setq-local dsh-emacs--buffer-session "sess-uq")
            (setq-local dsh-emacs--event-process proc))
          (let ((dsh-emacs-events--client-id "gen-uq"))
            (cl-letf (((symbol-function 'dsh-emacs-events-open-stream)
                       (lambda (&rest _) (setq opened t) "s"))
                      ((symbol-function 'dsh-emacs--collect-question-answers)
                       (lambda (_questions _session)
                         '(((id . "q1") (selected . [])))))
                      ((symbol-function 'dsh-emacs--events-result-async)
                       (lambda (&rest _) nil)))
              (dsh-emacs--question-requested
               chat "ev-uq2" "sess-uq"
               (list (dsh-protocol-question--from-alist
                      '((id . "q1") (question . "Which?"))))
               (dsh-protocol-question-wait--from-alist '((callId . "c2"))))))
          (ert-info ((format "%s" "question-drain-does-not-claim-untimed-wait"))
            (should (null opened))))
      (when (buffer-live-p chat) (kill-buffer chat))
      (delete-process proc))))

(ert-deftest dsh-emacs-test-questions-answer-question-submits-late-batch ()
  :tags '(dsh-unit)
  (let ((sent nil))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "sess-uq")
      (setq-local dsh-emacs--session-questions
                  (dsh-protocol-user-questions--from-alist
                   '((active . [((callId . "c1") (state . "continued")
                                 (questions . [((id . "q1")
                                                (question . "Which?"))
                                               ((id . "q2")
                                                (question . "Anything else?"))
                                               ((id . "q3")
                                                (question . "Skip?"))]))])
                     (settled . []))))
      (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                 (lambda (method params _callback)
                   (push (cons method params) sent)))
                ((symbol-function 'dsh-emacs--collect-question-answers)
                 (lambda (_questions _session)
                   '(((id . "q1") (selected . ("A" "B")))
                     ((id . "q2") (selected . []) (custom . "my note"))
                     ((id . "q3") (selected . []))))))
        (dsh-emacs-answer-question))
      (ert-info ((format "%s" "answer-question-submits-late-batch"))
        (should
         (equal sent
                '(("userQuestions/answer"
                   (agentId . "sess-uq")
                   (callId . "c1")
                   (answer . ((answers . (((id . "q1") (selected . ("A" "B")))
                                          ((id . "q2") (selected . [])
                                           (custom . "my note"))
                                          ((id . "q3") (selected . []))))))))))))))

(ert-deftest dsh-emacs-test-questions-answer-question-reports-without-continued-call ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "answer-question-reports-without-continued-call"))
    (should (with-temp-buffer
              (dsh-emacs-mode)
              (setq-local dsh-emacs--buffer-session "sess-uq")
              (setq-local dsh-emacs--session-questions
                          (dsh-protocol-user-questions--from-alist
                           '((active . [((callId . "c1") (state . "open")
                                         (questions . []))])
                             (settled . []))))
              (condition-case nil
                  (progn (dsh-emacs-answer-question) nil)
                (user-error t))))))

(ert-deftest dsh-emacs-test-questions-ask-live-wire-result-case ()
  :tags '(dsh-unit)
  (dolist (case '(("{\"answers\":[{\"id\":\"q1\",\"selected\":[\"Stacked\"]}]}"
                   nil success "1/1 answered")
                  ("{\"pending\":true,\"callId\":\"wire-call\"}"
                   nil success "pending")
                  ("The question failed" t error "The question failed")))
    ;; Captured dsh 0.2.0 shape: text and isError belong to the tool message,
    ;; not to a nested content block with type=tool-result.
    (pcase-let ((`(,text ,is-error ,state ,summary) case))
      (with-temp-buffer
        (dsh-emacs-mode)
        (dsh-emacs-modeline-setup)
        (dsh-emacs-render-tool-call
         (dsh-emacs-test--tool-call-event
          1 "wire-call" "ask_user_question" dsh-emacs-test--ask-args))
        (dsh-emacs-render-tool-result
         `((type . "tool/result") (seq . 2)
           (data . ((message . ((role . "tool")
                                (source . ((kind . "tool") (callId . "wire-call")))
                                (toolCallId . "wire-call")
                                (content . [((type . "text") (text . ,text))])
                                (isError . ,(if is-error t :json-false))))))))
        (let ((result (dsh-emacs-render--tool-state "wire-call"))
              (block (dsh-emacs-test--tool-block-text
                      (dsh-emacs-render--make-namespace) "tool-wire-call")))
          (ert-info ((format "%s" (format "ask-live-wire-result-%s" summary)))
            (should (equal (plist-get result :result) text))
            (should (eq (plist-get result :state) state))
            (should (string-match-p (regexp-quote summary) block))))))))

(ert-deftest dsh-emacs-test-questions-ask-pending-result-is-summarized-and-explained ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs-tool-expand-by-default t)
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event 1 "kp" "ask_user_question"
                                      dsh-emacs-test--ask-args))
    (dsh-emacs-render-tool-result
     (dsh-emacs-test--tool-result-event
      2 "kp" nil 0
      (json-encode '((pending . t) (callId . "kp")
                     (message . "No answer batch arrived before the timeout.")))))
    (let ((block (dsh-emacs-test--tool-block-text
                  (dsh-emacs-render--make-namespace) "tool-kp")))
      (ert-info ((format "%s" "ask-pending-result-is-summarized-and-explained"))
        (should (string-match-p "Ask question · pending" block))
        (should (string-match-p "dsh-emacs-answer-question" block))))))

(ert-deftest dsh-emacs-test-questions-ask-settled-late-answer-completes-the-pending-card ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs-tool-expand-by-default t)
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event 1 "ks" "ask_user_question"
                                      dsh-emacs-test--ask-args))
    (dsh-emacs-render-tool-result
     (dsh-emacs-test--tool-result-event
      2 "ks" nil 0 (json-encode '((pending . t) (callId . "ks")))))
    ;; The settled cell of the projection is what completes the pending row.
    (dsh-emacs--session-questions-apply
     (dsh-protocol-user-questions--from-alist
      '((active . [])
        (settled . [((callId . "ks")
                     (answers . [((id . "q1") (selected . ["Stacked"]))
                                 ((id . "q2") (selected . [])
                                  (custom . "late"))]))]))))
    (let ((block (dsh-emacs-test--tool-block-text
                  (dsh-emacs-render--make-namespace) "tool-ks")))
      (ert-info ((format "%s" "ask-settled-late-answer-completes-the-pending-card"))
        (should (string-match-p "Ask question · 2/2 answered" block))
        (should (string-match-p "^   1\\. ✓ Stacked$" block))
        (should (string-match-p "^  → late$" block))
        (should (not (string-match-p "pending" block)))))))

(ert-deftest dsh-emacs-test-questions-ask-late-answer-respects-display-gate ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs-show-tool-calls t)
    (setq-local dsh-emacs-tool-expand-by-default nil)
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event
      1 "hidden-ask" "ask_user_question" dsh-emacs-test--ask-args))
    (dsh-emacs-render-tool-result
     (dsh-emacs-test--tool-result-event
      2 "hidden-ask" nil 0
      (json-encode '((pending . t) (callId . "hidden-ask")))))
    (let* ((ns (dsh-emacs-render--make-namespace))
           (before (buffer-string))
           (state (copy-tree (dsh-emacs-render--tool-state "hidden-ask")))
           (answers (json-encode
                     '((answers . [((id . "q1") (selected . ["Stacked"]))])))))
      (should (string-match-p "Ask question · pending" before))
      (setq-local dsh-emacs-show-tool-calls nil)
      (should-not (dsh-emacs-render-question-settled "hidden-ask" answers))
      (should (equal before (buffer-string)))
      (should (equal state (dsh-emacs-render--tool-state "hidden-ask")))
      (setq-local dsh-emacs-show-tool-calls t)
      (dsh-emacs-render-question-settled "hidden-ask" answers)
      (should (equal answers
                     (plist-get (dsh-emacs-render--tool-state "hidden-ask")
                                :result)))
      (let ((block (dsh-emacs-test--tool-block-text ns "tool-hidden-ask")))
        (should (string-match-p "Ask question · 1/1 answered" block))
        ;; Completing the row preserves the user's collapsed presentation.
        (should-not (string-match-p "Which layout" block)))
      (goto-char (car (dsh-emacs-ui-find-block ns "tool-hidden-ask")))
      (dsh-emacs-ui-toggle-fragment)
      (should (string-match-p
               "^   1\\. ✓ Stacked$"
               (dsh-emacs-test--tool-block-text ns "tool-hidden-ask")))
      (let ((completed (buffer-string))
            (settled-state
             (copy-tree (dsh-emacs-render--tool-state "hidden-ask"))))
        (should-not
         (dsh-emacs-render-question-settled
          "hidden-ask"
          (json-encode
           '((answers . [((id . "q1") (selected . ["Compact"]))])))))
        (should (equal completed (buffer-string)))
        (should (equal settled-state
                       (dsh-emacs-render--tool-state "hidden-ask")))))))

(ert-deftest dsh-emacs-test-questions-ask-in-time-answer-is-not-overwritten-by-projection ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs-tool-expand-by-default t)
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event 1 "ki" "ask_user_question"
                                      dsh-emacs-test--ask-args))
    (dsh-emacs-render-tool-result
     (dsh-emacs-test--tool-result-event
      2 "ki" nil 0
      (json-encode '((answers . [((id . "q1") (selected . ["Stacked"]))
                                 ((id . "q2") (selected . []))])))))
    (dsh-emacs-render-question-settled
     "ki"
     (dsh-protocol-question-answers-json
      (list (dsh-protocol-question-answer--from-alist
             '((id . "q1") (selected . ["Compact"]))))))
    (let ((block (dsh-emacs-test--tool-block-text
                  (dsh-emacs-render--make-namespace) "tool-ki")))
      (ert-info ((format "%s" "ask-in-time-answer-is-not-overwritten-by-projection"))
        (should (string-match-p "Ask question · 1/2 answered" block))
        (should (string-match-p "^   1\\. ✓ Stacked$" block))
        (should (not (string-match-p "✓ Compact" block)))))))

(ert-deftest dsh-emacs-test-questions-ask-snapshot-settles-a-resumed-pending-card ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs-tool-expand-by-default t)
    (setq-local dsh-emacs--buffer-session "sess-uq")
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event 1 "kr" "ask_user_question"
                                      dsh-emacs-test--ask-args))
    (dsh-emacs-render-tool-result
     (dsh-emacs-test--tool-result-event
      2 "kr" nil 0 (json-encode '((pending . t) (callId . "kr")))))
    ;; A resumed transcript's snapshot carries the settled cell, applied after
    ;; the records have rendered.
    (dsh-emacs-events--apply-snapshot-projections
     "sess-uq"
     '((values . ((userQuestions
                   . ((active . [])
                      (settled . [((callId . "kr")
                                   (answers . [((id . "q1")
                                                (selected . ["Stacked"]))]))])))))))
    (let ((block (dsh-emacs-test--tool-block-text
                  (dsh-emacs-render--make-namespace) "tool-kr")))
      (ert-info ((format "%s" "ask-snapshot-settles-a-resumed-pending-card"))
        (should (string-match-p "Ask question · 1/1 answered" block))
        (should (string-match-p "^   1\\. ✓ Stacked$" block))
        (should (not (string-match-p "pending" block)))))))

;; Both asynchronous failure and synchronous exits release the wait claim.
(ert-deftest dsh-emacs-test-questions-question-claim-held-before-http-failure ()
  :tags '(dsh-unit)
  (dolist (outcome '(http-failure rpc-error reader-error quit))
    (with-temp-buffer
      (dsh-emacs-mode)
      (let ((chat (current-buffer))
            (dsh-emacs--interaction-active nil)
            (dsh-emacs--question-queue nil)
            (dsh-emacs--approval-queue nil)
            reply released)
        (cl-letf (((symbol-function 'dsh-emacs--question-claim-wait)
                   (lambda (&rest _) 'claim))
                  ((symbol-function 'dsh-emacs--question-release-wait)
                   (lambda (claim) (when claim (push claim released))))
                  ((symbol-function 'dsh-emacs--collect-question-answers)
                   (lambda (&rest _)
                     (pcase outcome
                       ('reader-error (error "Reader failed"))
                       ('quit (signal 'quit nil))
                       (_ '(((id . "q") (selected . ["A"])))))))
                  ((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (_client _event _answer callback)
                     (if (eq outcome 'rpc-error)
                         (error "Send failed")
                       (setq reply callback))))
                  ((symbol-function 'dsh-emacs-notify--post) #'ignore))
          (dsh-emacs--question-requested
           chat "failure-event" "failure-session"
           '(((id . "q") (question . "Which?")))
           (dsh-protocol-question-wait--from-alist
            '((callId . "call") (timed . t))))
          (when (eq outcome 'http-failure)
            (ert-info ((format "%s" "question-claim-held-before-http-failure"))
              (should reply)
              (should (null released)))
            (funcall reply nil "offline")))
        (ert-info ((format "%s" (format "question-claim-released-on-%s" outcome)))
          (should (equal released '(claim)))
          (should (null dsh-emacs--interaction-active)))))))

;; Envelope success does not imply that the host accepted a late answer.
(ert-deftest dsh-emacs-test-questions-late-answer-reports-response-case-case ()
  :tags '(dsh-unit)
  (dolist (response '((t t "Answered 1 question(s)")
                      (t :json-false "Question is no longer waiting for an answer")
                      (t nil "Question is no longer waiting for an answer")
                      (nil "offline" "Question answer not accepted (offline)")))
    (pcase-let ((`(,ok ,value ,expected) response))
      (let (reported)
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method _params callback) (funcall callback ok value)))
                  ((symbol-function 'message)
                   (lambda (format-string &rest args)
                     (setq reported (apply #'format format-string args)))))
          (dsh-emacs--question-answer-late
           "late" "call" '(((id . "q") (selected . ["A"])))))
        (ert-info ((format "%s" (format "late-answer-reports-response-%S-%S" ok value)))
          (should (equal expected reported)))))))

;; Settled state may arrive before the pending result or its history page.
(ert-deftest dsh-emacs-test-questions-question-settled-before-case-is-shown ()
  :tags '(dsh-unit)
  (dolist (source '(history live))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "questions-history")
      (setq-local dsh-emacs--history-earliest-seq 10)
      (setq-local dsh-emacs-tool-expand-by-default t)
      (let* ((call (dsh-emacs-test--tool-call-event
                    1 "older" "ask_user_question" dsh-emacs-test--ask-args))
             (result (dsh-emacs-test--tool-result-event
                      2 "older" nil 0
                      (json-encode '((pending . t) (callId . "older"))))))
        (when (eq source 'live)
          (dsh-emacs-render-tool-call call))
        (dsh-emacs--session-questions-apply
         (dsh-protocol-user-questions--from-alist
          '((active . [])
            (settled . [((callId . "older")
                         (answers . [((id . "q1") (selected . ["Stacked"]))
                                     ((id . "q2") (selected . [])
                                      (custom . "saved reply"))]))]))))
        (if (eq source 'live)
            (dsh-emacs-render-tool-result result)
          (dsh-emacs--load-older-history-page
           (current-buffer)
           `((records . [((type . "event") (event . ,call))
                         ((type . "event") (event . ,result))])
             (hasMore . :json-false))))
        (let ((block (dsh-emacs-test--tool-block-text
                      (dsh-emacs-render--make-namespace) "tool-older")))
          (ert-info ((format "%s" (format "question-settled-before-%s-is-shown" source)))
            (should (string-match-p "Ask question · 2/2 answered" block))
            (should (string-match-p "✓ Stacked" block))
            (should (string-match-p "→ saved reply" block))
            (should (not (string-match-p "pending" block)))))))))

;; Follow and control streams can deliver their cuts out of order.
(ert-deftest dsh-emacs-test-questions-question-live-update-during-history-wins ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs--buffer-session "questions-seq")
    (let* ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
           (continued '((active . [((callId . "new") (state . "continued")
                                    (questions . [((id . "q")
                                                   (question . "New?"))]))])
                        (settled . [])))
           (update `((type . "projection") (sessionId . "questions-seq")
                     (key . "userQuestions") (seq . 11)
                     (value . ,continued)))
           (old-snapshot '((cursor . 10)
                           (records . [((type . "event")
                                        (event . ((type . "step/end")
                                                  (seq . 10))))])
                           (projections . ((asOfSeq . 10)
                                           (values . ((userQuestions
                                                       . ((active . [])
                                                          (settled . [])))))))))
           (process (make-pipe-process :name "t-questions-seq" :buffer nil)))
      (unwind-protect
          (progn
            (puthash "questions-seq" (current-buffer) dsh-emacs--chat-buffers)
            (cl-letf (((symbol-function 'dsh-emacs-render-history-events)
                       (lambda (&rest _)
                         (dsh-emacs-events--host-item nil update))))
              (dsh-emacs-events--follow-snapshot (current-buffer) old-snapshot))
            (ert-info ((format "%s" "question-live-update-during-history-wins"))
              (should (equal '("new")
                             (mapcar #'dsh-protocol-pending-question-call-id
                                     (dsh-emacs--question-continued)))))
            (dsh-emacs-events--host-item nil update)
            (dsh-emacs-events--host-control-baseline
             nil '((projections . ((questions-seq . ((asOfSeq . 10)
                                                     (values)))))))
            (dsh-emacs-events--follow-snapshot (current-buffer) old-snapshot)
            (ert-info ((format "%s" "question-old-baselines-cannot-erase-newer-update"))
              (should (= 1 (length (dsh-emacs--question-continued)))))
            (dsh-emacs-events--host-control-baseline
             nil '((projections . ((questions-seq . ((asOfSeq . 12)
                                                     (values)))))))
            (dsh-emacs-events--host-item nil update)
            (ert-info ((format "%s" "question-absent-capability-retains-newer-cut"))
              (should (null (dsh-emacs--question-continued))))
            (cl-letf (((symbol-function 'process-send-string) #'ignore))
              (dsh-emacs-events--host-open process))
            (dsh-emacs-events--host-control-baseline
             nil `((projections . ((questions-seq
                                    . ((asOfSeq . 1)
                                       (values . ((userQuestions . ,continued)))))))))
            (ert-info ((format "%s" "question-new-generation-resets-sequence"))
              (should (= 1 (length (dsh-emacs--question-continued))))))
        (delete-process process)))))

;; Late answers share the prompt slot from picker entry through every exit.
(ert-deftest dsh-emacs-test-questions-late-answer-serializes-prompts-on-case ()
  :tags '(dsh-unit)
  (dolist (outcome '(answer quit error))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "late")
      (setq-local dsh-emacs--session-questions
                  (dsh-protocol-user-questions--from-alist
                   '((active . [((callId . "first") (state . "continued")
                                 (questions . [((id . "q1")
                                                (question . "First"))]))
                                ((callId . "second") (state . "continued")
                                 (questions . [((id . "q2")
                                                (question . "Second"))]))]))))
      (let ((chat (current-buffer))
            (dsh-emacs--interaction-active nil)
            (dsh-emacs--question-queue nil)
            (dsh-emacs--approval-queue nil)
            order)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _)
                     (dsh-emacs--question-requested
                      chat "queued-question" "live"
                      '(((id . "new") (question . "New?"))))
                     (dsh-emacs--approval-requested
                      chat "queued-approval" "live" "bash" "Check" nil)
                     (push 'picker order)
                     "First"))
                  ((symbol-function 'dsh-emacs--collect-question-answers)
                   (lambda (_questions session)
                     (if (equal session "late")
                         (progn
                           (push 'late order)
                           (pcase outcome
                             ('quit (signal 'quit nil))
                             ('error (error "Reader failed"))))
                       (push 'question order))
                     '(((id . "q1") (selected . ["A"])))))
                  ((symbol-function 'dsh-emacs--approval-prompt)
                   (lambda (&rest _) (push 'approval order) t))
                  ((symbol-function 'dsh-emacs-notify--post) #'ignore)
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method _params callback) (funcall callback t t))))
          (condition-case nil
              (dsh-emacs-answer-question)
            (quit nil)
            (error nil)))
        (ert-info ((format "%s" (format "late-answer-serializes-prompts-on-%s" outcome)))
          (should (equal (nreverse order) '(picker late question approval)))
          (should (null dsh-emacs--interaction-active))
          (should (null dsh-emacs--question-queue))
          (should (null dsh-emacs--approval-queue)))))))

(ert-deftest dsh-emacs-test-questions-question-read-error-declines-waterfall ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *dsh-test-question-error*"))
         (dsh-emacs-events--client-id "c-error")
         (responds nil))
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (client-id event-id outcome _cb)
                     (push (list client-id event-id outcome) responds)))
                  ((symbol-function 'dsh-emacs--collect-question-answers)
                   (lambda (&rest _) (error "reader blew up")))
                  ((symbol-function 'dsh-emacs--question-release-wait)
                   #'ignore))
          ;; A reader error must still answer the host: the waterfall is
          ;; declined instead of being dropped when the minibuffer is busy.
          (dsh-emacs--question-answer (list chat "rpc-q-error" "sess-q" nil nil))
          (ert-info ((format "%s" "question-read-error-declines-waterfall"))
            (should
             (equal responds
                    '(("c-error" "rpc-q-error"
                       ((kind . "rejected")
                        (error . ((name . "cancelled")
                                  (message . "User abandoned the questions"))))))))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

(ert-deftest dsh-emacs-test-questions-approval-read-error-rejects-waterfall ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *dsh-test-approval-error*"))
         (dsh-emacs-events--client-id "c-error")
         (responds nil))
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (client-id event-id outcome _cb)
                     (push (list client-id event-id outcome) responds)))
                  ((symbol-function 'dsh-emacs--approval-prompt)
                   (lambda (&rest _) (error "reader blew up"))))
          (dsh-emacs--approval-answer
           (list chat "wf-error" "sess-a" "bash" "why" "call-1"))
          (ert-info ((format "%s" "approval-read-error-rejects-waterfall"))
            (should (equal responds
                           '(("c-error" "wf-error"
                              ((kind . "result") (value . "rejected"))))))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

;; A waterfall delivered by the WebSocket dispatcher must not open its prompt
;; inside that dispatcher: the host's `cancel' frame (another client answered)
;; could not be dispatched until the prompt returned.  The drain is scheduled
;; instead; a cancel that arrives before it runs leaves nothing to ask.
(ert-deftest dsh-emacs-test-questions-waterfall-prompt-defers-out-of-dispatcher ()
  :tags '(dsh-unit)
  (let ((chat (get-buffer-create " *dsh-test-question-defer*"))
        (scheduled nil)
        (prompted nil)
        (dsh-emacs--question-queue nil)
        (dsh-emacs--approval-queue nil)
        (dsh-emacs--interaction-active nil)
        (dsh-emacs--waterfall-cancelled-event-id nil)
        (dsh-emacs-events--dispatching t)
        (dsh-emacs-enable-notifications nil))
    (unwind-protect
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (_time _repeat function &rest args)
                     (setq scheduled (lambda () (apply function args)))
                     'scheduled-timer))
                  ((symbol-function 'dsh-emacs--collect-question-answers)
                   (lambda (&rest _)
                     (setq prompted t)
                     nil)))
          (dsh-emacs--question-requested
           chat "wf-defer" "sess-defer"
           '(((id . "q1") (question . "Proceed?")
              (options . (((label . "Yes")))))))
          (ert-info ((format "%s" "waterfall-prompt-defers-out-of-dispatcher"))
            (should scheduled)
            (should-not prompted)
            (should (= 1 (length dsh-emacs--question-queue))))
          ;; The host cancels while the prompt is still only scheduled.
          (dsh-emacs--question-cancelled "wf-defer")
          (funcall scheduled)
          (ert-info ((format "%s" "scheduled-prompt-skips-cancelled-waterfall"))
            (should-not prompted)
            (should (null dsh-emacs--question-queue))
            (should (null dsh-emacs--interaction-active))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

(ert-deftest dsh-emacs-test-questions-cancelled-before-read-skips-prompt ()
  :tags '(dsh-unit)
  (let ((chat (get-buffer-create " *dsh-test-question-precancel*"))
        (prompted nil)
        (responded nil)
        (dsh-emacs--interaction-active '(question . "wf-pre"))
        (dsh-emacs--waterfall-cancelled-event-id "wf-pre")
        (dsh-emacs-enable-notifications nil))
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-emacs--collect-question-answers)
                   (lambda (&rest _) (setq prompted t) nil))
                  ((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (&rest _) (setq responded t))))
          (dsh-emacs--question-answer
           (list chat "wf-pre" "sess-pre"
                 '(((id . "q1") (question . "Proceed?"))) nil))
          (ert-info ((format "%s" "cancelled-before-read-skips-prompt"))
            (should-not prompted)
            (should-not responded)))
      (when (buffer-live-p chat) (kill-buffer chat)))))

;; A native dialog cannot be dismissed by the remote `cancel' frame; the
;; approval reader must stay in the minibuffer it documents.
(ert-deftest dsh-emacs-test-questions-approval-prompt-forces-minibuffer ()
  :tags '(dsh-unit)
  (let ((seen 'unset))
    (let ((use-dialog-box t))
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (&rest _)
                   (setq seen use-dialog-box)
                   t)))
        (dsh-emacs--approval-prompt "sess-a" "bash" "why" nil)))
    (ert-info ((format "%s" "approval-prompt-forces-minibuffer"))
      (should (eq seen nil)))))

;; Approvals are deferred like questions, and a cancel that lands before the
;; scheduled drain runs must leave nothing to ask.
(ert-deftest dsh-emacs-test-questions-approval-prompt-defers-out-of-dispatcher ()
  :tags '(dsh-unit)
  (let ((chat (get-buffer-create " *dsh-test-approval-defer*"))
        (scheduled nil)
        (prompted nil)
        (responded nil)
        (dsh-emacs--question-queue nil)
        (dsh-emacs--approval-queue nil)
        (dsh-emacs--interaction-active nil)
        (dsh-emacs--waterfall-cancelled-event-id nil)
        (dsh-emacs-events--dispatching t)
        (dsh-emacs-enable-notifications nil))
    (unwind-protect
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (_time _repeat function &rest args)
                     (setq scheduled (lambda () (apply function args)))
                     'scheduled-timer))
                  ((symbol-function 'dsh-emacs--approval-prompt)
                   (lambda (&rest _) (setq prompted t) t))
                  ((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (&rest _) (setq responded t))))
          (dsh-emacs--approval-requested
           chat "wf-ap-defer" "sess-ap" "bash" "why" nil)
          (ert-info ((format "%s" "approval-prompt-defers-out-of-dispatcher"))
            (should scheduled)
            (should-not prompted)
            (should (= 1 (length dsh-emacs--approval-queue))))
          (dsh-emacs--approval-cancelled "wf-ap-defer")
          (funcall scheduled)
          (ert-info ((format "%s" "scheduled-approval-skips-cancelled-waterfall"))
            (should-not prompted)
            (should-not responded)
            (should (null dsh-emacs--approval-queue))
            (should (null dsh-emacs--interaction-active))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

(ert-deftest dsh-emacs-test-questions-approval-cancelled-before-read-skips-prompt ()
  :tags '(dsh-unit)
  (let ((chat (get-buffer-create " *dsh-test-approval-precancel*"))
        (prompted nil)
        (responded nil)
        (dsh-emacs--interaction-active '(approval . "wf-ap-pre"))
        (dsh-emacs--waterfall-cancelled-event-id "wf-ap-pre"))
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-emacs--approval-prompt)
                   (lambda (&rest _) (setq prompted t) t))
                  ((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (&rest _) (setq responded t))))
          (dsh-emacs--approval-answer
           (list chat "wf-ap-pre" "sess-ap" "bash" "why" nil))
          (ert-info ((format "%s" "approval-cancelled-before-read-skips-prompt"))
            (should-not prompted)
            (should-not responded)))
      (when (buffer-live-p chat) (kill-buffer chat)))))

;; The late-answer picker uses the `(late-answer)' slot, which is not a
;; waterfall: its cdr is nil like an uncancelled flag, so the pre-read guard
;; must not mistake it for a cancelled question.
(ert-deftest dsh-emacs-test-questions-late-answer-slot-is-not-cancelled ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--interaction-active '(late-answer))
        (dsh-emacs--waterfall-cancelled-event-id nil)
        (choices 0))
    (cl-letf (((symbol-function 'dsh-emacs--question-choice)
               (lambda (&rest _)
                 (setq choices (1+ choices))
                 '((id . "q1") (selected . ("A"))))))
      (ert-info ((format "%s" "late-answer-slot-is-not-cancelled"))
        (should-not (dsh-emacs--waterfall-cancelled-p))
        (should (equal
                 (dsh-emacs--collect-question-answers
                  '(((id . "q1") (question . "Proceed?"))) "sess-late")
                 '(((id . "q1") (selected . ("A"))))))
        (should (= 1 choices))))))

(provide 'dsh-test-questions)
;;; dsh-test-questions.el ends here
