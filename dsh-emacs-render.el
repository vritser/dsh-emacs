;;; dsh-emacs-render.el --- Event renderers for dsh-emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.1.0
;; License: GPL-3.0-or-later
;; Package-Requires ((emacs "27.1"))

;;; Commentary:

;; 事件渲染器。参考 agent-shell / pi / opencode 的视觉语言：
;;
;;   * 用户消息 → 卡片背景（淡青色），无重边框
;;   * 助手消息 → 无框，仅 markdown body + 上下分隔
;;   * 思考块 → `<details>`-风格，可折叠，默认折叠
;;   * 工具调用 → 圆角框，按 pending/success/error 状态变色
;;   * 多工具连续调用 → 活动组（Activity Group），显示聚合状态
;; 与 dsh-emacs.el 配合使用。所有渲染函数都期望 buffer-local
;; 变量 `dsh-emacs--session-id'、`dsh-emacs--input-marker' 已被设置。

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'dsh-emacs-ui)
(require 'dsh-emacs-faces)
(require 'dsh-emacs-tokens)
(require 'dsh-emacs-markdown)

;; Defined in dsh-emacs-modeline.el, which loads via dsh-emacs.el after this
;; module.  Called at runtime from turn/end handling and event dispatch.
(declare-function dsh-emacs--ml-busy-set "dsh-emacs-modeline" (flag))
(declare-function dsh-emacs-modeline-note-event "dsh-emacs-modeline" (event))
(declare-function dsh-emacs-modeline-note-request "dsh-emacs-modeline" (event))
(declare-function dsh-emacs-modeline-note-header "dsh-emacs-modeline" (event))

;;; ---------------------------------------------------------------------------
;;; 定制
;;; ---------------------------------------------------------------------------

(defgroup dsh-emacs-render nil
  "Event renderers for `dsh-emacs'."
  :group 'dsh-emacs
  :prefix "dsh-emacs-")

(defcustom dsh-emacs-show-reasoning t
  "Whether to show reasoning (reasoning / thinking) content in the transcript.
On by default, matching dsh web (the web UI always shows the Think row);
set to nil for a leaner transcript."
  :type 'boolean
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-show-tool-calls t
  "Whether to show tool calls (bash / read / write etc.) in the transcript."
  :type 'boolean
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-thinking-expand-by-default nil
  "Whether thinking blocks are expanded by default.
nil = collapsed by default (the collapsed row shows a first-line preview)."
  :type 'boolean
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-thinking-preview-max 48
  "Maximum display width (columns) of the thinking-block first-line preview;
anything longer is truncated with \"...\".  Set to 0 to disable the preview
(the collapsed row then shows only the icon + Think)."
  :type 'integer
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-tool-expand-by-default nil
  "Whether tool calls are expanded by default.
nil = collapsed by default (only tool title + summary are shown)."
  :type 'boolean
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-show-commands t
  "Whether slash commands (/goal, /compact, ...) show in the transcript.
Command `command/run' + `command/done' events render as one flow node:
the run creates the muted label, the done restyles it with a short status
and folds the outcome text into a collapsible body below (collapsed by
default); the error kind turns the node red."
  :type 'boolean
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-assistant-divider nil
  "Whether to draw a divider between assistant message bodies.
Off by default to reduce visual noise."
  :type 'boolean
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-max-tool-result-chars 80
  "Maximum number of characters in the tool-result preview."
  :type 'integer
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-tool-call-chars 100
  "Maximum number of characters in the tool-call arguments preview."
  :type 'integer
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-tool-preview-lines 8
  "Maximum number of lines in the collapsed tool-call preview."
  :type 'integer
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-max-buffer-size 200000
  "Maximum character count of the chat transcript buffer.
When the buffer exceeds this size old content is silently trimmed from the
top to prevent unbounded memory growth and redisplay slowdown in long
sessions.  Set to nil to disable trimming."
  :type '(choice integer (const nil))
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-group-consecutive-tools 3
  "How many consecutive tool calls are grouped into one activity group."
  :type 'integer
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-show-todos t
  "Whether to render the session's todo (plan) rows.
Each `todo_write' snapshot renders ONE row in the transcript (like a tool
card), showing the latest whole checklist; the rows accumulate in the order the
todo events arrive.  Set to nil to suppress todo rows entirely."
  :type 'boolean
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-todo-title "Todo"
  "Title shown on each todo (plan) row header in the transcript."
  :type 'string
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-todo-expand-by-default nil
  "Whether todo rows start expanded showing the checklist.
nil (default): each todo row starts collapsed showing only the header line
(icon + title + progress summary); RET or click expands to reveal the
checklist body.  Set to t to show the full checklist on first render."
  :type 'boolean
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-todo-summary-only nil
  "Whether todo rows show only the progress summary.
When non-nil each row renders as a single passive line carrying the icon +
title and the task count/progress summary, with no per-item checklist body and
no fold toggle (RET/click are inert).  Set to nil to restore the interactive
collapsible checklist."
  :type 'boolean
  :group 'dsh-emacs-render)

;;; ---------------------------------------------------------------------------
;;; 工具 variant / icon / summary
;;; ---------------------------------------------------------------------------

(defconst dsh-emacs--tool-variants
  '(("bash"       . "bash")
    ("pwsh"       . "bash")
    ("read"       . "read")
    ("web_fetch"  . "read")
    ("search"     . "search")
    ("web_search" . "search")
    ("grep"       . "search")
    ("glob"       . "search")
    ("write"      . "write")
    ("edit"       . "edit")
    ("run_code"   . "code")
    ("cordis_package_inspect" . "read")
    ("cordis_runtime_inspect" . "read")
    ("cordis_run" . "others")
    ("cordis_stop" . "others")
    ("cordis_undefine" . "others"))
  "Tool name -> variant mapping.")

(defconst dsh-emacs--tool-name-icon-keys
  '(("web_search" . "web"))
  "Tool name -> icon-key override, consulted before the variant table.
Tools listed here deviate from their variant's default icon, mirroring dsh
web's keyed toolviews (WebRow): web_search uses the meridian-globe family
(`dsh-emacs--tool-icon-svgs' \"web\") while local grep/glob keep the
magnifier family.")

(defconst dsh-emacs--variant-icons
  '(("bash"   . "💻")
    ("read"   . "📖")
    ("search" . "🔍")
    ("web"    . "🌐")
    ("write"  . "✏️")
    ("edit"   . "✏️")
    ("code"   . "</>")
    ("command" . "⚡")
    ("others" . "✨"))
  "Variant -> emoji fallback icon, mirroring dsh web's VariantIcons by meaning:
- bash    = terminal            (IconApiOutline14)
- read    = browse / open book  (IconBrowseOutline16)
- search  = magnifying glass    (IconSearchOutline16)
- web     = meridian globe      (IconGlobeOutline14, web_search's WebRow icon)
- write   = pencil              (IconEditOutline16)
- edit    = pencil              (IconEditOutline16)
- code    = code brackets       (IconCodeOutline16)
- command = lightning           (slash commands, IconFlash16 style)
- others  = sparkle             (IconSparkle16)

The emoji is only a terminal / non-SVG fallback; graphical Emacs renders the
real dsh-web SVG icons (see `dsh-emacs--tool-icon-svgs').")

(defconst dsh-emacs--tool-icon-svgs
  ;; Each SVG template is the exact dsh-web icon (VARIANT_ICONS), with a
  ;; "__C__" placeholder for the fill color.  Path data was extracted from
  ;; dsh-web's compiled icon components (IconApiOutline14, IconBrowseOutline16,
  ;; IconSearchOutline16, IconEditOutline16, IconCodeOutline16, IconSparkle16).
  '(("bash" . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 14 14\" fill=\"none\"><path transform=\"translate(0.6689 1.073)\" d=\"M11.4818 5.57813C11.4818 4.45301 11.4807 3.66237 11.4075 3.05908C11.3359 2.46953 11.2024 2.13852 10.9939 1.89441C10.9247 1.81341 10.8493 1.73801 10.7683 1.66882C10.5242 1.46033 10.1932 1.32686 9.60364 1.25525C9.00034 1.18198 8.20974 1.18091 7.0846 1.18091L5.57813 1.18091C4.45301 1.18091 3.66238 1.18198 3.05908 1.25525C2.46953 1.32686 2.13852 1.46033 1.89441 1.66882C1.81341 1.73801 1.73801 1.81341 1.66882 1.89441C1.46033 2.13852 1.32686 2.46953 1.25525 3.05908C1.18198 3.66238 1.18091 4.45301 1.18091 5.57813L1.18091 6.2771C1.18091 7.40218 1.18197 8.19288 1.25525 8.79614C1.32687 9.38553 1.46036 9.71674 1.66882 9.96082C1.73797 10.0417 1.81347 10.1173 1.89441 10.1864C2.13851 10.3948 2.46965 10.5275 3.05908 10.5991C3.66238 10.6724 4.45298 10.6735 5.57813 10.6735L7.0846 10.6735C8.20977 10.6735 9.00033 10.6724 9.60364 10.5991C10.1931 10.5275 10.5242 10.3948 10.7683 10.1864C10.8493 10.1173 10.9247 10.0417 10.9939 9.96082C11.2024 9.71674 11.3358 9.38553 11.4075 8.79614C11.4808 8.19288 11.4818 7.40218 11.4818 6.2771L11.4818 5.57813ZM12.6627 6.2771C12.6627 7.37222 12.6637 8.247 12.5798 8.93799C12.4942 9.64284 12.3133 10.2359 11.8928 10.7282C11.7834 10.8562 11.6637 10.9751 11.5356 11.0845C11.0434 11.5049 10.4511 11.6867 9.74634 11.7723C9.05525 11.8563 8.17999 11.8552 7.0846 11.8552L5.57813 11.8552C4.48273 11.8552 3.60747 11.8563 2.91638 11.7723C2.21157 11.6867 1.61933 11.5049 1.12708 11.0845C0.99901 10.9751 0.879281 10.8562 0.769898 10.7282C0.349454 10.2359 0.168506 9.64284 0.0828864 8.93799C-0.00101964 8.247 4.88512e-07 7.37222 6.47206e-07 6.2771L6.47206e-07 5.57813C6.47206e-07 4.48273 -0.00106163 3.60747 0.0828864 2.91638C0.168502 2.21168 0.349594 1.61928 0.769898 1.12708C0.879302 0.998981 0.998981 0.879302 1.12708 0.769898C1.61928 0.349594 2.21168 0.168502 2.91638 0.0828864C3.60747 -0.00106163 4.48273 6.47206e-07 5.57813 6.47206e-07L7.0846 6.47206e-07C8.17999 6.47206e-07 9.05525 -0.00106163 9.74634 0.0828864C10.451 0.168505 11.0434 0.349587 11.5356 0.769898C11.6637 0.879302 11.7834 0.998981 11.8928 1.12708C12.3131 1.61928 12.4942 2.21169 12.5798 2.91638C12.6638 3.60747 12.6627 4.48273 12.6627 5.57813L12.6627 6.2771Z\" fill=\"__C__\" stroke=\"none\"/><path transform=\"translate(0.6689 1.073)\" d=\"M6.02607 5.50955L6.44306 5.9274L3.84284 8.52762L3.425 8.11063L3.00715 7.69278L4.77253 5.9274L3.00715 4.16202L3.84284 3.32633L6.02607 5.50955Z\" fill=\"__C__\" stroke=\"none\"/><path transform=\"translate(0.6689 1.073)\" d=\"M9.23789 7.35397L9.23789 8.53488L6.96238 8.53488L6.96238 7.35397L9.23789 7.35397Z\" fill=\"__C__\" stroke=\"none\"/></svg>")
    ("read" . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\"><path d=\"M11.2426 4.80473V6.10551H4.75819V4.80473H11.2426Z\" fill=\"__C__\" stroke=\"none\"/><path d=\"M9.40858 7.84478V9.14557H4.75819V7.84478H9.40858Z\" fill=\"__C__\" stroke=\"none\"/><path d=\"M9.23438 0.546389C10.1941 0.546389 10.9683 0.544914 11.5859 0.611819C12.2161 0.680096 12.7634 0.825745 13.2393 1.17139C13.5172 1.3733 13.7619 1.61812 13.9639 1.896C14.3096 2.37183 14.4551 2.91922 14.5234 3.54932C14.5903 4.16686 14.5889 4.94133 14.5889 5.90088V10.0981C14.5889 11.0576 14.5903 11.8321 14.5234 12.4497C14.4552 13.0798 14.3094 13.6272 13.9639 14.103C13.7619 14.381 13.5172 14.6257 13.2393 14.8276C12.7633 15.1734 12.2163 15.3189 11.5859 15.3872C10.9683 15.4541 10.1942 15.4536 9.23438 15.4536H6.76563C5.80591 15.4536 5.03168 15.4541 4.41407 15.3872C3.78385 15.3189 3.23665 15.1734 2.76074 14.8276C2.48291 14.6257 2.23802 14.3809 2.03614 14.103C1.69066 13.6272 1.54483 13.0798 1.47657 12.4497C1.40973 11.8321 1.41114 11.0576 1.41114 10.0981V5.90088C1.41113 4.94132 1.40966 4.16686 1.47657 3.54932C1.54488 2.91921 1.69042 2.37184 2.03614 1.896C2.2381 1.61807 2.4828 1.37333 2.76074 1.17139C3.23665 0.825682 3.78386 0.680109 4.41407 0.611819C5.03168 0.544905 5.80591 0.546389 6.76563 0.546389H9.23438ZM6.76563 1.896C5.77586 1.896 5.0876 1.89738 4.55957 1.95459C4.0443 2.01043 3.76214 2.11349 3.55469 2.26416C3.39135 2.38284 3.24761 2.52662 3.12891 2.68994C2.97821 2.89736 2.8752 3.17967 2.81934 3.69483C2.76214 4.22279 2.76075 4.91131 2.76074 5.90088V10.0981C2.76074 11.0876 2.76221 11.7762 2.81934 12.3042C2.87516 12.8194 2.97829 13.1026 3.12891 13.3101C3.24754 13.4733 3.39147 13.6172 3.55469 13.7358C3.76213 13.8865 4.04438 13.9896 4.55957 14.0454C5.0876 14.1026 5.77586 14.103 6.76563 14.103H9.23438C10.2242 14.103 10.9124 14.1026 11.4404 14.0454C11.9556 13.9896 12.2379 13.8865 12.4453 13.7358C12.6086 13.6172 12.7525 13.4733 12.8711 13.3101C13.0217 13.1026 13.1248 12.8195 13.1807 12.3042C13.2378 11.7762 13.2393 11.0876 13.2393 10.0981V5.90088C13.2393 4.91131 13.2379 4.22279 13.1807 3.69483C13.1248 3.17969 13.0218 2.89736 12.8711 2.68994C12.7524 2.52667 12.6086 2.38281 12.4453 2.26416C12.2379 2.11355 11.9556 2.01041 11.4404 1.95459C10.9124 1.8974 10.2241 1.896 9.23438 1.896H6.76563Z\" fill=\"__C__\" stroke=\"none\"/></svg>")
    ("search" . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\"><path d=\"M11.894845 6.647401C11.894845 3.725463 9.534486 1.356779 6.623219 1.35657C3.711786 1.35657 1.351635 3.725338 1.351635 6.647401C1.351843 9.569296 3.711911 11.938273 6.623219 11.938273C9.534361 11.938064 11.894637 9.569171 11.894845 6.647401ZM13.245462 6.647401C13.245254 10.317935 10.280401 13.293613 6.623219 13.293821C2.965871 13.293821 0.000204 10.31806 0 6.647401C0 2.976574 2.965746 0 6.623219 0C10.280526 0.000205 13.245462 2.9767 13.245462 6.647401Z\" fill=\"__C__\" stroke=\"none\"/><path d=\"M16.000417 15.041079L15.044449 16.000433L11.530434 12.473588L12.486298 11.514234L16.000417 15.041079Z\" fill=\"__C__\" stroke=\"none\"/></svg>")
    ("web" . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 14 14\" fill=\"none\"><path fill-rule=\"evenodd\" clip-rule=\"evenodd\" d=\"M7.00018 0.353516C10.6708 0.353535 13.6468 3.32958 13.6469 7.00018C13.6468 10.6708 10.6708 13.6468 7.00018 13.6469C3.32957 13.6468 0.353535 10.6708 0.353516 7.00018C0.353535 3.32957 3.32957 0.353531 7.00018 0.353516ZM5.44643 7.59661C5.49463 8.97506 5.70762 10.191 6.02136 11.0793C6.20141 11.5891 6.40328 11.9585 6.59898 12.1889C6.79501 12.4196 6.93213 12.454 7.00018 12.454C7.06822 12.454 7.20533 12.4197 7.40138 12.1889C7.59708 11.9585 7.79895 11.589 7.979 11.0793C8.29274 10.191 8.50574 8.97506 8.55394 7.59661H5.44643ZM1.57861 7.59661C1.80785 9.70467 3.2386 11.4509 5.1715 12.1388C5.07135 11.9317 4.97972 11.7098 4.89746 11.477C4.53084 10.4391 4.30224 9.0828 4.25357 7.59661H1.57861ZM9.74679 7.59661C9.69813 9.0828 9.46952 10.4391 9.1029 11.477C9.0206 11.7099 8.92818 11.9316 8.82797 12.1388C10.7613 11.4511 12.1925 9.70496 12.4218 7.59661H9.74679ZM5.1706 1.8616C3.23814 2.54963 1.80876 4.29604 1.5795 6.40376H4.25357C4.30224 4.91756 4.53083 3.56129 4.89746 2.5234C4.97968 2.29066 5.07051 2.0686 5.1706 1.8616ZM7.00018 1.54637C6.93213 1.54638 6.79503 1.5807 6.59898 1.81145C6.40332 2.04177 6.20139 2.41058 6.02136 2.92012C5.70754 3.80851 5.49461 5.02499 5.44643 6.40376H8.55394C8.50575 5.025 8.29282 3.80851 7.979 2.92012C7.79898 2.41059 7.59705 2.04177 7.40138 1.81145C7.20531 1.58067 7.06823 1.54637 7.00018 1.54637ZM8.82887 1.8616C8.92902 2.0687 9.02064 2.29053 9.1029 2.5234C9.46953 3.56129 9.69812 4.91756 9.74679 6.40376H12.4209C12.1916 4.29575 10.7618 2.54943 8.82887 1.8616Z\" fill=\"__C__\" stroke=\"none\"/></svg>")
    ("write" . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\"><path d=\"M9.94076 1.34942C10.7047 0.90231 11.6503 0.902415 12.4143 1.34942C12.7061 1.52015 12.9688 1.79118 13.3104 2.13284C13.6521 2.47448 13.9231 2.73721 14.0939 3.02894C14.5408 3.79294 14.5409 4.73856 14.0939 5.50251C13.9231 5.79415 13.652 6.05704 13.3104 6.39861L6.65932 13.0497C6.28068 13.4284 6.00695 13.7108 5.66543 13.9097C5.32391 14.1085 4.94315 14.2074 4.42705 14.3498L3.24394 14.6761C2.77527 14.8054 2.34538 14.9262 2.00131 14.9684C1.65196 15.0112 1.17964 15.0013 0.810764 14.6325C0.441921 14.2637 0.432107 13.7913 0.47486 13.442C0.517035 13.0979 0.6379 12.668 0.767181 12.1993L1.09352 11.0162C1.23588 10.5001 1.33481 10.1193 1.5336 9.77784C1.7325 9.43632 2.0149 9.1626 2.39355 8.78395L9.04466 2.13284C9.38625 1.79126 9.64911 1.52016 9.94076 1.34942ZM15.5427 14.8398H7.55223L8.96707 13.425H15.5427V14.8398ZM3.39382 9.78422C2.965 10.213 2.84244 10.3436 2.75709 10.49C2.67183 10.6366 2.61862 10.8079 2.45733 11.3925L2.13099 12.5756C2.00183 13.0439 1.92194 13.3419 1.88863 13.5536C2.10041 13.5204 2.39872 13.4416 2.86764 13.3123L4.05075 12.9859C4.63544 12.8246 4.80669 12.7715 4.95323 12.6862C5.09968 12.6008 5.23022 12.4783 5.65905 12.0494L10.721 6.98644L8.45577 4.72121L3.39382 9.78422ZM11.7 2.57079C11.3774 2.38198 10.9777 2.38198 10.6551 2.57079C10.5602 2.62647 10.4487 2.72931 10.0449 3.13311L9.45604 3.72094L11.7213 5.98617L12.3102 5.39833C12.7139 4.99457 12.8168 4.88307 12.8725 4.78818C13.0613 4.46561 13.0612 4.06585 12.8725 3.74326C12.8169 3.64827 12.7146 3.53752 12.3102 3.13311C11.9057 2.72863 11.795 2.6264 11.7 2.57079Z\" fill=\"__C__\" stroke=\"none\"/></svg>")
    ("edit" . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\"><path d=\"M9.94076 1.34942C10.7047 0.90231 11.6503 0.902415 12.4143 1.34942C12.7061 1.52015 12.9688 1.79118 13.3104 2.13284C13.6521 2.47448 13.9231 2.73721 14.0939 3.02894C14.5408 3.79294 14.5409 4.73856 14.0939 5.50251C13.9231 5.79415 13.652 6.05704 13.3104 6.39861L6.65932 13.0497C6.28068 13.4284 6.00695 13.7108 5.66543 13.9097C5.32391 14.1085 4.94315 14.2074 4.42705 14.3498L3.24394 14.6761C2.77527 14.8054 2.34538 14.9262 2.00131 14.9684C1.65196 15.0112 1.17964 15.0013 0.810764 14.6325C0.441921 14.2637 0.432107 13.7913 0.47486 13.442C0.517035 13.0979 0.6379 12.668 0.767181 12.1993L1.09352 11.0162C1.23588 10.5001 1.33481 10.1193 1.5336 9.77784C1.7325 9.43632 2.0149 9.1626 2.39355 8.78395L9.04466 2.13284C9.38625 1.79126 9.64911 1.52016 9.94076 1.34942ZM15.5427 14.8398H7.55223L8.96707 13.425H15.5427V14.8398ZM3.39382 9.78422C2.965 10.213 2.84244 10.3436 2.75709 10.49C2.67183 10.6366 2.61862 10.8079 2.45733 11.3925L2.13099 12.5756C2.00183 13.0439 1.92194 13.3419 1.88863 13.5536C2.10041 13.5204 2.39872 13.4416 2.86764 13.3123L4.05075 12.9859C4.63544 12.8246 4.80669 12.7715 4.95323 12.6862C5.09968 12.6008 5.23022 12.4783 5.65905 12.0494L10.721 6.98644L8.45577 4.72121L3.39382 9.78422ZM11.7 2.57079C11.3774 2.38198 10.9777 2.38198 10.6551 2.57079C10.5602 2.62647 10.4487 2.72931 10.0449 3.13311L9.45604 3.72094L11.7213 5.98617L12.3102 5.39833C12.7139 4.99457 12.8168 4.88307 12.8725 4.78818C13.0613 4.46561 13.0612 4.06585 12.8725 3.74326C12.8169 3.64827 12.7146 3.53752 12.3102 3.13311C11.9057 2.72863 11.795 2.6264 11.7 2.57079Z\" fill=\"__C__\" stroke=\"none\"/></svg>")
    ("code" . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\"><path d=\"M12.3368 1.53569L11.931 4.43172H14.8086V5.79673H11.7404L11.1962 9.67859H14.2839V11.0436H11.0056L10.4994 14.6529L9.14873 14.4643L9.62731 11.0436H5.75876L5.25252 14.6529L3.90186 14.4643L4.38043 11.0436H1.69141V9.67859H4.57104L5.11417 5.79673H2.21609V4.43172H5.30581L5.73724 1.34713L7.08995 1.53569L6.68414 4.43172H10.5527L10.9841 1.34713L12.3368 1.53569ZM5.94937 9.67859H9.81791L10.361 5.79673H6.49353L5.94937 9.67859Z\" fill=\"__C__\" stroke=\"none\"/></svg>")
    ("command" . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\"><path d=\"M9.64572 1.0455C9.76513 0.755118 10.0095 0.530578 10.309 0.437078C10.6086 0.343578 10.9369 0.394798 11.1939 0.575858L11.2012 0.581418C11.3182 0.661738 11.4221 0.760918 11.5034 0.8755C11.6954 1.14086 11.8542 1.4732 12.0085 1.8645C12.3203 2.6551 12.5387 3.65868 12.7963 5.00636L13.1411 6.51662C13.3881 6.97662 13.2748 7.53122 12.8678 7.86842C12.4607 8.20542 11.9025 8.19562 11.5073 7.84522C11.475 7.81655 11.4443 7.78658 11.4152 7.75542C11.4172 8.25776 11.3912 8.75092 11.3373 9.22898C11.2168 10.2971 11.0096 11.2154 10.7187 11.9567C10.5838 12.3118 10.3567 12.6263 10.0195 12.8129C9.92472 12.8645 9.82446 12.9061 9.72037 12.9368C9.82774 13.3274 9.86604 13.7345 9.83316 14.1389C9.80302 14.5069 9.62146 14.8444 9.32762 15.0619C9.03356 15.2793 8.65482 15.3692 8.27122 15.2454C7.87092 15.116 7.52282 14.872 7.26235 14.5431C6.89096 14.0741 6.55986 13.2548 6.16811 11.9501C5.80842 10.7459 5.40551 9.12869 4.97117 7.10983C4.86597 6.62643 4.98747 6.12163 5.29587 5.74463C5.60427 5.36763 6.06447 5.16503 6.53547 5.19483C7.22692 5.23743 7.92050 5.30787 8.60580 5.40420C8.62320 5.31802 8.64380 5.23258 8.66757 5.14810C8.69923 5.08838 8.71202 5.02050 8.70402 4.95382C8.68602 4.79682 8.55462 4.67382 8.41242 4.58502C8.29972 4.51512 8.17252 4.44762 8.03562 4.39882C7.76116 4.30336 7.57267 4.01694 7.56703 3.73038C7.56103 3.41998 7.68723 3.12158 7.92803 2.91498C8.14663 2.72838 8.43559 2.64336 8.71785 2.68403C9.14985 2.74463 9.48305 2.83943 9.64572 1.0455ZM11.9092 9.31463C11.8775 9.97603 11.6655 10.5722 11.3551 11.0817C11.1287 11.4805 10.8322 11.8266 10.4862 12.0999C10.3972 12.1841 10.3009 12.2605 10.1987 12.328C10.5802 13.5469 10.8160 14.1493 10.9275 14.1975C11.4897 14.4287 12.0083 14.0268 12.0416 13.4145C12.0657 12.9633 11.9724 12.3789 11.7989 11.7176C11.7692 11.6139 11.7377 11.5103 11.7043 11.4070C12.0070 11.0933 12.2912 10.7631 12.4902 10.3871C12.7589 9.87770 12.8951 9.32482 12.8930 8.76790C12.7832 8.96782 12.6543 9.15691 12.5087 9.32210C12.3467 9.51423 12.1243 9.65222 11.9092 9.31463Z\" fill=\"__C__\" stroke=\"none\"/></svg>")
    ("others" . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\"><path d=\"M6.1 3.1Q6.6 7.8 11.3 8.3Q6.6 8.8 6.1 13.5Q5.6 8.8 0.9 8.3Q5.6 7.8 6.1 3.1Z\" fill=\"__C__\" stroke=\"none\"/><path d=\"M11.9 1Q12.2 3.7 14.9 4Q12.2 4.3 11.9 7Q11.6 4.3 8.9 4Q11.6 3.7 11.9 1Z\" fill=\"__C__\" stroke=\"none\"/><path d=\"M12.5 9.4Q12.7 11.4 14.7 11.6Q12.7 11.8 12.5 13.8Q12.3 11.8 10.3 11.6Q12.3 11.4 12.5 9.4Z\" fill=\"__C__\" stroke=\"none\"/></svg>"))
  "Variant -> dsh-web SVG icon template, with a \"__C__\" fill placeholder.
Graphical Emacs renders these via `create-image'; terminal Emacs falls back to
the emoji in `dsh-emacs--variant-icons'.  The \"web\" key (meridian globe,
IconGlobeOutline14) is selected for web_search through
`dsh-emacs--tool-name-icon-keys', mirroring dsh web's WebRow.")

(defconst dsh-emacs--think-icon-svg-template
  "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 14 14\" fill=\"none\"><path d=\"M7.06431 5.93342C7.68763 5.93342 8.19307 6.43904 8.19322 7.06233C8.19322 7.68573 7.68772 8.19123 7.06431 8.19123C6.44099 8.19113 5.9354 7.68567 5.9354 7.06233C5.93555 6.43911 6.44108 5.93353 7.06431 5.93342Z\" fill=\"__C__\" stroke=\"none\"/><path fill-rule=\"evenodd\" clip-rule=\"evenodd\" d=\"M8.6815 0.963693C10.1169 0.447019 11.6266 0.374829 12.5633 1.31135C13.5 2.24805 13.4277 3.75776 12.911 5.19319C12.7126 5.74431 12.4386 6.31796 12.0965 6.89729C12.4969 7.54638 12.8141 8.19018 13.036 8.80647C13.5527 10.2419 13.6251 11.7516 12.6883 12.6883C11.7516 13.625 10.242 13.5527 8.8065 13.036C8.19022 12.8141 7.54641 12.4969 6.89732 12.0965C6.31797 12.4386 5.74435 12.7125 5.19322 12.911C3.75777 13.4276 2.2481 13.5 1.31138 12.5633C0.374859 11.6266 0.447049 10.1168 0.963724 8.68147C1.17185 8.10338 1.46321 7.50063 1.82896 6.8924C1.52182 6.35711 1.27235 5.82825 1.08872 5.31819C0.572068 3.88278 0.499714 2.37306 1.43638 1.43635C2.37308 0.499655 3.8828 0.572044 5.31822 1.08869C5.82828 1.27232 6.35715 1.5218 6.89243 1.82893C7.50066 1.46318 8.10341 1.17181 8.6815 0.963693ZM11.3573 8.01154C10.9083 8.62253 10.3901 9.22873 9.80943 9.8094C9.22877 10.3901 8.62255 10.9083 8.01158 11.3572C8.4257 11.5841 8.8287 11.7688 9.21275 11.9071C10.5456 12.3868 11.4246 12.2547 11.8397 11.8397C12.2548 11.4246 12.3869 10.5456 11.9071 9.21272C11.7688 8.82866 11.5841 8.42568 11.3573 8.01154ZM2.56529 8.02912C2.37344 8.39322 2.21495 8.74796 2.09263 9.08772C1.61291 10.4204 1.74512 11.2995 2.16001 11.7147C2.57505 12.1297 3.45415 12.2618 4.78697 11.7821C5.11057 11.6656 5.44786 11.5164 5.7938 11.3367C5.249 10.9223 4.70922 10.4533 4.19029 9.9344C3.57578 9.31987 3.03169 8.67633 2.56529 8.02912ZM6.90708 3.2469C6.24065 3.70479 5.5646 4.26321 4.91392 4.91389C4.26325 5.56456 3.70482 6.24063 3.24693 6.90705C3.72674 7.63325 4.32777 8.37459 5.03892 9.08576C5.64943 9.69627 6.28183 10.2265 6.90806 10.6678C7.59368 10.2025 8.2908 9.63076 8.96079 8.96076C9.6308 8.29075 10.2025 7.59366 10.6678 6.90803C10.2265 6.2818 9.69631 5.6494 9.08579 5.03889C8.37462 4.32773 7.63328 3.72672 6.90708 3.2469ZM11.7147 2.15998C11.2996 1.74509 10.4204 1.61288 9.08775 2.0926C8.74835 2.21479 8.39382 2.37271 8.03013 2.56428C8.67728 3.03065 9.31995 3.5758 9.93443 4.19026C10.4534 4.7092 10.9223 5.24896 11.3368 5.79377C11.5164 5.44785 11.6656 5.11052 11.7821 4.78694C12.2618 3.45416 12.1297 2.57502 11.7147 2.15998ZM4.91197 2.2176C3.57922 1.73788 2.70004 1.86995 2.28501 2.28498C1.87001 2.70003 1.73791 3.5792 2.21763 4.91194C2.31709 5.18822 2.44112 5.47427 2.58677 5.7674C3.01931 5.1887 3.51474 4.6158 4.06529 4.06526C4.61584 3.5147 5.18872 3.01928 5.76743 2.58674C5.47431 2.4411 5.18824 2.31706 4.91197 2.2176Z\" fill=\"__C__\" stroke=\"none\"/></svg>"
  "dsh web's IconThinkOutline14 (the ReasoningRow sparkle icon) as an SVG
template with a \"__C__\" fill placeholder.  Graphical Emacs renders it via
`create-image'; terminal Emacs falls back to the \"✶\" glyph.")

(defcustom dsh-emacs-tool-titles
  '(("pwsh" . "PowerShell"))
  "Alist of tool name -> display title overrides.
Tools not listed here show a humanized name (\"grep\" -> \"Grep\",
\"web_search\" -> \"Web Search\") while keeping their variant icon, so
distinct tools never share a display name just because they share an
icon.  Add your own entries to curate custom tool names."
  :type '(alist :key-type string :value-type string)
  :group 'dsh-emacs-render)

(defconst dsh-emacs--summary-keys
  '(("bash"   . ("description" "command"))
    ("read"   . ("path" "file_path" "url"))
    ("search" . ("query" "pattern" "url"))
    ("write"  . ("path" "file_path"))
    ("edit"   . ("path" "file_path"))
    ("code"   . ("description"))
    ("others" . ()))
  "Variant -> summary key priority list.")

;;; ---------------------------------------------------------------------------
;;; alist helpers (internal)
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render--aget (key alist)
  "Return KEY's value from ALIST (a list or vector of (KEY . VALUE) cells).
Accept both string and symbol keys because `json-read' normally produces
symbol-keyed alists while renderer call sites use JSON field names."
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
    (and (consp entry) (cdr entry))))

(defun dsh-emacs-render--aget-nested (path alist)
  "Walk PATH (list of keys) inside ALIST and return the value, or nil."
  (let ((cur alist))
    (dolist (key path cur)
      (setq cur (if (or (consp cur) (vectorp cur))
                    (dsh-emacs-render--aget key cur)
                  nil)))))

(defun dsh-emacs-render--json-bool (value)
  "JSON bool (`t' or `:json-false') -> Elisp bool."
  (and value (not (eq value :json-false))))

;;; ---------------------------------------------------------------------------
;;; 工具分类与摘要
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render--tool-icon-svg (variant color &optional tool-name)
  "Return the dsh-web SVG icon for VARIANT, filled with COLOR.
TOOL-NAME selects a per-tool icon override (`dsh-emacs--tool-name-icon-keys')
when the tool deviates from its variant's default icon (web_search uses the
meridian globe; grep/glob keep the magnifier family)."
  (let* ((icon-key (or (and tool-name
                            (cdr (assoc tool-name dsh-emacs--tool-name-icon-keys)))
                       variant))
         (template (cdr (assoc icon-key dsh-emacs--tool-icon-svgs))))
    (when template
      (replace-regexp-in-string "__C__" color template t t))))

(defun dsh-emacs-render--tool-icon (variant &optional tool-name)
  "Return VARIANT's icon as a display string.
TOOL-NAME picks a per-tool icon override (`dsh-emacs--tool-name-icon-keys').
In graphical Emacs with SVG support this is the real dsh-web SVG image;
otherwise it falls back to the emoji glyph in `dsh-emacs--variant-icons'."
  (let* ((icon-key (or (and tool-name
                            (cdr (assoc tool-name dsh-emacs--tool-name-icon-keys)))
                       variant))
         (glyph (or (cdr (assoc icon-key dsh-emacs--variant-icons)) "🔧")))
    (if (and (display-graphic-p)
             (fboundp 'image-type-available-p)
             (image-type-available-p 'svg))
        (condition-case nil
            (let* ((fg (face-foreground 'dsh-emacs-tool-icon-face nil t))
                   (color (if (and fg (not (equal fg "unspecified")))
                              fg
                            "#a78bfa")))
              (propertize glyph
                          'display
                          (create-image
                           (dsh-emacs-render--tool-icon-svg variant color tool-name)
                           'svg t :ascent 'center :height 1.0)))
          (error glyph))
      glyph)))

(defun dsh-emacs-render--think-icon-svg (color)
  "Return the dsh-web IconThinkOutline14 sparkle icon filled with COLOR."
  (replace-regexp-in-string "__C__" color dsh-emacs--think-icon-svg-template t t))

(defun dsh-emacs-render--think-icon ()
  "Return the Thinking row leading glyph as a display string.
In graphical Emacs with SVG support this is the real dsh-web IconThinkOutline14
sparkle, tinted with the thinking color (matching `dsh-emacs-thinking-face');
otherwise it falls back to the \"✶\" glyph used by terminal Emacs."
  (if (and (display-graphic-p)
           (fboundp 'image-type-available-p)
           (image-type-available-p 'svg))
      (condition-case nil
          (let* ((fg (face-foreground 'dsh-emacs-thinking-face nil t))
                 (color (if (and fg (not (equal fg "unspecified")))
                            fg
                          "#b45f06")))
            (propertize "✶"
                        'display
                        (create-image
                         (dsh-emacs-render--think-icon-svg color)
                         'svg t :ascent 'center :height 1.0)))
        (error "✶"))
    "✶"))

(defconst dsh-emacs--todo-icon-svg-template
  "<svg width=\"14\" height=\"14\" viewBox=\"0 0 14 14\" fill=\"none\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M13.3277 9.69629V10.976H7.28086V9.69629H13.3277Z\" fill=\"__C__\"/><path d=\"M13.3277 2.97256V4.25225H7.28086V2.97256H13.3277Z\" fill=\"__C__\"/><path d=\"M4.64512 10.336C4.64505 9.62755 4.07081 9.05322 3.3623 9.05322C2.65386 9.05329 2.07956 9.62759 2.07949 10.336C2.07949 11.0445 2.65382 11.6188 3.3623 11.6188C4.07085 11.6188 4.64512 11.0446 4.64512 10.336ZM5.92559 10.336C5.92559 11.7515 4.77777 12.8993 3.3623 12.8993C1.94689 12.8993 0.799805 11.7515 0.799805 10.336C0.799871 8.92066 1.94693 7.7736 3.3623 7.77354C4.77773 7.77354 5.92552 8.92062 5.92559 10.336Z\" fill=\"__C__\"/><path d=\"M4.64531 3.6123C4.6453 2.90382 4.07098 2.32949 3.3625 2.32949C2.65403 2.32951 2.0797 2.90383 2.07969 3.6123C2.07969 4.32079 2.65402 4.8951 3.3625 4.89512C4.07099 4.89512 4.64531 4.3208 4.64531 3.6123ZM5.925 3.6123C5.925 5.02772 4.77792 6.1748 3.3625 6.1748C1.9471 6.17479 0.8 5.02771 0.8 3.6123C0.800013 2.19691 1.9471 1.04982 3.3625 1.0498C4.77791 1.0498 5.92499 2.1969 5.925 3.6123Z\" fill=\"__C__\"/></svg>"
  "dsh web's plan/todo icon (a checklist: two rows + bullet marks) as an SVG
template with a \"__C__\" fill placeholder.  The color comes from the surrounding
line's face; graphical Emacs renders it via `create-image', terminal Emacs
falls back to a list glyph.")

(defun dsh-emacs-render--todo-icon-svg (color)
  "Return the dsh-web plan checklist icon filled with COLOR."
  (replace-regexp-in-string "__C__" color dsh-emacs--todo-icon-svg-template t t))

(defun dsh-emacs-render--todo-icon ()
  "Return the todo row leading glyph as a display string.
In graphical Emacs with SVG support this is the real dsh-web plan checklist
icon, tinted with the tool purple accent (`dsh-emacs-tool-icon-face'); it is
distinct from the green row text.  Terminal Emacs falls back to the \"▤\"
glyph carrying that same face."
  (let ((glyph (if (and (display-graphic-p)
                        (fboundp 'image-type-available-p)
                        (image-type-available-p 'svg))
                   (condition-case nil
                       (let* ((fg (face-foreground 'dsh-emacs-tool-icon-face nil t))
                              (color (if (and fg (not (equal fg "unspecified")))
                                         fg
                                       "#a78bfa")))
                         (propertize "▤"
                                     'display
                                     (create-image
                                      (dsh-emacs-render--todo-icon-svg color)
                                      'svg t :ascent 'center :height 1.0)))
                     (error "▤"))
                 "▤")))
    (propertize glyph 'face 'dsh-emacs-tool-icon-face)))

(defun dsh-emacs-render--tool-variant (tool-name)
  "Return (VARIANT . ICON) for TOOL-NAME.
ICON is a display string: the real dsh-web SVG image in graphical Emacs, or
the emoji fallback otherwise."
  (let* ((variant (or (cdr (assoc tool-name dsh-emacs--tool-variants)) "others"))
         (icon (dsh-emacs-render--tool-icon variant tool-name)))
    (cons variant icon)))

(defun dsh-emacs-render--humanize-name (name)
  "Humanize TOOL-NAME for display: split on _/-, capitalize each word.
Returns \"Tool\" for empty or missing names."
  (if (or (null name) (string-empty-p name))
      "Tool"
    (mapconcat #'capitalize (split-string name "[_-]+" t) " ")))

(defun dsh-emacs-render--tool-title (tool-name)
  "Display title for TOOL-NAME, independent of its icon variant.
Uses `dsh-emacs-tool-titles' overrides, else a humanized name, so
grep / glob / web_search all keep the search magnifier icon but show
distinct titles."
  (or (cdr (assoc tool-name dsh-emacs-tool-titles))
      (dsh-emacs-render--humanize-name tool-name)))

(defun dsh-emacs-render--first-line (text)
  "First line of TEXT, trimmed."
  (let ((nl (string-match "\n" text)))
    (if nl (string-trim (substring text 0 nl)) (string-trim text))))

(defun dsh-emacs-render--trim (text limit)
  "Trim TEXT to LIMIT chars on one line, append \"…\" if cut."
  (let* ((one-line (replace-regexp-in-string "[ \t]+" " "
                                          (replace-regexp-in-string "[\n\r]+" " " text)))
         (one-line (string-trim one-line)))
    (if (> (length one-line) limit)
        (concat (substring one-line 0 limit) "…")
      one-line)))

(defun dsh-emacs-render--first-sentence (text)
  "Return the first sentence of TEXT, or nil.
A sentence ends at the first `.', `!', `?', Chinese `。' / `！' / `？', or a
newline.  The terminating punctuation is kept, newlines are flattened to a
space.  Empty/whitespace-only TEXT yields nil."
  (when (and (stringp text) (not (string-empty-p text)))
    (let* ((end (string-match "[.!?。！？\n]" text))
           (first (if end (substring text 0 (1+ end)) text))
           (first (replace-regexp-in-string "[\n\r]+" " " first))
           (first (string-trim first)))
      (and (not (string-empty-p first)) first))))

(defun dsh-emacs-render--thinking-preview (text)
  "Return the collapse-time preview for reasoning TEXT.
The preview is the first sentence, truncated to `dsh-emacs-thinking-preview-max'
display columns with an ASCII \"...\" when it is too long (so a CJK-heavy
sentence is cut at the box width rather than overflowing).  Returns nil when
there is no previewable content."
  (let ((first (dsh-emacs-render--first-sentence text)))
    (when (and first (> dsh-emacs-thinking-preview-max 0))
      (truncate-string-to-width first dsh-emacs-thinking-preview-max nil nil "..."))))

(defun dsh-emacs-render--tool-summary (variant args-raw)
  "Extract single-line summary from ARGS-RAW (JSON string) for VARIANT."
  (when (and args-raw (not (string-empty-p args-raw)) (not (string= args-raw "{}")))
    (let* ((parsed (condition-case nil (json-read-from-string args-raw) (error nil)))
           (keys (cdr (assoc variant dsh-emacs--summary-keys))))
      (when (and parsed (listp parsed))
        (or
         (catch 'found
           (dolist (key keys)
             (let ((val (dsh-emacs-render--aget key parsed)))
               (when (and (stringp val) (not (string-empty-p val)))
                 (throw 'found (dsh-emacs-render--first-line val))))))
         (catch 'found
           (dolist (pair parsed)
             (let ((v (cdr pair)))
               (when (and (stringp v) (not (string-empty-p v)))
                 (throw 'found (dsh-emacs-render--first-line v)))))))))))

(defun dsh-emacs-render--tool-body-text (variant args-raw)
  "Format the args section of a tool card body."
  (let* ((parsed (condition-case nil (json-read-from-string args-raw) (error nil)))
         (command (and parsed (listp parsed)
                       (or (dsh-emacs-render--aget "command" parsed)
                           (dsh-emacs-render--aget "code" parsed)))))
    (cond
     ((and (stringp command) (not (string-empty-p command)))
      (concat "$ " command))
     ((and parsed (listp parsed))
      (let ((json-encoding-pretty-print t))
        (json-encode parsed)))
     (t (or args-raw "")))))

(defun dsh-emacs-render--tool-result-preview (text)
  "Format TEXT as a tool result body (max ~`dsh-emacs-max-tool-result-chars' chars)."
  (let* ((lines (split-string text "\n" t))
         (first (or (car lines) ""))
         (line (dsh-emacs-render--trim first dsh-emacs-max-tool-result-chars)))
    (concat line (when (> (length lines) 1) " …"))))

;;; ---------------------------------------------------------------------------
;;; content block extraction
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render--text-from-content (content)
  "Concatenate all \"text\" blocks from CONTENT (alist/vector)."
  (let ((parts '()))
    (dolist (block (append content nil))
      (when (and (consp block)
                 (equal (dsh-emacs-render--aget "type" block) "text"))
        (push (dsh-emacs-render--aget "text" block) parts)))
    (mapconcat #'identity (nreverse parts) "\n")))

(defun dsh-emacs-render--reasoning-from-content (content)
  "Concatenate all \"reasoning\" blocks from CONTENT."
  (let ((parts '()))
    (dolist (block (append content nil))
      (when (and (consp block)
                 (equal (dsh-emacs-render--aget "type" block) "reasoning"))
        (push (dsh-emacs-render--aget "text" block) parts)))
    (mapconcat #'identity (nreverse parts) "\n")))

;;; ---------------------------------------------------------------------------
;;; 时间戳
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render--event-time (event)
  "HH:MM:SS string from event's epoch-ms `time' field, or nil."
  (let ((time (dsh-emacs-render--aget "time" event)))
    (when (and (integerp time) (> time 0))
      (format-time-string "%H:%M:%S" (/ time 1000.0)))))

(defun dsh-emacs-render--event-seq (event)
  "Return the event seq."
  (dsh-emacs-render--aget "seq" event))

(defun dsh-emacs-render--event-data (event)
  "Return the event data alist."
  (dsh-emacs-render--aget "data" event))

;;; ---------------------------------------------------------------------------
;;; 渲染原语
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render--make-namespace ()
  "Return the namespace string for fragments of the current session."
  (format "sess-%s" (or (and (boundp 'dsh-emacs--session-id) dsh-emacs--session-id) "global")))

(defun dsh-emacs-render--make-block-id (event)
  "Return a block-id string for the event (using seq)."
  (let ((seq (dsh-emacs-render--event-seq event)))
    (format "evt-%s" (or seq (random 999999)))))

(defun dsh-emacs-render--face-matches-prompt-p (face)
  "Return non-nil when FACE contains `dsh-emacs-input-prompt-face'."
  (cond
   ((eq face 'dsh-emacs-input-prompt-face) t)
   ((listp face) (memq 'dsh-emacs-input-prompt-face face))
   (t nil)))

(defun dsh-emacs-render--input-anchor-pos ()
  "Return the buffer position of the internal input prompt, or nil.
The anchor is the `❯ ' prompt of the editable input line.  It is always the
last `dsh-emacs-input-prompt-face' run in the buffer because every chat
message is inserted strictly above it."
  (let ((pos (point-max))
        (found nil))
    (while (and (not found) pos (> pos (point-min)))
      (setq pos (previous-single-property-change pos 'face))
      (when (and pos (> pos (point-min)))
        (when (dsh-emacs-render--face-matches-prompt-p
               (get-text-property pos 'face))
          (setq found pos))))
    found))

(defun dsh-emacs-render--window-at-bottom-p (window anchor)
  "Return non-nil when WINDOW currently shows the bottom of the transcript.
True when the anchor region is within (a window-height plus slack) of
logical lines below the window start.  The slack absorbs message/chunk
insertions that push the anchor down between follow passes while still
leaving manually scrolled-up windows untouched."
  (ignore-errors
    (let ((start (window-start window)))
      (and (<= start anchor)
           (<= (count-lines start anchor)
               (+ (max 1 (window-text-height window)) 10))))))

(defun dsh-emacs-render--follow-stream ()
  "Scroll transcript windows to keep the newest content visible above input.
Agent-shell style: a window follows the stream when its bottom reaches the
input anchor AND the user is not reading up there (the window is not
selected, or the window's point already sits in the input area).  Windows
the user scrolled up or clicked into are left alone.  For the selected
window (inline input mode) the buffer point is never moved: the view is
re-pinned via `set-window-start' while the user keeps typing."
  (let ((anchor (or (dsh-emacs-render--input-anchor-pos) (point-max))))
    (dolist (window (get-buffer-window-list (current-buffer) nil t))
      (when (window-live-p window)
        (ignore-errors
          (when (and (dsh-emacs-render--window-at-bottom-p window anchor)
                     (or (not (eq window (selected-window)))
                         (>= (window-point window) anchor)))
            (save-excursion
              (goto-char anchor)
              (forward-line (- (1- (max 1 (window-text-height window)))))
              (set-window-start window (max (point-min) (point)) t))
            ;; Keep the pinned viewer's cursor at the input anchor; never move
            ;; the buffer point of the selected inline-input window while
            ;; typing.
            (unless (eq window (selected-window))
              (set-window-point window anchor))))))))

(defun dsh-emacs-render--input-insert-point ()
  "Return the start of the editable prompt line, or nil.
Rendered transcript blocks must be inserted before this line.  Do not move
back one line: after the first reply that would point inside the previous
assistant body and reverse the order of subsequent replies.

The live prompt marker is preferred; when it is missing or points into
another buffer, the anchor is located again by the prompt face so messages
can never be appended below the input area."
  (or
   ;; 1. Live marker pointing into the current buffer.
   (let ((m (and (boundp 'dsh-emacs--input-marker)
                 (markerp dsh-emacs--input-marker)
                 dsh-emacs--input-marker)))
     (when (and m (eq (marker-buffer m) (current-buffer)))
       (save-excursion
         (goto-char (marker-position m))
         (line-beginning-position))))
   ;; 2. Last prompt-face run: the anchor itself.
   (when-let* ((anchor (dsh-emacs-render--input-anchor-pos)))
     (save-excursion
       (goto-char anchor)
       (line-beginning-position)))))

(defun dsh-emacs-render--insert-read-only (text &optional face)
  "Insert TEXT as read-only with optional FACE."
  (let ((len (length text))
        (txt (copy-sequence text)))
    (add-text-properties 0 len '(read-only t front-sticky (read-only)) txt)
    (when face
      (add-text-properties 0 len (list 'face face) txt))
    (insert txt)))

(defun dsh-emacs-render--insert-divider (&optional position)
  "Insert a subtle divider at POSITION when dividers are enabled."
  (when dsh-emacs-assistant-divider
    (let* ((w (max 40 (- (window-width) 4)))
           (line (concat (propertize (make-string w ?─)
                                    'face 'dsh-emacs-divider-face))))
      (let ((inhibit-read-only t))
        (when position (goto-char position))
        (insert line "\n")))))

(defun dsh-emacs-render--insert-chat-message (text face insert-point event-id &optional user-message)
  "Insert TEXT as a read-only, background-colored chat message.
FACE is applied to the message body.  EVENT-ID is stored for navigation.
The prompt remains after the message and each message ends with a newline,
so subsequent messages are appended in history order.  Blank lines left by
the previous content are consumed so everything stacks flush — except
around a user message (USER-MESSAGE non-nil), which keeps one blank line
above AND is marked so the NEXT insertion keeps one blank line below it
(see `dsh-emacs-ui--blank-above-preserve')."
  (when (and (stringp text) (not (string-empty-p text)))
    ;; Rendering happens from an asynchronous callback.  Never leave point at
    ;; the transcript insertion position; the user's cursor belongs after ❯.
    (save-excursion
      (let ((inhibit-read-only t))
        (if insert-point
            (progn (goto-char insert-point) (beginning-of-line))
          ;; Robust fallback: never append below the input when the prompt
          ;; marker was unavailable to the caller.
          (if-let* ((anchor (dsh-emacs-render--input-anchor-pos)))
              (progn (goto-char anchor) (beginning-of-line))
            (goto-char (point-max))))
        ;; Flush against previous content, but keep one blank line above when
        ;; this is a user message, or when the previous entry was one.
        (dsh-emacs-ui--consume-blanks-above
         (if (or user-message (dsh-emacs-ui--blank-above-preserve)) 1 0))
        (let ((start (point))
              (text-end (progn (insert text) (point))))
          (unless (string-suffix-p "\n" text)
            (insert "\n"))
          ;; Trailing separator: consumed by the next content if any, or left
          ;; as spacing before the input area.
          (insert "\n")
          (let ((end (point)))
            (put-text-property start end 'read-only t)
            (put-text-property start end 'front-sticky '(read-only))
            ;; Add the background only to the message TEXT, never to the
            ;; trailing blank separator line, so blank lines stay transparent.
            (add-face-text-property start text-end face t)
            (when user-message
              ;; Marker consulted by `dsh-emacs-ui--blank-above-preserve':
              ;; whatever is inserted next keeps one blank line below the
              ;; user message.
              (put-text-property start text-end 'dsh-emacs-user-message t))
            (when event-id
              (put-text-property start end 'dsh-emacs-event-block event-id))))))))

;;; ---------------------------------------------------------------------------
;;; 公共助手：tool state tracking
;;; ---------------------------------------------------------------------------

(defvar-local dsh-emacs--anchor-seq 0
  "Seq of the last stably rendered event in the transcript.
Used for incremental rendering.")

(defvar-local dsh-emacs--streaming-assistant nil
  "Current assistant stream state, or nil.
The plist contains :key, :start, :end, :event-id and :raw.  The body between
:start and :end is kept as raw Markdown while chunks arrive, then rewritten
in place by `dsh-emacs-markdown-replace-markup'.")

(defvar-local dsh-emacs--streaming-thinking nil
  "Current live reasoning/Think block stream state, or nil.
The plist contains :key, :label-start, :start, :end and :raw.  Reasoning
deltas grow a raw body below the \"✶ Think\" header; on finalization
(`block-end' or `assistant/message') the raw region is replaced by the
collapsible Think fragment.")

(defvar-local dsh-emacs--tool-states (make-hash-table :test 'equal)
  "Map from toolCallId -> plist (:state :variant :title :summary :args :result).")

(defvar-local dsh-emacs--group-counter 0
  "Auto-incremented id for activity groups.")

(defvar-local dsh-emacs--current-group-id nil
  "Id of the currently open activity group, if any.")

(defvar-local dsh-emacs--current-group-count 0
  "Number of tool calls folded into the current activity group.")

(defvar-local dsh-emacs--current-group-completed 0
  "Number of tool calls in current group that have completed.")

(defvar-local dsh-emacs--command-blocks (make-hash-table :test 'equal)
  "Map from commandId -> (NS BLOCK-ID LABEL) of rendered slash-command nodes.
`command/run' creates the entry and the fragment; `command/done' (matched
by commandId) finds the entry to restyle the same node.")

(defvar-local dsh-emacs--pending-command nil
  "When non-nil, an optimistic slash-command row rendered before the RPC round-trip.
Value is (TEMP-COMMAND-ID LABEL) where TEMP-COMMAND-ID is the temporary key
used in `dsh-emacs--command-blocks' and LABEL is the display name.
The real `command/run' event replaces this entry; on RPC error or admission
miss the entry is cleaned up.")

(defun dsh-emacs-render--reset-tool-tracking ()
  "Reset tool tracking state. Called on full transcript reload."
  (setq dsh-emacs--streaming-assistant nil
        dsh-emacs--streaming-thinking nil
        dsh-emacs--tool-states (make-hash-table :test 'equal)
        dsh-emacs--command-blocks (make-hash-table :test 'equal)
        dsh-emacs--command-spinners (make-hash-table :test 'equal)
        dsh-emacs--pending-command nil
        dsh-emacs--group-counter 0
        dsh-emacs--current-group-id nil
        dsh-emacs--current-group-count 0
        dsh-emacs--current-group-completed 0)
  ;; Todo strip folds its snapshot from replayed `tool/call' events, so clear
  ;; the state and the fragment; the replay rebuilds it.
  (when (boundp 'dsh-emacs--todo-namespace)
    (dsh-emacs-render-todo-clear)))

(defun dsh-emacs-render--tool-state (tool-call-id)
  "Return the tracked state plist for TOOL-CALL-ID, or nil."
  (gethash tool-call-id dsh-emacs--tool-states))

(defun dsh-emacs-render--set-tool-state (tool-call-id &rest props)
  "Set props onto the tracked state of TOOL-CALL-ID, replacing all."
  (puthash tool-call-id props dsh-emacs--tool-states))

(defun dsh-emacs-render--close-current-group ()
  "Close out the current activity group (if any) so the next tool starts fresh."
  (when (and dsh-emacs--current-group-id
             (> dsh-emacs--current-group-count 1))
    ;; Update the group header's label-right with the completed count.
    (let* ((gid dsh-emacs--current-group-id)
           (done dsh-emacs--current-group-completed)
           (total dsh-emacs--current-group-count)
           (right (format "%d of %d completed" done total))
           (qualified-id (format "%s-%s" (dsh-emacs-render--make-namespace) gid))
           (block (dsh-emacs-ui-find-block qualified-id)))
      (when block
        (dsh-emacs-ui-update-fragment
         (dsh-emacs-ui-make-fragment
          :namespace-id (dsh-emacs-render--make-namespace)
          :block-id gid
          :label-left (propertize "Tool activity" 'face 'dsh-emacs-group-face)
          :label-right right)
         :create-new nil))))
  (setq dsh-emacs--current-group-id nil
        dsh-emacs--current-group-count 0
        dsh-emacs--current-group-completed 0))

(defun dsh-emacs-render--ensure-group ()
  "Maybe open a new group if we have accumulated `dsh-emacs-group-consecutive-tools'."
  (when (>= dsh-emacs--current-group-count dsh-emacs-group-consecutive-tools)
    (dsh-emacs-render--close-current-group))
  (unless dsh-emacs--current-group-id
    (setq dsh-emacs--group-counter (1+ dsh-emacs--group-counter))
    (setq dsh-emacs--current-group-id
          (format "group-%d-%d"
                  dsh-emacs--group-counter
                  (random 99999)))
    (setq dsh-emacs--current-group-count 0
          dsh-emacs--current-group-completed 0)))

(defun dsh-emacs-render--stream-key (event)
  "Return the logical assistant stream key for EVENT."
  (let ((data (dsh-emacs-render--event-data event)))
    (format "%s/%s"
            (or (dsh-emacs-render--aget "turn" data) "?")
            (or (dsh-emacs-render--aget "step" data) "?"))))

(defun dsh-emacs-render--stream-state-key (state)
  "Return the logical key stored in streaming STATE."
  (plist-get state :key))

(defun dsh-emacs-render--stream-render-region (state &optional force)
  "Render the Markdown body described by STATE in place.
Only the body region is narrowed, so the prompt, other messages and tool
blocks are never touched.  The agent-shell-style watermark and frozen
properties make already stable spans cheap to revisit while allowing the
last incomplete Markdown construct to be completed by a later chunk."
  (let ((start (marker-position (plist-get state :start)))
        (end (marker-position (plist-get state :end))))
    (when (and start end (<= start end))
      (save-excursion
        (save-restriction
          (goto-char start)
          (narrow-to-region start end)
          (let ((inhibit-read-only t))
            (dsh-emacs-markdown-replace-markup :force force))))
      (let ((body-start (marker-position (plist-get state :start)))
            (body-end (marker-position (plist-get state :end)))
            (event-id (plist-get state :event-id)))
        (when (and body-start body-end (<= body-start body-end))
          (let ((inhibit-read-only t))
            (put-text-property body-start body-end 'read-only t)
            (put-text-property body-start body-end 'front-sticky '(read-only))
            (put-text-property body-start body-end 'rear-nonsticky '(read-only))
            (add-face-text-property body-start body-end
                                    'dsh-emacs-assistant-body-face t)
            (when event-id
              (put-text-property body-start body-end
                                 'dsh-emacs-event-block event-id))))))))

(defun dsh-emacs-render--start-assistant-stream (event text)
  "Create or extend the live assistant stream with TEXT from EVENT."
  (when (and (stringp text) (not (string-empty-p text)))
    (let* ((key (dsh-emacs-render--stream-key event))
           (state dsh-emacs--streaming-assistant)
           (new-state nil))
      ;; There is normally only one active assistant step.  If the server
      ;; starts another one before sending the previous summary, leave the
      ;; already visible body in place and move the live cursor to the new
      ;; stream.
      (when (and state
                 (not (equal key (dsh-emacs-render--stream-state-key state))))
        (setq state nil
              dsh-emacs--streaming-assistant nil))
      (unless state
        (let* ((insert-point (dsh-emacs-render--input-insert-point))
               (event-id (format "%s-stream-%s"
                                 (dsh-emacs-render--make-namespace) key))
               start end)
          (save-excursion
            (let ((inhibit-read-only t))
              (if insert-point
                  (progn (goto-char insert-point) (beginning-of-line))
                ;; Never append below the input when the prompt marker was
                ;; unavailable: fall back to the anchor itself.
                (if-let* ((anchor (dsh-emacs-render--input-anchor-pos)))
                    (progn (goto-char anchor) (beginning-of-line))
                  (goto-char (point-max))))
              ;; Flush against the preceding content so a live stream never
              ;; leaves a blank gap above it (tools stack the same way).
              (dsh-emacs-ui--consume-blanks-above)
              (setq start (point))
              (insert text "\n\n")
              (setq end (copy-marker (- (point) 2) t))))
          (setq state (list :key key
                            :start (copy-marker start nil)
                            :end end
                            :event-id event-id
                            :raw text)
                dsh-emacs--streaming-assistant state
                new-state t)))
      (when (and state (not new-state))
        (let ((end (plist-get state :end))
              (inhibit-read-only t))
          (save-excursion
            (goto-char end)
            (insert text))
          (setq state (plist-put state :raw
                                 (concat (plist-get state :raw) text))
                dsh-emacs--streaming-assistant state)))
      (dsh-emacs-render--stream-render-region state)
      state)))

(defun dsh-emacs-render--finish-assistant-stream (event final-text)
  "Replace the live stream with FINAL-TEXT from assistant/message EVENT.
The final event is authoritative: this repairs a missing chunk and performs
one forced Markdown pass so a delimiter completed by the final message is
rendered immediately."
  (let ((state dsh-emacs--streaming-assistant))
    (when (and state
               (equal (dsh-emacs-render--stream-key event)
                      (dsh-emacs-render--stream-state-key state)))
      (let* ((start (marker-position (plist-get state :start)))
             (end (marker-position (plist-get state :end)))
             (text (or final-text ""))
             (inhibit-read-only t))
        (when (and start end)
          (save-excursion
            (goto-char start)
            (delete-region start end)
            (insert text)
            (set-marker (plist-get state :end) (point)))
          (setq state (plist-put state :raw text)
                dsh-emacs--streaming-assistant state)
          (dsh-emacs-render--stream-render-region state t)))
      (set-marker (plist-get state :start) nil)
      (set-marker (plist-get state :end) nil)
      (setq dsh-emacs--streaming-assistant nil)
      t)))

(defun dsh-emacs-render--thinking-stream-alive-for-p (key)
  "Return non-nil when the live thinking stream is active for KEY."
  (and dsh-emacs--streaming-thinking
       (equal key (plist-get dsh-emacs--streaming-thinking :key))))

(defun dsh-emacs-render--start-thinking-stream (event text)
  "Create or extend the live Thinking stream with reasoning TEXT.
The stream is a raw body under a dsh-web \"IconThink…\" header (see
`dsh-emacs-render--think-icon') inserted at the transcript's input point, so
`reasoning-delta' chunks stay cheap to append.  `dsh-emacs-render-assistant-message'
swaps it for the collapsible Think fragment once the authoritative reasoning
text arrives."
  (when (and dsh-emacs-show-reasoning
             (stringp text) (not (string-empty-p text)))
    (let* ((key (dsh-emacs-render--stream-key event))
           (state dsh-emacs--streaming-thinking)
           (label (concat (dsh-emacs-render--think-icon) " "
                          (propertize "Think" 'face 'dsh-emacs-thinking-face)))
           (new-state nil))
      ;; A different turn/step started reasoning: leave the previous raw
      ;; body in place (it is finalized by its own message) and start fresh.
      (when (and state (not (equal key (plist-get state :key))))
        (setq state nil
              dsh-emacs--streaming-thinking nil))
      (unless state
        (let* ((insert-point (dsh-emacs-render--input-insert-point))
               start end)
          (save-excursion
            (let ((inhibit-read-only t))
              (if insert-point
                  (progn (goto-char insert-point) (beginning-of-line))
                (if-let* ((anchor (dsh-emacs-render--input-anchor-pos)))
                    (progn (goto-char anchor) (beginning-of-line))
                  (goto-char (point-max))))
              (dsh-emacs-ui--consume-blanks-above)
              (setq start (point))
              (insert label "\n")
              (insert text "\n")
              (setq end (copy-marker (- (point) 1) t))))
          (setq state (list :key key
                            :start (copy-marker start nil)
                            :end end
                            :raw text)
                dsh-emacs--streaming-thinking state
                new-state t)))
      (when (and state (not new-state))
        (let ((end (plist-get state :end)))
          (save-excursion
            (let ((inhibit-read-only t))
              (goto-char end)
              (insert text)))
          (setq state (plist-put state :raw
                                 (concat (plist-get state :raw) text))
                dsh-emacs--streaming-thinking state)))
      state)))

(defun dsh-emacs-render--replace-live-thinking-text (ns block-id final-text)
  "Swap the live thinking stream for the final Think fragment.
NS and BLOCK-ID name the collapsible fragment; FINAL-TEXT is the
authoritative reasoning body from `assistant/message'.  Returns non-nil
when a live stream existed and was replaced."
  (let ((state dsh-emacs--streaming-thinking))
    (when state
      (let ((start (marker-position (plist-get state :start)))
            (end (marker-position (plist-get state :end))))
        (when (and start end (> end start))
          (let ((inhibit-read-only t))
            (delete-region start end)
            (setq dsh-emacs--streaming-thinking nil)
            (dsh-emacs-render--render-thinking-block
             ns block-id final-text
             (format-time-string "%H:%M:%S") start)))
        (set-marker (plist-get state :start) nil)
        (set-marker (plist-get state :end) nil)
        (setq dsh-emacs--streaming-thinking nil))
      t)))


(defun dsh-emacs-render-assistant-chunk (event)
  "Render an `assistant/chunk' EVENT incrementally.
Text-delta chunks are appended to one live body and re-rendered in place;
reasoning-delta chunks grow a live Thinking block (mind the `block-start'
with blockType \"reasoning\" that precedes them); block-end chunks are only
used as a fallback when no deltas were received."
  (let* ((data (dsh-emacs-render--event-data event))
         (chunk (dsh-emacs-render--aget "chunk" data))
         (chunk-type (dsh-emacs-render--aget "type" chunk))
         (text (dsh-emacs-render--aget "text" chunk)))
    (cond
     ((and (equal chunk-type "text-delta") (stringp text))
      (dsh-emacs-render--start-assistant-stream event text))
     ((equal chunk-type "block-start")
      (when (equal (dsh-emacs-render--aget "blockType" chunk) "reasoning")
        ;; A reasoning block is starting; the first reasoning-delta creates
        ;; the live Thinking block (there is nothing to insert yet).
        nil))
     ((and (equal chunk-type "reasoning-delta") (stringp text))
      (dsh-emacs-render--start-thinking-stream event text))
     ((and (equal chunk-type "block-end")
           (equal (dsh-emacs-render--aget "type"
                                           (dsh-emacs-render--aget "block" chunk))
                  "text")
           (stringp (dsh-emacs-render--aget "text"
                                             (dsh-emacs-render--aget "block" chunk))))
      (let ((state dsh-emacs--streaming-assistant)
            (block-text (dsh-emacs-render--aget "text"
                                                 (dsh-emacs-render--aget "block" chunk))))
        (unless (and state (equal (dsh-emacs-render--stream-key event)
                                  (dsh-emacs-render--stream-state-key state)))
          (dsh-emacs-render--start-assistant-stream event block-text))))
     ((and (equal chunk-type "block-end")
           (equal (dsh-emacs-render--aget "type"
                                           (dsh-emacs-render--aget "block" chunk))
                  "reasoning")
           (stringp (dsh-emacs-render--aget "text"
                                             (dsh-emacs-render--aget "block" chunk))))
      ;; Authoritative fallback for a reasoning block that produced no live
      ;; deltas (e.g. a compacted/retried block only present in history).
      (when (and dsh-emacs-show-reasoning
                 (not (dsh-emacs-render--thinking-stream-alive-for-p
                       (dsh-emacs-render--stream-key event))))
        (dsh-emacs-render--render-thinking-block
         (dsh-emacs-render--make-namespace)
         (dsh-emacs-render--make-block-id event)
         (dsh-emacs-render--aget "text" (dsh-emacs-render--aget "block" chunk))
         (dsh-emacs-render--event-time event)
         (dsh-emacs-render--input-insert-point))))))
  (dsh-emacs-render--event-seq event))

;;; ---------------------------------------------------------------------------
;;; 渲染器：用户消息
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render-user-message (event)
  "Render a `user/message' event with a user-specific background color.
The block gets one blank line before and after (see
`dsh-emacs-render--insert-chat-message' and `dsh-emacs-ui--blank-above-preserve')."
  (let* ((seq (dsh-emacs-render--event-seq event))
         (data (dsh-emacs-render--event-data event))
         (kind (dsh-emacs-render--aget "kind" (dsh-emacs-render--aget "source" data)))
         (text (dsh-emacs-render--text-from-content (dsh-emacs-render--aget "content" data)))
         (insert-point (dsh-emacs-render--input-insert-point))
         (block-id (dsh-emacs-render--make-block-id event)))
    (when (or (null kind) (equal kind "user"))
      (dsh-emacs-render--insert-chat-message
       (concat (propertize "❯ " 'face 'dsh-emacs-input-prompt-face)
               text)
       'dsh-emacs-user-block-face insert-point
       (format "%s-%s" (dsh-emacs-render--make-namespace) block-id)
       t))
    seq))

;;; ---------------------------------------------------------------------------
;;; 渲染器：助手消息
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render-assistant-message (event)
  "Render an `assistant/message' event with an assistant background color."
  (let* ((seq (dsh-emacs-render--event-seq event))
         (data (dsh-emacs-render--event-data event))
         (message (dsh-emacs-render--aget "message" data))
         (content (dsh-emacs-render--aget "content" message))
         (text (dsh-emacs-render--text-from-content content))
         (reasoning (dsh-emacs-render--reasoning-from-content content))
         (ts (dsh-emacs-render--event-time event))
         (ns (dsh-emacs-render--make-namespace))
         (block-id (dsh-emacs-render--make-block-id event)))
    (when dsh-emacs-show-reasoning
      (unless (string-empty-p reasoning)
        (if (dsh-emacs-render--thinking-stream-alive-for-p
             (dsh-emacs-render--stream-key event))
            (dsh-emacs-render--replace-live-thinking-text
             (dsh-emacs-render--make-namespace)
             (dsh-emacs-render--make-block-id event)
             reasoning)
          (dsh-emacs-render--render-thinking-block
           ns block-id reasoning ts (dsh-emacs-render--input-insert-point)))))
    (unless (dsh-emacs-render--finish-assistant-stream event text)
      (unless (string-empty-p text)
        (dsh-emacs-render--insert-chat-message
         (dsh-emacs-markdown-render text)
         'dsh-emacs-assistant-body-face (dsh-emacs-render--input-insert-point)
         (format "%s-%s" ns block-id))))
    seq))

(defun dsh-emacs-render--render-thinking-block (namespace-id block-id text timestamp insert-point)
  "Render a collapsible <details>-style thinking block."
  (dsh-emacs-ui-update-fragment
   (dsh-emacs-ui-make-fragment
    :namespace-id namespace-id
    :block-id block-id
    :label-left (concat (dsh-emacs-render--think-icon) " " "Think")
    :label-right (or (dsh-emacs-render--thinking-preview text)
                     (or timestamp ""))
    :body text
    :style 'minimal
    :color-key 'thinking)
   :create-new t :expanded dsh-emacs-thinking-expand-by-default
   :insert-before insert-point)
  ;; Apply thinking face to the entire block (like tool rows),
  ;; not just the body — one face, whole row.
  (when-let* ((b (dsh-emacs-ui-find-block (format "%s-%s" namespace-id block-id))))
    (let ((inhibit-read-only t))
      (add-face-text-property (car b) (cdr b)
                              'dsh-emacs-thinking-face t))))

;;; ---------------------------------------------------------------------------
;;; 渲染器：todo 计划行（每事件一行，像 tool 卡）
;;; ---------------------------------------------------------------------------
;;; dsh 的 `todo_write' 工具每次携带整份清单的全量替换快照（[{content,
;;; status}]）。每次快照都在 chat transcript 内渲染**一行**独立的可折叠
;;; fragment（namespace "todo"，block-id = call-id），并且像 tool 事件那样
;;; 一行一行按时间顺序堆叠，而不是常驻单块原位更新。清单为空时不渲染任何行。

(defconst dsh-emacs--todo-namespace "todo"
  "Namespace for the rendered todo (plan) rows.")

(defvar-local dsh-emacs--todo-list nil
  "Latest whole todo list snapshot as (\"content\" . \"status\") cells, or nil.
nil (or empty) means there is no plan yet.")

(defun dsh-emacs-render--todo-parse (args-raw)
  "Parse a `todo_write' ARGS-RAW JSON string into an ordered list of
\(\"content\" . \"status\") cells.  Empty/invalid content is dropped and a
missing or unknown status defaults to \"pending\".  Returns nil on any error."
  (let (result)
    (when (and args-raw (stringp args-raw) (not (string-empty-p args-raw)))
      (let* ((parsed (condition-case nil (json-read-from-string args-raw) (error nil)))
             (todos (and (listp parsed) (dsh-emacs-render--aget "todos" parsed))))
        (dolist (cell (append todos nil))
          (when (consp cell)
            (let ((content (dsh-emacs-render--aget "content" cell))
                  (status (dsh-emacs-render--aget "status" cell)))
              (when (and (stringp content) (not (string-empty-p content)))
                (push (cons content
                            (if (member status '("pending" "in_progress" "completed"))
                                status "pending"))
                      result)))))))
    (nreverse result)))

(defun dsh-emacs-render--todo-counts (list)
  "Return (DONE ACTIVE PENDING) counts for LIST of (\\\"content\\\" . STATUS) cells."
  (let ((done 0) (active 0))
    (dolist (cell list)
      (pcase (cdr cell)
        ("completed" (setq done (1+ done)))
        ("in_progress" (setq active (1+ active)))))
    (list done active (max 0 (- (length list) done active)))))

(defun dsh-emacs-render--todo-summary (list)
  "Compact progress label for LIST, e.g. \\\"2/5 completed · 1 in progress\\\".
Zero-count segments are omitted (a non-empty list keeps at least one)."
  (let* ((counts (dsh-emacs-render--todo-counts list))
         (done (nth 0 counts))
         (active (nth 1 counts))
         (pending (nth 2 counts))
         (total (length list))
         (parts '()))
    (when (> done 0) (push (format "%d/%d completed" done total) parts))
    (when (> active 0) (push (format "%d in progress" active) parts))
    (when (> pending 0) (push (format "%d pending" pending) parts))
    (mapconcat #'identity (nreverse parts) " · ")))

(defun dsh-emacs-render--todo-glyph (status)
  "Checkbox glyph for STATUS: ☑ (completed), ☐ (pending/in progress)."
  (pcase status
    ("completed" "☑")
    (_ "☐")))

(defun dsh-emacs-render--todo-glyph-face (_status)
  "Face for the STATUS checkbox glyph (green, per dsh web's plan checkbox)."
  'dsh-emacs-todo-check-face)

(defun dsh-emacs-render--todo-body (list)
  "Render LIST as a multi-line checkbox string, one `☑|☐ CONTENT — STATUS'
line per item.  The checkbox glyph carries `dsh-emacs-todo-check-face' (green);
`split-string' preserves these text properties through the fragment body
renderer.  `line-spacing' is pinned to 0 so a theme's line-spacing does not
spread the rows apart (each todo is one line)."
  (propertize
   (mapconcat
    (lambda (cell)
      (let* ((status (cdr cell))
             (glyph (propertize (dsh-emacs-render--todo-glyph status)
                                'face (dsh-emacs-render--todo-glyph-face status)))
             (word (pcase status
                     ("completed" "completed")
                     ("in_progress" "in progress")
                     (_ "pending"))))
        (concat "  " glyph " " (car cell) " — " word)))
    list
    "\n")
   'line-spacing 0))

(defun dsh-emacs-render--todo-block-id (call-id)
  "Return the per-event block-id of a todo row with CALL-ID."
  (or call-id "unknown"))

(defun dsh-emacs-render--todo-qualified-id (call-id)
  "Return the qualified-id of the todo row for CALL-ID."
  (dsh-emacs-ui--qualified-id dsh-emacs--todo-namespace
                              (dsh-emacs-render--todo-block-id call-id)))

(defun dsh-emacs-render--todo-row (list call-id)
  "Render one todo row for the whole snapshot LIST at the event's position.
Like a tool card, each `todo_write' snapshot gets its own collapsible row in
the transcript; a nil/empty LIST or `dsh-emacs-show-todos' nil renders nothing."
  (when (and dsh-emacs-show-todos list (car list))
    (let* ((insert-point (dsh-emacs-render--input-insert-point))
           (summary-only dsh-emacs-todo-summary-only)
           (sum (dsh-emacs-render--todo-summary list))
           (body (unless summary-only (dsh-emacs-render--todo-body list)))
           ;; Title + summary in the todo green accent (`dsh-emacs-todo-text-face',
           ;; non-italic); the leading checklist icon keeps the tool purple.
           ;; Separator: one space each side.
           (label (concat (dsh-emacs-render--todo-icon) " "
                          (propertize dsh-emacs-todo-title
                                      'face 'dsh-emacs-todo-text-face)
                          " · "
                          (propertize sum
                                      'face 'dsh-emacs-todo-text-face))))
      (dsh-emacs-ui-update-fragment
       (dsh-emacs-ui-make-fragment
        :namespace-id dsh-emacs--todo-namespace
        :block-id (dsh-emacs-render--todo-block-id call-id)
        :label-left label
        :label-right nil
        :body body
        :style 'minimal
        :color-key 'tool-pending
        :non-foldable (and summary-only t))
       :expanded dsh-emacs-todo-expand-by-default
       :insert-before insert-point))))

(defun dsh-emacs-render-todo-clear ()
  "Clear the latest todo snapshot state.  Rendered todo rows stay in the
transcript; they are removed with the buffer on a session reset/replay."
  (setq dsh-emacs--todo-list nil))

(defun dsh-emacs-render-todo-write (event)
  "Handle a `todo_write' tool event: render a new todo row at the event's
position in the transcript, one row per snapshot (like a tool card).  Returns
the event seq but renders no ordinary tool card."
  (let* ((data (dsh-emacs-render--event-data event))
         (args (dsh-emacs-render--aget "arguments" data))
         (list (dsh-emacs-render--todo-parse args))
         (call-id (or (dsh-emacs-render--aget "callId" data)
                      (format "seq-%s" (dsh-emacs-render--event-seq event)))))
    (setq dsh-emacs--todo-list list)
    (dsh-emacs-render--todo-row list call-id)
    (dsh-emacs-render--event-seq event)))

;;; ---------------------------------------------------------------------------
;;; 渲染器：工具调用（活动组的一部分）
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render--tool-call-block-id (tool-call-id)
  "Return a stable block-id for TOOL-CALL-ID (so we can update it later)."
  (format "tool-%s" tool-call-id))

(defun dsh-emacs-render--tool-group-id (tool-call-id)
  "Return the group id the tool-call with TOOL-CALL-ID belongs to, if any."
  (let ((state (dsh-emacs-render--tool-state tool-call-id)))
    (when state (plist-get state :group-id))))

(defun dsh-emacs-render--tool-group-qualified-id (tool-call-id)
  "Return the qualified id of the group for TOOL-CALL-ID."
  (let* ((gid (dsh-emacs-render--tool-group-id tool-call-id))
         (ns (dsh-emacs-render--make-namespace)))
    (and gid (format "%s-%s" ns gid))))

(defun dsh-emacs-render-tool-call (event)
  "Render a `tool/call' event. Returns seq."
  (let ((name (dsh-emacs-render--aget "name" (dsh-emacs-render--event-data event))))
    (if (equal name "todo_write")
        ;; todo_write updates the live plan strip, not an ordinary tool card.
        (dsh-emacs-render-todo-write event)
      (if (not dsh-emacs-show-tool-calls)
          nil
        (let* ((seq (dsh-emacs-render--event-seq event))
         (data (dsh-emacs-render--event-data event))
         (call-id (dsh-emacs-render--aget "callId" data))
         (name (dsh-emacs-render--aget "name" data))
         (args (dsh-emacs-render--aget "arguments" data))
         (variant-info (dsh-emacs-render--tool-variant name))
         (variant (car variant-info))
         (icon (cdr variant-info))
         (title (dsh-emacs-render--tool-title name))
         (summary (dsh-emacs-render--tool-summary variant args))
         (body-text (dsh-emacs-render--tool-body-text variant args))
         (ns (dsh-emacs-render--make-namespace))
         (insert-point (dsh-emacs-render--input-insert-point))
         (ts (dsh-emacs-render--event-time event))
         (label-left (concat icon " "
                             (propertize title 'face 'dsh-emacs-tool-title-face)))
         (label-right (or summary ""))
         (block-id (dsh-emacs-render--tool-call-block-id call-id)))
      ;; Track state for later (tool/result will update this block).
      (dsh-emacs-render--set-tool-state
       call-id :state 'pending :variant variant :icon icon :title title
       :summary summary :args body-text :call-time ts :ns ns)
      ;; Maybe open / reuse an activity group.
      (dsh-emacs-render--ensure-group)
      (when (and (>= dsh-emacs--current-group-count dsh-emacs-group-consecutive-tools)
                 (= dsh-emacs--current-group-count 0))
        ;; First call of a new group: render the header.
        nil)
      (setq dsh-emacs--current-group-count (1+ dsh-emacs--current-group-count))
      (dsh-emacs-ui-update-fragment
       (dsh-emacs-ui-make-fragment
        :namespace-id ns
        :block-id block-id
        :label-left label-left
        :label-right label-right
        :body body-text
        :style 'minimal
        :color-key 'tool-pending)
       :create-new t
       :expanded dsh-emacs-tool-expand-by-default
       :insert-before insert-point)
      ;; Update tracked state with group id.
      (dsh-emacs-render--set-tool-state
       call-id :state 'pending :variant variant :icon icon :title title
       :summary summary :args body-text :call-time ts :ns ns
       :group-id dsh-emacs--current-group-id)
      ;; Apply pending face to the block border + body background.
      ;; Use add-face-text-property (APPEND) to merge with existing face
      ;; attributes (e.g. a Nerd Font :family on icon glyphs).
      (when-let* ((b (dsh-emacs-ui-find-block (format "%s-%s" ns block-id))))
        (let ((inhibit-read-only t))
          (add-face-text-property (car b) (cdr b)
                                  'dsh-emacs-tool-pending-face t))))
    ;; Return seq via the helper to keep helper structure.
    (dsh-emacs-render--event-seq event)))))

;;; ---------------------------------------------------------------------------
;;; 渲染器：工具结果（dsh web 风格 ioCard）
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render--tool-leading (icon state)
  "Leading glyph for a tool row, mirroring dsh web's `leadingFor`:
ok/running keep the variant ICON; error/stopped are overridden by a
colored status dot (red / warning-yellow)."
  (pcase state
    ('error  "● ")
    ('stopped "◐ ")
    (_ (concat icon " "))))

(defun dsh-emacs-render--tool-body-io (in-text out-text &optional status-text)
  "Compose the expanded tool body from IN-TEXT (args) and OUT-TEXT (result).
Mirrors dsh web's ioCard: an `IN` section, then an `OUT` section.  When
STATUS-TEXT is non-empty it is prepended as a first status line.
Returns a multi-line body string (IN/OUT are literal labels so the fold
toggle — which strips faces — keeps them readable)."
  (let ((parts '()))
    (when (and status-text (not (string-empty-p status-text)))
      (push status-text parts))
    (when (and in-text (not (string-empty-p in-text)))
      (push "IN" parts)
      (dolist (line (split-string (string-trim in-text) "\n"))
        (push (concat "   " line) parts)))
    (when (and out-text (not (string-empty-p out-text)))
      (when (and in-text (not (string-empty-p in-text)))
        (push "────" parts))
      (push "OUT" parts)
      (dolist (line (split-string (string-trim out-text) "\n"))
        (push (concat "   " line) parts)))
    (mapconcat #'identity (nreverse parts) "\n")))

(defun dsh-emacs-render--tool-status-text (state exit-code signal)
  "Short human status for STATE/EXIT-CODE/SIGNAL, or nil."
  (pcase state
    ('success (format "✓ exit %s" (or exit-code "0")))
    ('error (cond
             ((and (integerp exit-code) (/= exit-code 0))
              (format "✗ exit %d" exit-code))
             (signal (format "✗ signal %s" signal))
             (t "✗ failed")))
    ('stopped "⏸ interrupted")
    (_ nil)))

(defun dsh-emacs-render-tool-result (event)
  "Render a `tool/result' event by appending to the corresponding tool-call block."
  (if (not dsh-emacs-show-tool-calls)
      nil
    (let* ((seq (dsh-emacs-render--event-seq event))
         (data (dsh-emacs-render--event-data event))
         (message (dsh-emacs-render--aget "message" data))
         ;; dsh Web stores the originating tool id under message.source;
         ;; accept the compact message.callId shape too (used by older
         ;; events/tests and some RPC responses).
         (call-id (or (dsh-emacs-render--aget "callId" message)
                      (dsh-emacs-render--aget
                       "callId" (dsh-emacs-render--aget "source" message))
                      (dsh-emacs-render--aget "callId" data)))
         (content (dsh-emacs-render--aget "content" message))
         (is-error nil)
         (exit-code nil)
         (signal nil)
         (text-parts '()))
      (dolist (block (append content nil))
        (when (equal (dsh-emacs-render--aget "type" block) "tool-result")
          (setq is-error (dsh-emacs-render--json-bool (dsh-emacs-render--aget "isError" block)))
          (setq exit-code (dsh-emacs-render--aget "exitCode" block))
          (setq signal (dsh-emacs-render--aget "signal" block))
          (dolist (inner (append (dsh-emacs-render--aget "content" block) nil))
            (when (equal (dsh-emacs-render--aget "type" inner) "text")
              (push (dsh-emacs-render--aget "text" inner) text-parts)))))
      (let* ((full-text (mapconcat #'identity (nreverse text-parts) "\n"))
             (state (if is-error 'error
                      (cond
                       ((and (integerp exit-code) (= exit-code 0)) 'success)
                       ((and (integerp exit-code) (/= exit-code 0)) 'error)
                       (signal 'stopped)
                       (t 'success))))
             (ns (dsh-emacs-render--make-namespace))
             (block-id (dsh-emacs-render--tool-call-block-id call-id))
             (qualified-id (format "%s-%s" ns block-id)))
        (when-let* ((prev (dsh-emacs-render--tool-state call-id)))
          (let* ((title (or (plist-get prev :title) "Tool"))
                 (args (or (plist-get prev :args) ""))
                 (summary (or (plist-get prev :summary) ""))
                 (icon (or (plist-get prev :icon) ""))
                 (status-text (dsh-emacs-render--tool-status-text state exit-code signal))
                 (body (dsh-emacs-render--tool-body-io args full-text status-text)))
            (dsh-emacs-ui-update-fragment
             (dsh-emacs-ui-make-fragment
              :namespace-id ns
              :block-id block-id
              :label-left (concat
                           (dsh-emacs-render--tool-leading icon state)
                           (propertize title 'face 'dsh-emacs-tool-title-face))
              :label-right summary
              :body body
              :style 'minimal
              :color-key (pcase state
                          ('success 'tool-success)
                          ('error 'tool-error)
                          (_ 'tool-stopped)))
             :create-new nil)
            (dsh-emacs-ui-restyle-block qualified-id (pcase state
                                                  ('success 'tool-success)
                                                  ('error 'tool-error)
                                                  (_ 'tool-stopped)))
            ;; Re-face the block border/body.  Merge (APPEND) so Nerd Font
            ;; :family on icon glyphs is preserved.
            (when-let* ((b (dsh-emacs-ui-find-block qualified-id)))
              (let ((inhibit-read-only t))
                (add-face-text-property
                 (car b) (cdr b)
                 (pcase state
                   ('success 'dsh-emacs-tool-success-face)
                   ('error 'dsh-emacs-tool-error-face)
                   ('stopped 'dsh-emacs-tool-stopped-face)
                   (_ 'dsh-emacs-tool-pending-face))
                 t))))
          ;; Track the new state.
          (dsh-emacs-render--set-tool-state
           call-id :state state :result full-text :exit-code exit-code)
          ;; Increment completed counter in the current group.
          (when (and dsh-emacs--current-group-id
                     (equal (plist-get (dsh-emacs-render--tool-state call-id) :group-id)
                            dsh-emacs--current-group-id))
            (setq dsh-emacs--current-group-completed
                  (1+ dsh-emacs--current-group-completed))))))
    (dsh-emacs-render--event-seq event)))

;;; ---------------------------------------------------------------------------
;;; 渲染器：turn start / end / interrupt / error
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render-turn-start (event)
  "Record a `turn/start' event without adding visual chrome.
The event stream is the authoritative source for turn liveness: a replayed
or re-fetched history whose tail is a `turn/start' without a matching
`turn/end' means the turn is still in flight, so re-light the mode-line
running spinner (idempotent — the send path already lit it, and a
`turn/end' later clears it)."
  (dsh-emacs-render--close-current-group)
  ;; A turn started (or a still-open turn was replayed after a reconnect /
  ;; session reopen): light the mode-line running spinner.
  (when (fboundp 'dsh-emacs--ml-busy-set)
    (dsh-emacs--ml-busy-set t))
  (dsh-emacs-render--event-seq event))

(defun dsh-emacs-render-turn-end (event)
  "Record a `turn/end' event; surface a failed model run.
A terminal `turn/end' whose DATA.REASON.KIND is \"error\" (dsh web's
turn-error node — the provider rejected the run: quota, rate, ...)
renders as a visible error row; anything else just clears the running
spinner."
  (dsh-emacs-render--close-current-group)
  ;; The turn finished: stop the mode-line running spinner.
  (when (fboundp 'dsh-emacs--ml-busy-set)
    (dsh-emacs--ml-busy-set nil))
  ;; A failed run must not be silently swallowed: dsh signals it as
  ;; `turn/end' + data.reason.kind = \"error\", mirroring dsh web's
  ;; turn-error node.
  (let ((failure (dsh-emacs-render--turn-failure event)))
    (when failure
      (dsh-emacs-render-info
       (if (cdr failure)
           (format "✗ Model error (%s)" (cdr failure))
         "✗ Model error")
       (car failure))))
  (dsh-emacs-render--event-seq event))

(defun dsh-emacs-render--turn-failure (event)
  "Return (MESSAGE . CODE) for EVENT's terminal turn failure, or nil.
Mirrors dsh web's turn-error definition: a `turn/end' event whose
DATA.REASON.KIND is \"error\" carries the provider failure in
DATA.REASON.ERROR ({code, message, ...})."
  (let* ((data (dsh-emacs-render--event-data event))
         (reason (dsh-emacs-render--aget "reason" data))
         (kind (dsh-emacs-render--aget "kind" reason))
         (error (dsh-emacs-render--aget "error" reason)))
    (when (equal kind "error")
      (cond
       ((stringp error) (cons error nil))
       ((listp error)
        (cons (or (dsh-emacs-render--aget "message" error)
                  (format "%S" error))
              (let ((code (dsh-emacs-render--aget "code" error)))
                (and (stringp code) (not (string-empty-p code)) code))))
       (t (cons "Model run failed" nil))))))

(defun dsh-emacs-render-info (label text &optional block-id)
  "Render a one-off informational fragment (interrupts, errors, polling errors)."
  (let* ((ns (dsh-emacs-render--make-namespace))
         (bid (or block-id (format "info-%d" (random 999999))))
         (insert-point (dsh-emacs-render--input-insert-point)))
    (dsh-emacs-ui-update-fragment
     (dsh-emacs-ui-make-fragment
      :namespace-id ns
      :block-id bid
      :label-left (propertize label 'face 'dsh-emacs-error-face)
      :body text
      :style 'minimal
      :color-key 'info)
     :create-new t :expanded t
     :insert-before insert-point)))

(defun dsh-emacs-render-command-label (name &optional _args)
  "Return the display string for slash command NAME.
The leading \"/\" is stripped from NAME so the row reads e.g. \"compact\".
ARGS is ignored — command rows show only the command name, not the
user's input text."
  (if (and (stringp name) (string-prefix-p "/" name))
      (substring name 1)
    (or name "")))

(defun dsh-emacs-render--command-status-text (state)
  "Short status suffix for a slash-command node STATE (success/error)."
  (pcase state
    ('success "✓ done")
    ('error "✗ failed")
    (_ nil)))

;;; ---------------------------------------------------------------------------
;;; Slash-command row styling: bash terminal icon + running `-\|/' spinner
;;; ---------------------------------------------------------------------------

(defconst dsh-emacs--command-spinner-frames
  '("-" "\\" "|" "/")
  "Frames of the running slash-command leading animation.
The classic shell `-\\|/' spinner (the same frames as slash.sh), so the
row animates with familiar 4-frame terminal rhythm.")

(defconst dsh-emacs--command-spinner-interval 0.1
  "Seconds between running-command animation frames (~10fps, like the
classic shell spinner in slash.sh).")



(defvar-local dsh-emacs--command-spinners (make-hash-table :test 'equal)
  "Live running-command animations, keyed by COMMAND-ID.
Each value is (BUFFER TIMER INDEX): BUFFER is the chat buffer the row lives
in, TIMER the repeating `run-at-time' timer, INDEX the next frame index.

Buffer-local: several chats may run commands concurrently, and the
optimistic temp ids (`pending-<name>') collide across buffers — a global
table would let one session's spinner overwrite/cancel another's.  Each
chat buffer gets its own hash in `dsh-emacs-render--reset-tool-tracking'.")

(defun dsh-emacs--command-spinner-start (command-id buffer)
  "Start the running `-\\|/' animation for COMMAND-ID in BUFFER.
Replaces any existing animation for the same command (idempotent)."
  (dsh-emacs--command-spinner-stop command-id)
  (let ((timer (run-at-time dsh-emacs--command-spinner-interval
                            dsh-emacs--command-spinner-interval
                            #'dsh-emacs--command-spinner-tick
                            command-id)))
    (puthash command-id (list buffer timer 0)
             dsh-emacs--command-spinners)))

(defun dsh-emacs--command-spinner-tick (command-id)
  "Advance COMMAND-ID's spinner one frame and redraw its row label.
Auto-stops when the chat buffer is gone or the row no longer exists.
The per-buffer `dsh-emacs--command-blocks' lookup happens inside the chat
buffer, because a timer callback may otherwise run in any buffer."
  (let ((rec (gethash command-id dsh-emacs--command-spinners)))
    (when rec
      (let ((buffer (nth 0 rec))
            (timer (nth 1 rec)))
        (if (and (buffer-live-p buffer)
                 (timerp timer))
            (with-current-buffer buffer
              (if (gethash command-id dsh-emacs--command-blocks)
                  (let* ((entry (gethash command-id dsh-emacs--command-blocks))
                         (next-index (mod (1+ (nth 2 rec))
                                          (length dsh-emacs--command-spinner-frames))))
                    (setcar (nthcdr 2 rec) next-index)
                    (dsh-emacs-ui-update-fragment
                     (dsh-emacs-ui-make-fragment
                      :namespace-id (nth 0 entry)
                      :block-id (nth 1 entry)
                      :label-left (concat
                                   (dsh-emacs-render--tool-leading
                                    (or (nth 3 entry) "")
                                    'pending)
                                   (propertize (nth 2 entry)
                                               'face 'dsh-emacs-tool-title-face)
                                   " "
                                   (nth next-index
                                        dsh-emacs--command-spinner-frames))
                      :style 'minimal
                      :color-key 'tool-pending))
                    ;; The label change above caused a full delete + re-insert,
                    ;; so re-apply the tool-row pending tint to the whole row.
                    (dsh-emacs-render--command-tint-running
                     (nth 0 entry) (nth 1 entry)))
                (dsh-emacs--command-spinner-stop command-id)))
          (dsh-emacs--command-spinner-stop command-id))))))

(defun dsh-emacs--command-spinner-stop (command-id)
  "Cancel COMMAND-ID's running animation and drop its state."
  (let ((rec (gethash command-id dsh-emacs--command-spinners)))
    (when rec
      (let ((timer (nth 1 rec)))
        (when (timerp timer)
          (cancel-timer timer))))
    (remhash command-id dsh-emacs--command-spinners)))

(defun dsh-emacs--command-spinner-clear-all ()
  "Cancel every running command spinner (event-stream teardown)."
  (maphash (lambda (command-id _rec)
             (dsh-emacs--command-spinner-stop command-id))
           dsh-emacs--command-spinners))

(defun dsh-emacs--command-spinner-revive ()
  "Re-arm the running-command animation after a stream reconnect.
`dsh-emacs-events-disconnect' cancels every spinner (so a detached
conversation never keeps animating); when the same chat buffer reconnects
mid-command, its rows are still on screen and still pending, so restart the
animation for each such entry.  No-op when the command already settled
(`command/done' restyled the row: color-key is no longer `tool-pending'),
the row no longer exists, or there is nothing to revive."
  (dolist (command-id (hash-table-keys dsh-emacs--command-blocks))
    (when-let* ((entry (gethash command-id dsh-emacs--command-blocks))
                (block (dsh-emacs-ui-find-block (format "%s-%s" (nth 0 entry)
                                                        (nth 1 entry))))
                (state (get-text-property (car block) 'dsh-emacs-ui-state))
                ((eq (map-elt state :color-key) 'tool-pending)))
      (dsh-emacs--command-spinner-start command-id (current-buffer)))))

(defun dsh-emacs-render--command-tint-running (ns block-id)
  "Tint running slash-command row NS-BLOCK-ID like a running tool row.
Applies `dsh-emacs-tool-pending-face' (orange, bold) to the whole block
with merge semantics, so the leading icon's Nerd Font :family survives.
The spinner tick re-inserts the row every frame, so call this after every
fragment update while the command is running."
  (when-let* ((b (dsh-emacs-ui-find-block (format "%s-%s" ns block-id))))
    (let ((inhibit-read-only t))
      (add-face-text-property (car b) (cdr b)
                              'dsh-emacs-tool-pending-face t))))

(defun dsh-emacs-render-command-optimistic (line)
  "Render a slash-command row immediately for LINE (e.g. \"/compact\").
This is the optimistic path called from `dsh-emacs--submit-prompt' before
the RPC round-trip, so the user sees the command row instantly.  The temp
entry is tracked in `dsh-emacs--pending-command' and will be replaced by
the real `command/run' event when it arrives."
  (when (and dsh-emacs-show-commands line)
    (let* ((parsed (dsh-emacs-command-parse line))
           (name (car parsed))
           (args (cdr parsed))
           (temp-id (format "pending-%s" name))
           (label (dsh-emacs-render-command-label
                   (concat "/" name) args))
           (icon (dsh-emacs-render--tool-icon "bash"))
           (ns (dsh-emacs-render--make-namespace))
           (block-id (format "cmd-%s" temp-id)))
      (when (and name (not (gethash temp-id dsh-emacs--command-blocks)))
        (puthash temp-id (list ns block-id label icon)
                 dsh-emacs--command-blocks)
        (setq dsh-emacs--pending-command (list temp-id label))
        (dsh-emacs-ui-update-fragment
         (dsh-emacs-ui-make-fragment
          :namespace-id ns :block-id block-id
          :label-left (concat
                       (dsh-emacs-render--tool-leading icon 'pending)
                       (propertize label 'face 'dsh-emacs-tool-title-face)
                       " "
                       (car dsh-emacs--command-spinner-frames))
          :style 'minimal
          :color-key 'tool-pending)
         :create-new t :expanded t
         :insert-before (dsh-emacs-render--input-insert-point))
        (dsh-emacs-render--command-tint-running ns block-id)
        (dsh-emacs--command-spinner-start temp-id
                                          (current-buffer))))))

(defun dsh-emacs-render-command-cleanup-optimistic ()
  "Remove the optimistic slash-command row (if any) on RPC error or miss.
Stops the spinner, deletes the fragment, and clears `dsh-emacs--pending-command'."
  (when dsh-emacs--pending-command
    (let* ((temp-id (nth 0 dsh-emacs--pending-command))
           (entry (gethash temp-id dsh-emacs--command-blocks)))
      (dsh-emacs--command-spinner-stop temp-id)
      (when entry
        (let* ((qualified-id (format "%s-%s" (nth 0 entry) (nth 1 entry)))
               (block (dsh-emacs-ui-find-block qualified-id)))
          (when block
            (let ((inhibit-read-only t))
              (delete-region (car block) (cdr block))))))
      (remhash temp-id dsh-emacs--command-blocks))
    (setq dsh-emacs--pending-command nil)))

(defun dsh-emacs-render-command (event)
  "Render a `command/run' or `command/done' EVENT as one flow node,
mirroring dsh web's command rows: a leading bash terminal icon (the same
dsh-web SVG as bash tool rows, the `💻' emoji in terminal Emacs) followed
by the command name and a classic `-\|/' spinner while running (see
`dsh-emacs--command-spinner-frames');
on completion the header shows only the command name + a short status
(`✓ done' / `✗ failed', green on success, red on error), and the outcome
text is folded into a collapsible body below, collapsed by default.

Run creates the node; done (matched by commandId) restyles it — success
turns the row green, error red.  Events on load render in seq order, so
a run followed by its done (the usual shape) becomes a single node.
Returns the event seq."
  (let ((seq (dsh-emacs-render--event-seq event)))
    (when dsh-emacs-show-commands
      (let* ((type (dsh-emacs-render--aget "type" event))
             (data (dsh-emacs-render--event-data event))
             (command-id (dsh-emacs-render--aget "commandId" data))
             (ns (dsh-emacs-render--make-namespace)))
        (when command-id
          (let* ((block-id (format "cmd-%s" command-id))
                 (label (dsh-emacs-render-command-label
                         (dsh-emacs-render--aget "name" data)
                         (dsh-emacs-render--aget "args" data)))
                 (icon (dsh-emacs-render--tool-icon "bash")))
            (if (equal type "command/run")
                (progn
                  ;; Clean up the optimistic row if one is pending for
                  ;; this command name (instant feedback → real event).
                  (when dsh-emacs--pending-command
                    (let* ((temp-id (nth 0 dsh-emacs--pending-command))
                           (temp-entry (gethash temp-id
                                                dsh-emacs--command-blocks)))
                      (dsh-emacs--command-spinner-stop temp-id)
                      (when temp-entry
                        (let* ((qid (format "%s-%s"
                                            (nth 0 temp-entry)
                                            (nth 1 temp-entry)))
                               (blk (dsh-emacs-ui-find-block qid)))
                          (when blk
                            (let ((inhibit-read-only t))
                              (delete-region (car blk) (cdr blk))))))
                      (remhash temp-id dsh-emacs--command-blocks))
                    (setq dsh-emacs--pending-command nil))
                  ;; Now render with the real command-id.
                  (puthash command-id (list ns block-id label icon)
                           dsh-emacs--command-blocks)
                  (dsh-emacs-ui-update-fragment
                   (dsh-emacs-ui-make-fragment
                    :namespace-id ns :block-id block-id
                    :label-left (concat
                                 (dsh-emacs-render--tool-leading icon 'pending)
                                 (propertize label 'face 'dsh-emacs-tool-title-face)
                                 " "
                                 (car dsh-emacs--command-spinner-frames))
                    :style 'minimal
                    :color-key 'tool-pending)
                   :create-new t :expanded nil
                   :insert-before (dsh-emacs-render--input-insert-point))
                  (dsh-emacs-render--command-tint-running ns block-id)
                  (dsh-emacs--command-spinner-start command-id
                                                    (current-buffer)))
              (when-let* ((entry (gethash command-id
                                          dsh-emacs--command-blocks)))
                (dsh-emacs--command-spinner-stop command-id)
                (let* ((kind (dsh-emacs-render--aget "kind" data))
                       (ok (not (equal kind "error")))
                       (state (if ok 'success 'error))
                       (text (dsh-emacs-render--aget "text" data))
                       (entry-icon (or (nth 3 entry)
                                       (dsh-emacs-render--tool-icon "bash")))
                       (qualified-id (format "%s-%s" (nth 0 entry)
                                             (nth 1 entry))))
                  (dsh-emacs-ui-update-fragment
                   (dsh-emacs-ui-make-fragment
                    :namespace-id (nth 0 entry) :block-id (nth 1 entry)
                    :label-left (concat
                                 (dsh-emacs-render--tool-leading entry-icon state)
                                 (propertize (nth 2 entry)
                                             'face 'dsh-emacs-tool-title-face))
                    ;; The header shows only the command name + a short status,
                    ;; never the (possibly long, multi-line) result.  The result
                    ;; body is a collapsible section below, collapsed by default,
                    ;; so `goal' is not truncated to `goal…' by top-border.
                    :label-right (propertize
                                   (or (dsh-emacs-render--command-status-text state)
                                       "")
                                   'face (if ok
                                             'dsh-emacs-tool-success-face
                                           'dsh-emacs-tool-error-face))
                    :body (and (stringp text) (not (string-empty-p text)) text)
                    :style 'minimal
                    :color-key (if ok 'tool-success 'tool-error))
                   :create-new nil)
                  (dsh-emacs-ui-restyle-block
                   qualified-id (if ok 'tool-success 'tool-error))
                  ;; 节点边框/正文着色与状态一致（merge 保留 icon 的 :family）
                  (when-let* ((b (dsh-emacs-ui-find-block qualified-id)))
                    (let ((inhibit-read-only t))
                      (add-face-text-property
                       (car b) (cdr b)
                       (if ok
                           'dsh-emacs-tool-success-face
                         'dsh-emacs-tool-error-face)
                       t))))))))))
    seq))

;;; ---------------------------------------------------------------------------
;;; 顶层 dispatcher
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render-event (event)
  "Dispatch EVENT to the appropriate renderer. Returns the event seq, or nil."
  (let* ((type (dsh-emacs-render--aget "type" event))
         (seq nil))
    (pcase type
      ("user/message" (setq seq (dsh-emacs-render-user-message event)))
      ("assistant/chunk" (setq seq (dsh-emacs-render-assistant-chunk event)))
      ("assistant/message" (setq seq (dsh-emacs-render-assistant-message event))
                           (when (fboundp 'dsh-emacs-modeline-note-event)
                             (dsh-emacs-modeline-note-event event)))
      ("request/context" (setq seq (dsh-emacs-render--event-seq event))
                         (when (fboundp 'dsh-emacs-modeline-note-request)
                           (dsh-emacs-modeline-note-request event)))
      ("request/header" (setq seq (dsh-emacs-render--event-seq event))
                        (when (fboundp 'dsh-emacs-modeline-note-header)
                          (dsh-emacs-modeline-note-header event)))
      ("tool/call" (setq seq (dsh-emacs-render-tool-call event)))
      ("tool/result" (setq seq (dsh-emacs-render-tool-result event)))
      ("command/run" (setq seq (dsh-emacs-render-command event)))
      ("command/done" (setq seq (dsh-emacs-render-command event)))
      ("turn/start" (setq seq (dsh-emacs-render-turn-start event)))
      ("turn/end" (setq seq (dsh-emacs-render-turn-end event)))
      (_ nil))
    (when (and (integerp seq)
               (boundp 'dsh-emacs--anchor-seq)
               (> seq (or dsh-emacs--anchor-seq 0)))
      (setq dsh-emacs--anchor-seq seq))
    seq))

(defun dsh-emacs-render--consume-pending-user-message (event)
  "Consume one optimistic user message matching EVENT, if present."
  (when (and (boundp 'dsh-emacs--pending-user-messages)
             (equal (dsh-emacs-render--aget "type" event) "user/message"))
    (let* ((data (dsh-emacs-render--event-data event))
           (text (dsh-emacs-render--text-from-content
                  (dsh-emacs-render--aget "content" data)))
           (pending dsh-emacs--pending-user-messages)
           (matched nil)
           remaining)
      (dolist (message pending)
        (if (and (not matched) (equal message text))
            (setq matched t)
          (push message remaining)))
      (when matched
        (setq dsh-emacs--pending-user-messages (nreverse remaining)))
      matched)))

(defun dsh-emacs-render--trim-buffer ()
  "Trim old transcript content when the buffer exceeds `dsh-emacs-max-buffer-size'.
Deletes the earliest content while preserving the input prompt area."
  (when (and dsh-emacs-max-buffer-size
             (> (buffer-size) dsh-emacs-max-buffer-size))
    (let* ((limit dsh-emacs-max-buffer-size)
           (trim-to (- (point-max) (/ limit 2))))
      (when (> trim-to (point-min))
        (let ((inhibit-read-only t))
          (delete-region (point-min) trim-to))))))

(defun dsh-emacs-render-history-events (events &optional stream)
  "Render EVENTS in seq order, optionally processing live STREAM chunks.
EVENTS is a vector/sequence of {\"event\": alist} entries.  Renders only
entries with seq > `dsh-emacs--anchor-seq'.  During an initial history load,
STREAM should be nil: completed `assistant/message' snapshots are sufficient
and avoid replaying thousands of old deltas.  Polling passes STREAM non-nil
to render new `assistant/chunk' events as they arrive.
The loop yields to the input queue every 5 events so that user keystrokes
interrupt the batch and keep the UI responsive."
  (let ((rendered 0)
        (entries (if (vectorp events) (append events nil) events))
        (counter 0))
    (while-no-input
      (dolist (entry entries)
        (let* ((ev (dsh-emacs-render--aget "event" entry))
               (seq (and ev (dsh-emacs-render--event-seq ev))))
          (when (and ev
                     (> (or seq 0) (or dsh-emacs--anchor-seq 0))
                     (or stream
                         (not (equal (dsh-emacs-render--aget "type" ev)
                                     "assistant/chunk"))))
            (if (dsh-emacs-render--consume-pending-user-message ev)
                ;; The optimistic copy is already visible.  Still advance the
                ;; anchor so this canonical event is not processed repeatedly.
                (when (integerp seq)
                  (setq dsh-emacs--anchor-seq seq))
              (when (dsh-emacs-render-event ev)
                (setq rendered (1+ rendered)))))
          ;; Yield every 5 events so the user can interrupt and see progress.
          (cl-incf counter)
          (when (and (>= counter 5) (sit-for 0))
            (setq counter 0)))))
    (when (> rendered 0)
      (dsh-emacs-render--follow-stream)
      (dsh-emacs-render--trim-buffer))
    rendered))

(provide 'dsh-emacs-render)

;;; dsh-emacs-render.el ends here
