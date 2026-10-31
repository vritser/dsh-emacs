# UI Styling

Shared faces and palette defaults live in `dsh-emacs-faces.el`. Fragment
faces live in `dsh-emacs-ui.el`, and active Markdown faces live in
`dsh-emacs-markdown.el`. Faces use light/dark specs or inherit Emacs theme
faces; some surfaces have explicit backgrounds.

## Design language

The visual language mirrors the dsh web UI — tool rows reuse its
`ToolRow` / `ioCard` semantics; in `full` they also reuse its exact SVG icons.
The session list and context meter follow dsh-web conventions (the underlying
rendering/folding machinery builds on agent-shell, the mode-line stats on
pi-mono):

- **User messages**: left-aligned text with a thin left rail and no background;
  one blank line before and after the message. The rail continues across
  explicit newlines and wrapped lines; the editable input keeps its `❯` prompt
- **Assistant messages**: frameless Markdown bodies with transcript spacing
- **Thinking blocks**: collapsible `<details>`-style items, folded by default,
  shown with dsh web's Think sparkle SVG (IconThink) in `full` or one dot in
  `simple`, plus "Think" and a first-sentence preview (truncated with `...`
  when too long)
- **Tool calls**: collapsible tool rows modeled on dsh web, with a variant icon
  in `full` (one state-colored dot in `simple`) and, in `full`, the status tint
  (pending=orange, success=green, error=red); bash/pwsh rows
  expand into a terminal card (`$` prompt + output, error/interrupt footer),
  read rows into a line-numbered file card, write/edit rows into a diff card,
  `ask_user_question` rows into their question/answer record, and every other
  variant into an IN/OUT section
- **Execution events**: retry/failed/cancelled reply cards, `Model error` and
  automatic compaction failures share a small status dot, inspired by dsh
  web's `StateDot`. Retry uses the running face (orange), failure the error
  face (red), and cancellation/unknown the timestamp face (grey). Explicit titles
  distinguish outcomes even without color. Headers keep the bold title face
  (the muted event-row face in `simple`) and compact spacing; metadata uses the
  muted timestamp face. `Model error`
  places its error code on the right and keeps the reason expanded initially.
  Normal automatic compaction summaries retain their terminal-style icon in
  `full` style.
- **Mode-line stats**: a compact status section spliced into the mode line (model, effort, preset,
  permission, context%; cwd, branch, tokens, provider and cost are opt-in)
- **Session list**: card view showing session title, working directory, branch,
  and last activity time

`dsh-emacs-render-style` chooses between these icons and a single-dot
`simple` style for every transcript event row. In `simple`, color is reserved
for the leading dot: titles and summaries use the muted
`dsh-emacs-event-row-face` (labels add bold) and status text stays muted while
tool dots follow state — purple (`dsh-emacs-tool-icon-face`) pending, green
(`dsh-emacs-tool-success-face`) success, red (`dsh-emacs-tool-error-face`)
error, and `dsh-emacs-tool-stopped-face` stopped. The live Think dot uses
`dsh-emacs-thinking-face` and settles to the same muted grey when complete;
todo, goal and turn-trigger dots use `dsh-emacs-tool-icon-face`,
`dsh-emacs-composer-goal-face` and `dsh-emacs-meta-face`. On non-graphical
frames and in Emacs builds without SVG support there is no emoji fallback:
`full` draws ordinary tool rows as one dot in the tool accent, while goal
tools (the `◎` glyph) and the `✶` Think, `▤` todo and `➤` turn-trigger rows
keep their text glyphs. The option restyles newly rendered rows only.

## User/Assistant messages

| Face | Description |
|---|---|
| `dsh-emacs-input-prompt-face` | Editable input prompt `❯` (accent color) |
| `dsh-emacs-user-block-face` | User message body (no background or typography override) |
| `dsh-emacs-user-border-face` | Three-pixel teal user rail on graphical displays |
| `dsh-emacs-assistant-body-face` | Assistant message body (no background) |
| `dsh-emacs-reply-meta-face` | Readable grey completion summaries and reply footers; theme font size and weight |

