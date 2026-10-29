# Mode-line Status

Native mode lines always show plain `DSH` as the major-mode label, whether
idle, running or compacting. The separate activity segment keeps the whale-tail
animation, caption and clock together and disappears when idle.

With Doom Modeline, the static DeepSeek Harness whale SVG appears just before
`buffer-info`, beside the buffer name. Its vertical padding is cropped to match
the permission shield's visible height, without making the mode line taller or
adding a badge or background. The DSH Web running-status whale tail appears in
Doom's right-side major-mode slot. During an active turn, graphical Emacs with
Motion Line and GIF support displays the web whale's
60-frame, 28-pixel animation with 50ms per frame and a three-second loop.
Both the running GIF and idle SVG use an 18×18 display box with a centered
baseline. The larger box makes the tail clearer despite its transparent
padding. The optional `motion-line` package selects GIF frames
explicitly; mode-line evaluation starts no timers. Both tails use the logo's
color: blue (`#4d6bfe`) on dark frames and black on light frames, including
Doom's right-side tail. Theme changes update running frames on the next
visible tick.

[Motion Line](https://github.com/vritser/motion-line) is an optional dependency,
installed separately. Install `motion-line.el` with `M-x package-install-file`,
or add its checkout to `load-path` before loading dsh-emacs:

```elisp
(add-to-list 'load-path "/path/to/motion-line")
(require 'dsh-emacs)
```

When Motion Line is unavailable, dsh-emacs loads normally and displays static
`Deep diving` text during a turn, or teal `Compacting` during context
compaction, in both native and Doom mode lines. The text has no whale
animation, sweep or elapsed clock and creates no animation timer. It
disappears when both activities finish or on disconnect. Step, Plan and
execution feedback keep their existing behavior; step elapsed text refreshes
only when Emacs otherwise redraws. No bundled copy or automatic download is
needed. Restart Emacs after installing Motion Line to enable animation.
Errors inside an installed library still surface normally.

The following animation and clock details apply when Motion Line is installed.

When idle, Doom uses the same static SVG path as the web runtime's fallback.
The native running indicator disappears. Terminals and builds without GIF
support use cycling `DSH.` / `DSH..` / `DSH...` text while running; the idle
label is `DSH` without SVG. The larger whale logo remains blue (`#4d6bfe`)
on dark frames and black on light frames. Emacs does not decode APNG; the
converted GIF retains its motion and timing but uses binary transparency.
Its Base64 data is embedded in `dsh-emacs-modeline.el` and decoded on first
use, then cached; installations need no external image file.
See [asset provenance and conversion](../assets/dsh-whale-tail.md).

While running, the tail is followed by `Deep diving · 12s`. The English
caption uses a gentle foreground sweep over a three-second cycle in graphical
Emacs, with a quiet gap between passes. The duration updates in whole seconds,
using `1m05s` after a minute. Terminal captions remain static beside the cycling
text indicator. Whale, caption and clock share the existing animation slot;
Doom retains the sweep's text properties. Its ordinary running and idle
states keep the standard major-mode menu; clicking `Compacting` opens status
details instead.

The clock starts at `0s` when this buffer enters the running state. It measures
local observed running time, including tools and waits; it is independent of
the three-second animation loop and does not reset on repeated running
snapshots. Turn completion clears it unless one of the chat's direct children
is still running; the last child settling then clears it. Disconnect always
clears the whale's child activity and clock, and host updates cannot restart
them in a detached chat. Child activity does not mark the session busy, so
input submission and stop keep their turn semantics. A follow snapshot
restores child activity even when its cached projection has not changed.
A reconnect — or opening
the session again after its buffer was killed — starts a new local
observation interval; switching back to an already-open chat keeps its
running clock. Neither claims an exact server turn duration. For completed
turns with folded work, the Completed summary above the answer shows the
server-based duration; add `duration` to `dsh-emacs-reply-footer-items` to
show it in the footer too.
See [095](../postmortem/095-running-status.md).

Customize `dsh-emacs-modeline-running-face` for the caption/clock foreground
and `dsh-emacs-modeline-running-highlight-face` for the sweep's peak color.
Setting both foregrounds to the same color removes the text sweep.
Compaction uses `dsh-emacs-modeline-compacting-face` and
`dsh-emacs-modeline-compacting-highlight-face` for the same roles, with teal
defaults. See [Execution feedback](#execution-feedback) for its separate clock.

The stats use `dsh-emacs-modeline-format-spec` to choose segments and their
separator (one space by default). Status indicators—animation, Plan
and subagents—and the parenthesized stats have one separating space in
both native and Doom mode lines. Empty indicators add no gaps; SVG placeholders
retain their display and click properties. Doom's right-side major-mode slot
shows the DSH Web runtime whale mark in DSH chat buffers. Ordinary running and
idle states retain the standard major-mode menu; `Compacting` opens status
details. Custom Doom layouts with `buffer-info` and `major-mode`
anchors receive the same segments. Reopening chats does not duplicate them,
and Doom's excluded layouts remain excluded.

Available stats segments:

- **cwd**: current working directory (home path abbreviated with `~`)
- **branch**: git branch name (auto-detected)
- **provider**: provider id serving the model (e.g. `deepseek`), opt-in — the
  provider also rides the model segment's tooltip
- **model**: last-used model name, seeded from the session list and kept live
  by `modelSelection.lastUsed` in control/follow projections, plus
  `request/header` / `request/context` events; switches made in another client
  update the cached selection and the model/provider/effort segments too
- **effort**: reasoning effort — the `reasoningEffort` chosen via the model
  picker, or the one the host announces in `request/header` or the model
  projection (e.g. `high`); a model projection without effort clears an old one
- **preset**: agent preset of the session (`agentPreset`, e.g. `standard` / `ptc`)
- **permission**: the `permissions` session projection's current value, drawn
  as a shield icon so it costs one cell: the dsh-web SVG shield (check =
  `read-only`, pencil = `workspace-write`, exclamation = `danger-full-access`)
  in graphical Emacs with SVG, otherwise the matching Nerd Font shield glyph
  when `nerd-icons` is installed, otherwise a short token. An unrestricted
  session (or the derived `custom`) tints the shield with
  `dsh-emacs-modeline-permission-warn-face`; the tooltip carries the full
  preset name. No emoji are used — they are double-width and ignore the face
  color. Switch it with `M-x dsh-emacs-set-permission` (see
  [Customization](customization.md#permission-presets)); set
  `dsh-emacs-modeline-permission-style` to `text` for the unabbreviated name
- **tokens**: token usage (`↑input ↓output Rcache-read Wcache-write CHcache-hit%`)
- **ctx**: context-window usage percentage (color-coded)
- **cost**: cumulative cost (USD)

The stats can be toggled with `C-c C-f`, or controlled via the
`dsh-emacs-modeline-enabled` customization option. The layout and faces are
documented in [UI Styling](ui-styling.md).

## How ctx% is computed

The dsh server computes context pressure itself and pushes it to every client
as `session/control` `projection` frames (`key: "contextPressure"` → projected
tokens, pressure tokens and context window). Live updates trust a sample only
when raw pressure is positive. They prefer positive projected tokens, falling
back to raw pressure, and take the window from the same projection. A zero or
negative raw sample, or an absent/non-positive window, preserves the previous
snapshot. Synchronization from a cached session-list row uses its raw pressure
and window; an incomplete row likewise leaves the existing snapshot intact.

No local model→window map is maintained and no full session refresh is needed.
The segment updates as the server's projection frames arrive. Without a server
snapshot the ctx segment is simply hidden; a model change or session open pulls
the projection immediately.

## Mode Line (session buffer status bar)

dsh-emacs does **not replace** your mode line; instead it adds small
segments to your existing (default or custom) `mode-line-format`. While **dsh
is running** (after sending a prompt, before `turn/end` is received), the
whale tail swings. Native mode lines keep the plain `DSH` major-mode name and
its standard menu, with the combined whale-tail animation, caption and clock
in the appended activity segment;
Doom animates its existing right-side major-mode tail, followed by the stats,
while the larger logo stays before `buffer-info`. No extra progress bar or
second tail is added. The modified flag, line/column position, primary/secondary modes,
misc-info, and all other existing content are preserved:

```
 U:***  %b   L40  DSH [whale tail] Deep diving · 12s (model max 95.0%)
```

- **Whale-tail animation**: the web animation replaces the old filled progress
  bar. `motion-line` owns one shared timer and independent playback slots
  for all chat buffers. Repeated running snapshots do not reset the loop.
  Playback controls in another buffer keep the pending tick's deadline, so
  repeated starts or cleanup cannot starve a running tail.
- Opening an already-running session seeds the indicator from that session's
  cached host status, including after restarting Emacs when `turn/start` is
  outside the retained history window. The elapsed clock starts at local open.
  Cached status seeds only a fresh transcript; reconnecting an existing chat
  preserves its observed state so a delayed cache cannot undo `turn/end`.
- Ending the last active turn or compaction, or disconnecting, stops only
  that chat's slot. Buffer death and major-mode changes also release it.
  No scheduler remains once all slots stop. Hidden buffers skip intermediate
  rendering and catch up when visible.
- When idle, the native activity segment disappears; the major-mode name
  remains plain `DSH`. Without Motion Line, it still stays plain during
  activity, beside static `Deep diving` or `Compacting` text with no clock.
  Doom returns to its static major-mode tail; its larger whale logo, other
  status labels and stats retain their normal layout.
- The splicing is done with `(:eval …)` and is recomputed live on
  `force-mode-line-update`.
- **Buffer name**: session buffers are named `dsh: <list title>` (matching the
  title of the row in the `*dsh-sessions*` list, with `dsh: ` prepended), which is
  what `%b` in the mode line shows; a `%` in the title is replaced with the
  full-width `％` (mode-line `%`-expansion would swallow characters), sessions
  with the same title automatically get a `<N>` suffix, and the buffer is
  renamed automatically with the list refresh after a title drifts or is
  renamed. Sessions without a title use `dsh: <session-id>`; subagent chats
  use `dsh: <parent title>/<label>`.

The animation lights up when a message is sent or compaction starts and goes
out when both activities finish; it is cleaned up automatically when the
event stream disconnects.
While a text refresh is pending, the animation advances without forcing an
additional redraw; the text refresh also paints the indicator. Quiet visible
turns redraw through the shared animation scheduler. See
[037](../postmortem/037-streaming-display-cpu.md) and
[095](../postmortem/095-running-status.md).

### Step badge

A turn is executed in **steps**, one model call plus the tool executions it
requested (`step/start` … `step/end`).  Steps are turn-internal boundaries,
not conversation, so they never appear in the transcript.  With
`dsh-emacs-modeline-show-step` enabled (**off by default** — the step number
is diagnostic, so the mode line stays quiet unless asked), the running turn's
step shows right after the running whale tail:

```elisp
(setq dsh-emacs-modeline-show-step t)
```

```
 U:***  %b   L40  DSH [whale tail] Deep diving · 12s step 2 · 3s  (deepseek-v4-flash max ptc 95.0%)
```

- The badge comes from `dsh-emacs-modeline-note-step`, which the renderer
  calls for every `step/start` / `step/end`.  It is hidden whenever the option
  is off or the running animation is hidden: a finished turn's last step is
  not a status.
- The elapsed time (`· 3s`, then `· 1m05s`) is measured in local wall-clock
  time, not from the event timestamps: a reconnect (or opening the session
  again after killing its buffer) replays a still-open turn's `step/start`
  from history, and the wire timestamp would then claim hours.  It appears
  once the step passes one second, advances with the animation's redraws (no
  timer of its own) and freezes at `step/end`.
- The tooltip carries the full `dsh turn N · step N`, which the badgeless
  compact form elides.
- A `step/end` only closes the step it names, so a replayed or out-of-order
  end cannot replace a newer step.

### Execution feedback

The mode line has no separate retry label. The transcript's attempt card uses
`llm/retry`, `llm/retry-started` and `turn/end` to distinguish outcomes:

- **Retry n/m · scheduled** → **Retry n/m · started** when the wait finishes.
  Policies without a fixed limit omit `/m`; the metadata shows the scheduled
  wait, not a countdown. Hover for provider, failure code and message.
- **Failed reply** or **Cancelled reply** when the unresolved attempt ends.
- **Retry cancelled** when cancellation interrupts the scheduled wait.
- **Incomplete reply** while the outcome is unknown or absent from history.

Cards use a shared status dot (orange retry, red failure, grey cancelled or
unknown), the tool title face, and muted turn/step metadata. They open expanded when replacing live output and folded
in history; empty output has no disclosure. State updates preserve folding
and partial text. Final model failures retain a separate `Model error` row
with the same icon and compact styling, muted error-code metadata, and an
initially expanded explanation.

During context compaction, teal `Compacting · 12s` replaces `Deep diving` in
the existing whale-tail slot, with the same gentle text sweep. Its clock
starts when the buffer observes that compaction and does not reset on
repeated snapshots of the same operation. The underlying turn clock keeps
running; when compaction finishes, `Deep diving` resumes with that elapsed
turn time. Standalone compaction between turns starts the same slot without
claiming a running turn. Without Motion Line, the caption is static
`Compacting`, with no clock or animation timer.

Hover or click the compaction or Plan label, or run
`M-x dsh-emacs-describe-status`, to see compaction and Plan mode details.
The details buffer is a snapshot taken when opened.

Compaction status comes from `compaction/start` and `compaction/end`.
Matching end events or the enclosing turn's end clear it;
disconnect clears them immediately. Reconnection rebuilds state from the
follow snapshot's retained event window, independently of transcript dedup.
If that window no longer includes the operation's start, no label is shown:
the client has no current evidence of it. Loading older history never changes
the current execution status. Compaction shares the existing Motion Line slot
and scheduler; it adds no polling or separate animation timer.

Retry transitions and compaction start/end do not add transcript rows.
An automatic `compaction/summary` event adds a folded **Automatic compaction**
row. `RET` or a click expands the generated summary. Its header counts the
covered items and shows an approximate token count for the old context, for
example `3 history items · ~42k tokens`. Neither value measures saved tokens
or the context that remains. The original conversation stays visible, and raw
model output and the checkpoint body stay hidden. The neutral title records a
summary being generated, since applying the checkpoint can still fail
afterward. Such a failure leaves a separate
`Context compaction failed` card. Manual `/compact` summary events are hidden;
the existing command result card keeps its counts and result or failure text.
If the retained history window lacks the summary, no summary row is shown
and no extra fetch is made. See [104](../postmortem/104-auto-compaction-feedback.md).

### Plan mode

The mode line shows the session's collaboration mode even when no turn is
running:

| Label | Current state | Requested change |
|---|---|---|
| `Plan` | Active | None |
| `Plan → on` | Inactive | Enter Plan mode |
| `Plan → off` | Active | Leave Plan mode |
| Hidden | Inactive or unavailable | None |

Use `/plan` to enter and `/plan off` to leave. Hover, click or run
`M-x dsh-emacs-describe-status` to inspect the current and pending state.
Pending means the host has not confirmed the selected mode; it is not a
request for user approval. During a turn the switch applies at the next
accepted step; between turns the host can apply it immediately.

The `plan` projection is authoritative. Finishing a turn or loading older
history keeps the current mode. A disconnected chat retains its last known
mode; opening a new core connection clears the old generation's state and
reseeds it. Follow snapshots and control baselines merge by sequence, so an
older snapshot cannot undo a newer selection, including a pending switch.
An absent `plan` key in a current baseline removes the badge and means the
capability is unavailable.

Plan mode supplies planning guidance to the model. Sandbox permissions and
approval policy remain independent. Todo cards continue to show task progress;
their presence does not imply that Plan mode is active.

### Queue and background jobs

Pending input stays in the Composer Next Message preview above the input.
Use `C-c C-q` (`dsh-emacs-list-queue`) for queued/steering counts and the full
queue manager. Neither native nor Doom mode lines show a queue segment;
counts are not passively visible when the input area is off screen. See
[queue ownership](architecture.md#pending-input-queue-inbox-projection-on-sessioncontrol)
and [decision record 114](../postmortem/114-remove-queue-modeline.md).

Background jobs use their transcript tool rows for status. `C-c C-j`
(`dsh-emacs-list-jobs`) opens the job manager; they have no mode-line segment.

### Why the branch segment is cached

Cwd is read from the chat buffer's `default-directory`; Git branch detection
runs in that directory. There is no separate display override. The unused
Lisp APIs `dsh-emacs-modeline-set-cwd`, `dsh-emacs-modeline-set-branch` and
`dsh-emacs-modeline-teardown` are removed in 0.7.0 without aliases; remove
external calls to them. Doom segment registration stays package-scoped,
not a per-chat teardown operation. Opening a chat no longer prints internal
mode-line setup flags. See [decision record 138](../postmortem/138-unused-helpers-and-modeline-overrides.md).

The branch segment has a 10-second TTL cache
(`dsh-emacs-modeline-branch-refresh-interval`): the running whale animation
can trigger a mode-line recomputation about every 50ms, and without caching each
tick would fork a `git rev-parse` subprocess (~30ms+), which would freeze Emacs;
the nil result for non-git directories is cached too, so it never respawns.

## Subagents

The child count uses a 1px SVG with a brain above three downward branches,
inheriting
`dsh-emacs-modeline-face` like the existing status text. Without SVG support it
uses `nerd-icons`' `nf-md-source_branch` when available, then `Sub`.
The total uses bold digits and a half-character gap after the icon, like
Flycheck's mode-line counts, while keeping the muted status-text color.
`Sub 3` means three direct children in the text fallback. Only the total is
shown; the tooltip includes the running count. Mouse-1 opens
`dsh-emacs-list-subagents` in the
minibuffer.
While the connection is live and at least one direct child is running, the
icon and the child count pulse together between the muted mode-line color and
the running orange, roughly once a second, with no separate spinner or layout
shift.  The pulse is a motion-line clip (`dsh-subagents` slot, about 1.2s per
cycle), so it needs motion-line installed; without it the icon and count keep
their static tint.  It stops when the last child settles; a stale running flag
on a disconnected connection never animates.  Only an SVG-capable display
repaints the icon, and the `nerd-icons` and `Sub` fallbacks stay static.  The
motion-line slot is buffer-local, so one chat's pulse cannot drive another's.
Child chats show their direct parent, label and mode. A child that has
descendants can also have its own child-count indicator.
The completion annotations' cumulative token projection includes uncached
input, output, cache read and cache write; it is independent of this mode line's message-based
usage accumulator and does not estimate cost.

## Animation backend boundary

All `motion-line` access goes through the public
`dsh-emacs-modeline-animation-*` facade in `dsh-emacs-modeline.el`.  The whale
and the subagent pulse ask that facade to play, stop, query playback or return
the cached animated text; `dsh-emacs-subagent.el` no longer calls
`motion-line` directly.  Rendering still falls back to static text and colors
when the backend is absent.

## Testing the optional animation integration

`scripts/verify.sh` works without Motion Line: the suite checks loading and
running-state cleanup in a fresh Emacs process with no animation library, and
the animation playback tests report skips. When an engine is available the
gate runs the suite against it as well, preferring the sibling
`../motion-line` checkout — engine development lives there — over an installed
package; `DSH_MOTION_LINE_DIR` overrides both. To run one configuration by
hand:

```sh
emacs -Q --batch -L /path/to/motion-line -l test/dsh-test.el
```

Those tests need an engine that exposes the deterministic seams
`motion-line-current-time-function` and `motion-line-visible-p-function`
(that repository's postmortem/002). An older install fails loudly instead of
silently skipping, so a stale package cannot leave the animated path
unverified.
