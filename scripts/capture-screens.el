;;; capture-screens.el --- export dsh-emacs frames as PNG (README screenshots)
;;;
;;; The README shows two screenshots (assets/sessions.png, assets/chat.png).
;;; Frame-to-PNG export needs a GUI frame and the build's own exporter
;;; (`ns-export-frames' on macOS, `x-export-frames' on X11, `w32-export-frames'
;;; on Windows) — none exist in a batch/headless session, so run this in your
;;; normal GUI Emacs:
;;;
;;;   M-x load-file RET scripts/capture-screens.el RET
;;;
;;;   # session list view:
;;;   M-x dsh-emacs RET
;;;   M-x dsh-emacs-screenshot RET sessions RET
;;;
;;;   # chat buffer view (open any session first):
;;;   M-x dsh-emacs-screenshot RET chat RET
;;;
;;; Each shot writes assets/<name>.png next to the package (relative to the
;;; loaded dsh-emacs library), which is what the README references.

;;; Code:

(require 'cl-lib)

(defvar dsh-emacs-screenshot-dir
  (expand-file-name "assets/"
                    (file-name-directory (locate-library "dsh-emacs")))
  "Directory screenshots are written to.")

(defun dsh-emacs--screenshot-exporter ()
  "Return this build's frame-to-PNG exporter function, or nil."
  (cl-loop for fn in '(ns-export-frames x-export-frames w32-export-frames)
           when (fboundp fn) return fn))

;;;###autoload
(defun dsh-emacs-screenshot (name)
  "Export the selected frame as assets/NAME.png.
NAME is any string; the README expects \"sessions\" and \"chat\"."
  (interactive "sImage name: ")
  (when (not (display-graphic-p))
    (user-error "Screenshots need a GUI frame (this session has no display)"))
  (let ((exporter (dsh-emacs--screenshot-exporter)))
    (unless exporter
      (user-error "No frame-export support in this Emacs build \
\(need ns-/x-/w32-export-frames)"))
    (make-directory dsh-emacs-screenshot-dir t)
    (let ((file (expand-file-name (concat name ".png")
                                  dsh-emacs-screenshot-dir)))
      (funcall exporter nil file)
      (message "Wrote %S — add it to the README and commit" file))))

(provide 'capture-screens)

;;; capture-screens.el ends here