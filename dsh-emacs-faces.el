;;; dsh-emacs-faces.el --- Faces and color tokens for dsh-emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.1.0
;; License: GPL-3.0-or-later
;; Package-Requires ((emacs "27.1"))
;; Keywords: convenience, ai, tools

;;; Commentary:

;; Centralized face definitions for dsh-emacs, modeled after the
;; themes used by agent-shell (xenodium), pi (badlogic/pi-mono), and
;; opencode (anomalyco).
;;
;; Every face exposes a light / dark color value so users get a sensible
;; appearance on both backgrounds.  All colors are referenced through
;; the `dsh-emacs-color-*' custom variables, so end-users can re-tune
;; the entire palette from a single place:
;;
;;   (custom-set-variables
;;    '(dsh-emacs-color-accent "#0b7285")
;;    '(dsh-emacs-color-tool-pending-border "#b45f06")
;;    ...)
;;
;; Faces are organized into:
;;   - Brand / accent (`dsh-emacs-accent-face')
;;   - Roles (`dsh-emacs-user-*', 'dsh-emacs-assistant-*')
;;   - Tool state palette (`dsh-emacs-tool-{pending,success,error,title,output}-face')
;;   - Thinking (`dsh-emacs-thinking-*')
;;   - Activity groups (`dsh-emacs-group-*')
;;   - UI borders (`dsh-emacs-border-*')
;;   - Dividers / meta (`dsh-emacs-divider-face', 'dsh-emacs-meta-face')
;;   - Input prompt / mode-line / tokens

;;; Code:

(defgroup dsh-emacs-faces nil
	"Faces used by `dsh-emacs'."
	:group 'dsh-emacs
	:prefix "dsh-emacs-")

;;; ---------------------------------------------------------------------------
;;; 颜色 token 变量（用户可重定义以改变整体主题）
;;; ---------------------------------------------------------------------------

(defcustom dsh-emacs-color-accent "#0b7285"
	"Primary accent color (title, logo, active prompt)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-accent-dark "#22c3ee"
	"Primary accent color for dark themes."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-border "#b8c1cc"
	"Rounded border color (light)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-border-dark "#3b4252"
	"Rounded border color (dark)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-border-muted "#e0e0e0"
	"Muted border color (light)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-border-muted-dark "#313244"
	"Muted border color (dark)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-user "#0b7285"
	"User message label color (light)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-user-dark "#4dd0e1"
	"User message label color (dark)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-assistant "#52606d"
	"Assistant message label color (light)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-assistant-dark "#a8b3c2"
	"Assistant message label color (dark)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-tool-pending-border "#b45f06"
	"Tool pending border (light)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-tool-pending-border-dark "#f0a63c"
	"Tool pending border (dark)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-tool-pending-bg "#fff7e6"
	"Tool pending background (light)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-tool-pending-bg-dark "#2a2118"
	"Tool pending background (dark)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-tool-success-border "#1a7f37"
	"Tool success border (light)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-tool-success-border-dark "#5dd879"
	"Tool success border (dark)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-tool-success-bg "#e6f7ec"
	"Tool success background (light)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-tool-success-bg-dark "#172821"
	"Tool success background (dark)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-tool-error-border "#c62828"
	"Tool error border (light)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-tool-error-border-dark "#ff6b6b"
	"Tool error border (dark)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-tool-error-bg "#fdecec"
	"Tool error background (light)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-tool-error-bg-dark "#2c1818"
	"Tool error background (dark)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-thinking "#b45f06"
	"Thinking block color (light)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-thinking-dark "#f0a63c"
	"Thinking block color (dark)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-thinking-bg "#fdf6e3"
	"Thinking block background (light)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-thinking-bg-dark "#1f1b16"
	"Thinking block background (dark)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-divider "#d9dee5"
	"Divider color (light)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-divider-dark "#303746"
	"Divider color (dark)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-input-bg "#f8f9fa"
	"Input box background (light)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-input-bg-dark "#1e1e2e"
	"Input box background (dark)."
	:type 'string
	:group 'dsh-emacs-faces)

;;; ---------------------------------------------------------------------------
;;; 品牌 / 强调
;;; ---------------------------------------------------------------------------

(defface dsh-emacs-accent-face
	`((((background light)) :foreground ,dsh-emacs-color-accent :weight bold)
		(((background dark))  :foreground ,dsh-emacs-color-accent-dark :weight bold)
		(t :inherit bold))
	"Accent color (dsh logo, active prompt, header title)."
	:group 'dsh-emacs-faces)

;;; ---------------------------------------------------------------------------
;;; 角色标签
;;; ---------------------------------------------------------------------------

(defface dsh-emacs-user-face
	`((((background light)) :foreground ,dsh-emacs-color-user :weight bold)
		(((background dark))  :foreground ,dsh-emacs-color-user-dark :weight bold)
		(t :inherit font-lock-keyword-face :weight bold))
	"User message label (👤 you)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-user-block-face
	'((t))
	"User message card background (no background, matches default)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-assistant-face
	`((((background light)) :foreground ,dsh-emacs-color-assistant :weight bold)
		(((background dark))  :foreground ,dsh-emacs-color-assistant-dark :weight bold)
		(t :inherit font-lock-string-face :weight bold))
	"Assistant message label (🤖 Assistant)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-assistant-body-face
	'((t))
	"Assistant message body (no background, matches default)."
	:group 'dsh-emacs-faces)

;;; ---------------------------------------------------------------------------
;;; 工具卡（pending / success / error 三态）
;;; ---------------------------------------------------------------------------

(defface dsh-emacs-tool-pending-face
	`((((background light))
		 :foreground ,dsh-emacs-color-tool-pending-border :weight bold)
		(((background dark))
		 :foreground ,dsh-emacs-color-tool-pending-border-dark :weight bold)
		(t :inherit warning))
	"Tool card pending state (running): orange border + orange text (no background)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-tool-success-face
	`((((background light))
		 :foreground ,dsh-emacs-color-tool-success-border :weight bold)
		(((background dark))
		 :foreground ,dsh-emacs-color-tool-success-border-dark :weight bold)
		(t :inherit success))
	"Tool card success state (exit 0): green border + green text (no background)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-tool-error-face
	`((((background light))
		 :foreground ,dsh-emacs-color-tool-error-border :weight bold)
		(((background dark))
		 :foreground ,dsh-emacs-color-tool-error-border-dark :weight bold)
		(t :inherit error))
	"Tool error (exit N≠0 / signal / isError): red border + red text (no background)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-tool-stopped-face
	'((t :inherit font-lock-keyword-face :weight bold))
	"Tool stopped state (⏹ stopped)."
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-tool-icon "#a78bfa"
	"Purple accent for tool icons / titles (dsh web tool purple #a78bfa)."
	:type 'string
	:group 'dsh-emacs-faces)

(defcustom dsh-emacs-color-tool-icon-dark "#b794f6"
	"Tool purple accent for dark themes."
	:type 'string
	:group 'dsh-emacs-faces)

(defface dsh-emacs-tool-icon-face
	`((((background light)) :foreground ,dsh-emacs-color-tool-icon :weight bold)
		(((background dark))  :foreground ,dsh-emacs-color-tool-icon-dark :weight bold)
		(t :inherit bold))
	"Tool card header icon (dsh web purple accent)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-tool-title-face
	'((t :inherit bold))
	"Tool card header title (tool variant name)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-tool-io-face
	'((t :inherit (font-lock-keyword-face :weight bold)))
	"Tool card IN / OUT section labels."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-tool-status-face
	'((t :inherit italic))
	"Tool status suffix (running / exit N / failed, etc.)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-tool-output-face
	'((t :inherit (font-lock-string-face)))
	"Tool invocation arguments / output text."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-tool-running-face
	`((((background light)) :foreground ,dsh-emacs-color-tool-pending-border :weight bold)
		(((background dark))  :foreground ,dsh-emacs-color-tool-pending-border-dark :weight bold)
		(t :inherit font-lock-warning-face :weight bold))
	"Tool running state text (◌ pulse)."
	:group 'dsh-emacs-faces)

;;; ---------------------------------------------------------------------------
;;; todo 计划行
;;; ---------------------------------------------------------------------------

(defface dsh-emacs-todo-text-face
	`((((background light)) :foreground ,dsh-emacs-color-tool-success-border)
		(((background dark))  :foreground ,dsh-emacs-color-tool-success-border-dark)
		(t :inherit default))
	"Todo row title / summary text (green, non-italic)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-todo-check-face
	`((((background light)) :foreground ,dsh-emacs-color-tool-success-border)
		(((background dark))  :foreground ,dsh-emacs-color-tool-success-border-dark)
		(t :inherit success))
	"Todo item checkbox glyph (☑/☐, green)."
	:group 'dsh-emacs-faces)

;;; ---------------------------------------------------------------------------
;;; 思考块
;;; ---------------------------------------------------------------------------

(defface dsh-emacs-thinking-face
	`((((background light))
		 :foreground ,dsh-emacs-color-thinking :weight bold)
		(((background dark))
		 :foreground ,dsh-emacs-color-thinking-dark :weight bold)
		(t :inherit font-lock-builtin-face :weight bold))
	"Thinking block label (dsh web IconThink icon + Think).
Bold, no italic — matching dsh web's thinkingToggle style."
	:group 'dsh-emacs-faces)

;;; ---------------------------------------------------------------------------
;;;  活动组
;;; ---------------------------------------------------------------------------

(defface dsh-emacs-group-face
	`((((background light)) :foreground "#555555" :weight bold)
		(((background dark))  :foreground "#aaaaaa" :weight bold)
		(t :inherit bold))
	"Activity group header (e.g., “2 of 3 completed”)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-group-count-face
	`((((background light)) :foreground "#888888")
		(((background dark))  :foreground "#666666")
		(t :inherit shadow))
	"Activity group count (completed / total)."
	:group 'dsh-emacs-faces)

;;; ---------------------------------------------------------------------------
;;;  UI 边框
;;; ---------------------------------------------------------------------------

(defface dsh-emacs-border-face
	`((((background light)) :foreground ,dsh-emacs-color-border)
		(((background dark))  :foreground ,dsh-emacs-color-border-dark)
		(t :inherit shadow))
	"Rounded border (┌─┐│└─┘)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-border-muted-face
	`((((background light)) :foreground ,dsh-emacs-color-border-muted)
		(((background dark))  :foreground ,dsh-emacs-color-border-muted-dark)
		(t :inherit shadow))
	"Muted border (collapsed / hidden indicator)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-border-tool-face
	'((t :inherit dsh-emacs-border-face))
	"Tool card border (inherits from border-face, overridden by tool state faces)."
	:group 'dsh-emacs-faces)

;;; ---------------------------------------------------------------------------
;;;  元信息 / 分隔线 / 输入
;;; ---------------------------------------------------------------------------

(defface dsh-emacs-divider-face
	`((((background light)) :foreground ,dsh-emacs-color-divider)
		(((background dark))  :foreground ,dsh-emacs-color-divider-dark)
		(t :inherit shadow))
	"Divider (────)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-meta-face
	'((t :inherit font-lock-comment-face))
	"Meta info (inline notes next to labels, idle state)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-timestamp-face
	'((t :inherit shadow))
	"Timestamp face (muted)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-error-face
	'((t :inherit error))
	"Error message."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-running-face
	`((((background light)) :foreground ,dsh-emacs-color-tool-pending-border :weight bold)
		(((background dark))  :foreground ,dsh-emacs-color-tool-pending-border-dark :weight bold)
		(t :inherit font-lock-warning-face))
	"Generating state."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-input-box-face
	`((((background light))
		 :background ,dsh-emacs-color-input-bg :foreground "#1a1a2e")
		(((background dark))
		 :background ,dsh-emacs-color-input-bg-dark :foreground "#cdd6f4")
		(t :inherit shadow))
	"Input box face."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-input-prompt-face
	`((((background light)) :foreground ,dsh-emacs-color-accent :weight bold)
		(((background dark))  :foreground ,dsh-emacs-color-accent-dark :weight bold)
		(t :inherit bold))
	"Input area prompt symbol (❯)."
	:group 'dsh-emacs-faces)

;;; ---------------------------------------------------------------------------
;;;  mode-line / token / cost
;;; ---------------------------------------------------------------------------

(defface dsh-emacs-modeline-face
	`((((background light)) :foreground "#555555")
		(((background dark))  :foreground "#999999")
		(t :inherit shadow))
	"Mode-line stats text."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-modeline-separator-face
	'((t :inherit dsh-emacs-modeline-face))
	"The “•” separator between mode-line segments."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-modeline-token-face
	`((((background light)) :foreground "#888888")
		(((background dark))  :foreground "#777777")
		(t :inherit shadow))
	"Token count in the mode line."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-modeline-cost-face
	`((((background light)) :foreground "#1a7f37")
		(((background dark))  :foreground "#5dd879")
		(t :inherit success))
	"Cost shown in the mode line."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-modeline-ctx-ok-face
	`((((background light)) :foreground "#1a7f37")
		(((background dark))  :foreground "#5dd879")
		(t :inherit success))
	"Context usage < 50%."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-modeline-ctx-warn-face
	`((((background light)) :foreground "#b45f06")
		(((background dark))  :foreground "#f0a63c")
		(t :inherit warning))
	"Context usage 50–80%."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-modeline-ctx-crit-face
	`((((background light)) :foreground "#c62828")
		(((background dark))  :foreground "#ff6b6b")
		(t :inherit error))
	"Context usage > 80%."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-modeline-queue-face
	`((((background light)) :foreground "#b45f06")
		(((background dark))  :foreground "#f0a63c")
		(t :inherit warning))
	"Pending-input queue indicator (`[Q2 S1]') in the mode line."
	:group 'dsh-emacs-faces)

;;; ---------------------------------------------------------------------------
;;;  兼容 face 别名（0.1.0 时代叫 footer）
;;; ---------------------------------------------------------------------------

(define-obsolete-face-alias 'dsh-emacs-footer-face
  'dsh-emacs-modeline-face "0.2.0")
(define-obsolete-face-alias 'dsh-emacs-footer-separator-face
  'dsh-emacs-modeline-separator-face "0.2.0")
(define-obsolete-face-alias 'dsh-emacs-footer-token-face
  'dsh-emacs-modeline-token-face "0.2.0")
(define-obsolete-face-alias 'dsh-emacs-footer-cost-face
  'dsh-emacs-modeline-cost-face "0.2.0")
(define-obsolete-face-alias 'dsh-emacs-footer-ctx-ok-face
  'dsh-emacs-modeline-ctx-ok-face "0.2.0")
(define-obsolete-face-alias 'dsh-emacs-footer-ctx-warn-face
  'dsh-emacs-modeline-ctx-warn-face "0.2.0")
(define-obsolete-face-alias 'dsh-emacs-footer-ctx-crit-face
  'dsh-emacs-modeline-ctx-crit-face "0.2.0")

;;; ---------------------------------------------------------------------------
;;;  Session list faces
;;; ---------------------------------------------------------------------------

(defface dsh-emacs-session-title-face
	'((t :weight bold))
	"Session title in session list."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-session-cwd-face
	'((t :inherit font-lock-string-face))
	"Session CWD in session list (info view)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-session-branch-face
	'((t :inherit font-lock-comment-face))
	"Session git branch in session list (info view)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-session-model-face
	'((t :inherit font-lock-keyword-face))
	"Session model name in session list (info view)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-session-id-face
	'((t :inherit font-lock-comment-face :slant italic))
	"Session ID in session list (info view)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-session-status-face
	'((t :weight bold))
	"Session status indicator."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-muted-face
	'((t :inherit font-lock-comment-face))
	"Muted text (e.g., 'No sessions', time)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-status-running-face
	`((((background light)) :foreground ,dsh-emacs-color-tool-pending-border :weight bold)
		(((background dark))  :foreground ,dsh-emacs-color-tool-pending-border-dark :weight bold)
		(t :inherit warning))
	"Running status indicator (orange)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-status-pending-face
	`((((background light)) :foreground ,dsh-emacs-color-tool-pending-border :weight bold)
		(((background dark))  :foreground ,dsh-emacs-color-tool-pending-border-dark :weight bold)
		(t :inherit warning))
	"Pending/approval status indicator (orange)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-status-idle-face
	'((t :inherit font-lock-comment-face))
	"Idle status indicator (muted)."
	:group 'dsh-emacs-faces)

;;; ---------------------------------------------------------------------------
;;;  Approval prompt faces
;;; ---------------------------------------------------------------------------

(defface dsh-emacs-approval-justification-face
	`((((background light)) :foreground ,dsh-emacs-color-tool-pending-border)
		(((background dark))  :foreground ,dsh-emacs-color-tool-pending-border-dark)
		(t :inherit warning))
	"Approval prompt justification (light orange)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-approval-command-face
	'((t :inherit shadow))
	"Approval prompt tool command (gray)."
	:group 'dsh-emacs-faces)

;;; ---------------------------------------------------------------------------
;;;  Markdown faces
;;; ---------------------------------------------------------------------------

(defface dsh-emacs-markdown-heading-face
	'((t :inherit font-lock-function-name-face :weight bold :height 1.2))
	"Markdown heading."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-markdown-bold-face
	'((t :weight bold))
	"Markdown bold text."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-markdown-italic-face
	'((t :slant italic))
	"Markdown italic text."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-markdown-strikethrough-face
	'((t :strike-through t))
	"Markdown strikethrough text."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-markdown-code-face
	'((t :inherit font-lock-string-face))
	"Markdown inline code."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-markdown-code-block-face
	'((t :inherit font-lock-string-face :background "gray20"))
	"Markdown code block."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-markdown-link-face
	'((t :inherit font-lock-keyword-face :underline t))
	"Markdown link text."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-markdown-link-url-face
	'((t :inherit font-lock-string-face :underline t))
	"Markdown link URL."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-markdown-list-marker-face
	'((t :inherit font-lock-builtin-face :weight bold))
	"Markdown list marker."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-markdown-quote-face
	'((t :inherit font-lock-comment-face :slant italic))
	"Markdown blockquote."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-markdown-strikethrough-face
	'((t :strike-through t))
	"Markdown strikethrough text."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-markdown-table-border-face
	'((t :inherit font-lock-comment-face))
	"Markdown table borders."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-markdown-table-header-face
	'((t :weight bold))
	"Markdown table header cells."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-markdown-divider-face
	'((t :inherit font-lock-comment-face))
	"Markdown horizontal rule."
	:group 'dsh-emacs-faces)

;;; ---------------------------------------------------------------------------
;;;  Misc UI faces
;;; ---------------------------------------------------------------------------

(defface dsh-emacs-header-face
	'((t :inherit font-lock-function-name-face :weight bold :height 1.2))
	"Header text."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-separator-face
	'((t :inherit font-lock-comment-face))
	"Separator lines."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-hint-face
	'((t :inherit font-lock-comment-face :slant italic))
	"Hint text."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-mode-line-buffer-face
	'((t :weight bold))
	"Mode line buffer name."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-mode-line-badge-face
	`((((class color) (background light))
		 :foreground "#ffffff" :background ,dsh-emacs-color-accent :weight bold)
		(((class color) (background dark))
		 :foreground "#04121a" :background ,dsh-emacs-color-accent-dark :weight bold)
		(t :inherit dsh-emacs-accent-face))
	"Mode line dsh brand badge (inverted: white on light bg / dark text on dark bg)."
	:group 'dsh-emacs-faces)

(defface dsh-emacs-mode-line-busy-face
	`((((class color) (background light))
		 :foreground ,dsh-emacs-color-tool-pending-border :weight bold)
		(((class color) (background dark))
		 :foreground ,dsh-emacs-color-tool-pending-border-dark :weight bold)
		(t :inherit font-lock-warning-face :weight bold))
	"Mode line running-state spinner (dsh scrolling animation while running)."
	:group 'dsh-emacs-faces)

(provide 'dsh-emacs-faces)

;;; dsh-emacs-faces.el ends here