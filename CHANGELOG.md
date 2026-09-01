# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Unreleased
sections carry the planned next version (pre-1.0: `fix` → patch, features →
minor) and stay undated until the release is cut.

## 0.2.0 - Unreleased

### Breaking Changes

- **Status bar renamed from "footer" to "mode-line"**: the customize group
  `dsh-emacs-footer` is now `dsh-emacs-modeline`, and its options
  `dsh-emacs-footer-enabled` / `-format-spec` / `-branch-refresh-interval`
  became `dsh-emacs-modeline-*`.  No compatibility aliases are retained.
- **Manual context-window options removed**: `dsh-emacs-footer-context-window`
  and `dsh-emacs-footer-context-window-alist` are gone.  The ctx% segment is
  driven exclusively by the context window the server reports; saved
  customizations of the old options are silently dropped on upgrade.
- **HTTP polling fallback removed**: `dsh-emacs-poll-fallback`,
  `dsh-emacs-poll-interval` and `dsh-emacs-poll-warn-delay` are gone.  The
  WebSocket event stream is the only automatic reply channel: if it is down,
  replies appear only once the stream recovers or via manual refresh
  (`C-c C-r`).  Saved customizations of the removed options are silently
  dropped on upgrade.

### Added

- **Filter-free question chooser**: single-select `ask` prompts now behave
  like a static key menu instead of a typing-narrowed completion prompt —
  pressing `1`–`9` (`0` = the 10th option) picks that option immediately,
  `t` switches to the `Type answer…` free-text path, and typing is inert,
  so the numbered option list never narrows out from under you.  Without
  a list-rendering completion UI (vertico, icomplete, fido, ivy) the
  numbered options are embedded in the prompt itself, so the same keys
  work on a bare minibuffer.  Multi-select questions keep plain
  comma-separated typing.
- **Per-question skip in `ask` prompts**: the `dsh-emacs-question-skip-key`
  shortcut (a single `s` keypress by default, configurable, nil disables)
  answers that single question with an empty selection — dsh web's
  per-question Skip — and moves on to the next question; an option-less
  free-text question is skipped by submitting an empty input.
- **Session switching**: `M-x dsh-emacs-switch-workspace-session` (`C-c C-s`)
  switches among sessions in the current workspace, and
  `M-x dsh-emacs-switch-session` (`C-u C-c C-s`) switches across all
  workspaces and the Ungrouped bucket.  Workspace names never take part in
  filtering; they only disambiguate same-titled sessions.
- **Shared visible-session rule for switch candidates**: both scopes offer
  exactly the sessions dsh web shows — no archived, subagent or blank rows —
  through `dsh-emacs-session--visible-p`, and the empty-input candidate offer
  is recency-bounded by `dsh-emacs-switch-max-candidates`.
- **New sessions inherit the current workspace**: starting a session from a
  chat buffer creates it inside that session's workspace instead of the
  ungrouped pool.
- **Image attachments are rendered inline** in the chat transcript.
- **Run-finished notifications**: when a submitted run ends while its chat
  buffer is not visible on the focused frame, a notification is posted
  (echo-area fallback); toggle with `dsh-emacs-enable-notifications`.
- **Interactive approval prompts**: `approval/requested` frames are answered
  in the minibuffer and the response goes out through the same `/api/respond`
  path as `ask` questions; prompts are serialized so only one owns the
  minibuffer at a time.
- **Remote dsh servers are a first-class target**: probe failures against a
  non-loopback base URL no longer spawn or install the local `dsh` CLI,
  HTTPS probes wait at most 5s, and URL userinfo (basic auth) is carried on
  the raw-TCP probe and the WebSocket handshake as well as the RPC path.
- **Opt-in `provider` mode-line segment** listing the provider id serving
  the model (enable it in `dsh-emacs-modeline-format-spec`); hidden while
  the provider is unknown.  The provider also rides the model segment's
  tooltip.
- **Mode-line segment tooltips and hover highlight** using the standard
  `mode-line-highlight` mouse-face affordance.
- **Contributor tooling**: `scripts/verify.sh` aggregates every
  machine-checkable verification step into a single exit-code gate.

### Changed

- **`scripts/check-lisp.el` is diagnostics-only**: the auto-fixer was
  replaced by an ordered root-cause report (line / column / offset /
  context); repair procedure is documented in `AGENTS.md`.

### Fixed

- **C-g on a question abandons the whole group like dsh web**: pressing
  `C-g` (or entering an empty no-option answer) now answers the frame
  with the protocol's reserved `cancelled` receipt — `result.ok: false`
  with `error.code: "cancelled"`, the exact signal dsh web's "abandon
  questions" sends — so the host withdraws the ask and broadcasts
  `question/resolved` (`cancelled`), and the agent's turn is never left
  blocked; previously nothing was sent and the run stayed stuck until
  interrupted.
- **Replayed questions no longer re-ask**: a `question/requested` whose
  rpcId is already pending (queued or being answered — the mux replays the
  same request on reconnect) is dropped, and the host's `question/resolved`
  push retires any still-queued copy, so the user is never asked the same
  question twice after a stream replay.
- **Context usage reflects the server**: the footer ctx% is seeded when a
  session opens and updated live from `session/projection` frames, instead
  of only showing manually configured values.
- **ctx% survives incomplete session rows**: a `session.list` entry without
  context-window data no longer hides a usage percentage already known from
  projection frames.
- **ctx% survives a failed model run**: a provider rejection (quota/rate)
  reports usage 0/0, which the server's context-pressure fold turns into a
  0-token projection; the mode-line now keeps the last genuine snapshot
  until the next successful run reports real usage, instead of dropping to
  0%.
