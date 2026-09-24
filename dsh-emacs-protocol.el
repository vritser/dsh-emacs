;;; dsh-emacs-protocol.el --- Typed views of dsh RPC payloads -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.5.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; dsh server responses are JSON-decoded alists (arrays are vectors).  This
;; file distills the common responses into cl-defstruct types: every field name
;; appears exactly once, in its `--from-alist' constructor, and business code
;; always reads through accessors; when the server protocol changes only the
;; fields here need syncing, and callers need no per-use confirmation.
;;
;; Structure overview (endpoint to protocol):
;;
;;   session/list   → dsh-protocol-session             (sessionId title cwd
;;                                                       agentPreset updatedAt)
;;   workspace/follow baseline → dsh-protocol-workspace-list (items
;;                                                       archivedSessionIds)
;;                     ├─ dsh-protocol-workspace      (workspaceId sessionIds
;;                     │                               title path)
;;   session/modelCatalog → dsh-protocol-model-directory     (current . groups)
;;                     ├─ dsh-protocol-model-selection (provider model
;;                     │                                 reasoningEffort)
;;                     └─ dsh-protocol-provider-group  (id name models)
;;                          └─ dsh-protocol-model-catalog-entry (id name
;;                                description reasoning)
;;                               └─ dsh-protocol-reasoning (efforts
;;                                    defaultEffort)
;;                                    └─ dsh-protocol-effort (id name
;;                                         description)
;;   agentPresets/list → dsh-protocol-agent-preset-list (presets
;;                       mode-selection-enabled)
;;                        └─ dsh-protocol-agent-preset (id is-default name
;;                             description broken)
;;   commands.list    → dsh-protocol-command (name description input)
;;                        └─ dsh-protocol-command-input (hint attachments)
;;   commands.execute → dsh-protocol-command-execution (command-id
;;                        result kind text)
;;   skills.list      → dsh-protocol-skill-list (skills)
;;                        └─ dsh-protocol-skill (name description when-to-use
;;                             model-invocable path)
;;   inbox projection → dsh-protocol-queue-item (id placement text kind)
;;   permissionPresets/catalog → dsh-protocol-permission-catalog (options)
;;                        └─ dsh-protocol-permission-option (value name
;;                             description)
;;
;; Conversion entry points all accept a wire alist; note that arrays (vectors)
;; on the wire are always normalized to lists inside the structs.  Once
;; business code caches a struct, it reads it uniformly through the
;; `dsh-protocol-*' accessors.

;;; Code:

