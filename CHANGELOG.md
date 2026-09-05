# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Unreleased
sections carry the planned next version (pre-1.0: `fix` → patch, features →
minor) and stay undated until the release is cut.

## 0.3.0 - Unreleased

### Breaking Changes

- **dsh 0.1.2 wire protocol migration**: the client now talks the dsh 0.1.2
  RPC/stream protocol.  The realtime event surfaces moved from the old
  per-session mux + host stream (`/api/events.mux`, `/api/events.host`,
  `session.history`, `session/event` envelope frames) to a single
  `/api/remote.mux` WebSocket multiplexing logical streams: a chat opens a
  `session/follow` stream whose snapshot seeds the transcript and whose
  `event` items render live; the session list keeps a core connection
  (`session/control` + `workspace/follow` + `$events`).  RPC endpoints use
  the two-segment slash form (`session/list`, `session/create`, …) with the
  request body wrapped as `payload = {args: …}`.  Ask-questions and tool
  approvals arrive as `$events` waterfall frames and are answered through
  the unary `$events/result` RPC (there is no `/api/respond` and no
  `approvalId` on the wire); a question's answers carry the selected option
  ids, and approval answers are the strings `allowed-once` / `rejected`.
  Workspace state (workspaces, session→workspace membership, archives) is
  delivered by the `workspace/follow` stream instead of a `workspace.list`
  RPC.  `dsh-emacs-history-refetch-max-rounds` is removed — the snapshot
  seeds the opening tail and reconnects reseed via a fresh snapshot, so no
  load-gap backfill option exists.  Saved customizations of the removed
  option are silently dropped on upgrade
  (rationale: postmortem/009).
- **Slash-command auto-pop now goes through the user's own completion
  front-end instead of dsh-emacs driving one**: typing `/` no longer opens
  the command list via dsh-emacs' own content-driven `post-command` trigger
  (which called `completion-at-point` on a short timer to force a popup for
  stock `*Completions*` / vertico / ivy — and, for corfu users, buffer-locally
  force-enabled `corfu-auto` and hooked `corfu-auto--post-command`).  That
  self-driven path is removed.  dsh-emacs is a completion *backend*: it
  registers `completion-at-point-functions` in chat buffers, and contributes
  `/` to the auto trigger of a front-end only when that front-end's own auto
  mode is already on — corfu (`/` added to `corfu-auto-trigger` when
  `corfu-auto` is enabled) and company (works through `company-capf` / its own
  idle delay).  Stock `*Completions*` / vertico / icomplete have no auto
  channel and stay `TAB`-only.  The option `dsh-emacs-slash-auto-complete`
  (default `t`) now controls whether that `/` trigger is contributed at all
  (rationale: postmortem/011).

### Added

- **Browser-session authentication for dsh web (0.1.2-rc.1+)**: recent dsh
  servers return `401` on every RPC and WebSocket stream unless the request
  carries a `dsh-auth-*` browser cookie minted from the per-process launch
  token the server prints (`dsh web: …/?token=…`).  dsh-emacs now performs
  that token→cookie exchange itself — parsing the token from the managed
  server's output automatically (or from a user-supplied
  `dsh-emacs-server-auth-token` or a `?token=` in `dsh-emacs-base-url` for a
  server dsh-emacs didn't start) and sending the cookie on all RPC posts and
  the `/api/remote.mux` WebSocket handshakes, and the
  `dsh web` URL opened by `dsh-emacs-open-web`.  A `?token=` in the base URL
  is stripped before request paths are appended, so pasting dsh's printed URL
  into `dsh-emacs-base-url` works.  A `401` RPC now reports an actionable
  hint instead of a generic HTTP error (rationale: postmortem/008).
- **External servers ask for the launch token instead of popping a
  username/password box**: when dsh-emacs points at an already-running
  (external) dsh 0.1.2-rc.1+ server that requires the browser-session
  cookie and no token is configured, the first server-touching command now
  prompts you once for the `token=` value from the URL the server printed,
  mints the cookie, and proceeds — previously the unauthenticated RPC came
  back `401` and Emacs' `url` library fell back to a Basic username/password
  prompt that could never succeed (rationale: postmortem/008).
- **Realtime live chat**: an open chat keeps a `session/follow` stream on
  the shared `/api/remote.mux` socket, so replies stream in live and the
  transcript never needs a polling or manual-history refresh; the follow
  snapshot seeds the opening tail and reconnects reseed it, so nothing is
  missed during a drop (rationale: postmortem/009).
