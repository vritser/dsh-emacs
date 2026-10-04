# 073 — Timed `ask_user_question`: claim the wait, answer late

## Background

dsh-emacs presents an `ask_user_question` batch as the
`user-questions/request` waterfall, answered in one minibuffer read
(postmortem/042) and recorded on the ask card (postmortem/053).

dsh 0.2.0 (`dsh-v0.2.0-rc.2`, `639ed01539`) added a **timed** tool mode. The
host applies a foreground window (default 120 s); when it closes with no answer
batch it records the tool result `{pending:true, callId, message}` and keeps the
call answerable. The `userQuestions` session projection publishes
`{active: [{callId, questions, state}], settled: [{callId, answers}]}`, a late
answer goes through `userQuestions/answer` (steered in as a
`user-question-reply` user message), and `userQuestions/attachWait` holds the
host deadline while a client claims the wait. Evidence: harness
`packages/interaction/user-questions/src/{index,projection,timed-wait}.ts` and
`packages/interaction/tool-ask-user/src/timed.ts` at `dsh-v0.2.0-rc.2`;
`docs/rpc.md` §4.25.

That left three client defects. The drain force-retired the waterfall at the
timeout, so an in-progress minibuffer read could be closed out from under the
user. The pending result parsed to no answers, so `--ask-summary` returned nil
and the ask row fell back to the raw JSON preview, reading as `waiting`
forever. And a `continued` question had **no answer path at all**: the only
answer route was `$events/result`, whose waterfall was already gone. The
failing layers were the protocol decoders, the event/projection layer, the
question flow, and the renderer — not the transport.

## Decision

Adopt the timed surface end to end:

- `dsh-emacs-protocol.el` gains `dsh-protocol-question-wait`,
  `dsh-protocol-question-answer`, `dsh-protocol-pending-question`,
  `dsh-protocol-settled-question` and `dsh-protocol-user-questions`, plus
  `dsh-protocol-question-answers-json` for the replay below. All wire field
  names stay in that module.
- `dsh-emacs-events.el` passes the waterfall's `wait` into the question queue
  and routes the `userQuestions` projection cell — both the
  `session/control`/increment form and the `session/follow` snapshot form —
  into the owning chat buffer's buffer-local state.
- `dsh-emacs--question-drain` claims a timed wait with
  `userQuestions/attachWait` through the interactive read and the answer RPC
  response. Other exits release immediately; the claim is skipped for an
  untimed or absent `wait`.
- New command `dsh-emacs-answer-question` (`C-c C-p`) reads the session's
  `continued` calls from the projection and submits the batch through
  `userQuestions/answer`, reusing `dsh-emacs--collect-question-answers` so the
  reader is unchanged.
- The ask card gains a `pending` outcome; a settled projection cell completes
  the row with `dsh-emacs-render-question-settled`, which replays the answer
  batch through the one tool-result path that updates a row in place.

Implemented by `feat: support timed question answers`, following `7573ebe`.

## Why

- **The pending result is not a failure and not an answer.** The host's own
  tool text says so ("This is pending, not a skipped answer"). Rendering it as
  the generic result preview made the row contradict the host; a dedicated
  `pending` summary plus a body sentence keeps the card honest and names the
  command that resolves it.
- **Claiming the wait is the one host-behavior change, and it protects the
  user.** Without it the 120 s window can close while the prompt is on screen;
  the host then retires the waterfall and the input is lost. `attachWait`
  suspends expiry while Emacs is reading but reschedules the original deadline
  on release, possibly expiring immediately. Review caught the asynchronous
  submission race: the response callback must own release after submission;
  abandoning the read, `C-g`, errors, and buffer death still clean up.
- **The projection is the only late-answer source.** There is no unary read
  for continued questions, and the synthetic `user-question-reply` message is
  deliberately hidden by the renderer's source filter, so the card can only be
  completed from the projection cell. Reusing the ordinary result path (rather
  than duplicating the card's fragment code) keeps one state machine for the
  row; the replay is a no-op unless the row is currently showing the pending
  result, which is also what protects an in-time answer from being overwritten.
  The result renderer also consults the stored settled state, because a late
  reply can precede the card's history page or follow result. Projection
  sequence cuts prevent an older snapshot from replacing newer question state.
- **The late reader owns the existing shared prompt slot.** A real GUI probe
  showed an incoming waterfall trying to nest a minibuffer during a late
  answer, then being dropped locally. Reserving the slot through the picker
  and reader lets both question and approval queues drain after any exit.
- **Rejected: a minibuffer countdown.** `attachWait` yields a single
  `remainingMs` frame, not a ticker, and postmortem/042 rules out re-entering
  the reader or driving frontend state, so the UI states `pending` instead of
  pretending to count down.
- **Rejected: polling `session/projections`.** The `userQuestions` cell already
  arrives on the connection's existing projection frames; a poll would add a
  second, slower source for state the client is already handed.
- **Rejected: rendering the late reply as its own transcript note.** The call
  card is the record of what was asked and answered (053); a second element
  would duplicate the questionnaire.
- **Rejected: a separate `dsh-emacs-question.el` module.** The timed feature
  extends the existing question flow (queue, drain, reader); the protocol
  structs live with the other wire views and the projection consumer with the
  other projection branches, so no new boundary was needed.

## Consequence

- New user surface: `dsh-emacs-answer-question` (`C-c C-p`), the `pending`
  ask-row summary, and the pending body sentence.
- New protocol views and the serializer; new chat-buffer-local
  `dsh-emacs--session-questions`; new `dsh-emacs-render-question-settled`;
  `dsh-emacs-render--ask-summary` gained a `pending` argument; the result
  render now keeps the call-time identity (`:title :name :args :args-raw
  :icon :summary :variant :call-time :ns`) in the tracked tool state, because
  the replay needs the original arguments to rebuild the card.
- Tests (`test/dsh-test.el`, section 31g): protocol decoding incl. a malformed
  element and both states, empty view, `wait` timed flag, projection dispatch
  into chat state and foreign-session drop, the timed claim opened and released
  (and not opened for an untimed wait), the late-answer RPC body, the
  no-continued-call report, the pending row, the projection-completed card, the
  snapshot/`resume` completion, and the guarantee that an in-time answer is not
  overwritten. Disabling the settle wiring fails the settle test.
  Review regressions cover asynchronous claim release and failure cleanup,
  all late-reader exits with queued prompts, false answer responses, stale
  baselines, generation resets, and settled state arriving before a result.
- Docs in the same change: `CHANGELOG.md` (0.6.0 Added), `README.md`,
  `docs/customization.md`, `docs/architecture.md`, `docs/rpc.md`
  (§0.5/§4.25/§7.4).
- On dsh 0.1.7 the feature is dormant: there is no `wait` field and no
  `userQuestions` cell, so the blocking question flow is byte-for-byte the old
  behavior.

## Known limitations

- No countdown: the protocol provides a single remaining duration, so the row
  reads `pending` rather than ticking.
- A question that expires while it is queued behind another session's prompt
  (not actively being read) becomes `continued`; the user answers it later with
  the command rather than the original prompt.
- The late reply is steered as a hidden user message; its answers are shown by
  completing the original card, not as a new transcript element.
- `userQuestions/answer` requires the exact live root agent, so a continued
  question asked from a delegated subagent's context is rejected by the host
  (the same rule as the waterfall).
- A server that enables the timed tool but never publishes the `userQuestions`
  projection cannot complete the card; the command reports that nothing is
  waiting rather than guessing.
