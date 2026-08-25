;;; dsh-emacs-protocol.el --- Typed views of dsh RPC payloads -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.1.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; dsh server 的响应是 JSON 解码后的 alist（数组为 vector）。本文件把
;; 常用响应归纳为 cl-defstruct 类型：每个字段名只在对应的 `--from-alist'
;; 构造器里出现一次，业务代码一律通过访问器取值；服务端协议修改时，
;; 只需在这里同步字段，调用方无需逐个确认。
;;
;; 结构概览（对应端到协议）：
;;
;;   session.list   → dsh-protocol-session             (sessionId title cwd
;;                                                       agentPreset updatedAt)
;;   workspace.list → dsh-protocol-workspace           (workspaceId sessionIds
;;                                                       title path)
;;   session.models → dsh-protocol-model-directory     (current . groups)
;;                     ├─ dsh-protocol-model-selection (provider model
;;                     │                                 reasoningEffort)
;;                     └─ dsh-protocol-provider-group  (id name models)
;;                          └─ dsh-protocol-model-catalog-entry (id name
;;                                description reasoning)
;;                               └─ dsh-protocol-reasoning (efforts
;;                                    defaultEffort)
;;                                    └─ dsh-protocol-effort (id name
;;                                         description)
;;
;; 转换入口都接受 wire alist；注意 wire 中的数组（vector）在 struct 里
;; 一律归一为 list。业务代码写入缓存 struct 后，读取统一用 `dsh-protocol-*'
;; 访问器。

;;; Code:

(require 'cl-lib)

(defun dsh-protocol--list (value)
  "JSON VALUE (list or vector) as a proper list."
  (cond ((vectorp value) (append value nil))
        ((listp value) value)
        (t nil)))

;; ---------------------------------------------------------------------------
;; session.list / workspace.list
;; ---------------------------------------------------------------------------

(cl-defstruct (dsh-protocol-session
               (:constructor dsh-protocol-session--from-alist
                             (alist
                              &aux
                              (session-id (cdr (assq 'sessionId alist)))
                              (title (cdr (assq 'title alist)))
                              (cwd (cdr (assq 'cwd alist)))
                              (agent-preset (cdr (assq 'agentPreset alist)))
                              (updated-at (cdr (assq 'updatedAt alist)))
                              (blank (cdr (assq 'blank alist)))
                              (running (cdr (assq 'running alist)))
                              ;; projections.values.title —— dsh web 的
                              ;; 自动摘要标题（与列表行的显示标题一致）
                              (title-value
                               (let ((p (cdr (assq 'projections alist))))
                                 (and p (cdr (assq 'title
                                                   (cdr (assq 'values p)))))))
                              ;; projections.values.sessionStats.pendingInteraction
                              (pending-interaction
                               (let* ((p (cdr (assq 'projections alist)))
                                      (v (and p (cdr (assq 'values p))))
                                      (st (and v
                                               (cdr (assq 'sessionStats v)))))
                                 (and st (cdr (assq 'pendingInteraction st))))))))
  "One `session.list' item."
  session-id
  title
  cwd
  agent-preset
  updated-at
  blank
  running
  title-value
  pending-interaction)

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
  "One workspace row of `workspace.list' (the `WorkspaceView' shape)."
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
  "The `workspace.list' response value: ITEMS plus the ARCHIVED-SESSION-IDS."
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
  "A workspace mutation response: `workspace.create' (WORKSPACE + CREATED
flag), `workspace.rename' and `workspace.insertSessionBefore' (WORKSPACE
only; CREATED is nil there)."
  workspace
  created)

;; ---------------------------------------------------------------------------
;; session.models
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
  "The `session.selectModel' response value (the SELECTED selection)."
  selected)

(cl-defstruct (dsh-protocol-model-directory
               (:constructor dsh-protocol-model-directory--from-alist
                             (alist
                              &aux
                              (current (and (cdr (assq 'current alist))
                                            (dsh-protocol-model-selection--from-alist
                                             (cdr (assq 'current alist)))))
                              (routable (cdr (assq 'routable alist)))
                              (groups
                               (mapcar #'dsh-protocol-provider-group--from-alist
                                       (dsh-protocol--list
                                        (cdr (assq 'groups alist)))))
                              (failures
                               (dsh-protocol--list (cdr (assq 'failures alist)))))))
  "A `session.models' response value: CURRENT selection, ROUTABLE flag,
GROUPS by provider and unknown FAILURES."
  current
  routable
  groups
  failures)

;; 将 wire alist 归一为 struct 的便捷入口：已是 struct 则原样返回。
;; 这样业务函数可以同时接受“协议响应”和“转换后的 struct”两种形态，
;; 调用方（以及既有测试里的裸 alist fixture）无需改动。
(defun dsh-protocol--struct (struct-alist-pred constructor value)
  "Return VALUE as a struct via CONSTRUCTOR if needed.
STRUCT-ALIST-PRED distinguishes an already-converted struct from a wire
alist; CONSTRUCTOR converts the wire alist."
  (if (funcall struct-alist-pred value)
      value
    (funcall constructor value)))

(provide 'dsh-emacs-protocol)

;;; dsh-emacs-protocol.el ends here