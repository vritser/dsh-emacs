# 064 — Mirror the pending-input queue from the inbox projection

## Background

Through dsh 0.1.6 the host published the agent inbox on `session/control` as
`queue` frames plus the baseline's `queues` record
(`packages/api/session-controller/src/control.ts` at `dsh-v0.1.6-alpha.1`,
`0a15e36e7f`).  `dsh-emacs-queue.el` mirrored those frames: the mode-line
`[Qn Sm]` indicator, the echo-area `queued:`/`steering:`/`running:` feedback,
the Composer Next Message row and `C-c C-q` all read that mirror.

dsh 0.1.7-rc.1 (`46a7f68b09`) deleted both — the control baseline now carries
`projections` only, and `SessionQueuedItem`/`SessionJob` left the wire.  The
same fold state is still published, as the **`inbox` session projection**
(`packages/core/agent-loop/src/inbox.ts`), delivered through the ordinary
`projection` frames and the baseline's `projections` record.  Against a 0.1.7
server the client therefore stopped updating every queue surface, silently:
the frames it waited for simply never arrived.

The same release dropped the `trust` field from `agentPresets/list` rows, which
`dsh-emacs--preset-display-name` used to gate the web-consistent built-in labels
(`Standard mode` …).

## Decision

The queue mirror's source is the `inbox` projection, read through the existing
projection plumbing:

- `dsh-emacs-events--host-apply-projection` gains an `"inbox"` branch.  It
  converts the cell with `dsh-protocol-queue-items-from-inbox` and hands the
  structs to `dsh-emacs-queue-apply`, which now takes an item list instead of a
  wire payload.
- The `queue` frame branch, the baseline's `queues` seeding, the
  `dsh-protocol-queue-item--from-alist` frame parser and the roster's
  `trust`/`authorable`/`hasDocument` fields are deleted.
- An `inbox` cell whose session has no live chat buffer is dropped; the mirror
  is buffer-local and only a chat buffer can render it.
- `dsh-emacs-events--host-control-baseline` normalizes each projection record
  key to a **string** session id.  JSON object keys are interned by `json-read`
  (`{"session-0f3a…": …}` → the symbol `session-0f3a…`), while a session id
  elsewhere on the wire — and the chat-buffer table's key — is a string, so the
  record key had never matched `dsh-emacs-events--chat-buffer`.

## Why

The `inbox` projection predates 0.1.5 and is unchanged since, and 0.1.5–0.1.6
publish it in the same baseline and the same `projection` frames — their
control controller broadcasts the projection frame for *every* key before it
adds the extra `queue` frame (`control.ts` at `dsh-v0.1.5-rc.1`).  One read path
therefore serves every server the client supports, with no version branch, no
capability probe and no fallback list to maintain.

Keeping the old frame path "just in case" was rejected: 0.1.7 does not send it,
so it would be dead code that only a compat fixture could exercise.

Dropping foreign-session cells is required *because* the source is now a
whole-host record: the baseline carries an inbox cell for every session, so the
0.1.6 fallback of applying an unmatched frame to `(current-buffer)` would let
any session's pending queue overwrite the active chat's mirror.  The old test
that asserted that fallback now asserts the drop instead.

Keying the built-in preset labels on the id alone is what dsh web's
`presetDisplayText` already does, and the removed `trust` cannot be
reconstructed from the 0.1.7 roster; inventing a replacement (for example
"shipped unless a local root supplies it") would guess at host state the wire no
longer reports.

The session-id normalization belongs on the record key, not in
`dsh-emacs-events--chat-buffer`: the record key is the one place where a session
id arrives as a JSON *object key* rather than as a string value, and every
consumer downstream of the loop (`--host-apply-projection`'s title / ctx /
permission / goal branches, the chat lookup, the queue mirror) expects the same
string identity the incremental `sessionId` field and `session/list` carry.
Making the chat lookup itself symbol-tolerant was rejected: it would leave the
other branches receiving a symbol and hide the mismatch instead of fixing it.

This was a **pre-existing** bug, not one the migration introduced: the 0.1.6
`queues` record had the same `Record<sessionId, …>` shape and the same
`(car pair)` lookup, so its baseline seeding silently missed too — the mirror was
merely reseeded by the first incremental `queue` frame that followed.  With the
inbox cell as the *only* seeding path, the latent bug became a visible one
(pending items absent after a reconnect until the next inbox change), which is
why it is recorded here.  The lesson is the test's: the old baseline fixture
built the record with a string key by hand, so it agreed with the code and not
with `json-read`; the test now encodes real JSON and dispatches it, so the
symbol-keyed path is what is exercised.

## Consequence

- `dsh-protocol-queue-item` is built from an inbox `UserMessage` through
  `dsh-protocol-queue-item--from-message` (id, text, source kind) plus an
  explicit placement.  The client derives the placement the host used to apply:
  `next-turn` → `queued`, a `next-step` entry with a user source → `steering`,
  any other `next-step` → `context`.
- `dsh-emacs-queue-apply` takes `(chat process items)`; `dsh-emacs-events.el`
  threads the mux process into `--host-apply-projection` so the connect-time
  seed still lands silently.
- Tests: `dsh-emacs-test--queue-item` builds structs and the new
  `dsh-emacs-test--inbox-message` builds wire messages; the dispatch fixtures
  send `projection`/`inbox` frames; the baseline tests encode a real JSON
  `baseline` frame and dispatch it, so the `json-read` symbol-key path is
  covered and the session-id normalization is pinned (removing that
  normalization fails both — seeding and stale replacement — and nothing else);
  a foreign-cell test asserts the drop.  A second baseline test pins the
  reconnect case: a new process's empty cell must clear the previous
  connection's items.
- Docs updated in the same change: `docs/rpc.md` (§0.4, §6.1, §8, §9),
  `docs/architecture.md` (queue section, RPC table, core connection) and
  `docs/modeline.md`.
- On 0.1.5/0.1.6 the queue surfaces behave as before; on 0.1.7 they work
  again.  On every supported server a reconnect (or a chat opened while the
  session list is connected) now restores the session's pending queue and
  Next-preview from the baseline instead of waiting for the next inbox change.
  `CHANGELOG.md` carries the entry under `0.5.1` with
  `(rationale: postmortem/064)`.

## Known limitations

- Background jobs still have no client surface.  0.1.6's `jobs` record is gone
  and this client never opens the new `job` namespace streams (`job/list`,
  `job/follow`); a future job UI must consume those.
- The roster's `modeSelectionEnabled` is parsed but unused — the picker does
  not hide itself when the host disables visible mode selection, exactly as
  before this change.
- Other 0.1.7 additions are unread for now: `session/list`'s `agentAvailable`,
  `turnWindow`, `openWorkspacePath.application`, the workspace pin set and the
  unary `session/projections`.  `docs/rpc.md` §0.4 records them for later
  adoption.
