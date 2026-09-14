# 044 — Loading older history into an open transcript

## Background

A chat buffer seeds from the `session/follow` snapshot, which carries a
message-aligned tail of `dsh-emacs-history-window` messages (default 30) and
nothing older (`dsh-emacs-events--follow-open` sends `maxMessages`).  Everything
before that tail was unreachable from an open session: the only recovery was to
raise `dsh-emacs-history-window` and reopen, which pays the whole parse cost
again and starts a new buffer state.

The wire already supports reading backwards.  `session/page` takes
`{address, throughSeq, beforeSeq?, maxMessages?}` and returns a page ending
exclusively at `beforeSeq`, cut on message boundaries, with a `hasMore` flag.
The follow snapshot returns the same `hasMore` for the tail it sent.  So the
missing piece was entirely client-side: a way to ask for the page before the
oldest thing on screen and stack it *above* the existing transcript.

Two things about that were not obvious, and each cost a wrong first cut.

- **`throughSeq: -1` does not mean "the newest page" on this request.**  The
  server slices `events[0 .. min(throughSeq + 1, beforeSeq))`.  `docs/rpc.md`
  documents `-1` as the newest-page convention, and the server's own `paginate`
  defaults to `-1`; an explicit `-1` in the request collapses the slice to
  `events[0 .. 0)` — an empty page with `hasMore: false`.  The first cut sent
  `-1`, so `C-c C-o` reported "No older messages remain" in every session.
  Confirmed by hand against the live server on a 3439-event session:
  `throughSeq: -1, beforeSeq: 10` returned 0 records, while `throughSeq: 3439`
  returned the 10 records before seq 10.
- **Insertion position and render semantics are different questions.**  Every
  existing renderer inserts at one place: `dsh-emacs-render--input-insert-point`,
  the line above the prompt / Composer chrome.  A history page must go to the
  other end — and, separately, must not be processed as if it were live.

## Decision

`C-c C-o` (`dsh-emacs-load-older-history`) reads one `session/page` window and
prepends it; `dsh-emacs-render-history-events` gained a bounded page mode.

- **Renderer** (`dsh-emacs-render.el`): `dsh-emacs--history-insert-marker`
  (buffer-local, insertion type `t`) takes priority in `input-insert-point`, so
  every renderer — message, fragment, thinking, tool — lands there without
  touching each renderer.  `dsh-emacs-render-history-events` accepts `bound`
  (exclusive seq cap) plus `:insert-before` / `:follow-p`: with a cap it renders
  entries with `seq < bound` in ASCENDING order (a tool result needs its call to
  have run first) and leaves `dsh-emacs--anchor-seq` alone.  A page runs
  *outside* `while-no-input`: it is a settled, bounded batch, and an early exit
  on pending input would silently drop half of it.
- **A page is identified by its own flag.**  `dsh-emacs--history-page`, bound by
  `dsh-emacs--load-older-history-page` for the page render and read only through
  `dsh-emacs-render--history-page-p`, says what a render IS.  The insertion
  marker only says *where the top of the transcript is* and is legitimately nil
  when the buffer has no block to insert above yet, so it is not a page test.
- **A page is isolated from live turn state.**  The page render scopes stream,
  pending-command, todo, activity-group and deliverable state to itself while
  retaining shared fragment/tool identity, so a tool card's call and result
  still meet.  Mode-line and usage notes, step tracking, busy state and command
  animations belong to live events only: a page neither starts nor stops a
  command spinner (its completed row still renders), and it never takes over the
  optimistic `dsh-emacs--pending-command`.
- **A page is settled text.**  Page bodies render Markdown synchronously instead
  of joining the buffer's idle queue — that queue is how a live streaming tail
  formats itself, and page jobs would compete with a running reply for it.
- **State** (`dsh-emacs-render.el` / `dsh-emacs-events.el`): the snapshot
  records the tail's earliest seq, its `hasMore`, and its inclusive cursor in
  `dsh-emacs--history-earliest-seq` / `dsh-emacs--history-has-more` /
  `dsh-emacs--history-cursor`; a loaded page advances the first two from its own
  response.  The frontier only moves EARLIER, so a reconnect snapshot cannot
  push the cursor past pages already on screen (which would re-fetch them).
