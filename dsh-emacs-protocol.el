;;; dsh-emacs-protocol.el --- Typed views of dsh RPC payloads -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.7.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; dsh server responses are JSON-decoded alists (arrays are vectors).  This
;; file distills common responses and event payloads into cl-defstruct types.
;; Their `--from-alist' constructors own decoded fields; business code reads
;; those fields through accessors.  Opaque payloads stay with their existing
;; consumers until their own protocol views are introduced.
;; Outbound `*-request' encoders own the migrated endpoint arguments; RPC and
;; mux envelopes use `dsh-protocol-write-json' with fixed wire JSON settings.
;;
;; Structure overview (endpoint to protocol):
;;
;;   WebSocket mux → dsh-protocol-mux-frame (type stream-id value error)
;;   session/follow → dsh-protocol-follow-item (type payload)
;;                        └─ dsh-protocol-follow-snapshot (cursor records
;;                             has-more execution plan assistant projections)
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
;;   raw file upload  → dsh-protocol-file-receipt (receipt-id)
;;                        └─ dsh-protocol-file-ref (attachment-id name bytes)
;;   skills.list      → dsh-protocol-skill-list (skills)
;;                        └─ dsh-protocol-skill (name description when-to-use
;;                             model-invocable path)
;;   inbox projection → dsh-protocol-queue-item (id placement text kind)
;;   agent/inbox/spliced → dsh-protocol-inbox-splice (target start
;;                            removed-count outcome inserted)
;;   permissionPresets/catalog → dsh-protocol-permission-catalog (options)
;;                        └─ dsh-protocol-permission-option (value name
;;                             description)
;;   userQuestions projection → dsh-protocol-user-questions (active settled seq)
;;                        ├─ dsh-protocol-pending-question (call-id questions
;;                        │    state)
;;                        │    └─ dsh-protocol-question (see above)
;;                        └─ dsh-protocol-settled-question (call-id answers)
;;                             └─ dsh-protocol-question-answer (id selected
;;                                  custom)
;;   user-questions/request wait → dsh-protocol-question-wait (call-id timed)
;;   approval/request → dsh-protocol-approval-request (tool-name call-id
;;                       reason display-reasons)
;;
;; Conversion entry points accept a wire alist and normalize decoded arrays
;; to lists.  Opaque payloads retain their wire shape.  Once business code
;; caches a struct, it reads its decoded fields through `dsh-protocol-*'
;; accessors.

;;; Code:

