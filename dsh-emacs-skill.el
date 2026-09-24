;;; dsh-emacs-skill.el --- Skill catalog (skills/list) and /name gestures -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.5.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; dsh skills are host-side instruction bundles (a SKILL.md plus optional
;; resources) that a Session sees through its cwd + agent-preset composition.
;; The `skills' namespace has exactly one endpoint — `skills/list' (typert
;; Remote, HTTP path /api/skills/list, args {request: {sessionId}}, value
;; {skills: SkillEntry[]}) — and this file provides:
;;
;;   - `dsh-emacs-skill-catalog'         per-session cached catalog (read)
;;   - `dsh-emacs-skill-catalog-fetch' / `dsh-emacs-skill-catalog-sync'
;;                                       async / sync fetch and cache
;;   - `dsh-emacs-skill-catalog-invalidate' / `...-catalog-refresh'
;;                                       drop and re-fetch the cache
;;   - `dsh-emacs-skill-prefetch'        warm the cache when a session opens
;;   - `dsh-emacs-skill-label'           the description as shown in the "/"
;;                                       list (user-only skills marked)
;;   - `dsh-emacs-skill-open'            open the picked skill's SKILL.md
;;
;; Skills have no menu of their own: they share the "/" surface with the
;; command registry, so `dsh-emacs-command' in dsh-emacs-command.el lists both
;; catalogs and inserts the "/name " gesture when a skill is picked.
;;
;; **Invoking a skill has no wire of its own.**  It is an ordinary prompt
;; whose text carries a `/name' gesture wherever a word can start; the host's
;; skill tool scans the direct user input for that gesture and injects the
;; skill body as a user message before the next step.  A user-only skill (no
;; `modelInvocable') is just as invocable — it only cannot be loaded through
;; the model-facing `skill' tool.  So the client never calls a "run skill"
;; RPC: the "/" completion and the slash menu in `dsh-emacs-command.el'
;; (which merge this catalog into the command candidates) only help name the
;; gesture, and the existing send path (`dsh-emacs--submit-prompt') delivers
;; it.  A `/name' line is first offered to `commands.execute'; a
;; skill name is not a registered command, so the host declines it and the
;; admission-miss fallback sends the line as an ordinary prompt — the same end
;; state as dsh web, which routes a skill pick straight into the composer.
;;
;; The catalog is a cold read of the session's current composition, so
;; switching the agent preset can change it; `dsh-emacs-skill-catalog-refresh'
;; re-reads it on demand.

;;; Code:

(require 'cl-lib)
(require 'dsh-emacs-protocol)

(declare-function dsh-emacs--rpc-async "dsh-emacs.el" (method params callback))
(declare-function dsh-emacs--rpc-request "dsh-emacs.el" (method params))
(declare-function dsh-emacs--active-session-id "dsh-emacs.el" ())

(defgroup dsh-emacs-skill nil
  "Skill catalog (skills/list) and its /name gestures."
  :group 'dsh-emacs)

(defcustom dsh-emacs-skill-prefetch t
  "Whether opening a session pre-fetches its `skills/list' catalog.
The fetch runs on a short timer after the chat buffer opens, so the
catalog is already cached by the time the first \"/\" or TAB is typed
— no synchronous round trip on the first completion.  The prefetch is
a no-op when the catalog has already been fetched."
  :type 'boolean
  :group 'dsh-emacs-skill)

(defcustom dsh-emacs-skill-prefetch-delay 0.5
  "Delay (seconds) before the `skills/list' pre-fetch runs.
Keeps the prefetch from racing the session-history load that also
starts when the chat buffer opens.  A plain timer is used (not an idle
one), so the catalog still lands while a reply streams — an idle timer
would be starved by the pending event-stream output."
  :type 'number
  :group 'dsh-emacs-skill)

(defvar dsh-emacs--skill-catalogs nil
  "Alist of (SESSION-ID . ITEMS) caching `skills/list' catalogs.
ITEMS is a list of `dsh-protocol-skill' structs in the host's order.  A
session whose catalog is genuinely empty keeps an entry with nil ITEMS,
so a later completion does not re-fetch it.")

(defvar dsh-emacs--skill-fetch-inflight nil
  "List of SESSION-IDs whose `skills/list' fetch is still in flight.
Guards the completion warm-up so repeated TAB presses do not stack
requests; drained by the fetch callback.")

(defvar dsh-emacs--skill-fetch-generation 0
  "Monotonic counter stamping each `skills/list' fetch.
Only the response whose stamp is still its session's current one may
write the cache or clear the in-flight flag, so a fetch superseded by
`dsh-emacs-skill-catalog-invalidate' cannot repopulate a cache that was
just dropped.")

(defvar dsh-emacs--skill-fetch-stamps nil
  "Alist of (SESSION-ID . STAMP) naming each session's current fetch.
A session absent from this list has no admissible response in flight.")

;; ---------------------------------------------------------------------------
;; Catalog (skills/list)
;; ---------------------------------------------------------------------------

(defun dsh-emacs-skill--parse (value)
  "Return VALUE (a `skills/list' response) as a list of `dsh-protocol-skill'."
  (dsh-protocol-skill-list-skills
   (dsh-protocol-skill-list--from-alist value)))

(defun dsh-emacs-skill--fetched-p (session-id)
  "Non-nil when SESSION-ID's catalog has been fetched (even when empty)."
  (assoc session-id dsh-emacs--skill-catalogs))

(defun dsh-emacs-skill-catalog (&optional session-id)
  "Return the cached skill catalog (list of `dsh-protocol-skill') for
SESSION-ID (default: the active session), or nil when not yet fetched."
  (cdr (assoc (or session-id (dsh-emacs--active-session-id))
              dsh-emacs--skill-catalogs)))

(defun dsh-emacs-skill--cache-catalog (session-id items)
  "Store ITEMS as the cached skill catalog of SESSION-ID."
  (setq dsh-emacs--skill-catalogs
        (cons (cons session-id items)
              (assoc-delete-all session-id dsh-emacs--skill-catalogs))))

(defun dsh-emacs-skill-catalog-invalidate (session-id)
  "Drop the cached catalog (and any in-flight fetch flag) of SESSION-ID.
A later `dsh-emacs-skill-catalog' / completion trigger re-fetches from
the server.  A response still in flight for SESSION-ID is superseded: it
can no longer repopulate the dropped cache nor clear a newer fetch's
flag."
  (setq dsh-emacs--skill-catalogs
        (assoc-delete-all session-id dsh-emacs--skill-catalogs)
        dsh-emacs--skill-fetch-inflight
        (delete session-id dsh-emacs--skill-fetch-inflight)
        dsh-emacs--skill-fetch-stamps
        (assoc-delete-all session-id dsh-emacs--skill-fetch-stamps)))

(defun dsh-emacs-skill-catalog-fetch (session-id &optional callback)
  "Fetch the `skills/list' catalog of SESSION-ID asynchronously.
Caches the result; CALLBACK (optional) receives the item list (nil on
failure — the error is already reported).  A fetch already in flight
for SESSION-ID is not duplicated, and a response whose fetch
`dsh-emacs-skill-catalog-invalidate' superseded is dropped instead of
overwriting the newer catalog."
  (unless (member session-id dsh-emacs--skill-fetch-inflight)
    (setq dsh-emacs--skill-fetch-inflight
          (cons session-id dsh-emacs--skill-fetch-inflight))
    (let ((stamp (setq dsh-emacs--skill-fetch-generation
                       (1+ dsh-emacs--skill-fetch-generation))))
      (setq dsh-emacs--skill-fetch-stamps
            (cons (cons session-id stamp)
                  (assoc-delete-all session-id dsh-emacs--skill-fetch-stamps)))
      (dsh-emacs--rpc-async
       "skills/list"
       `((request . ((sessionId . ,session-id))))
       (lambda (ok value)
         (when (equal stamp
                      (cdr (assoc session-id dsh-emacs--skill-fetch-stamps)))
           (setq dsh-emacs--skill-fetch-inflight
                 (delete session-id dsh-emacs--skill-fetch-inflight))
           (let ((items (and ok (dsh-emacs-skill--parse value))))
             (when ok
               (dsh-emacs-skill--cache-catalog session-id items))
             (when (functionp callback)
               ;; The callback may run inside a process filter: swallow the C-g quit.
               (condition-case nil
                   (funcall callback (and ok items))
                 (quit nil))))))))))

