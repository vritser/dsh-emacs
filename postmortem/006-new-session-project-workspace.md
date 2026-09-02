# 006 — New Session Auto-Attach to the Project Workspace

## Background

`dsh-emacs-new-session` resolved its creation context only from UI state:
the workspace under point in the session list, or — inside a chat buffer —
the current session's workspace.  Everywhere else it fell back to plain CWD,
which the server renders outside any workspace (the Ungrouped bucket in the
session list).  That covered the common flow poorly: starting a session from
a project directory (`dired` / `magit` / `M-x dsh-emacs-new-session`) landed
it Ungrouped even when the project's workspace already existed, carrying
none of the workspace affordances (`c`-in-workspace grouping, workspace
filter, `C-c C-s` switch lists).  The web client instead always targets an
explicit `workspaceId` (`ui-workspace/startSession`), so dsh-emacs sessions
were the odd ones out.

The first implementation had a second gap that only surfaced in real use
(report: dired on a git repo → `M-x dsh-emacs-new-session` → session with
no workspace): the command's CWD was resolved through
`dsh-emacs--absolute-cwd`, which with a nil `cwd` argument (the normal
interactive case) always fell back to the fixed `dsh-emacs-default-cwd`
option — whose default is the `default-directory` at load time, typically
the startup directory.  The browsed directory never reached the detection,
so no `workspace.create` was ever triggered for it and the session landed in
the Ungrouped bucket again.

## Decision

Add project auto-detection to the new-session CWD path only (the point /
chat-session precedence is unchanged): `dsh-emacs--new-session-project-workspace`
detects the Emacs project root of the command's CWD and passes that
workspace's id to `session.create`.  When the server has no workspace for
the root, `workspace.create` — idempotent by canonical path — is called
first (a single synchronous RPC), so each project gets exactly one
workspace on first use.  Detection prefers project.el (`project-current` /
`project-root`, built-in from Emacs 28 and also reaching a user's
`project-find-functions` finders such as projectile), then `vc-root-dir`,
then a `.git` directory walk; workspace matching compares canonical paths
(`file-truename` + `directory-file-name`, mirroring the server's
`fs.realpath` uniqueness canon).  The whole feature sits behind the
`dsh-emacs-new-session-auto-project` option (default on) and the existing
local-loopback server check.

The command's CWD is the current buffer's `default-directory` — a dired
buffer's browsed dir, magit's repo root, a file's directory, i.e. Emacs'
own notion of "where I am": `dsh-emacs--absolute-cwd` now expands
`(or cwd default-directory dsh-emacs-default-cwd)`.  `dsh-emacs-default-cwd`
is demoted from the primary source to the fallback for the (rare) case with
no buffer directory context, so the detection sees the very project the
command is invoked from.

## Why

- The session belongs to the project, not to wherever point happens to be:
  dsh web's model is one workspace per directory, and grouping sessions
  under the project root is the behavior the rest of the client's UI
  (grouping, filtering, switching) already assumes.
- The motivating scenario is the dired flow, so the directory fed into the
  detection must be the buffer's `default-directory`.  Any fix that kept
  sourcing it from an unset, load-time constant could not see the browsed
  project — that was the reported bug, and it is why the cwd provenance is
  part of this record, not a later correction: the flawed behavior never
  shipped (the whole change set is pre-release).
- Attach-vs-create: `workspace.create` is a pure registration over an
  existing directory and idempotent by path (`resolveByPath` first), so
  "create-if-missing" costs one cheap call and cannot duplicate or
  overwrite anything; without it the feature would silently do nothing for
  the first session in every new project.  Rejected: running a separate
  `workspace.list` fetch first — the idempotent create subsumes the lookup
  and is race-free against a stale local cache.
- Canonical matching is required, not polish: workspace paths are stored
  `fs.realpath`-canonicalized server-side, and `project-root` may return an
  unexpanded `~` form (observed on project-vc), so a naive string compare
  misses legitimately-same directories (symlinks, trailing slashes, `..`).
- Local-server gate: a remote dsh server's workspace paths are its own
  filesystem; matching a local project root against them is meaningless and
  the guaranteed-failing `workspace.create` would only produce error noise.
- Rejected: running detection on `default-directory` while keeping the
  session's cwd as `dsh-emacs-default-cwd` — the two would disagree about
  the session's home, and the server's workspace path (not the payload
  cwd) is what the client aligns the chat buffer to, so the split is both
  incoherent and invisible.
- Rejected: interactive-only special-casing in the `interactive` spec — the
  same provenance rule also serves `dsh-emacs--cache-new-session`'s
  placeholder row (the async callback restores the creation-time buffer),
  so one rule in `dsh-emacs--absolute-cwd` covers both.

## Consequence

- New behavior: `dsh-emacs-new-session` (and the `c` / `C` list keys)
  outside any workspace context now group the session under the project of
  the invoking buffer's directory, creating that workspace on first use;
  the chat buffer's `default-directory` follows the workspace path as
  before.
- `dsh-emacs-default-cwd`'s role changed from primary to fallback (docstring
  and `docs/customization.md` updated); `dsh-emacs-new-session-auto-project`
  (default t) restores the old cwd-only behavior; the point / chat
  precedence in `dsh-emacs--new-session-workspace` is unchanged.
- The create-and-attach path relies on the workspace being in
  `dsh-emacs--workspaces` before the `session.create` callback runs; the
  `workspace.create` response is upserted synchronously for that reason.
- Tests: the plain-cwd new-session tests bind the option nil (their intent
  is workspace-context-free cwd creation); the new behavior is covered end
  to end (real project detection, mocked RPC) plus a regression pinning the
  cwd provenance and the `dsh-emacs--absolute-cwd` precedence in
  `test/dsh-test.el`.
- Test harness: the suite tail listed failures via
  `(nreverse dsh-test-results)`, which rewrote the list in place and left a
  one-element list — the final exit-code check then never saw failures and
  a red suite exited 0, slipping past `scripts/verify.sh`.  Switched to the
  copy `reverse`; the new regression tests now actually gate the gate.

## Known limitations

- Sync RPC: the first session in a new project spends one synchronous
  `workspace.create` round-trip inside `dsh-emacs-new-session`; subsequent
  sessions hit the local cache and skip it.  A remote server never pays it.
- Project detection is directory-based only: a buffer whose
  `default-directory` is not inside a detected project (flat dir, no VCS)
  keeps plain cwd semantics — no workspace is invented for it.
- The session-list buffer's directory (used for `c` / `C` in the ungrouped
  area) is whatever it was when the list buffer was first created, not
  necessarily a meaningful project directory; if that ever matters, the
  list UI would need an explicit directory context of its own.
- Auto-created workspaces appear in the server's workspace list (that is
  the feature); deleting them via the list's `dsh-emacs-delete-workspace`
  is unaffected.