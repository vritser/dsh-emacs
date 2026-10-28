# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Unreleased
sections carry the planned next version (pre-1.0: `fix` → patch, features →
minor) and stay undated until the release is cut.

## 0.8.0 - Unreleased

### Added

- **Choose transcript event icons**: `dsh-emacs-render-style` defaults to
  `full` (dsh-web SVG icons) and offers `simple`, where every event row leads
  with one state-colored dot and the rest of the row uses the muted
  `dsh-emacs-event-row-face`. The Think title is muted; its live dot keeps the
  thinking accent and settles to grey when the fragment completes. Emoji
  fallbacks are removed: on displays that cannot draw SVG, `full` uses one dot
  for ordinary tool rows while goal tools and the Think, todo and turn-trigger
  rows keep their text glyphs. Composer pause/clear and queued-message delete
  use `||` and `✕` when Emacs cannot draw SVG; typed emoji still render.
  (rationale: [postmortem/161](postmortem/161-event-icon-style.md))

- **Hide Recents while filtering workspaces**: `w` shows only the selected
  workspace; clearing the filter restores Recents. (rationale: [postmortem/158](postmortem/158-filter-hides-recents.md))

- **Choose the session-list jump target**: `dsh-emacs-session-jump-target`
  makes chat-to-list navigation (`C-c C-l` or `M-x dsh-emacs`) prefer `recents`
  by default, falling back to the canonical workspace or `Ungrouped` session
  row when absent, or always select that canonical row with `workspace`.
  Explicit project-root workspace navigation and point-preserving refreshes
  are unchanged. (rationale: [postmortem/157](postmortem/157-session-jump-target.md))

- **Recents at the top of the session list**: an initially expanded group
  shows the 15 most recently updated visible sessions across workspaces,
  while retaining their original workspace rows. Set
  `dsh-emacs-session-recents-limit` to change the count or use zero to hide
  it. Workspace filtering, group folding and session commands also work in
  Recents. (rationale: postmortem/154)

### Fixed

- **Session list honours `dsh-emacs-server-auto-start'**: opening a cold
  session list now refuses with startup instructions when the option is nil
  and the server is unreachable, instead of offering to install the CLI or
  launching a local server behind the user's back.  An explicit
  `M-x dsh-emacs-server-start` is unchanged.

- **Attribute subagent- and event-driven turns**: a host-injected notice that
  the inbox claim wakes (a child `send_message`, a settled subagent, or a
  team, webhook, schedule, job or plugin event) now renders dsh web's
  collapsed turn-trigger row above the turn's **Completed in …** summary
  instead of disappearing. The row names its source, folds the recorded body
  behind RET and stays visible when the turn folds; the idle step-1 case is
  recognized too, so child-driven turns no longer read as unprompted replies.
  Mid-turn, canceled and requeued injections stay hidden.
  (rationale: [postmortem/159](postmortem/159-turn-trigger-notices.md))

- **History rounds follow user+assistant**: `C-c C-o` counts and starts a
  loaded page at a turn with a user-authored message, so a child- or
  goal-woken turn is loaded with the human round it belongs to instead of
  topping the range as an orphan trigger and answer.  Opening a snapshot that
  starts on such a turn backs up to the preceding user prompt.
  (rationale: [postmortem/160](postmortem/160-history-human-rounds.md))

- **Older-history exhaustion at the start**: pressing `C-c C-o` when only
  non-round seed records remain now reports "Beginning of history" instead of
  claiming to load history events with no round boundaries.

- **Live session activity ordering**: sending a message now updates the
  session's cached activity time, so Recents and workspace rows reorder
  immediately. Activity received during a list refresh survives its snapshot,
  and older events cannot roll back newer timestamps. (rationale: postmortem/154)

- **Readable RPC errors**: failed requests now report the server's message and
  error code instead of the raw error alist. A fork refused because the source
  session's preset no longer exists also lists the presets the server provides.

- **Drafts survive a missing preset**: when `session/create` reports
  `agent-preset/not-found` or `agent-preset/invalid`, the draft keeps its text
  and retries once without the preset, continuing under the host default,
  including when `dsh-emacs-default-preset` names a preset the server no
  longer has. (rationale: postmortem/156)

### Changed

- **Preset picker uses server labels**: new-session preset choices show a
  preset's published `name` and fall back to its id. The client-side English
  names for the shipped presets (`Standard mode` …), which the server does not
  publish, are removed, so those choices read `standard`, `minimal`, `ptc` and
  `cordis`. Choices that would render identically append the preset id. When
  the roster is not cached yet, the picker ensures the server is ready and
  fetches it before prompting; a failed fetch reports an error instead of
  creating the session with an unchosen preset. (rationale: postmortem/155)

## 0.7.0 - 2026-10-23

Compatible with **dsh 0.2.1-rc.2**, the latest upstream release as of
2026-10-18 (npm `next`; npm `latest` still points to 0.2.0-rc.2).
The minimum supported Emacs version is now **28.1**.

### Breaking Changes

- **Remove unused Lisp helper APIs**: `dsh-emacs-modeline-set-cwd`,
  `dsh-emacs-modeline-set-branch`, `dsh-emacs-modeline-teardown` and
  `dsh-emacs-usage-p` are removed without aliases. External callers must
  remove these calls; mode-line cwd and branch use the chat's
  `default-directory` and cached Git detection, not separate overrides.
  Chat commands and keybindings are unchanged. (rationale: postmortem/138)

- **Emacs 28.1 is now the minimum**: 27.1 support is removed. The code
  already relied on 28.1 APIs (`setf` on `plist-get`, `ensure-list`),
  and CI now runs the gate on 28.1 and a current stable release.
  (rationale: postmortem/136)
- **Remove inactive transcript options**: `dsh-emacs-group-consecutive-tools`
  and `dsh-emacs-assistant-divider` are removed without compatibility aliases.
  Neither affected the transcript: tool cards continue to fold independently,
  and assistant bodies retain their existing spacing. Remove these settings
  from personal configuration. (rationale: postmortem/122)

### Added

- **Open sessions with complete rounds**: fresh chat buffers complete the
  latest round, fetching extra bounded pages for a long round without moving
  the draft cursor or delaying live output; `C-c C-o` cancels the pending
  history load and loads earlier rounds. Switching back to an already-open
  chat remains unchanged. (rationale: postmortem/148, postmortem/152)
- **Web-style task and activity disclosures**: settled thinking and tool
  cards fold into independent summaries between visible replies. Successful
  turns without mid-turn input also fold their whole process under a muted
  **Completed in …** row, leaving any final answer visible. Missing timestamps
  yield **Completed**; a loaded tail can fold without the task start. `RET`
  toggles each disclosure independently, and narrow rows remain truncated.
  Set `dsh-emacs-fold-work-details` to `nil` and reopen the chat for a flat
  transcript. (rationale: postmortem/142, postmortem/149)
- **Pulsing running-subagent icon and count**: while the connection is live
  and at least one direct child is running, the mode-line subagent icon and
  child count pulse together between their muted tint and the running orange
  instead of adding a separate spinner. The pulse is a motion-line clip in the
  `dsh-subagents` slot; without motion-line or SVG they keep their static
  tint. It stops when the last child settles or the connection drops. The
  tooltip and mouse-1 picker are unchanged.

### Changed

- **Web-style image gallery for message attachments**: every image attachment
  now shows as a compact thumbnail in wrapping rows below the text instead of
  one full-width picture per line, mirroring dsh web's message gallery — a
  lone image uses the same style as a multi-image gallery. Inline bytes show
  immediately, attachment refs fill in when the fetch settles, and `RET` or
  `mouse-1` opens the original. The new
  `dsh-emacs-render-image-thumbnail-lines` option sets the height in text
  lines. (rationale: postmortem/151)
- **Clearer conversation grouping**: left-aligned user messages use a
  three-pixel teal rail instead of a full-width highlight, with a wider gap
  after the rail, light top/bottom padding and one blank line before each
  question to keep turns distinct without excessive space above the rail.
  Completed summaries leave a small gap above answers without a divider;
  theme font sizes stay unchanged, and summary/footer text uses the muted
  reply face at normal weight. Footers default to Copy, Fork
  and tokens together on the left, in configured order; `duration` remains
  available in `dsh-emacs-reply-footer-items`.
  (rationale: postmortem/145)

- **Next Message above the Goal Row**: the queued-message preview now leads the
  composer chrome, with the active goal row beneath it. Faces, actions and the
  `C-c C-g` / `C-c C-q` keys are unchanged.

### Fixed

- **Skip formatting folded tool details**: live and replayed tool cards now
  prepare their terminal, read, diff and generic result bodies only when
  expanded. Repeated expansion reuses the formatted body; a new result or
  width change refreshes it, and expanded cards still update immediately.
  (rationale: postmortem/153)
- **Keep links looking like links**: a link label authored as inline code,
  bold, italic or strikethrough keeps the link's own colour and underline;
  the label's styling still applies underneath instead of overriding the
  link. Backticked labels no longer render as plain inline code.
- **Keep Markdown file destinations intact**: emphasis and inline code no
  longer rewrite characters in link/image targets, including incomplete
  streamed destinations. Balanced or escaped parentheses and optional titles
  resolve correctly; rendered labels cannot become a second link target.
  Linked images open the enclosing link. (rationale: postmortem/150)
- **Resolve local Markdown paths consistently**: links and images decode URI
  escapes once, support workspace-relative targets and retain the rendering
  directory for later clicks. File links accept one-based line/column
  positions. Invalid or missing local targets no longer launch a browser;
  remote file authorities and unsafe schemes are rejected.
- **Wait for complete bare image paths**: a partial streamed filename does
  not acquire a stale image or click target before its newline/final boundary.
  Literal path characters are kept distinct from Markdown URL escapes.
- **Keep multi-backtick inline code literal**: matching backtick runs protect
  embedded image/link syntax and literal backticks instead of rendering them.
  Unmatched openers retain line-local streaming protection.
- **Render bracketed local image destinations**: `![alt](<path>)` displays
  supported local images instead of leaving raw Markdown, including paths
  containing spaces or parentheses. Images inside inline or fenced code remain
  literal; missing files and non-graphical displays retain their markup.
- **Switch to already-open sessions without rebuilding**: opening a session
  that is already open — from the session list, `M-x dsh-emacs-switch-session`
  or an `@` reference — selects its live chat buffer without clearing the
  transcript, draft or cursor position, or restarting its event stream.
  Killed chat buffers still initialize normally when opened again, and
  `C-c C-r` (`dsh-emacs-refresh`) remains the explicit resync. (rationale:
  postmortem/147)
- **Keep user-message spacing during streaming**: the first live reply or
  reasoning chunk preserves the blank line below the question, matching
  history rendering; subsequent chunks keep the same gap.
- **Copy user-message text cleanly**: copy-line and region copies no longer
  include a hidden prompt; yanking them also drops transcript styling and
  identity properties. Authored `❯` characters remain intact, including in
  Imenu labels. (rationale: postmortem/146)
- **Keep C-a on the user-message line**: navigating to the first line's
  beginning reaches its first authored character instead of jumping to the
  preceding blank line.
- **Keep automatic compaction inside activity groups**: a compaction summary
  no longer splits adjacent tools into separate disclosures. It folds with the
  activity and remains inspectable after expansion, but contributes no tool
  category count. Summaries now rank the combined calls on both sides, matching
  Web. Live compaction and standalone failure rows are unchanged.
  (rationale: postmortem/149)
- **Match Web's stopped and interleaved turns**: **Failed** and **Stopped**
  status rows no longer hide the whole process. Mid-turn input also keeps the
  outer turn open. Replies remain visible while internal activities still
  fold independently, with Web's category-ranked summaries. Successful turns
  can fold without a final answer; empty processes show a non-foldable status
  row. This supersedes the earlier stopped-turn and disjoint-span approaches.
  (rationale: postmortem/149)
- **Avoid flashing expanded work while opening history**: history snapshots
  and older pages redraw only after their reply footers and task folds are
  reconciled. Completed work first appears collapsed; live replies retain
  their incremental rendering.
- **Prevent duplicate replies during history replay**: reentrant WebSocket
  reads queue behind the active snapshot consumer instead of parsing the
  same snapshot again. Thinking, tools and final answers no longer appear
  twice around the reply footer; queued and partial frames retain wire order.
  (rationale: postmortem/142)
- **Use the renamed PTC preset**: the new-session picker resolves PTC mode to
  `ptc` rather than `code`, including before the server roster arrives. Update
  any `dsh-emacs-default-preset` setting from `"code"` to `"ptc"`.
- **Keep streaming output clear of the input highlight**: with local or global
  `hl-line-mode`, new thinking, tool and answer rows no longer acquire the
  input line's background while waiting for the next keyboard command.
- **Match header separator colors**: minimal-card separator dots use the
  adjacent right label's face, matching the goal notice timestamp.
- **Separate the goal trigger icon from its label**: the collapsed
  `Continuing goal` notice now has a visible gap after the SVG dartboard.
- **Keep each chat window's draft cursor while following output**: background
  windows no longer jump to the start of input during streaming. Each window
  follows at its own draft position, including long multiline drafts whose
  prompt has scrolled out of view; history-reading windows remain untouched.
- **Restore the native DSH mode label**: native mode lines always show plain
  `DSH` instead of a static whale in the major-mode name. The separate active
  whale-tail animation, caption and elapsed time stay together; without Motion
  Line, only the static activity caption appears. Doom's static whale, layout
  and the native major-mode menu are unchanged.
- **Open file links with line ranges locally**: assistant links such as
  `source.el#L10-L20`, `source.el#L10-20` and `source.el:10-20` now open
  in Emacs at the first line instead of falling back to a browser. This also
  fixes function-name labels whose link targets contain line ranges.