(defun dsh-emacs-skill-catalog-sync (session-id)
  "Fetch and cache the `skills/list' catalog of SESSION-ID synchronously.
Returns the item list (possibly empty), or nil on failure (a message is
emitted).  A catalog already fetched — even an empty one — is returned
from cache without a round trip.  A new synchronous fetch supersedes older
requests, and may itself be superseded while the RPC processes events."
  (if (dsh-emacs-skill--fetched-p session-id)
      (dsh-emacs-skill-catalog session-id)
    (let ((stamp (setq dsh-emacs--skill-fetch-generation
                       (1+ dsh-emacs--skill-fetch-generation))))
      (setq dsh-emacs--skill-fetch-stamps
            (cons (cons session-id stamp)
                  (assoc-delete-all session-id dsh-emacs--skill-fetch-stamps)))
      (cl-pushnew session-id dsh-emacs--skill-fetch-inflight :test #'equal)
      (unwind-protect
          (let ((res (dsh-emacs--rpc-request
                      "skills/list"
                      `((request . ((sessionId . ,session-id)))))))
            (if (not (equal stamp
                            (cdr (assoc session-id
                                        dsh-emacs--skill-fetch-stamps))))
                (dsh-emacs-skill-catalog session-id)
              (if (car res)
                  (let ((items (dsh-emacs-skill--parse (cdr res))))
                    (dsh-emacs-skill--cache-catalog session-id items)
                    items)
                (message "Failed to list skills: %S" (cdr res))
                nil)))
        ;; Never clear a newer request's guard after a refresh during the wait.
        (when (equal stamp
                     (cdr (assoc session-id dsh-emacs--skill-fetch-stamps)))
          (setq dsh-emacs--skill-fetch-inflight
                (delete session-id dsh-emacs--skill-fetch-inflight)
                dsh-emacs--skill-fetch-stamps
                (assoc-delete-all session-id dsh-emacs--skill-fetch-stamps)))))))

(defun dsh-emacs-skill-prefetch (session-id)
  "Pre-fetch the `skills/list' catalog of SESSION-ID lazily.
Called when a chat buffer opens: the catalog is fetched on a short
timer (see `dsh-emacs-skill-prefetch-delay') so the first \"/\"
completion does not block on the network.  No-op unless
`dsh-emacs-skill-prefetch' is enabled, the catalog has not been fetched
and no fetch is already in flight.  Returns the timer, or nil."
  (when (and dsh-emacs-skill-prefetch
             session-id
             (not (dsh-emacs-skill--fetched-p session-id))
             (not (member session-id dsh-emacs--skill-fetch-inflight)))
    (run-at-time
     dsh-emacs-skill-prefetch-delay nil
     (lambda (sid)
       (dsh-emacs-skill-catalog-fetch sid))
     session-id)))

(defun dsh-emacs-skill-catalog-refresh (&optional session-id)
  "Re-fetch and re-cache the `skills/list' catalog, then report.
Refreshes SESSION-ID (default: the active session), which is useful
after the agent preset changed while a session stays open.  Runs
asynchronously; the result is shown via message."
  (interactive)
  (let ((sid (or session-id (dsh-emacs--active-session-id))))
    (unless sid (user-error "Open or select a session first"))
    (dsh-emacs-skill-catalog-invalidate sid)
    (dsh-emacs-skill-catalog-fetch
     sid
     ;; The callback gets nil items both when the fetch failed and when the
     ;; session genuinely has no skills, so the cache entry (not the item list)
     ;; tells the two apart.
     (lambda (items)
       (if (dsh-emacs-skill--fetched-p sid)
           (message "Skills refreshed: %d available" (length items))
         (message "Skill refresh failed (see *Messages*)"))))))

;; ---------------------------------------------------------------------------
;; Presentation and file access
;; The picker itself lives with the "/" surface in dsh-emacs-command.el: one
;; menu lists the command and skill catalogs and acts by item type.
;; ---------------------------------------------------------------------------

(defun dsh-emacs-skill-label (skill)
  "Return the display label of SKILL: its description, marked when user-only.
A skill without `modelInvocable' cannot be loaded by the model through
the `skill' tool, but the user may still invoke it — so wherever skills
are listed (the \"/\" completion and the slash menu) the row says so,
the same wording dsh web uses."
  (let ((description (or (dsh-protocol-skill-description skill) "")))
    (if (dsh-protocol-skill-model-invocable skill)
        description
      (format "user-only · %s" description))))

(defun dsh-emacs-skill-open (skill)
  "Open SKILL's `SKILL.md' file, or report that the provider ships none.
SKILL is a `dsh-protocol-skill'; its PATH comes from the host (dsh
0.1.6+) and is absent for providers that manage their own resources."
  (let ((path (dsh-protocol-skill-path skill)))
    (if path
        (find-file path)
      (user-error "Skill /%s has no SKILL.md path"
                  (dsh-protocol-skill-name skill)))))

(provide 'dsh-emacs-skill)

;;; dsh-emacs-skill.el ends here