User rails use display prefixes, preserving message text and navigation.
Graphical displays draw a three-pixel teal rail (`#4f9eaf` in dark themes,
`#348694` in light themes), followed by a two-column gap. The first visual
line gets a little extra headroom, and the last line requests a quarter-line
gap below it; interior lines retain their normal spacing. This adds no text
or font overrides. Terminals use a muted `│` glyph and ordinary line spacing.
Historical user messages contain only their authored text; `❯` belongs to
the editable input. Copying and yanking a user message preserves its text
without carrying the rail, spacing or transcript identity into the destination.

### Slash gestures in user messages

A `/name` token a user sent is **accented** when one of the session's catalogs
confirms it: a host command is drawn as a blue bordered chip
(`dsh-emacs-slash-command-face`), a skill as plain violet text with **no
border** (`dsh-emacs-slash-skill-face`) — a skill is a prompt gesture, not
something the host executes, so the box is reserved for commands and the two
kinds stay distinguishable. Either way the catalog description rides the
`help-echo` tooltip, and the token text itself is never changed. Skill names
may start with a digit, so `/3d-review` is accented too when confirmed.

Classification is catalog-confirmed, never shape-alone: `/usr/bin`, `5/8`,
`http://…`, `/name,` and unknown names stay plain text, the same rule dsh web's
user-text projection applies. Reading the catalogs never fetches, so a message
rendered before its catalog landed stays plain — until the host's hidden
`skill-invocation` copy for that gesture arrives, which is authoritative
evidence and accents it retroactively (this is what styles replayed history
reliably, whichever of the snapshot and the prefetch wins the race). If a
command and skill share a name, that evidence replaces the initial command
styling with the skill face and tooltip. Repeated evidence preserves an
existing skill tooltip, even after the catalog is invalidated.

Colors come from `dsh-emacs-color-slash-command` / `-slash-command-dark` and
`dsh-emacs-color-slash-skill` / `-slash-skill-dark`.

## Tool calls (dsh web style)

| Face | Description |
|---|---|
| `dsh-emacs-tool-pending-face` | Tool running (orange text, no background) |
| `dsh-emacs-tool-success-face` | Tool succeeded (green text, no background) |
| `dsh-emacs-tool-error-face` | Tool failed (red text, no background) |
| `dsh-emacs-tool-stopped-face` | Tool interrupted (inherits `font-lock-keyword-face`) |
| `dsh-emacs-tool-icon-face` | Tool variant icon (purple, mimicking dsh web's tool purple #a78bfa) |
| `dsh-emacs-tool-bash-prompt-face` | Bash terminal card `$` prompt glyph (same tool-purple accent) |
| `dsh-emacs-tool-title-face` | Tool card title |
| `dsh-emacs-event-row-face` | `simple` event-row title/summary text and completed Think dot (muted grey, normal; labels add bold) |
| `dsh-emacs-tool-io-face` | ioCard `IN` / `OUT` section labels |
| `dsh-emacs-tool-meta-face` | Muted card body text: read line numbers, the read window footer, diff gap and totals lines |
| `dsh-emacs-tool-diff-path-face` | Diff card hunk path |
| `dsh-emacs-tool-diff-add-face` | Diff card added line (`+ ` prefix) |
| `dsh-emacs-tool-diff-del-face` | Diff card removed line (`- ` prefix) |

State faces tint the **header row only** — variant icon/title plus the
summary/suffix — for every tool variant, bash included; an expanded body never
inherits them.  A card body carries its own faces instead (`$` prompt,
gutter numbers, diff lines, muted footers), and the ioCard body keeps `IN`/`OUT`
labels in `dsh-emacs-tool-io-face`, its divider in `dsh-emacs-divider-face`,
and its args/output lines unstyled (`dsh-emacs-tool-output-face` is unused).

Tool rows mimic dsh web's `ToolRow`: each tool call renders as one row of
**collapsible** cards, with a header of `variant icon + title + summary`;
expanding reveals the call body. Each card folds independently. In `full`,
icons correspond one-to-one with dsh web's
`VARIANT_ICONS`:

| Variant | Full-style icon | Corresponding dsh web icon |
|---|---|---|
| bash (bash/pwsh) | terminal SVG | IconApiOutline14 (terminal) |
| read (read/web_fetch/cordis_*_inspect) | browse SVG | IconBrowseOutline16 (browse) |
| search (grep/glob) | magnifier SVG | IconSearchOutline16 (magnifier) |
| web (web_search) | globe SVG | IconGlobeOutline14 (globe) |
| write | pencil SVG | IconEditOutline16 (pencil) |
| edit | pencil SVG | IconEditOutline16 (pencil) |
| code (run_code) | code-brackets SVG | IconCodeOutline16 (code brackets) |
| question (ask_user_question) | question-mark SVG | IconQuestionOutline14 (question mark) |
| others (cordis_run, etc.) | sparkle SVG | IconSparkle16 (sparkle) |

A row with a known variant shows a humanized tool name (`grep` → `Grep`), or
the `dsh-emacs-tool-titles` override when one is configured.  A variant-less
tool with no curated title instead takes dsh web's generic header
(`Tool Call` + wire tool name, see the summary rules below), and its
arguments appear only in the expanded card.

Status semantics align with dsh web's `leadingFor`/`stateStatus` in `full`:

- **Running**: keeps the variant icon with purple highlighting (no spinner animation)
- **Success** (exit 0): keeps the variant icon and prints no status line on
  any card — the header's green tint already says the call settled, and dsh
  web's exit-0 pill never renders
- **Failure**: leading switches to the red status dot `●`; the body shows
  `✗ exit N`, `✗ signal …`, or `✗ failed` according to the result
- **Interrupted**: leading switches to `◐` in the stopped face; the body
  shows `⏸ interrupted`

In `simple`, every state uses the leading dot and the row chrome is muted.
Failure uses a red `●`; the interrupted state uses a stopped-face `●` instead
of `full`'s `◐`. Execution-status dots are unchanged.

Expanded bodies mirror dsh web's keyed toolviews.  Every one of them is drawn
on the transcript background — no card surface band: a card's own faces (the
`$` prompt, gutter numbers, the `-`/`+` diff colors) already carry its
structure, and padding every row to the box width would inflate the transcript
for no added meaning (see
[045](../postmortem/045-read-and-diff-tool-cards.md)).