- **Realtime session list**: the session list keeps a core connection
  (`session/control` + `workspace/follow` + `$events`), so workspace/
  session/archive changes from any client repaint the list in place — no
  `g` needed — and queue/context projections stay current
  (rationale: postmortem/009).
- **@ file/session references (web-style @ mentions)**: typing `@` in the chat
  input opens a combined completion menu — file/directory candidates from the
  session workspace (`fileReferences/list`) first, then session candidates
  (`sessionReferenceResolver/candidates`).  Rows are grouped files →
  directories → sessions in the host's order; picking a file inserts `@path`,
  a directory inserts `@dir/` and keeps the menu open for the next level, and
  a session inserts the host's canonical `@[label](dsh-session:…)` mention.
  Matching is flexible — the `@` completion category uses the built-in `flex`
  style in chat buffers (independent of your `completion-styles`), so typing a
  word anywhere in a path narrows to it.
  Grammar (`@"path with spaces"` quoting), host-side snapshots, and
  stale-while-revalidate caching mirror dsh web's composer.  Completion is
  cooperative like slash: dsh-emacs registers a `completion-at-point-functions`
  backend and contributes `@` to an already-active front-end auto trigger
  (corfu-auto), never driving the popup itself — a data-fetch watcher keeps
  corfu's list fresh as the query changes, and stock/vertico/icomplete
  complete on TAB.  Open-session prefetch, `M-x dsh-emacs-reference`, and the
  `dsh-emacs-reference-*` options are covered in
  [docs/reference.md](docs/reference.md) (rationale: postmortem/010).

### Fixed

- **`@` completion rows keep their type icon while a background fetch is
  refreshing the list**: the icon column reverse-looked-up each shown row in
  the mutable candidate cache, so once a fetch for a narrower query replaced
  that cache (corfu keeps showing the older snapshot popup and re-affixes it
  on every keystroke), rows no longer present in the swapped cache rendered
  without an icon.  The icon data is now captured into the completion table
  when it is built and affixed from that snapshot, independent of later cache
  replacement (rationale: postmortem/010).
- **The `commands.list` catalog prefetch stays live while the assistant is
  replying**: the prefetch was armed on an idle timer, and idle timers do not
  fire while subprocess output is pending — the event stream keeps delivering
  while a reply streams, so the catalog could stay uncached until the reply
  paused and the first `/` or TAB then hit a blocking synchronous fetch inside
  the completion backend.  The prefetch now arms a plain one-shot timer.
