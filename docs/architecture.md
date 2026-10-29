# Architecture

Module ownership:

```
dsh-emacs/
├── dsh-emacs.el              # Main entry point, session management, mode definition
├── dsh-emacs-protocol.el     # Typed views of dsh RPC payloads (cl-defstruct)
├── dsh-emacs-ui.el           # Fragment snapshots, borders, folding, fragment faces
├── dsh-emacs-faces.el        # Shared faces and palette defaults
├── dsh-emacs-tokens.el       # Token tracking and formatting
├── dsh-emacs-markdown.el     # Markdown syntax highlighting
├── dsh-emacs-render.el       # Event renderer (user/assistant/tool/thinking)
├── dsh-emacs-history.el      # Round-based history loading and Imenu index
├── dsh-emacs-events.el       # Event stream: native WebSocket + reconnect
├── dsh-emacs-modeline.el     # Mode-line stats and whale-tail playback
├── dsh-emacs-queue.el        # Pending-input queue mirror (queue/steer)
├── dsh-emacs-subagent.el     # Durable child catalogs, completion, availability and navigation
├── dsh-emacs-jobs.el         # Background jobs: job/list + job/follow streams, stop
├── dsh-emacs-plan.el         # Plan documents, asynchronous review and decisions
├── dsh-emacs-server.el       # HTTP/RPC client, server bootstrap, authentication, configuration entry
├── dsh-emacs-provider.el     # Minibuffer provider setup through settings and credential RPCs
├── dsh-emacs-command.el      # Slash surface: commands/list + commands/execute, "/" completion and menu
├── dsh-emacs-skill.el        # Skill catalog (skills/list) and /name gestures
├── dsh-emacs-shell.el        # Client-side `!command` shell commands (local execution)
├── dsh-emacs-reference.el    # @ reference completion, chips and navigation
├── dsh-emacs-composer.el     # Composer chrome: Next Message and Goal rows above the input
├── dsh-emacs-reload.el       # Local source reload and bounded presentation refresh
└── dsh-emacs-session.el      # Session list card view
```

## Source reload

`M-x dsh-emacs-reload` loads every local package source module in
[dsh-emacs-reload.el](../dsh-emacs-reload.el)'s directory. Lisp callers may
select another local checkout explicitly:

```elisp
(dsh-emacs-reload "/path/to/dsh-emacs/")
```

The loader reads every matching `dsh-emacs*.el` source before changing running
definitions. Literal top-level package `require` forms determine dependency
order; unreadable forms and cycles reject the reload before evaluation.
Explicit `.el` paths bypass stale bytecode. External dependencies remain owned
by ordinary `require`; this does not reload third-party packages.

This is definition and presentation reload, not an unload or session migration.
It does not re-enter modes, reconnect transports, restart the server, send RPCs
or submit a prompt. Existing buffers, draft text, attachments, stream state,
processes and timers remain live. Current `defvar` and Custom option values
remain intact, with two intentional presentation exceptions:

- Existing keymaps declared by `defvar` take their source initializer's contents
  in place, so live buffers and text properties retain the same map object.
  Ad-hoc edits to these package maps are replaced; reapply personal bindings
  after reload if needed.
- Face default specs refresh while Custom/theme overrides retain precedence.
  This is not a reset of user options or saved face customizations.

After loading, the command invalidates visual image caches and refreshes
Composer rows, session-list rows and mode-line presentation. It neither replays
nor reformats the existing transcript. Stable named `eval-after-load` callbacks
register optional icon integrations without retaining a new anonymous callback
body on each source revision.

Reload refuses during an active minibuffer, question or approval interaction,
or while any chat/draft is creating a session or loading history. Ordinary
streaming is not a blocker: existing callbacks continue against their retained
state, and named function calls resolve the new definitions. The command has
no default keybinding. In an already-running older Emacs, use `M-x load-file`
on [dsh-emacs-reload.el](../dsh-emacs-reload.el) once to make the command
available; merely updating the checkout does not hot-apply it.

Preflight is not a transaction. Evaluation errors can leave some new
definitions installed; fix the error and reload again, or restart Emacs.
Removed definitions stay resident, and existing lexical callbacks are not
rewritten. Restart for full definition removal, changed struct layouts or
changed major-mode initialization. These boundaries avoid destroying drafts
and live streams for the sake of an apparent clean restart. See
[decision record 115](../postmortem/115-source-hot-reload.md).

## New session drafts (`dsh-emacs.el`)

New-session commands display an editable `dsh-emacs-draft-mode` buffer first.
Its creation context captures cwd, workspace, preset, server and a
client-generated session candidate. A successful create response supplies the
authoritative identity, which replaces the candidate for activation and any
later retry after activation failure. Each retry owns a fresh attempt token;
callbacks require the original live draft, token and server. Pending drafts
have no active session fallback. Failures preserve the text and surface in the
header; `C-c C-c` retries. Workspace creation failures stop the chain instead
of changing the requested placement.

`dsh-emacs-server-ensure-async` owns asynchronous HTTP readiness and launch-token
exchange, bounded startup polling, local-only launch, and cancellation on draft
closure. Initial installation and token entry retain their interactive steps.
The entry point resolves the project workspace and issues creation RPCs; the
protocol module serializes the session creation request. Successful creation
uses the same buffer initialization as opening an existing session, without a
second server probe or window selection. The draft text and point are restored
into the chat composer, including recovery if a mode hook fails. Closing a draft
does not roll back a session already accepted by the host. See
[decision record 111](../postmortem/111-asynchronous-session-drafts.md).

## Provider setup (`dsh-emacs-provider.el`)

`dsh-emacs-add-provider` reads `settings/describe`, the configurable provider
directory and credential status asynchronously. Protocol constructors decode
Schemastery's reference envelope, provider addresses, existing endpoint/key
references and strict booleans. The command offers catalog routes owned by a
compatible provider dictionary or a new custom route. Multiple compatible
namespaces require an explicit owner choice; namespace ids are not hardcoded.

Minibuffer readers gather the required fields. A new route is written at its
own dictionary entry; existing routes receive only explicitly changed fields.
The provider command decides which values changed; protocol request encoders
own field names, model-ID objects, vector operation paths and the settings CAS
envelope. An empty new profile remains `{}`, while an unchanged existing route
has `ops: []`. Credential status/write argument encoding is also in protocol;
the secret key never enters the settings request.
Every `settings/mutate` uses the captured namespace revision. Credential
storage follows a successful settings write and partial success is reported
without rollback or automatic retries. Each asynchronous stage checks the
captured server URL. No model selection is changed and no catalog cache is
added: the existing model picker reads the current catalog when opened.
See [decision record 080](../postmortem/080-provider-minibuffer-setup.md).

## Configuration file entry (`dsh-emacs-server.el`)

`dsh-emacs-edit-config` visits an explicitly selected existing file with
`find-file`, without requiring a running server. Successful selections are
held in a private alist keyed by the normalized server base URL (launch-token
queries excluded), for this Emacs session only. A prefix argument selects a
replacement; failed or cancelled opens leave the previous choice intact.
TRAMP paths pass through ordinary Emacs file handling. Configuration loading,
validation and activation remain owned by dsh; there is no save hook or
settings RPC path. See [decision record 079](../postmortem/079-config-file-entry.md).

## Transcript fragments (`dsh-emacs-ui.el`)

The renderer supplies a complete alist snapshot: identity, labels, body,
border style, optional header/body faces, and the non-foldable flag. Optional
`padding` adds a blank line above and below the fragment; standalone
diagnostics use it to retain their spacing when folded or replaced. Padding
belongs to the fragment bounds but carries neither header nor body faces.
`dsh-emacs-ui-update-fragment` replaces that snapshot while preserving the
user's fold state. Nil fields clear previous values; this is not a patch API.
It returns the exact `(START . END)` range, excluding surrounding spacing.
An identical snapshot skips rendering when the buffer change tick, measured
width and label separator still match the last successful update. Snapshot
strings are copied so later caller mutation cannot fool this comparison.
Otherwise it renders again; identical rendered text and properties still
return the range without buffer writes or viewport measurement.
Changed updates preserve the common text prefix and suffix and replace only
the middle span. Native string comparisons locate the suffix without a Lisp
loop over every character or reversed copies of the body. The new state is
applied across the block, but visual properties are written only on differing
runs. Property-only updates do not replace characters. Changed updates still
render and compare the whole card.

A fragment's `:body` may be a string or a zero-argument text formatter capturing
immutable inputs. Minimal collapsed fragments do not call that formatter;
expanded and non-foldable fragments do, as do bordered fragments that need a
hidden-line count. The UI retains the function identity, not a copied closure
environment, and caches its string-or-nil result by source identity and body
width in the fragment snapshot. A replacement source invalidates it; changing
width rebuilds it the next time the body is needed. Identical-source updates
reuse the cache even after unrelated buffer edits. The cache is published only
with a successful atomic write, so a failed expansion leaves the old state
and retry path intact. Formatters must not mutate transcript or session state.
Tool renderers defer pending card details and settled terminal/read/diff/generic
bodies through this boundary; protocol decoding, summaries and state transitions
remain immediate. This does not defer ordinary assistant Markdown or introduce
a background render queue. See [153](../postmortem/153-lazy-tool-bodies.md).

Changed updates leave each window's start to move with the text, like a
marker, for every window showing the buffer. Only two cases adjust it: a
following window is recentered on `point-max` with native `recenter`, then
left unforced so redisplay still keeps point visible; a start that was at a
line beginning and collapsed into the replaced span moves back to that line's
start. Generic buffers follow when their screen-row view reaches the bottom;
chat buffers supply the renderer's shared input-anchor policy, described
under history browsing below. See decision records
[107](../postmortem/107-fragment-viewport-markers.md) and
[109](../postmortem/109-history-browsing.md).

Identity is the separate `:namespace-id` / `:block-id` pair, compared with
`equal`; do not join these strings. Lookup and deletion both take two
positional arguments: `(dsh-emacs-ui-find-block namespace-id block-id)` and
`(dsh-emacs-ui-delete-fragment namespace-id block-id)`. Thus `("a-b", "c")`
and `("a", "b-c")` identify different cards. Navigation and bulk folding
walk local property boundaries without repeated identity searches.
See [decision record 024](../postmortem/024-fragment-identity-and-local-navigation.md).

Identity lookup caches a start marker and its state object per buffer.
Successful insertion, update and folding refresh the cache; deletion releases
the entry. Each hit verifies the marker against the actual state property.
Misses and stale entries use property search, retaining the last matching
block rule for duplicate identities. Erase and undo invalidate the index;
narrowed operations bypass it so a restricted lookup cannot poison the full
buffer's ordering. Cache entries are published after atomic edits succeed.
See [decision record 026](../postmortem/026-fragment-performance-cache.md)
for lifecycle constraints and measured results.

One renderer builds the complete text and its `dsh-emacs-ui-state` property
before the buffer is edited. Updates and fold changes both use it and replace
text inside `atomic-change-group`; rendering or insertion errors propagate
while preserving the previous card. Minimal blocks need no special
body-range editing path. The stored snapshot includes labels and faces as
well as the body text or deferred source; fold/unfold preserves embedded
links, icon faces and body styling. `:status` is opaque renderer metadata
and does not apply colors. Renderers choose concrete `:header-face` /
`:body-face` values; the two regions are disjoint, so a row/status face can
never reach the body and a body face never tints the row. The UI merges
those faces after embedded faces on every redraw — which is how the bash
terminal card keeps its own body faces under a state-tinted header.

Each render measures the displaying window once and shares that body width
between the header, body and footer. Titles take priority over summaries;
bordered rows add four framing columns. Headers retain embedded keymaps,
local maps and button actions; only otherwise passive text gets the fold map.
Long body lines remain intact. Width is recomputed on update/fold, not through
a resize hook. See [decision record 023](../postmortem/023-fragment-layout-and-atomic-updates.md).

