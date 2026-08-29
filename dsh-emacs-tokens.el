;;; dsh-emacs-tokens.el --- Token usage tracking and formatting -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.1.0
;; License: GPL-3.0-or-later
;; Package-Requires ((emacs "27.1"))

;;; Commentary:

;; Token 用量跟踪与格式化（参考 pi-mono 的 formatTokens / pi-tui）。
;;
;; 公开 API：
;;
;;   (dsh-emacs-format-tokens 12345)
;;     => "12.3k"
;;
;;   (dsh-emacs-format-tokens 1234567)
;;     => "1.2M"
;;
;;   (dsh-emacs-usage-from-event assistant/message-event-alist)
;;     => (:input 626 :output 155 :cache-read 7168 :cache-write 0 :cost 0.0)
;;
;; 真实 dsh 事件把用量对象放在 `data.usage'，键名为 camelCase：
;; inputTokens / outputTokens / cacheReadTokens（cacheWriteTokens、cost
;; 当服务端上报时才有）。同时兼容早期短键名 input/output/cacheRead。
;;
;; 用法：render 层每收到一个 assistant/message 事件调用
;; `dsh-emacs-modeline-note-event' 累计，mode-line 用 `dsh-emacs-format-tokens' /
;; `dsh-emacs-format-cost' 显示。

;;; Code:

(require 'cl-lib)

;;; ---------------------------------------------------------------------------
;;; 数值格式化
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-format-tokens (count)
  "Format COUNT (an integer) as a compact token count.
  12345 -> \"12.3k\", 1234567 -> \"1.2M\"."
  (cond
   ((null count) "0")
   ((not (numberp count)) "0")
   ((< count 1000) (number-to-string count))
   ((< count 10000) (format "%.1fk" (/ count 1000.0)))
   ((< count 1000000) (format "%dk" (/ (float count) 1000)))
   ((< count 10000000) (format "%.1fM" (/ count 1000000.0)))
   (t (format "%dM" (/ count 1000000)))))

(defun dsh-emacs-format-cost (cost)
  "Format COST (a USD number) as a dollar amount ($X.YYY)."
  (cond
   ((null cost) "$0.000")
   ((not (numberp cost)) "$0.000")
   ((< cost 0.001) "<$0.001")
   (t (format "$%.3f" cost))))

(defun dsh-emacs-format-percent (pct)
  "Format PCT (0..100) as a percentage string (with 1 decimal place)."
  (cond
   ((null pct) "?%")
   ((not (numberp pct)) "?%")
   ((< 0 pct 0.05) "0.0%")
   (t (format "%.1f%%" pct))))

;;; ---------------------------------------------------------------------------
;;; usage plist
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-usage-p (obj)
  "Return t if OBJ is a usage plist."
  (and (listp obj)
       (keywordp (car-safe obj))
       (memq :input obj)))

(defun dsh-emacs-make-usage (&optional input output cache-read cache-write cost)
  "Create a new usage plist with the given keys."
  (list :input (or input 0)
        :output (or output 0)
        :cache-read (or cache-read 0)
        :cache-write (or cache-write 0)
        :cost (or cost 0.0)))

(defun dsh-emacs-usage-zero ()
  "Return a zero usage plist."
  (dsh-emacs-make-usage))

(defun dsh-emacs-usage-input (usage)
  "Get input tokens from USAGE plist."
  (plist-get usage :input))

(defun dsh-emacs-usage-output (usage)
  "Get output tokens from USAGE plist."
  (plist-get usage :output))

(defun dsh-emacs-usage-cache-read (usage)
  "Get cache-read tokens from USAGE plist."
  (plist-get usage :cache-read))

(defun dsh-emacs-usage-cache-write (usage)
  "Get cache-write tokens from USAGE plist."
  (plist-get usage :cache-write))

(defun dsh-emacs-usage-cost (usage)
  "Get cost from USAGE plist."
  (plist-get usage :cost))

(defun dsh-emacs-set-usage-input (usage value)
  "Set input tokens in USAGE plist to VALUE."
  (plist-put usage :input value))

(defun dsh-emacs-set-usage-output (usage value)
  "Set output tokens in USAGE plist to VALUE."
  (plist-put usage :output value))

(defun dsh-emacs-set-usage-cache-read (usage value)
  "Set cache-read tokens in USAGE plist to VALUE."
  (plist-put usage :cache-read value))

(defun dsh-emacs-set-usage-cache-write (usage value)
  "Set cache-write tokens in USAGE plist to VALUE."
  (plist-put usage :cache-write value))

(defun dsh-emacs-set-usage-cost (usage value)
  "Set cost in USAGE plist to VALUE."
  (plist-put usage :cost value))

(defun dsh-emacs-usage-add (existing usage-or-raw)
  "Add USAGE-OR-RAW into EXISTING (a usage plist) and return it.
USAGE-OR-RAW may be either a usage plist (see `dsh-emacs-make-usage') or a
raw dsh `usage' alist parseable by `dsh-emacs-usage-from-message'."
  (let ((parsed (if (and (listp usage-or-raw)
                         (keywordp (car usage-or-raw)))
                    usage-or-raw
                  (dsh-emacs-usage-from-message usage-or-raw))))
    (dsh-emacs-set-usage-input existing
      (+ (dsh-emacs-usage-input existing)
         (dsh-emacs-usage-input parsed)))
    (dsh-emacs-set-usage-output existing
      (+ (dsh-emacs-usage-output existing)
         (dsh-emacs-usage-output parsed)))
    (dsh-emacs-set-usage-cache-read existing
      (+ (dsh-emacs-usage-cache-read existing)
         (dsh-emacs-usage-cache-read parsed)))
    (dsh-emacs-set-usage-cache-write existing
      (+ (dsh-emacs-usage-cache-write existing)
         (dsh-emacs-usage-cache-write parsed)))
    (dsh-emacs-set-usage-cost existing
      (+ (dsh-emacs-usage-cost existing)
         (dsh-emacs-usage-cost parsed)))
    existing))