(require 'cl-lib)
(require 'json)

(defun dsh-protocol-read-json (&optional string)
  "Decode wire JSON from STRING, or the current buffer at point.
Objects use symbol-keyed alists, arrays use vectors, null is nil and
false is `:json-false'.  Use native JSON support when available, with
the Lisp reader as a fallback for builds without it.  Errors propagate
to the transport boundary.  Input must already be decoded from UTF-8."
  (if (and (fboundp 'json-available-p) (json-available-p))
      (if string
          (json-parse-string string :object-type 'alist :array-type 'array
                             :null-object nil :false-object :json-false)
        (json-parse-buffer :object-type 'alist :array-type 'array
                           :null-object nil :false-object :json-false))
    (let ((json-object-type 'alist)
          (json-key-type 'symbol)
          (json-array-type 'vector)
          (json-null nil)
          (json-false :json-false))
      (if string (json-read-from-string string) (json-read)))))

(defun dsh-protocol-write-json (value)
  "Encode wire VALUE independently of user json.el settings.
Use nil for null, `:json-false' for false, t for true, alists or hash
tables for objects and vectors for arrays.  Retain json.el's list-array
support for opaque payloads such as question answers; native serialization
is not a drop-in replacement for those lists.  Errors propagate to callers."
  (let ((json-null nil)
        (json-false :json-false)
        (json-encoding-pretty-print nil)
        (json-encoding-separator ",")
        (json-encoding-object-sort-predicate nil))
    (json-encode value)))

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
  "Return KEY's value from ALIST (a list or vector of (KEY . VALUE) cells).
Accept both string and symbol keys because `json-read' normally produces
symbol-keyed alists while renderer call sites use JSON field names.  A
non-sequence ALIST (a number, symbol, or string where the wire promised an
object) yields nil rather than signalling: this accessor is the protocol's
wire boundary, and a malformed field must select a fallback, not break the
event stream."
  (when (or (listp alist) (vectorp alist))
    (let* ((alternate-key (cond
                           ((stringp key) (intern key))
                           ((symbolp key) (symbol-name key))
                           (t key)))
           (entry (if (listp alist)
                      (or (assoc key alist)
                          (assoc alternate-key alist))
                    (catch 'found
                      (dotimes (i (length alist))
                        (let ((pair (aref alist i)))
                          (when (and (consp pair)
                                     (or (equal (car pair) key)
                                         (equal (car pair) alternate-key)))
                            (throw 'found pair))))))))
      (and (consp entry) (cdr entry)))))

(defun dsh-protocol--boolean (value)
  "Return wire VALUE as a strict boolean, mapping JSON `false' to nil.
`json-read' decodes false as the truthy symbol `:json-false', so a flag must
be normalized where it crosses into a struct: otherwise an idle session
carries a truthy `running' value and every consumer that tests the field
directly (e.g. `dsh-emacs--busy-p') misreads it as running.  Every JSON
boolean field read by a `--from-alist' constructor passes through here, so a
struct never hands a caller `:json-false'."
  (and value (not (eq value :json-false))))

(defun dsh-protocol--tool-json (text)
  "Decode TEXT as one JSON object, or return nil.
Nil for a non-string, an empty document, or anything the protocol reader
rejects: callers decline instead of signalling on malformed tool data.
The reader owns the wire object shape, so dynamic JSON settings cannot
turn an object into a hash table here."
  (when (and (stringp text) (not (string-empty-p (string-trim text))))
    (let ((parsed (condition-case nil
                      (dsh-protocol-read-json (string-trim text))
                    (error nil))))
      (and (listp parsed) parsed))))

;; ---------------------------------------------------------------------------
;; WebSocket mux envelope
;; ---------------------------------------------------------------------------

(cl-defstruct (dsh-protocol-mux-frame
               (:constructor dsh-protocol-mux-frame--from-alist
                             (alist &aux
                                    (type (dsh-protocol--field 'type alist))
                                    (stream-id (dsh-protocol--field 'streamId alist))
                                    (value (dsh-protocol--field 'value alist))
                                    (error (dsh-protocol--field 'error alist)))))
  "Shared mux envelope; VALUE and ERROR retain their logical payloads."
  type stream-id value error)

;; ---------------------------------------------------------------------------
;; Durable session title and deliverables
;; ---------------------------------------------------------------------------

(cl-defstruct (dsh-protocol-session-title
               (:constructor dsh-protocol--make-session-title))
  "A session title event, including an explicitly absent TITLE."
  title)

(defun dsh-protocol-session-title--from-alist (event)
  "Decode a session/title EVENT, returning nil for other event types.
A matching event always produces a view, even when its title is nil."
  (when (equal (dsh-protocol--field 'type event) "session/title")
    (dsh-protocol--make-session-title
     :title (dsh-protocol--field 'title (dsh-protocol--field 'data event)))))

(cl-defstruct (dsh-protocol-deliverables
               (:constructor dsh-protocol-deliverables--from-alist
                             (event &aux
                                    (seq (dsh-protocol--field 'seq event))
                                    (data (dsh-protocol--field 'data event))
                                    (turn (dsh-protocol--field 'turn data))
                                    (files
                                     (cl-loop
                                      for file in (dsh-protocol--objects
                                                   (dsh-protocol--field 'files data))
                                      for path = (dsh-protocol--field 'path file)
                                      for description =
                                      (dsh-protocol--field 'description file)
                                      when (and (stringp path) (not (equal path "")))
                                      collect
                                      (cons path (and (stringp description)
                                                      (not (equal description ""))
                                                      description)))))))
  "Declared files for one turn, preserving wire order and duplicate paths.
FILES contains (PATH . DESCRIPTION) pairs with nonempty paths.  Empty or
non-string descriptions become nil; merging repeated declarations belongs
to the renderer.  SEQ advances replay even when no file is usable."
  seq turn files)

;; ---------------------------------------------------------------------------
;; Provider configuration (settings, llm directory and credentials)
;; ---------------------------------------------------------------------------

(cl-defstruct (dsh-protocol-provider-profile
               (:constructor dsh-protocol-provider-profile--from-alist
                             (alist &aux
                                    (endpoint (dsh-protocol--field 'baseURL alist))
                                    (key-ref (dsh-protocol--field 'apiKeyEnv alist)))))
  endpoint key-ref)

(cl-defstruct (dsh-protocol-provider-settings
               (:constructor dsh-protocol-provider-settings--from-alist
                             (alist &aux
                                    (name (dsh-protocol--field 'ns alist))
                                    (revision (dsh-protocol--field 'revision alist))
                                    (protocols
                                     (let* ((schema (dsh-protocol--field 'schema alist))
                                            (refs (dsh-protocol--field 'refs schema)))
                                       ;; Schemastery serializes children as numeric
                                       ;; references, not inline JSON Schema nodes.
                                       (cl-labels
                                           ((node (value)
                                              (if (numberp value)
                                                  (dsh-protocol--field
                                                   (number-to-string value) refs)
                                                value)))
                                         (let* ((root (if refs
                                                          (node (dsh-protocol--field
                                                                 'uid schema))
                                                        schema))
                                                (dict (dsh-protocol--field 'dict root))
                                                (providers (node (dsh-protocol--field
                                                                  'providers dict)))
                                                (profile (node (dsh-protocol--field
                                                                'inner providers)))
                                                (fields (dsh-protocol--field
                                                         'dict profile))
                                                (api (node (dsh-protocol--field
                                                            'api fields))))
                                           (delq nil
                                                 (mapcar
                                                  (lambda (entry)
                                                    (let ((value (dsh-protocol--field
                                                                  'value (node entry))))
                                                      (and (stringp value) value)))
                                                  (dsh-protocol--list
                                                   (dsh-protocol--field 'list api))))))))
                                    (profiles
                                     (mapcar
                                      (lambda (entry)
                                        (cons (if (symbolp (car entry))
                                                  (symbol-name (car entry))
                                                (car entry))
                                              (dsh-protocol-provider-profile--from-alist
                                               (cdr entry))))
                                      (dsh-protocol--field
                                       'providers (dsh-protocol--field 'value alist)))))))
  name revision protocols profiles)

(cl-defstruct (dsh-protocol-provider-settings-catalog
               (:constructor dsh-protocol-provider-settings-catalog--from-alist
                             (alist &aux
                                    (writable (dsh-protocol--boolean
                                               (dsh-protocol--field 'writable alist)))
                                    (sections
                                     (mapcar
                                      #'dsh-protocol-provider-settings--from-alist
                                      (dsh-protocol--objects
                                       (dsh-protocol--field 'namespaces alist)))))))
  writable sections)

(cl-defstruct (dsh-protocol-configurable-provider
               (:constructor dsh-protocol-configurable-provider--from-alist
                             (alist &aux
                                    (id (dsh-protocol--field 'provider alist))
                                    (namespace (dsh-protocol--field 'settingsNs alist))
                                    (path (dsh-protocol--list
                                           (dsh-protocol--field 'settingsPath alist)))
                                    (declared (dsh-protocol--boolean
                                               (dsh-protocol--field 'declared alist))))))
  id namespace path declared)

(cl-defstruct (dsh-protocol-provider-credential
               (:constructor dsh-protocol-provider-credential--from-alist
                             (alist ref &aux
                                    (info (dsh-protocol--field ref alist))
                                    (configured (dsh-protocol--boolean
                                                 (dsh-protocol--field 'configured info)))
                                    (writable (dsh-protocol--boolean
                                               (dsh-protocol--field 'writable info))))))
  configured writable)

(cl-defstruct (dsh-protocol-rpc-error
               (:constructor dsh-protocol-rpc-error--from-alist
                             (alist &aux
                                    (code (dsh-protocol--field 'code alist))
                                    (message (dsh-protocol--field 'message alist))
                                    (details (dsh-protocol--field 'details alist)))))
  code message details)

;; ---------------------------------------------------------------------------
;; session/list / workspace/follow baseline
;; ---------------------------------------------------------------------------

(cl-defstruct (dsh-protocol-context-pressure
               (:constructor dsh-protocol-context-pressure--from-alist
                             (alist &aux
                              (pressure (dsh-protocol--field 'pressureTokens alist))
                              (projected (dsh-protocol--field 'projectedTokens alist))
                              (window (dsh-protocol--field 'contextWindow alist)))))
  "The server's context occupancy sample, before display policy is applied.
Keep the raw PRESSURE, PROJECTED estimate and WINDOW together.  Consumers
decide whether the sample is usable and which estimate to display."
  pressure projected window)

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
                              (agent-available
                               (when (assq 'agentAvailable alist)
                                 (if (eq t (cdr (assq 'agentAvailable alist)))
                                     t :unavailable)))
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
                              ;; Decode the same occupancy sample as live
                              ;; projections; keep the existing session fields.
                              (context
                               (let* ((p (cdr (assq 'projections alist)))
                                      (v (and p (cdr (assq 'values p)))))
                                 (dsh-protocol-context-pressure--from-alist
                                  (and v (cdr (assq 'contextPressure v))))))
                              (context-pressure
                               (dsh-protocol-context-pressure-pressure context))
                              (context-window
                               (dsh-protocol-context-pressure-window context))
                              (context-projected
                               (dsh-protocol-context-pressure-projected context))
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
                                 (dsh-protocol-model-selection-projection--from-alist
                                  ms))))))
  "One `session/list' item."
  session-id
  title
  cwd
  agent-preset
  updated-at
  blank
  running
  agent-available
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
                                              (dsh-protocol--field 'items alist))))
                              (archived-session-ids
                               (dsh-protocol--list
                                (dsh-protocol--field 'archivedSessionIds alist))))))
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
                              (provider (dsh-protocol--field "provider" alist))
                              (model (dsh-protocol--field "model" alist))
                              (reasoning-effort
                               (dsh-protocol--field "reasoningEffort" alist)))))
  "The session's live model selection (`current' / `selected')."
  provider
  model
  reasoning-effort)

(defun dsh-protocol-model-selection-projection--from-alist (value)
  "Decode the last-used model from modelSelection projection VALUE.
The next selection is a future request choice, not the model last used."
  (when-let* ((selection (dsh-protocol--field 'lastUsed value)))
    (dsh-protocol-model-selection--from-alist selection)))

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
`name' is present only when the preset declaration publishes one; the
shipped presets do not, so callers fall back to `id' for display.  There is
no `trust' field (dsh 0.1.7 dropped it)."
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

(cl-defstruct (dsh-protocol-command-event
               (:constructor dsh-protocol-command-event--from-alist
                             (event &aux
                                    (type (dsh-protocol--field 'type event))
                                    (data (dsh-protocol--field 'data event))
                                    (command-id (dsh-protocol--field 'commandId data))
                                    (name (dsh-protocol--field 'name data))
                                    (kind (dsh-protocol--field 'kind data))
                                    (text (dsh-protocol--field 'text data)))))
  "Fields consumed by command/run and command/done rendering.
NAME labels a run; KIND and TEXT describe its result.  The event sequence
stays in the envelope, so hidden or unmatched events can still be consumed."
  type command-id name kind text)

;; ---------------------------------------------------------------------------
;; Prompt attachments (durable file refs and the upload receipt)
;; ---------------------------------------------------------------------------
;; A composed file attachment is uploaded to the host before the prompt
;; (raw-byte route, rpc.md §4.17), which answers with the one-time receipt
;; that is submitted back inside one `session/prompt' content part.  Once the
;; prompt is admitted the receipt is replaced by the durable file reference
;; carried on the `user/message' content block (`{type:'file', attachment}').

(cl-defstruct (dsh-protocol-file-ref
               (:constructor dsh-protocol-file-ref--from-alist
                             (alist
                              &aux
                              (attachment-id (cdr (assq 'attachmentId alist)))
                              (name (cdr (assq 'name alist)))
                              (bytes (cdr (assq 'bytes alist))))))
  "A durable stored file: ATTACHMENT-ID is an opaque content-addressed
identifier (never a path), NAME the sanitized leaf name, BYTES the exact
byte length."
  attachment-id
  name
  bytes)

(cl-defstruct (dsh-protocol-file-receipt
               (:constructor dsh-protocol-file-receipt--from-alist
                             (alist
                              &aux
                              (receipt-id (cdr (assq 'receiptId alist)))
                              (file (let ((file (cdr (assq 'file alist))))
                                      (and file
                                           (dsh-protocol-file-ref--from-alist
                                            file)))))))
  "The upload route's value: RECEIPT-ID is the one-time authority that
travels back inside exactly one prompt's content (valid only in the
session it was uploaded for), FILE the durable stored reference."
  receipt-id
  file)

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

(defun dsh-protocol-permission-value--from-alist (alist)
  "Decode the current permission preset from projection ALIST.
Return a nonempty string, or nil for absent, empty or non-string values.
Preset names are host-defined; this does not validate them against a catalog."
  (let ((value (dsh-protocol--field 'currentValue alist)))
    (and (stringp value) (not (equal value "")) value)))

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
                              (intent-kind
                               (cdr (assq 'kind (cdr (assq 'intent alist)))))
                              (approve-label
                               (cdr (assq 'approve (cdr (assq 'intent alist)))))
                              (call-id
                               (cdr (assq 'callId (cdr (assq 'intent alist)))))
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
  intent-kind
  approve-label
  call-id
  options
  multi-select)

(cl-defstruct (dsh-protocol-plan-document
               (:constructor dsh-protocol-plan-document--from-alist
                             (value &key json-p &aux
                                    (alist (if json-p
                                               (dsh-protocol-read-json value)
                                             value))
                                    (text (dsh-protocol--field 'plan alist)))))
  "The complete Markdown submitted by `exit_plan_mode'."
  text)

(cl-defstruct (dsh-protocol-tool-call
               (:constructor dsh-protocol-tool-call--from-alist
                             (data &key event-p &aux
                                   (data (if event-p (dsh-protocol--field "data" data) data))
                                   (name (dsh-protocol--field 'name data))
                                   (call-id (dsh-protocol--field 'callId data))
                                   (arguments (dsh-protocol--field 'arguments data)))))
  "The data payload of a tool/call event.
ARGUMENTS retains the original JSON string; individual tool variants own its
interpretation.  Sequence and time stay in the surrounding event envelope."
  name call-id arguments)

(cl-defstruct (dsh-protocol-tool-result
               (:constructor dsh-protocol--make-tool-result)
               (:constructor dsh-protocol-tool-result--from-alist
                             (alist &key event-p
                                    &aux
                                    (alist (if event-p (dsh-protocol--field "data" alist) alist))
                                    (message (dsh-protocol--field 'message alist))
                                    (content (dsh-protocol--objects
                                              (dsh-protocol--field 'content message)))
                                    (nested
                                     (cl-remove-if-not
                                      (lambda (block)
                                        (equal (dsh-protocol--field 'type block)
                                               "tool-result"))
                                      content))
                                    (outcome (if nested (car (last nested)) message))
                                    (blocks
                                     (if nested
                                         (cl-loop for block in nested append
                                                  (dsh-protocol--objects
                                                   (dsh-protocol--field 'content block)))
                                       content))
                                    (failure (dsh-protocol--field 'error alist))
                                    (call-id
                                     (or (dsh-protocol--field 'toolCallId message)
                                         (dsh-protocol--field 'callId message)
                                         (dsh-protocol--field
                                          'callId (dsh-protocol--field 'source message))
                                         (dsh-protocol--field 'callId alist)))
                                    (text
                                     (mapconcat
                                      #'identity
                                      (cl-loop for block in blocks
                                               for text = (dsh-protocol--field 'text block)
                                               when (and (equal "text" (dsh-protocol--field
                                                                        'type block))
                                                         (stringp text))
                                               collect text)
                                      "\n"))
                                    (is-error (dsh-protocol--boolean
                                               (dsh-protocol--field 'isError outcome)))
                                    (exit-code (dsh-protocol--field 'exitCode outcome))
                                    (signal (dsh-protocol--field 'signal outcome))
                                    (error-code (dsh-protocol--field 'code failure))
                                    (error-reason (dsh-protocol--field 'reason failure))
                                    (meta (dsh-protocol--field 'meta alist)))))
  "Decoded tool/result data, including its message's text and outcome.
Current hosts use direct text blocks and message-level isError; older
hosts and fixtures wrap both in a tool-result content block."
  call-id text is-error exit-code signal error-code error-reason meta)

(cl-defstruct (dsh-protocol-approval-request
               (:constructor dsh-protocol-approval-request--from-alist
                             (alist
                              &aux
                              (tool-name (dsh-protocol--field 'toolName alist))
                              (call-id (dsh-protocol--field 'callId alist))
                              (reason (dsh-protocol--field 'reason alist))
                              (display-reasons
                               (cl-loop
                                for (locale . text) in
                                (dsh-protocol--objects
                                 (dsh-protocol--field 'displayReason alist))
                                when (and (or (stringp locale) (symbolp locale))
                                          (stringp text)
                                          (string-match-p "[^ \t\r\n]" text))
                                collect
                                (cons (downcase
                                       (replace-regexp-in-string
                                        "_" "-" (format "%s" locale)))
                                      text))))))
  "An approval request with raw REASON and localized DISPLAY-REASONS.
DISPLAY-REASONS maps lowercase, hyphenated language tags to nonblank text;
the UI selects a translation without changing the host's audit reason."
  tool-name call-id reason display-reasons)

;; ---------------------------------------------------------------------------
;; userQuestions projection + timed-question wait (dsh 0.2.0)
;; ---------------------------------------------------------------------------
;; dsh 0.2.0 added a timed `ask_user_question' tool: a question the user does
;; not answer inside the foreground window stays answerable, and the host
;; publishes that state as the `userQuestions' session projection.  The
;; waterfall request then carries an optional `wait' naming the tool call, and
;; a late answer goes through the `userQuestions/answer' Remote whose value is
;; the same answer batch the in-time `$events/result' outcome carries.

(cl-defstruct (dsh-protocol-question-wait
               (:constructor dsh-protocol-question-wait--from-alist
                             (alist
                              &aux
                              (call-id (dsh-protocol--field 'callId alist))
                              (timed (dsh-protocol--boolean
                                      (dsh-protocol--field 'timed alist))))))
  "The optional `wait' of a `user-questions/request': the tool CALL-ID the
answer UI may claim on `userQuestions/attachWait', and whether that wait is
TIMED (an expiring foreground window) rather than indefinite."
  call-id
  timed)

(cl-defstruct (dsh-protocol-question-request
               (:constructor dsh-protocol-question-request--from-alist
                             (request &aux
                                      (questions
                                       (dsh-protocol--list
                                        (dsh-protocol--field 'questions request)))
                                      (wait
                                       (let ((raw (dsh-protocol--field
                                                   'wait request)))
                                         (and (consp raw)
                                              (dsh-protocol-question-wait--from-alist
                                               raw)))))))
  "A routed question batch and optional decoded timed WAIT.
Question objects stay raw until their existing Plan/reader boundaries, so
decoding this envelope does not change per-question validation order."
  questions wait)

(cl-defstruct (dsh-protocol-question-answer
               (:constructor dsh-protocol-question-answer--from-alist
                             (alist
                              &aux
                              (id (dsh-protocol--field 'id alist))
                              (selected (dsh-protocol--list
                                         (dsh-protocol--field 'selected alist)))
                              (custom (dsh-protocol--field 'custom alist)))))
  "One answer of a settled question batch: question ID, the SELECTED option
labels (empty when the question was skipped or answered with free text), and
the optional free-text CUSTOM."
  id
  selected
  custom)

(cl-defstruct (dsh-protocol-pending-question
               (:constructor dsh-protocol-pending-question--from-alist
                             (alist
                              &aux
                              (call-id (dsh-protocol--field 'callId alist))
                              (questions (mapcar
                                          #'dsh-protocol-question--from-alist
                                          (dsh-protocol--objects
                                           (dsh-protocol--field
                                            'questions alist))))
                              (state (pcase (dsh-protocol--field 'state alist)
                                       ("open" 'open)
                                       ("continued" 'continued)
                                       (_ nil))))))
  "One timed `ask_user_question' call of the `userQuestions' projection:
CALL-ID, its QUESTIONS, and STATE (`open' while the foreground window runs,
`continued' once only a later answer can settle it)."
  call-id
  questions
  state)

(cl-defstruct (dsh-protocol-settled-question
               (:constructor dsh-protocol-settled-question--from-alist
                             (alist
                              &aux
                              (call-id (dsh-protocol--field 'callId alist))
                              (answers (mapcar
                                        #'dsh-protocol-question-answer--from-alist
                                        (dsh-protocol--objects
                                         (dsh-protocol--field
                                          'answers alist)))))))
  "One settled timed call of the `userQuestions' projection: CALL-ID and the
answer batch it settled with (empty when the late reply carried none)."
  call-id
  answers)

(cl-defstruct (dsh-protocol-user-questions
               (:constructor dsh-protocol-user-questions--from-alist
                             (alist &optional seq
                                    &aux
                                    (active (mapcar
                                             #'dsh-protocol-pending-question--from-alist
                                             (dsh-protocol--objects
                                              (dsh-protocol--field 'active alist))))
                                    (settled (mapcar
                                              #'dsh-protocol-settled-question--from-alist
                                              (dsh-protocol--objects
                                               (dsh-protocol--field
                                                'settled alist)))))))
  "The `userQuestions' projection value: ACTIVE questions still answerable
(open or continued) and SETTLED ones, in ask and settlement order.  A session
that only ever used the blocking legacy tool folds to two empty lists.
SEQ is the projection's watermark, including when the capability is absent."
  active
  settled
  seq)

(defun dsh-protocol-user-questions-baseline--from-alist (baseline)
  "Decode question state or capability absence at BASELINE's watermark."
  (dsh-protocol-user-questions--from-alist
   (dsh-protocol--field 'userQuestions (dsh-protocol--field 'values baseline))
   (dsh-protocol--field 'asOfSeq baseline)))

(defun dsh-protocol-question-answers-json (answers)
  "Serialize ANSWERS as the host's answer document.
ANSWERS is a list of `dsh-protocol-question-answer' structs.  The result is
the same `{\"answers\": [...]}' text a settled `ask_user_question' result
carries, so a caller can replay a late answer through the ordinary result
renderer; the wire field names stay in this module."
  (json-encode
   `((answers
      . ,(mapcar (lambda (answer)
                   (let ((custom (dsh-protocol-question-answer-custom answer)))
                     `((id . ,(dsh-protocol-question-answer-id answer))
                       (selected
                        . ,(vconcat (dsh-protocol-question-answer-selected answer)))
                       ,@(and custom `((custom . ,custom))))))
                 answers)))))

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
                                 (and s (cdr (assq 'kind s)))))
                              (text-only
                               (cl-every
                                (lambda (block)
                                  (equal "text" (cdr (assq 'type block))))
                                (dsh-protocol--list
                                 (cdr (assq 'content message))))))))
  "One pending-inbox item: PLACEMENT is `queued' (next turn), `steering'
(next-step user input) or `context' (host-injected next-step content);
TEXT the message's text blocks concatenated, KIND the message's source
kind (`user' for real user input); TEXT-ONLY whether every content block is
text, so a client edit (which sends text blocks back) cannot flatten an
image or file attachment."
  id
  placement
  text
  kind
  text-only)

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
           (dsh-protocol--objects
            (and (listp value) (cdr (assq 'next-turn value)))))
   (mapcar (lambda (message)
             (dsh-protocol-queue-item--from-message
              message
              (let ((source (cdr (assq 'source message))))
                (if (equal "user" (and source (cdr (assq 'kind source))))
                    'steering
                  'context))))
           (dsh-protocol--objects
            (and (listp value) (cdr (assq 'next-step value)))))))

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

(defun dsh-protocol--goal-blocked-message (value)
  "Human message of a wire `blockedReason' VALUE, or nil.
The record is `{code, message}'; a bare string is accepted for legacy
fixtures.  The code is machine-routable and has no client consumer, so only
the message is carried."
  (cond ((stringp value) value)
        ((and (listp value) (stringp (alist-get 'message value)))
         (alist-get 'message value))))

(cl-defstruct (dsh-protocol-goal
               (:constructor dsh-protocol-goal--from-alist
                             (value &aux
                                    (id (alist-get 'id value))
                                    (revision (alist-get 'revision value))
                                    (objective (alist-get 'objective value))
                                    (phase (alist-get 'phase value))
                                    (blocked-reason
                                     (dsh-protocol--goal-blocked-message
                                      (alist-get 'blockedReason value)))
                                    (max-goal-rounds (alist-get 'maxGoalRounds value)))))
  "A goal core from a projection or mutation response.
BLOCKED-REASON is the human message of the wire `{code, message}' record
\(see `dsh-protocol--goal-blocked-message'); ACTIVATION is the process-local
continuation state a goal-tool result carries beside the goal, and is nil in
the session projection (activation is never persisted)."
  id revision objective phase blocked-reason max-goal-rounds rounds-started
  activation)

(defun dsh-protocol-goal-tool--from-alist (value)
  "Decode a goal tool result VALUE into a `dsh-protocol-goal', or nil.
`create_goal' / `get_goal' / `update_goal' answer with the GoalView core in
`goal' — `{id, revision, objective, phase, roundsStarted, maxGoalRounds,
blockedReason?}' — plus the process-local `activation' beside it (see
dsh-tool-goal).  A document without a usable `goal' object (an absent or
malformed cell, or the cleared `{goal: null}' answer) yields nil."
  (when-let* ((core (and (listp value) (alist-get 'goal value)))
              ((listp core))
              (goal (dsh-protocol-goal--from-alist core)))
    (setf (dsh-protocol-goal-rounds-started goal)
          (alist-get 'roundsStarted core)
          (dsh-protocol-goal-activation goal)
          (alist-get 'activation value))
    goal))

(defun dsh-protocol-goal-projection--from-alist (value)
  "Decode goal projection VALUE, including its progress, or nil."
  (when-let* ((core (and (listp value) (alist-get 'goal value)))
              (goal (dsh-protocol-goal--from-alist core)))
    (setf (dsh-protocol-goal-rounds-started goal)
          (alist-get 'roundsStarted value))
    goal))

;; Plan mode is persistent collaboration state, separate from Todo items.
(cl-defstruct (dsh-protocol-plan
               (:constructor dsh-protocol--make-plan))
  "The host's committed Plan mode and whether an opposite selection is pending."
  active pending available seq)

(defun dsh-protocol-plan--from-alist (value &optional seq)
  "Decode a `plan' projection VALUE at SEQ, retaining capability absence."
  (dsh-protocol--make-plan
   :active (dsh-protocol--boolean (dsh-protocol--field 'active value))
   :pending (dsh-protocol--boolean (dsh-protocol--field 'pending value))
   :available (consp value) :seq seq))

(defun dsh-protocol-plan-baseline--from-alist (baseline)
  "Decode Plan mode or capability absence at projection BASELINE's watermark."
  (dsh-protocol-plan--from-alist
   (dsh-protocol--field 'plan (dsh-protocol--field 'values baseline))
   (dsh-protocol--field 'asOfSeq baseline)))

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

;; Generated compaction summaries are distinct from completion boundaries.

(cl-defstruct (dsh-protocol-compaction-summary
               (:constructor dsh-protocol--make-compaction-summary))
  "Generated compaction text and the context it summarizes.
TOKEN-COUNT is the estimated size of the replaced context, not savings."
  seq id command-id text item-count token-count)

(defun dsh-protocol-compaction-summary--from-alist (event)
  "Decode a `compaction/summary' EVENT, or nil for other event types.
Only summary text blocks are exposed; provider output and reasoning stay
private.  Missing or invalid counts remain nil; an empty wire array is zero."
  (when (equal (dsh-protocol--field 'type event) "compaction/summary")
    (let* ((data (dsh-protocol--field 'data event))
           (seqs (dsh-protocol--field 'shadowedSeqs data))
           (tokens (dsh-protocol--field 'shadowedTokenCount data)))
      (dsh-protocol--make-compaction-summary
       :seq (dsh-protocol--field 'seq event)
       :id (dsh-protocol--field 'compactionId data)
       :command-id (dsh-protocol--field 'sourceCommandId data)
       :text (mapconcat
              #'identity
              (cl-loop for block in (dsh-protocol--objects
                                    (dsh-protocol--field 'summary data))
                       for text = (dsh-protocol--field 'text block)
                       when (and (equal (dsh-protocol--field 'type block) "text")
                                 (stringp text))
                       collect text)
              "")
       :item-count (when (and (or (vectorp seqs) (consp seqs))
                              (cl-every #'natnump seqs))
                     (length seqs))
       :token-count (when (natnump tokens) tokens)))))

;; Execution feedback: durable retry/compaction facts and their boundaries.

(cl-defstruct (dsh-protocol-execution-event
               (:constructor dsh-protocol--make-execution-event))
  "A retry, compaction or execution boundary consumed by the status UI."
  type seq turn step id attempt limit delay provider code message command-id reason)

(defun dsh-protocol-execution-event--from-alist (event)
  "Decode execution feedback from wire EVENT, or nil for unrelated events."
  (let ((type (dsh-protocol--field 'type event)))
    (when (member type '("llm/retry" "llm/retry-started"
                         "compaction/start" "compaction/end"
                         "turn/end"
                         "assistant/message" "assistant/attempt"))
      (let* ((data (dsh-protocol--field 'data event))
             (reason (dsh-protocol--field 'reason data))
             (failure (or (dsh-protocol--field 'failure data)
                          (dsh-protocol--field 'error reason))))
        (dsh-protocol--make-execution-event
         :reason (dsh-protocol--field 'kind reason)
         :type type :seq (dsh-protocol--field 'seq event)
         :turn (dsh-protocol--field 'turn data)
         :step (dsh-protocol--field 'step data)
         :id (or (dsh-protocol--field 'retryId data)
                 (dsh-protocol--field 'compactionId data))
         :attempt (dsh-protocol--field 'retry data)
         :limit (dsh-protocol--field 'maxRetries data)
         :delay (dsh-protocol--field 'delayMs data)
         :provider (dsh-protocol--field 'provider data)
         :code (dsh-protocol--field 'code failure)
         :message (or (dsh-protocol--field 'message failure)
                      (dsh-protocol--field 'error data))
         :command-id (dsh-protocol--field 'sourceCommandId data))))))

;;; ---------------------------------------------------------------------------
;;; History round classification
;;; ---------------------------------------------------------------------------

(defun dsh-protocol--event-user-authored-p (event)
  "Whether the `user/message' EVENT is author text.
A source-less message is author text for legacy fixtures and optimistic
echoes; every recorded non-`user' source (child, goal, context, plugin) is
not."
  (let* ((data (dsh-protocol--field 'data event))
         (source (dsh-protocol--field 'source data))
         (kind (dsh-protocol--field 'kind source)))
    (or (null kind) (equal kind "user"))))

(defun dsh-protocol-history-human-rounds (records)
  "Return (TURN SEQ RECORD) for human rounds in RECORDS, oldest first.
RECORDS is an accumulated `session/page' history list, oldest first.  A human
round is a turn containing a user-authored `user/message'; child, goal and
other host wakes are not rounds by this definition.  The turn's own
`turn/start' record supplies SEQ and RECORD.  Scanning the accumulated list
(not one page) keeps a message-aligned page boundary from splitting a turn's
start from its user message."
  (let (rounds current)
    (dolist (record records)
      (let* ((event (dsh-protocol--field 'event record))
             (type (dsh-protocol--field 'type event))
             (data (dsh-protocol--field 'data event)))
        (when (equal type "turn/start")
          (when (and current (nth 3 current))
            (push current rounds))
          (let ((turn (dsh-protocol--field 'turn data)))
            (setq current
                  (and (natnump turn)
                       (list turn (dsh-protocol--field 'seq event)
                             record nil)))))
        (when (and current
                   (equal type "user/message")
                   (dsh-protocol--event-user-authored-p event))
          (setf (nth 3 current) t))))
    (when (and current (nth 3 current))
      (push current rounds))
    (mapcar (lambda (round)
              (list (nth 0 round) (nth 1 round) (nth 2 round)))
            (nreverse rounds))))

(cl-defstruct (dsh-protocol-follow-snapshot
               (:constructor dsh-protocol-follow-snapshot--from-alist
                             (value &aux
                              (cursor (dsh-protocol--field 'cursor value))
                              (raw-records (dsh-protocol--objects
                                            (dsh-protocol--field 'records value)))
                              (records
                               (cl-remove-if-not
                                (lambda (record)
                                  (equal (dsh-protocol--field 'type record) "event"))
                                raw-records))
                              (has-more (dsh-protocol--boolean
                                         (dsh-protocol--field 'hasMore value)))
                              (human-round-count
                               (length (dsh-protocol-history-human-rounds
                                        records)))
                              (execution
                               (delq nil
                                     (mapcar
                                      (lambda (record)
                                        (dsh-protocol-execution-event--from-alist
                                         (dsh-protocol--field 'event record)))
                                      raw-records)))
                              (projections (dsh-protocol--field 'projections value))
                              (plan (dsh-protocol-plan-baseline--from-alist
                                     projections))
                              (assistant
                               (dsh-protocol-assistant-baseline--from-alist
                                (dsh-protocol--field 'assistantStream value))))))
  "A follow stream's opening transcript and presentation baseline.
RECORDS retain raw durable event records in wire order for the renderer;
unlike a backward history page, this view imposes no sequence validation.
HUMAN-ROUND-COUNT counts turns in RECORDS with a user-authored message,
including an active human round.
EXECUTION covers the whole window, including events below the render anchor.
PLAN is applied before history can yield; PROJECTIONS stay raw until their
late decoding boundary.  An absent ASSISTANT is an empty baseline."
  cursor records has-more human-round-count execution plan assistant projections)

(cl-defstruct (dsh-protocol-follow-item
               (:constructor dsh-protocol-follow-item--from-alist
                             (value &aux
                              (type (dsh-protocol--field 'type value))
                              (payload
                               (pcase type
                                 ("snapshot"
                                  (dsh-protocol-follow-snapshot--from-alist value))
                                 ("event" (dsh-protocol--field 'event value))
                                 ("assistant-stream"
                                  (dsh-protocol-assistant-frame--from-alist
                                   (dsh-protocol--field 'frame value))))))))
  "One logical follow item, with a payload selected by TYPE.
Snapshot and assistant-stream payloads are decoded views; a durable event
stays raw for its event-specific consumers.  Unknown types have no payload."
  type payload)

;; Turn footer facts are independent of the cumulative session projections.
(cl-defstruct (dsh-protocol-reply-event
               (:constructor dsh-protocol--make-reply-event))
  type seq turn time text usage reason answer-p tool-name call-id)

(defun dsh-protocol-reply-event--from-alist (event)
  "Decode turn, step, tool-call or assistant facts from wire EVENT.
USAGE is a normalized plist, or nil when no token counts were reported.
ANSWER-P marks assistant prose without tool calls, not turn completion.
Synthetic fork endings have no usable elapsed-time endpoint."
  (let ((type (dsh-protocol--field 'type event)))
    (when (member type '("turn/start" "turn/end" "step/start" "tool/call"
                         "assistant/message" "assistant/attempt"))
      (let* ((data (dsh-protocol--field 'data event))
             (reason (dsh-protocol--field
                      'kind (dsh-protocol--field 'reason data)))
             (raw (dsh-protocol--field 'usage data))
             (counts (mapcar (lambda (key) (dsh-protocol--field key raw))
                             '(inputTokens outputTokens cacheReadTokens
                                           cacheWriteTokens)))
             (content (dsh-protocol--objects
                       (dsh-protocol--field
                        'content (dsh-protocol--field 'message data))))
             (text (mapconcat
                    (lambda (block) (or (dsh-protocol--field 'text block) ""))
                    (cl-remove-if-not
                     (lambda (block)
                       (equal (dsh-protocol--field 'type block) "text"))
                     content) "\n")))
        (dsh-protocol--make-reply-event
         :type type :seq (dsh-protocol--field 'seq event)
         :turn (dsh-protocol--field 'turn data)
         :tool-name (and (equal type "tool/call")
                         (dsh-protocol--field 'name data))
         :call-id (and (equal type "tool/call")
                       (dsh-protocol--field 'callId data))
         :reason (and (equal type "turn/end") reason)
         :time (unless (equal reason "forked")
                 (dsh-protocol--field 'time event))
         :text text
         :answer-p (and (equal type "assistant/message")
                        (not (string-blank-p text))
                        (not (cl-some
                              (lambda (block)
                                (equal (dsh-protocol--field 'type block)
                                       "tool-call"))
                              content)))
         :usage (when (cl-some #'numberp counts)
                  (cl-loop for key in '(:input :output :cache-read :cache-write)
                           for count in counts
                           append (list key (if (numberp count) count 0)))))))))

;;; Subagent wire boundaries.
(cl-defstruct (dsh-protocol-subagent-address
               (:constructor dsh-protocol-subagent-address-create
                             (parent child mode)))
  parent child mode)

(cl-defstruct (dsh-protocol-subagent-entry
               (:constructor dsh-protocol-subagent-entry--from-alist
                             (alist &aux
                                    (id (cdr (assq 'id alist)))
                                    (mode (or (cdr (assq 'mode alist)) "unknown"))
                                    (label (cdr (assq 'label alist)))
                                    (created-at (cdr (assq 'createdAt alist))))))
  id mode label created-at)

(cl-defstruct (dsh-protocol-subagent-identity
               (:constructor dsh-protocol-subagent-identity--from-alist
                             (alist &aux
                                    (mode (cdr (assq 'mode alist)))
                                    (label (cdr (assq 'label alist)))
                                    (seq (cdr (assq 'seq alist))))))
  mode label seq)

(cl-defstruct (dsh-protocol-subagent-timing
               (:constructor dsh-protocol-subagent-timing--from-alist
                             (alist &aux
                                    (settled-ms (or (cdr (assq 'settledMs alist)) 0))
                                    (active-since (cdr (assq 'since (cdr (assq 'active alist)))))
                                    (active-through (cdr (assq 'through (cdr (assq 'active alist)))))
                                    (completed (eq t (cdr (assq 'lastTurnCompleted alist)))))))
  settled-ms active-since active-through completed)

(cl-defstruct (dsh-protocol-token-usage
               (:constructor dsh-protocol-token-usage--from-alist
                             (alist &aux
                                    (input (or (cdr (assq 'uncachedInputTokens alist)) 0))
                                    (output (or (cdr (assq 'outputTokens alist)) 0))
                                    (cache-read (or (cdr (assq 'cacheReadTokens alist)) 0))
                                    (cache-write (or (cdr (assq 'cacheWriteTokens alist)) 0)))))
  input output cache-read cache-write)

(cl-defstruct (dsh-protocol-subagent-cell
               (:constructor dsh-protocol-subagent-cell--from-alist
                             (alist &aux
                                    (key (intern (format "%s" (cdr (assq 'key alist)))))
                                    (seq (or (cdr (assq 'seq alist)) -1))
                                    (present (if (assq 'present alist)
                                                 (cdr (assq 'present alist)) t))
                                    (value
                                     (let ((raw (cdr (assq 'value alist))))
                                       (pcase key
                                         ('subagentCatalog
                                          (mapcar #'dsh-protocol-subagent-entry--from-alist
                                                  (dsh-protocol--list raw)))
                                         ('subagent (and raw (dsh-protocol-subagent-identity--from-alist raw)))
                                         ('subagentTiming (and raw (dsh-protocol-subagent-timing--from-alist raw)))
                                         ('tokenUsage (and raw (dsh-protocol-token-usage--from-alist raw)))))))))
  key seq present value)

(define-error 'dsh-protocol-migration-required
  "Session requires migration; open its conversation first" 'user-error)

(defun dsh-protocol-subagent-baseline--from-alist (alist)
  "Decode ALIST into sequenced cells, retaining absence watermarks.
Signal `dsh-protocol-migration-required' for sequence-free cached hints."
  (when (equal (cdr (assq 'kind alist)) "migration-required")
    (signal 'dsh-protocol-migration-required nil))
  (let ((values (cdr (assq 'values alist)))
        (seq (or (cdr (assq 'asOfSeq alist)) -1)))
    (mapcar
     (lambda (key)
       (let ((entry (assq key values)))
         (dsh-protocol-subagent-cell--from-alist
          `((key . ,key) (seq . ,seq) (present . ,(and entry t))
            (value . ,(cdr entry))))))
     '(subagentCatalog subagent subagentTiming tokenUsage))))

;;; Follow snapshot projections.
(cl-defstruct (dsh-protocol-follow-projections
               (:constructor dsh-protocol--make-follow-projections))
  "Decoded projections applied after a follow snapshot's history and prefix.
SUBAGENTS is one complete batch.  GOAL-UPDATE-P distinguishes a missing/null
goal, which clears the row, from a non-object value, which leaves it alone.
QUESTIONS is a decoded state including its watermark, or nil to skip it.
Plan is applied earlier; inbox and unknown projections have no follow consumer."
  subagents title context permission goal goal-update-p questions model-selection)

(defun dsh-protocol-follow-projections--from-alist (baseline)
  "Decode the late projections in a follow BASELINE.
Keep this separate from the opening snapshot decoder: migration failures
must surface after history and the assistant prefix have been applied."
  (let* ((subagents (dsh-protocol-subagent-baseline--from-alist baseline))
         (values (dsh-protocol--field 'values baseline))
         (apply-values (listp values))
         (raw-goal (dsh-protocol--field 'goal values))
         (goal-update-p (and apply-values (listp raw-goal))))
    (dsh-protocol--make-follow-projections
     :subagents subagents
     :title (and apply-values (dsh-protocol--field 'title values))
     :context (and apply-values
                   (dsh-protocol-context-pressure--from-alist
                    (dsh-protocol--field 'contextPressure values)))
     :permission (and apply-values
                      (dsh-protocol-permission-value--from-alist
                       (dsh-protocol--field 'permissions values)))
     :model-selection (and apply-values
                           (dsh-protocol-model-selection-projection--from-alist
                            (dsh-protocol--field 'modelSelection values)))
     :goal (and goal-update-p
                (dsh-protocol-goal-projection--from-alist raw-goal))
     :goal-update-p goal-update-p
     :questions (and apply-values
                     (dsh-protocol-user-questions-baseline--from-alist
                      baseline)))))

;;; Core control projections.
(cl-defstruct (dsh-protocol-projection
               (:constructor dsh-protocol--make-projection))
  "One session projection: a string KEY and its decoded VALUE.
Known values are protocol structs, queue-item lists or scalar values;
unknown values retain their wire identity for forward-compatible routing."
  session-id key value)

(defun dsh-protocol-projection-value--from-alist (key value &optional seq)
  "Decode projection VALUE for string KEY at SEQ.
Subagent cells need the enclosing update frame and are decoded separately."
  (pcase key
    ("contextPressure" (dsh-protocol-context-pressure--from-alist value))
    ("permissions" (dsh-protocol-permission-value--from-alist value))
    ("modelSelection" (dsh-protocol-model-selection-projection--from-alist value))
    ("goal" (dsh-protocol-goal-projection--from-alist value))
    ("inbox" (dsh-protocol-queue-items-from-inbox value))
    ("plan" (dsh-protocol-plan--from-alist value seq))
    ("userQuestions" (dsh-protocol-user-questions--from-alist value seq))
    (_ value)))

(defun dsh-protocol-projection--from-alist (frame)
  "Decode one control projection FRAME, preserving its sequence metadata."
  (let* ((raw-key (dsh-protocol--field 'key frame))
         (key (if (symbolp raw-key) (symbol-name raw-key) raw-key)))
    (dsh-protocol--make-projection
     :session-id (dsh-protocol--field 'sessionId frame)
     :key key
     :value
     (if (member key '("subagentCatalog" "subagent"
                       "subagentTiming" "tokenUsage"))
         (dsh-protocol-subagent-cell--from-alist frame)
       (dsh-protocol-projection-value--from-alist
        key (dsh-protocol--field 'value frame)
        (dsh-protocol--field 'seq frame))))))

(cl-defstruct (dsh-protocol-control-session
               (:constructor dsh-protocol--make-control-session))
  "One decoded session in a control baseline.
SUBAGENTS is a complete four-cell batch.  PROJECTIONS starts with Plan and
questions, including absence watermarks, then keeps other cells in wire order.
For goal/inbox, missing keys stay missing and explicit nil values clear."
  session-id subagents projections)

(defun dsh-protocol-control-session--from-alist (entry)
  "Decode one (SESSION-ID . BASELINE) ENTRY from a control baseline."
  (let* ((id (car entry))
         (session-id (if (symbolp id) (symbol-name id) id))
         (baseline (cdr entry))
         (subagents (dsh-protocol-subagent-baseline--from-alist baseline)))
    (dsh-protocol--make-control-session
     :session-id session-id
     :subagents subagents
     :projections
     (append
      (list (dsh-protocol--make-projection
             :session-id session-id :key "plan"
             :value (dsh-protocol-plan-baseline--from-alist baseline))
            (dsh-protocol--make-projection
             :session-id session-id :key "userQuestions"
             :value (dsh-protocol-user-questions-baseline--from-alist baseline)))
      (cl-loop
       for cell in (dsh-protocol--list (dsh-protocol--field 'values baseline))
       for raw-key = (car-safe cell)
       for key = (if (symbolp raw-key) (symbol-name raw-key) raw-key)
       when (and (consp cell)
                 (not (member key '("plan" "userQuestions" "subagentCatalog"
                                    "subagent" "subagentTiming" "tokenUsage"))))
       collect (dsh-protocol--make-projection
                :session-id session-id :key key
                :value (dsh-protocol-projection-value--from-alist
                        key (cdr cell))))))))

(defun dsh-protocol-control-baseline--from-alist (value)
  "Return nonempty session records from control baseline VALUE, in wire order.
Records stay raw so callers can decode and apply each session before reading
the next; a later migration-required record must not discard earlier updates."
  (cl-remove-if-not
   (lambda (entry) (and (consp entry) (cdr entry)))
   (dsh-protocol--list (dsh-protocol--field 'projections value))))

(cl-defstruct (dsh-protocol-session-notice
               (:constructor dsh-protocol-session-notice--from-alist
                             (frame &aux
                                    (name (dsh-protocol--field 'event frame))
                                    (args (dsh-protocol--list
                                           (dsh-protocol--field 'args frame)))
                                    (session-id
                                     (when (member name '("api-session/removed"
                                                          "api-session/status"
                                                          "api-session/activity"))
                                       (car args)))
                                    (value
                                     (pcase name
                                       ("api-session/added" (car args))
                                       ("api-session/status"
                                        (dsh-protocol--boolean (cadr args)))
                                       ("api-session/activity" (cadr args))
                                       (_ nil))))))
  "A session emit with named arguments instead of positional wire fields.
VALUE is the raw added summary, decoded running flag or activity timestamp;
otherwise nil.
Added summaries stay raw until cache application so a mutable cached session
cannot contaminate the payload retained for refresh replay."
  name session-id value)

(cl-defstruct (dsh-protocol-waterfall
               (:constructor dsh-protocol-waterfall--from-alist
                             (frame &aux
                                    (name (dsh-protocol--field 'event frame))
                                    (event-id (dsh-protocol--field 'eventId frame))
                                    (agent-id (dsh-protocol--field 'agentId frame))
                                    (request (dsh-protocol--field 'request frame)))))
  "A routed interaction envelope with an opaque REQUEST.
Decode the request only after routing to a live chat: other clients' requests
must be handed on without interpreting their contents."
  name event-id agent-id request)

(cl-defstruct (dsh-protocol-core-item
               (:constructor dsh-protocol--make-core-item))
  "One core stream item with a payload selected by TYPE.
Workspace/projection payloads and session/interaction envelopes are decoded.
Control baselines stay raw for per-session decoding; ready/cancel payloads are
ids, and unknown frames retain their original object."
  type payload)

(defun dsh-protocol-core-item--from-alist (frame)
  "Decode a core FRAME without applying cache or interaction changes.
A baseline with non-nil items is a workspace baseline, including the empty
wire array []; absent/null items retain the control-baseline route."
  (let ((type (dsh-protocol--field 'type frame)))
    (dsh-protocol--make-core-item
     :type type
     :payload
     (pcase type
       ("baseline"
        (let ((value (dsh-protocol--field 'value frame)))
          (if (dsh-protocol--field 'items value)
              (dsh-protocol-workspace-list--from-alist value)
            value)))
       ("projection" (dsh-protocol-projection--from-alist frame))
       ("upsert"
        (when-let* ((workspace (dsh-protocol--field 'workspace frame)))
          (dsh-protocol-workspace--from-alist workspace)))
       ("remove" (dsh-protocol--field 'workspaceId frame))
       ("order" (dsh-protocol--list
                 (dsh-protocol--field 'workspaceIds frame)))
       ("archived" (dsh-protocol--list
                    (dsh-protocol--field 'archivedSessionIds frame)))
       ("ready" (dsh-protocol--field 'clientId frame))
       ("emit" (dsh-protocol-session-notice--from-alist frame))
       ("waterfall" (dsh-protocol-waterfall--from-alist frame))
       ("cancel" (dsh-protocol--field 'eventId frame))
       (_ frame)))))

(defun dsh-protocol-rpc-request-json (method rpc-id args)
  "Encode METHOD, RPC-ID and ARGS into a client-request envelope.
ARGS is the method's parameter alist, or nil for no parameters.  Empty
arguments must be an object, not null."
  (dsh-protocol-write-json
   `((type . "client-request") (rpcId . ,rpc-id) (method . ,method)
     (payload . ((args . ,(or args (make-hash-table))))))))

(defun dsh-protocol-mux-open-json (stream-id endpoint args)
  "Encode a mux open frame for STREAM-ID at ENDPOINT with ARGS.
Parameter-less endpoints still carry an empty args object."
  (dsh-protocol-write-json
   `((type . "open") (streamId . ,stream-id) (endpoint . ,endpoint)
     (payload . ((args . ,(or args (make-hash-table))))))))

(defun dsh-protocol-mux-cancel-json (stream-id)
  "Encode a mux cancel frame for STREAM-ID."
  (dsh-protocol-write-json `((type . "cancel") (streamId . ,stream-id))))

(defun dsh-protocol-session-list-request ()
  "Encode the unfiltered session/list arguments.
Its parameter is named `_request', unlike other session methods, and its
empty value must be an object rather than null."
  (list (cons '_request (make-hash-table))))

(defun dsh-protocol-session-select-model-request (session provider model effort)
  "Encode model selection for SESSION, PROVIDER and MODEL.
Omit reasoningEffort when EFFORT is nil."
  `((request . ((sessionId . ,session) (provider . ,provider) (model . ,model)
                ,@(when effort `((reasoningEffort . ,effort)))))))

(defun dsh-protocol-session-rename-request (session title)
  "Encode a rename of SESSION to TITLE."
  `((request . ((sessionId . ,session) (title . ,title)))))

(defun dsh-protocol-session-cancel-request (session)
  "Encode cancellation of SESSION's running turn."
  `((request . ((sessionId . ,session)))))

(defun dsh-protocol-prompt-content (text parts)
  "Encode prompt TEXT followed by resolved attachment PARTS."
  (vconcat `(((type . "text") (text . ,text))) parts))

(defun dsh-protocol-image-attachment (media bytes name)
  "Encode raw image BYTES as a staged descriptor with MEDIA and NAME.
Base64 is continuous, without line breaks, as required by the host."
  `((mediaType . ,media) (data . ,(base64-encode-string bytes t)) (name . ,name)))

(defun dsh-protocol-image-content-part (attachment)
  "Tag staged image ATTACHMENT as a content part, retaining its fields.
A staged file has no image media type and cannot become a part before upload."
  (when (assq 'mediaType attachment)
    (cons '(type . "image") attachment)))

(defun dsh-protocol-file-content-part (receipt)
  "Encode decoded file upload RECEIPT as a single-use content part.
Only the receipt ID travels; display metadata and local paths do not."
  `((type . "file")
    (receiptId . ,(dsh-protocol-file-receipt-receipt-id receipt))))

(defun dsh-protocol-session-prompt-request (session id mode content zone)
  "Encode SESSION's prompt with request ID, MODE, CONTENT and time ZONE."
  `((request . ((requestId . ,id) (sessionId . ,session) (mode . ,mode)
                (content . ,content) (clientTimeZone . ,zone)))))

(defun dsh-protocol-queue-remove-action ()
  "Encode removal of a confirmed queue item."
  '((kind . "remove")))

(defun dsh-protocol-queue-steer-action ()
  "Encode promotion of a confirmed queue item into the running turn."
  '((kind . "steer")))

(defun dsh-protocol-queue-edit-action (text)
  "Encode replacement of a queue item's content with one TEXT block."
  `((kind . "edit") (content . ,(dsh-protocol-prompt-content text nil))))

(defun dsh-protocol-session-update-queue-request (session item action)
  "Encode ACTION on queue ITEM in SESSION."
  `((request . ((sessionId . ,session) (itemId . ,item) (action . ,action)))))

(defun dsh-protocol-session-attachment-request (session attachment)
  "Encode a fetch of ATTACHMENT bytes from SESSION."
  `((request . ((sessionId . ,session) (attachmentId . ,attachment)))))

(defun dsh-protocol-session-follow-request (session address max-messages rounds)
  "Encode a follow of SESSION or ADDRESS for ROUNDS, bounded by MAX-MESSAGES.
Always request assistant stream frames; omit a nil message bound."
  `((request . ((address . ,(dsh-protocol-session-address-json session address))
                (assistantStream . t)
                ,@(when max-messages `((maxMessages . ,max-messages)))
                (turnWindow . ((minMessages . 1) (minTurns . ,rounds)))))))

(defun dsh-protocol-workspace-archive-session-request (session)
  "Encode archiving or unarchiving SESSION in the workspace registry."
  `((request . ((sessionId . ,session)))))

(defun dsh-protocol-workspace-create-request (path)
  "Encode creation of a workspace at absolute PATH."
  `((request . ((path . ,path)))))

(defun dsh-protocol-workspace-rename-request (workspace title)
  "Encode a rename of WORKSPACE to TITLE."
  `((request . ((workspaceId . ,workspace) (title . ,title)))))

(defun dsh-protocol-workspace-delete-request (workspace)
  "Encode deletion of WORKSPACE from the registry."
  `((request . ((workspaceId . ,workspace)))))

(defun dsh-protocol-workspace-insert-before-request (workspace before)
  "Encode moving WORKSPACE before BEFORE, or to the end when nil."
  `((request . ((workspaceId . ,workspace)
                ,@(when before `((beforeWorkspaceId . ,before)))))))

(defun dsh-protocol-job-list-request (session)
  "Encode a background job roster subscription for SESSION."
  `((request . ((sessionId . ,session)))))

(defun dsh-protocol-job-follow-request (job &optional session)
  "Encode following JOB, scoped to SESSION for session-owned jobs."
  `((request . ((jobId . ,job) ,@(when session `((sessionId . ,session)))))))

(defun dsh-protocol-job-kill-request (session job)
  "Encode stopping JOB on behalf of SESSION."
  `((request . ((sessionId . ,session) (jobId . ,job)))))

(defun dsh-protocol-skills-list-request (session)
  "Encode a skill catalog read for SESSION."
  `((request . ((sessionId . ,session)))))

(defun dsh-protocol-commands-list-request (session)
  "Encode a command catalog read scoped to SESSION as an agent."
  `((agentId . ,session)))

(defun dsh-protocol-commands-execute-request (session line parts)
  "Encode command LINE and resolved attachment PARTS for SESSION.
The required submittedAttachments argument is an array, including when empty."
  `((agentId . ,session) (line . ,line)
    (submittedAttachments . ,(vconcat parts))))

(defun dsh-protocol-reference-query-request (session query)
  "Encode SESSION and QUERY for file and session reference discovery.
Both endpoints take the same flat arguments; preserve an empty query string."
  `((agentId . ,session) (query . ,query)))

(defun dsh-protocol-goal-mutation-request (session goal &optional objective)
  "Encode a mutation of decoded GOAL in SESSION using its current CAS ref.
OBJECTIVE adds the edit request; nil omits it for pause, resume and clear."
  `((agentId . ,session)
    (ref . ((id . ,(dsh-protocol-goal-id goal))
            (revision . ,(dsh-protocol-goal-revision goal))))
    ,@(when objective `((request . ((objective . ,objective)))))))

(cl-defun dsh-protocol-provider-settings-request
    (section provider profile &key endpoint api models key-ref)
  "Encode changed provider settings in SECTION using its current revision.
For an existing PROFILE, update only supplied fields; otherwise set the new
PROVIDER entry.  MODELS contains model IDs.  Nil keyword values omit fields."
  (let* ((fields
          `(,@(when key-ref `((apiKeyEnv . ,key-ref)))
            ,@(when models
                `((models . ,(vconcat
                              (mapcar (lambda (id) `((id . ,id))) models)))))
            ,@(when api `((api . ,api)))
            ,@(when endpoint `((baseURL . ,endpoint)))))
         (ops
          (if profile
              (vconcat
               (mapcar (lambda (field)
                         `((op . "set")
                           (path . ,(vector "providers" provider
                                            (symbol-name (car field))))
                           (value . ,(cdr field))))
                       fields))
            (vector `((op . "set") (path . ,(vector "providers" provider))
                      (value . ,(or fields (make-hash-table))))))))
    `((ns . ,(dsh-protocol-provider-settings-name section))
      (expectedRevision . ,(dsh-protocol-provider-settings-revision section))
      (ops . ,ops))))

(defun dsh-protocol-credentials-describe-request (ref)
  "Encode credential status lookup for REF without reading its secret."
  `((refs . ,(vector ref))))

(defun dsh-protocol-credentials-set-request (ref key)
  "Encode a write of KEY to credential REF."
  `((ref . ,ref) (value . ,key)))

(defun dsh-protocol-events-result-request (client-id event-id outcome)
  "Encode OUTCOME for EVENT-ID on the CLIENT-ID waterfall generation."
  `((clientId . ,client-id) (eventId . ,event-id) (outcome . ,outcome)))

(defun dsh-protocol-question-answer-request (id selected &optional custom)
  "Encode an answer for question ID with SELECTED labels and optional CUSTOM.
Keep SELECTED's list or vector representation; nil CUSTOM omits the field."
  `((id . ,id) (selected . ,selected)
    ,@(when custom `((custom . ,custom)))))

(defun dsh-protocol-question-result-outcome (answers)
  "Encode the successful question waterfall's ANSWERS, preserving their shape."
  `((kind . "result") (value . ((answers . ,answers)))))

(defun dsh-protocol-approval-outcome (allow)
  "Encode an approval decision: allow once when ALLOW, otherwise reject.
Both decisions are result values, not rejected waterfall errors."
  `((kind . "result") (value . ,(if allow "allowed-once" "rejected"))))

(defun dsh-protocol-events-cancelled-outcome (message)
  "Encode a cancelled waterfall with its caller-supplied MESSAGE."
  `((kind . "rejected") (error . ((name . "cancelled") (message . ,message)))))

(defun dsh-protocol-events-next-outcome ()
  "Encode a waterfall handoff, with no result value or error."
  '((kind . "next")))

(defun dsh-protocol-question-wait-request (session call-id)
  "Encode the timed wait claim for CALL-ID in SESSION."
  `((agentId . ,session) (callId . ,call-id)))

(defun dsh-protocol-question-late-answer-request (session call-id answers)
  "Encode a late ANSWERS batch for CALL-ID in SESSION without array coercion."
  `((agentId . ,session) (callId . ,call-id)
    (answer . ((answers . ,answers)))))

(defun dsh-protocol-session-address-json (session-id &optional address)
  "Serialize SESSION-ID or its durable subagent ADDRESS."
  (if address
      `((kind . "subagent")
        (parentSessionId . ,(dsh-protocol-subagent-address-parent address))
        (childSessionId . ,(dsh-protocol-subagent-address-child address))
        (mode . ,(dsh-protocol-subagent-address-mode address)))
    `((kind . "session") (sessionId . ,session-id))))

;; Backwards history pages retain raw event records for the transcript renderer;
;; pagination and round metadata are decoded here for the history controller.
(cl-defstruct (dsh-protocol-history-page
               (:constructor dsh-protocol--make-history-page))
  "One decoded `session/page' history window.
RECORDS retain raw events and OLDEST/NEWEST are its sequence cursors.  ROUNDS
is supplied by the history loader from
`dsh-protocol-history-human-rounds' over the accumulated records; the wire
page has no round classification."
  records oldest newest has-more rounds)

(defun dsh-protocol-history-page--from-alist (value)
  "Decode VALUE into records, an oldest/newest cursor and has-more.
The history loader supplies the page's human ROUNDS from the accumulated
records."
  (let (records oldest previous)
    (dolist (record (dsh-protocol--objects (dsh-protocol--field 'records value)))
      (when (equal (dsh-protocol--field 'type record) "event")
        (let* ((event (dsh-protocol--field 'event record))
               (seq (dsh-protocol--field 'seq event)))
          (unless (and (natnump seq) (or (null previous) (> seq previous)))
            (error "History page has invalid or unordered event sequence: %S" seq))
          (unless oldest (setq oldest seq))
          (setq previous seq)
          (push record records))))
    (dsh-protocol--make-history-page
     :records (nreverse records) :oldest oldest :newest previous
     :has-more (dsh-protocol--boolean (dsh-protocol--field 'hasMore value)))))

(defun dsh-protocol-history-page-request (session address through before limit rounds)
  "Serialize a backwards SESSION/ADDRESS request through THROUGH, before BEFORE.
LIMIT bounds messages in one response; ROUNDS is the remaining round target."
  `((request . ((address . ,(dsh-protocol-session-address-json session address))
                (throughSeq . ,through) (beforeSeq . ,before)
                (maxMessages . ,limit)
                (turnWindow . ((minMessages . 1) (minTurns . ,rounds)))))))

(defun dsh-protocol-subagent-projections-request (session-id)
  "Cold-read request for SESSION-ID."
  `((request . ((sessionId . ,session-id)))))

(defun dsh-protocol-session-create-request (id cwd workspace preset)
  "Encode creation of ID in CWD or WORKSPACE with optional PRESET."
  `((request . ,(append `((sessionId . ,id))
                        (if workspace `((workspaceId . ,workspace))
                          `((cwd . ,cwd)))
                        (and preset `((agentPreset . ,preset)))))))

(defun dsh-protocol-session-fork-request (session-id &optional at-seq)
  "Serialize a fork of SESSION-ID, optionally through inclusive AT-SEQ."
  `((request . ((sessionId . ,session-id)
                ,@(when at-seq `((atSeq . ,at-seq)))))))

(defun dsh-protocol-subagent-prompt-request (address id delivery text zone)
  "Serialize ADDRESS, caller ID, DELIVERY, TEXT and ZONE for follow-up."
  `((request . ((requestId . ,id)
                (parentSessionId . ,(dsh-protocol-subagent-address-parent address))
                (childSessionId . ,(dsh-protocol-subagent-address-child address))
                (mode . ,(dsh-protocol-subagent-address-mode address))
                (delivery . ,delivery)
                (content . [((type . "text") (text . ,text))])
                (clientTimeZone . ,zone)))))

(defun dsh-protocol-subagent-stop-request (address)
  "Serialize the direct-parent stop ADDRESS."
  `((parentSessionId . ,(dsh-protocol-subagent-address-parent address))
    (childSessionId . ,(dsh-protocol-subagent-address-child address))
    (mode . ,(dsh-protocol-subagent-address-mode address))))

(defun dsh-protocol-session-list--from-alist (alist)
  "Decode the session list ALIST."
  (mapcar #'dsh-protocol-session--from-alist
          (dsh-protocol--list (cdr (assq 'items alist)))))

(defun dsh-protocol-event-sequence--from-alist (event)
  "Return the event seq."
  (dsh-protocol--field "seq" event))

(defun dsh-protocol-event-kind--from-alist (event)
  "Return the wire EVENT kind without interpreting its payload."
  (dsh-protocol--field 'type event))

(defun dsh-protocol-event-clock--from-alist (event)
  "Return EVENT's positive integer epoch milliseconds, or nil."
  (let ((time (dsh-protocol--field 'time event)))
    (and (integerp time) (> time 0) time)))

(defun dsh-protocol-replacement--from-alist (event)
  "Whether EVENT is a model-only surface replacement copy.
A message-producing event carries `surfaceOp' either \"append\" (it entered
the transcript at its own log position) or `{op:\"replace\", startSeq,
endSeq}' (it shadows an existing surface range so the MODEL sees the newer
copy).  dsh-session's `isAppendSurfaceEvent' exists for exactly that split:
replacements are the wrong source for a human transcript, because painting
one would show conversation the user already saw a second time.  The record
still belongs in the log — it is the state the next request is built from.

Compaction checkpoints are already skipped by the `user/message' source
filter (their source kind is `plugin'), but a pruned `tool/result'
replacement shares its `callId' with the record it shadows and has no
source filter, so without this check the same tool card is painted twice."
  (equal "replace"
         (dsh-protocol--field
          "op" (dsh-protocol--field "surfaceOp" event))))

(defun dsh-protocol-stream-key--from-alist (event)
  "Return the logical assistant stream key for EVENT."
  (let ((data (dsh-protocol--field 'data event)))
    (format "%s/%s"
            (or (dsh-protocol--field "turn" data) "?")
            (or (dsh-protocol--field "step" data) "?"))))

(cl-defstruct (dsh-protocol-chunk
               (:constructor dsh-protocol-chunk--from-alist
                             (event &aux
                                    (data (dsh-protocol--field 'data event))
                                    (chunk (dsh-protocol--field 'chunk data))
                                    (kind (dsh-protocol--field 'type chunk))
                                    (ending (equal kind "block-end"))
                                    (block (if ending (dsh-protocol--field 'block chunk) chunk))
                                    (type (dsh-protocol--field 'type block))
                                    (text (dsh-protocol--field 'text block))
                                    (index (dsh-protocol--field 'index chunk)))))
  "One assistant chunk; a block-end uses its nested block as content."
  kind ending type text index)

(defun dsh-protocol-chunk-index--from-alist (event)
  "Return the block index identifying EVENT's live text or reasoning region."
  (dsh-protocol--field 'index
                       (dsh-protocol--field 'chunk
                                            (dsh-protocol--field 'data event))))

(defun dsh-protocol-turn--from-alist (event)
  "Return the turn identity in EVENT without interpreting other payloads."
  (dsh-protocol--field 'turn (dsh-protocol--field 'data event)))

(defun dsh-protocol-turn-failure--from-alist (event)
  "Return (MESSAGE . CODE) for EVENT's terminal turn failure, or nil.
Mirrors dsh web's turn-error definition: a `turn/end' event whose
DATA.REASON.KIND is \"error\" carries the provider failure in
DATA.REASON.ERROR ({code, message, ...})."
  (let* ((data (dsh-protocol--field 'data event))
         (reason (dsh-protocol--field "reason" data))
         (kind (dsh-protocol--field "kind" reason))
         (error (dsh-protocol--field "error" reason)))
    (when (equal kind "error")
      (cond
       ((stringp error) (cons error nil))
       ((listp error)
        (cons (or (dsh-protocol--field "message" error)
                  (format "%S" error))
              (let ((code (dsh-protocol--field "code" error)))
                (and (stringp code) (not (string-empty-p code)) code))))
       (t (cons "Model run failed" nil))))))

(cl-defstruct (dsh-protocol-content-block
               (:constructor dsh-protocol-content-block--from-alist
                             (block &aux
                                    (kind (dsh-protocol--field 'type block))
                                    (text (dsh-protocol--field 'text block))
                                    (ref (dsh-protocol--field 'attachment block))
                                    (name (or (dsh-protocol--field 'name block)
                                              (dsh-protocol--field 'name ref)))
                                    (media-type (or (dsh-protocol--field 'mediaType block)
                                                    (dsh-protocol--field 'mediaType ref)))
                                    (data (or (dsh-protocol--field 'data block)
                                              (dsh-protocol--field 'data ref)))
                                    (attachment-id
                                     (or (dsh-protocol--field 'attachmentId block)
                                         (dsh-protocol--field 'attachmentId ref)))
                                    (file (when (equal kind "file")
                                            (dsh-protocol-file-ref--from-alist
                                             (or ref block)))))))
  "A message block with inline or referenced attachment fields normalized."
  kind text name media-type data attachment-id file)

(cl-defstruct (dsh-protocol-message
               (:constructor dsh-protocol-message--from-alist
                             (event &key assistant &aux
                                    (data (dsh-protocol--field 'data event))
                                    (source (dsh-protocol--field 'source data))
                                    (id (dsh-protocol--field 'id data))
                                    (source-kind (dsh-protocol--field 'kind source))
                                    (source-name (dsh-protocol--field 'name source))
                                    (source-provider
                                     (dsh-protocol--field 'provider source))
                                    (content
                                     (mapcar #'dsh-protocol-content-block--from-alist
                                             (dsh-protocol--list
                                              (dsh-protocol--field
                                               'content
                                               (if assistant
                                                   (dsh-protocol--field 'message data)
                                                 data)))))
                                    (references
                                     (when (equal source-kind "session-reference")
                                       (cl-loop
                                        for ref in (dsh-protocol--objects
                                                    (dsh-protocol--field 'references source))
                                        for id = (dsh-protocol--field 'sessionId ref)
                                        for label = (dsh-protocol--field 'label ref)
                                        when (and (stringp id) (not (equal id ""))
                                                  (stringp label))
                                        collect (cons label id)))))))
  "Content and source evidence of a user or assistant message.
ID is the durable message identity an inbox claim names; SOURCE-PROVIDER is
the recorded provider for webhook triggers.  Source-less optimistic user
echoes use the same content boundary and leave both nil."
  id content source-kind source-name source-provider references)

(defun dsh-protocol-attachment-data--from-alist (value)
  "Return the encoded bytes in a session/attachment response VALUE."
  (dsh-protocol--field 'data value))

(cl-defstruct (dsh-protocol-inbox-splice
               (:constructor dsh-protocol-inbox-splice--from-alist
                             (event &aux
                                    (data (dsh-protocol--field 'data event))
                                    (target (dsh-protocol--field 'target data))
                                    (start (dsh-protocol--field 'start data))
                                    (removed-count
                                     (dsh-protocol--field 'removedCount data))
                                    (outcome
                                     (dsh-protocol--field 'outcome data))
                                    (inserted
                                     (cl-loop
                                      for item
                                      in (dsh-protocol--objects
                                          (dsh-protocol--field 'inserted data))
                                      for id = (dsh-protocol--field 'id item)
                                      for source = (dsh-protocol--field
                                                    'source item)
                                      when (stringp id)
                                      collect (cons id (dsh-protocol--field
                                                        'kind source)))))))
  "One `agent/inbox/spliced' queue change.
TARGET is `next-turn' or `next-step'; INSERTED holds (ID . SOURCE-KIND) for
the messages the splice adds and REMOVED-COUNT the number it drops from the
same queue.  OUTCOME is `canceled' when a dropped batch was never admitted.
The renderer replays these records only to classify a turn-opening notice;
it paints no row and keeps no Agent state."
  target start removed-count outcome inserted)

(defun dsh-protocol-record-event--from-alist (record)
  "Return the durable event carried by history RECORD."
  (dsh-protocol--field 'event record))

(cl-defstruct (dsh-protocol-turn-step-event
               (:constructor dsh-protocol-turn-step-event--from-alist
                             (event &aux
                                    (kind (dsh-protocol--field 'type event))
                                    (data (dsh-protocol--field 'data event))
                                    (turn (dsh-protocol--field 'turn data))
                                    (step (dsh-protocol--field 'step data))
                                    (stream (dsh-protocol--assistant-records
                                             (dsh-protocol--field 'stream data))))))
  "Turn/step position and any uncommitted assistant stream in an event."
  kind turn step stream)

(defun dsh-protocol-input-prompt--from-alist (entry)
  "Return a recallable user prompt in history ENTRY, or nil.
Only author text without attachments belongs in input history."
  (let* ((event (dsh-protocol-record-event--from-alist entry))
         (message (dsh-protocol-message--from-alist event))
         (blocks (dsh-protocol-message-content message))
         (source (dsh-protocol-message-source-kind message)))
    (when (and (equal (dsh-protocol-event-kind--from-alist event) "user/message")
               (or (null source) (equal source "user"))
               (cl-every (lambda (block)
                           (equal (dsh-protocol-content-block-kind block) "text"))
                         blocks))
      (mapconcat #'identity
                 (delq nil (mapcar #'dsh-protocol-content-block-text blocks))
                 "\n"))))

(cl-defun dsh-protocol-request-model--from-alist (event &key header-p)
  "Decode EVENT's model selection, or nil when its config is absent.
HEADER-P selects the request/header envelope instead of request/context."
  (let* ((data (dsh-protocol--field "data" event))
         (config (if header-p
                     (dsh-protocol--field
                      "config" (dsh-protocol--field "header" data))
                   data)))
    (when config
      (dsh-protocol-model-selection--from-alist config))))

(defun dsh-protocol--usage-number (value)
  "Normalize a numeric usage VALUE, preserving nil for missing values.
A string is parsed with `string-to-number', so nonnumeric text becomes 0."
  (cond ((numberp value) value)
        ((stringp value) (string-to-number value))))

(cl-defun dsh-protocol-message-usage--from-alist (value &key event-p)
  "Decode VALUE into an input/output/cache-read/cache-write/cost list.
EVENT-P selects an event envelope rather than a raw usage object."
  (let ((usage (if event-p
                   (dsh-protocol--field
                    "usage" (dsh-protocol--field "data" value))
                 value)))
    (list
     (or (dsh-protocol--usage-number (dsh-protocol--field "inputTokens" usage))
         (dsh-protocol--usage-number (dsh-protocol--field "input" usage)) 0)
     (or (dsh-protocol--usage-number (dsh-protocol--field "outputTokens" usage))
         (dsh-protocol--usage-number (dsh-protocol--field "output" usage)) 0)
     (or (dsh-protocol--usage-number (dsh-protocol--field "cacheReadTokens" usage))
         (dsh-protocol--usage-number (dsh-protocol--field "cacheRead" usage)) 0)
     (or (dsh-protocol--usage-number (dsh-protocol--field "cacheWriteTokens" usage))
         (dsh-protocol--usage-number (dsh-protocol--field "cacheWrite" usage)) 0)
     (or (dsh-protocol--usage-number (dsh-protocol--field "cost" usage)) 0.0))))

(defun dsh-protocol-todos--from-alist (args-raw)
  "Parse a `todo_write' ARGS-RAW JSON string into an ordered list of
\(\"content\" . \"status\") cells.  Empty/invalid content is dropped and a
missing or unknown status defaults to \"pending\".  Returns nil on any error."
  (let (result)
    (when (and args-raw (stringp args-raw) (not (string-empty-p args-raw)))
      (let ((todos (dsh-protocol--field
                    "todos" (dsh-protocol--tool-json args-raw))))
        (dolist (cell (append todos nil))
          (when (consp cell)
            (let ((content (dsh-protocol--field "content" cell))
                  (status (dsh-protocol--field "status" cell)))
              (when (and (stringp content) (not (string-empty-p content)))
                (push (cons content
                            (if (member status '("pending" "in_progress" "completed"))
                                status "pending"))
                      result)))))))
    (nreverse result)))

(defun dsh-protocol-read-lines--from-alist (meta offset)
  "Narrow META's `lines' to a list of (NUMBER . TEXT) cells, or nil.
META is the settled `tool/result' metadata alist.  The payload is validated
as a whole (web `readMeta'), so a malformed one falls back to the generic
card instead of printing a half-read file: `lines' must be an array whose
NUMBERs are strictly increasing from the 1-based OFFSET through
`totalLines', each with a string TEXT."
  (when (listp meta)
    (let ((raw (dsh-protocol--field "lines" meta))
          (total (dsh-protocol--field "totalLines" meta)))
      (when (and (vectorp raw) (integerp total) (>= total 0)
                 (integerp offset) (>= offset 1))
        (catch 'bad
          (let ((previous (1- offset)) (out '()))
            (dotimes (i (length raw))
              (let ((cell (aref raw i)))
                (unless (listp cell) (throw 'bad nil))
                (let ((number (dsh-protocol--field "number" cell))
                      (text (dsh-protocol--field "text" cell)))
                  (unless (and (integerp number) (>= number 1)
                               (> number previous) (<= number total)
                               (stringp text))
                    (throw 'bad nil))
                  (setq previous number)
                  (push (cons number text) out))))
            (nreverse out)))))))

(defun dsh-protocol-intended-diff--from-alist (name args-raw)
  "Return the hunk NAME/ARGS-RAW intend as (PATH OLD-TEXT NEW-TEXT), or nil.
Mirrors dsh web's `intendedDiff': `write' contributes a whole-file creation
(OLD-TEXT nil) from its `content', `edit' the `old_string' → `new_string'
replacement (an empty old string means insertion, so OLD-TEXT is nil).
Returns nil when the arguments are not a usable file mutation."
  (let ((args (dsh-protocol--tool-json args-raw)))
    (when args
      (let ((path (dsh-protocol--field "file_path" args)))
        (when (and (stringp path) (not (string-empty-p (string-trim path))))
          (pcase name
            ("write"
             (let ((content (dsh-protocol--field "content" args)))
               (when (stringp content) (list path nil content))))
            ("edit"
             (let ((old (dsh-protocol--field "old_string" args))
                   (new (dsh-protocol--field "new_string" args)))
               (when (and (stringp old) (stringp new))
                 (list path (unless (string-empty-p old) old) new))))))))))

(defun dsh-protocol-applied-diffs--from-alist (meta)
  "Return META's applied `diffs' as (PATH OLD-TEXT NEW-TEXT) hunks, or nil.
Mirrors dsh web's `narrowDiffs': any malformed hunk invalidates the whole
payload, and an empty array is no hunk list (the caller then keeps the
argument-derived diff for a `write' and the generic ioCard for an `edit')."
  (let ((raw (and (listp meta) (dsh-protocol--field "diffs" meta))))
    (when (and (vectorp raw) (> (length raw) 0))
      (catch 'bad
        (let (out)
          (dotimes (i (length raw))
            (let ((hunk (aref raw i)))
              (unless (listp hunk) (throw 'bad nil))
              (let ((path (dsh-protocol--field "path" hunk))
                    (old (dsh-protocol--field "oldText" hunk))
                    (new (dsh-protocol--field "newText" hunk)))
                (unless (and (stringp path)
                             (or (null old) (stringp old))
                             (stringp new))
                  (throw 'bad nil))
                (push (list path old new) out))))
          (nreverse out))))))

(defun dsh-protocol-ask-questions--from-alist (args-raw)
  "Decode an `ask_user_question' call's ARGS-RAW into question structs.
Returns the questions in their offered order, or nil when the arguments name
no usable question — a missing `questions' array, a question without an id or
text, or malformed JSON — so the caller keeps the generic ioCard.  Empty text
is allowed: it is a presentation concern, and the caller substitutes a
placeholder while still showing the options.  The protocol module owns both
argument spellings of the multi-select flag and drops a malformed element
instead of signalling."
  (let ((parsed (dsh-protocol--tool-json args-raw)))
    (when parsed
      (delq nil
            (mapcar
             (lambda (item)
               (let ((question (dsh-protocol-question--from-alist item)))
                 (when (and (dsh-protocol-question-p question)
                            (let ((id (dsh-protocol-question-id question))
                                  (text (dsh-protocol-question-text question)))
                              (or (and (stringp id)
                                       (not (string-empty-p id)))
                                  (and (stringp text)
                                       (not (string-empty-p text))))))
                   question)))
             (dsh-protocol--objects
              (dsh-protocol--field "questions" parsed)))))))

(defun dsh-protocol-ask-answers--from-alist (text)
  "Decode an `ask_user_question' result TEXT into (ID SELECTED CUSTOM) cells.
SELECTED is the list of labels the user chose; CUSTOM is the free-text answer,
or nil when none was typed.  Returns nil when TEXT is not the tool's answer
document — an error message or an empty result — so the card renders its
questions unanswered."
  (let* ((parsed (dsh-protocol--tool-json text))
         (answers (and parsed (dsh-protocol--objects
                               (dsh-protocol--field "answers" parsed)))))
    (when answers
      (mapcar
       (lambda (answer)
         (list (dsh-protocol--field "id" answer)
               (delq nil
                     (mapcar (lambda (label) (and (stringp label) label))
                             (dsh-protocol--list
                              (dsh-protocol--field "selected" answer))))
               (let ((custom (dsh-protocol--field "custom" answer)))
                 (and (stringp custom)
                      (not (string-empty-p custom))
                      custom))))
       answers))))

(defun dsh-protocol-ask-pending--from-alist (text)
  "Whether ask result TEXT is the timed tool's pending payload.
dsh 0.2.0's timed `ask_user_question' returns `{pending:true, callId,
message}' when the foreground window expired before an answer batch arrived;
the questions stay answerable, so this is not an empty result and the card
must say so.  Mirrors the host's own `isPendingResult'."
  (let ((parsed (and (stringp text) (dsh-protocol--tool-json text))))
    (and (listp parsed)
         (eq t (dsh-protocol--boolean
                (dsh-protocol--field "pending" parsed))))))

(defun dsh-protocol-goal-result--from-alist (text)
  "Decode goal tool result TEXT into (GOAL . CLEARED-P), or nil.
The three tools answer with the GoalView in `goal' plus the process-local
`activation' beside it (see dsh-tool-goal), or `{goal: null}' after a clear.
GOAL is a `dsh-protocol-goal' decoded by the protocol module, CLEARED-P marks
the empty answer, and an unrecognized document yields nil so the caller keeps
the generic ioCard."
  (when (and (stringp text) (not (string-empty-p (string-trim text))))
    (let ((parsed (dsh-protocol--tool-json text)))
      (when-let* ((cell (and parsed (assoc 'goal parsed))))
        (if (null (cdr cell))
            (cons nil t)
          (when-let* ((goal (dsh-protocol-goal-tool--from-alist parsed)))
            (cons goal nil)))))))

(cl-defstruct (dsh-protocol-read-file
               (:constructor dsh-protocol-read-file--from-alist
                             (args-raw meta &aux
                                       (args (dsh-protocol--tool-json args-raw))
                                       (path (dsh-protocol--field "file_path" args))
                                       (offset (dsh-protocol--field "offset" meta))
                                       (total (dsh-protocol--field "totalLines" meta))
                                       (language (dsh-protocol--field "lang" meta))
                                       (lines (dsh-protocol-read-lines--from-alist
                                               meta offset)))))
  "Decoded read arguments and numbered result lines."
  path offset total language lines)

(cl-defstruct (dsh-protocol-tool-arguments
               (:constructor dsh-protocol--make-tool-arguments))
  "Tool argument facts; OBJECT is retained only for generic JSON display.
RAW is the original argument text, for cards that fall back to it."
  object raw command summary paths objective action)

(defun dsh-protocol-tool-arguments--from-alist (text &optional name variant)
  "Decode tool argument TEXT, selecting summary fields for NAME and VARIANT."
  (let* ((object (dsh-protocol--tool-json text))
         (priorities '(("bash" . ("description" "command"))
                       ("read" . ("path" "file_path" "url"))
                       ("search" . ("query" "pattern" "url"))
                       ("write" . ("path" "file_path"))
                       ("edit" . ("path" "file_path"))
                       ("code" . ("description"))
                       ("job_output" . ("job_id"))
                       ("job_kill" . ("job_id"))
                       ("others")))
         (keys (cdr (or (assoc name priorities) (assoc variant priorities))))
         (summary
          (or (cl-loop for key in keys
                       for value = (dsh-protocol--field key object)
                       when (and (stringp value) (not (string-empty-p value)))
                       return value)
              (cl-loop for pair in object
                       for value = (cdr pair)
                       when (and (stringp value) (not (string-empty-p value)))
                       return value))))
    (dsh-protocol--make-tool-arguments
     :object object
     :raw text
     :command (or (dsh-protocol--field "command" object)
                  (dsh-protocol--field "code" object))
     :summary summary
     :paths (cl-loop for file in (dsh-protocol--list
                                  (dsh-protocol--field "files" object))
                     for path = (dsh-protocol--field "path" file)
                     when (and (stringp path) (not (string-empty-p path)))
                     collect path)
     :objective (dsh-protocol--field "objective" object)
     :action (dsh-protocol--field "action" object))))

(cl-defun dsh-protocol-rpc-result--from-alist (response &key direct-p)
  "Decode RESPONSE into (OK-P . VALUE-OR-ERROR).
DIRECT-P selects the upload route's bare result.  Ordinary RPC failures
prefer their result error, then a provider message or error at the root."
  (let* ((result (if direct-p response (dsh-protocol--field 'result response)))
         (ok (dsh-protocol--boolean (dsh-protocol--field 'ok result))))
    (if ok
        (cons t (dsh-protocol--field 'value result))
      (cons nil (or (dsh-protocol--field 'error result)
                    (unless direct-p
                      (or (dsh-protocol--field 'message response)
                          (dsh-protocol--field 'error response))))))))

(defun dsh-protocol-agent-preset-error--from-alist (value)
  "Return (PRESET . AVAILABLE) from an `agent-preset/*' error VALUE.
PRESET is the rejected preset id; AVAILABLE lists the ids the server
does provide, or nil when the error names none."
  (let* ((details (dsh-protocol-rpc-error-details
                   (dsh-protocol-rpc-error--from-alist value)))
         (preset (dsh-protocol--field 'agentPreset details)))
    (when preset
      (cons preset
            (dsh-protocol--list (dsh-protocol--field 'available details))))))

(defun dsh-protocol-workspace-order--from-alist (value)
  "Return the authoritative workspace order in RPC VALUE as a list."
  (dsh-protocol--list (dsh-protocol--field 'workspaceIds value)))

(defun dsh-protocol-job-kill--from-alist (value)
  "Return the server's job kill outcome in VALUE, if present."
  (dsh-protocol--field 'outcome value))

(defun dsh-protocol-session-uri--from-string (payload)
  "Return the session id the `dsh-session:' URI PAYLOAD encodes, or nil.
The host writes base64url(JSON.stringify(ID)) into a mention (see the
harness's `encodeSessionReferenceUri'), so the id every RPC expects is the
decoded JSON string; treating PAYLOAD itself as the identity asks the host
for a session named after the encoding and earns `session/not-found'.  Nil
when PAYLOAD is no decodable session reference."
  (when (and (stringp payload)
             (string-match-p "\\`[A-Za-z0-9_-]+\\'" payload))
    (let* ((b64 (replace-regexp-in-string
                 "-" "+" (replace-regexp-in-string "_" "/" payload t t) t t))
           (pad (mod (- 4 (mod (length b64) 4)) 4))
           (decoded (ignore-errors
                      (base64-decode-string (concat b64 (make-string pad ?=))))))
      (when (stringp decoded)
        ;; JSON numbers/escapes use match data; preserve the mention scan.
        (let ((id (ignore-errors
                    (save-match-data
                      (dsh-protocol-read-json
                       (if (multibyte-string-p decoded)
                           decoded
                         (decode-coding-string decoded 'utf-8)))))))
          (and (stringp id) id))))))

(provide 'dsh-emacs-protocol)

;;; dsh-emacs-protocol.el ends here
