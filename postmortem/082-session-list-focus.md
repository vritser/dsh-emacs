# 082 — Keep list focus when rows move or disappear

## Background

The session-list renderer at `43aa7fb` restored row identity, but forced the
old viewport with `set-window-start`'s NOFORCE argument omitted. A GUI probe
showed focus on session 55 after rendering, then session 65 after redisplay;
the highlight remained on session 54. Row transposition had not preserved
the highlight overlay. These failures belonged to the list UI.

Fixing the viewport and overlay exposed a separate removal path. The user
reported jumping to the first workspace after archiving or deleting. That
was the renderer's explicit fallback when the original row disappeared,
documented in 058; the first fix had tested only a surviving, reordered row.

## Decision

Restore surviving row identities with NOFORCE enabled and realign the
existing highlight overlay. For a removed row, choose the next surviving
row in the pre-update order, then search preceding rows backward. Use the
first new row only when no old candidate survives. Share that policy
between buffer focus and every window displaying the list.

## Why

The operation removes an item, not the user's position in the list. Saving
the previous row order keeps adjacent identities available even if the
update deletes several rows or regroups the survivors. A raw position or a
marker at a deleted boundary cannot identify the intended neighbor after
row transposition. Updating only archive commands would miss workspace
deletion and background removals through the same renderer.

Moving the existing highlight respects its window restriction and avoids
activating highlighting in an unrelated selected buffer. NOFORCE lets Emacs
reveal the restored row rather than move point to satisfy an obsolete view.

## Consequence

Tests cover recency reordering, middle/end session removal, workspace
removal, independent window focus and a second refresh. GUI probes exercise
actual redisplay, which batch-only point assertions had missed. This record
covers the uncommitted focus fixes following `43aa7fb`.

## Known limitations

When every old candidate disappears, there is no meaningful adjacent target;
the first new row remains the fallback. Opening the list explicitly still
uses the active-session jump rather than refresh restoration.