- **Keep the model indicator in sync**: modelSelection updates from the live
  control stream and follow snapshots now update both the session cache and
  model/provider/effort segments, including switches made in another client.
  Older list responses and history rendering no longer undo a model update
  delivered during them. (rationale: postmortem/141)
- **Keep requests independent of JSON customization**: RPC and WebSocket
  requests retain their required booleans, nulls, arrays and empty objects
  even when user json.el encoding settings differ. (rationale: postmortem/140)
- **Keep running status across manual refresh**: `C-c C-r` preserves busy
  while reconnecting, even when the snapshot omits the original turn start;
  a completed turn is not revived by a stale session-list running flag.
- **Keep chat startup quiet**: mode-line setup no longer prints internal
  integration flags each time a chat opens. (rationale: postmortem/138)
- **Reorder multilingual session lists safely**: workspace regrouping no longer
  triggers the Emacs transposition crash or corrupts multibyte row text;
  navigation markers stay attached to their sessions. (rationale: postmortem/137)
- **Show goal objectives in the help buffer on Emacs 28**: opening goal details
  no longer inserts the objective into the chat buffer or omits it from help.
- **Keep unchanged cards untouched on Emacs 28**: streaming outside a card no
  longer causes its equivalent snapshot properties to be rewritten.
- **Keep chat events working without D-Bus**: desktop notifications use the
  existing fallback when Emacs lacks D-Bus support, so turn completion and
  question prompts are no longer interrupted on affected Emacs 28 builds.
- **Keep idle session indicators muted**: idle dots and muted text inherit
  `shadow`, so the default Emacs theme shows them in grey instead of the
  red comment color. Running indicators remain orange.
- **Answer a question or approval whose prompt cannot open**: when the reader
  signals (for example while another minibuffer owns the prompt), the client
  now declines the question or rejects the approval instead of leaving the
  host waiting for an outcome.

## 0.6.1 - 2026-10-18

Compatible with **dsh 0.2.1-rc.2**, the latest upstream release as of
2026-10-18 (npm `next`; npm `latest` still points to 0.2.0-rc.2).
The minimum supported Emacs version remains **27.1**.

### Changed

- **Show retry outcomes once, in the transcript**: remove the mode-line
  Retry/Retrying label and its status details. Compact attempt cards now
  distinguish scheduled/started retries, failed replies and cancellation,
  using the same styling as tool and automatic-compaction rows. Partial
  output stays expandable, and failure details appear on hover. Model errors
  and automatic compaction failures share a compact status-dot layout with
  retry/cancellation cards: orange for retry, red for failure, grey for
  cancellation or unknown outcomes. Model error codes appear as muted
  metadata, with the reason expanded. Recovery retries without an explicit
  retry event show **Retried** when a later response confirms recovery in the
  same step. Outcome caches are released with trimmed transcript content.
  (rationale: postmortem/121)

### Fixed

- **Accept server-assigned session IDs**: dsh 0.2.1 can replace a requested
  session candidate. Draft activation uses the returned ID and preserves it
  for retries after an activation failure, together with the draft text.
- **Keep migration hints out of projection state**: migration-required reads
  report an explicit error instead of marking the subagent catalog ready or
  installing cached hints as sequenced cells.
- **Guard external subagents**: catalog entries without a local conversation
  no longer trigger child projection reads or attempt to open a local chat;
  interrupt remains limited to local continuable children.

## 0.6.0 - 2026-10-17

### Breaking Changes

- **Remove the mode-line queue indicator**: pending input stays in the
  Composer Next Message preview and `C-c C-q` manager. The duplicate
  `[Qn Sm]` count, its mouse shortcut and public
  `dsh-emacs-modeline-queue-face` are removed without compatibility aliases.
  Queue/steer behavior, manager counts and the Composer queue color settings
  remain unchanged. (rationale: postmortem/114)

- **Remove unused composer background settings**: `dsh-emacs-input-box-face`,
  `dsh-emacs-color-input-bg` and `dsh-emacs-color-input-bg-dark` are removed;
  composer rows now use the buffer background. (rationale: postmortem/103)

- **Stage files before sending**: `C-c C-a` now adds one file to the existing
  attachment list; repeat to add more. Drag-and-drop keeps its confirmation
  and stages valid files in order. Neither sends immediately or prompts for
  a caption. `C-c C-c` sends the staged set with the current input (the
  staged file names when blank); `C-c C-d` clears all. Lisp callers now use
  `(dsh-emacs-attach-file file)`; the caption argument is removed.
  (rationale: postmortem/094)

- **Remove the mode-line job indicator**: job status stays in the tool rows;
  the duplicate `[Jn]` count and its mouse shortcut are removed, along with
  `dsh-emacs-jobs-modeline-face` and `dsh-emacs-jobs-map`. Use `C-c C-j` to
  view output or stop background jobs. (rationale: postmortem/088)

### Added

- **Keep automatic compaction summaries as compact tool rows**: the folded
  summary uses the existing terminal/tool icon and tool-title face, without
  extra blank padding. Counts stay muted and the Markdown body stays folded
  by default. The row remains neutral: it does not claim checkpoint success
  or replace later failure cards, manual `/compact` output or mode-line
  activity. (rationale: postmortem/116)

- **Reload local package source without resetting chats**: `M-x dsh-emacs-reload`
  preflights every local module and loads `.el` source in dependency order,
  bypassing stale bytecode. Drafts, attachments, settings, connections and
  timers stay live; Composer, session-list and mode-line presentation refresh.
  Package keymap defaults replace ad-hoc edits; face defaults refresh beneath
  custom overrides. Active readers, session creation and history loads block
  reload. Existing transcript text and callbacks are not recreated; removed
  definitions and structural changes still require a restart. Evaluation
  errors may leave a partial reload. (rationale: postmortem/115)

- **Start typing while a session is created**: new-session commands open an
  editable draft immediately, then connect it in place when the host responds.
  Creation runs without a header banner; only failures show a header message.
  Text and cursor survive the transition, and late responses do not steal focus.
  Failures retain the draft; `C-c C-c` retries the same session without sending.
  Workspace creation failures now remain available for retry instead of silently
  creating an ungrouped session. (rationale: postmortem/111)

- **Load history by complete rounds**: `C-c C-o` loads 3 earlier rounds;
  a numeric prefix selects the count. Long rounds are fetched across bounded
  batches; the loaded round range appears only in the completion message. Press
  the same key again to cancel. Other windows and readers who moved while
  waiting keep their positions. `C-c >` returns to the draft and resumes
  following, and the question directory (`M-x imenu`) refreshes as pages load.
  (rationale: postmortem/110)

- **Inspect render work offline**: `scripts/render-report.el` reports fragment
  reconstruction, session row visits, character edits and requested property
  writes, with separate uninstrumented timing samples. It runs on synthetic
  buffers and adds no normal-session instrumentation.
  (rationale: postmortem/105)

- **Follow automatic compaction**: a folded **Automatic compaction** row
  shows the generated summary, covered item count and approximate old-context
  token count while preserving the original conversation. During compaction,
  the mode line uses a teal `Compacting` caption with the existing whale,
  gentle sweep and its own elapsed clock when Motion Line is installed,
  including between turns. Without Motion Line the caption is static.
  (rationale: postmortem/104)

- **Customize the pending-input queue color**: `dsh-emacs-color-queue` and
  `dsh-emacs-color-queue-dark` own the amber of the Composer Next Message
  row's queue glyph. (rationale: postmortem/101, postmortem/114)

- **See what each goal tool did**: `create_goal`, `get_goal` and `update_goal`
  rows now show dsh web's goal card — the goal icon, a `Create goal` /
  `View goal` / `Update goal` title and the objective as the summary, with
  Status, Rounds and (while blocked) the blocker text in the expanded body,
  instead of a raw IN/OUT JSON dump. A cleared `get_goal` reads `No goal`; a
  failed call keeps the generic card with its status line.
  (rationale: postmortem/100)

- **See goal rounds in the transcript**: when a goal continues on its own, the
  chat now shows dsh web's **Continuing goal** notice — goal icon, label and
  event time, folded by default — instead of staying silent. RET or a click on
  the notice expands the injected `<goal_round>` prompt. Other host-injected
  messages stay hidden and are still never offered to `M-p` recall.
  (rationale: postmortem/099)

- **Show running status in the mode line**: with the optional
  `motion-line` package, native and Doom mode lines show a 60-frame,
  three-second whale-tail loop beside `Deep diving` and a seconds/minutes
  elapsed clock. Graphical displays add a gentle foreground sweep to the
  caption. The tail follows the logo color in a centered 18×18 display box;
  GIF frames clear between poses without trails. Doom animates its existing
  tail without duplicating it. Terminals and displays without GIF support
  use cycling `DSH...` text in place of the animated tail.
  Without Motion Line, the client shows static `Deep diving` text and creates
  no animation timer. Completion, disconnects and buffer cleanup clear the
  running status and release playback. (rationale: postmortem/095,
  postmortem/096)

- **Attach any file to a prompt**: `C-c C-a` (`dsh-emacs-attach-file`) and a
  drag-and-drop onto a chat buffer now take any readable file, not only images.
  An image still travels inline as an image; every other file is uploaded to
  the host when the prompt is submitted (`POST /api/session/uploadFileBinary`)
  and reaches the model as a file attachment, shown in the transcript as a
  display-only `[file: name · size]` line. `dsh-emacs-attach-max-file-size`
  (32 MiB) caps an uploaded file; a failed upload restores the draft and sends
  nothing. Session attachments are never recorded for `M-p` recall.
  (rationale: postmortem/092)

- **Switch reasoning effort directly**: `C-c C-e`
  (`dsh-emacs-select-effort`) changes the running model's reasoning effort
  without re-picking the model — it reads the session's live selection,
  pre-selects the current effort and sends `session/selectModel`. A model
  without reasoning-effort options reports that and sends nothing.
  (rationale: postmortem/091)

- **Locate the current project's workspace**: `M-x dsh-emacs` from a local
  project file or directory expands its existing workspace and centers the
  header in the selected window when space permits, including when workspace
  data arrives after opening. A user command in the list cancels pending
  navigation. Chat buffers retain active-session navigation.
  (rationale: postmortem/089, postmortem/090)

- **Configurable reply footer**: completed turns show Copy, Fork, per-turn
  token usage and elapsed time below their last reply, separated by a blank
  line. Customize
  `dsh-emacs-reply-footer-items` to reorder or hide items, or disable the row.
  Copy preserves Markdown; partial history and unavailable statistics are
  marked explicitly. (rationale: postmortem/084)

- **Branch from a reply**: `C-c C-y` (`dsh-emacs-fork-message-at-point`)
  opens a new conversation inheriting history through the assistant reply
  at point, including replies loaded from older history. Streaming replies
  become selectable once committed; session-list `f` still branches through
  the latest completed turn. (rationale: postmortem/083)

- **Add providers from the minibuffer**: `M-x dsh-emacs-add-provider` sets up
  a pi-ai catalog provider or custom API endpoint through ordinary completion
  and password prompts. Settings and API keys are saved separately on the
  connected server; existing providers can update their endpoint/key without
  replacing other settings. (rationale: postmortem/080)

- **Edit dsh configuration in Emacs**: `M-x dsh-emacs-edit-config` opens a
  user-chosen existing configuration file, including explicit TRAMP paths,
  for ordinary editing and saving. Choices are remembered per server URL
  during the Emacs session; a prefix argument chooses again.
  (rationale: postmortem/079)

- **Theme-aware whale icons**: graphical Emacs with SVG support shows a
  whale in the native mode label. Doom Modeline places the full whale before
  the buffer name and a whale tail in the major-mode slot, retaining its
  standard menu. Icons are blue on dark themes and black on light themes,
  and follow theme changes. Displays without SVG support use `DSH` text.