- **Sending non-ASCII (Chinese) messages works again**: the browser-session
  cookie was captured with `match-string` from a network response buffer, so
  even its pure-ASCII content carried the multibyte string flag.  Emacs'
  `url` library rejects a request whose concatenated header+body is multibyte
  (`url-http-create-request` errors "Multibyte text in HTTP request" when
  `string-bytes` ≠ `length`, Bug#23750), and a multibyte-flagged cookie header
  mixed with the unibyte-encoded request body tripped exactly that — every
  Chinese message failed before it was sent.  The cookie is now returned as a
  true unibyte byte string, so the RPC header and the WebSocket handshake stay
  single-byte regardless of the body's non-ASCII payload
  (rationale: postmortem/009).
- **The model picker shows the session's actual running model as
  "current"**: `session/modelCatalog` is session-agnostic and only carries
  the host `default`, so the picker used to announce the host default as the
  session's "current" model — disagreeing with the mode-line (which reads the
  session's `modelSelection` projection), misreporting empty-RET "Kept
  current model", and pre-selecting a fresh effort instead of the running
  model's live one.  The picker now derives its reference from the cached
  session row's `modelSelection` projection, falling back to the catalog
  default only for a session that has none yet (rationale: postmortem/009).
- **A stale browser-session cookie self-heals instead of 401-looping**: when
  an out-of-band dsh server restarts it mints a new per-process token,
  silently invalidating the cookie this client cached.  A request that came
  back `401` while carrying our cookie now clears the cached cookie (and the
  ask-once memory), so the next call re-mints from a fresh token / re-prompts
  instead of failing every RPC until Emacs restarts (rationale: postmortem/008).
- **`g` workspace refresh no longer opens a second live `workspace/follow`
  stream**: the re-baseline path re-opened `workspace/follow` on the live
  core socket without retiring the one opened at connect, so two streams fed
  the same workspace/archive caches (a stale frame from the retired stream
  could transiently revert a newer reorder).  The prior stream is now
  cancelled before a fresh one is opened, and the no-core fallback just
  connects (its own handshake-time baseline repaints) instead of sending an
  `open` frame before the WS upgrade completes (rationale: postmortem/009).
- **The session list is grouped by workspace again**: the `workspace/follow`
  and `session/control` `baseline` frames were misrouted — unlike the
  incremental frames (`upsert`/`order`/`queue`/`projection`, whose fields sit
  on the frame), a baseline nests its payload one level deeper
  (`{type:'baseline', value:{items…}}`), and the dispatcher looked for
  `items` at the frame top level, so every baseline was mistaken for a
  `session/control` one and `dsh-emacs--workspaces` was never seeded.  The
  core stream's baseline is now unwrapped before routing, so sessions render
  under their workspace headers (and ungrouped sessions under "Ungrouped")
  against a real server (rationale: postmortem/009).
- **`session/list` now sends the wire `_request` parameter**: the dsh
  0.1.2-rc.1 `session/list` Remote method declares its single (usually empty)
  argument literally named `_request` — not `request` like the other session
  methods.  Sending `args: {}` made the server reject it
  (`missing "_request"`), so opening the session list failed with
  `gateway/arguments-invalid`; the list fetch now sends `args: {"_request": {}}`
  (rationale: postmortem/009).
- **WebSocket send no longer crashes on multibyte payloads**: client frames
  were encoded with `encode-coding-string … 'utf-8 t`, where the trailing `t`
  is `nocopy` — inside a unibyte process buffer a multibyte JSON payload came
  back still multibyte, so the mask loop's byte `aset` raised
  `Attempt to store non-ASCII char into multibyte string` and the chat/core
  stream died on connect.  Frames are now forced to a true unibyte UTF-8 byte
  string before masking, so opening any session / the session list against a
  real server works (rationale: postmortem/009).
- **Browser-session cookie is now actually minted (`dsh-emacs-server-auth-token`,
  self-started servers included)**: the token→cookie exchange requested
  `GET /?token=…` through `url-retrieve-synchronously`, which followed dsh's
  `303 `See Other`' redirect to `/` and returned that follow-on response — a
  `401` — so the `Set-Cookie` header on the first `303` was never seen and
  every RPC/WebSocket still came back `401`, surfacing as a Basic
  username/password prompt (dsh sends no `WWW-Authenticate`; Emacs' `url`
  library falls back to a `basic` challenge).  The exchange now reads the
  first response's headers directly: a raw TCP request for a plain-`http`
  base URL (redirect-follow is never performed), and `url-retrieve` with
  `url-max-redirections` bound to `0` for an `https` base — so the minted
  `dsh-auth-*` cookie is captured and sent, and the prompt no longer appears
  (rationale: postmortem/008).

## 0.2.0 - 2026-09-04

### Breaking Changes

- **Status bar renamed from "footer" to "mode-line"**: the customize group
  `dsh-emacs-footer` is now `dsh-emacs-modeline`, its options
  `dsh-emacs-footer-enabled` / `-format-spec` / `-branch-refresh-interval`
  became `dsh-emacs-modeline-*`, the commands `dsh-emacs-footer-toggle` /
  `-setup` / `-update` became `dsh-emacs-modeline-*`, and the seven footer
  faces became `dsh-emacs-modeline-*`.  No compatibility aliases are
  retained: the old footer names are gone, and saved customizations
  referencing them stop working until renamed to the new names
  (rationale: postmortem/007).
- **Manual context-window options removed**: `dsh-emacs-footer-context-window`
  and `dsh-emacs-footer-context-window-alist` are gone.  The ctx% segment is
  driven exclusively by the context window the server reports; saved
  customizations of the old options are silently dropped on upgrade
  (rationale: postmortem/005).
- **HTTP polling fallback removed**: `dsh-emacs-poll-fallback`,
  `dsh-emacs-poll-interval` and `dsh-emacs-poll-warn-delay` are gone.  The
  WebSocket event stream is the only automatic reply channel: if it is down,
  replies appear only once the stream recovers or via manual refresh
  (`C-c C-r`).  Saved customizations of the removed options are silently
  dropped on upgrade (rationale: postmortem/001).

### Added

- **Per-session input history option**: `dsh-emacs-input-history-cross-session`
  (default nil) chooses what `M-p` / `M-n` recall — only the current
  session's own prompts (per-session history, the new default) or the
  prompts from every session when set to `t`.  Prompts are recorded in both
  scopes regardless, so toggling the option never loses history; browse
  position and saved text are now per chat buffer, so recalling in one
  session no longer bleeds into another.
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
- **New sessions follow the detected project**: `dsh-emacs-new-session`
  outside any workspace context detects the Emacs project root of the
  working directory (project.el on Emacs 28+, falling back to the VC root,
  then a `.git` walk) and creates the session in the workspace registered
  for that root — resolved via idempotent `workspace.create` on first use,
  so every project's sessions group under one workspace.  Disable with
  `dsh-emacs-new-session-auto-project`; remote dsh servers are skipped
  (their workspace paths live on another host)
  (rationale: postmortem/006).
- **Image attachments are rendered inline** in the chat transcript.
- **Run-finished notifications**: when a submitted run ends while its chat
  buffer is not visible on the focused frame, a notification is posted
  (echo-area fallback); toggle with `dsh-emacs-enable-notifications`.
- **Interaction notifications**: an ask-question or approval request that
  arrives while its chat is not visible posts the same desktop
  notification (gated by `dsh-emacs-enable-notifications`), previewing
  the question or the tool call needing approval; replayed frames never
  re-notify.
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
- **Queue and steer while a turn runs**: `C-c C-c` no longer only
  interrupts a running turn — input is delivered per the new
  `dsh-emacs-busy-enter-behavior` option (`queue` default, `steer`, or
  `stop` for the old interrupt-only behavior): queued input runs as the
  next turn automatically, steering wakes the running agent before its
  next step, `C-u C-c C-c` flips queue and steer for one send, and with
  an empty input the turn is still interrupted.  Interrupting explicitly
  is `C-c C-b` (`dsh-emacs-interrupt-turn`).  The pending inbox mirrors
  the server's `session/queue` frames: a `[Q2 S1]` mode-line indicator
  (hidden when empty, mouse-1 opens the manager), transient echo-area
  feedback on enqueue (`queued: …`), steer (`steering: …`)
  and consumption (`running: …`), an input-prompt preview — a small
  clock icon (SVG, tinted with the prompt color) followed by the next
  message the host will send: after a steer the steered item leads the
  hint (in-flight `steering` items reach the running agent before any
  item queued for the next turn, so `next` follows that delivery
  order); our own steer/delete/edit
  RPCs apply to the mirror optimistically on success, so the hint and
  mode-line refresh the instant the call succeeds, without waiting for
  the confirming `session/queue` frame; prefix repaints are coalesced
  per frame burst, so an item the host splices and instantly claims
  never flashes the hint),
  and `C-c C-q` (`dsh-emacs-list-queue`) managing the queue from a
  minibuffer candidate list — vertico up/down highlights an item and the
  single keys act on it directly, with no numbered selection step (`e`
  edit, `s` steer, `d` delete, `RET` send now, `x` delete the whole
  queue after confirmation); one `C-g` cancels.  All wire names verified
  against
  the dsh 0.1.1-rc.2 RPC table (`session.prompt` `mode`, new
  `session.updateQueue`) (rationale: postmortem/003).

### Changed

- **`scripts/verify.sh` gates byte-compilation**: undefined functions or
  variables in the production `dsh-emacs*.el` files now fail the one-shot
  gate instead of being caught only by manual compilation; warnings stay
  allowed per AGENTS.md, and `.elc` artifacts are emitted to a temp dir so
  they never land in the tree.
- **`scripts/check-lisp.el` is diagnostics-only**: the auto-fixer was
  replaced by an ordered root-cause report (line / column / offset /
  context); repair procedure is documented in `AGENTS.md`.

### Fixed

- **`M-p` / `M-n` recall works on first entry of a session**: per-session
  history only held prompts submitted in the current Emacs run, so entering
  a session with earlier messages recalled nothing until it submitted
  something.  Loading a session's history now seeds its recall list from
  the transcript's user messages (skipping texts already present, so
  refresh/backfill never duplicate), and the shared cross-session list is
  untouched.
- **Mode-line running animation always stops at `turn/end`**: the spinner
  could keep animating after a turn had finished — a fast run (a very short
  reply, or a model immediately rejected, e.g. quota/rate) could start and
  end on the event stream *before* the `session.prompt` HTTP callback ran,
  and the callback then re-lit the spinner with no matching `turn/end` left
  to extinguish it.  The callback now lights the spinner only while the
  submitted run is still awaited, so an already-finished turn stays dark.
- **Collapsed blocks no longer crash when a new chunk arrives**: appending
  into a folded fragment (a tool card kept collapsed while more output
  streams in) used to signal `void-variable old-body` — the hidden-count
  update bound `old-count` from `old-body` inside the same `let`, and Emacs
  evaluates `let` bindings in parallel, so the reference hit an unbound
  variable and the render path died.  The bindings now use `let*`.
- **New sessions follow the directory you invoke them from**: the session's
  working directory now comes from the current buffer's `default-directory`
  (a dired buffer's browsed directory, magit's repo root, a file's
  directory) instead of the fixed `dsh-emacs-default-cwd`, so the project
  auto-detection sees the very project you are in — starting a session from
  a dired buffer at a git repo now lands it in that repo's workspace,
  created on first use, rather than in the Ungrouped bucket under the
  startup directory.  `dsh-emacs-default-cwd` remains the fallback when no
  buffer directory context exists
  (rationale: postmortem/006).
- **Cursor no longer gets stuck under the input line**: the cursor could
  drift below the `❯` input line (often after a split window or a stream
  redraw), refuse to move back, while the typed text stayed on the input
  line — only a session refresh/reopen cleared it.  `dsh-emacs--input-end`
  used to fall back to `point-max` when the structural mode-line overlay
  was torn, treating the phantom display line *beneath* the input as the
  end of the editable region, which made the cursor clamp a no-op.  It now
  mirrors the separator-newline case so the clamp still pulls the cursor
  up onto the input line, and the stream-following window logic no longer
  parks a followed window's point on that phantom line.
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
  malformed base URL) is contained — the reconnect is re-armed and another
  connect scheduled instead of leaving the chat with no recovery channel.
- **Opening a session stays lightweight on big/far sessions**: while the
  initial history is loading, the mux replay is dropped outright — the
  load gap is covered by the bounded re-fetch, and replaying old delta
  chunks would otherwise re-impose the "replay old deltas" cost the
  snapshot-first page render was designed to avoid.
- **Cursor never rests on the input prompt**: the read-only stretch on the
  input line before the `❯ ' prompt is now a no-park zone — `C-a` in the
  input or a stray click lands the cursor at the edit start after the
  prompt instead of on the icon.  A repaired input marker is likewise
  anchored on the actual `❯ ' glyph (scanning the prompt line instead of
  skipping a fixed two characters), so the edit start tracks the real
  prompt even when the prompt's face run starts further left.
- **A stream reconnect no longer doubles the transcript**: the mux replays
  the whole global event stream to every new connection — including
  mid-session reconnects — and the live dispatch path now drops replayed
  frames whose seq is already within `dsh-emacs--anchor-seq` (the same
  gate history and watchdog re-fetches already used).  Previously a
  reconnect repainted every already-rendered event: the user message and
  the agent reply each appeared twice with the layout interleaved and
  garbled until the session was reopened (rationale: postmortem/004).
- **A fast second submit can no longer double-send**: the plain send path
  (`C-c C-c` while idle) now clears the input at submit time, exactly like
  the queue/steer and slash-command paths, so pressing the key again
  before the server answers reads an empty input instead of sending the
  same message twice.  A transport failure restores the draft when the
  input is still empty (a newer draft typed meanwhile is left alone), and
  a successful send never wipes text typed during the round-trip.
- **Sending with an empty queue no longer flashes through the queue**: the
  wire accepts only `queue`/`steer` prompt modes, so every send — idle, or
  behind a running turn with nothing else pending — is spliced into the
  host inbox and claimed when the turn starts, and the `session/queue`
  mirror diffed those two frames into `queued:` / `running:` echo flashes.
  Submitting with an empty mirror now suppresses that transient feedback,
  including the input-line `[next: …]` preview (the preview would paint
  and clear within milliseconds — the "flash" at the prompt) — the message
  is rendered directly in the transcript, as before — while genuine
  queueing (items already parked) keeps its flashes, `[next: …]` preview
  and mode-line count (rationale: postmortem/004).
- **A parked message's preview appears right away instead of after ~2s**:
  the suppression arm stayed up for a defensive 2s window, so a message
  genuinely queued behind a running turn surfaced in the `[next: …]`
  preview only when that timer fired.  Revealing the parked preview is
  now event-driven, not timed: while a turn is running an item in the
  mirror can only be claimed at the turn end, so the preview shows it
  immediately regardless of the arm — the millisecond self-submit
  transient (turn idle) stays invisible as before
  (refines postmortem/004).

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
