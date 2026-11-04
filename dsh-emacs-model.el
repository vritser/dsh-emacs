;;; dsh-emacs-model.el --- Session model and reasoning-effort selection -*- lexical-binding: t; -*-

;; Copyright (C) 2026 vritser
;; Author: vritser
;; Version: 0.8.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:
;; Owns the live model catalog readers, selection RPCs, picker presentation
;; and model options.  Session identity and cached projections remain with
;; the coordinator; provider configuration remains in dsh-emacs-provider.el.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'dsh-emacs-protocol)
(require 'dsh-emacs-server)
(require 'dsh-emacs-ui)
(require 'dsh-emacs-modeline)
(require 'dsh-emacs-subagent)

(declare-function dsh-emacs--active-session-id "dsh-emacs" ())
(declare-function dsh-emacs--session-model-selection "dsh-emacs" (session-id))
(declare-function dsh-emacs-list-sessions--fetch "dsh-emacs" ())

(defcustom dsh-emacs-model-group-format
  #(" %s " 0 4 (face vertico-group-title))
  "Format string for provider group titles in the model selector.
`%s' is replaced with the provider name.
Inside the model selector's minibuffer this overrides vertico's global
`vertico-group-format' (buffer-locally, other completions are untouched):
vertico's stock format draws a long strike-through separator line across
the whole group header (\"----...\"), which is noisy; the default here
paints just the provider name.  Set to nil to hide group titles entirely
inside the picker."
  :type '(choice (const :tag "No group titles" nil) string)
  :group 'dsh-emacs)

(defcustom dsh-emacs-default-model "deepseek-v4-flash-0731"
  "Default model name."
  :type 'string
  :group 'dsh-emacs)

(defun dsh-emacs--model-candidates (directory)
  "Flatten model DIRECTORY into per-model entries, sorted.

The list is sorted by provider display name then model id
(case-insensitive), so the model picker shows a stable, predictable
order regardless of the host's own group/model ordering.

Each entry is (ID PROVIDER PROVIDER-NAME NAME REASONING):
  ID            — the model id, sent as `session/selectModel' model.
  PROVIDER      — the owning group's id; the live host resolves
                  `current.provider' to exactly this value (the provider
                  `session/selectModel' expects for the model).
  PROVIDER-NAME — the group's display name (may equal PROVIDER).
  NAME          — the model's display name (may equal ID).
  REASONING     — the model's reasoning metadata
                  (a `dsh-protocol-reasoning' struct), or nil when the
                  model offers no reasoning-effort options.

DIRECTORY is a decoded `dsh-protocol-model-directory' struct."
  (let ((groups (dsh-protocol-model-directory-groups directory)))
    (sort (cl-loop for g in groups
                   for provider = (dsh-protocol-provider-group-id g)
                   for provider-name = (or (dsh-protocol-provider-group-name g)
                                           provider)
                   append (cl-loop for m in (dsh-protocol-provider-group-models g)
                                   for id = (dsh-protocol-model-catalog-entry-id m)
                                   for name = (or (dsh-protocol-model-catalog-entry-name m)
                                                  id)
                                   for reasoning = (dsh-protocol-model-catalog-entry-reasoning m)
                                   collect (list id provider provider-name
                                                 name reasoning)))
          (lambda (a b)
            (pcase-let* ((`(,id-a ,_ ,provider-a . ,_) a)
                         (`(,id-b ,_ ,provider-b . ,_) b)
                         (provider-a (downcase provider-a))
                         (provider-b (downcase provider-b)))
              (or (string-lessp provider-a provider-b)
                  (and (string= provider-a provider-b)
                       (string-lessp (downcase id-a) (downcase id-b)))))))))

(defun dsh-emacs--model-effort-choices (reasoning)
  "Effort options of REASONING (a `dsh-protocol-reasoning' struct, or a
wire alist) as ((NAME . ID) ...), keeping the host's directory order for
display; entries without a display name fall back to their id.  Returns
nil when REASONING has no efforts."
  (setq reasoning (dsh-protocol--struct
                   #'dsh-protocol-reasoning-p
                   #'dsh-protocol-reasoning--from-alist
                   reasoning))
  (mapcar (lambda (e)
            (let ((id (dsh-protocol-effort-id e))
                  (name (or (dsh-protocol-effort-name e)
                            (dsh-protocol-effort-id e))))
              (cons name id)))
          (dsh-protocol-reasoning-efforts reasoning)))

(defun dsh-emacs--model-effort-default-id (reasoning &optional current-id)
  "The effort id to pre-select for a model with REASONING options.
CURRENT-ID wins when it is a valid option (the session already runs that
model at that effort); otherwise the model's `defaultEffort' when it is a
known option; otherwise the first effort in the directory."
  (setq reasoning (dsh-protocol--struct
                   #'dsh-protocol-reasoning-p
                   #'dsh-protocol-reasoning--from-alist
                   reasoning))
  (let* ((choices (dsh-emacs--model-effort-choices reasoning))
         (ids (mapcar #'cdr choices))
         (default (dsh-protocol-reasoning-default-effort reasoning)))
    (cond ((and current-id (member current-id ids)) current-id)
          ((member default ids) default)
          (ids (car ids))
          (t nil))))

(defun dsh-emacs--model-pick-effort (model choices default-id)
  "Read a reasoning-effort choice for MODEL from CHOICES ((NAME . ID) ...).
Returns the chosen effort id.  The choice whose id equals DEFAULT-ID is
passed as completing-read's DEF: vertico pre-selects it and an empty RET
takes it — re-picking the current model keeps its live effort, other
models default to their host-supplied default.  Signals quit on C-g, so
the caller can cancel the whole selection."
  (let* ((default-name (car (rassoc default-id choices)))
         (name (completing-read
                (if default-name
                    (format "Reasoning effort for %s (default %s): "
                            model default-name)
                  (format "Reasoning effort for %s: " model))
                choices nil t nil nil default-name)))
    (or (cdr (assoc name choices)) default-id)))

(defun dsh-emacs--model-row-entry (c dup)
  "One (KEY . C) completing-read entry for model tuple C.
KEY = \"id [provider|Provider Name]\" — the id first, so prefix
completion (default `completion-styles' match by prefix) hits when the
user types a model id; provider id and display name are embedded for
exact `assoc' and for searching by provider name — with a `display'
property rendering \"  id\" (or, when DUP non-nil — the same id is
offered by several providers — and no group headers are available,
\"  id (Provider Name)\" so duplicate-id rows stay distinguishable
after the group headers are dropped)."
  (pcase-let* ((`(,id ,provider ,provider-name . ,_) c)
               (shown (if dup
                          (format "  %s (%s)" id provider-name)
                        (format "  %s" id)))
               (key (propertize (format "%s [%s|%s]" id provider provider-name)
                                'display shown)))
    (cons key c)))

(defun dsh-emacs--model-key-parts (key)
  "Parse row KEY built by `dsh-emacs--model-row-entry' as
\"id [provider|Provider Name]\", returning (ID PROVIDER PROVIDER-NAME)
or nil when KEY is not a model row."
  (when (string-match "\\`\\([^ ]+\\) \\[\\([^]|]*\\)|\\([^]]*\\)\\]\\'" key)
    (list (match-string 1 key)
          (match-string 2 key)
          (match-string 3 key))))

(defun dsh-emacs--model-entries (candidates)
  "Entries for completion UIs WITHOUT grouping support: provider shown
once as a bare header row, its models following, indented, each
showing the model id (the payload keeps the display NAME for
messages/the mode line) with payload = the candidate tuple
(ID PROVIDER PROVIDER-NAME NAME REASONING), where REASONING is the
host's `dsh-protocol-reasoning' struct or nil.  Rows are
(DISPLAY . PAYLOAD) conses, so a picked header is rejected by the
caller instead of being treated as a model.

The row KEY embeds the owning provider (\"id [provider|Provider
Name]\", id first so prefix filtering still matches) and a `display'
property renders the row: bare \"  id\" for unique ids, and
\"  m2 (Qwen)\" when an id collides across providers — because this
path's group headers are ordinary candidates and vanish from the
displayed list the moment the user types a query."
  (let ((entries '())
        (last-provider nil)
        (id-count (make-hash-table :test #'equal)))
    (dolist (c candidates)
      (let ((id (car c)))
        (puthash id (1+ (gethash id id-count 0)) id-count)))
    (dolist (c candidates (nreverse entries))
      (pcase-let* ((`(,id ,_ ,provider-name . ,_) c)
                   (dup (> (gethash id id-count 0) 1)))
        (unless (equal provider-name last-provider)
          (push (cons provider-name (cons :header provider-name)) entries)
          (setq last-provider provider-name))
        (push (dsh-emacs--model-row-entry c dup) entries)))))

(defun dsh-emacs--model-grouped-collection (candidates)
  "Completion table with sticky group headers, returns (TABLE . ROWS).
For completion UIs that honour the `group-function' completion
metadata — modern vertico draws sticky group headers from it,
recomputing them on every filter input, and the Emacs 27+ *Completions*
buffer renders them too: rows are flat (no header-row candidates),
each KEY \"id [provider|Provider Name]\" rendered as bare \"  id\"
via the `display' property (id first so prefix completion still
matches while typing; provider name sits in the key, so substring
styles also find it), and the table metadata carries a
`group-function' mapping every key back to its provider display name.
The UI then paints one sticky group header per provider that stays
visible while any of its rows still matches the query — grouping is
NOT lost while searching."
  (let* ((rows (mapcar (lambda (c) (dsh-emacs--model-row-entry c nil))
                       candidates))
         (group-fn
          ;; Self-contained: parse the provider display name
          ;; straight from the key, capturing no variables.
          ;; The title must be a property-free string
          ;; (match-string keeps the candidate key's display
          ;; property).  The transform branch moves the match
          ;; highlight face over the id span to the matching
          ;; position in the display string: key = "m2
          ;; [g2|Qwen]" (display hides the rest); typing "m2"
          ;; makes orderless/basic put completion-match-face on
          ;; the key's first [0,2) — spreading the whole key
          ;; through the frontend's display transform would paint
          ;; the entire line background, and stripping every
          ;; property loses the highlight; the right move is to
          ;; embed a face-carrying substring into the visible
          ;; "  " + id text
          (lambda (cand transform)
            (if transform
                (let* ((c (copy-sequence cand))
                       (id (car (dsh-emacs--model-key-parts cand))))
                  (if (and id (> (length id) 0))
                      (let ((sub (substring c 0 (length id))))
                        ;; The substring drops display/invisible (properties
                        ;; of the hidden part) while keeping face.
                        (remove-text-properties
                         0 (length sub) '(display nil invisible nil) sub)
                        sub)
                    c))
              (let ((parts (dsh-emacs--model-key-parts cand)))
                (and parts (substring-no-properties (nth 2 parts)))))))
         (table (dsh-emacs-ui--completion-table-with-metadata
                 rows
                 ;; Emacs 31's completion-table-with-metadata wants
                 ;; the metadata without the (metadata ...) prefix —
                 ;; give it the plist directly and it wraps it itself.
                 ;; (category . dsh-model): nerd-icons-completion
                 ;; inserts an icon at the start of every candidate
                 ;; row — in its icon table the nil category maps to
                 ;; nf-cod-arrow_small_right (the "->" arrow at line
                 ;; start) while categories absent from the table
                 ;; return an empty string; declaring a private
                 ;; category keeps the row start icon-free (and
                 ;; marginalia injects no suffix annotation either,
                 ;; because the category is not in its annotator
                 ;; table).
                 ;; An identity affixation-function is the last
                 ;; backstop: a third-party package trying to append
                 ;; an annotation/affixation suffix is overridden too
                 (list (cons 'category 'dsh-model)
                       (cons 'group-function group-fn)
                       (cons 'affixation-function
                             (lambda (cands)
                               (mapcar (lambda (c) (list c "" "")) cands)))))))
    (cons table rows)))

;; Model picker row-start icon (optional integration, no new
;; dependency): the picker metadata declares category=dsh-model;
;; once nerd-icons-completion is loaded, register a default chip
;; icon (nf-cod-chip) for that category — it shows at the row
;; start with no user configuration.  To change the icon,
;; add-to-list a same-category entry in your own config first and
;; it overrides the default (the default registration is skipped
;; when assq already finds one).  No effect when
;; nerd-icons-completion is not installed.
(defun dsh-emacs--install-model-completion-icon ()
  "Register the default model-picker icon without overriding user choices."
  (when (and (boundp 'nerd-icons-completion-category-icons)
             (not (assq 'dsh-model nerd-icons-completion-category-icons)))
    (add-to-list 'nerd-icons-completion-category-icons
                 '(dsh-model . (nerd-icons-codicon "nf-cod-chip" nerd-icons-blue)))))

(eval-after-load 'nerd-icons-completion
  #'dsh-emacs--install-model-completion-icon)

(defun dsh-emacs--model-select-setup-hook (grouped)
  "Buffer-local tweaks for the model picker's minibuffer.
GROUPED says whether vertico's native group-function rendering is
active (see the detection in `dsh-emacs--read-model-selection').
Sorting and preselect are tamed locally so the provider order and the
cursor position stay put; when GROUPED, `vertico-group-format' is
overridden buffer-locally by `dsh-emacs-model-group-format' (killing
the stock long separator lines inside the picker only)."
  (when (boundp 'vertico-sort-function)
    (setq-local vertico-sort-function nil))
  (when (boundp 'vertico-sort-override-function)
    (setq-local vertico-sort-override-function nil))
  (when (boundp 'vertico-preselect)
    (setq-local vertico-preselect 'first))
  (when (and grouped (boundp 'vertico-group-format))
    (setq-local vertico-group-format dsh-emacs-model-group-format))
  ;; Return nil explicitly: Emacs 31's minibuffer-with-setup-hook
  ;; funcalls the evaluation result of the SETUP expression, so
  ;; never let another value flow back (such as the setq-local
  ;; value above — that would become "Invalid function: ...")
  nil)

;; Interactive entry needs the session coordinator as well as this module.
;;;###autoload (autoload 'dsh-emacs-select-model "dsh-emacs" nil t)
(defun dsh-emacs-select-model ()
  "Choose a model for the current session from the live model catalog.
Lists the models the host can route to (`session/modelCatalog'), shows each
under its provider as its id, reads one with `completing-read'
and switches via `session/selectModel'.  Each row's key carries its
provider (hidden from display), and the provider display name is part
of the key too, so provider names stay searchable while filtering.
Modern vertico draws sticky provider group headers from the table's
`group-function' metadata (an Emacs 27+ *Completions* buffer does the
same), kept while any row of the group matches the query; without a
group-aware UI, header rows plus a per-row provider suffix on
colliding ids are shown.  The mode-line model segment updates
immediately."
  (interactive)
  (dsh-emacs-subagent-require 'mutate)
  (dsh-emacs-server-ensure)
  (let ((session-id (dsh-emacs--active-session-id)))
    (unless session-id (user-error "Open or select a session first"))
    ;; `session/modelCatalog' is session-agnostic (args {}), so its only
    ;; "current"-ish value is the host `default'.  The session's real
    ;; running model lives in the cached row's `modelSelection' projection
    ;; (`lastUsed'), and is resolved inside `dsh-emacs--select-model-prompt'
    ;; (falling back to the catalog default only when the row has none yet).
    (dsh-emacs--rpc-async "session/modelCatalog" nil
                          (lambda (ok value)
                            (if (not ok)
                                (message "Failed to list models: %s"
                                         (dsh-emacs-rpc-error-text value))
                              (dsh-emacs--select-model-prompt
                               session-id value))))))

(defun dsh-emacs--read-model-selection (directory current)
  "Read a model and effort from decoded DIRECTORY relative to CURRENT.
Return (CANDIDATE EFFORT), where CANDIDATE is a model tuple from
`dsh-emacs--model-candidates', or nil when no model is selected.
Empty input keeps the current model.  Header and unknown selections report
why they cannot be used.  Quit propagates to the RPC callback boundary."
  (let* ((current-model (and current
                             (dsh-protocol-model-selection-model current)))
         (current-provider (and current
                                (dsh-protocol-model-selection-provider current)))
         (candidates (dsh-emacs--model-candidates directory))
         (provider-label
          (or (cl-loop for (_id provider name) in candidates
                       when (equal provider current-provider) return name)
              current-provider))
         ;; Vertico applies group metadata only while this public option is
         ;; non-nil.  Other frontends keep the candidate-header fallback.
         (grouped (and (bound-and-true-p vertico-mode)
                       (bound-and-true-p vertico-group-format)))
         (grouped-pair (and grouped
                            (dsh-emacs--model-grouped-collection candidates)))
         (entries (if grouped (cdr grouped-pair)
                    (dsh-emacs--model-entries candidates)))
         (collection (if grouped (car grouped-pair) entries))
         (prompt (format "Select model%s: "
                         (if current-model
                             (format " (current %s)"
                                     (if (and provider-label
                                              (not (string-empty-p provider-label)))
                                         (concat provider-label "/" current-model)
                                       current-model))
                           "")))
         ;; Do not pass DEF: Vertico would move it out of its provider group.
         (picked (minibuffer-with-setup-hook
                     (lambda () (dsh-emacs--model-select-setup-hook grouped))
                   (completing-read prompt collection nil nil nil nil nil)))
         (entry (assoc picked entries)))
    (cond
     ((or (null picked) (equal picked ""))
      (message (if current-model
                   (format "Kept current model %s" current-model)
                 "Kept the current model"))
      nil)
     ((null entry)
      (message "Unknown model: %s" picked)
      nil)
     ((eq :header (car (cdr entry)))
      (message "That is a provider header — pick a model below it")
      nil)
     (t
      (pcase-let* ((candidate (cdr entry))
                   (`(,model ,_provider ,_provider-name ,_model-name ,reasoning)
                    candidate)
                   (effort
                    (and reasoning
                         (dsh-emacs--model-pick-effort
                          model (dsh-emacs--model-effort-choices reasoning)
                          (dsh-emacs--model-effort-default-id
                           reasoning
                           (and (equal model current-model)
                                (dsh-protocol-model-selection-reasoning-effort
                                 current)))))))
        (list candidate effort))))))

(defun dsh-emacs--select-model-prompt (session-id value)
  "Read and apply a model for SESSION-ID from a model-catalog VALUE.
The session's cached selection outranks the catalog default.  Reading is
separate from RPC submission; quit is caught here because this function
runs in the catalog's asynchronous process-filter callback."
  (condition-case nil
      (let* ((directory (dsh-protocol-model-directory--from-alist value))
             (current (or (dsh-emacs--session-model-selection session-id)
                          (dsh-protocol-model-directory-current directory))))
        (when-let* ((selection
                     (dsh-emacs--read-model-selection directory current)))
          (pcase-let ((`((,model ,provider ,provider-name ,model-name ,_reasoning)
                         ,effort)
                       selection))
            (dsh-emacs--rpc-async
             "session/selectModel"
             (dsh-protocol-session-select-model-request
              session-id provider model effort)
             (lambda (ok result)
               (if ok
                   (progn
                     (dsh-emacs-modeline-set-model model)
                     (dsh-emacs-modeline-set-provider provider)
                     (dsh-emacs-modeline-set-effort effort)
                     ;; Fetch the new model's context snapshot as well as its
                     ;; selection; the previous context pressure is stale.
                     (dsh-emacs-list-sessions--fetch)
                     (message "Model switched to %s (%s)%s"
                              model-name provider-name
                              (if effort (format ", effort %s" effort) "")))
                 (message "Failed to switch model: %s"
                          (dsh-emacs-rpc-error-text result))))))))
    (quit (message "Model selection cancelled"))))

;;;###autoload (autoload 'dsh-emacs-select-effort "dsh-emacs" nil t)
(defun dsh-emacs-select-effort ()
  "Choose a reasoning effort for the current session's running model.
Reads the live model catalog (`session/modelCatalog') to find the running
model's `reasoning' options, pre-selects the effort the session already
runs at (or the model's default), and switches via `session/selectModel'
with the same provider and model.  A model without reasoning-effort
options reports that and sends no RPC; the mode-line effort segment
updates immediately."
  (interactive)
  (dsh-emacs-subagent-require 'mutate)
  (dsh-emacs-server-ensure)
  (let ((session-id (dsh-emacs--active-session-id)))
    (unless session-id (user-error "Open or select a session first"))
    (dsh-emacs--rpc-async "session/modelCatalog" nil
                          (lambda (ok value)
                            (if (not ok)
                                (message "Failed to list models: %s"
                                         (dsh-emacs-rpc-error-text value))
                              (dsh-emacs--select-effort-prompt
                               session-id value))))))

(defun dsh-emacs--read-effort-selection (directory current)
  "Read an effort for CURRENT from decoded DIRECTORY.
Return (PROVIDER MODEL EFFORT), or nil when the running model is unknown,
absent from the catalog or has no effort choices.  Quit propagates."
  (let* ((model (and current (dsh-protocol-model-selection-model current)))
         (provider (and current
                        (dsh-protocol-model-selection-provider current)))
         (effort (and current
                      (dsh-protocol-model-selection-reasoning-effort current))))
    (if (null model)
        (progn (message "No running model is known for this session") nil)
      (pcase-let* ((entry
                    (cl-find-if
                     (lambda (candidate)
                       (pcase-let ((`(,id ,owner . ,_) candidate))
                         (and (equal id model)
                              (or (null provider) (equal owner provider)))))
                     (dsh-emacs--model-candidates directory)))
                   (`(,_ ,entry-provider ,_ ,_ ,reasoning) entry)
                   (choices (dsh-emacs--model-effort-choices reasoning)))
        (cond
         ((null entry)
          (message "Model %s is not in the live catalog" model)
          nil)
         ((null choices)
          (message "Model %s offers no reasoning-effort options" model)
          nil)
         (t
          (list (or provider entry-provider) model
                (dsh-emacs--model-pick-effort
                 model choices
                 (dsh-emacs--model-effort-default-id reasoning effort)))))))))

(defun dsh-emacs--select-effort-prompt (session-id value)
  "Read and apply an effort for SESSION-ID from model-catalog VALUE.
The cached session selection outranks the catalog default.  Catch quit at
this asynchronous callback boundary, before any selection RPC is sent."
  (condition-case nil
      (let* ((directory (dsh-protocol-model-directory--from-alist value))
             (current (or (dsh-emacs--session-model-selection session-id)
                          (dsh-protocol-model-directory-current directory))))
        (when-let* ((selection
                     (dsh-emacs--read-effort-selection directory current)))
          (pcase-let ((`(,provider ,model ,effort) selection))
            (dsh-emacs--rpc-async
             "session/selectModel"
             (dsh-protocol-session-select-model-request
              session-id provider model effort)
             (lambda (ok result)
               (if ok
                   (progn
                     (dsh-emacs-modeline-set-effort effort)
                     ;; The next effort prompt reads the session cache.
                     (dsh-emacs-list-sessions--fetch)
                     (message "Reasoning effort set to %s" effort))
                 (message "Failed to set reasoning effort: %s"
                          (dsh-emacs-rpc-error-text result))))))))
    (quit (message "Reasoning-effort selection cancelled"))))

(provide 'dsh-emacs-model)
;;; dsh-emacs-model.el ends here