- **Browse and continue subagent conversations**: `M-x dsh-emacs-list-subagents`
  selects direct children through minibuffer completion, while `TAB` in the
  session list expands nested children. Arrows appear only for confirmed
  children; missing catalogs load on demand. Large lists retain responsive
  folding, cursor position and return navigation through refreshes and regrouping.
  `RET` opens a child and `M-,` returns, with history paging and cumulative
  usage available. Continuable children accept queue/steer input through their
  live direct parent and can be stopped; one-shot records and unavailable-parent
  input stay read-only. The mode line shows a muted brain-and-circuit child count
  (Nerd Font / `Sub` fallback), with running counts in the tooltip. Child lineage
  remains visible.
  (rationale: postmortem/075, postmortem/076, postmortem/077, postmortem/078)

- **Approval reasons follow your language**: dsh 0.2.0 approval prompts use
  the host's localized reason, following the Emacs message locale by default.
  `dsh-emacs-approval-language` selects a language explicitly; missing
  translations fall back to English and then the original reason.
  (rationale: postmortem/074)
- **Timed questions stay answerable**: when a dsh 0.2.0 `ask_user_question`
  foreground window expires before an answer, the question is no longer lost.
  Its transcript row reads `pending` and explains itself, and `M-x
  dsh-emacs-answer-question` (`C-c C-p`) answers it through the host's
  `userQuestions` API with the ordinary minibuffer reader. While a timed
  question is being answered the client holds the host's foreground wait, so
  the window cannot expire out from under the prompt, and a late answer
  completes the original card. Requires dsh 0.2.0; on 0.1.7 the blocking
  question flow is unchanged. (rationale: postmortem/073)
- **Read plans before approving them**: submitted plans open as Markdown
  documents with **Approve and execute** and **Request changes** actions.
  Requesting changes returns to chat to write feedback; closing the document
  leaves review pending. Titled transcript cards reopen previous plans, and
  `M-x dsh-emacs-plan-review` reopens the current pending review. Disconnected
  or cancelled requests lose their approval actions, and a review the document
  interface cannot present reports the fallback instead of silently using the
  question reader. (rationale: postmortem/072)
- **Plan mode is visible across turns**: the mode line shows `Plan` when
  active, `Plan → on` while entry is pending, and `Plan → off` while exit is
  pending. Hover, click or `M-x dsh-emacs-describe-status` explains the
  current state and requested change. The host's `plan` projection drives the
  badge; reconnect snapshots restore it without overwriting newer updates.
  Use the existing `/plan` and `/plan off` commands to switch.
  (rationale: postmortem/071)
- **Execution waits have visible status**: the mode line shows `Retry n/m`
  while waiting, `Retrying n/m` once the request starts, and `Compacting`
  during context compaction, including between turns. Hover, click or run
  `M-x dsh-emacs-describe-status` for the provider, scheduled wait and
  failure reason. Status clears on disconnect and rebuilds from retained
  events on reconnect; automatic compaction failures remain in the transcript.
  (rationale: postmortem/070)
- **Background jobs are visible and controllable**: while a session can see
  running work — a bash command the model left in the background, a subagent
  delegation, a workflow — `C-c C-j` opens the
  roster as a picker: `RET` shows a job's retained output in a read-only
  buffer, `k` stops it (two presses within 3s; see
  `dsh-emacs-jobs-kill-arm-seconds`), `r` re-subscribes.  dsh 0.1.7 removed
  the `session/control` `jobs` record this state used to ride in, so the client
  previously showed nothing at all; it now subscribes to the `job` namespace's
  own `job/list` and `job/follow` streams over the chat connection.  A stop is
  recorded as `cancelled by the user`, and the owning agent still receives its
  completion notice.  (rationale: postmortem/065)
- **Host skills are discoverable and invocable**: the `/` completion and the
  `M-x dsh-emacs-command` slash menu now list the session's skills beside its
  slash commands (a user-only skill, one the model may not load itself, is
  marked `user-only`).  Picking a skill inserts the `/name ` gesture at the
  cursor — `C-u` opens the picked skill's `SKILL.md` instead, while commands in
  the same menu still run.  Invocation has no RPC of its own: the host expands a
  `/name` gesture found in the prompt text, so the gesture is sent like
  ordinary input.  The catalog is read from `skills.list`, prefetched per
  session (`dsh-emacs-skill-prefetch`, `dsh-emacs-skill-prefetch-delay`) and
  re-read on demand with `M-x dsh-emacs-skill-catalog-refresh`.
  (rationale: postmortem/067)
- **Slash gestures are accented in the transcript**: a `/name` token you sent is
  colored when the session's catalogs confirm it — a host slash command as a
  blue bordered chip, a skill as violet text with no border (dsh web
  distinguishes the same two) — with the description on hover, so the
  transcript shows what the host will act on.  Classification is
  catalog-confirmed, not shape-alone: `/usr/bin`, `5/8`, `http://…` and unknown
  names stay plain.  A replayed message that rendered before its catalog was
  fetched is accented retroactively from the host's own skill-invocation
  evidence.  (rationale: postmortem/068)
- **`/name` completion works mid-sentence**: the `/` completion and the slash
  menu now handle the token the host's gesture grammar accepts anywhere — at
  the start of the message or after whitespace — so `please /rev` + `TAB`
  becomes `please /review `, and picking a skill from `M-x dsh-emacs-command`
  replaces the token being typed instead of appending to it.  Mid-sentence the
  token goes to command completion only when a command or skill actually
  matches it, so prose and paths (`see /usr/…`) keep path and word completion;
  at the input start a `/name` stays with command completion even when the
  catalog is empty.  (rationale: postmortem/069)
- **The `/` list matches a word inside a long name**: the `/` completion
  category defaults to prefix matching plus the built-in `flex` style
  (registered in `completion-category-defaults`, the same place `@`
  references get theirs), so `/probe` finds `dsh-emacs-skill-probe`.  Prefix
  matching runs first, so an ambiguous prefix (`/p`) or a bare `/` still lists
  its candidates instead of completing; your own `completion-styles` apply
  after those defaults, `completion-category-overrides` replaces them, and
  every other completion in the buffer is untouched.  (rationale:
  postmortem/069)

### Changed

- **Use a consistent chat buffer prefix**: titled chats are named
  `dsh: <title>` instead of `dsh-<title>`, and subagent chats use
  `dsh: <parent title>/<label>`. The session-ID fallback is unchanged.

- **Decode large session lists faster**: HTTP responses and event-stream frames
  use native JSON parsing when available, reducing client-side work on first
  open. Builds without native JSON keep the Lisp reader.
  (rationale: postmortem/112)

- **Faster Markdown rendering with less garbage collection**: code blocks
  set up each language's major mode once and reuse it, table rows are
  assembled without repeated string copies, and streamed flushes no longer
  rebuild the image-path regexp. Rendered text and faces are unchanged; in a
  GUI test with default GC settings, a 10 KB reply rendered about 22% faster
  and a streamed 3 KB reply took 40–50% less time. (rationale: postmortem/108)

- **Reuse unchanged session row layouts**: repeated list refreshes reuse title
  padding and styling while keeping status, relative time, child activity and
  navigation targets current. Hidden and removed rows leave the cache.
  (rationale: postmortem/106)

- **Act on the next message from its own row**: the pending-input preview is
  followed by a compact cluster — dsh web's up arrow, edit and trash, one space
  apart. RET or a click sends that message now (steering it into the running
  turn, or re-submitting text-only items while idle), rewrites its text in the minibuffer,
  or deletes it; each cell runs the same queue verb `C-c C-q` binds to
  `s`/`e`/`d`. Edit appears only for a message whose content is all text, since
  the edit RPC answers with text blocks and would otherwise flatten an
  attachment. The cells are muted like the Goal Row's actions, name themselves
  in tooltips, and a window that runs out of room drops them from the tail
  (delete, then edit, then the arrow). (rationale: postmortem/101)

- **Next Message matches the Goal Row's anatomy**: the pending-input preview no
  longer paints its whole line in the `❯` prompt accent. It leads with dsh
  web's queue glyph in the queue amber and folds the preview into the same muted
  tier as the goal objective, on the buffer background; without SVG support
  a `≡` glyph replaces the old `Next:` prefix.
  (rationale: postmortem/101)

- **Show goal status before the objective**: a prominent `Ongoing Goal`,
  `Paused Goal` or `Blocked Goal` label now precedes the upright, muted
  objective. Like Next Message, the row uses the buffer background and places
  compact action icons one space after the objective, one space apart; narrow
  windows hide actions first and keep status visible. (rationale: postmortem/103)

- **Tint every goal dartboard with the tool purple**: the Goal Row icon, the
  transcript **Continuing goal** notice and the goal tool cards now share the
  tool icons' purple accent instead of the teal accent color.

- **Attachment icon**: use the SVG Repo `attachment` file-and-paperclip icon
  in the staged-attachments row, retaining its theme tint and size.

- **Per-file attachment removal**: the staged-attachments row lists only the
  file names, each followed by its own `✕` that drops that file, while
  `C-c C-d` still discards the whole set. A blank input sends the staged file
  names as the message text instead of an attachment count. (rationale:
  postmortem/094)

- **Clearer subagent count**: bold mode-line digits and a thin gap after the
  icon follow Flycheck's compact layout, retaining the muted status color.

- **Simpler chat header**: remove the permanent shortcut hint row from chat
  buffers. Existing keybindings remain available through `C-h m`.

- **Hide seed boundaries**: restored and forked histories no longer display
  `── seed boundary` rows. Event sequence tracking is preserved.
  (rationale: postmortem/085)

### Fixed

- **@ suggestions mirror the session list**: completion and the explicit
  reference menu skip archived sessions (through the synced archive registry,
  even before the list has loaded), blank never-messaged sessions and
  subagent-origin sessions. Unarchiving or a first message makes a session
  eligible again without a fetch, and references already in a draft are
  untouched. (rationale: postmortem/120)

- **@ reference discovery never blocks**: both host queries run in the
  background, even on a cold cache, so completion answers immediately and Corfu
  refreshes its open popup as results arrive; other frontends read the new table
  on their next completion. Prefetch now warms Corfu buffers too.
  (rationale: postmortem/119)

- **@ reference matching follows the host**: while a query loads, cached paths
  and session label/ID/workspace match case-insensitively; settled host results
  are offered as returned, quoted paths keep their quotes, and an ambiguous
  exact prefix stays editable instead of becoming a chip. Late replies cannot
  replace a newer query. (rationale: postmortem/119)

- **Keep the cursor on row headers when folding**: pressing `RET` on a
  header, including its end, expands or collapses the same row without
  jumping below it. Consecutive presses keep targeting that row.

- **Avoid repeated reply action rows after background follow-ups**: between
  rendered human messages, only the latest completed turn with a nonempty
  reply keeps its footer. Earlier replies remain visible; Copy/Fork target
  that latest reply, and tokens/time still describe only its turn. Unfinished
  or empty turns do not replace the row. History preserves separate groups
  when streamed replies straddle human input, and rejected submissions merge
  the groups again when their optimistic echo disappears.
  (rationale: postmortem/117)

- **Reuse saved authentication in batch E2E tests**: the runner reads the
  matching server's literal Customize token without executing the Emacs init,
  while preserving existing authentication. `DSH_E2E_CUSTOM_FILE` selects a
  nonstandard settings file; tokens are neither printed nor written back.
  (rationale: postmortem/113)

- **Recover from heartbeat write failures**: a connection that closes while a
  WebSocket ping is sent now retires its timers and reconnects through the normal
  stream recovery path, rather than leaking a broken-pipe error from the timer.
  The failed probe is still reported once for that connection.

- **Respect draft cancellation during CLI installation**: an installation
  finishing after timeout, draft closure or a server-address change no longer
  starts a server for the cancelled request. A server started by another request
  during installation is reused instead of restarted.

- **Authenticate after automatic server restart**: new-session drafts use the
  replacement server's fresh launch token instead of prompting for the old one.

- **Keep older history readable**: loading a page preserves every window's
  text even at the insertion boundary. Tool cards use the same following
  rule as streaming replies, and transcript trimming waits while a displayed
  window is scrolled away from the bottom. Newly fetched pages survive the
  size cap. (rationale: postmortem/109)

- **Keep your reading position when cards above it change**: a tool, job or
  subagent card growing or shrinking above the visible text no longer scrolls
  the transcript by the same number of lines; every window showing the chat,
  not only the first, keeps its place. Windows at the bottom keep following,
  now measured in screen rows so a long wrapped line no longer pulls a
  scrolled-up reader down. (rationale: postmortem/107)

- **Show every level of nested blockquotes**: `>> text` now draws two bars
  (and `>>> text` three) instead of merging adjacent `>` into a single bar.