- **ctx% survives re-submitting after a model error**: the failed run's
  zero usage sample also corrupts the projection's derived
  `projectedTokens` (it recovers to a small lying value as the session
  surface grows); every projection whose raw usage sample is zero is now
  ignored, so submitting a new prompt no longer resets the shown
  percentage to ~0%.
- **`C-c C-r` no longer mixes transcripts between sessions**: refreshing an
  older chat buffer (one that is not the last-opened session) used to render
  its history into the last-opened session's buffer; the history now renders
  into the chat buffer the refresh was issued from.
- **Mode-line model segment syncs with the live catalog**: provider, model
  and reasoning effort land asynchronously from `session.models`' `current`
  entry instead of trusting the client's default guess.
- **Prompt images reach the model** as message content parts rather than
  being dropped from the sent payload.
- **A reconnected session keeps rendering replies**: after a chat's mux
  socket drops, the reconnect handshake used to fail on a reused events
  buffer (the re-inferred process coding system folded the 101 response's
  CRLF terminator, so the handshake never completed and the health check
  kept killing the socket — that session silently stopped showing replies
  while other sessions' streams kept working); the socket now pins
  `no-conversion`, and a synchronous connect failure (unresolvable host,
  malformed base URL) restores HTTP polling and schedules the next retry
  instead of leaving the chat with no recovery channel.
- **Opening a session stays lightweight on big/far sessions**: while the
  initial history is loading, fallback polling ticks now stand down — the
  load gap is covered by the bounded re-fetch, and a poll tick's
  chunk-replay rendering would otherwise re-impose the "replay old deltas"
  cost the snapshot-first page render was designed to avoid.

### Documentation

- README restructured around the quick start; deep guides split into
  `docs/` (customization, modeline, slash-commands, …) and a dsh RPC wire
  protocol reference added as `docs/rpc.md`.

## 0.1.0 - 2026-08-28

First release of `dsh-emacs`, an Emacs client for the
[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`)
web service. It talks to a running dsh web server over HTTP/WebSocket and
renders sessions, streaming replies, tool calls and thinking blocks with an
Emacs-native UI — built on core `url` / `json` only (Emacs 27.1+). Everything
below is new in this release.

### Added

- **Session list** (`*dsh-sessions*`): card-style browsing with search filter;
  create, open, rename, archive (`workspace.archiveSession`) and fork sessions;
  workspace filter (`w`) with a sticky header, empty-input clearing and an
  auto-refresh timer; workspace ordering driven by the host event stream;
  focus kept on redraw with the cursor parked on the first row when opening.
- **Chat buffer**: read-only Markdown transcript with a fixed input area,
  streaming output, interrupt (`C-c C-c`, `session.cancel`), image attachments
  (`C-c C-a` / drag & drop), code-block copy (`C-c C-k`), input history
  (`M-p` / `M-n`), and imenu navigation over user input. Failed model turns
  surface as a visible error row, duplicate user-message echoes on delivery
  races are suppressed, and replay is interruptible with a buffer-size cap for
  very large histories.
- **Slash commands**: a `/name` line is dispatched to the host command registry
  (`commands.execute`) instead of the model; `/` pops the live command catalog
  (corfu, `*Completions*`, or vertico in-region), `TAB` completes `/name`
  anywhere, and `M-x dsh-emacs-command` picks a command with its argument hint.
  Running slash-command rows get a whole-block pending tint with a classic
  `-\|/` spinner.
- **Interactive `ask` questions**: questions from the agent's `ask` tool are
  answered in the minibuffer — numbered options, free-text fallback,
  multi-select, `Question N/M` framing, per-session prompt labels — and the
  reply goes out via `/api/respond` (dsh 0.1.1-rc.2 `question/requested` flow).
- **Model picker** (`C-c C-m`): the live `session.models` catalog grouped by
  provider with sticky headers, plus a reasoning-effort mini-prompt for models
  that declare `reasoning` options (`session.selectModel`).
- **Agent presets**: pick the thinking preset from `agentPreset.list` when
  creating a session (`C-u M-x dsh-emacs-new-session`).
- **On-demand server bootstrap**: the `dsh` CLI is auto-detected (install
  prompt when missing), the server is spawned and awaited before the first RPC —
  the interactive start is non-blocking, and an eager background start option
  (`dsh-emacs-server-start-on-init`) is available; `M-x dsh-emacs-open-web`
  opens the dsh web UI.
- **Footer status bar** (`C-c C-f`): cwd, git branch, model, reasoning effort,
  agent preset, token usage, context-window percentage and cost as mode-line
  segments, customizable via `customize-group dsh-emacs-footer`; busy/spinner
  state stays per-buffer when several sessions run concurrently.
- **Todo rows**: per-event rendering of the agent's todo list with accumulated
  per-event state.
- **Thinking blocks**: one face for the entire block, collapsible, folded by
  default, with a first-sentence preview.
- **Tool-call rows**: dsh web-style collapsible rows; per-tool display titles
  decoupled from icons (web_search globe, bash terminal), with an optional
  icon/label separator.
- **Resilient event stream**: native RFC 6455 WebSocket client with fallback
  polling, a watchdog and anchored incremental history rendering; the
  mode-line busy indicator and command spinner survive WebSocket reconnects;
  each session's stream stays alive while other sessions are opened; RPC parse
  errors are dispatched cleanly; server readiness is polled before the first
  RPC in the session list.
- **Scroll discipline**: telega-style — the input area stays visible while
  typing and page commands land on line boundaries.
- **Blank lines around user messages** for visual separation.
- **Contributor tooling**: `scripts/check-lisp.el` read-balance checker and a
  testcover coverage report (`scripts/check-coverage.el`).