- **bash/pwsh rows expand into a terminal card** (dsh web `BashRow` +
  `TerminalBlock`): the card body carries a single `$` prompt row for the
  command (prompt glyph in the tool-purple `dsh-emacs-tool-bash-prompt-face`;
  a multi-line or over-long command is flattened to one line and ellipsized —
  the full raw command stays available as the row's tooltip), a thin `─`
  divider where the output starts, and the output below — dsh's shell renderer
  appends the exit status to the result text (`[exit code: N]` /
  `[killed by signal: X]`), and that trailing marker is parsed into the row
  state (web `parseExitStatus`) and removed, so it is never shown twice.  A
  failure or interrupt appends a state-colored footer (`✗ exit N`,
  `✗ signal …`, `⏸ interrupted`); a clean exit ends bare at the output.
  While the call is still running the card shows only the prompt row.  The
  faces are baked onto the card text, so fold/unfold keeps the styling; the
  row's state tint covers only the header line, never the card.
- **`read` rows expand into a line-numbered file card** (dsh web `ReadBlock`):
  the file's lines with their numbers right-aligned in a muted gutter
  (`dsh-emacs-tool-meta-face`).  When the call read only a window of a larger
  file, a muted footer reports `Showing N of M lines` (plus the Host-reported
  language).  Neither the raw `<path>/<type>/<content>` envelope nor the
  argument JSON is repeated: the row header already shows the path.  The card
  needs the settled result's `meta` (path, offset, lines, totalLines) **and** a
  `<type>file</type>` envelope, and is drawn only for a successful call.  Line
  numbers must increase within the range from `offset` through `totalLines`.
  A directory or image read, a call that failed or was interrupted, a nonzero
  exit or signal, a truncated payload, or a tool sharing the icon without
  being `read` (`web_fetch`, `cordis_*_inspect`) keeps the generic ioCard.
- **`write`/`edit` rows expand into a diff card** (dsh web `DiffBlock`): a bold
  path row per file (an `⋯` gap row when a later hunk stays in the same file),
  removed lines as `- text` in `dsh-emacs-tool-diff-del-face`, added lines as
  `+ text` in `dsh-emacs-tool-diff-add-face`, and a muted
  `└ +N -M · K file(s)` footer.  While the call runs the diff is the one the
  arguments intend (so an `edit` previews immediately, like the bash prompt
  row); once settled the applied `meta.diffs` win.  A `write` whose result
  records no diff keeps its whole-file diff; an `edit` whose result records
  none (it can match nothing), a call that did not succeed (a failure, an
  `interrupted` abort, a nonzero exit, or a signal), or unusable arguments
  keep the generic ioCard, preserving the diagnostic output.
  Matching lines appear once as plain context, aligned with the text after
  the `- ` / `+ ` gutter; only changed rows count in the totals. Literal
  signs in file contents are preserved. Common leading and trailing lines
  are matched first, then the remaining lines are aligned in order. For a
  very large replacement (more than 262144 comparison-table cells), a muted
  `⋯ Large replacement: middle shown without alignment` row introduces the
  whole old/new middle, and totals count those displayed replacement rows.
  This bound keeps comparison work limited on the live event path.
- **`present` rows expand into a declared-files card** (dsh web `PresentRow`):
  the header summary is the call's `files[].path` list, comma-joined under the
  `Present files` title, and the body is the result text (`Presented <path>`
  lines, or the Host's failure message) as indented rows.  The argument JSON
  is never repeated.  The turn-tail Deliverables row still lists the same
  paths with their descriptions and clickable links.
- **Background-job rows expand into a job card** (this client's own model; web
  keeps these generic): a `job_output` row shows the job's output as body rows
  and renders the Host's trailing `[status: …]` line as a footer in the face
  matching the job status — success for `completed`, error for `failed`,
  stopped for `killed`/`stopping`, pending for `running`.  A `completed`
  footer with a nonzero `exit code` detail uses the error face: the job ended,
  but its command failed.  `job_list` renders one row per job
  (`id [kind] status — label`) with the status token colored by its lifecycle
  state and a label that spans lines indented under its row; `job_kill`
  renders its one-line acknowledgement.  The argument JSON is never repeated:
  `job_output` and `job_kill` headers explicitly use `job_id` as their summary,
  independent of argument order.  The titles are `Job Output`, `Jobs` and
  `Kill Job`.  A `job_output` without a status line (a
  malformed or failed read) keeps the generic ioCard.
- **`exit_plan_mode` submissions appear as document cards**: the plan's heading
  is a clickable title, and `RET` opens the complete rendered Markdown in a
  read-only buffer. Settlement retains the link; an unsuccessful review also
  keeps the host's explanation. Replay restores the same document without
  reopening review automatically. The host's live plan-review question opens
  the document with explicit approval and change-request actions; see
  [Plan review](slash-commands.md#plan-review).
- **`ask_user_question` rows expand into the decision record** (dsh web
  `AskQuestionCard` plus the options its composer showed): one block per
  question — its `header` chip in the accent face and its prompt, then the
  options under the minibuffer reader's own numbering, the chosen ones checked
  (`✓ `) with the label in the accent face, each description hanging at the
  label column in `dsh-emacs-meta-face`, and a closing `→ <free text>` answer or
  `Not answered` once that question settled.  The collapsed row states the
  outcome instead (`waiting`, `2/3 answered`, `cancelled`, `interrupted`).  A
  question set the user dismissed (`ASK_CANCELLED`) settles and an abandoned
  one (`ASK_ABORTED`) reads as interrupted rather than a failed call, and the
  body then opens with dsh web's explanation sentence instead of a status
  line; the argument and answer JSON are never shown, and a call whose
  arguments name no usable question keeps the generic ioCard.
- Every other variant keeps a dsh web-style **ioCard**: one aligned block in
  which the `IN` (arguments) and `OUT` (result) labels share a label column
  and their text starts in a shared text column.  The `IN` value reads as a
  **single row** — a pretty-printed argument object is flattened, and one
  wider than the card is ellipsized with the full value in its tooltip, the
  treatment the bash card gives a long command — while the `OUT` result keeps
  its own lines, hanging at the text column.  A thin `─` rule sized to the
  content separates the two sections, and the whole block is indented like
  the bash card so rows of either kind keep one left edge.  A failed or
  interrupted call prints its status line above the block (`✗ exit N`,
  `✗ failed`, `⏸ interrupted`); a clean success prints none.  A
  zero-argument call (`{}`) drops the empty `IN` section instead of printing
  a bare pair of braces.

The collapsed state is a **compact single line** (no ellipsis placeholders, no
extra blank lines), and adjacent tool rows stack tightly; pressing `RET` on a
tool row expands/collapses the body (the body is stored inside the block, so
expanding always restores it).

Automatic compaction summaries use a folded **Automatic compaction** row
with the existing bash/terminal icon in `full` (one dot in `simple` or on a
non-graphical display) and the tool title, muted in `simple`. Like tool rows,
the header has no extra blank padding; covered-item counts and the approximate
old-context token estimate remain muted. `RET` or a click expands
the Markdown summary, and the original conversation stays visible. The header
has no success tint or success mark: the summary arrives before checkpoint
application, which can still fail afterward. Raw model output and the
checkpoint body stay hidden. Manual `/compact` retains its command card,
and running compaction keeps its existing mode-line presentation. No new icon,
face or option is added; see [record 116](../postmortem/116-compaction-tool-row.md).
Within a settled turn, the summary joins adjacent thinking/tool cards in one
activity group rather than splitting them. Expand the activity first to see
its compaction row; compaction itself contributes no tool category count.

Standalone model and automatic compaction errors use the same compact spacing
as attempt cards, with a red status dot and no extra blank padding. Their
explanations start expanded; model error codes appear as muted metadata.
The reply footer supplies its own spacing after an error row.
See [record 121](../postmortem/121-single-attempt-feedback.md).

Summary key precedence matches dsh web's `SUMMARY_KEYS`, keyed by tool name
first and by variant second: bash→`description|command`,
read→`path|file_path|url`, search→`query|pattern|url`,
write/edit→`path|file_path`, code→`description`,
job_output/job_kill→`job_id`.  A `present` row is different again: it names
the call's declared `files[].path` list rather than one argument value, and an
`ask_user_question` row carries its question set's outcome — `waiting` while
the call runs, `A/B answered` once the answers are known, `cancelled` or
`interrupted` for the two user-driven outcomes its error codes name.
A **variant-less** tool is titled `Tool Call` and carries its wire name as the
summary instead: `Tool Call · <tool name>`.  Its arguments are deliberately
absent from the header — the expanded card already shows them in the `IN`
row, so repeating the raw JSON on the collapsed line would only crowd it.  A
curated `dsh-emacs-tool-titles` entry still owns its row, so the `present`
and job headers above keep their documented titles and summaries.  A row that
still has no summary — a curated title with unusable arguments, or a variant
row called with none — falls back to the first line of its result, capped by
`dsh-emacs-max-tool-result-chars` (with a trailing `…` when the result had
more lines), rather than showing a bare title.

## Thinking blocks

| Face | Description |
|---|---|
| `dsh-emacs-thinking-face` | Live Think icon/dot; in `full`, also the "Think" label (bold accent) |
| `dsh-emacs-thinking-body-face` | Reasoning preview and expanded body (muted) |

The collapsed row shows a preview of the first thinking sentence on the right
(`dsh-emacs-thinking-preview-max` controls the maximum length; longer content is
truncated with `...`; set to 0 to disable). In `full`, the amber accent covers
the icon and the "Think" label. In `simple`, the live dot is amber while
thinking streams, then settles to the muted `dsh-emacs-event-row-face` when
the fragment is complete; the label is muted throughout. The preview and the
expanded thinking body use the muted body face at normal weight in both styles.

## Fragment styling for extensions

Fragment snapshots accept two region-scoped faces: `:header-face` for the
header row and `:body-face` for the expanded body — there is no whole-block
face.  Within the header, the bold `dsh-emacs-ui-label-face` is the title face
(left label only); the right label is a summary and takes its own or the header
face.  Both merge after embedded text faces on every update and fold/unfold,
so body links and icon fonts survive.  Supply the complete snapshot on update;
nil clears prior content and styling.
See the [fragment API](architecture.md#transcript-fragments-dsh-emacs-uiel)
for the update contract.

Titles retain their own link/button keymaps; the remaining title text uses
RET/click to fold. The main title is fitted first, then the summary uses any
remaining space. Headers and bordered bodies/footers share one width measured
from the displaying window, including narrow windows. Long body lines retain
their content. Layout is recomputed when a card updates or folds.

Tool cards retain their independent folds inside the completed task
compact **Completed in 4m 10s** disclosure using theme typography, directly
above the answer without a separator. On graphical displays its newline
requests half a line of space below the summary, leaving larger user-defined
line spacing intact. Terminals retain ordinary line spacing. Summary and footer
text use `dsh-emacs-reply-meta-face` at normal weight, inheriting the theme's
font size from `shadow`; the footer defaults to Copy, Fork and
tokens, with `duration` still available as an opt-in item. All footer items
stay together on the left in configured order, separated by dots.
The disclosure shows **Completed** when full turn timestamps are
unavailable, rather than estimating duration from a partial
page. Its small, rounded-stroke SVG chevron uses the summary face color
and points up when expanded, down when collapsed. Terminal/non-SVG displays
retain a character fallback. The button hides or reveals the
original work region, not a copied card body; final answers remain outside it.
The summary row keeps the displaying window's truncation instead of widening
a narrow row. Failed rounds use **Failed**, while canceled and interrupted
rounds use **Stopped**, matching Web's process titles without elapsed time.
Those status rows have no chevron and cannot hide the whole turn. The same
applies when input arrives mid-turn. Instead, thinking/tool cards between
visible replies fold into independent summaries such as **Read files and ran
commands**. Each summary has its own chevron; replies and user spacing remain
outside it. Successful turns without mid-turn input can additionally fold the
whole process, even when no final answer exists. Terminal errors stay visible.
`dsh-emacs-fold-work-details` controls both levels. See
[Web folding rules](web-folding.md) for the audited defaults and scope.

## Mode-line stats

| Face | Description |
|---|---|
| `dsh-emacs-modeline-face` | The entire stats strip |
| `dsh-emacs-modeline-running-face` | Deep diving caption and elapsed clock |
| `dsh-emacs-modeline-running-highlight-face` | Peak color of the caption's gentle sweep |
| `dsh-emacs-modeline-compacting-face` | Teal Compacting caption and elapsed clock |
| `dsh-emacs-modeline-compacting-highlight-face` | Peak color of the Compacting sweep |
| `dsh-emacs-modeline-separator-face` | Separator between stats (default: one space) |
| `dsh-emacs-modeline-token-face` | Token count |
| `dsh-emacs-modeline-cost-face` | Cost |
| `dsh-emacs-modeline-ctx-ok-face` | Context < 50% (green) |
| `dsh-emacs-modeline-ctx-warn-face` | Context ≥ 50% and < 80% (yellow) |
| `dsh-emacs-modeline-ctx-crit-face` | Context ≥ 80% (red) |

## Session list

Idle dots (`dsh-emacs-status-idle-face`, also the `New Session` placeholder)
and muted text (`dsh-emacs-muted-face`: timestamps, reply footers, deliverable
descriptions, subagent error notices) inherit `shadow` (grey in the default
Emacs theme). Running dots (`dsh-emacs-status-running-face`) are orange.

| Face | Description |
|---|---|
| `dsh-emacs-session-title-face` | Session title |
| `dsh-emacs-session-cwd-face` | Working directory |
| `dsh-emacs-session-branch-face` | Git branch |
| `dsh-emacs-session-model-face` | Model name |
| `dsh-emacs-session-id-face` | Session ID |
| `dsh-emacs-session-status-face` | Status indicator |

## Miscellaneous

| Face | Description |
|---|---|
| `dsh-emacs-divider-face` | Divider line |
| `dsh-emacs-timestamp-face` | Timestamp |
| `dsh-emacs-meta-face` | Meta information and ask option descriptions |
| `dsh-emacs-error-face` | Error message |
| `dsh-emacs-running-face` | Generating status |
| `dsh-emacs-input-prompt-face` | Input prompt "❯" |
| `dsh-emacs-composer-goal-face` | Goal dartboard icon tint (Goal Row, round notice, goal tool cards; dartboard SVG, `currentColor`; tool purple) |
| `dsh-emacs-composer-goal-label-face` | Goal Row leading status label (semi-bold) |
| `dsh-emacs-composer-goal-body-face` | Goal Row objective (muted, upright) |
| `dsh-emacs-composer-goal-action-face` | Goal Row muted action SVG tint (dsh-web pause/resume/edit/clear) |
| `dsh-emacs-composer-next-face` | Next Message row queue glyph tint (dsh-web `IconQueueOutlineRegular`; queue amber) |
| `dsh-emacs-composer-next-body-face` | Next Message row preview (muted, upright) |
| `dsh-emacs-composer-next-action-face` | Next Message row up-arrow steer cell (muted like the Goal Row actions) |
| `dsh-emacs-accent-face` | Accent color (badges, headings) |

The Composer Goal Row uses the buffer background, like Next Message and the
editable `❯` line. It places the status before the objective and a compact
action cluster one space after it, with one space between icons and no trailing
stretch padding. While an operation
is pending its progress (for example, “Pausing…”) replaces the status label
and action icons are hidden. In narrow windows it drops
inline actions to preserve objective and status space; the `C-c C-g` commands
remain available. Action tooltips show readable labels and keyboard shortcuts.
Use `C-c C-g ?` for the full objective and blocked reason, also available in
the objective tooltip. SVG icons occupy at most two columns of pixel space.

The Next Message row sits above the Goal Row and above `❯`, built like that
row: dsh web's queue glyph (a chat bubble with two text lines,
`IconQueueOutlineRegular`) tinted with `dsh-emacs-composer-next-face` — the
queue amber `dsh-emacs-color-queue` / `dsh-emacs-color-queue-dark` — then the
folded preview in `dsh-emacs-composer-next-body-face`,
the muted upright tier the goal objective uses. The row carries **no**
background band, like the Goal Row and editable `❯` line; its identity is
the tinted glyph and muted text.
One space after the preview text sits a compact action cluster, one
space apart, all tinted with `dsh-emacs-composer-next-action-face` (text
fallbacks when Emacs lacks SVG): the up arrow `IconSendOutlineRegular` (RET or
a click sends the previewed message now — steering the running turn, or
re-submitting text-only items while idle, the verb RET runs in `C-c C-q`), then `✎` edit
(`IconEditOutline16`, offered only for a message whose content is all text,
because the edit RPC answers with text blocks) and `✕` delete
\(`IconTrashOutline16`), which run the manager's `e`/`d` verbs. Local previews
show no cells until their server queue ID arrives. Send-now refuses attachments
while idle, preserving the original queued item. Each cell names
itself in a tooltip and carries a hover highlight. The preview truncates to
leave the cluster its columns, and a window that runs out of room drops cells
from the tail — delete, then edit, then the arrow, always keeping eight preview
columns. The row fits the narrowest window displaying the chat, and its full
text is available in the tooltip; the whole queue stays under `C-c C-q`.
Without SVG support the leading glyph falls back to `≡ `; hiding or completing
a goal does not hide Next Message. Both rows share Composer's read-only
region.

## Markdown rendering

The first reply chunk is inserted immediately. Subsequent reply insertion,
Markdown formatting and viewport following are coalesced over 50ms using
one pending timer per chat. Event boundaries, final messages and disconnect
flush pending text synchronously. Hidden command rows do not repaint for
spinner animation. See [decision record 029](../postmortem/029-stream-write-batching.md).
Live thinking also shows its first delta immediately, then batches subsequent
text over 100ms; event boundaries flush it immediately.
Chat socket reads also coalesce over 50ms; received events retain their order.
The running indicator shares pending text redraws. Clearing the transcript's
modified flag does not itself invalidate the mode line. Reading windows are
excluded before screen-row scans. Native recentering keeps each window's draft
point visible with line spacing and variable face heights, avoiding competing
scroll corrections. Unselected chat windows retain their own editing positions,
and long drafts still follow when the prompt is above the viewport.
See [037](../postmortem/037-streaming-display-cpu.md) for the original geometry fix.

The live Markdown watermark is a stream-owned marker; advancing it does not
modify the reply's first character. When no text is ready to format, the
formatter skips its passes entirely. Bottom detection and scroll pinning use
each window's screen rows, including line wrapping, while preserving each
window's input cursor. See [031](../postmortem/031-stream-frontier-and-screen-rows.md).

Large first chunks, queued reply/thinking bursts and corrected replies keep
the windows that were following immediately before the edit pinned afterward.
The check happens when the text is written, so scrolling up while a timer is
pending still takes effect. Partial-line formatting keeps one assistant base
face on each run and avoids emphasis searches before the first delimiter;
plain-paste behavior uses a reusable handler. See
[032](../postmortem/032-partial-line-styling-and-burst-follow.md).

`dsh-emacs-markdown-replace-markup` accepts an optional `:base-face` symbol.
Its final pass keeps one copy of that face below all Markdown faces, then
mirrors the complete face to `font-lock-face`. The assistant renderer supplies
its body face here,
so block replacements and inline text share the same layering order.
Pixel width probes measure the full string, including content wider than the
window. Emacs 31 uses `string-pixel-width` with the destination buffer's face
remapping and the destination window selected during measurement; this avoids
editing the chat buffer. Older Emacs versions insert the string into a
temporary buffer with the destination's font settings. Emacs 29–30 measure
that buffer without displaying it; Emacs 27–28 temporarily display it under
a saved window configuration, restored even on error. No path changes the
chat buffer's edit counter, so deferred formatting can publish its result. See
[033](../postmortem/033-final-face-pass-and-pixel-probes.md) and
[034](../postmortem/034-full-table-pixel-widths.md).

Table metrics are reused only during one render. New renders use current
destination fonts, text scaling and remapping; they cannot inherit a prior
table's cached values. On Emacs 29+, height measurement uses an undisplayed
buffer with that font context, avoiding window-buffer switches. Existing
rendered tables are not automatically reflowed when fonts or window widths
change. See [035](../postmortem/035-table-render-metrics.md).

Oversized assistant Markdown uses the renderer's idle queue. Text and event
protection appear immediately; complete styling replaces it after an
input-interruptible preparation attempt. The default 8192-character threshold
and synchronous override are described in
[customization](customization.md#markdown-responsiveness). See
[036](../postmortem/036-bounded-stream-markdown.md).

An unfinished code fence or table stays raw source until it ends: the
formatter stops at the block's start and reformats only the text before it, so
a growing block is never re-parsed chunk by chunk. A table renders once — at
the next non-table line or the final message — and a fence when its closing
fence arrives.

The Markdown renderer is modeled on `agent-shell-markdown` and uses
replacement-style rendering: Markdown marker characters are removed and face
properties are kept on the visible text. It supports bold, italic,
strikethrough, headings, inline code, code blocks, links, images, horizontal
rules, blockquotes, and aligned tables.

Table wrapping measures each character's face-aware width once per cell and
reuses it for fit checks and word boundaries. The measurements live only for
that wrap call, so later renders use the current text and font settings.

| Face | Description |
|---|---|
| `dsh-emacs-markdown-bold` | Bold |
| `dsh-emacs-markdown-italic` | Italic |
| `dsh-emacs-markdown-strikethrough` | Strikethrough |
| `dsh-emacs-markdown-header-1` … `-6` | Heading levels 1 through 6 |
| `dsh-emacs-markdown-inline-code` | Inline code |
| `dsh-emacs-markdown-source-block` | Code block background |
| `dsh-emacs-markdown-source-block-language` | Code block language label |
| `dsh-emacs-markdown-link` | Link text |
| `dsh-emacs-markdown-blockquote` | Blockquote |
| `dsh-emacs-markdown-table-header` | Table header |
| `dsh-emacs-markdown-table-border` | Table border |
| `dsh-emacs-markdown-table-zebra` | Table zebra striping |

Customize the faces above for transcript Markdown; they are defined in
`dsh-emacs-markdown.el`.

## Example: customize the tool card colors

Use `custom-set-faces` or `M-x customize-face` to change loaded faces.
The `dsh-emacs-color-*` variables supply defaults when the face definitions
first load; setting those variables afterward does not recompute the faces.
This example adds a success background; the default has none.

```elisp
(custom-set-faces
 '(dsh-emacs-tool-success-face
   ((((background light)) :foreground "#1a7f37" :background "#e6f7ec")
    (((background dark))  :foreground "#5dd879" :background "#172821"))))
```
