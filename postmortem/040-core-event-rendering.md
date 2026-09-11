# 040 — Consuming the remaining V3 core events

## Background

At the `6615bfb` baseline, `dsh-emacs-render-event` dispatched nine durable
event types (`user/message`, `assistant/chunk`, `assistant/message`,
`request/header`, `request/context`, `tool/call`, `tool/result`,
`command/run`/`command/done`, `turn/start`, `turn/end`) and let the rest fall
into `_ nil`.  dsh 0.1.5's session-format V3 vocabulary (docs/rpc.md §7.2) has
four more core types, so the client dropped them silently:

- `step/start` / `step/end` — one step is one model call plus the tool
  executions it requested (`dsh-agent-loop` appends the pair around each).
  The transcript showed the content but not the boundary, so a turn's progress
  had to be inferred.
- `assistant/attempt` — an attempt that settled without committing a surface
  message (failed, retried, cancelled).  It has no `message`; its compact
  `data.stream` is the only record of what the model produced.  Nothing was
  painted, and the live streamed body it settled was left open: the
  `assistant-stream` `end` frame only published on `outcome.kind ==
  "abandoned"` (dsh-emacs-events.el), so a retry — whose turn/step key is
  identical — appended its deltas into the failed body until a later
  `assistant/message` replaced the whole region.
- `session/end-seed` — the constructor-seed boundary of a resumed, forked, or
  replayed session.  The restored history and the current lifecycle ran
  together with no marker between them.

This is the events/render layer's gap: the wire delivered the events, the
dispatcher discarded them before any consumer could decide.

## Decision

Give each remaining core event its right consumer instead of one uniform
treatment; `system/message` stays unrendered.

- **`step/start` / `step/end` go to the mode line, not the transcript, and
  are opt-in.**  `dsh-emacs-render-event` routes them to
  `dsh-emacs-render-step-event`, which hands `(turn step start-p)` to
  `dsh-emacs-modeline-note-step`.  With `dsh-emacs-modeline-show-step`
  (default nil) enabled, the mode line shows `step N` after the spinner while
  the running animation is active, with the step's elapsed time (`· 3s`) once
  it passes a second and the full `dsh turn N · step N` in the tooltip.
  `turn/end` (and the disconnect/teardown path) clears the badge with the
  running flag.
- **`assistant/attempt` renders as a muted `↻ Attempt (no committed reply)`
  card** in `dsh-emacs-render-assistant-attempt`.  Its body is rebuilt by
  `dsh-emacs-render--assistant-stream-text` from the packed
  `AssistantStreamRecord` runs (`reasoning-chunks` / `text-chunks` parallel
  `texts` arrays, `tool-call-chunks` name + args), in record order; reasoning
  honors `dsh-emacs-show-reasoning`.
  `dsh-emacs-render--settle-live-attempt` first takes over a live body whose
  turn/step matches the event: it cancels the flush timer and deferred
  Markdown, deletes the live region, and clears
  `dsh-emacs--streaming-assistant`, so the attempt is never painted twice and
  a retry opens a fresh body.  The card is expanded when it replaced visible
  live text and collapsed when replayed from history.
- **`session/end-seed` renders one muted `── seed boundary` row**, labelled
  `inherited history` when `data.inherited` is true.

## Why

A client that silently discards an event class reports a state that is wrong
by omission: a retried run looked like one reply, a failed attempt looked like
nothing, and a resumed session had no visible seam.  The events reach the
client (todo.org's "full event render"), so each needs an owner — but not the
same owner.

Steps are turn-internal lifecycle, not conversation.  dsh web uses
`step/start`/`step/end` purely as `ConversationLocation` boundaries for
folding a turn's process (`packages/client/ui-chat/src/client/conversation-nodes/turn-process.ts`)
and never renders a step row, so painting one per model call would add chrome
the reference client deliberately omits — and it would double the
transcript's line count on a long replay.  The mode line is where dsh-emacs
already owns running state (the spinner, the queue badge), and "which step of
the running turn" is exactly that kind of status; this follows the web
client's boundary treatment while giving the fact a visible home.

That home is opt-in (`dsh-emacs-modeline-show-step`, default nil) because the
step number is diagnostic rather than actionable: it says how many model
round-trips a turn has taken, but nothing in the transcript or the user's
work changes with it, and the mode line already carries the spinner, queue
counts and token/context stats.  A default-off switch keeps the event
*consumed* (no silent-drop gap) while leaving the line quiet for users who do
not want another moving part.

The attempt body must come from `data.stream` because there is no assembled
message to fall back on, and the packed run format is the same one
`assistant/message` embeds (docs/rpc.md §7.1).  Taking the live body over in
the render layer — rather than flushing it and letting the card repeat the
text — keeps the invariant that one attempt produces one visible body, and it
repairs the retry-append behavior at its root: the terminal frame's
`eventType` is `assistant/attempt`, not `assistant/message`, so nothing else
was ever going to finalize that body.

Rejected: a transcript row per step (web-parity failure and replay noise,
superseded by the mode-line badge); rendering `system/message` (docs/rpc.md
§7.1 and §7.4 keep it out of the human transcript — the prompt is not
conversation); a plain assistant body for the attempt with no marker (loses
the failure/retry signal that made the event worth rendering); measuring the
step's elapsed time from the wire timestamps (a replayed still-open
`step/start` would claim hours, see below).

## Consequence

Users now see a card for every attempt that committed no reply and a divider
where restored seed history ends; the transcript gains no step chrome.  The
running turn's step is available via `dsh-emacs-modeline-show-step` (default
nil).  New surface: that option, `dsh-emacs-modeline-note-step` (the
renderer's hand-off) and the buffer-local step state.

Docs touched: `docs/modeline.md` (step badge), `docs/customization.md` (the
option), `docs/rpc.md` §3.2.1 and §7.4 (settlement and consumption scope),
CHANGELOG 0.4.0 `Added`.

Seven assertions in `test/dsh-test.el` cover the step hand-off (no transcript
row, badge value, the option gate, no fabricated elapsed, `turn/end`
clearing, idle hiding, an `end` for another step), and four cover the attempt
card and seed divider.

## Known limitations

- The step badge measures local wall-clock time from the moment this process
  received `step/start`; a reconnect that replays a still-open step restarts
  its elapsed time at zero rather than reporting the server-side duration.
- The badge is tied to the running animation, so it never shows the last step
  of a finished turn.
- The attempt body flattens packed records in record order; the block
  structure of the attempt (`block-start` / `block-end`) is not rendered.
- Attempt cards and the seed divider have no visibility option.
- Plugin extension events (`compaction/*`, `todo/write`, `deliverables/…`)
  remain unrendered; their state still arrives through projections
  (docs/rpc.md §9).  Only the V3 *core* vocabulary was completed here.