- **Open angle-bracketed file links**: Markdown links such as
  `[source](</path/to/file.el#L10>)` now open the file at the requested line.
  Spaces and parentheses inside the bracketed destination are preserved,
  instead of sending an invalid target to the browser.

- **Keep render-report property ranges stable**: marker endpoints are recorded
  as positions at the time of each setter call, so later edits or marker cleanup
  cannot change the reported ranges or their summed span.

- **Keep running status through failed reconnects**: a failed connection attempt
  no longer loses the active turn flag. After reconnection and automatic
  compaction, a bounded history snapshot without `turn/start` still restores
  the running caption; `turn/end` clears it normally.

- **Open a session mention as the session, not as its opaque URI**: RET or a
  click on a `@label` chip or a rendered `@[label](dsh-session:…)` mention now
  decodes the URI payload into the session id before opening the chat.
  Previously the encoded payload itself was sent as the id, so the host
  answered `session/not-found` and the chat stayed in a follow-stream
  reconnect loop. Escaped IDs and malformed payloads are handled without
  stalling reference rendering.

- **Keep inline queue actions tied to confirmed state**: local pending previews
  offer no actions until the server supplies their queue ID; placement changes
  refresh the buttons even when the preview text stays the same. Sending an
  attachment-bearing item while idle now leaves it queued and reports an error
  instead of deleting its attachments, in both Composer and the queue manager.
  (rationale: postmortem/102)

- **Keep short goals on one line when text is enlarged**: flexible Goal Row
  spacing no longer wraps the row or pushes action icons onto a second line,
  including when inline actions are hidden.

- **Show a blocked goal's message, not its wire record**: the Goal Row
  tooltip, `C-c C-g ?` and the goal tool card now print the blocker's human
  `message`; previously the composer surfaces rendered the raw
  `{code, message}` record.

- **Show session mentions in goal text as their label**: the Goal Row (and its
  tooltip), `C-c C-g ?` and the goal tool card collapse a canonical
  `@[label](dsh-session:…)` objective to the clickable `@label` chip, exactly
  like the transcript message that named the goal; the opaque id is never
  displayed.

- **Keep goal notices when replies finish**: expanding or collapsing a notice
  while the following reply streams no longer lets the final reply replacement
  erase the notice and its prompt.

- **Locate the invoking chat in the session list**: `C-c C-l` now selects
  the chat you are viewing after switching between open chats, instead of
  jumping to the last opened session. Delayed list data and subagent
  ancestor expansion use the same target.

- **Keep the whale animation self-contained**: its GIF data is embedded in
  Elisp and decoded lazily, so installing the client needs no separate image
  file. Frame timing and colors stay unchanged. (rationale: postmortem/098)

- **Keep completed sessions idle on reconnect**: a delayed running cache no
  longer restarts the indicator after the chat has received `turn/end`.

- **Preserve status in custom Doom Modeline layouts**: layouts with the standard
  anchors receive the whale and DSH status segments, including layouts added
  after another chat was opened, without duplicate segments.

- **Restore running status after restarting Emacs**: opening an already-running
  session starts its whale animation (or static caption) from the cached session
  status, even when the initial history window no longer contains `turn/start`.

- **Open chat sessions with Doom Modeline enabled**: file-icon refresh now
  skips fileless DSH chat buffers, avoiding the mode-change hook error.

- **Use the DSH whale in the buffer-switch minibuffer**: Consult candidates for
  DSH chat buffers show the whale when `nerd-icons-completion` is active,
  instead of the generic Emacs icon. Without SVG support, the label is `DSH`.

- **Keep drafts written during file uploads**: completing an upload no longer
  clears text or attachments staged for the next message, including queued,
  steering, and slash-command submissions. (rationale: postmortem/092)

- **Undo restores sent text after replies arrive**: plain, image and file
  submissions retain their actual input until another input edit takes over,
  without changing the transcript or reattaching files. History navigation
  resets when consuming the draft; delayed success callbacks leave newer
  navigation alone. (rationale: postmortem/093)

- **Recover from local upload failures**: files that become unreadable or
  exceed the size limit while waiting to upload restore the draft, as do
  request-start failures, even after an earlier file has uploaded. The specific
  local error is reported once instead of being replaced by "transport error".
  (rationale: postmortem/092)

- **File echoes match the upload**: the transcript uses the host's sanitized
  filename and uploaded byte count while retaining local filenames for retries.
  (rationale: postmortem/092)

- **Expand only sessions with subagents**: session-list `TAB` now acts only
  on sessions with confirmed children. Empty and unknown catalogs no longer
  expand into placeholder rows or trigger a fetch. Workspace folding and
  automatic ancestor reveal remain available. (rationale: postmortem/087)

- **Error messages have breathing room**: standalone model and automatic
  compaction errors keep a blank line above and below their cards, including
  when collapsed, instead of touching the preceding footer or input line.

- **Reply footer stays at the turn's end**: Copy, Fork, token usage and
  elapsed time follow all of the turn's content, including deliveries,
  tool and thinking cards, failed attempts and error diagnostics. Placement
  survives historical paging, reconnects and deferred Markdown rendering;
  actions still target the last text reply. (rationale: postmortem/086)

- **Session list highlights only the focused row on first load**: when
  global line highlighting is enabled, asynchronously inserted rows no
  longer stretch the highlight over the rest of the list.

- **Session list keeps its focused row after updates**: reordering or
  refreshing rows no longer moves the cursor to the middle of the old
  viewport. The row highlight follows the restored focus immediately,
  including updates received between commands. Archiving or deleting the
  focused row selects the next surviving row, or the preceding row when
  none follows, instead of jumping to the first workspace.
  (rationale: postmortem/082)

- **Late thinking updates keep replies intact**: reasoning deltas received
  after answer text starts update their original Think row. They no longer
  insert another Think row in the middle of a sentence or split the answer.

- **Session list paints as soon as its data arrives**: frames recorded during
  a list refresh are replayed with repainting batched, and workspace frames
  arriving before the first `session/list` response no longer paint a list of
  empty groups. On a host with hundreds of sessions the first open previously
  showed group headers with `(0)` counts and a "New Session" row each, then
  replaced them with the real rows half a second later — and could block for
  several seconds while the frames replayed. Groups and rows now appear
  together, as soon as the list is read. (rationale: postmortem/081)

- **Consistent mode-line spacing**: status indicators and model details use one
  separating space in native and Doom mode lines; SVG icons and click targets
  stay intact. Chat buffers also remove Doom's duplicate padding around the
  major-mode label.

- **dsh 0.2.0 tool results render correctly**: direct tool-message text and
  error flags are decoded alongside the older nested format. Question cards
  now display real answers and pending state, including late replies restored
  from history, instead of losing the tool's result body.
- **Timed answers survive concurrent activity**: submitting an answer keeps
  its timeout protection until the host responds, and incoming prompts wait
  until a late-answer reader closes. Older snapshots no longer hide pending
  questions, loaded history shows saved late replies, and answers declined
  by the host no longer report success.
- **Confirmed skill invocations use skill styling**: host evidence now replaces
  a same-named command's border and tooltip with the skill presentation,
  including when the skill catalog has not loaded yet.
- **Digit-leading skill names are accented**: gestures such as `/3d-review`
  now receive skill styling from both the cached catalog and host evidence.
- **Ambiguous skill completion keeps the gesture editable**: matching a shared
  word such as `/review` in `code-review` and `design-review` no longer inserts
  a space into the unfinished name. A separator is added after a complete
  candidate is accepted.
- **Older history styles the skill gesture in its own message**: a replayed
  skill invocation now decorates the preceding message in the loaded page,
  instead of a newer message beside the composer.
- **Skill completion keeps the newest catalog**: a synchronous lookup now
  supersedes pending prefetch responses, so a late reply cannot restore stale
  skill suggestions. Refreshes started during the lookup also take priority.

- **A catalog refresh no longer loses to an older request**: a `commands/list`
  response already in flight when `M-x dsh-emacs-command-catalog-refresh` (or a
  reopen) invalidated the cache could land afterwards and write the stale
  catalog back, so the `/` completion and the slash menu kept showing the
  pre-refresh list.  Only the response of the session's current fetch may now
  write the cache or clear the in-flight flag; the same guard covers the new
  `skills/list` catalog.
- **The pending-input queue works against dsh 0.1.7 servers**: dsh 0.1.7
  removed the `session/queue` control frames (and the baseline's `queues`
  record) that carried the pending inbox, so the echo-area
  `queued:`/`steering:`/`running:` feedback, the Composer Next Message row
  and `C-c C-q` would all have stopped updating.
  The mirror is now derived from the host's `inbox` session projection, which
  carries the same fold state and predates the deleted frames — so the same
  client keeps working against 0.1.5/0.1.6 servers.  Reconnect baselines
  resolve session IDs consistently with live updates, restoring the pending
  queue without waiting for another inbox change.  The new-session picker
  also stops keying the web-consistent built-in preset labels on the roster
  row's `trust`, which 0.1.7 removed; it keys on the preset id alone, as dsh
  web does.  (rationale: postmortem/064)

## 0.5.0 - 2026-09-24

### Added