The UI does not interpret message kinds. Renderers can mark text with
`dsh-emacs-ui-space-after` to request blank lines after it; user messages
request one after their body and ensure one blank line before it, including
when the preceding footer leaves none. Newly inserted spacing shares the
message’s transcript boundary so older history precedes its work-start marker.
User-message line/wrap prefixes draw a rail without editing message contents;
the retained textual prompt has an empty display replacement.
Fragment lookup/navigation use the contiguous state property.
There is no group hierarchy or append/header-only mutation API. Streaming
assistant text remains owned by the renderer's existing stream path.
See [decision record 022](../postmortem/022-fragment-snapshots.md); the
region-scoped face contract is [decision record
039](../postmortem/039-region-scoped-fragment-faces.md).

## Task work details (`dsh-emacs-render.el`, `dsh-emacs-ui.el`)

The per-turn reply facts also own task-fold eligibility and boundary markers.
The protocol decoder exposes completion reason and final-prose eligibility;
`step/start`, `tool/call` and assistant settlements update the answer candidate
in sequence order. Step starts and tool calls do not enter footer token totals;
assistant usage accounting is unchanged. The Copy/Fork target remains the
latest nonempty reply, a different contract from a final answer that has no
later work. Facts are collected when either footers or task folding are enabled.

After `turn/end`, the renderer partitions visible thinking and tool fragments
around replies, input and process-external rows. Each activity has an independent
overlay and a deterministic summary, using decoded call IDs and names from the
same turn facts. Counts are deduplicated by call ID and stably ranked by category.
Replies never become activity members. Group headers retain their identity when
older history extends their members; temporary markers protect ranges while
headers are inserted or updated.

Successful turns without interleaved input additionally fold the whole process
before their final answer, or through the pre-`turn/end` boundary if there is no
answer. Failed/stopped turns and turns with interleaved input instead have a
non-foldable status header. Terminal diagnostics, deliverables and reply actions
remain outside. Missing `turn/start` does not prevent folding a loaded tail, but
elapsed-time accounting still requires the actual start timestamp. Active and
unknown-ending turns get no whole-turn fold.

The UI owns one contiguous overlay per disclosure, not disjoint spans around
human input. The renderer owns both levels' lifetime; trim/reset releases all
activity overlays and the outer overlay or disabled header. See
[149](../postmortem/149-web-activity-folding.md) and
[the audited Web rules](web-folding.md).

History batches bind `inhibit-redisplay` through final footer/fold
reconciliation and viewport following. Timer/process-input yields remain, but
the unfinished, expanded intermediate work is not painted at those yields.
The binding unwinds on errors too. This applies only while a snapshot or
older page renders, not across network requests or normal live event delivery;
it avoids extra intermediate paints without reducing the work to render a
large batch.

`dsh-emacs-ui-fold-region` adds a stock-button header and an invisibility
overlay over the original region. It does not copy or replace child cards,
so their identities, late updates, links and independent fold states survive.
The overlay retains the reader's choice across reconciliation; full transcript
reset releases it, and trimming a start boundary unfolds the surviving text.
During older-page insertion, existing task starts at the insertion boundary
advance past the page; starts first encountered within the page still precede
their own work. This keeps an active oldest task from absorbing older answers.
See [decision 142](../postmortem/142-task-work-details.md).

## Reply footers (`dsh-emacs-render.el`)

`dsh-protocol-reply-event--from-alist` decodes turn boundaries and assistant
settlements into footer facts. The renderer merges usage by event sequence
and selects the last committed text reply in each turn. This summary stays
independent of the mode-line accumulator, survives reconnects and merges
older pages; full reload clears it and transcript trimming discards summaries
whose completed replies are gone.

Visibility is a renderer policy, separate from those per-turn facts. Between
rendered human messages, only the latest completed turn with a nonempty text
reply keeps its footer. Replacing earlier footer chrome leaves reply text
and turn summaries intact; Copy/Fork still target the selected turn's last
text reply, and usage/duration still describe only that turn. Unfinished or
empty turns do not replace the current footer. Goal notices and hidden
subagent traffic do not create human-message boundaries. A reply's final
rendered text segment determines its group, including when streaming spans
human input. Removing a rejected optimistic echo goes through
`dsh-emacs-render-delete-user-message`, which reconciles footers after the
boundary disappears. History and replay use the same visibility rule rather
than restoring superseded rows; no protocol or transport grouping is added. See
[117](../postmortem/117-consecutive-reply-footer.md).

History batches collect facts before painting, so a page cannot attach a
footer to an intermediate reply. After rendering `turn/end`, the summary
retains the identity of the last transcript fragment or message at the
live/history insertion boundary. The footer resolves that identity's current
end, so tools, thinking, deliveries and diagnostics remain above it, even
after folding or deferred Markdown. Stock text buttons retain the reply's source
Markdown and sequence for Copy/Fork. Pending Markdown states close their end
markers against insertion so their idle replacement cannot absorb the footer.
The row never carries assistant-body or message-sequence properties. Its
items form one left-aligned label with ordinary dot separators, preserving
configured item order without stretch spaces. See
[decision record 084](../postmortem/084-reply-footer.md) and the placement
correction in [086](../postmortem/086-reply-footer-turn-tail.md).

## Composer (`dsh-emacs-composer.el`)

The bottom of a chat buffer is a **Composer**: a persistent, non-transcript UI
region with optional read-only **Next Message**, **Goal Row** and
**Attachments** rows, in that order, above the editable **Input Area**. The
input geometry (the `❯ ` prompt,
`dsh-emacs--input-marker` /
`dsh-emacs--input-end`, cursor clamps, delete guards) is owned by
`dsh-emacs.el`; `dsh-emacs-composer.el` owns all three chrome rows and the seam
that keeps streamed transcript above them. The queue module supplies the
visible next item directly from its mirror; Composer keeps no second queue.
Staged attachments stay in `dsh-emacs.el` (file/drop acquisition, clipboard
paste and the submit path own them); Composer reads them, exactly as it reads
the queue mirror, and a row's per-file remove cell only calls back into
`dsh-emacs--remove-attachment`.

Word and region kills are clipped to both editable input boundaries while
preserving their direction. Backward word motion over punctuation such as
`~/` can reach the read-only prompt before `kill-region` runs; the guard
clamps the deletion and cursor back to the input, so only draft text enters
the kill ring. Forward kills also preserve the structural separator newline.

The Goal Row shows the session's current goal as one read-only line (a leading
dartboard goal SVG icon mirroring dsh web — the `◎ ` text is a fallback when
Emacs cannot draw SVG (a non-graphical frame or no SVG support) — tinted with
the tool purple shared by the
transcript goal round notice and the goal tool cards), followed by a
prominent status label (`Ongoing Goal`, `Paused Goal` or `Blocked Goal`), a
muted, upright objective (folded to one line, with a canonical session mention
collapsed to its clickable `@label` chip as in the transcript message that
named the goal) and compact dsh-web pause/resume/edit/clear **SVG**
action icons (text fallbacks `||`, `▶`, `✎`, `✕`), one space after the
objective and between icons. The row uses the buffer background and
appears only when an unfinished goal exists, fed
**passively** from the server `goal` session projection (`rpc.md §9`):
`session/control` projection frames and the `session/follow` snapshot route to
the session's live chat buffer. It is composer chrome, never a `user/message`
and never sent to the model.

The goal **actions** (pause/resume/edit/clear) are `goals.*` RPCs
(`rpc.md §4.10`) issued on the current goal's CAS `ref` `{id, revision}`:
`dsh-emacs-goal-pause|resume|edit|clear` commands under a `C-c C-g` prefix
keymap, and each action glyph on the row binds RET/mouse-1 to the same
command via a text-region keymap.  A pending request token guards against a
second mutation mid-flight; a successful verb optimistically re-renders the row from
the returned view only while its request token and CAS ref remain current (a
clear removes it), so an already-newer projection always wins.  Failures
surface via `message` and leave the row unchanged (see postmortem/018).

`C-c C-g ?` (`dsh-emacs-goal-describe`) opens a read-only help buffer with
the full objective, phase and blocked reason. The objective's tooltip also
exposes the full text and reason. Editing starts from the original objective,
preserving embedded line breaks; display folding is confined to the row.
While an action is pending, its progress label replaces the status label and
inline actions are hidden. Narrow windows drop actions before sacrificing
objective space, then prioritize status when even the fixed chrome cannot fit.
The dock reserves the final window column to prevent a filled row from wrapping.
There is no trailing background padding or right-edge action alignment.
SVGs reserve two columns and are capped to fit the narrowest viewing frame's cells.
Goal projection, mutation request encoding and RPC response decoding belong to
the protocol module. The request encoder reads the decoded goal's id/revision
into the CAS ref and adds `request.objective` only when supplied for editing.
Composer retains phase guards, fresh pending-token identity and the mutation
callback's comparisons of parsed goal identities and revisions.

Next Message mirrors the Goal Row's anatomy: dsh web's queue glyph (a chat
bubble with two text lines, tinted with `dsh-emacs-composer-next-face` from
`dsh-emacs-color-queue` / `dsh-emacs-color-queue-dark`) followed by the
folded preview in the muted `dsh-emacs-composer-next-body-face`, or `≡ …` as a
text fallback when Emacs lacks SVG. Like the Goal Row and editable `❯` line,
it uses the buffer background. One
space after the preview text carries a compact action cluster, one space apart,
whose text-region keymaps run the queue's own item verbs on the previewed
message: the up arrow (`IconSendOutlineRegular`) → `dsh-emacs-queue--send-now`
\(steer into the running turn, or re-submit text-only items while idle), `IconEditOutline16` →
`dsh-emacs-queue--edit` after a `read-string` (present only while
`dsh-protocol-queue-item-text-only`, since the edit RPC answers with text
blocks), and `IconTrashOutline16` → `dsh-emacs-queue--delete`. The queue owner
rejects idle send-now for non-text items before any removal RPC. Composer
withholds every action for the optimistic submit object, whose local ID is
not a host queue ID, and includes placement in its signature so replacement
queue structs cannot leave buttons referring to the previous placement.
So the read-only
row can act on the queue without leaving Composer; a window that cannot keep
eight preview columns drops cells from the tail — delete, then edit, then the
arrow. The row truncates to the narrowest window displaying the chat; hover for
the full text and use `C-c C-q` to manage the whole queue. Either row may
appear independently; clearing a goal leaves pending input visible, and
clearing the queue leaves the goal.

