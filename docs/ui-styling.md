# UI Styling

Shared faces and palette defaults live in `dsh-emacs-faces.el`. Fragment
faces live in `dsh-emacs-ui.el`, and active Markdown faces live in
`dsh-emacs-markdown.el`. Faces use light/dark specs or inherit Emacs theme
faces; some surfaces have explicit backgrounds.

## Design language

The visual language mirrors the dsh web UI — tool rows reuse its exact SVG
icons and `ToolRow` / `ioCard` semantics, and the session list and context
meter follow dsh-web conventions (the underlying rendering/folding machinery
builds on agent-shell, the mode-line stats on pi-mono):

- **User messages**: `❯` prompt followed by text, with blank-line spacing and
  no background by default
- **Assistant messages**: frameless design, pure Markdown rendering, separated
  by dividers
- **Thinking blocks**: collapsible `<details>`-style items, folded by default,
  shown with dsh web's Think icon (IconThink) + "Think" + a first-sentence
  preview (truncated with `...` when too long)
- **Tool calls**: collapsible tool rows modeled on dsh web, with a variant icon
  + status color (pending=orange, success=green, error=red); bash/pwsh rows
  expand into a terminal card (`$` prompt + output, error/interrupt footer),
  other variants into separate IN/OUT sections
- **Mode-line stats**: a compact status section spliced into the mode line (cwd, git branch, model,
  tokens, context%, and cost)
- **Session list**: card view showing session title, working directory, branch,
  and last activity time

## User/Assistant messages

| Face | Description |
|---|---|
| `dsh-emacs-input-prompt-face` | User message and input prompt `❯` (accent color) |
| `dsh-emacs-user-block-face` | User message body (no background by default) |
| `dsh-emacs-assistant-body-face` | Assistant message body (no background) |

## Tool calls (dsh web style)