- **Command** (`dsh-emacs.el`): `dsh-emacs--load-older-history-page` prepends
  under `save-window-excursion`, releases the marker in `unwind-protect`, and
  appends missing older prompts behind the existing `M-p` recall list.
- **One transcript-block identity**: message bodies and UI fragments both tag
  their first character `dsh-emacs-transcript-block`, so the prepend target is
  one FORWARD property search (`text-property-any`) — immune to finding anything
  but the first block, including at buffer start after header trimming.

## Why

- **Reuse the one anchor everyone already reads.**  A dynamic marker at the
  insertion layer changes no renderer and keeps one owner for "where does
  transcript content go"; a per-renderer insert-before argument would have been
  fifteen call sites and a new invariant to maintain.
- **`throughSeq` must be a real seq.**  The snapshot's inclusive cursor is the
  one value known to be at or below the server's current cursor, so it stays a
  valid upper bound as the session grows.  The `hasMore` gate stops the command
  at the start of a session without issuing a doomed request; note `json-read`
  decodes `false` as the truthy `:json-false`, so both flags go through
  `dsh-emacs-render--json-boolean`.
- **Keep the live anchor on the frontier.**  Advancing `dsh-emacs--anchor-seq` to
  the page would make the reconnect snapshot (and any `seq > anchor` catch-up)
  repaint the loaded page a second time.
- **Insertion position and event order are separate concerns.**  A page is
  inserted above the transcript but must be PROCESSED oldest-first.  An early cut
  reversed the batch to make stacking easy and consumed separator blanks by hand;
  that put results before their calls and made two mechanisms fight.
  Chronological processing with one advancing marker does both.
- **The marker is the wrong page test because page-vs-live depends on content.**
  A page whose first block does not exist yet (an assistant message alone in an
  empty buffer) rendered with the live treatment, so its Markdown was queued as
  if it were streaming.  Deriving page behaviour from what happens to be in the
  buffer is exactly the silent coupling this design exists to avoid.
- **Rejected**: a "Load more" button rendered as a transcript row (a clickable
  widget whose lifetime must be managed against trim/erase, for a command a
  single key reaches); re-opening the session with a bigger window (loses the
  open buffer's fold state and pays the full parse again); a client-side keyed
  cache of pages (the server is the only page-boundary authority).

## Consequence

- New public key `C-c C-o` and command `dsh-emacs-load-older-history` in chat
  buffers; `dsh-emacs-history-window` now also sizes the page a load fetches.
- `dsh-emacs-render-history-events`'s signature is
  `(events &optional stream bound &key insert-before follow-p)`; callers that
  pass only the first two arguments are unchanged.
- New internal state: `dsh-emacs--history-insert-marker`,
  `dsh-emacs--history-page`, `dsh-emacs--history-earliest-seq`,
  `dsh-emacs--history-has-more`, `dsh-emacs--history-cursor`,
  `dsh-emacs--history-loading`; the new text property
  `dsh-emacs-transcript-block` on message bodies and fragments.
- Regression tests pin: exact chronological placement, completed tool output,
  unchanged live state during idle and running turns, an untouched pending
  stream timer, recent-first bounded recall, stable draft/window positions
  across repeated pages after header trimming, the page flag's definition (a
  marker alone is not a page), synchronous page Markdown against a control that
  the live path still defers, and a page command row that renders without
  stopping a spinner or taking over the pending-command state.
- The feature ships whole, so its CHANGELOG entry is a single `Added` item:
  ordering, isolation and the request cursor are how it behaves, not repairs to
  a released version.
- Docs touched: README key table, docs/customization.md (the
  `dsh-emacs-history-window` line), docs/architecture.md (event-stream
  reliability + a pagination paragraph).

## Known limitations

- `dsh-emacs-max-buffer-size` still trims the top silently, so loading older
  pages into a transcript already at the cap can trim what was just loaded (the
  option's existing contract).  Raising or disabling the cap is the remedy; no
  "load more" state tracks trimmed blocks.
- Shell (`!command`) rows are client-local and never returned by `session/page`,
  so a loaded page cannot restore them.
- Older server builds whose snapshot omits `hasMore` leave the command reporting
  that nothing is left (it fails closed rather than guessing).
- This change does not touch server pagination, transport, or message
  boundaries.