The Attachments row appears while `dsh-emacs--pending-attachments` is non-nil:
the SVG Repo `attachment' icon (tinted from the attachment face; a text glyph
when Emacs lacks SVG) and each staged attachment's name followed by its own
clickable `✕` (`dsh-emacs--remove-attachment`, which drops only that entry;
`C-c C-d`, `dsh-emacs-clear-attachments`, clears the whole list).
Staging is owned by `dsh-emacs.el`: `dsh-emacs-attach-file` takes only `file`;
its interactive `C-c C-a` entry calls standard `read-file-name` once with
`mustmatch` t, then appends one attachment through
`dsh-emacs--stage-attachments`. Repeating it adds more files without a caption
prompt or server/network activity. Drag-and-drop retains its `y-or-n-p`
confirmation and existing filtering, then appends all valid files in their
existing order through the same staging function. Neither entry submits.
There is no new selector or command; see
[decision record 094](../postmortem/094-staged-file-attachments.md).
`C-c C-v` (`dsh-emacs-attach-clipboard-image`) reads the system
clipboard, `s-v` (`dsh-emacs-paste`) does the same but falls back to
`yank` when the clipboard holds no image, and
`dsh-emacs--yank-media-handler` (registered per chat buffer for
Emacs 29+ `yank-media`) feeds the same state.  A staged entry is either an
image (accepted `dsh-emacs-attach-media-types` MIME flavors, each validated
against its magic number; a macOS pasteboard exposes TIFF only, so those bytes
are converted to PNG through the system `sips` tool only when PNG is accepted)
or a **file entry** — only `(file . PATH) (name . N) (bytes . B)`, capped by
`dsh-emacs-attach-max-file-size`, with the bytes read and uploaded at submit
time, after rechecking readability and size.  `C-c C-c` sends the staged set
with the current input and consumes the set immediately.  File submissions
clear the input before uploading and leave later edits alone when uploads
complete; ordinary submissions clear after the optimistic echo.  Both consume
through `dsh-emacs--clear-input`, which saves
the actual input for undo and resets history navigation at consumption time.
Completion callbacks leave newer editing/navigation state alone.  Undo uses
the shared input state described below, without restoring attachments or
inventing a caption for an originally empty input.  Both paths clear before
sending the prompt RPC, so even a synchronous failure can restore it.
The resolved parts append to `session/prompt`: `{type:'image'}` with inline
bytes, or `{type:'file', receiptId}` after the raw-byte upload route
(`/api/session/uploadFileBinary`, `dsh-emacs--upload-file`) minted a one-time
receipt for that file.  Blank input uses the staged file names as its
caption.  A failed submit puts text and attachments back together only while
neither has been replaced; a submit that throws synchronously — or an upload
that fails — restores the pre-submit draft, and a restored file entry keeps
its path so the next submit uploads it again rather than reusing a spent
receipt.  A prompt carrying attachments is
never recorded for `M-p` recall — neither at submit time nor by the history
backfill — since a text-only replay would drop them, which is also why the
synthesized caption cannot resurface as a prompt.  The row's signature carries
only attachment names, never image bytes or a file's path and size.  The
optimistic echo builds
the same display blocks the host will persist (`{type:'file', attachment:{name,
bytes}}` renders through `dsh-emacs-render--file-placeholder`), because the
canonical `user/message` that matches it is never rendered a second time.
Upload completion stores the receipt's typed file reference as `uploaded-file`
on a per-submit copy of staging, so the echo uses the host's sanitized name and
actual byte count while retries retain the original local upload name.  The
wire prompt still carries only the receipt ID.
Image descriptor/base64 encoding, image tagging and receipt-only file parts
belong to protocol encoders. Acquisition, MIME/size checks, conversion and the
sequential raw upload/rollback lifecycle remain in `dsh-emacs.el`.

Geometry: `dsh-emacs--composer-top-marker` and
`dsh-emacs--composer-end-marker` delimit the complete read-only chrome region,
including row newlines. The top marker has insertion type `t`, so transcript
inserts through `dsh-emacs-render--input-insert-point` leave it attached to the
rows. The end marker has insertion type `nil` and stops before the `❯ ` line.
Composer replaces only its tagged region, preserving the draft and cursor,
and releases both markers when no rows remain. A content/layout signature
avoids rewriting unchanged rows; resize reflows Next Message even without a
goal. The input prompt remains a plain `❯ ` run, with no queue-prefix scanning
or text matching needed to remove stale previews.

## Undo (`dsh-emacs.el`)

Undo/redo covers the editable input area only; the transcript is never
undone.  A chat buffer is a live view of a session, and `undo` itself binds
`inhibit-read-only`, so the transcript's read-only text property cannot stop
a stale record from deleting rendered text.  Two rules keep them apart:

- Every programmatic write above the input — message bodies, tool cards,
  streamed Markdown, Composer chrome, the mode-line separator — runs with
  `buffer-undo-list` bound to `t`, so it leaves no undo entry (and no copy of
  the text it replaced).  Input-area writes stay recorded: typing, yanks,
  `M-p` recall and the clear after a send are all undoable.
- A write above the input still shifts the draft down, and undo records hold
  absolute positions that Emacs does not adjust when text lands elsewhere.
  `dsh-emacs--note-undo-change` (`after-change-functions`) flags that;
  `dsh-emacs--reset-undo-history` (`pre-command-hook`, so before the command
  can reach a stale record) rebuilds one step through
  `dsh-emacs--input-undo-history`. Nonempty input becomes an insertion record:
  `C-/` clears the draft; `C-g C-/` restores it, as does `undo-redo` on
  Emacs 28+. Empty input with a saved consumption becomes a deletion record:
  `C-/` restores the consumed text. Typing from there is undoable step by step.

The position-independent input state consists of the editable text and
`dsh-emacs--undo-consumed`, the last input consumed by `--clear-input`, including
reference-chip properties. All submission kinds use this boundary; it saves
text after deletion and clears the history navigation cursor. Any input edit,
including undo or failure restoration, invalidates the saved consumption.
Callbacks never reinstall it, so older completions cannot overwrite a later
consumption. An empty consumption saves nothing; attachment summaries are not
input, and undo never restores attachments or retracts a server submission.

A native deletion record alone requires clearing after the submit echo, and
still disappears at the next transcript write. Saving the consumption makes
both echo orders safe and gives plain, image and file sends the same lifetime:
reply writes do not prevent restoring the sent text before another input edit.
This retains only the latest consumption, not a full submit history. Rebuilding
still discards earlier editing granularity and redo records; undo/redo itself
counts as an edit and does not rearm the consumed text.

Point discipline: `undo` re-inserts a restored region at the position it was
deleted from and parks point there, which would leave the cursor at the start
of a draft it just brought back.  `dsh-emacs--note-undo-change` therefore
remembers the end of input text restored at the input's tail
(`undo-in-progress`), and `dsh-emacs--park-point-after-undo`
(`post-command-hook`) puts point after it; an undo that only removed input
text leaves point where that text was, which is where the user was editing.

`atomic-change-group` (streamed Markdown replacement, fragment rewrites)
requires that nothing edits `buffer-undo-list` while its handle is live, so
the history is rebuilt at command boundaries or before an input clear,
outside transcript change groups. See
[postmortem/054](../postmortem/054-undo-scoped-to-input.md) and the shared
consumption extension in [postmortem/093](../postmortem/093-consumed-input-undo.md).

## Shell commands (`dsh-emacs-shell.el`)

`!<command>` inputs without attachments are **client-side** commands:
`dsh-emacs-send-or-stop` routes them before server and busy checks, and
`dsh-emacs--submit-prompt`
also intercepts them before deferred or slash-command routing. Both use
`dsh-emacs-shell-submit` / `dsh-emacs-shell-run`, which preserve multiline
commands and spawn Emacs's `shell-file-name` with `-c`
asynchronously (`make-process`) with the chat buffer's `default-directory` —
the session workspace — as working directory.  The result row is rendered by
`dsh-emacs-render-shell-start` / `dsh-emacs-render-shell-done` in
`dsh-emacs-render.el`, reusing the slash-command row machinery (bash icon in
`full`, one dot in `simple` or on a display that cannot draw SVG, and state
color carried by the dot and, in `full`, the header tint):
a `!` row rides the same `dsh-emacs--command-blocks` table under its
own monotonic `shell-N` id.  A running row is marked by that color, with no
timer-driven spinner.  Process tracking is buffer-local
\(`dsh-emacs--shell-procs`).
Killing the chat buffer or resetting its major mode kills the tracked shell
before its tracking is discarded. `C-c C-!`
(`dsh-emacs-shell-process-kill`) interrupts a running one, rendered as
failed.  Because the chat has no terminal, `!` commands receive EOF through
`process-send-eof` (`dsh-emacs-shell-null-stdin`). This supplies EOF to stdin
readers but does not guarantee TUI termination; vim may continue running.
Submitting a new `!` command stops the previous tracked shell, and the opt-in
`dsh-emacs-shell-timeout` kills a tracked shell that outlives its limit.
Only exit or signal termination finalizes a row; stop/continue notifications
retain process tracking, captured output, and the timeout. Terminal processes
release their output buffers and timers even if the chat buffer is already
dead. Timeout settings are validated before either submission entry mutates
input or process state: only nil or positive integer seconds are accepted.
The process uses a pipe connection; closing its input leaves the original
command unchanged for `shell-file-name -c`, including with non-POSIX shells.
The executable follows the Emacs variable, not a fresh lookup of `$SHELL`.
When a shell exits, its tracking entry is removed; background children that
outlive it are not tracked or cleaned up by later buffer teardown or timeout.
Shell rows are also absent from server history, so a full transcript reload
discards them; reopening the session does not restore their output.
`!` never touches `session/prompt` or `commands.execute` and does
not depend on the server or the session's busy state — the model keeps
running while the local command executes. With attachments, a leading `!`
is ordinary caption text; the normal prompt path retains the images.
Output is capped by `dsh-emacs-shell-max-output`;
`dsh-emacs-shell-require-confirm` optionally
gates each run behind `y-or-n-p` (see docs/shell-commands.md).

## Protocol layer (`dsh-emacs-protocol.el`)

`dsh-protocol-read-json` owns JSON decoding for HTTP responses and WebSocket
frames. It uses native JSON support when available and the Lisp reader otherwise.
Both paths return symbol-keyed alists, vector arrays, nil for null and
`:json-false` for false, independent of user json.el options. Transport code
still owns UTF-8 decoding and error reporting. See
[112](../postmortem/112-native-wire-json.md).

Outbound `*-request` functions return method argument alists for session RPCs,
workspace mutations, job streams/kill, skills/list, commands, goals, provider
configuration/credentials, interaction replies/wait claims and reference queries.
Both model and effort pickers use
`dsh-protocol-session-select-model-request`. The same boundary owns
prompt text content and session/follow arguments. Absent effort, ordering target,
job scope and follow limit fields are omitted, not sent as null; session/list
retains its distinct `_request: {}` parameter.
Callers still choose endpoints and supply ids, modes, expanded paths, time zones
and resolved attachments. Protocol also owns nested queue action and attachment
content encoders; feature modules do not construct their wire fields.

Command catalog reads and execution keep flat `agentId` arguments, without a
`request` wrapper. The execute encoder owns the required `submittedAttachments`
array, preserving resolved parts and using `[]` for text-only commands. Both
reference discovery endpoints share `dsh-protocol-reference-query-request` for
flat `agentId` / `query` arguments, including the empty warm-up query. Command
admission, sync/async catalogs, reference generations and callback settlement
remain with their feature modules.

Interaction encoders own the flat `$events/result` envelope, timed wait/late
answer arguments, answer rows and explicit result/rejected/next outcomes.
Approval denial remains a result value (`"rejected"`), distinct from a
cancelled question or plan waterfall's rejected error. Ordinary answer batches
and selected labels retain their list representation; skipped/custom selections
stay empty vectors, and plan approval retains vectors at both array levels.
These encoders do not normalize opaque arrays. Readers, FIFO/shared prompt-slot
ownership, wait-claim lifetimes, callback handling and plan retirement remain
with their existing feature owners. Local settled-answer replay is unchanged.

Queue encoders retain remove/steer actions and edit's one text-block vector,
including empty text. Image descriptors retain media/data/name field order and
encode raw bytes once as continuous base64. Image tagging keeps descriptor order,
extra fields and tail identity; files instead emit only `type` and `receiptId`
from the decoded upload receipt. Feature modules still own staging, sequential
upload, confirmed queue identity, optimistic updates and draft restoration;
restored files upload again rather than reuse a receipt.

This boundary covers production RPC/mux payloads. Literal ERT and real E2E
request fixtures intentionally remain independent. Local staging metadata,
display-only optimistic/replay events, raw upload URL/query construction and
octet-stream bodies are not RPC/mux JSON and retain their existing owners.

`dsh-protocol-rpc-request-json` and the mux open/cancel encoders own outgoing
envelopes. `dsh-protocol-write-json` fixes null/false sentinels and compact
formatting independently of user json.el settings. It intentionally uses the
Lisp encoder: existing opaque question answers include list arrays that native
`json-serialize` does not accept. Empty argument objects use hash tables; vector
arrays, nil/null, t/true and `:json-false`/false retain their wire meaning.
Transport still owns request/stream id generation, UTF-8 encoding and framing.
See [140](../postmortem/140-outbound-request-encoders.md).

dsh server responses arrive as decoded JSON alists (arrays as vectors). Their
common structured payloads are normalized into `cl-defstruct` types here;
single-value payloads can decode directly to a scalar. For the struct-backed
views, business code reads fields through generated accessors (e.g.
`dsh-protocol-model-selection-reasoning-effort`, `dsh-protocol-session-cwd`):
each wire field name appears only in the matching `--from-alist` constructor, so
protocol field changes stay in the decoder. Covered payloads:

- Incoming mux envelopes → `dsh-protocol-mux-frame` (type, stream-id, value,
  error). Chat follow, custom streams and the core stream share this decoder;
  events retains routing, retired-stream checks and callback/error handling.
- Core logical items → `dsh-protocol-core-item` (type, payload). Workspace
  baselines reuse `dsh-protocol-workspace-list`; upserts become workspaces,
  removals become ids, and order/archive arrays become lists. Non-nil `items`,
  including the empty wire array `[]`, selects a workspace baseline; missing
  or null `items` retains the control route. Control baselines stay raw until
  each session is decoded/applied, while projection increments are decoded
  immediately. Events owns cache updates, repainting and refresh replay in
  their existing order.
  See [129](../postmortem/129-core-workspace-boundary.md).
- `$events` ready/cancel payloads become ids; session emits become
  `dsh-protocol-session-notice` (name, session-id, value). Running flags are
  decoded booleans; activity values retain the host timestamp, which events
  applies monotonically to cached session times and records for refresh replay.
  Added summaries stay raw until cache application so the
  refresh record cannot share a mutable session object with the cache.
  Waterfalls become `dsh-protocol-waterfall` (name, event-id, agent-id, request).
  Only a request routed to a live chat is decoded: approvals use their existing
  view; `dsh-protocol-question-request` normalizes the question array and wait.
  Individual questions retain their existing Plan/reader decoding boundaries.
  See [130](../postmortem/130-host-event-decoding-boundaries.md).
- `session/follow` logical items → `dsh-protocol-follow-item` (type, payload).
  Opening snapshots become `dsh-protocol-follow-snapshot`: cursor, event
  records in wire order, has-more, execution events, Plan and assistant
  baselines, and the opaque projections block. Events applies execution and
  Plan before history rendering, then replays the assistant prefix and applies
  the remaining projections. The latter decode at that late application point
  into `dsh-protocol-follow-projections`: a complete subagent batch, title,
  context, permission, model selection, goal/update flag and questions.
  Missing/null goal clears the row; a non-object goal is skipped. Questions apply
  to the current follow chat, after its cards exist. This path does not consume
  inbox or reapply Plan.
  Keeping the late decoder separate also preserves history/prefix application
  before a migration-required error. See
  [128](../postmortem/128-follow-projection-view.md).
  Unlike backward history pages, snapshots do not impose strict sequence
  validation. Live assistant frames use their existing
  decoded type; durable events remain raw for their event-specific consumers.
- `session/control` projection increments → `dsh-protocol-projection`
  (session-id, key, value), with a normalized string key and decoded payload.
  The baseline decoder retains raw session records for sequential decoding;
  each becomes `dsh-protocol-control-session` with a complete subagent batch
  and ordered projections. Events applies the batch first, then Plan/questions
  with their absence watermarks, then the remaining cells in wire order, and
  repaints the list once after all sessions. Missing goal/inbox keys preserve
  state; explicit nil cells clear it. See
  [127](../postmortem/127-control-projection-boundary.md).
- `session/title` → `dsh-protocol-session-title`, or nil for unrelated events.
  A matching event with no title still produces a view, preserving refresh
  replay recording. Events owns cache application and buffer renaming without
  reading the payload through renderer helpers.
- `deliverables/presented` → `dsh-protocol-deliverables` (seq, turn, files).
  Files are ordered `(path . description)` pairs; decoding drops unusable paths
  and normalizes absent descriptions. The renderer owns merging declarations,
  last-description-wins behavior, links and deferred turn-tail placement.
  See [133](../postmortem/133-title-and-deliverables-boundaries.md).
- `tool/call` data → `dsh-protocol-tool-call` (name, call-id, arguments).
  The renderer decodes once, then selects a Plan card, todo snapshot, hidden
  call or ordinary tool card. Protocol decoders interpret tool arguments and
  results; the renderer owns titles, summaries, formatting and card selection.
  See [131](../postmortem/131-tool-call-dispatch.md).
- `tool/result` → `dsh-protocol-tool-result` (call-id, text, outcome and
  metadata). The event renderer decodes once and returns the event sequence;
  late question settlement constructs the same decoded type directly.
- Durable event metadata (kind, sequence, clock, replacement and stream identity)
  is decoded in protocol. Message views normalize content, sources, references
  and attachment fields; chunk and turn/step views cover incremental output and
  uncommitted attempts. History records and recallable prompts use the same
  boundaries, including typeless optimistic/test messages.
- Request model selection and message usage decode in protocol. Mode-line owns
  accumulation and refresh policy; token helpers adapt decoded counts to the
  existing mutable usage plist.
- Tool arguments, todo snapshots, ask questions/answers, goal results and read/
  diff metadata have semantic decoders. Ordered pairs/triples suffice for rows;
  read-file and tool-argument views expose related facts together. Generic JSON
  display may retain an opaque object, but does not inspect its fields. No
  generic wire reader remains in renderer, events, modeline or input history.
  See [134](../postmortem/134-event-consumer-boundaries.md).
- RPC result envelopes and bare upload results use
  `dsh-protocol-rpc-result--from-alist`; transport retains callbacks and error
  reporting. Session lists reuse one list decoder; workspace order and job-kill
  outcomes have scalar/list decoders. Plan argument JSON and encoded session
  reference URIs also decode in protocol. Local draft attachments and UI/cache
  alists remain with their owners. See
  [135](../postmortem/135-rpc-response-boundaries.md).
- `session/list` → `dsh-protocol-session` (sessionId, title, cwd, agentPreset,
  updatedAt, blank, running, title-value, pending-interaction, context-pressure,
  context-window, context-projected)
- `contextPressure` projection → `dsh-protocol-context-pressure` (pressure,
  projected, window). Session rows and live projections share this decoder;
  the session struct keeps its existing flat fields. Display policy stays with
  the consumers: list synchronization uses raw pressure, while live updates
  prefer a positive projected estimate only when raw pressure is positive.
- `permissions` projection → `dsh-protocol-permission-value--from-alist`, a
  scalar decoder returning a nonempty preset name or nil. Events applies the
  decoded name to the target chat; absent/empty values leave the old segment
  unchanged. This value is independent of the selectable preset catalog.
- `workspace/follow` baseline → `dsh-protocol-workspace-list` (items,
  archived-session-ids) → `dsh-protocol-workspace` (workspaceId, sessionIds,
  title, path, createdAt, updatedAt)
- `workspace/create` / `rename` / `delete` / `insertBefore` →
  `dsh-protocol-workspace-result` (workspace, created)
- `session/modelCatalog` → `dsh-protocol-model-directory` → `provider-group` →
  `model-catalog-entry` → `reasoning` → `effort`, plus
  `dsh-protocol-model-selection` for `current`
- `session/selectModel` → `dsh-protocol-model-selection-result` (selected)
- `modelSelection.lastUsed` is decoded once to `dsh-protocol-model-selection`
  in session rows, control baselines/increments and follow snapshots. Live
  updates replace the cached row selection and its chat's model/provider/effort
  without another RPC. Internal list fetches record/replay model updates just
  like public refreshes; a stable internal callback buffer keeps global refresh
  cleanup independent of a chat's lifetime. Snapshot history can yield to newer
  control updates; scoped snapshot slots keep those live values authoritative at
  late projection application, without comparing cached and connected sequence domains.
  See [141](../postmortem/141-live-model-selection.md).
- `agentPresets/list` → `dsh-protocol-agent-preset-list` (presets,
  mode-selection-enabled) → `dsh-protocol-agent-preset` (id, is-default, name,
  description, broken) — dsh 0.1.7 dropped the row's `trust` and the roster's
  `authorable` flag, so the web-consistent built-in labels key on the id alone
- `goal` session projection (§9) → `dsh-protocol-goal` (id, revision,
  objective, phase, blocked-reason, max-goal-rounds, rounds-started)
- `plan` session projection → `dsh-protocol-plan` (active, pending, available,
  seq); constructors decode both control increments and projection baselines,
  including the watermark of an absent capability
- `commands/list` → `dsh-protocol-command` (name, description, input) and
  `skills/list` → `dsh-protocol-skill-list` (skills) → `dsh-protocol-skill`
  (name, description, when-to-use, model-invocable, path) — the two catalogs
  the `/` completion merges
- `command/run` / `command/done` → `dsh-protocol-command-event` (type,
  command-id, name, kind, text). Run creates a row and uses the same optimistic
  cleanup as submit rejection; done keeps that row's label and icon. Only
  live events take over an optimistic row or change animations. Hidden events,
  missing ids and unmatched results still return their sequence without
  changing rows. Command arguments are not displayed or decoded by this view.
  See [132](../postmortem/132-command-event-boundary.md).
- `user-questions/request` items → `dsh-protocol-question` (id, text, header,
  detail, multi-select, options) → `dsh-protocol-question-option` (label,
  description). The `ask_user_question` tool's own arguments are the same
  question, so the ask card decodes them through this constructor too; it
  accepts the tool's `multi_select` spelling beside the request's
  `multiSelect`, which keeps both spellings in one place, and unpacks its
  `options` array through `dsh-protocol--objects` so a non-object element
  declines at the boundary rather than signalling out of the constructor.
- the request's optional `wait` → `dsh-protocol-question-wait` (call-id,
  timed) — dsh 0.2.0's timed `ask_user_question`, which names the tool call
  whose foreground wait the answer UI may claim.
- the `userQuestions` projection → `dsh-protocol-user-questions` (active,
  settled, seq) → `dsh-protocol-pending-question` (call-id, questions, state:
  `open`/`continued`) and `dsh-protocol-settled-question` (call-id, answers)
  → `dsh-protocol-question-answer` (id, selected, custom). The reverse
  direction, `dsh-protocol-question-answers-json`, re-serializes a settled
  batch as the host's answer document so the transcript card can be completed
  through the shared decoded-result renderer. It does not wrap the answer
  document in a synthetic event.

Covered payloads are converted once at their owning boundary:
`session/modelCatalog` responses become a `dsh-protocol-model-directory`
before the picker reads them; the cached
session/workspace lists are stored as structs too. Helper `dsh-protocol--struct`
accepts either a wire alist or an already-converted struct, so callers and
fixtures can stay on either side of the boundary. Follow snapshots retain raw
projection blocks only until their late decoding boundary. Core routing and
workspace consumers use decoded values. `$events` envelopes have typed views;
their opaque summaries and requests decode at the application boundaries above.
Durable event payloads still reach their event-specific consumers as raw data.
Control and follow projection consumers read decoded values; Composer receives
a goal struct or nil directly.

The question reader in `dsh-emacs.el` answers each ordinary `ask` question in one
minibuffer read. The question text and a hint are the prompt, the numbered
options are the completion candidates, and each
candidate's description is delivered as a completion annotation through
`completion-extra-properties`, so descriptions appear in whatever list UI the
user has — no tooltip, geometry inspection, or frontend state is involved.
Multiple choice uses `completing-read-multiple` from `crm.el`, the stock
comma-separated input path; numbers, labels and unambiguous label prefixes
all resolve back to the original labels, an ambiguous prefix is left as the
user's own text, and the reader never guesses which option was meant.  A
selection is returned in the question's option order, not in the order it
was typed, so the answer matches the options as presented. Single choice uses the same reader and takes one value. Empty input
skips the question, the `dsh-emacs-question-skip-key` shortcut throws the
skip sentinel out of the reader's scope, and C-g propagates to abandon the
whole waterfall. Because every question is one read, no reader is reopened
per key: there is no flicker, no reordering and no dependence on how a
completion frontend highlights its candidates.
`dsh-emacs-question-help-display` selects whether the question's own detail
shows in the echo area (`echo-area`, the default) or not at all. Echo-area
output uses `message` with logging disabled and never inspects completion
geometry; the minibuffer remembers its last text, so cleanup clears only a
matching current message and preserves unrelated command output.
Protocol structs remain the only question wire decoder, and waterfall/RPC
ownership is unchanged.
See [decision record 042](../postmortem/042-question-prompts.md).

Questions and approvals keep separate FIFO queues but share one interaction
owner, `dsh-emacs--interaction-active`. It holds `(kind . event-id)` while a
waterfall is read, or `(late-answer)` during the late picker and reader.
`dsh-emacs--interaction-drain` finishes the current kind's queue before
switching to the other kind; late-answer cleanup starts with questions.
This preserves the existing service order, rather than imposing arrival
order across both queues. Each handler owns its reader and result submission;
dynamic bindings release the slot and its cancellation marker on exit.
Remote cancellation must match both kind and event id before closing a
minibuffer. Plan documents bypass this slot. See
[decision record 124](../postmortem/124-shared-interaction-owner.md).

dsh 0.2.0's **timed** form adds two rules on top of that reader, without
changing it. While a timed question owns the answer slot, its handler claims the
host's foreground wait with `userQuestions/attachWait` (a stream on the chat
socket). A submitted answer holds the claim until the asynchronous RPC
response, even after the prompt slot has moved to another frame; other exits
release it immediately. The host reschedules its original
deadline on release, so releasing before acknowledgement could discard an
answer after a long read. A question whose window closed — `continued` in
the `userQuestions` projection — is answered later by
`M-x dsh-emacs-answer-question`, which runs the same reader and submits through
`userQuestions/answer`. The picker and reader reserve the same global prompt
slot as foreground questions and approvals, draining queued work on exit.
Only a true answer response reports acceptance. The questions come from the
projection, which `dsh-emacs-events.el` keeps buffer-local per chat (the `session/control`
increment, the control baseline, and the follow snapshot all feed it).
The decoded sequence orders these updates, including absent capabilities;
a new host generation resets the watermark. The late answer is steered as a
`user-question-reply` user message, which the transcript
source filter hides; the settled cell completes the original ask card through
`dsh-emacs-render-question-settled`, which applies the batch through the
shared decoded-result path. That path also consults the stored settled
state when rendering a pending result, covering delayed live results and
older history loaded after the projection arrived.
See [decision record 073](../postmortem/073-timed-question-answers.md).

Approval waterfalls decode through `dsh-protocol-approval-request`: the raw
audit reason stays intact beside a normalized locale-to-text alist.
`dsh-emacs--approval-display-reason` selects the full language tag, base language,
English, then raw reason, using `dsh-emacs-approval-language` or the Emacs message
locale. Selection occurs before queueing, so the notification and ordinary
yes/no prompt share one value. The command detail and outcome RPC are unchanged.
See [decision record 074](../postmortem/074-localized-approval-reasons.md).

Plan review is a document interaction in `dsh-emacs-plan.el`. The protocol
question struct retains the intent kind, approval label and optional call id;
one supported plan-review question bypasses the minibuffer queue. Pending
requests live in their owning chat buffer, retain the originating client id,
and use asynchronous `$events/result` callbacks. A re-issued waterfall for the
same call id moves the one pending request onto the newest event id instead of
stacking a second one. Document buffers can be closed or killed without
answering; opening a transcript link or running
`dsh-emacs-plan-review` reattaches live actions. A sending flag rejects double
submission, failures retain the request for retry, and cancellation, connection
retirement and chat closure disable obsolete actions; a chat closed while a
decision is on the wire hands the waterfall back only once. Historical
documents never recreate pending requests. The renderer derives their titled
cards from `exit_plan_mode` arguments using `dsh-protocol-plan-document`, so
replay needs no separate persistence store. See
[072](../postmortem/072-plan-review-documents.md).

## RPC API

`dsh-emacs-server.el` owns the dsh service's one-shot unary RPC client
(`POST /api/<namespace>/<method>`, e.g. `/api/session/list`) directly, with
no server-side changes required.  Endpoint names are the two-segment
slash form of the dsh 0.1.7 wire protocol (rpc.md §4); the request body
is the `client-request` envelope with `payload = {args: {...}}`:

| RPC method | Purpose |
|---|---|
| `session/list` | List sessions (including running status, title, cwd) |
| `session/create` | Create a session |
| `session/prompt` | Send a message (`mode: "queue"` = next turn, `"steer"` = wake the running agent; text and/or inline base64 image attachments; `requestId` dedups resends) |
| `session/page` | Read one message-aligned history page before a cursor (feeds `C-c C-o`) |
| `session/updateQueue` | Manage pending inbox items (`edit` text / `remove` / `steer` by itemId) |
| `session/cancel` | Interrupt the running turn (partial reply is kept, inbox preserved) |
| `session/fork` | Branch through the latest completed turn, or the reply at point (`C-c C-y`, inclusive `atSeq`) |
| `session/modelCatalog` | List the routable model catalog for a session |
| `session/selectModel` | Switch the session's model |
| `session/rename` | Rename a session (its display title) |
| `session/attachment` | Fetch a stored image attachment (ref + base64 data) |
| `workspace/create` / `rename` / `delete` / `insertBefore` / `archiveSession` / `unarchiveSession` | Mutate a workspace or a session's workspace membership (archive has no delete; unarchive is its dsh 0.1.6 inverse) |
| `agentPresets/list` | List agent presets |
| `commands/list` / `commands/execute` | List / run slash commands |
| `skills/list` | List the session's user-invocable skills (the `/` completion's second catalog; invocation is a `/name` gesture in a prompt, rpc.md §4.2) |
| `$events/result` | Answer a `$events` waterfall (approval/question), args `{clientId, eventId, outcome}` |
| `userQuestions/answer` | Answer a timed question whose foreground window closed (dsh 0.2.0), args `{agentId, callId, answer}`; `dsh-emacs-events-open-stream`/`-close-stream` carry the matching `userQuestions/attachWait` claim |

Feature modules require the server module for `dsh-emacs--rpc-request`,
`dsh-emacs--rpc-async` and binary `dsh-emacs--http-post`; these functions no
longer depend on loading the entry point. Protocol owns the migrated endpoint
arguments and JSON envelopes described above; feature owners retain command
policy and callbacks. The server normalizes UTF-8 response bodies and reads JSON
through protocol; `dsh-protocol-rpc-result--from-alist` still owns RPC versus
upload envelopes.

The server also supplies authentication headers. HTTP requests leave Basic
credentials in URL userinfo for the URL library and add the package-owned
cookie; raw WebSocket handshakes request both Basic and Cookie explicitly.
Readiness and token exchange retain their separate pre-authentication rules.
Synchronous error results, asynchronous callback buffer/lifetime and exception
handling remain distinct. This is not a generic transport adapter or a new
retry policy. Required package callbacks use direct calls with declarations
at cyclic boundaries, not optional `fboundp` guards; external integrations
and version/build capabilities still use guards. See
[decision record 139](../postmortem/139-server-transport-ownership.md).

Real-time state — the transcript, the session list, queue/steer mirrors,
projections, and the approval/question waterfalls — is NOT polled; it
arrives over `/api/remote.mux` logical streams (next section).

## Pending-input queue (`inbox` projection on `session/control`)

Input sent while a turn runs is delivered through the agent inbox:
`queue` lands in next-turn (the next turn), `steer` in next-step (before
the running agent's next step).  The host publishes the authoritative
snapshot as its **`inbox` session projection** on the core connection's
`session/control` logical stream — every session's cell in the generation
baseline, and a `projection` frame on every inbox splice thereafter — so
`dsh-emacs-queue.el` only mirrors frames (no fetch RPC, no local drift).
dsh 0.1.7 deleted the dedicated `session/queue` frames that carried the
same state through 0.1.6, and dropped the baseline's `queues`/`jobs`
records; the `inbox` projection predates them and is still published, so
this source works against 0.1.5+ servers.  The wire cell (`next-turn` /
`next-step` lists of JSON `UserMessage`s) is normalized to
`dsh-protocol-queue-item` (`id`, `placement` =
`queued`/`steering`/`context`, `text`, `kind`) by
`dsh-protocol-queue-items-from-inbox` in `dsh-emacs-protocol.el`; an
`inbox` cell for a session with no live chat buffer is dropped rather than
applied to whatever buffer is current.  The baseline's `projections` record
is keyed by session id, and JSON decoding interns object keys as symbols,
so `dsh-protocol-control-session--from-alist` normalizes each record key to a
string before the chat-buffer and projection lookups — the same identity the
incremental `sessionId` field and `session/list` rows carry. The mirror
drives the echo-area feedback (enqueue / steer / consumption, diffed against
the previous mirror, with locally-deleted ids suppressed), the Composer Next
Message row, and the `C-c C-q` manager with its queued/steering counts. The
mode line has no queue segment and queue-only updates do not request
mode-line redraws.
`dsh-emacs-queue-next-item` determines the visible next message from delivery
order and the transient gate: steering (next-step) takes priority over queued
(next-turn), and a locally-submitted queued message not yet in the mirror is
the fallback (`dsh-emacs-queue--optimistic-submit') so the row appears with
the keystroke, not one round trip later. Composer owns its queue glyph, width
fitting and buffer geometry.
Our steer/delete/edit RPCs still update the mirror optimistically on success,
so Composer refreshes immediately. Queue-triggered repaints
are coalesced per frame burst with the existing zero-delay timer, preserving
transient suppression. The manager's minibuffer keys `e`/`s`/`d`/`RET` act on the
highlighted item; `x` deletes the whole queue. `context`
items (host-injected next-step content) are mirrored but never counted,
previewed, or listed; `steering` items count and list, and — as the
next thing the host injects — head the preview.