| Face | Description |
|---|---|
| `dsh-emacs-tool-pending-face` | Tool running (orange text, no background) |
| `dsh-emacs-tool-success-face` | Tool succeeded (green text, no background) |
| `dsh-emacs-tool-error-face` | Tool failed (red text, no background) |
| `dsh-emacs-tool-stopped-face` | Tool interrupted (inherits `font-lock-keyword-face`) |
| `dsh-emacs-tool-icon-face` | Tool variant icon (purple, mimicking dsh web's tool purple #a78bfa) |
| `dsh-emacs-tool-bash-prompt-face` | Bash terminal card `$` prompt glyph (same tool-purple accent) |
| `dsh-emacs-tool-bash-panel-face` | Bash terminal card surface (the expanded card's background band, mirroring the code-block panel look) |
| `dsh-emacs-tool-title-face` | Tool card title |

State faces apply to the header of a bash/pwsh card and to the whole fragment
for other variants. IN/OUT labels and output inherit the fragment's state
face; the renderer does not apply `dsh-emacs-tool-io-face`,
`dsh-emacs-tool-output-face`, or `dsh-emacs-tool-running-face` separately.

Tool rows mimic dsh web's `ToolRow`: each tool call renders as one row of
**collapsible** cards, with a header of `variant icon + title + summary`;
expanding reveals the call body.  Icons correspond one-to-one with dsh web's
`VARIANT_ICONS`:

| Variant | Icon | Corresponding dsh web icon |
|---|---|---|
| bash (bash/pwsh) | 💻 | IconApiOutline14 (terminal) |
| read (read/web_fetch/cordis_*_inspect) | 📖 | IconBrowseOutline16 (browse) |
| search (web_search/grep/glob) | 🔍 | IconSearchOutline16 (magnifier) |
| write | ✏️ | IconEditOutline16 (pencil) |
| edit | ✏️ | IconEditOutline16 (pencil) |
| code (run_code) | `</>` | IconCodeOutline16 (code brackets) |
| others (cordis_run, etc.) | ✨ | IconSparkle16 (sparkle) |

Status semantics align with dsh web's `leadingFor`/`stateStatus`:

- **Running**: keeps the variant icon with purple highlighting (no spinner animation)
- **Success** (exit 0): keeps the variant icon; ioCard rows still append
  `✓ exit 0`, a bash terminal card shows no success footer (a clean exit has
  no news to print, matching the web card whose exit-0 pill never renders)
- **Failure**: leading switches to the red status dot `●`; the body shows
  `✗ exit N`, `✗ signal …`, or `✗ failed` according to the result
- **Interrupted**: leading switches to `◐` in the stopped face; the body
  shows `⏸ interrupted`

Expanded bodies mirror dsh web's keyed toolviews:

- **bash/pwsh rows expand into a terminal card** (dsh web `BashRow` +
  `TerminalBlock`): the card body is one background band (the
  `dsh-emacs-tool-bash-panel-face` surface, the same look as transcript code
  blocks) carrying a single `$` prompt row for the command (prompt glyph in
  the tool-purple `dsh-emacs-tool-bash-prompt-face`; a multi-line or
  over-long command is flattened to one line and ellipsized — the full raw
  command stays available as the row's tooltip), a thin `─` divider where
  the output starts, and the raw output verbatim below.  A failure or
  interrupt appends a state-colored footer (`✗ exit N`, `✗ signal …`,
  `⏸ interrupted`); a clean exit ends bare at the output.  While the call is
  still running the card shows only the prompt row.  The faces are baked
  onto the card text, so fold/unfold keeps the styling; the row's state tint
  covers only the header line, never the card.
- Every other variant keeps a dsh web-style **ioCard** (an `IN` arguments /
  `OUT` result pair with the status line on top).

The collapsed state is a **compact single line** (no ellipsis placeholders, no
extra blank lines), and adjacent tool rows stack tightly; pressing `RET` on a
tool row expands/collapses the body (the body is stored inside the block, so
expanding always restores it).

Summary key precedence matches dsh web's `SUMMARY_KEYS`:
bash→`description|command`, read→`path|file_path|url`,
search→`query|pattern|url`, write/edit→`path|file_path`, code→`description`.

## Thinking blocks

| Face | Description |
|---|---|
| `dsh-emacs-thinking-face` | Thinking label and expanded body (bold, no italic) |

The collapsed row shows a preview of the first reasoning sentence on the right
(`dsh-emacs-thinking-preview-max` controls the maximum length; longer content is
truncated with `...`; set to 0 to disable).

## Fragment styling for extensions

Fragment snapshots accept `:face` for the entire card and `:header-face`
for the header only. These are merged after embedded text faces on every
update and fold/unfold, so body links and icon fonts survive. Supply the
complete snapshot on update; nil clears prior content and styling.
See the [fragment API](architecture.md#transcript-fragments-dsh-emacs-uiel)
for the update contract.

Titles retain their own link/button keymaps; the remaining title text uses
RET/click to fold. The main title is fitted first, then the summary uses any
remaining space. Headers and bordered bodies/footers share one width measured
from the displaying window, including narrow windows. Long body lines retain
their content. Layout is recomputed when a card updates or folds.

Tool cards currently fold independently; no aggregate activity-group header
is rendered. The remaining renderer group options/faces are legacy state,
not a working grouping surface.

## Mode-line stats

| Face | Description |
|---|---|
| `dsh-emacs-modeline-face` | The entire stats strip |
| `dsh-emacs-modeline-separator-face` | The "•" separator |
| `dsh-emacs-modeline-token-face` | Token count |
| `dsh-emacs-modeline-cost-face` | Cost |
| `dsh-emacs-modeline-ctx-ok-face` | Context < 50% (green) |
| `dsh-emacs-modeline-ctx-warn-face` | Context ≥ 50% and < 80% (yellow) |
| `dsh-emacs-modeline-ctx-crit-face` | Context ≥ 80% (red) |

## Session list

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
| `dsh-emacs-meta-face` | Meta information |
| `dsh-emacs-error-face` | Error message |
| `dsh-emacs-running-face` | Generating status |
| `dsh-emacs-input-box-face` | Input box background |
| `dsh-emacs-input-prompt-face` | Input prompt "❯" |
| `dsh-emacs-composer-goal-face` | Goal Row leading icon tint (dartboard SVG, `currentColor`) |
| `dsh-emacs-composer-goal-body-face` | Goal Row objective / phase text |
| `dsh-emacs-composer-goal-action-face` | Goal Row action SVG icons tint (dsh-web pause/resume/edit/clear) |
| `dsh-emacs-accent-face` | Accent color (badges, headings) |

The Composer Goal Row hides action icons while an operation is pending and
shows its progress (for example, “Pausing…”). In narrow windows it drops
inline actions to preserve objective and status space; the `C-c C-g` commands
remain available. Action tooltips show readable labels and keyboard shortcuts.
Use `C-c C-g ?` for the full objective and blocked reason, also available in
the objective tooltip. SVG icons occupy at most two columns of pixel space.

The Next Message row sits below the Goal Row and above `❯`, using
`dsh-emacs-input-prompt-face` for its text and clock icon, matching the
historical next-preview prefix; `Next:` is the non-SVG fallback. It folds line
breaks and fits the narrowest window displaying the chat. Its full text is available
in the tooltip; queue management remains under `C-c C-q`. Hiding or completing
a goal does not hide Next Message. Both rows share Composer's read-only region.

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
excluded before screen-row scans. Native recentering keeps the selected draft
point visible with line spacing and variable face heights, avoiding competing
scroll corrections. See [037](../postmortem/037-streaming-display-cpu.md).

The live Markdown watermark is a stream-owned marker; advancing it does not
modify the reply's first character. When no text is ready to format, the
formatter skips its passes entirely. Bottom detection and scroll pinning use
each window's screen rows, including line wrapping, while preserving the
selected input cursor. See [031](../postmortem/031-stream-frontier-and-screen-rows.md).

Large first chunks, queued reply/reasoning bursts and corrected replies keep
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

Customize the faces above for transcript Markdown. The renderer does not use
the `dsh-emacs-markdown-*-face` definitions in `dsh-emacs-faces.el`.

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
