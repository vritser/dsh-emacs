# Mode-line Status

The mode line shows the
following segments (separated by ` • `):

- **cwd**: current working directory (home path abbreviated with `~`)
- **branch**: git branch name (auto-detected)
- **model**: current model name (fed live from `request/header` / `request/context`)
- **effort**: reasoning effort — the `reasoningEffort` chosen via the model
  picker, or the one the host announces in `request/header` (e.g. `high`)
- **preset**: agent preset of the session (`agentPreset`, e.g. `standard` / `code`)
- **tokens**: token usage (`↑input ↓output Rcache-read Wcache-write CHcache-hit%`)
- **ctx**: context-window usage percentage (color-coded)
- **cost**: cumulative cost (USD)

The stats can be toggled with `C-c C-f`, or controlled via the
`dsh-emacs-modeline-enabled` customization option. The layout and faces are
documented in [UI Styling](ui-styling.md).

## How ctx% is computed

The dsh server computes context pressure itself and pushes it to every client
as `session/projection` frames (`key: "contextPressure"` → projected tokens,
pressure tokens and context window). dsh-emacs feeds this snapshot into the
mode-line: the projected tokens are used when present (`projectedTokens ?? 
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

### Why the branch segment is cached

The branch segment has a 10-second TTL cache
(`dsh-emacs-modeline-branch-refresh-interval`): the running spinner animation
triggers a mode-line recomputation about every 80ms, and without caching each
tick would fork a `git rev-parse` subprocess (~30ms+), which would freeze Emacs;
the nil result for non-git directories is cached too, so it never respawns.