- **Paste a clipboard image into the next message**: `C-c C-v` reads the
  system clipboard's image (a screenshot, a copied picture) and stages it in a
  new Composer row above the input; type a caption — or leave the input empty
  to use the image name — and `C-c C-c` sends text and image together.
  `C-c C-d` (or the row's `✕`) discards the staged images, and a rejected send
  restores the text and images together only while the draft is still empty.
  A prompt carrying images is not kept for `M-p' recall — a text-only replay
  would drop them — so the automatic image-name caption never comes back as a
  prompt either.  `s-v` does the same whenever the clipboard
  holds an image, and falls back to an ordinary text yank otherwise; `C-y`
  always stays a text yank.  Accepted types are
  `dsh-emacs-attach-media-types`; where the pasteboard exposes TIFF rather
  than PNG (macOS), the image is converted with the system `sips` tool first,
  provided PNG is allowed by that option.
  Emacs 29+ users can also run `M-x yank-media`.  `C-c C-a` stays the
  one-shot "attach a file and send it now" command.
  (rationale: postmortem/063)

- **Opening the session list lands on the session you are in**: `M-x
  dsh-emacs` (and `C-c C-l`) now puts the cursor and `hl-line` on the current
  session's row instead of the first row, scrolling it into view — a folded
  workspace group it lives in is unfolded to show it, and a `w' filter that
  would hide it is cleared.  The row arrives asynchronously for a brand-new
  session, so the jump waits for it.  A plain refresh (`g', events,
  auto-refresh) still keeps the row you are on.

- **Undo/redo in the chat buffer, scoped to the input area**: `C-/`, `C-_`
  and `C-x u` now undo input editing — typing, yanks, `M-p` recall, the clear
  after a send — and `C-g C-/` (or `undo-redo` on Emacs 28+) redoes it;
  previously the buffer disabled undo and `C-/` answered "No undo information".
  The transcript is never
  undone: rendered messages, tool cards, streamed bodies and Composer chrome
  leave no undo step, so a `C-/` cannot delete rendered text (undo binds
  `inhibit-read-only` internally, so the read-only transcript was no
  protection).  A reply rendered above the draft moves the input, which
  invalidates the positions in the records made for it; those are rebuilt
  before the next command runs, so the first undo after a reply clears the
  draft instead of touching the transcript.  Redo leaves the cursor where
  typing continues — after the text it brought back — rather than at the
  start of the restored draft, where stock `undo` parks it.
  (rationale: postmortem/054)

- **Ask rows record the decision**: an `ask_user_question` call no longer
  dumps both of its JSON documents into an ioCard.  The row collapses to
  `Ask question · waiting`, then `2/2 answered` (or `cancelled` /
  `interrupted`), and expands into the questionnaire: each question's header
  chip and prompt, its options under the reader's own numbering with their
  descriptions, the chosen ones checked, and the free-text answer or
  `Not answered` where the batch settled empty.  The row takes dsh web's
  question icon (`IconQuestionOutline14`), and a question set the user
  dismissed or abandoned no longer paints the row as a red failure — its
  expanded body states the outcome in dsh web's wording.
  Arguments that name no usable question keep the generic ioCard; a malformed
  question or option element is dropped instead of breaking the row.
  (rationale: postmortem/053)

- **Restore an archived session without leaving Emacs**: `M-x
  dsh-emacs-unarchive-session`, and `u` in `*dsh-sessions*`, bring a session
  back from the archive set through the dsh 0.1.6 `workspace/unarchiveSession`
  RPC — the inverse the `d` archive action never had.  The picker offers only
  archived sessions (an archived row stays in `session/list`, the list just
  hides it), and the returned set refreshes the archive cache and the list.
  (rationale: postmortem/049)

- **Failed tool rows explain themselves**: a settled `tool/result` carrying
  dsh 0.1.6's `error.reason` now shows that user-facing explanation in the
  row's status line (`✗ failed — …`, `✗ exit 1 — …`).  The reason is the one
  the host deliberately keeps *outside* the model-facing result text, so a
  refused call (for example an Auto review denial) no longer reads as a bare
  `✗ failed`.  An absent or whitespace-only reason keeps the old status text
  unchanged.

- **See and switch the session's permission preset**: the mode line gains a
  `permission` segment (on by default, between `preset` and `ctx`) showing the
  session's current sandbox/approval preset from the `permissions` projection
  — `workspace-write` by default, `danger-full-access` when the session runs
  unconfined, or `custom` when the knobs match no preset.  The segment draws
  dsh web's shield icon, so it costs one cell instead of a word: the real SVG
  shield (check / pencil / exclamation) on a graphical Emacs with SVG, else
  the matching Nerd Font shield glyph when `nerd-icons` is installed, else a
  short token — an unrestricted session tints the shield red.  Emoji are never
  used (they are double-width and do not take the face color).
  `M-x dsh-emacs-set-permission` offers the host's
  `permissionPresets/catalog` (dsh 0.1.6) with each preset's label and
  description and switches through the `/permission` command, so the change is
  recorded in the session and the segment follows it.  Set
  `dsh-emacs-modeline-permission-style` to `text` for the unabbreviated preset
  name, or remove `permission` from `dsh-emacs-modeline-format-spec` to hide
  the segment.
  (rationale: postmortem/050)

### Changed

- **Opening the session list no longer re-fetches or reconnects**: the list
  is kept live by the server's event stream (and by the local cache update
  session creation already does), so `M-x dsh-emacs` / `C-c C-l` now reuses
  the cached rows instead of POSTing `session/list` and re-opening the
  `workspace/follow` stream on every open.  A cold cache (nothing fetched
  yet) still fetches, and `g` still refreshes on demand.  (rationale: postmortem/059)

- **Ask option descriptions read as one face, without brackets**: the
  description riding along with each option candidate in the `ask` reader
  now carries `dsh-emacs-meta-face` — the face the transcript's ask card
  gives the same text — instead of the frontend's generic
  `completions-annotations` default, and the suffix is the bare description
  rather than `[description]`, so the reader and the settled row read as one
  surface.  (rationale: postmortem/042)

- **Generic tool cards line up and say what happened**: a tool with no
  dedicated card (any variant-less tool — for example a plugin's `dev_*`
  tools) now expands into one aligned block: the `IN` arguments read as a
  single row (a pretty-printed object is flattened, and one wider than the
  card is ellipsized with the full value in its tooltip), the `OUT` result
  keeps its own lines hanging under a content-sized `─` rule, and a
  zero-argument call drops the empty `IN {}` section entirely.  A clean
  success no longer prints `✓ exit 0` (an exit code these tools never had;
  failures and interrupts keep their status line), and the header now reads
  `Tool Call · <tool name>` — the wire tool name, with the call's arguments
  shown only once the card is expanded — instead of a humanized title.  A
  curated `dsh-emacs-tool-titles` entry still wins, so `Present files` and
  the job rows keep their headers.

- **`TAB` completes ordinary words in the chat input**: a word already
  written in the buffer — the draft above point and, within
  `dsh-emacs-word-completion-limit` characters, the transcript above it —
  now completes instead of being retyped, so a term from an earlier message
  or a tool result is one keystroke away.  Words are runs of letters, digits,
  `_` and `-` (identifier-like terms complete whole), and matching follows
  `completion-ignore-case`.  Candidates appear nearest-first, and completing
  inside a word includes its existing suffix instead of duplicating it.
  Slash commands and `@` references keep their own completion even when
  their catalogs are empty.  (rationale: postmortem/061)

- **`TAB` completes local file paths in the chat input**: a token carrying a
  separator (`docs/rp`, `./src/`, `~/…`, an absolute path) completes through
  the stock file-name completer against the chat buffer's working directory
  — the session workspace — with `find-file`'s directory drill-down and the
  active completion styles, preserving any suffix after the cursor.  A
  leading slash-command prefix stays with command completion even when its
  catalog is empty; a bare name still completes as a word, and an `@`
  reference still completes from the host's workspace list (use one for a
  path with spaces, or when the dsh server runs on another host).  This
  reads the machine Emacs runs on, like `!` shell lines.
  (rationale: postmortem/062)

### Fixed

- **Backward word deletion clears punctuation at the input start**:
  `M-<backspace>` / `M-DEL` now removes drafts such as `~/` and `../`
  instead of failing on the read-only prompt. Word and region kills stop at
  both input boundaries, keeping the prompt, transcript and separator intact.

- **Re-opening the session list no longer resets your folded groups**:
  `M-x dsh-emacs` / `C-c C-l` skipped the list's major mode when the buffer
  was already in it, which used to run `kill-all-local-variables` and wipe
  the per-buffer fold overrides (a group folded with `TAB` came back
  expanded), the workspace filter, and the host-stream binding — the last
  one silently orphaned the live stream and forced a reconnect on every
  open.  Re-opening now keeps the buffer's state and its connection.

- **A reconnect no longer announces that it dropped nothing**: the `$events`
  generation banner (`new $events generation — retiring N queued
  question(s) and M approval(s)`) now appears only when a reconnect actually
  retired queued waterfalls; a plain reconnect, which mints a generation as a
  matter of course, stays quiet.

- **Finished replies no longer gain a duplicate Think row**: a delayed
  block-end notification recognizes reasoning that already streamed and
  folded above the answer. Blocks delivered without deltas are also tracked,
  so the final message does not display them twice.
  (rationale: postmortem/060)

- **Streamed blocks stay separate through finalization and retry**:
  consecutive Think or text blocks keep their own boundaries; corrected or
  removed reasoning replaces its old content in place. Failed attempts move
  all their streamed content into the attempt card, leaving no stale Think
  or partial body to mix into the retry. (rationale: postmortem/060)

- **Reconnect restores the complete in-progress reply once**: compressed
  snapshot records now rebuild the active stream after retiring its old
  partial output. Repeated frames at the snapshot's revision are ignored.
  (rationale: postmortem/060)

- **Live replies recover from restarted counters and missing frames**:
  a new Agent lifecycle can stream on the existing connection; an attempt
  mismatch or frame gap requests a fresh snapshot before continuing, so
  missing text does not silently leave a truncated live reply.
  (rationale: postmortem/060)

- **A session-list refresh no longer scrolls the list**: a repaint (event,
  auto-refresh, `g`) now puts every window's scroll position back — keyed to
  the row that was at its top — instead of re-centering the current row,
  which read as the page "re-flowing".  Opening the list still moves to the
  current session, but scrolls only when that row is genuinely off screen.
  (rationale: postmortem/058)

- **Every window on the session list keeps its own row**: when the same
  `*dsh-sessions*` buffer is shown in two windows, a refresh (events,
  auto-refresh, `g`) no longer drops the window that is not current back to
  the top of the list — each window's row is captured before the redraw and
  put back after it, including a window parked on a workspace header.  A row
  that is gone (its group collapsed) falls back to the top row.
  (rationale: postmortem/058)

- **Streamed replies protect their trailing blank lines**: the separators
  after text, code blocks and tables can no longer be edited while a reply
  streams or after it finishes; the input area remains editable.

- **Live Think output is read-only from the first chunk**: its header,
  streamed body and separator can no longer be edited with newline or
  deletion commands while reasoning is arriving. The input remains editable.

- **Typing no longer stalls a streamed block transition**: unfinished
  Markdown stays queued until idle when reasoning starts. A corrected final
  answer cancels any queued formatting for the text it replaces.

- **Markdown after a code fence renders in the same chunk**: headings,
  emphasis and subsequent code blocks are formatted even when they arrive
  with the previous block's closing fence or the final message.

- **Interleaved answers keep their order when finalized**: unchanged text
  and thinking blocks no longer move or duplicate because of the separators
  between protocol blocks.

- **Undo immediately after sending restores the draft**: inserting the
  transcript echo no longer discards the undo record for clearing the input.

- **File diffs distinguish unchanged context from edits**: expanded `edit`
  and `write` cards align matching lines and show them once in plain text.
  Only removed and added lines receive red/green prefixes and contribute to
  the footer totals, in both running previews and settled results.  Very
  large replacement middles are explicitly marked as unaligned.
  (rationale: postmortem/057)

- **Thinking no longer rewrites the transcript while it streams**: a step's
  blocks now render where they arrive.  A reasoning block folds into its own
  collapsible `Think` fragment as soon as the answer starts, and a later
  reasoning block opens a new `Think` fragment below the answer, so a step
  with text–reasoning–text streams in that order.  Previously the whole step
  shared one live text region: a reasoning block inserted mid-stream sat
  inside it, so the Markdown passes rewrote the reasoning text (a table or
  fence in the thinking became a rendered card, inserting line breaks into
  the Think body) and the final message could delete the Think block — and
  the answer around it — when it repaired the body.  The authoritative
  message now reconciles only what has not been rendered: finished bodies are
  left in place, and only a genuinely divergent body is replaced.
  (rationale: postmortem/056)

- **A streamed code block no longer rearranges what is already on screen**:
  the card chrome (label and panel lines) is written the moment the opening
  fence completes, so the body streams into a settled layout and the closing
  fence only appends the bottom panel line.  Previously the whole block stayed
  raw until its closing fence arrived and was then replaced by the card, which
  inserted blank lines above text the user had already read and shifted
  everything below it.  Highlighting and the body's panel properties are
  applied as the body arrives (properties only, never text).  Tables still
  re-render their rows while they extend; that part of the same fix is
  pending.  (rationale: postmortem/055)

- **`M-p` no longer recalls the host's own injected messages**: alongside a
  prompt the host appends `user/message` copies of model-facing text —
  workspace instructions (`<system-reminder>…</system-reminder>`),
  runtime-context snapshots, goal and subagent notices — marked with their
  origin in `data.source.kind`.  The transcript already skipped them, but
  the per-session history backfill took every `user/message` text, so `M-p`
  on an existing session could drop a wall of system-reminder prose into the
  input.  Backfill now records only messages whose source kind is `user`
  (or that carry no source at all, like fixtures and the optimistic echo);
  the same predicate decides what the transcript renders, so the two views
  of "a message the user wrote" cannot drift apart.

- **A slow first server start no longer reads as a failure**: `M-x
  dsh-emacs` starts `dsh web` in the background and then polls for it, but
  that poll gave up after a fixed ten half-second attempts.  A cold boot
  composes the profile and loads the whole plugin tree — measured at about
  4.5 s here, a fraction of a second inside that window — so a slightly
  slower boot ended with an empty session list and "server did not become
  ready".  The poll now waits for `dsh-emacs-server-wait-seconds` (the same
  grace period a blocking server start uses) and, when it does give up,
  says whether the process it started exited and points at `*dsh-server*`.
  (rationale: postmortem/052)

- **A new session no longer pre-selects the wrong agent preset**: the preset
  roster's `isDefault` is a required JSON boolean, and `json-read` decodes
  `false` as the truthy `:json-false`; the protocol struct kept that raw
  value, so with `dsh-emacs-default-preset` unset the picker pre-selected the
  first roster row instead of the host's default.  `isDefault` — and the
  roster's `authorable` / `hasDocument` plus a command's `attachments` flag —
  now normalize where they cross into the struct, like the session flags
  below.

- **An idle `C-c C-c` is no longer queued as if the session were running**:
  the session row's `running` flag is a JSON boolean, and `json-read` decodes
  `false` as the truthy `:json-false`; the protocol struct kept that raw
  value, so `dsh-emacs--busy-p` read every idle session as generating.  The
  send then took the queue path — the message showed first as the blue Next
  Message preview and only entered the transcript when the host claimed it,
  instead of starting a turn and echoing at once.  Wire booleans are now
  normalized where they cross into the session struct
  (`dsh-protocol--boolean'), and the now-redundant per-caller normalizations
  are gone.

- **Sending a message no longer flashes the Next Message row**: an idle
  `C-c C-c` passes through the host inbox (a splice frame and a claim frame
  within milliseconds), and the row is suppressed for that transient — but
  the suppression was lifted whenever a turn was running, and the send path
  lights the spinner on acceptance, *before* the claim frame arrives.  The
  row therefore painted the just-sent message and cleared it a frame later.
  The reveal is now keyed on whether a turn was ALREADY running when the
  submit was made (captured in `dsh-emacs-queue--submit-parked-p'): a
  genuinely parked message behind a running turn still shows immediately,
  while an idle submit stays invisible through its transient.

- **A newly opened session's first send no longer flashes it either**: a
  fresh chat buffer's queue mirror is seeded by the connection's first
  frame, which can be empty and arrive between the suppression arm and the
  splice.  That baseline was taken for the claim, disarming the gate so the
  next frame painted our own message (and leaked a `queued:` echo).  The
  suppression now ends only at the empty frame that FOLLOWS the submit's
  own splice — the real claim — while the hygiene timer still bounds a
  submit whose item never reaches the mirror.

- **Opening a session no longer leaves the mode-line running animation
  stuck**: the `session/follow` opening snapshot rendered inside
  `while-no-input`, whose early exit drops the whole batch whenever input is
  pending — a fast keystroke while a session opened from `*dsh-sessions*`
  cut the seed short.  The caller then advanced `dsh-emacs--anchor-seq` to
  the snapshot cursor, so the dropped tail was never re-delivered: a dropped
  trailing `turn/end` left the spinner ticking with no later event to stop
  it (and the transcript missing its tail).  The snapshot is a settled,
  bounded batch like an older-history page, so it now renders to completion,
  yielding between groups instead of being abandoned.

- **Sent messages show up the moment the input clears**: the transcript echo
  was rendered in the `session/prompt` HTTP callback, and a queued (busy)
  message waited for the host's `session/queue` frame, so `C-c C-c` left a
  visible gap before the message appeared.  The idle path now echoes the
  message optimistically at submit; the host's canonical `user/message` is
  deduped against it, and a rejected prompt deletes the echo and restores
  the draft.  The busy path shows the queued message in the Next Message row
  immediately from a local optimistic item, which the host's own frame (or a
  failed submit) retires.
  (rationale: postmortem/051)

## 0.4.1 - 2026-09-17

### Fixed

- **The server is found when the process coding system has DOS line endings**:
  on Windows, `default-process-coding-system` normally encodes to a `-dos`
  coding system (`locale-coding-system` carries DOS line endings), and every
  new connection inherited it.  The hand-written `GET` requests of the
  liveness probe, the auth probe and the launch-token exchange then left the
  socket with `\r\r\n` line endings, which dsh's HTTP parser rejects with
  `400 Bad Request`.  Since the probe only counts `200`/`401` as alive, a
  running server looked down: `*dsh-sessions*` stayed empty and
  `new-session` failed with "did not become ready".  The three raw HTTP
  sockets now force binary (byte-exact) coding, as the WebSocket sockets
  already did.

## 0.4.0 - 2026-09-16

### Breaking Changes

- **The tool-card surface face is removed**: `dsh-emacs-tool-bash-panel-face`
  has no replacement — expanded tool cards now draw on the transcript
  background (see `Changed`).  Drop any `custom-set-faces` entry that named it
  (rationale: postmortem/045).

- **Fragment faces are region-scoped**: `dsh-emacs-ui-make-fragment` drops the
  whole-block `:face` for `:header-face` (header row) and `:body-face`
  (expanded body).  The regions are disjoint, so a row/status face can no
  longer bleed into a body; extensions that passed `:face` must pick the region
  they meant (rationale: postmortem/039).

- **`ask` questions are answered in one read**: multiple choice is now a
  comma-separated answer (`2,3`) instead of a toggle menu, and the question
  detail moves to the echo area. `dsh-emacs-question-help-display` keeps only
  `echo-area` (the new default) and `nil`; `tooltip` is gone, along with
  `dsh-emacs-question-tip-delay` and the `dsh-emacs-question-tip-face` face.
  The menu no longer reopens per key, so it cannot flicker or reorder
  (rationale: postmortem/042).

- **The question skip key is `C-c C-s` by default**: it was `s`, but the
  reader's text is the answer now, so a bare letter would make that letter
  untypable inside the answer (the free-text sentinel contains an `s`).
  Rebind `dsh-emacs-question-skip-key` if you prefer another key
  (rationale: postmortem/042).

- **Copy keybindings are consolidated on `C-c C-w`**: it now runs the
  context-aware `dsh-emacs-copy-dwim` instead of copying the whole transcript,
  and the code-block copy key `C-c C-k` is unbound.  The standalone copies
  stay available as `M-x dsh-emacs-copy-transcript` and
  `M-x dsh-emacs-copy-code-block` (rationale: postmortem/043).

### Added

- **Read and file-mutation rows expand into their own cards**: a `read` row
  shows the file's lines with their numbers in a muted gutter, plus a
  `Showing N of M lines` footer when it read only a window; a `write`/`edit`
  row shows a `- `/`+ ` diff with a per-file path row and a
  `└ +N -M · K file(s)` total.  Both replace the raw argument JSON and result
  envelope.  An `edit` previews its intended diff while it runs and switches
  to the one its result records; a `write` keeps its whole-file diff.
  Anything the models cannot describe (a directory or image read,
  `web_fetch`, a failed call, malformed arguments) keeps the generic IN/OUT
  card.  Four faces style the new bodies: `dsh-emacs-tool-meta-face`,
  `dsh-emacs-tool-diff-path-face`, `dsh-emacs-tool-diff-add-face` and
  `dsh-emacs-tool-diff-del-face` (rationale: postmortem/045).

- **Background-job rows expand into job cards**: a `job_output` row shows the
  job's output and turns the Host's trailing `[status: ...]` line into a
  state-colored footer (`running`, `completed`, `killed`, `failed`), while
  `job_list` and `job_kill` show their result as plain rows.  The argument
  JSON is no longer repeated — `job_output` and `job_kill` headers carry the
  job id, and the three tools get `Job Output`, `Jobs` and `Kill Job` titles
  (rationale: postmortem/046).

- **`present` rows name the files they declared**: the row header carries the
  call's paths, comma-joined under a `Present files` title (dsh web's
  `PresentRow` shape), and the expanded body shows the result text instead of
  the argument JSON.  A failed `present` keeps the Host's message and the
  declared-path summary (rationale: postmortem/047).

- **Question prompts explain themselves while you answer**: an `ask` prompt is
  one minibuffer read — the question text is the prompt, the numbered options
  are the candidates, and each option's description is a completion
  annotation. Multiple choice takes a comma-separated answer (`2,3` or
  `alpha,beta`, Emacs' standard `completing-read-multiple`); single choice
  takes one candidate; any text that names no option is itself the answer
  (there is no separate "type an answer" step); a selection comes back in the
  question's option order; empty input and the skip key skip the question;
  `C-g` abandons the group. The question detail
  shows in the echo area, and cleanup preserves unrelated messages.
  `M-x dsh-emacs-question-preview` demonstrates the reader locally with a
  three-question sample batch — multi-select, single-select and free text
  (rationale: postmortem/042).

- **The remaining V3 core events reach the client**: `step/start` /
  `step/end`, `assistant/attempt`, and `session/end-seed` — dropped silently
  until now — are consumed (rationale: postmortem/040); `system/message` stays
  deliberately unrendered.  A step (one model call plus its tool executions)
  is a turn-internal boundary, not conversation, so it does not enter the
  transcript; the new `dsh-emacs-modeline-show-step` option (default nil, off
  so the line stays quiet) adds a `step N` badge next to the running spinner,
  with the step's elapsed wall-clock time appended once it passes a second and
  the full `turn N · step N` in its tooltip.  An
  `assistant/attempt` — a failed, retried, or cancelled attempt that committed
  no surface message and exists only in its `data.stream` — renders as a muted
  `↻ Attempt (no committed reply)` card whose body reconstructs the packed
  reasoning / tool-call / text records (reasoning follows
  `dsh-emacs-show-reasoning`); when the attempt settles a live streamed body
  the live body is taken over instead of being painted twice, and a retry
  starts a fresh body instead of appending to the failed one.
  `session/end-seed` marks the restore boundary with one muted
  `── seed boundary` row (`inherited history` for a fork/resume seed); a fresh
  session never appends one (rationale: postmortem/040).

- **Declared deliverables close the turn**: a successful `present` call
  appends the durable `deliverables/presented` event, which the client used to
  drop; it now renders one collapsed `Deliverables · N files` row led by a
  green `●` with a magenta title (`dsh-emacs-deliverable-dot-face` /
  `dsh-emacs-deliverable-text-face`, magenta via
  `dsh-emacs-color-deliverable`), after the turn's closing message (dsh
  web's turnTail position).  Expanding the row lists one indented line per
  declared path with its optional description; paths are clickable references
  — RET or mouse-1 opens the file resolved against the session working
  directory.  Repeated declarations
  of one path collapse to one line with the latest description.  A turn's
  `write`/`edit` changes are not folded in: their tool cards already show
  them, matching dsh web's produced-files row (rationale: postmortem/041).

- **One `C-c C-w` copy key that reads the context**: the new
  `dsh-emacs-copy-dwim` copies the active region verbatim, else the code block
  at point, else the assistant message containing point, else the most recent
  assistant message.  Assistant-message bodies carry no user prompts, tool
  cards, thinking blocks or transcript chrome.  The narrower copies remain as
  commands: `M-x dsh-emacs-copy-last-assistant-message` (the fallback alone),
  `M-x dsh-emacs-copy-assistant-message` (every reply, blank-line separated),
  `M-x dsh-emacs-copy-code-block` and `M-x dsh-emacs-copy-transcript`
  (rationale: postmortem/043).

- **Load older messages into the transcript**: `C-c C-o`
  (`M-x dsh-emacs-load-older-history`) reads one more page
  (`dsh-emacs-history-window` messages) of `session/page` history *before* the
  earliest message currently rendered and inserts it above the transcript,
  keeping the visible text where it was — no re-open, no scroll jump, and the
  draft under point stays put.  Pages arrive in conversation order, each tool
  call above its result, and loading while a turn runs leaves the running
  reply, the mode-line, busy state and `M-p` recall order untouched.  The
  follow snapshot's `hasMore` flag arms the command and each loaded page's flag
  re-arms it, so at the start of a session the command reports that nothing is
  left instead of requesting a page that cannot exist (rationale:
  postmortem/044).

- **Rename the current session from its chat buffer**:
  `M-x dsh-emacs-rename-session` inside a chat buffer prompts for a new
  title, prefilled with the session's current one, and renames that session
  in place — no trip through the session list or a session picker (there is
  no default chat key for it).  The session list and any other open buffer
  for the same session follow the live title (rationale: postmortem/048).

### Fixed

- **Background command failures use the error color**: a `job_output` footer
  with `completed, exit code: N` is red when N is nonzero, even though the
  Host marks the job as completed.

- **Job summaries consistently identify the job**: `job_output` and
  `job_kill` prioritize `job_id`, even when another string argument such as
  the cancellation reason appears first.

- **Shell exit status is read from the result text**: a nonzero exit or a
  killing signal settles the row as failed and prints its `✗ exit N` /
  `✗ signal X` footer — dsh's shell renderer writes the status into the
  model-facing text (`[exit code: N]` / `[killed by signal: X]`), not into the
  result block, so the marker is parsed there (web `parseExitStatus`) and
  removed from the displayed output.

- **File cards require a successful call**: read and diff cards fall back to
  the raw result for any other status — a failure, an `interrupted` abort, a
  nonzero exit, or a signal — instead of drawing a card over the diagnostic
  text.

- **Read cards reject lines before the requested window**: metadata with line
  numbers below its declared offset falls back to the raw result instead of
  displaying an unrelated window.

- **Large file reads finish rendering**: validating the read envelope no
  longer overflows Emacs' regexp matcher when the host returns a large window.

- **Malformed tool results no longer leave completed calls pending**: invalid
  read/diff metadata, and a malformed result body (a non-array `content`, or
  members that are not objects), now select the existing fallback body instead
  of signalling out of the renderer — preserving the result text for reads and
  edits and the whole-file preview for writes.

- **The package loads and completes on Emacs 27–30**: session switching, the
  model picker, `ask` answers and `@` references all pinned candidate order
  through `completion-table-with-metadata`, which is Emacs 31-only, so on
  older Emacsen they signalled `void-function` and even `require 'dsh-emacs`
  failed while building the model collection.  The call sites now go through
  a shim that uses the Emacs 31 built-in when present and an equivalent local
  completion table otherwise, restoring the declared 27.1 baseline.

- **`ask` option lists keep the question's order**: the numbered candidates
  now carry identity sort metadata, so a completion frontend no longer
  re-ranks them by history, length, and alphabet (which scrambled the
  numbers, differently from one question to the next).

- **The code-block scan no longer hangs at the end of the transcript**: it
  read `next-single-property-change`'s limit return as a real block and
  looped forever at `point-max` when the buffer held no code block;
  `dsh-emacs-copy-code-block` now stops at the limit and reports
  `Point is not inside a code block`.

- **HTTPS RPC calls can authenticate on demand**: obtaining or renewing the
  session cookie during an RPC now uses an independent GET request. The token
  exchange no longer inherits the RPC's POST method, body, or headers, which
  could cause a 405 response followed by an authentication failure.

- **HTTPS connections no longer ask for Basic credentials before using the
  launch token**: the initial reachability probe now handles a server's 401
  without opening a username/password prompt, allowing the configured token
  to be exchanged for the browser-session cookie as intended.

- **HTTP token authentication works behind Basic-auth proxies**: the token
  exchange now carries the credentials configured in the server URL and
  selects the `dsh-auth-*` cookie even when the proxy sets another cookie
  first.

- **RPC authentication failures no longer ask for a username/password**:
  HTTP and HTTPS requests use the client's authentication cookie without
  mixing in Emacs' global cookie jar. A rejected cookie produces an HTTP 401
  authentication hint and is cleared for the next attempt; synchronous calls
  no longer mistake the error page for a malformed JSON response.

- **HTTP WebSocket connections on port 443 keep their authentication**:
  the handshake now retains this non-default HTTP port in `Host` and
  `Origin`, matching the authority used to mint the cookie.

- **Row accents no longer leak into card text**: expanding a Think block
  painted its preview and reasoning body in the title's orange bold,
  `Edit`/`Read`/… ioCards painted `IN`/`OUT` in the row's green/red/orange, and
  every summary inherited the title's bold weight.  The accent now stays on the
  row title — the Think label, or a tool's icon + title — the new muted
  `dsh-emacs-thinking-body-face` styles the reasoning preview and body, and
  command / `!command` outcome bodies stay plain (rationale: postmortem/039).

- **Pruned tool results no longer paint a second card**: a `tool/result`
  surface record that *replaces* an earlier one (compaction's tool-result
  pruning) shares its `callId` with the record it shadows, so the transcript
  rendered the same tool card twice — once with the original output and once
  with the pruned copy.  Replacements are model-only by design
  (dsh-session's `isAppendSurfaceEvent`: the model-visible surface shadows the
  old range while the human transcript keeps what the user already saw), so
  the replacement copy is now consumed without rendering; the original card
  stays as-is.  Compaction checkpoints were already invisible (their
  `user/message` source kind is `plugin', which the user-message renderer
  filters) and system-prompt rewrites target `system/message`, which is never
  rendered (rationale: docs/rpc.md §7.1).

- **Session list no longer reports a status the wire never sends**: the row
  status now derives from the row's `running` flag alone.  It used to read
  `projections.values.sessionStats.pendingInteraction`, a field no dsh
  version puts on the list wire, so the "approval"/"pending" states were
  unreachable code that could only ever mislabel a session.  dsh web keeps
  that state in a client-side registry its live approval/question waterfall
  claimants fill in, which this client cannot mirror from the same place: a
  waterfall for a session with no open chat buffer is handed back to the
  host with `next`, so no client state exists for it.  A waiting session
  therefore shows as `running` (its tool call is in fact still running)
  rather than as idle or approval (rationale: docs/rpc.md §9).
  `dsh-protocol-session-pending-interaction` is removed with it.
  `dsh-emacs-status-pending-face` stays defined (now documented as reserved)
  so an existing customization is not lost when that derivation lands.

- **Replies stream again under dsh 0.1.5**: the client now opens its
  `session/follow` stream with `assistantStream: true` and consumes the
  process-local `assistant-stream` frames.  dsh 0.1.5 dropped
  `assistant/chunk` as a durable Session event, so before this change a reply
  appeared only once its `assistant/message` settled — the whole turn showed
  as silence.  Text and reasoning deltas render incrementally again (the
  frames are rebuilt into the durable envelope the existing renderer
  expects), a reconnect mid-reply resumes the live body from the opening
  snapshot's accumulated attempt, and frames from an older generation are
  dropped instead of interleaving two replies
  (rationale: docs/rpc.md §0.2, §3.2.1).

- **Slash commands work against dsh 0.1.5**: `commands/execute` now sends the
  renamed `submittedAttachments` field (dsh 0.1.2 called it `images`), so
  running a slash command no longer fails with
  `gateway/arguments-invalid: missing "submittedAttachments"; unexpected
  "images"`.  Attachments travel as one tagged union member
  (`{type: "image", …}`) instead of a bare image object, and the command
  catalog's input descriptor reads the host's renamed `input.attachments`
  flag (`input.images` is gone), so commands that accept composed attachments
  are recognized again (rationale: docs/rpc.md §0.2, §4.11).

### Changed

- **Expanded tool cards no longer paint a background band**: every card — the
  bash terminal card included — draws on the transcript background, so rows
  are no longer padded to the box width (a 20-line bash card is 542 characters
  instead of 1814) (rationale: postmortem/045).

- **`scripts/verify.sh` now rejects free-variable warnings**: the
  byte-compile step used to pass on any warning.  `reference to free
  variable` is now a FAIL, because it means the code reads a variable that
  never exists — the exact symptom of a docstring whose unescaped `"` closes
  the string early and turns the rest of the line into code, a silent runtime
  bug no read-level check can see.  Docstring width and third-party "not
  known to be defined" warnings stay informational; an intentional
  cross-module read is fixed by declaring it (`defvar` / `declare-function`).


### Documentation

- `docs/rpc.md` re-anchored on dsh `0.1.5-rc.1`: the 0.1.5 wire deltas are
  recorded as a migration table (session-format V3 event vocabulary,
  `assistant-stream` frames, the renamed `commands/execute` field and
  `input.attachments`, `isSeeded`, the new `workspaceFiles` /
  `fileUploads` / `sessionFeedback` namespaces and HTTP routes), and the
  session-list status note plus the surface-replacement rendering rule are
  documented with the evidence that settled them.

## 0.3.0 - 2026-09-10

### Breaking Changes

- **Fragment lookup and deletion take separate identity arguments**:
  use `(dsh-emacs-ui-find-block namespace-id block-id)` and
  `(dsh-emacs-ui-delete-fragment namespace-id block-id)`. Joined IDs and
  keyword deletion arguments are no longer accepted (rationale: postmortem/024).

- **Fragment extension API uses complete snapshots**: callers of
  `dsh-emacs-ui-update-fragment` supply all content and styling fields;
  nil clears a field and the return value is now `(START . END)`.
  Unused group and `hide-label-on-collapse` constructor arguments, the
  `append` update argument, and `dsh-emacs-ui-make-group-model`,
  `dsh-emacs-ui-update-header`, `dsh-emacs-ui-restyle-block`,
  `dsh-emacs-ui-state-at`, and `dsh-emacs-ui-block-p` are removed.
  The unused `dsh-emacs-ui-body-face` and `dsh-emacs-ui-group-header-face`
  are also removed, and the `:color-key` constructor argument is renamed
  `:status` (it never applied colors — `:face` does). Extensions should
  supply `:face` / `:header-face` with their snapshot
  (rationale: postmortem/022).

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

- **Bash tool rows expand into a terminal card**: a settled (or running)
  bash/pwsh call now opens into the dsh-web `BashRow` shape — a
  code-block-style background band (`dsh-emacs-tool-bash-panel-face`) with a
  single `$` prompt row for the command (a multi-line or over-long command
  is flattened to one line and ellipsized; the full raw command remains
  available as the row's tooltip), a divider where the output starts, the
  raw output below, and (for a failure or interrupt) a state-colored footer
  (`✗ exit N`, `✗ signal …`, `⏸ interrupted`) — instead of the generic IN/OUT
  ioCard.  A clean exit ends bare at the output, with no `✓ exit 0` line.
  Other tool variants keep the ioCard.  The card's faces are baked onto its
  text (so fold/unfold preserves them) and the row's state tint stays on the
  header line; the new `dsh-emacs-tool-bash-prompt-face` colors the `$`
  prompt with the same tool-purple as the leading icon.

- **`!command` local shell commands**: a line typed after `❯ ` starting with
  `!`, without attachments, runs the full input **locally** using Emacs's
  `shell-file-name` with `-c` in the session workspace. It works offline and
  while the model is busy; attached images with a `!` caption still go to the
  model. A spinning transcript row becomes expanded, collapsible output with
  its exit status when the shell finishes. Local results are not sent to the
  model or saved in server history and disappear on history reload.
  `C-c C-!` (`dsh-emacs-shell-process-kill`), the next `!` command, chat
  closure, or a major mode reset stops the tracked shell; background children
  may outlive it. New options: `dsh-emacs-shell-require-confirm` (nil;
  t asks before running), `dsh-emacs-shell-max-output` (50000 characters),
  `dsh-emacs-shell-null-stdin` (t; EOF on stdin, without a guarantee that TUIs
  exit), and `dsh-emacs-shell-timeout` (nil for no limit, or positive integer
  seconds; other values are rejected). See `docs/shell-commands.md`
  (rationale: postmortem/038).

- **Next Message joins Composer**: pending input now has its own read-only
  row below the goal and above `❯`, with a window-width preview and full-text
  tooltip. Its text and icon use the prompt accent color, matching the former
  next-preview prefix. Goal and queue rows appear independently; updates
  preserve the draft and cursor. Steering priority and transient suppression
  are unchanged (rationale: postmortem/020).

- **Composer goal feedback**: `C-c C-g ?` shows the full objective and blocked
  reason. Pending actions show progress and temporarily hide inline controls;
  narrow rows prioritize status and objective, and action tooltips include
  readable labels and shortcuts (rationale: postmortem/019).

- **Goal Row in the chat composer**: while a session has an active goal, the
  chat buffer shows a read-only **Goal Row** pinned above the editable input —
  a dartboard goal SVG icon (mirroring dsh web) followed by the objective and
  phase on one line (embedded line breaks are folded, a long objective is
  ellipsis-truncated to the window width instead of wrapping, and a completed
  goal hides the row entirely, like dsh web) — composer chrome, not transcript
  content, never sent to the model.  The row is fed passively from the server's
  `goal` session projection (`session/control` frames and the `session/follow`
  snapshot), so it appears/disappears as the goal changes and is rebuilt when
  the session reopens.  Streamed messages stay above the Goal Row instead of
  pushing it away from the input (rationale: postmortem/017).
- **Goal actions**: pause, resume, edit, and clear the current goal from the
  chat buffer — `C-c C-g` is a goal prefix (`p` pause, `r` resume, `e` edit, `d`
  clear), and the Goal Row shows the dsh-web pause/resume/edit/clear **SVG
  icons** (RET or mouse-1 on the icon runs the action; a text glyph is the
  fallback when Emacs lacks SVG support).  Each action is a CAS `goals.*` call
  on the live goal ref, guarded against double-fire, and the row updates
  optimistically from the returned view only while that request's ref remains
  current, so a late HTTP response cannot overwrite a newer projection (a
  cleared goal is removed).  `edit` prompts in the minibuffer pre-filled with
  the current objective.  Failures message the user and leave the row unchanged
  (rationale: postmortem/018).
  The inline action buttons are optional: `dsh-emacs-composer-goal-actions`
  (default on) shows them on the Goal Row, `C-c C-g a` (or `M-x
  dsh-emacs-goal-actions-toggle`) hides/shows them and re-renders the row —
  the `C-c C-g` keys work either way.
- **Workspace folding in the session list**: workspace and `Ungrouped` headers
  now show an expanded/collapsed indicator and accept `TAB` or `RET` to hide
  or reveal their session rows.  Fold state is local to the session-list
  buffer and survives realtime and manual refreshes.  The new option
  `dsh-emacs-workspaces-collapsed-by-default` controls the initial state, and
  `dsh-emacs-collapse-workspaces` / `dsh-emacs-expand-workspaces` change every
  group in the current list
  (rationale: postmortem/015).
- **Rendered @ references in the transcript are clickable links**: a user
  message that echoes a completed `@` mention shows it as an accent-colored,
  underlined link instead of raw text — a session mention
  (`@[label](dsh-session:…)`) renders as just `@label` (the opaque id never
  shown), and file/directory mentions (`@path`, `@"path with spaces"`) keep
  their path.  RET or mouse-1 on the link opens the reference: a session jumps
  to that session's chat buffer, a file opens it under the session's working
  directory.  The buffer still carries the raw canonical text, so the wire to
  the host is unchanged (rationale: postmortem/012).
- **A completed session mention is an atomic chip in the composer**: picking a
  session from the `@` menu keeps the short `@label` text in the input and
  wraps it as one unbreakable unit — the canonical `@[label](dsh-session:…)`
  text is stored on the chip and expanded back when the input is read for
  sending/history, so the wire is unchanged. Editing treats the chip as a
  whole: backspace removes the entire mention, and typing on it hops the
  cursor past it rather than splitting it (the buffer holds the short text
  itself, so there is no `display`-fold geometry). RET or mouse-1 on the chip
  jumps to that session's chat buffer. Completed file picks are equally atomic
  chips that keep their own `@path` (already the wire text) — a backspace
  removes the whole mention — and RET/mouse-1 opens the file
  (rationale: postmortem/013).
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

### Changed

- **Reduce CPU use while replies stream**: chat socket reads coalesce over
  50ms and the running animation shares pending text redraws. Following
  respects actual line heights and multiline drafts, preventing repeated
  scroll corrections. Transcript edits and history readers avoid redundant
  display work (rationale: postmortem/037).
- **Faster reference detection in long drafts**: `@` completion and its typing
  watcher inspect the buffer directly and copy only the active token,
  reducing allocation and garbage collection after large pastes
  (rationale: postmortem/030).
- **Faster table wrapping**: each cell character's display width is measured
  once and reused when choosing line breaks, preserving faces and existing
  Chinese/emoji layout (rationale: postmortem/030).
- **Smoother reply streaming**: the first text chunk appears immediately;
  subsequent text writes, Markdown and scrolling share a 50ms refresh.
  Pending text flushes at event boundaries, completion and disconnect.
  Markdown scan state now persists across refreshes, avoiding repeated
  scans of growing code blocks and tables (rationale: postmortem/029).
- **A streamed table renders when it ends, not row by row**: while rows are
  still arriving the table shows its raw `| … |` text, then renders in one
  pass at the next non-table line or the final message.  Unfinished code
  fences keep showing raw source as before
  (rationale: postmortem/028).
- **Model-picker prompt names the current provider too**: `C-c C-m` now prompts
  `Select model (current <provider>/<model>):` instead of only the model, so a
  model id that several providers offer is unambiguous at a glance.
- **Session-list keys for archive and workspace delete are clearer**: deleting a
  workspace is now `D` (matching the other workspace keys `W`/`R`/`M`, was `u`),
  and archiving a session moved to `d` (was `D`).
- **The session list no longer has a `/` text search**: narrowing by title/ID
  duplicated the workspace filter and the existing by-name session switchers,
  so `/` (and `dsh-emacs-session-search`) were removed.
- **The external-server launch token is remembered**: a token that successfully
  authenticates an external dsh server is saved into
  `dsh-emacs-server-auth-token`, so the next session reuses it instead of
  prompting again.  The stored token is validated (token→cookie exchange) on
  each connect; only when that fails (the server restarted and minted a new
  token) do you get the prompt again, pre-filled with the last value for easy
  editing.

### Fixed

- **IN/OUT face styling**: `dsh-emacs-tool-io-face` now declares bold weight
  separately from face inheritance, so custom renderers using it receive
  keyword colors and bold text correctly.

- **Deferred tables finish on Emacs 27–30**: width probes leave the chat
  buffer's edit counter unchanged, so idle formatting can publish its result
  and continue with later queued replies.
- **Chat teardown flushes pending text before releasing markers**: closing a
  buffer or changing its major mode no longer fails when text and Markdown
  are both waiting to render.
- **Large replies leave expensive Markdown work until idle**: text stays
  visible while long partial lines wait for a newline or completion, and
  large ready regions finish styling in an input-interruptible idle attempt.
  This includes final-only and history replies; the new
  `dsh-emacs-stream-markdown-limit` defaults to 8192 characters, or nil for
  synchronous formatting (rationale: postmortem/036).
- **Table measurements follow the destination font**: each render shares
  fresh metrics, so later renders no longer reuse stale font/scale values.
  Emacs 29+ height probes also avoid switching the displayed buffer
  (rationale: postmortem/035).
- **Table header styling stays above the reply base face**: inherited body
  styling no longer takes precedence over the table header
  (rationale: postmortem/036).
- **Table widths are no longer capped at the window edge**: long styled or
  non-ASCII cells use their full pixel width. On Emacs 31, width measurement
  also avoids temporary edits to the chat buffer; Emacs 27.1 remains supported
  (rationale: postmortem/034).
- **Less property work during reply refresh**: base-face application and
  font-lock mirroring share one traversal, and transcript protection is
  applied together. Code blocks retain the complete face in both display
  properties (rationale: postmortem/033).
- **Table width probes preserve draft and undo history**: temporary measurement
  text is removed even if pixel measurement fails; restoring the modified
  flag no longer explicitly refreshes the mode line
  (rationale: postmortem/033).
- **Long streamed paragraphs do less repeated styling**: emphasis matching
  skips text before the first delimiter, assistant base faces no longer
  accumulate on earlier text, and unchanged Markdown reuses its plain-paste
  handler without another property write (rationale: postmortem/032).
- **Large stream updates keep following the reply**: first chunks, queued
  text/reasoning bursts and corrected final replies preserve the windows
  following before the edit. Scrolling up while a flush is pending still
  stops following (rationale: postmortem/032).
- **Streaming refresh leaves stable reply text untouched**: the live Markdown
  frontier uses a marker instead of rewriting the reply's first character;
  unfinished blocks skip empty formatting passes (rationale: postmortem/031).
- **Wrapped replies follow the actual screen rows**: bottom detection and
  scroll positioning account for line wrapping, avoiding false bottom
  detection and incorrect pinning on long paragraphs
  (rationale: postmortem/031).

- **Streamed Markdown formats incrementally**: the live body scan advances
  over newly arrived lines only and leaves an unfinished fence or table to the
  final pass, so a growing block is no longer re-parsed on every chunk
  (rationale: postmortem/028).

- **Mode-line segments rebuild only when their inputs change**: the compact
  stats string and the pending-input indicator reuse their previous text while
  nothing they display changed, cutting redisplay work during streaming.

- **Mode-line redraws allocate less**: percent escaping preserves styled
  text without repeatedly copying the entire growing status string, reducing
  garbage collection during streaming and busy-animation redraws.

- **Thinking bursts redraw in batches**: the first delta appears immediately;
  later deltas are inserted together every 100ms, with one follow pass per
  batch. Event boundaries and disconnect flush pending text
  (rationale: postmortem/027).

- **Lower thinking-stream overhead**: build the Think SVG header only when
  the live block starts, and avoid resetting an unchanged window start on
  every streamed chunk. Text still appears immediately and bottom-following
  continues when the viewport needs to move.

- **Repeated card updates avoid transcript scans and redundant rendering**:
  validated buffer-local markers accelerate lookup, unchanged snapshots skip
  rendering, and title edits leave unchanged body styling alone. Cache handling
  preserves deletion, folding, undo and narrowed-buffer behavior
  (rationale: postmortem/026).

- **Fragment edits retain unchanged text**: updates replace only the middle
  span between a common prefix and suffix, preserving markers in retained
  text while refreshing styling and snapshot properties
  (rationale: postmortem/025).

- **Unchanged fragment updates preserve buffer positions**: identical
  rendered text and properties skip replacement, avoiding change hooks and
  interior-marker movement. Styling, hidden content and width changes
  still update normally.

- **Reading long history avoids unnecessary redraw work**: stream and
  fragment scroll-follow checks inspect at most one screen plus ten lines.
  Running command spinners repaint only when their header is visible in a
  window, resuming on the next tick after scrolling back.

- **Fragment IDs containing hyphens stay distinct**: updating or deleting
  one namespace/block pair cannot target another pair with the same joined
  spelling. Navigation and bulk folding use local text boundaries
  (rationale: postmortem/024).

- **Fragment titles stay readable in narrow windows**: main titles take
  priority over summaries, and bordered headers, bodies and footers share
  one width calculation (rationale: postmortem/023).
- **Custom title actions survive redraws**: embedded link/button keymaps
  remain active; other title text retains the default fold action
  (rationale: postmortem/023).
- **Failed card updates preserve the transcript**: rendering finishes before
  replacement, and insertion failures roll back text changes while reporting
  the original error (rationale: postmortem/023).

- **Fragment updates preserve complete cards**: shrinking or clearing a
  body keeps neighboring blocks intact, and folding restores the current
  labels, body text properties and card colors. Updates preserve the user's
  fold state (rationale: postmortem/022).

- **Busy submission no longer falls back to an optimistic send**: `C-c C-c`
  honors the host's cached running status even before the chat stream receives
  `turn/start`, so queued input does not render a premature user row.
  `C-u C-c C-c` likewise always sends nonempty input with steer semantics
  (rationale: postmortem/021).

- **Goal editing preserves source text**: accepting an unchanged objective
  keeps its original line breaks and whitespace instead of sending the folded
  display label.
- **Goal icons respect row width**: SVG icons reserve two columns and have a
  pixel-width cap, preventing their display width from exceeding the budget.

- **Streaming replies stay responsive during chunk bursts**: text appears
  immediately while Markdown updates coalesce over 50ms; unchanged final
  messages reuse the rendered body and stable text avoids repeated styling
  (rationale: postmortem/016).
- **Command animation timers are cleaned up reliably**: callbacks use their
  owning chat buffer, transcript resets cancel old timers, and hidden chats
  skip row repainting.
- **Quiet turns no longer trigger immediate reconnects**: the watchdog first
  sends a WebSocket ping and reconnects only if its matching pong times out.
  Batched frames and fragmented messages also avoid repeated tail copying
  (rationale: postmortem/016).

- **The mode-line shows the session's agent preset again**: the dsh 0.1.2 wire
  migration moved `agentPreset` from a top-level `session/list` row field to a
  session projection (`projections.values.agentPreset`), but the client kept
  reading only the old top-level field — so a real server row yielded no preset
  and the mode-line `preset` segment never appeared (model/effort already read
  their `modelSelection` projection).  The session protocol struct now parses
  the projection, keeping the top-level field only for the optimistic
  `session/create` cache row.  The preset is also re-fed on every session-cache
  refresh (`session/list` / workspace re-sync), the same cadence as the model
  and ctx segments, so it stays current instead of only being set on open.

- **Questions and approvals close when answered in another client**:
  receiving the waterfall's `cancel` frame now dismisses its active
  minibuffer prompt as well as removing queued copies, without sending a
  second answer or rejection.

- **`C-u C-c C-c` consistently steers a message**: while a turn is running,
  the prefix now selects `steer` regardless of whether the default busy-enter
  behavior is `queue`, `steer`, or `stop` (rationale: postmortem/014).

- **External server token entry can be retried**: after empty input, an
  incorrect token, or cancellation with `C-g`, running `dsh-emacs` again
  prompts for the launch token. Successful authentication still caches the
  cookie and skips further prompts.

- **A server-returned `@session` mention in the transcript links again**: dsh
  persists a user message that references another session with its canonical
  `@[label](dsh-session:…)` already collapsed to the readable `@label` (id
  stripped), and delivers the real `sessionId`/`label` in the immediately
  following `session-reference` recall context.  When that history was
  re-rendered (reopen / follow reseed), the readable `@label` fell through to
  the file-link matcher and had no session id, so the label rendered wrong and
  RET/mouse could not jump to the session.  The reseed renderer now pairs each
  referencing message with its adjacent recall event, re-links the readable
  `@label` as a real session chip (real id, still file-linking plain `@file`
  mentions), and RET/mouse jumps to that session.
- **`C-k` on a composer `@` chip removes the whole chip**: the chip editing
  guard used to hop the cursor to the chip's end before any edit, so a `C-k`
  that started on a chip killed only what followed it and the chip could never
  be deleted by `C-k`.  A `C-k` starting on a chip now pulls the cursor back to
  the chip's start and removes the whole chip (plus anything after it) as one
  atomic unit, matching the backspace behaviour.
- **`C-k` in the chat input keeps standard `kill-line` semantics**: `C-k`
  kills only from the cursor to the end of the input line, never the whole
  input ahead of the cursor and never the input area's structural separator
  newline.  (An earlier iteration cleared the whole input on every `C-k`,
  which was surprising; the structural-newline protection is kept, so `C-k`
  with the cursor at the very end is a no-op rather than dropping the cursor
  below the input line.)
- **A forward word/character delete at the input's end no longer drops the
  cursor below the input line**: `M-d`/`kill-word` (and region kills, which
  route through `kill-region`) or `C-d`/`delete-forward-char` with the cursor
  at the very end of the chat input used to delete the input area's structural
  separator newline — the same stranding the C-k guard already blocked, but
  reachable through any forward delete.  Forward deletions are now clipped at
  the input boundary, so the structural newline survives and the cursor stays
  on the input line.
- **The `@` menu reopens with the full list after a completed reference**:
  completing an `@` pick left the candidate cache pinned to the previous host
  query (which typing had narrowed, often to the single just-picked item), so
  the next bare `@` answered from that stale cache and the already-open corfu
  popup never widened it — you only got everyone back after deleting and
  retyping `@`.  A completed *file* reference was the worst case: its `@path`
  still parsed as an active `@` token, so the data-fetch watcher re-fetched
  that path and re-narrowed the cache the moment your cursor sat next to it.
  Inserting a completed reference now clears the fetch state, and a completed
  reference rendered as a chip is no longer treated as a fresh active token —
  so the next `@` re-fetches the full list.
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
