# Mode-line Status

The major-mode label uses the DeepSeek Harness whale SVG with its vertical
padding cropped to match the permission shield's visible height, without
making the mode line taller or adding a badge or background. It retains the
standard Emacs major-mode menu in both native and Doom mode lines. Terminals
and builds without SVG support display `DSH`. The logo is blue (`#4d6bfe`) on dark
frames and black on light frames, following Emacs's `background-mode` frame
parameter on each redraw. Changing themes updates the color automatically.

The stats use `dsh-emacs-modeline-format-spec` to choose segments and their
separator (one space by default). Status indicators—animation, Plan/retry,
queue and subagents—and the parenthesized stats have one separating
space in both native and Doom mode lines. Empty indicators add no gaps; SVG
placeholders retain their display and click properties. Doom's extra padding
around the major-mode label is removed in chat buffers so adjacent segments
provide a single separating space.

Available stats segments:

- **cwd**: current working directory (home path abbreviated with `~`)
- **branch**: git branch name (auto-detected)
- **model**: current model name (fed live from `request/header` / `request/context`)
- **effort**: reasoning effort — the `reasoningEffort` chosen via the model
  picker, or the one the host announces in `request/header` (e.g. `high`)
- **preset**: agent preset of the session (`agentPreset`, e.g. `standard` / `code`)
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
tokens, pressure tokens and context window). dsh-emacs feeds this snapshot into
the mode-line: the projected tokens are used when present (`projectedTokens ??
pressureTokens`), and the window comes from the same server projection. No local
model→window map is maintained and no full session refresh is needed — the
segment updates as the server's projection frames arrive. Without a server
snapshot the ctx segment is simply hidden; a model change or session open pulls
the projection immediately.

## Mode Line (session buffer status bar)

dsh-emacs does **not replace** your mode line; instead it makes two small
additions to your existing (default or custom) `mode-line-format`: while **dsh
is running** (after sending a prompt, before `turn/end` is received), a spinner
animation is shown beside the DSH mode name (end-of-line area); the stats
segment is appended at the far right. The modified flag, line/column position,
primary/secondary modes, misc-info, and all other existing content are
preserved:

```
 U:***  %b   L40  DSH [██  ]  [ deepseek-v4-flash • max • code • CH95% ]
```

- **Spinner animation**: filled progress bar (`[█   ]` fills to `[████]` then
  drains to `[   █]`, the `progress-bar-filled` style from Malabarba's
  spinner.el, with the track drawn as square brackets),
  `dsh-emacs-mode-line-busy-face` (amber), about 12.5fps, displayed at the end
  of the line next to the DSH mode name.
- The animation is hidden when idle; when the stats segment is empty the right
  end is not shown either (the right side of the mode line stays as-is).
- The splicing is done with `(:eval …)` and is recomputed live on
  `force-mode-line-update`.
- **Buffer name**: session buffers are named `dsh-<list title>` (matching the
  title of the row in the `*dsh-sessions*` list, with `dsh` prepended), which is
  what `%b` in the mode line shows; a `%` in the title is replaced with the
  full-width `％` (mode-line `%`-expansion would swallow characters), sessions
  with the same title automatically get a `<N>` suffix, and the buffer is
  renamed automatically with the list refresh after a title drifts or is
  renamed.

The animation lights up when a message is sent and goes out at `turn/end`; it
is cleaned up automatically when the event stream disconnects.
While a text refresh is pending, the animation advances without forcing an
additional redraw; the text refresh also paints the indicator. Quiet visible
turns keep the normal animation timer. See
[037](../postmortem/037-streaming-display-cpu.md).

### Step badge

A turn is executed in **steps**, one model call plus the tool executions it
requested (`step/start` … `step/end`).  Steps are turn-internal boundaries,
not conversation, so they never appear in the transcript.  With
`dsh-emacs-modeline-show-step` enabled (**off by default** — the step number
is diagnostic, so the mode line stays quiet unless asked), the running turn's
step shows right after the spinner:

```elisp
(setq dsh-emacs-modeline-show-step t)
```

```
 U:***  %b   L40  DSH [██  ] step 2 · 3s  [ deepseek-v4-flash • max • code • CH95% ]
```

- The badge comes from `dsh-emacs-modeline-note-step`, which the renderer
  calls for every `step/start` / `step/end`.  It is hidden whenever the option
  is off or the running animation is hidden: a finished turn's last step is
  not a status.
- The elapsed time (`· 3s`, then `· 1m05s`) is measured in local wall-clock
  time, not from the event timestamps: a reconnect or session reopen replays a
  still-open turn's `step/start` from history, and the wire timestamp would
  then claim hours.  It appears once the step passes one second, advances with
  the animation's redraws (no timer of its own) and freezes at `step/end`.
- The tooltip carries the full `dsh turn N · step N`, which the badgeless
  compact form elides.
- A `step/end` only closes the step it names, so a replayed or out-of-order
  end cannot replace a newer step.

### Execution feedback

The mode line shows exceptional execution states beside the running animation:

| Label | Meaning |
|---|---|
| `Retry 1/3` | Waiting before the first retry, with a limit of three retries |
| `Retrying 1/3` | That retry request has started |
| `Retry 7` | Waiting to retry under a policy with no fixed retry limit |
| `Compacting` | Context compaction is in progress |

Hover or click the label, or run `M-x dsh-emacs-describe-status`, to see
the provider, retry count, scheduled wait and last failure reason/code when
available. The scheduled wait is the server's delay, not a local countdown.
The details buffer is a snapshot taken when opened. Standalone compaction
between turns is visible even without a running animation; if retry and
compaction overlap, both labels appear.

These labels come from `llm/retry`, `llm/retry-started`, `compaction/start`
and `compaction/end`. Matching completion/cancellation boundaries clear them;
disconnect clears them immediately. Reconnection rebuilds state from the
follow snapshot's retained event window, independently of transcript dedup.
If that window no longer includes the operation's start, no label is shown:
the client has no current evidence of it. Loading older history never changes
the current execution status. There is no extra polling or animation timer.

Successful retry/compaction transitions do not add transcript rows. An
automatic compaction failure leaves a `Context compaction failed` card with
the reason; a manual `/compact` failure uses the existing command result card.

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

### Pending-input queue indicator

While messages are queued or steering, a `[Q2 S1]` indicator (queued /
steering counts; zero-count placements are omitted) sits right after the
running animation, colored with `dsh-emacs-modeline-queue-face` (amber) and
clickable (`mouse-1` opens `dsh-emacs-list-queue`).  It is hidden when
nothing is pending — including when the queue holds only host-injected
`context` items, which are neither counted nor listed, matching dsh web's
QueueDock.  The counts come from the `inbox` session projection mirrored by
`dsh-emacs-queue.el` (delivered as `session/control` `projection` frames), so the
segment is live without any polling.

Background jobs use their transcript tool rows for status. `C-c C-j`
(`dsh-emacs-list-jobs`) opens the job manager; they have no mode-line segment.

### Why the branch segment is cached

The branch segment has a 10-second TTL cache
(`dsh-emacs-modeline-branch-refresh-interval`): the running spinner animation
can trigger a mode-line recomputation about every 80ms, and without caching each
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
minibuffer. `S` remains reserved for steering messages.
Child chats show their direct parent, label and mode. A child that has
descendants can also have its own child-count indicator.
The completion annotations' cumulative token projection includes uncached
input, output, cache read and cache write; it is independent of this mode line's message-based
usage accumulator and does not estimate cost.
