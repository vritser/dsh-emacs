# 049 — Restore an archived session from the session list

## Background

Archiving was one-way inside Emacs.  `d` in `*dsh-sessions*`
(`dsh-emacs-archive-session-at-point`) and `M-x dsh-emacs-archive-session`
call `workspace/archiveSession` (`dsh-emacs.el`); the success callback stores
the returned `archivedSessionIds` in `dsh-emacs--archived-sessions`,
`workspace/follow`'s `archived` frame keeps that set fresh
(`dsh-emacs-events--host-set-archived`), and `dsh-emacs-session--visible-p`
hides those rows from the list.  No code called the inverse.

The archive set is registry-global on the host, so a session archived from
Emacs could only be recovered from another surface.  dsh 0.1.6 supplies that
inverse: `workspace/unarchiveSession`
(`packages/api/workspace-controller`, tag `dsh-v0.1.6-alpha.1` /
`0a15e36e7f`), idempotent ("an id that is not archived is not an error") and
returning the same `{ archivedSessionIds }` value as the archive call, so the
client's existing cache-replacement step applies unchanged.

## Decision

Add `dsh-emacs-unarchive-session` next to its archive sibling in
`dsh-emacs.el`, plus `dsh-emacs--archived-session-p` (a session-struct
predicate over the cached archive set) and two optional parameters on
`dsh-emacs--completing-session-id` (`FILTER` and `EMPTY-MESSAGE`).  The
session list binds `u` to the command.  On success the returned archive set
replaces `dsh-emacs--archived-sessions` and `dsh-emacs-list-sessions`
refreshes — the same two steps the archive callback already ran.

## Why

- The pair becomes symmetric: archive had no in-client inverse, and the miss
  was reachable in one keystroke.  The change is an RPC mirror, one predicate,
  and one keybinding.
- The picker offers the **archived rows**, not the raw id set: `session/list`
  still returns archived sessions (the host's "visible" filter is the
  client's own `dsh-emacs-session--visible-p`), so the completion can show
  the same display titles as every other session picker.  This mirrors dsh
  web's archived-sessions page, which joins `archivedSessionIds` with loaded
  summaries and drops ids it cannot title.
- The two optional parameters were chosen over a second picker function: the
  display-title formatting and the id/index plumbing have one owner, and the
  existing callers (rename, archive, fork) keep their behavior by omission.
- `u` in the list rather than `M-x` only: the action targets a set the list
  deliberately hides, so the discoverable place is the keymap beside `d`.
- Rejected: an "Archived" group inside `*dsh-sessions*`.  The list hides
  archived rows to match dsh web's sidebar, and a group would change what the
  default view shows for an action that is rare.
- Rejected: offering bare session ids for archived entries with no loaded
  summary.  dsh web declines to restore those (its "No archived session here
  can be restored." state), and a uuid-only completion row carries no
  information a user can act on.

## Consequence

- New command `dsh-emacs-unarchive-session`; new session-list key `u`
  (`dsh-emacs-session-mode-map`); `docs/customization.md` session controls
  and the `docs/architecture.md` workspace RPC row updated; CHANGELOG 0.5.0
  `Added`.
- `dsh-emacs--completing-session-id` gains optional `FILTER` /
  `EMPTY-MESSAGE`; an empty candidate set now signals a `user-error` carrying
  the caller's message instead of failing inside `completing-read`.
- Tests in `test/dsh-test.el`: `unarchive-passes-session-id`,
  `unarchive-updates-archived-set`, `unarchive-refreshes-list`,
  `unarchive-picker-offers-archived-only`, `unarchive-picker-empty-user-error`.
- Later changes must keep `dsh-emacs--archived-sessions` the single source
  for "is this row archived": the success callback replaces it wholesale from
  the response, exactly like the archive callback.

## Known limitations

- An archived session that `session/list` does not return (for example a
  persisted session with no cwd) cannot be picked here; the RPC itself would
  accept its id.
- The picker lists in `session/list` order (updatedAt descending), not
  archive order; the host exposes no archive timestamp.
- Restoring only returns the session to its workspace grouping; it does not
  open it.