(defun dsh-emacs-usage-from-message (usage-alist)
  "Parse USAGE-ALIST (a raw dsh `usage' object) into a usage plist.
Real dsh events carry the usage object at `data.usage' with camelCase keys:
inputTokens / outputTokens / cacheReadTokens (plus cacheWriteTokens and
cost when the server reports them).  The legacy short keys
(input/output/cacheRead/cacheWrite/cost) are also tolerated.  Returns a
zero usage when USAGE-ALIST is nil or carries no token numbers."
  (dsh-emacs-make-usage
   (or (dsh-emacs-usage-get usage-alist "inputTokens")
       (dsh-emacs-usage-get usage-alist "input") 0)
   (or (dsh-emacs-usage-get usage-alist "outputTokens")
       (dsh-emacs-usage-get usage-alist "output") 0)
   (or (dsh-emacs-usage-get usage-alist "cacheReadTokens")
       (dsh-emacs-usage-get usage-alist "cacheRead") 0)
   (or (dsh-emacs-usage-get usage-alist "cacheWriteTokens")
       (dsh-emacs-usage-get usage-alist "cacheWrite") 0)
   (or (dsh-emacs-usage-get usage-alist "cost") 0.0)))

(defun dsh-emacs-usage-from-event (event-alist)
  "From an `assistant/message' EVENT-ALIST, return its usage struct.
Real dsh events carry the usage object at `data.usage'; an event without
one yields a zero struct."
  (dsh-emacs-usage-from-message
   (dsh-emacs--alist-state
    (dsh-emacs--alist-state event-alist "data")
    "usage")))

(defun dsh-emacs-ctx-face (pct)
  "Return the appropriate mode-line context face for PCT."
  (cond
   ((or (null pct) (not (numberp pct))) 'dsh-emacs-modeline-face)
   ((< pct 50.0) 'dsh-emacs-modeline-ctx-ok-face)
   ((< pct 80.0) 'dsh-emacs-modeline-ctx-warn-face)
   (t 'dsh-emacs-modeline-ctx-crit-face)))

;;; ---------------------------------------------------------------------------
;;; alist helpers（不依赖 dsh-emacs.el 内部的 dsh-emacs--alist-get）
;;; ---------------------------------------------------------------------------

(defun dsh-emacs--alist-state (alist key)
  "Get KEY's value from ALIST, or nil.
Tolerates both string and symbol keys: real dsh payloads decoded by
`json-read' are symbol-keyed, while render call sites and tests use JSON
field names (strings).  ALIST may also be a vector of (KEY . VALUE) cells."
  (let ((alternate (if (stringp key) (intern key) (symbol-name key))))
    (cond
     ((listp alist)
      (or (cdr (assoc key alist))
          (cdr (assoc alternate alist))))
     ((vectorp alist)
      (catch 'found
        (dotimes (i (length alist))
          (let ((pair (aref alist i)))
            (when (and (consp pair)
                       (or (equal (car pair) key)
                           (equal (car pair) alternate)))
              (throw 'found (cdr pair))))))))))

(defun dsh-emacs-usage-get (usage-alist key)
  "Get numeric KEY's value from a usage alist (tolerates strings / numbers)."
  (let ((raw (dsh-emacs--alist-state usage-alist key)))
    (cond
     ((null raw) nil)
     ((numberp raw) raw)
     ((stringp raw)
      (condition-case nil (string-to-number raw) (error nil)))
     (t nil))))

(provide 'dsh-emacs-tokens)

;;; dsh-emacs-tokens.el ends here