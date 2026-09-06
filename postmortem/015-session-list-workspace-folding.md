# 015 — Session-List Workspace Folding

## Background

The session list already groups rows by workspace, but every group was always
expanded.  A list with several active projects therefore made navigation noisy,
especially when realtime updates repeatedly repainted the buffer.

## Decision

The session-list UI owns a buffer-local set of collapsed group ids.  Real
workspaces use their server ids and the synthetic Ungrouped bucket uses a local
sentinel.  `TAB` toggles the group header at point; `RET` does the same on a
header while retaining its existing open-session behavior on a session row.
Rendering omits the folded group's rows and shows a disclosure indicator on
every header.  A boolean user option supplies the default state; workspace
collapse/expand commands replace that default inside the current list buffer.

## Why

Folding is presentation state, not workspace data, so it does not belong in the
protocol or shared caches.  Keeping ids in the list buffer preserves the user's
view across manual, automatic, and realtime redraws without introducing a new
server mutation or coupling the renderer to transport events.

`TAB` follows familiar outline navigation, while context-sensitive `RET` makes
the header useful without changing the established session-row action.

## Consequence

Users can compact long session lists one workspace at a time.  New sessions and
incoming updates remain hidden inside a folded group until it is expanded; the
header count still reflects the current visible-session membership.

`dsh-emacs-workspaces-collapsed-by-default` controls how a list starts.
`dsh-emacs-collapse-workspaces` and `dsh-emacs-expand-workspaces` also define
how newly arriving groups appear for the remainder of that buffer's lifetime.

Tests cover the option, all-group commands, key binding, folded rendering,
redraw persistence, and the header-specific `RET` behavior.

## Known limitations

Fold state lasts only for the lifetime of the session-list buffer and is not
persisted across Emacs restarts.