The echo feedback is silenced for the client's OWN empty-queue submit:
the wire accepts only `queue`/`steer` prompt modes, so every send —
idle, or queued behind a running turn with nothing else pending — is
appended to the inbox and claimed when the turn starts, two
`inbox` projection frames within milliseconds.  With an empty mirror those
frames carry no ordering information, so the transient splice/claim
gets no `queued:` / `running:` echo and no Next Message preview paint
(the row would otherwise flash as the item is inserted and claimed) — `dsh-emacs-queue--mark-submit-suppress`
arms `dsh-emacs--queue-submit-suppress` when the mirror is empty at
submit time, on both the plain and the deferred path; it clears at the
CLAIM — the empty frame that follows the submit's own splice (which is
why an empty frame seen before the splice, such as a fresh session's
connection seed, is ignored rather than taken for the claim) — in the
submit failure branch, or by a transport-hygiene timer (a dead transport
would otherwise leave the echo gate stuck until the next submit — the
timer paces no preview).
The Next Message preview is gated by the same flag, with one exception:
a submit that was already PARKED when it was made — a turn was running
then, recorded by `dsh-emacs-queue--mark-submit-suppress' in
`dsh-emacs-queue--submit-parked-p' — shows its preview at once, because
such an item can only be claimed at the turn end and is genuinely
parked.  The deferred path does not wait for the host's confirming frame
to do so: `dsh-emacs-queue--optimistic-submit-show' records the
just-submitted text as a local queue item and repaints, and the host's own
`inbox' projection frame (or the submit-failure branch) retires it.
An IDLE submit is not parked (the host claims it at the turn
START), so its queue transient stays hidden even after the send path lights
the optimistic spinner; keying this on the live spinner instead painted
and cleared the row within milliseconds (the `C-c C-c' flash), and
taking a fresh session's empty seed for the claim did the same on the
first send of a newly opened session.  The idle path echoes the message
into the transcript at submit time
(`dsh-emacs--render-user-message-optimistic') instead, so the message
appears the instant the input clears rather than one HTTP round trip later;
the pending entry dedups the host's canonical `user/message', and a
rejected prompt deletes the echo and restores the draft.
Genuine queueing — items already parked — keeps its feedback and preview;
the manager retains queued/steering counts.
This is the queue-frame complement of the anchor-gated replay dedup
(rationale: postmortem/004): transcript frames are idempotent by seq,
queue frames by submit context.

## Background jobs (`job` namespace streams, `dsh-emacs-jobs.el`)

Background work the model starts — a bash command it left running, a
subagent delegation, a workflow — is owned by a session and mirrored by
`dsh-emacs-jobs.el` from the **`job` Remote namespace**, not from the
core control plane.  dsh 0.1.6 and earlier carried a whole-host `jobs`
record on `session/control`; 0.1.7 deleted it and moved the state behind
this namespace's own streams, so the client must subscribe to see the
roster at all (rationale: postmortem/065).

Two logical streams, both on the **chat buffer's** `/api/remote.mux`
socket:

- `job/list` — one per followed session.  The host sends the complete
  visible set (`rows`) per frame, so the mirror is replaced wholesale and
  a reconnect's first frame is already the truth; a frame that drops a
  job removes it here too.  The stream is (re)opened at handshake
  completion alongside `session/follow`, so it lives exactly as long as
  the chat's socket.
- `job/follow` — one per job whose output is being viewed.  An `opened`
  anchor carries the job's projection and the offset the first batch
  continues from, `output` batches carry absolute offsets and a `next`
  resume offset, and a terminal `status` frame ends the stream normally.
  The output buffer is read-only and appended as batches arrive, so the
  host's screen is not re-emulated client-side.

Because the chat socket now multiplexes more than the follow stream,
`dsh-emacs-events--dispatch-stream` routes by `streamId`:
`dsh-emacs-events-open-stream` registers a handler on the process and
`dsh-emacs-events-close-stream` (also called by the socket teardown, via
`dsh-emacs-events--close-streams`) retires it, invoking the handler once
with nil so no mirror outlives its stream.  A teardown keeps the last
roster rather than blanking it — a reconnect re-reads the whole set, so
clearing would temporarily empty the job chooser.

The wire views are normalized in `dsh-emacs-protocol.el`
(`dsh-protocol-job` with symbol `status`, `dsh-protocol-job-list`,
`dsh-protocol-job-frame`/`-chunk`), and the namespace's CLI surface is
Emacs-native: `C-c C-j` opens the roster as a
minibuffer menu whose single keys show output (`RET`), stop a job (`k`,
two presses within `dsh-emacs-jobs-kill-arm-seconds`) and re-subscribe
(`r`).  A kill is a human action: the host records `cancelled by the
user` and the owning agent still receives its completion notice.

Job status stays in transcript tool rows. The mode line does not consume the
job roster, and roster updates do not request a mode-line redraw.

## Event rendering flow

dsh web multiplexes all logical Remote streams over one long-lived
WebSocket, `/api/remote.mux`.  A chat buffer opens a `session/follow`
stream whose opening `snapshot` seeds the transcript and whose `event`
items render live; the follow stream is the only automatic reply channel
for a chat — when it drops, the health-check / watchdog / reconnect
machinery below restores it, and until then replies appear only via manual
refresh (`C-c C-r`):

1. **user/message** → `dsh-emacs-render-user-message`: rendered as a card background. Image attachments follow the text like dsh web's message gallery: every image becomes a compact thumbnail in wrapping rows (`dsh-emacs-render-image-thumbnail-lines`), one image or several; inline base64 fills immediately and an attachment ref fills when `session/attachment` settles, with `RET` / `mouse-1` opening the original. File attachments stay display-only chips. A host-injected goal round continuation (`source.kind = "goal"`, appended by dsh-goal-round-driver) draws dsh web's collapsed **Continuing goal** trigger notice, expandable to the injected `<goal_round>` prompt. A non-human message admitted by an inbox claim (a child `send_message`, a settled subagent, or a team, webhook, schedule, job or plugin event) also draws a collapsed turn-trigger notice — source-family title, event clock and the recorded body — above the turn's own **Completed in …** summary; it stays outside that fold. Every other host injection stays hidden (`dsh-emacs-render--user-authored-p`).
2. **assistant/chunk** → `dsh-emacs-render-assistant-chunk`: the first text chunk appears immediately; subsequent insertion, Markdown and viewport following coalesce on a 50ms one-shot timer. Event boundaries, finalization, stream changes and disconnect flush pending text.
3. **assistant/message** → `dsh-emacs-render-assistant-message`: the final snapshot is used to correct the streamed body, avoiding duplicate display
4. **tool/call** → `dsh-emacs-render-tool-call`: a nonempty `exit_plan_mode`
   document uses a Plan card; `todo_write` appends a todo snapshot; other
   calls use pending tool cards. Hidden tool calls return nil and do not
   advance the render anchor, while todo snapshots still apply and return
   their sequence. An absent or blank Plan document uses an ordinary card.
5. **tool/result** → `dsh-emacs-render-tool-result`: updates the existing tool card (success/error state). `create_goal` / `get_goal` / `update_goal` settle into dsh web's goal card (`dsh-emacs-render--goal-card-body`): objective summary, State / Rounds, and the blocker message while blocked.
6. **turn/start** / **turn/end** → `dsh-emacs-render-turn-start/end`: rendered as a divider

`dsh-emacs-protocol.el` decodes retry, compaction, turn-ending and
`agent/inbox/spliced` facts.  The renderer replays the latter's queue/claim
state only for turn-trigger attribution; it paints no row.
`dsh-emacs-modeline.el` owns only compaction state, its matching boundaries,
and `dsh-emacs-describe-status` for compaction/Plan details. Compaction matches
its own id and may run between turns. Retry has no mode-line state.
The renderer retains attempt/outcome facts by turn and seq so older pages can
complete a pair already partially loaded. A retry consumes the preceding
unresolved attempt of the same step; started matches retry id and number.
Another response in the same turn and step also confirms a retry, including
compaction recovery that emits no retry event; it shows **Retried** without
inventing a counter or delay. Each turn tracks its newest event's transcript
boundary with a marker. Trimming past that boundary releases its cached facts;
older pages cannot move the boundary backwards.
Turn failure settles only the remaining unresolved attempt, preserving earlier
retry labels. The existing attempt fragment is updated in place with explicit
retry/failure/cancellation labels, tool-row styling and failure hover details.
Unknown outcomes retain **Incomplete reply**. Live output is taken over once,
with expanded-live/folded-history behavior and user folding preserved.
Model errors and automatic compaction failures use `dsh-emacs-render-info`:
the same status dot, title face and compact spacing, with muted
metadata and an initially expanded explanation.
`dsh-emacs-render.el` routes those facts. Automatic summaries get a folded
`Automatic compaction` row containing the generated summary, covered-item
count and approximate old-context token count. It leaves the original
conversation visible and does not show raw output or the checkpoint body.
The neutral title does not claim checkpoint application succeeded; automatic
failures still get separate cards. Summary events with a source command id
are suppressed; manual compaction keeps the existing command result card's
counts and result or failure text. Missing summary events are not fetched or
cached separately. These transitions need no new stream or polling loop. See
[104](../postmortem/104-auto-compaction-feedback.md).

Before rendering a follow snapshot, `dsh-emacs-events.el` rebuilds execution
status from its whole retained event window, including records below the
transcript anchor. Folding before history rendering can yield ensures a newer
live event cannot be overwritten by the older snapshot. A sequence watermark
rejects duplicate facts; older history pages never feed this live state.
Disconnect/rebaseline clears it, and a snapshot lacking a start leaves the
operation unknown. See [070](../postmortem/070-execution-feedback.md).

Plan mode is persistent projection state in the modeline module. The control
stream delivers live updates; follow and control baselines seed the same
buffer-local mirror. `seq` / `asOfSeq` guards prevent stale snapshots from
overwriting or clearing newer state. A new core connection resets the old
generation's values and watermarks. Follow seeds Plan before history can yield,
and raw `plan/mode` events never rewind it. The badge and the status-details
command share the existing mode-line surface; switching still uses the host
slash commands. See [071](../postmortem/071-plan-mode-status.md).

The follow snapshot is the opening history tail: every record is one durable
`event` (there is no packed-row form any more), so old `assistant/chunk`
deltas are not replayed and the completed
`assistant/message` is used directly; new chunks from live follow events
are handled directly. The streamed body uses
a render watermark and frozen properties so that only the not-yet-stable tail is
re-rendered and styled. Fenced code blocks render **append-only**: a block
writes its card chrome as soon as the opening
fence line completes and then streams its body raw inside it (each flush
styles only the new body lines, properties only), so the closing fence merely
appends the bottom panel line — no line break is ever inserted into text the
user has already read. Extending tables still re-render their rows
(see [postmortem/055](../postmortem/055-append-only-streamed-blocks.md)).
The assistant stream creates and retains its Markdown
scan state from the outset, so successive flushes scan only new complete
lines of unfinished blocks.  Each protocol block owns its own transcript
region: starting a text block folds the live Thinking body into its fragment,
starting a reasoning block closes the live text body, and a per-step record
(`dsh-emacs--streamed-step`) lets the authoritative message render only what
has not been shown, so a reasoning body is never inside the text stream's
Markdown region and the final repair cannot delete it
(see [postmortem/056](../postmortem/056-thinking-block-boundaries.md)).
The step record also tracks block indices that supplied content: a delayed
`block-end` cannot append an already folded Think block after the answer.
An unseen block's final content uses the same stream/commit path as deltas,
so the authoritative message recognizes it too.
Distinct block indices separate consecutive blocks of the same kind.
Folded Think fragments retain their identities until settlement: corrected
reasoning replaces them at their original position, and failed attempts move
all live/folded blocks into the attempt card. Their indexed stream states also
remain available: a late reasoning delta updates its original fragment and
the committed reasoning text, preserving the fold state and leaving the
current answer stream open. Text reconciliation completes
before an earlier Think fragment is replaced, preserving text-region bounds.
`dsh-emacs-render--discard-stream` owns that transient cleanup for both failed
attempts and reconnect snapshots (see [060](../postmortem/060-stream-settlement.md)).
The step record joins committed blocks with the same newline separators as
the final content, removing the joining separator before rendering the next
body. Closed text blocks retain their stream states until reconciliation;
unfinished formatting stays on the idle queue with those bounded regions.
Transitions never spin waiting for pending keyboard input to disappear, and
a divergent final body cancels queued work for the regions it drops.
An open block is never deferred to the idle
queue, and a block that a queued (temp-buffer) render opened is handed to the
live state with its body-start marker, so a streamed body is never re-read as
Markdown. Its render watermark is a non-advancing marker
owned by that state, avoiding property writes to the first character of an
otherwise stable reply. Empty ready ranges bypass Markdown passes.
After closing a source block, formatting resumes at the text after its bottom
padding before advancing the watermark, including when that tail arrived in
the same chunk as the closing fence. Force
replacement resets the watermark; finalization detaches it after the final
formatting attempt. Queued replies retain their body markers until publication
or cancellation. Non-stream Markdown conversions keep their serializable watermark
property. Raw deltas are retained as a list and joined once
for comparison with the final message; a second list references only unpainted
deltas, which are inserted together before formatting. An unchanged final
message keeps the painted body. See [decision record 029](../postmortem/029-stream-write-batching.md).
The WebSocket decoder walks each input batch by byte offset,
retains its incomplete tail once, and joins message fragments only at FIN.
A process-local drain guard keeps one consumer in charge across rendering
yields. Reentrant filters append bytes only; the original consumer advances
its exclusive cursor before dispatch, then consumes appended frames in order.
This prevents re-parsing the current snapshot or overwriting partial input.
Viewport bottom detection uses `vertical-motion` with each destination
window, so wrapped lines count as screen rows.
Stream insertion, timer flushes and corrected final replies capture the
following window list immediately before editing, then pin that list after
formatting. This avoids mistaking a large insertion for a manual scroll;
there is no saved follow state between callbacks. Per-event calls still skip
pending batches. Every window's draft point and excluded reading windows remain
untouched. Hidden buffers skip prompt lookup for following altogether.
Reading windows are excluded before any screen-row measurement. The bottom
check uses each eligible window's draft point, so a long draft still follows
when its prompt has scrolled above the viewport. Pinning uses `recenter -1`
in the destination window at its own draft point, without selecting another
chat permanently or resetting an inactive window to the input anchor.
Counting backwards by `window-text-height` overestimates capacity with extra
line spacing or larger faces; the resulting offscreen cursor made Emacs scroll
back on every redraw.
The transcript's after-change hook uses `restore-buffer-modified-p` so text
and property edits do not repeatedly invalidate the mode line. The animation
advances during pending text batches without forcing a separate redraw.
When installed, the optional `motion-line` package refreshes quiet visible
turns. It is installed independently; there is no bundled engine. If it is
absent, the modeline renders a static Deep diving or Compacting caption and
explicitly redraws on activity changes. That path calls no animation API,
reads no animation asset and creates no animation timer. It omits the elapsed
clock.
Library load errors other than a missing file still propagate. The modeline
module owns the web whale asset,
color cache and `dsh-running` slot. The independent package owns elapsed-time
sampling, cached output, one shared scheduler and buffer cleanup. Native
mode lines keep a plain DSH major-mode name and render the combined whale,
caption and clock in the separate activity segment only while active. The
mode name retains the standard major-mode menu; the compaction activity keeps
its status-details map. Doom consumes the same combined output in its existing
major-mode slot, with its separate static logo unchanged. Without Motion
Line, the native DSH label remains plain and the activity caption has no clock.
The modeline sets a buffer-local redisplay callback to preserve batching.
See [095](../postmortem/095-running-status.md) and
[096](../postmortem/096-standalone-motion-line.md).
The same cached output includes the English Deep diving caption and its
foreground sweep. Compaction temporarily replaces it with teal Compacting
and a clock measured from local observation of that compaction. Standalone
compaction uses the same slot; the Plan label remains independent.
A buffer-local running-start timestamp provides the turn clock;
the three-second animation phase never acts as elapsed turn time. Completion
and disconnect clear the timestamp. The turn clock keeps running underneath
compaction and returns with Deep diving afterward. Doom appends its base face
so the caption's per-character foregrounds survive. See
[095](../postmortem/095-running-status.md) and
[104](../postmortem/104-auto-compaction-feedback.md).

After a ready chat socket delivers input, the events module suspends further
reads for 50ms with `set-process-filter` set to t. Bytes remain in the socket;
each received batch still parses and dispatches synchronously in order. A
one-shot timer restores the filter saved when reads paused. Disconnect and
connection loss cancel that process-owned timer and clear the saved filter;
a quiet socket has no polling timer. Handshakes and the host question/approval
channel bypass this pacing.
This bounds process-triggered redraws that downstream text batching cannot
prevent, adding up to about 50ms of receive latency during bursts. See
[037](../postmortem/037-streaming-display-cpu.md).
See [decision record 031](../postmortem/031-stream-frontier-and-screen-rows.md)
and [032](../postmortem/032-partial-line-styling-and-burst-follow.md), and the
[performance audit](streaming-performance.md).

Partial-line emphasis passes narrow to the first delimiter plus its preceding
character, preserving the existing whitespace/line-start grammar. Other
Markdown passes retain the full ready range. The renderer supplies its assistant
base face to Markdown's final face pass, which keeps one copy at the lowest
priority and mirrors the complete result to `font-lock-face` in one traversal.
The renderer
then applies read-only, stickiness and event identity properties together.
Repeated tail formatting cannot grow the face list. A stable named yank handler
keeps repeated formatting from rewriting an otherwise identical property.
See [033](../postmortem/033-final-face-pass-and-pixel-probes.md).

Table width measurement belongs to Markdown. On Emacs 31 it uses the public
`string-pixel-width` buffer argument and selects the destination window during
measurement to preserve frame/font context without editing chat text.
Older versions measure in a temporary buffer with the destination's font
settings: Emacs 29–30 use `buffer-text-pixel-size`, while Emacs 27–28 briefly
display the probe under a saved window configuration. Every path measures
beyond the window width without changing the chat buffer's edit counter. See
[034](../postmortem/034-full-table-pixel-widths.md).

Font measurements are shared through one dynamically bound, render-scoped
plist. Space widths, face ratios and character-height scales cannot outlive
the table render. Height probes copy the destination's face remapping and
default properties, using `buffer-text-pixel-size` where available (Emacs 29+)
or a saved window configuration on older versions. See
[035](../postmortem/035-table-render-metrics.md).

The renderer owns the idle queue for expensive assistant Markdown, including
history messages. Pending regions above `dsh-emacs-stream-markdown-limit`
(8192 by default) wait for an idle attempt; oversized partial lines first wait
for a newline or finalization. Ready-region detection still belongs to
Markdown. A callback prepares one reply in a temporary buffer under
`while-no-input`. A one-shot 100ms clock timer checks current idleness before
each attempt, avoiding immediate re-firing of an elapsed idle deadline.
It commits only a complete result whose source character
tick is unchanged, and recomputes following windows just before publication.

Queued body markers exclude adjoining messages; the owning edit restores its
explicit bounds after changes. `replace-region-contents` preserves positions
in matching text with a 10ms comparison limit, then the renderer installs the
prepared properties. The diff receives plain characters, avoiding a reproduced
Emacs 31 coding-buffer failure with protected strings. Reset, buffer death and
major-mode changes cancel jobs and release their markers. Teardown hooks
disconnect and flush pending text before releasing those markers. Errors at
this idle callback boundary are reported while leaving the raw reply visible. This uses
the main Emacs thread and standard idle/input machinery, not a worker thread
or an alternate parser. See [036](../postmortem/036-bounded-stream-markdown.md).

## Markdown resources and file navigation

`dsh-emacs-markdown.el` owns inline link/image syntax, independently of
filesystem resolution. Resource scanning captures destinations before prose
styling can consume their punctuation. Rendered resources retain their click
identity instead of reparsing label text. Single-line and code-span boundaries
apply equally to full and streamed rendering; a bare image cannot freeze on
an unfinished path fragment.

The shared local-path decoder rejects remote authorities and unsafe input,
then links validate existing targets and optional one-based line/column
positions. Images additionally require readable regular files and a graphical
image backend. Click closures capture the rendering working directory. The
reference module still opens literal `@` and deliverable paths against the
session cwd; Markdown percent decoding and position suffixes do not belong to
that path. Web's authenticated server-file endpoint is not used by Emacs.

See [the user-facing file/image contract](reference.md#assistant-markdown-file-links)
and [decision 150](../postmortem/150-markdown-resource-boundaries.md), including
the intentionally bounded syntax and differences from the Web renderer.

## Event-stream reliability

- **No native compile**: `dsh-emacs-events.el` declares a file-level
  `no-native-compile: t` — on the project's emacs-plus@31 build the
  network-process filter of native-compiled code is not dispatched continuously
  (the socket is read at most once, after which data piles up in the receive
  queue), whereas the byte-compiled filter delivers correctly on all builds, so
  this module is always loaded as byte code; the filter/sentinel are likewise
  installed via byte-compiled closures.
- **Connection health check**: after connecting, a repeating timer checks every
  2 seconds whether the handshake has completed; if not, the socket is treated
  as wedged and killed, and the sentinel reconnects.  Errors
  inside the check body are isolated with `condition-case` — if a timer function
  throws outward, Emacs silently removes the timer, leaving an unrecoverable
  deadlock where the process stays "open" but nothing ever kills it; this is a
  pitfall hit in real testing.
- **Snapshot-first rendering**: the first open of a session — or reopening
  one whose buffer was killed — opens a `session/follow` stream whose
  `snapshot` seeds the transcript; switching back to an already-open chat
  reuses its live buffer and stream (see
  [147](../postmortem/147-open-session-buffer-reuse.md)).  The snapshot carries
  a `cursor` plus message-aligned `records`: `turnWindow` requests
  one round start, bounded by `dsh-emacs-history-window` messages per response.
  The protocol decoder counts human rounds (turns with a user-authored
  message) in the snapshot; on first open, Events asks the history controller
  to complete one human round only if no human round is present, after
  applying the snapshot and projections. A snapshot that starts at a child or
  goal wake therefore backs up to the preceding user turn. The manual
  `dsh-emacs-history-rounds` target does not affect opening. The live follow
  stream stays gapless. Reconnects do not start another automatic history load.
- **Reconnect is self-healing**: the reconnect socket pins `no-conversion` — on
  a reused events buffer the re-inferred process coding system folds the 101
  response's `\r\n\r\n` to `\n\n`, so the handshake never matched and the
  health check killed the socket in a 2s reconnect loop, leaving that session
  silently deaf while other sessions' sockets kept rendering (reproduced live
  against a real server).  A synchronous connect error (unresolvable host,
  malformed `dsh-emacs-base-url`) is contained: the reconnect is re-armed and
  another connect scheduled, instead of a timer-error leaving the chat with no
  recovery channel.  Reconnecting re-opens the `session/follow` stream, and the
  fresh snapshot reseeds whatever was missed.
- **Replayed frames never render twice**: on a mid-session reconnect the fresh
  follow snapshot re-sends the transcript tail; the dispatch path
  (`dsh-emacs-events--dispatch-event`) gates every transcript frame on
  `dsh-emacs--anchor-seq` — the newest seq this buffer rendered or consumed —
  and drops frames whose seq is not newer, the same gate
  `dsh-emacs-render-history-events` applies to re-fetch windows.  The follow
  snapshot advances the anchor to its `cursor`, so replaying the same tail
  renders nothing; events generated during the outage carry seq > anchor and
  render once as the catch-up.  Without the gate a reconnect repainted the
  whole transcript a second time (doubled user messages and assistant replies,
  interleaved layout, only cleared by killing the buffer and opening the
  session again).
- **Live assistant continuity**: protocol structs decode the frame, reconnect
  baseline and compact stream records. Events keeps the active attempt id,
  turn/step and next frame index together; duplicate revisions are ignored,
  while a revision-1 `start` after a higher watermark resets the lifecycle
  counter (attempt ids restart per lifecycle, so they cannot identify the
  reset). Revision or frame-index gaps and unexpected attempts cancel and
  reopen only the logical follow stream. Its fresh snapshot replaces transient
  output, and retired stream ids cannot feed queued frames into that
  replacement.
- **Stream health watchdog**: while a turn runs, three seconds without
  business events triggers a WebSocket ping. A matching pong clears the
  probe; only a probe unanswered for more than three seconds kills the
  socket. Long model/tool waits therefore do not force reconnects on a
  responsive connection. Reconnect snapshots remain anchor-gated catch-up;
  there is no history-probe RPC. This tests transport responsiveness, not
  whether the server's logical follow stream is making progress.
- **Each history response is bounded**: the snapshot and continuation pages
  request `dsh-emacs-history-window` (default 30 messages). Completing long
  rounds can require multiple requests and substantial staging memory. The
  HTTP callback dynamically raises the GC threshold for page decoding and
  rendering. Bounded network batches do not bound the total cost of the
  requested round range; staged pages still publish in one synchronous render.
- **Core connection (list side)**: the session list keeps a separate
  `/api/remote.mux` connection that opens `session/control` + `workspace/follow`
  + `$events`.  `session/control` delivers whole-host projection baselines and
  increments (since dsh 0.1.7 that record carries the `inbox` cell the queue
  mirror is derived from; the 0.1.6 `queues`/`jobs` records are gone);
  `workspace/follow` seeds and then upserts/removes/
  reorders the workspace caches; `$events` carries the session list's live
  changes (`api-session/added|removed|status|activity` emits) and the
  approval/question waterfalls.  This connection is scoped to the list buffer's
  lifecycle and is also self-healing (reconnect + re-baseline).

## History browsing (`dsh-emacs-history.el`)

The history module owns round loading and the existing Imenu question index.
It uses user-message text properties rather than maintaining another message
index. Imenu targets are advancing markers and auto-rescan refreshes loaded
questions. Previous/next question commands are not added.

`C-c C-o` requests `dsh-emacs-history-rounds` complete human rounds (default
3), overridable by a numeric prefix. A human round is a turn containing a
user-authored message; child, goal and other host-woken turns are grouped with
the human round that preceded them. The protocol constructor decodes records,
oldest/newest sequence numbers and `hasMore`; the loader derives human rounds
from the accumulated records, so a message-aligned page boundary cannot split
a turn's start from its user message. `session/page` receives `turnWindow` with
`minMessages: 1` and the remaining human-round count; because the server counts
turns, the loop repeats until enough human rounds are staged. `maxMessages`
stays bounded by `dsh-emacs-history-window`. A loaded page starts at the oldest
kept human round's `turn/start`; a leading child or goal turn is deferred to
the previous round's page instead of topping the range. A partial oldest human
round counts as the first round to complete. This uses original server round
numbers, including autonomous continuations. Opening uses the same request
builder and loop to complete only the latest human round, with no initiating
window to visit; manual loads retain their jump behavior.
See [152](../postmortem/152-open-single-round.md), which narrows the automatic
target introduced by [148](../postmortem/148-open-complete-rounds.md), and
[160](../postmortem/160-history-human-rounds.md), which defines the human
round used by both.

One buffer-local request plist stages records across bounded RPCs. Before
publishing, the loader checks request identity, session/address, the original
frontier, and strict backwards cursor progress. The opening snapshot cursor
is the stable `throughSeq` for the whole operation. Cancellation (invoking
`C-c C-o` again) invalidates the token; late callbacks cannot publish it.
Errors leave the old pagination cursor unchanged. Once enough `turn/start`
boundaries arrive, any extra prefix is discarded at the requested oldest
start, retaining the correct next cursor. Exhaustion publishes the available
range with its actual count. No unbounded single RPC or whole-session index
is needed. See [110](../postmortem/110-load-complete-rounds.md).

History insertion saves every window's point and start as advancing markers
plus horizontal/vertical scroll offsets, restoring only windows still showing
the same buffer. During insertion, fragments receive an empty following set.
Round numbers appear only in the completion message; `turn/start` events
add no transcript rows. After publication,
only the initiating, still-selected window visits the new range, and only
when its point still matches its request-time marker. The prior position
goes on the mark ring. Waiting readers who moved and other windows keep
their current views. The live event frontier is never advanced by this load.

In live chat, `dsh-emacs-ui--following-windows-function` delegates to the
stream renderer: every following window must have point at the input and
be geometrically near the bottom. Non-chat fragments retain their generic
bottom-of-buffer policy. The size cap is deferred during older-history
insertion, while a displayed window is not following, and when the input
boundary cannot be located; a cut never lands in the input area. See
[109](../postmortem/109-history-browsing.md).

`dsh-emacs--history-insert-marker` — a marker at the oldest transcript block,
insertion type `t` — takes priority in
`dsh-emacs-render--input-insert-point`, so every renderer lands there without a
per-renderer insert argument, and the marker advances so the page stacks in
order. `dsh-emacs-render-history-events` takes the page as `bound` (exclusive
seq cap) plus `:insert-before` / `:follow-p`, renders events in ascending order
so a tool call precedes its result, and skips the live path's `while-no-input`:
a settled page must not be dropped on pending input. `dsh-emacs--anchor-seq` is
deliberately NOT advanced — the page sits below the live frontier, so a
reconnect snapshot cannot replay it.

A page is identified by `dsh-emacs--history-page` (bound by
`dsh-emacs--load-older-history-page`, read through
`dsh-emacs-render--history-page-p`), never by the marker, which only positions
and may be nil. Page state — stream, pending command, todo, deliverable —
is scoped to the page, and a page cannot flush or divert a live
reply, change model/usage or step/busy indicators, consume a pending
notification, or animate a command. Its Markdown renders synchronously instead
of joining the idle queue that formats a live streaming tail. Older prompts are
appended behind newer `M-p` recall entries and trimmed from the oldest end.
Message bodies and UI fragments both carry the `dsh-emacs-transcript-block`
text property; a forward lookup finds its first occurrence, even at buffer start
after trimming. See
[044](../postmortem/044-load-older-history.md).

## Tool card ownership

Tool cards render and fold independently. The renderer tracks each call's
identity, arguments and result; the UI owns that card's fold state. Turn
boundaries and older-history pages do not maintain separate activity-group
counters. See [decision 122](../postmortem/122-remove-inactive-transcript-options.md).

`dsh-emacs-render--apply-tool-result` owns updates from both decoded stream
results and late question answers. Event sequence tracking stays at the event
entry point; projection-driven settlement updates the existing card without
constructing an event. Both callers respect tool visibility, and settled
question cards keep their original call identity and fold state. See
[decision 123](../postmortem/123-decoded-stream-and-tool-results.md).

## Chinese encoding

The dsh service returns UTF-8 JSON. The `url` library can leave its response
body in a unibyte buffer, where a direct Lisp JSON read would interpret UTF-8
bytes as separate characters. `dsh-emacs--decode-response-body` decodes those
bytes as UTF-8 and switches the response buffer to multibyte before inserting
the decoded text. `dsh-protocol-read-json` then parses that buffer. This keeps
Chinese titles, messages and tool results intact with either JSON reader.

The outbound direction has the mirror hazard: the raw-socket requests in
`dsh-emacs-server.el` (liveness probe, auth probe, launch-token exchange) are
hand-written strings ending in `\r\n`.  On Windows
`default-process-coding-system` encodes to a `-dos` coding system (its
`locale-coding-system` carries DOS line endings), which rewrites every `\n`
written to a process as `\r\n`; the request then reaches the socket as
`\r\r\n`, dsh's HTTP parser answers `400 Bad Request`, and the probe — which
counts only `200`/`401` as alive — reads a running server as down.  Every raw
HTTP socket therefore pins binary coding (`:coding 'binary`), so the bytes on
the wire are exactly the ones the code wrote.

### Live thinking refresh

The renderer inserts the first reasoning delta immediately, then queues raw
strings in reverse order on the live thinking state. One buffer-owned 100ms
one-shot timer joins and inserts the pending burst, clears the queue and
follows the viewport once. Per-event follow calls skip a pending burst.
Non-reasoning events, step changes and stream teardown flush pending text
before continuing. This keeps transport delivery immediate while limiting
reasoning-driven buffer invalidation. See [027](../postmortem/027-thinking-refresh.md).

## GUI display regression tests

Run the optional display suite from the repository root in a separate graphical
Emacs; it needs no dsh server or model provider:

```sh
DSH_GUI_TEST_LOG=/tmp/dsh-gui.log \
  emacs -Q -l "$PWD/test/dsh-gui.el" -f dsh-emacs-gui-test-start
```

Use an absolute load path as above: macOS GUI Emacs can change its working
directory during startup. The runner waits until the first frame is idle, runs
ERT, writes diagnostics to `DSH_GUI_TEST_LOG`, and exits 0 on success or 1 on
failure. Without the environment variable the log is `dsh-emacs-gui-test.log`
in Emacs's temporary directory. Batch or terminal Emacs is rejected rather
than counted as a display pass.

The Goal Row regression displays a short active goal in an 80-column window at
text scales 0 and 1, with inline actions both enabled and disabled. After real
redisplay, `vertical-motion` must reach the following buffer line in one screen
row. This catches padding that expands and wraps under text scaling even when
`string-width` still fits the canonical column budget. The ordinary verification
gate checks this file's Lisp syntax; the GUI suite itself remains optional.

## Real-server E2E testing

`emacs -Q --batch -L . -l test/dsh-e2e.el` runs the transport smoke suite.
It also opens a second real chat, switches back to the earlier chat and
presses `C-c C-l`, checking the selected session row by ID for both chats.
`DSH_E2E_URL` selects the server and `DSH_E2E_PRESET` selects the test session's
preset. When no cookie, captured/configured token or URL token is available,
the runner reads the literal `dsh-emacs-server-auth-token` saved by Customize,
without loading or evaluating user Lisp. `DSH_E2E_CUSTOM_FILE` selects a file;
otherwise an already-set `custom-file` is used. With neither, it searches
`user-init-file`, `custom.el` and `init.el` under `user-emacs-directory`, then
`~/.emacs`. The selected explicit file must be readable and local.

A saved token is reused only when the `dsh-emacs-base-url` saved in that same
file matches the test server (ignoring a trailing slash and URL query). Without
a saved address, the token belongs only to `http://127.0.0.1:3080`; overriding
the test URL does not send it to another host or port. Computed Lisp values are
not evaluated. The restored token is scoped to the run and is never printed or
written back to the user's configuration. For a nonstandard Customize path:

```sh
DSH_E2E_CUSTOM_FILE="$HOME/path/to/custom.el" \
  emacs -Q --batch -L . -l test/dsh-e2e.el
```

A stale token still fails authentication: replace it with the current launch
token or pass the authenticated URL through `DSH_E2E_URL`. The inspected dsh
0.2.0-rc.2 stores its launch token only in memory; its persisted browser signing
secret is not a token and is never read by these tests.

`DSH_E2E_PLAN_REVIEW=1` additionally exercises model-generated review.
`DSH_E2E_RUNNING=1` starts a real sleeping turn and then proves that a cold
client reopen seeds its running status from the cached host status before the
follow snapshot can replay anything (the opening window is one message), and
that cancelling the turn clears the indicator; it needs a working model
provider and a bash-capable preset.

Timed-question E2E needs a working model and a preset that configures
`@deepseek-ai/dsh-tool-ask-user` with `mode: timed`, plus the Plan capability
used by the smoke suite. Use an otherwise idle graphical Emacs connected to
that server. Disconnect other answer-capable clients for the duration: a Web
client can independently reject the shared waterfall when its countdown ends.
In the running Emacs, evaluate:

```elisp
(load "/path/to/dsh-emacs/test/dsh-e2e.el" nil t)
(let ((process-environment (copy-sequence process-environment)))
  (setenv "DSH_E2E_PRESET" "your-timed-preset")
  (dsh-emacs-e2e-run t))
```

The suite creates and archives its own sessions. It uses existing authentication
and the real minibuffer frontend, automatically entering option 2. An answer
is deliberately held past the host deadline and its actual HTTP request is
delayed another second; assertions require a live claim until acknowledgement
and the exact returned answer in the card. A second question expires while
queued, is answered through `dsh-emacs-answer-question`, and must settle through
the live projection. Duplicate submission must receive a false response and
display rejection. Rebaseline and a fresh buffer with older-history paging
must retain the saved answer.

The interactive runner preserves existing chats, the core connection, window
layout and clipboard; it never exits Emacs. It returns `(NAME PASSED DETAIL)`
records, and reports failures instead of counting an unavailable timed preset
or model as a skip. Deterministic unit tests cover deliberately reordered
snapshots and concurrent prompt exits; the E2E suite exercises live delivery.

## Subagent conversations

`dsh-emacs-subagent.el` owns the host-wide four-cell projection store, per-cell
sequence cuts, cold-read retries and minibuffer child selection. Protocol
constructors normalize identity/catalog/timing and cumulative token usage; token arithmetic
stays in `dsh-emacs-tokens.el`. The event layer feeds control deltas/baselines
and follow snapshots, and merges summary facts without replacing projection
hints. Availability is true / explicitly unavailable / unknown; disconnect
invalidates it and a generation-checked summary read restores it.
The baseline decoder rejects `migration-required` hints with a named user
error. Async cold reads retain that error and release their request token;
no hinted values enter the sequenced store. The picker skips metric reads for
external children, and opening their local chat fails before connecting.

Each child chat carries its direct-parent address. Follow, paging, prompt and
stop serialize that address in the protocol module. The entry point owns input
read-only presentation and command guards; Composer renders its reason. Cold
reads use a host-owned callback buffer so closing the originating chat cannot
strand requests. The picker reads a missing root catalog at command time and
uses standard completion with status/metric annotations. The existing session
list owns buffer-local child expansion, indented rows and ancestor reveal.
Rows carry the same direct-parent catalog entry used by the picker. Rendering
reads cached state; TAB expands only known nonempty catalogs and projection
changes repaint the list. Existing row identities preserve focus and viewport
position.
Opening the list from a child still loads missing ancestor catalogs; the
temporary render buffer retains that pending jump to show loading feedback.
Viewport restoration allows redisplay to scroll when the focused row moves
off screen, instead of forcing point into the old viewport. After row updates,
the existing `hl-line` overlay is realigned without changing its window scope.
If the focused row disappears, both buffer and window focus use the previous
row order to find the next surviving row, then the preceding row. Only a list
with no surviving candidate falls back to its first new row. See
[082](../postmortem/082-session-list-focus.md).
The list renders into a temporary buffer, deletes rows that are no longer visible,
moves surviving rows by identity with
`transpose-regions`, and diffs only individual changed lines. This preserves
xref departure markers even when workspaces reorder, without a whole-list diff.
It reapplies all row properties afterward because matching text may otherwise
retain an old child's address. Unknown and empty catalogs have no disclosure
arrow and do not respond to TAB; only confirmed children can be expanded.
There is no separate browser mode or display timer. Xref owns return history to the actual
originating chat position. See [decision record 075](../postmortem/075-subagent-conversations.md)
and navigation revisions [076](../postmortem/076-subagent-minibuffer.md) and
[077](../postmortem/077-session-list-subagents.md), with row update rationale in
[078](../postmortem/078-session-list-row-updates.md).
