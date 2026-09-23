# 058 — Session list keeps one row per window

## Background

The session list (`*dsh-sessions*`) is a single buffer that a user can show
in more than one window — split the frame, or keep it in a side window while
a chat buffer holds the main one.  Its renderer rebuilds the whole body on
every refresh (`erase-buffer` + re-insert), driven by the event stream,
auto-refresh and `g' (`dsh-emacs-session--render').

Emacs gives every window its own point, and a window's point is clamped back
into the buffer whenever the text is replaced.  The renderer only ever
remembered **one** row, taken from the current buffer's point:

```elisp
(restore-id (dsh-emacs-session-id-at-point))
```

so after a refresh the window that was not current was left wherever its
point landed (clamped to the buffer start), and the list appeared to lose
its place there.  Measured in a real frame with the same buffer in two
windows on rows `s19` and `s59`: after one render, window 2's point sat on
the header instead of a session row.

## Decision

Each window showing the list keeps the row it was on across a render, and
the list keeps its scroll position.  Every row now carries one identity
property, `dsh-emacs-row-id` (a session id, or a group id for a header and
the empty New Session row).  The renderer captures, before `erase-buffer':

- `dsh-emacs-session--window-points' — one entry per window displaying the
  buffer: the row id under its point, the row id at its `window-start', and
  the offset into that row.  The selected window's point capture reads the
  buffer's point (the list's focus is the buffer point, and the selected
  window's own point can trail a `goto-char`); other windows read
  `window-point'.
- `buffer-id' — the row under the buffer point, kept separately because a
  buffer displayed in **no** window (batch/daemon render, a buried list)
  yields no window entries at all.

After the rebuild, point is restored from, in order: a pending auto-jump
target (`dsh-emacs-session--auto-jump-session`, the "open the list on the
current session" feature), the buffer's captured row, the first row when
that captured row is gone, and the first session row on a fresh buffer.
Then each window gets its point back with `set-window-point' (the selected
window follows the buffer point), and its viewport back by resolving the
captured top row and setting `window-start' to it plus the offset.

Helpers `dsh-emacs-session--row-pos' (resolve a position by property and
value) and `dsh-emacs-session--first-row-pos' keep the lookups in one place.

## Why

Reusing `save-window-excursion' / window configurations was rejected: those
restore point *and* scroll position from a snapshot, but the list's content
is rebuilt with different line numbers, so a stale configuration would fight
the new layout rather than re-find a row.

Restoring only the current buffer's point (the previous behavior) cannot
represent two views of one buffer; that is the bug.  A per-window alist of
row **ids** survives re-ordering (recency sort, archived rows, a group that
got folded), which a per-window buffer position does not.

Keeping `buffer-id' separate from the window alist was necessary, not
speculative: the first attempt dropped the buffer snapshot when the window
list was empty, which silently parked every non-displayed render on row one
(three unit tests caught it).  The rule is that **the buffer's own focus is
state of its own**, independent of which windows happen to show it.

The viewport is stored as a row id plus an offset rather than a position or
marker, and the same identity property is used for both point and viewport.
A marker is the first thing one reaches for, but it cannot work here: the
render *erases the whole buffer*, so a marker into the old text collapses to
the buffer start (measured: captured 898, restored 1).  Row ids also survive
the re-sort, where a line number would silently point at a different
session.

## Consequence

- Splitting the frame on the session list and refreshing keeps each window's
  row; a window on a workspace header stays on that header.
- A refresh also keeps each window's scroll position, keyed to the row that
  was at its top, so the list does not visibly jump.
- The selected window's row follows the buffer point, so `RET`-opening a
  session, `TAB` folding, and the auto-jump all keep working unchanged.
- An auto-jump does not center the target row; it leaves the viewport alone
  and lets Emacs show an off-screen point with the minimum scroll.  The
  earlier "always `recenter` after a jump" scrolled the list on every
  refresh that carried a pending jump — the reported "page re-flows"
  symptom.
- The lookup/restore helpers are private to `dsh-emacs-session.el`;
  `docs/customization.md` and `CHANGELOG.md` describe the user-visible
  effect only.  A later row kind must carry `dsh-emacs-row-id' or the
  viewport restore cannot key it.
- Later changes to the renderer must capture focus **before** `erase-buffer`
  and restore it **after** the inserts; reading the row afterwards cannot
  work (point is at `point-max`, where no row carries a property).

## Known limitations

- The viewport is keyed to the row that was at its top: a row that is gone
  (its group collapsed, a session archived) leaves that window at the top of
  the list, and a session inserted *above* the viewport moves the viewport
  content by that many lines instead of holding the exact offset.
- The scroll restore is asserted in the unit suite by the row at the
  viewport's top (the batch window is not redisplayed, so an unforced
  `set-window-start' does not read back); the visual "nothing moved" check
  is interactive, because a headless macOS run throttles redisplay and its
  `window-start` readings are not trustworthy (see AGENTS.md, "Limits of
  headless-probe timing").