(require 'cl-lib)

(defun dsh-protocol--list (value)
  "JSON VALUE (list or vector) as a proper list."
  (cond ((vectorp value) (append value nil))
        ((listp value) value)
        (t nil)))

(defun dsh-protocol--objects (value)
  "JSON array VALUE as a list of its object elements.
A non-object element — a string, number, or null where the wire promised an
object — is dropped here, at the boundary: the `--from-alist' constructors
unpack their fields by key, which expects an object, so a malformed element
must decline rather than break the caller."
  (delq nil (mapcar (lambda (item) (and (consp item) item))
                    (dsh-protocol--list value))))

(defun dsh-protocol--field (key alist)
  "Return KEY's value from wire ALIST, accepting string and symbol keys.
`json-read' normally produces symbol-keyed alists while fixtures and renderer
call sites use JSON field names, so a `--from-alist' constructor must accept
both.  A non-list ALIST (a number, symbol, or string where the wire promised
an object) yields nil rather than signalling."
  (when (listp alist)
    (cdr (or (assoc key alist)
             (assoc (if (stringp key) (intern key) (symbol-name key)) alist)))))

(defun dsh-protocol--boolean (value)
  "Return wire VALUE as a strict boolean, mapping JSON `false' to nil.
`json-read' decodes false as the truthy symbol `:json-false', so a flag must
be normalized where it crosses into a struct: otherwise an idle session
carries a truthy `running' value and every consumer that tests the field
directly (e.g. `dsh-emacs--busy-p') misreads it as running.  Every JSON
boolean field read by a `--from-alist' constructor passes through here, so a
struct never hands a caller `:json-false'."
  (and value (not (eq value :json-false))))

;; ---------------------------------------------------------------------------
;; session/list / workspace/follow baseline
;; ---------------------------------------------------------------------------

(cl-defstruct (dsh-protocol-session
               (:constructor dsh-protocol-session--from-alist
                             (alist
                              &aux
                              (session-id (cdr (assq 'sessionId alist)))
                              (title (cdr (assq 'title alist)))
                              (cwd (cdr (assq 'cwd alist)))
                              ;; In dsh 0.1.2 `agentPreset' is a session
                              ;; projection (`projections.values.agentPreset'),
                              ;; delivered on `session/list' rows and
                              ;; follow/control projection frames; the top-level
                              ;; `agentPreset' field only appears on the
                              ;; optimistic `session/create' cache row (see
                              ;; `dsh-emacs--cache-new-session').
                              (agent-preset
                               (or (let* ((p (cdr (assq 'projections alist)))
                                          (v (and p (cdr (assq 'values p)))))
                                     (and v (cdr (assq 'agentPreset v))))
                                   (cdr (assq 'agentPreset alist))))
                              (updated-at (cdr (assq 'updatedAt alist)))
                              (blank (dsh-protocol--boolean
                                      (cdr (assq 'blank alist))))
                              (running (dsh-protocol--boolean
                                        (cdr (assq 'running alist))))
                              ;; Sub-session markers: a subagent carries both
                              ;; origin="subagent"
                              ;; and parentSessionId; a fork child has only
                              ;; parentSessionId (no origin)
                              (parent-session-id
                               (cdr (assq 'parentSessionId alist)))
                              ;; subagent session marker (server schema:
                              ;; origin: literal("subagent")); when non-nil it
                              ;; should be hidden from the session list
                              (origin (cdr (assq 'origin alist)))
                              ;; projections.values.title — dsh web's
                              ;; auto-summary title (same as the list row's
                              ;; display title)
                              (title-value
                               (let ((p (cdr (assq 'projections alist))))
                                 (and p (cdr (assq 'title
                                                   (cdr (assq 'values p)))))))
                              ;; projections.values.contextPressure — the
                              ;; server's authoritative estimate of the current
                              ;; context occupancy (the ctx% segment uses it,
                              ;; not cumulative token usage, which is the
                              ;; session total and far exceeds the window)
                              (context-pressure
                               (let* ((p (cdr (assq 'projections alist)))
                                      (v (and p (cdr (assq 'values p))))
                                      (cp (and v
                                               (cdr (assq 'contextPressure v)))))
                                 (and cp (cdr (assq 'pressureTokens cp)))))
                              ;; the window size inside the same
                              ;; contextPressure object
                              (context-window
                               (let* ((p (cdr (assq 'projections alist)))
                                      (v (and p (cdr (assq 'values p))))
                                      (cp (and v
                                               (cdr (assq 'contextPressure v)))))
                                 (and cp (cdr (assq 'contextWindow cp)))))
                              ;; contextPressure.projectedTokens — pressure plus
                              ;; the surface delta (answers "how much will the
                              ;; next request occupy").  dsh web's ctx indicator
                              ;; prefers it (StatsLine: projected ??
                              ;; pressure); align with that definition.
                              (context-projected
                               (let* ((p (cdr (assq 'projections alist)))
                                      (v (and p (cdr (assq 'values p))))
                                      (cp (and v
                                               (cdr (assq 'contextPressure v)))))
                                 (and cp (cdr (assq 'projectedTokens cp)))))
                              ;; projections.values.modelSelection.lastUsed —
                              ;; the (provider, model,
                              ;; reasoningEffort?) triple the session last used
                              ;; (the mode-line's authoritative current source;
                              ;; §9 modelSelection projection).
                              (model-selection
                               (let* ((p (cdr (assq 'projections alist)))
                                      (v (and p (cdr (assq 'values p))))
                                      (ms (and v
                                               (cdr (assq 'modelSelection v)))))
                                 (and ms (cdr (assq 'lastUsed ms))))))))
  "One `session/list' item."
  session-id
  title
  cwd
  agent-preset
  updated-at
  blank
  running
  origin
  parent-session-id
  title-value
  context-pressure
  context-window
  context-projected
  model-selection)

(cl-defstruct (dsh-protocol-workspace
               (:constructor dsh-protocol-workspace--from-alist
                             (alist
                              &aux
                              (workspace-id (cdr (assq 'workspaceId alist)))
                              (session-ids (dsh-protocol--list
                                            (cdr (assq 'sessionIds alist))))
                              (title (cdr (assq 'title alist)))
                              (path (cdr (assq 'path alist)))
                              (created-at (cdr (assq 'createdAt alist)))
                              (updated-at (cdr (assq 'updatedAt alist))))))
  "One workspace row of the `workspace/follow' baseline (the
`WorkspaceView' shape)."
  workspace-id
  session-ids
  title
  path
  created-at
  updated-at)

(cl-defstruct (dsh-protocol-workspace-list
               (:constructor dsh-protocol-workspace-list--from-alist
                             (alist
                              &aux
                              (items (mapcar #'dsh-protocol-workspace--from-alist
                                             (dsh-protocol--list
                                              (cdr (assq 'items alist)))))
                              (archived-session-ids
                               (dsh-protocol--list
                                (cdr (assq 'archivedSessionIds alist)))))))
  "The `workspace/follow' baseline value: ITEMS plus the ARCHIVED-SESSION-IDS."
  items
  archived-session-ids)

(cl-defstruct (dsh-protocol-workspace-result
               (:constructor dsh-protocol-workspace-result--from-alist
                             (alist
                              &aux
                              (workspace (and (cdr (assq 'workspace alist))
                                              (dsh-protocol-workspace--from-alist
                                               (cdr (assq 'workspace alist)))))
                              (created (cdr (assq 'created alist))))))
  "A workspace mutation response: `workspace/create' (WORKSPACE + CREATED
flag), `workspace/rename' and `workspace/insertBefore' (WORKSPACE
only; CREATED is nil there)."
  workspace
  created)

(cl-defstruct (dsh-protocol-archived-set
               (:constructor dsh-protocol-archived-set--from-alist
                             (alist
                              &aux
                              (archived-session-ids
                               (dsh-protocol--list
                                (cdr (assq 'archivedSessionIds alist)))))))
  "The `workspace/archiveSession' response value: the full updated archive set."
  archived-session-ids)

;; ---------------------------------------------------------------------------
;; session/modelCatalog
;; ---------------------------------------------------------------------------

(cl-defstruct (dsh-protocol-effort
               (:constructor dsh-protocol-effort--from-alist
                             (alist
                              &aux
                              (id (cdr (assq 'id alist)))
                              (name (cdr (assq 'name alist)))
                              (description (cdr (assq 'description alist))))))
  "One reasoning-effort option of a model."
  id
  name
  description)

(cl-defstruct (dsh-protocol-reasoning
               (:constructor dsh-protocol-reasoning--from-alist
                             (alist
                              &aux
                              (efforts
                               (mapcar #'dsh-protocol-effort--from-alist
                                       (dsh-protocol--list
                                        (cdr (assq 'efforts alist)))))
                              (default-effort (cdr (assq 'defaultEffort
                                                         alist))))))
  "A model's reasoning metadata: its EFFORTS options and the default id."
  efforts
  default-effort)

(cl-defstruct (dsh-protocol-model-catalog-entry
               (:constructor dsh-protocol-model-catalog-entry--from-alist
                             (alist
                              &aux
                              (id (cdr (assq 'id alist)))
                              (name (cdr (assq 'name alist)))
                              (description (cdr (assq 'description alist)))
                              (reasoning (and (cdr (assq 'reasoning alist))
                                              (dsh-protocol-reasoning--from-alist
                                               (cdr (assq 'reasoning alist))))))))
  "One advisory model entry inside a provider group."
  id
  name
  description
  reasoning)

(cl-defstruct (dsh-protocol-provider-group
               (:constructor dsh-protocol-provider-group--from-alist
                             (alist
                              &aux
                              (id (cdr (assq 'id alist)))
                              (name (cdr (assq 'name alist)))
                              (models
                               (mapcar
                                #'dsh-protocol-model-catalog-entry--from-alist
                                (dsh-protocol--list
                                 (cdr (assq 'models alist))))))))
  "One provider group of the model directory."
  id
  name
  models)

(cl-defstruct (dsh-protocol-model-selection
               (:constructor dsh-protocol-model-selection--from-alist
                             (alist
                              &aux
                              (provider (cdr (assq 'provider alist)))
                              (model (cdr (assq 'model alist)))
                              (reasoning-effort
                               (cdr (assq 'reasoningEffort alist))))))
  "The session's live model selection (`current' / `selected')."
  provider
  model
  reasoning-effort)

(cl-defstruct (dsh-protocol-model-selection-result
               (:constructor dsh-protocol-model-selection-result--from-alist
                             (alist
                              &aux
                              (selected (and (cdr (assq 'selected alist))
                                             (dsh-protocol-model-selection--from-alist
                                              (cdr (assq 'selected alist))))))))
  "The `session/selectModel' response value (the SELECTED selection)."
  selected)

(cl-defstruct (dsh-protocol-model-directory
               (:constructor dsh-protocol-model-directory--from-alist
                             (alist
                              &aux
                              ;; `session/modelCatalog' has no session-scoped
                              ;; `current'; its host `default' selection folds
                              ;; into CURRENT so the picker can keep treating
                              ;; it as the reference model.
                              (current (let ((c (or (cdr (assq 'current alist))
                                                    (cdr (assq 'default alist)))))
                                         (and c
                                              (dsh-protocol-model-selection--from-alist
                                               c))))
                              (groups
                               (mapcar #'dsh-protocol-provider-group--from-alist
                                       (dsh-protocol--list
                                        (cdr (assq 'groups alist)))))
                              (failures
                               (dsh-protocol--list (cdr (assq 'failures alist)))))))
  "A `session/modelCatalog' (or legacy directory) value: CURRENT/`default'
selection, GROUPS by provider and unknown FAILURES.  The wire's
`routableProviders' list is deliberately not carried — no consumer reads it."
  current
  groups
  failures)

;; ---------------------------------------------------------------------------
;; agentPresets/list
;; ---------------------------------------------------------------------------

(cl-defstruct (dsh-protocol-agent-preset
               (:constructor dsh-protocol-agent-preset--from-alist
                             (alist
                              &aux
                              (id (cdr (assq 'id alist)))
                              (is-default (dsh-protocol--boolean
                                           (cdr (assq 'isDefault alist))))
                              (name (cdr (assq 'name alist)))
                              (description (cdr (assq 'description alist)))
                              (broken (cdr (assq 'broken alist))))))
  "One `agentPresets/list' entry.
There is no `trust' field: dsh 0.1.7 dropped it, so a client keys any
built-in label on ID alone (`dsh-emacs--preset-display-name')."
  id
  is-default
  name
  description
  broken)

(cl-defstruct (dsh-protocol-agent-preset-list
               (:constructor dsh-protocol-agent-preset-list--from-alist
                             (alist
                              &aux
                              (presets (mapcar #'dsh-protocol-agent-preset--from-alist
                                               (dsh-protocol--list
                                                (cdr (assq 'presets alist)))))
                              (mode-selection-enabled
                               (dsh-protocol--boolean
                                (cdr (assq 'modeSelectionEnabled alist)))))))
  "The `agentPresets/list' response value: the PRESETS roster plus whether
visible mode selection governs unnamed new sessions.  The 0.1.6 `authorable'
and never-sent `hasDocument' flags are gone."
  presets
  mode-selection-enabled)

;; Convenience entry that normalizes a wire alist into a struct: an
;; already-converted struct is returned as-is.  This lets business functions
;; accept both a "protocol response" and a "converted struct", so callers (and
;; the bare alist fixtures in existing tests) need no changes.
;; ---------------------------------------------------------------------------
;; commands.list / commands.execute
;; ---------------------------------------------------------------------------

;; The `commands.list' response VALUE is a bare array of command items (no
;; envelope object), so callers map it with `dsh-protocol--list' +
;; `dsh-protocol-command--from-alist' directly.

(cl-defstruct (dsh-protocol-command-input
               (:constructor dsh-protocol-command-input--from-alist
                             (alist
                              &aux
                              (hint (cdr (assq 'hint alist)))
                              (attachments (dsh-protocol--boolean
                                            (cdr (assq 'attachments alist)))))))
  "The optional `input' descriptor of a command item: HINT is the argument
placeholder, ATTACHMENTS whether the command accepts composed attachments
(images and staged file receipts)."
  hint
  attachments)

(cl-defstruct (dsh-protocol-command
               (:constructor dsh-protocol-command--from-alist
                             (alist
                              &aux
                              (name (cdr (assq 'name alist)))
                              (description (cdr (assq 'description alist)))
                              (input (let ((input (cdr (assq 'input alist))))
                                       (and input
                                            (dsh-protocol-command-input--from-alist
                                             input)))))))
  "One `commands.list' item: a slash command the host can execute."
  name
  description
  input)

(cl-defstruct (dsh-protocol-command-execution
               (:constructor dsh-protocol-command-execution--from-alist
                             (alist
                              &aux
                              (command-id (cdr (assq 'commandId alist)))
                              (result (cdr (assq 'result alist)))
                              (kind (let ((r (cdr (assq 'result alist))))
                                      (and r (cdr (assq 'kind r)))))
                              (text (let ((r (cdr (assq 'result alist))))
                                      (and r (cdr (assq 'text r))))))))
  "The admitted `commands.execute' response value: COMMAND-ID pairs the
`command/run' / `command/done' session events, KIND is \\='success or
\\='error, TEXT the optional outcome text."
  command-id
  result
  kind
  text)

;; ---------------------------------------------------------------------------
;; skills.list
;; ---------------------------------------------------------------------------
;; The `skills' namespace has this one endpoint: a cold read of the
;; user-invocable skills of one Session composition (cwd + agent preset).  It
;; takes `{request: {sessionId}}' — unlike `commands.list', whose session rides
;; the `agentId' scope lookup.  There is no invocation Remote: a `/name'
;; gesture in a user prompt is what the host's skill tool expands (see
;; dsh-emacs-skill.el).

(cl-defstruct (dsh-protocol-skill
               (:constructor dsh-protocol-skill--from-alist
                             (alist
                              &aux
                              (name (cdr (assq 'name alist)))
                              (description (cdr (assq 'description alist)))
                              (when-to-use (cdr (assq 'whenToUse alist)))
                              (model-invocable
                               (dsh-protocol--boolean
                                (cdr (assq 'modelInvocable alist))))
                              (path (cdr (assq 'path alist))))))
  "One `skills.list' entry: a skill the user may invoke as `/NAME'.
DESCRIPTION is the one-line summary; WHEN-TO-USE the optional model-facing
hint.  MODEL-INVOCABLE says the model may also load the skill through the
`skill' tool — when nil the skill is user-only.  PATH is the absolute
`SKILL.md' path when the mounted provider supplies one (dsh 0.1.6+), so it
is nil for providers that manage their own resources."
  name
  description
  when-to-use
  model-invocable
  path)

(cl-defstruct (dsh-protocol-skill-list
               (:constructor dsh-protocol-skill-list--from-alist
                             (alist
                              &aux
                              (skills (mapcar
                                       #'dsh-protocol-skill--from-alist
                                       (dsh-protocol--objects
                                        (dsh-protocol--field 'skills
                                                             alist)))))))
  "The `skills.list' response value: the session's user-invocable skills, in
the host's order."
  skills)

;; ---------------------------------------------------------------------------
;; permissionPresets/catalog
;; ---------------------------------------------------------------------------
;; dsh 0.1.6 split the selectable permission presets out of the `permissions'
;; session projection (which now carries only `currentValue'): this
;; process-level catalog is the only source of options, and the switch itself
;; is the `/permission' slash command (the namespace has no write Remote).

(cl-defstruct (dsh-protocol-permission-option
               (:constructor dsh-protocol-permission-option--from-alist
                             (alist
                              &aux
                              (value (cdr (assq 'value alist)))
                              (name (cdr (assq 'name alist)))
                              (description (cdr (assq 'description alist))))))
  "One selectable permission preset: VALUE is the switch target, NAME its
display label, DESCRIPTION the optional explanation."
  value
  name
  description)

(cl-defstruct (dsh-protocol-permission-catalog
               (:constructor dsh-protocol-permission-catalog--from-alist
                             (alist
                              &aux
                              (options (mapcar
                                        #'dsh-protocol-permission-option--from-alist
                                        (dsh-protocol--list
                                         (cdr (assq 'options alist))))))))
  "The `permissionPresets/catalog' value: every currently selectable preset,
in contribution order.  The derived `custom' state is not an option."
  options)

;; ---------------------------------------------------------------------------
;; user-questions/request waterfall items
;; ---------------------------------------------------------------------------

(cl-defstruct (dsh-protocol-question-option
               (:constructor dsh-protocol-question-option--from-alist
                             (alist
                              &aux
                              (label (cdr (assq 'label alist)))
                              (description (cdr (assq 'description alist))))))
  "One offered answer label and its optional supporting description."
  label
  description)

(cl-defstruct (dsh-protocol-question
               (:constructor dsh-protocol-question--from-alist
                             (alist
                              &aux
                              (id (cdr (assq 'id alist)))
                              (text (cdr (assq 'question alist)))
                              (header (cdr (assq 'header alist)))
                              (detail (cdr (assq 'detail alist)))
                              (options
                               (mapcar
                                #'dsh-protocol-question-option--from-alist
                                (dsh-protocol--objects
                                 (cdr (assq 'options alist)))))
                              (multi-select
                               ;; The ask request spells this flag
                               ;; `multiSelect'; the `ask_user_question'
                               ;; tool's own arguments spell it
                               ;; `multi_select'.  Same flag, same
                               ;; question, so both decode here.
                               (dsh-protocol--boolean
                                (or (cdr (assq 'multiSelect alist))
                                    (cdr (assq 'multi_select alist))))))))
  "One `user-questions/request' item, with options in their offered order."
  id
  text
  header
  detail
  options
  multi-select)

;; ---------------------------------------------------------------------------
;; inbox projection items (the pending-input queue since dsh 0.1.7)
;; ---------------------------------------------------------------------------

;; The `inbox' session projection VALUE is
;; `{"next-turn": [...], "next-step": [...]}' where each entry is a JSON-safe
;; `UserMessage' alist (`{id, content, source}').  dsh 0.1.7 deleted the
;; `session/control' queue frames that used to carry the same state, so the
;; client derives the mirror from this projection; the projection itself has
;; been published unchanged since before 0.1.5.

(cl-defstruct (dsh-protocol-queue-item
               (:constructor dsh-protocol-queue-item--from-message
                             (message placement
                              &aux
                              (id (cdr (assq 'id message)))
                              (text
                               (mapconcat
                                (lambda (block)
                                  (or (and (equal (cdr (assq 'type block))
                                                  "text")
                                           (cdr (assq 'text block)))
                                      ""))
                                (dsh-protocol--list
                                 (cdr (assq 'content message)))
                                ""))
                              (kind
                               (let ((s (cdr (assq 'source message))))
                                 (and s (cdr (assq 'kind s))))))))
  "One pending-inbox item: PLACEMENT is `queued' (next turn), `steering'
(next-step user input) or `context' (host-injected next-step content);
TEXT the message's text blocks concatenated, KIND the message's source
kind (`user' for real user input)."
  id
  placement
  text
  kind)

(defun dsh-protocol-queue-items-from-inbox (value)
  "Normalize an `inbox' projection VALUE into queue item structs.
VALUE is `((next-turn . [...]) (next-step . [...]))' with one JSON-safe
`UserMessage' alist per entry.  `next-turn' entries become `queued'
items; a `next-step' entry with a `user' source becomes `steering', any
other `context' — the same placement the host applied before 0.1.7, and
in the same next-turn-then-next-step order."
  (append
   (mapcar (lambda (message)
             (dsh-protocol-queue-item--from-message message 'queued))
           (dsh-protocol--list (and (listp value)
                                    (cdr (assq 'next-turn value)))))
   (mapcar (lambda (message)
             (dsh-protocol-queue-item--from-message
              message
              (let ((source (cdr (assq 'source message))))
                (if (equal "user" (and source (cdr (assq 'kind source))))
                    'steering
                  'context))))
           (dsh-protocol--list (and (listp value)
                                    (cdr (assq 'next-step value)))))))

;; ---------------------------------------------------------------------------
;; @ reference candidates (typert remotes used by dsh-emacs-reference.el)
;; ---------------------------------------------------------------------------

;; `fileReferences/list' VALUE is a bare array of path-only candidates;
;; `sessionReferenceResolver/candidates' a bare array of mention-carrying
;; candidates.  Both are mapped with `dsh-protocol--list' + the matching
;; --from-alist constructor, the same pattern as `commands.list'.

(cl-defstruct (dsh-protocol-file-reference-candidate
               (:constructor dsh-protocol-file-reference-candidate--from-alist
                             (alist
                              &aux
                              (path (cdr (assq 'path alist)))
                              (kind (cdr (assq 'kind alist))))))
  "One `fileReferences/list' item: a path-only completion candidate.
PATH is the user-facing path inside the session cwd, KIND \\='file or
\\='directory (directories keep completion open after a trailing slash)."
  path
  kind)

(cl-defstruct (dsh-protocol-session-reference-candidate
               (:constructor dsh-protocol-session-reference-candidate--from-alist
                             (alist
                              &aux
                              (session-id (cdr (assq 'sessionId alist)))
                              (label (cdr (assq 'label alist)))
                              (cwd (cdr (assq 'cwd alist)))
                              (same-workspace (cdr (assq 'sameWorkspace alist)))
                              (created-at (cdr (assq 'createdAt alist)))
                              (mention (cdr (assq 'mention alist))))))
  "One `sessionReferenceResolver/candidates' item.
SESSION-ID is the opaque source identity, LABEL the latest log-backed
title (falling back to the id), CWD the source working directory when
recorded, SAME-WORKSPACE whether it equals the requesting session's,
CREATED-AT the source creation epoch milliseconds, and MENTION the
canonical `@[label](dsh-session:...)' prompt text the client inserts."
  session-id
  label
  cwd
  same-workspace
  created-at
  mention)

;; ---------------------------------------------------------------------------
;; goal projection (§9 `goal` cell) — parsed for the Composer Goal Row
;; ---------------------------------------------------------------------------
;; The `goal' session projection value is the GoalView core the host folds
;; from goals.* state: `{ goal: {id, revision, objective, phase,
;; blockedReason?, maxGoalRounds}, roundsStarted, createdAt, updatedAt }` or
;; null.  Phase 1 renders only objective/phase (display chrome); the rest is
;; carried so the row can grow without re-wiring callers.

(cl-defstruct (dsh-protocol-goal
               (:constructor dsh-protocol-goal--from-alist
                             (value &aux
                                    (id (alist-get 'id value))
                                    (revision (alist-get 'revision value))
                                    (objective (alist-get 'objective value))
                                    (phase (alist-get 'phase value))
                                    (blocked-reason (alist-get 'blockedReason value))
                                    (max-goal-rounds (alist-get 'maxGoalRounds value)))))
  "A goal core from a projection or mutation response."
  id revision objective phase blocked-reason max-goal-rounds rounds-started)

(defun dsh-protocol-goal-projection--from-alist (value)
  "Decode goal projection VALUE, including its progress, or nil."
  (when-let* ((core (and (listp value) (alist-get 'goal value)))
              (goal (dsh-protocol-goal--from-alist core)))
    (setf (dsh-protocol-goal-rounds-started goal)
          (alist-get 'roundsStarted value))
    goal))

;; Process-local assistant presentation frames and reconnect state.
(cl-defstruct (dsh-protocol-assistant-frame
               (:constructor dsh-protocol-assistant-frame--from-alist
                             (alist &aux
                              (type (dsh-protocol--field 'type alist))
                              (revision (dsh-protocol--field 'revision alist))
                              (attempt-id (dsh-protocol--field
                                           'attemptId alist))
                              (turn (dsh-protocol--field 'turn alist))
                              (step (dsh-protocol--field 'step alist))
                              (index (dsh-protocol--field 'index alist))
                              (chunk (dsh-protocol--field 'chunk alist))
                              (outcome-kind
                               (dsh-protocol--field
                                'kind
                                (dsh-protocol--field 'outcome alist))))))
  type revision attempt-id turn step index chunk outcome-kind)

;; One compact stream record: a packed delta run (`text-chunks' /
;; `reasoning-chunks' / `tool-call-chunks') or one raw `chunk'.
(cl-defstruct (dsh-protocol-assistant-record
               (:constructor dsh-protocol-assistant-record--from-alist
                             (alist &aux
                              (type (dsh-protocol--field 'type alist))
                              (index (dsh-protocol--field 'index alist))
                              (texts (dsh-protocol--list
                                      (dsh-protocol--field 'texts alist)))
                              (name (dsh-protocol--field 'name alist))
                              (args (dsh-protocol--list
                                     (dsh-protocol--field 'args alist)))
                              (chunk (dsh-protocol--field 'chunk alist)))))
  type index texts name args chunk)

(defun dsh-protocol--assistant-records (value)
  "Compact stream VALUE (a JSON record array) as record structs.
Non-object elements are dropped here, at the boundary."
  (mapcar #'dsh-protocol-assistant-record--from-alist
          (dsh-protocol--objects value)))

(cl-defstruct (dsh-protocol-assistant-baseline
               (:constructor dsh-protocol-assistant-baseline--from-alist
                             (alist &aux
                              (revision (dsh-protocol--field 'revision alist))
                              (attempt (dsh-protocol--field
                                        'activeAttempt alist))
                              (attempt-id (dsh-protocol--field
                                           'attemptId attempt))
                              (turn (dsh-protocol--field 'turn attempt))
                              (step (dsh-protocol--field 'step attempt))
                              (next-index (dsh-protocol--field
                                           'nextIndex attempt))
                              (stream (dsh-protocol--assistant-records
                                       (dsh-protocol--field
                                        'stream attempt))))))
  revision attempt-id turn step next-index stream)

(defun dsh-protocol-assistant-baseline--from-snapshot (value)
  "VALUE (a `session/follow' snapshot) as an assistant baseline struct.
An absent `assistantStream' field yields the empty baseline: nil revision,
no active attempt and no records."
  (dsh-protocol-assistant-baseline--from-alist
   (dsh-protocol--field 'assistantStream value)))

;; ---------------------------------------------------------------------------
;; Background jobs (the `job' namespace streams, 0.1.7+)
;; ---------------------------------------------------------------------------

;; `job/list' frames carry the whole roster per frame (`{type:"rows", jobs:[…]}');
;; `job/follow' frames carry one job's projection plus its output chunks
;; (`opened' / `output' / `status').  dsh 0.1.6 and earlier carried the same
;; jobs through the `session/control' `jobs' record, which 0.1.7 deleted; the
;; roster is now only available from this namespace.

(cl-defstruct (dsh-protocol-job
               (:constructor dsh-protocol-job--from-alist
                             (alist
                              &aux
                              (id (dsh-protocol--field 'id alist))
                              (kind (dsh-protocol--field 'kind alist))
                              (label (dsh-protocol--field 'label alist))
                              (owner (dsh-protocol--field 'owner alist))
                              (status (dsh-protocol--job-status
                                       (dsh-protocol--field 'status alist)))
                              (progress (dsh-protocol--field 'progress alist))
                              (detail (dsh-protocol--field 'detail alist))
                              (started-at (dsh-protocol--field 'startedAt alist))
                              (finished-at (dsh-protocol--field 'finishedAt alist))
                              (output (dsh-protocol--job-output
                                       (dsh-protocol--field 'output alist))))))
  "One background job (`job/list' `JobView').
STATUS is a symbol — `running', `stopping', `completed', `killed' or
`failed'.  PROGRESS is the producer's live line and DETAIL the terminal
reason (`exit code: 3', a recorded kill reason); both may be nil.
OUTPUT is the normalized `(TOTAL EARLIEST SPILL-PATHS)' tuple — the next
chunk's offset, the oldest retained byte (> 0 exactly when retention
dropped the head) and the spill files the job's sources keep (see
`dsh-protocol-job-output-spill-paths')."
  id
  kind
  label
  owner
  status
  progress
  detail
  started-at
  finished-at
  output)

(defun dsh-protocol--job-status (value)
  "Normalize the wire job STATUS string to a symbol.
The wire carries one of the closed set `running' / `stopping' /
`completed' / `killed' / `failed'; an unrecognized or absent value
becomes nil so callers can treat it as \"unknown\" rather than crash."
  (when (stringp value)
    (let ((sym (intern value)))
      (and (memq sym '(running stopping completed killed failed)) sym))))

(defun dsh-protocol--job-output (value)
  "Normalize a job's wire `output' object to `(TOTAL EARLIEST SPILL-PATHS)'.
TOTAL is the offset the next chunk starts at, EARLIEST the oldest retained
byte (> 0 exactly when retention dropped the head), SPILL-PATHS the spill
files the job's sources keep (nil when none)."
  (let* ((v (and (listp value) value))
         (spill (dsh-protocol--list (dsh-protocol--field 'spillPaths v))))
    (list (dsh-protocol--field 'total v)
          (dsh-protocol--field 'earliest v)
          spill)))

(defun dsh-protocol-job-output-total (job)
  "Retained-output high-water offset of JOB, or nil."
  (nth 0 (dsh-protocol-job-output job)))

(defun dsh-protocol-job-output-earliest (job)
  "Oldest retained offset of JOB, or nil."
  (nth 1 (dsh-protocol-job-output job)))

(defun dsh-protocol-job-output-spill-paths (job)
  "Spill files JOB's output sources currently keep, or nil."
  (nth 2 (dsh-protocol-job-output job)))

(cl-defstruct (dsh-protocol-job-list
               (:constructor dsh-protocol-job-list--from-alist
                             (alist
                              &aux
                              (type (dsh-protocol--field 'type alist))
                              (jobs (mapcar #'dsh-protocol-job--from-alist
                                            (dsh-protocol--objects
                                             (dsh-protocol--field 'jobs alist)))))))
  "One `job/list' frame: the complete roster the session can see.
JOBS replaces the previous roster wholesale, so a reconnect's first frame
is already the truth."
  type
  jobs)

(cl-defstruct (dsh-protocol-job-chunk
               (:constructor dsh-protocol-job-chunk--from-alist
                             (alist
                              &aux
                              (at (dsh-protocol--field 'at alist))
                              (text (dsh-protocol--field 'text alist))
                              (channel (dsh-protocol--job-channel
                                        (dsh-protocol--field 'channel alist)))
                              (gap-before
                               (dsh-protocol--field 'gapBefore alist)))))
  "One output chunk of a job: absolute offset AT, TEXT, stream CHANNEL.
GAP-BEFORE non-nil marks bytes lost immediately before this chunk."
  at
  text
  channel
  gap-before)

(defun dsh-protocol--job-channel (value)
  "Normalize the wire chunk CHANNEL to a symbol, or nil."
  (when (stringp value)
    (let ((sym (intern value)))
      (and (memq sym '(stdout stderr log)) sym))))

(cl-defstruct (dsh-protocol-job-frame
               (:constructor dsh-protocol-job-frame--from-alist
                             (alist
                              &aux
                              (type (dsh-protocol--field 'type alist))
                              (job (let ((j (dsh-protocol--field 'job alist)))
                                     (and (listp j)
                                          (dsh-protocol-job--from-alist j))))
                              (from (dsh-protocol--field 'from alist))
                              (next (dsh-protocol--field 'next alist))
                              (lossy (dsh-protocol--field 'lossy alist))
                              (chunks
                               (mapcar #'dsh-protocol-job-chunk--from-alist
                                       (dsh-protocol--objects
                                        (dsh-protocol--field 'chunks alist)))))))
  "One `job/follow' frame.
TYPE is `opened' (JOB projection + FROM, the offset the first `output'
frame continues from), `output' (CHUNKS + NEXT resume offset, LOSSY when
bytes between the requested offset and the chunks were already evicted) or
`status' (the settled JOB, after which the stream closes normally)."
  type
  job
  from
  next
  lossy
  chunks)

(defun dsh-protocol--struct (struct-alist-pred constructor value)
  "Return VALUE as a struct via CONSTRUCTOR if needed.
STRUCT-ALIST-PRED distinguishes an already-converted struct from a wire
alist; CONSTRUCTOR converts the wire alist."
  (if (funcall struct-alist-pred value)
      value
    (funcall constructor value)))

(provide 'dsh-emacs-protocol)

;;; dsh-emacs-protocol.el ends here
