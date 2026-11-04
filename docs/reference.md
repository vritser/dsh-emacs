# @ References (file & session mentions)

After opening a file or session reference, `M-,` returns to the exact departure
position through Emacs's xref history. Local Markdown links, including line
and column targets within the same file, support the same return command.
Missing targets and cancelled navigation leave the return history unchanged.

The `@` directive brings relevant work from the current workspace or from
**another conversation** into a new message without resuming or forking the
source session — dsh web's cross-session reference feature, mirrored in
dsh-emacs. Typing `@` after the `❯ ` prompt opens a **combined menu**: file
and directory candidates first, then session candidates.

A path typed **without** `@` completes locally instead — on the machine Emacs
runs on, relative to the chat buffer's working directory — through the stock
file-name completer (see the completion note in the README). The two do not
mix: `@` rows are the workspace candidates the host ranks, while a plain path
is the local file system. Plain path completion includes the suffix after
the cursor and uses the active filename completion styles. A leading
`/name` remains a slash-command prefix; continue with another `/` or put the
absolute path after prose to disambiguate it.

dsh-emacs only builds the menu (the composer side). Both endpoints are the
same typert Remotes the web client uses — `fileReferences/list` and
`sessionReferenceResolver/candidates` — and **snapshot preparation lives on
the host**: when a session mention travels inside an ordinary
`session.prompt`, the server's `agent/pre-step` listener parses it, freezes
the source session (projected through the canonical surface algorithm, with
an untrusted-background warning for the model), and injects it right after
your message. dsh-emacs ships no cross-session read logic of its own.

## The two candidate kinds

- **Files & directories** — path-only candidates inside the session's working
  directory, ranked deterministically by the host. Rows are grouped **files
  before directories** (the host ranks directories ahead of files on equal
  scores; dsh-emacs shows files first), with sessions after both. Picking a
  file inserts
  `@path`; picking a directory inserts `@dir/` and **keeps the menu open for
  the next level** (drill-down), the same continuation the web shows below a
  directory's trailing slash. When nerd-icons or all-the-icons is loaded,
  file/directory rows carry a per-type icon column (consult-buffer style):
  the glyph follows the file's extension (`.ts` → TypeScript icon), the
  folder glyph for directories, the generic file glyph for extension-less
  paths; disable with `dsh-emacs-reference-inline-icons`. The icon is
  display-only — picking still inserts the plain mention.
- **Sessions** — candidates matched by session id, cwd or latest title, ranked
  by working-directory affinity. Rows are the short `@label` (a ` #n` suffix
  disambiguates repeated labels) — the same row the web shows — so the popup
  width is never stretched by the opaque mention payloads. Like file/directory
  rows, session rows carry a per-type icon in the same column — nerd-icons
  draws its `references` glyph, all-the-icons a link glyph; disable with
  `dsh-emacs-reference-inline-icons`. Picking one rewrites the row, via the
  completion `:exit-function`, into the host's
  **canonical mention** `@[label](dsh-session:…)`; the id payload is opaque
  and the label is display-only, so renaming the source session later never
  breaks the reference.

Rows show only the candidate text, plus the optional type icon: file rows,
directory rows, and session rows have no path, workspace, age, or other
completion annotation. Repeated session labels still receive a ` #n`
suffix so each source session remains selectable.

## Grammar (same as dsh web's `grammar.ts`)

An active token is `@path` or `@"path with spaces` that starts at the start
of the input line or right after a space and runs to the cursor. `@` inside
another token — `mail@example` — is **not** a trigger. Paths containing
spaces are inserted in the quoted form (`@"my dir/file"`); typing `@"`
yourself keeps the quote open after a directory pick so completion descends.

Token detection scans backward in the editable buffer and copies only the
active token. Large pasted drafts are not copied for each completion check;
the typing watcher also reuses its first detection result.

## Four ways to insert a reference

- **Type it**: `@sr` + `C-c C-c` — the mention travels as plain text; no
  client-side handling after that.
- **Trigger popup**: dsh-emacs is a completion backend — it contributes `@`
  to whichever front-end already has its own auto mode on, and that front-end
  pops the list when you type `@`. With corfu-auto, `@` is added
  buffer-locally to `corfu-auto-trigger` so Corfu pops and filters as you
  type; company reaches the buffer's capf through `company-capf` and
  auto-shows on its idle delay. Stock `*Completions*` / vertico / icomplete
  have no auto channel and complete on `TAB`. Disable the `@` contribution
  with `dsh-emacs-reference-auto-complete` (`TAB` and
  `M-x dsh-emacs-reference` always work).
- **Menu**: `M-x dsh-emacs-reference` offers the combined cache (files,
  directories, sessions) and refreshes it asynchronously. On a cold cache it
  reports loading; invoke it again after results arrive.
- **Completion**: `TAB` completes the active `@` token over the current cache.
  Matching ignores case: `@re` finds `README.md`. Paths match substrings or
  ordered characters, so `@button` finds `src/components/ui/button.tsx`.
  Session matches can come from their label, ID or workspace, even when that
  field is not displayed. Fresh results keep the host's matching decisions;
  while loading, the client searches those fields in the previous cache.
  Opening quotes do not become part of the search: `@"src/a` can complete to
  `@"src/a.ts"`, preserving explicit quotation. The completion category
  `dsh-emacs-reference` defaults to the package's `dsh-emacs-reference-search`
  style; `completion-category-overrides` can replace it with your preferred
  styles.

An ambiguous exact match stays editable: with both `a` and `ab` available,
`TAB` at `@a` does not turn it into a chip. Pick a row or finish an unambiguous
completion to accept the reference.

Session suggestions mirror the session list: archived, blank (never-messaged)
and subagent-origin sessions are not offered, in `@` completion or in the
explicit menu. Archived ids are filtered through the synced archive registry,
so they stay hidden even before `session/list` has loaded; the other kinds use
that cache, and a candidate whose session it does not know stays offered.
Archive/unarchive updates are reflected the next time candidates are read,
including in an existing completion table; a session that receives its first
message appears on the next completion. The raw cache is not rewritten, so
this never deletes sessions or changes mentions already inserted in a draft.

Menu rows are short by design: a file names its path, a directory its path
with a trailing slash, a session only its label. Picking a file or directory
inserts its formatted mention (`@path` / `@path/`); picking a session inserts
its short `@label` as the wire-composing form — the long canonical mention
never appears in the popup, and the buffer keeps the short label (expanded to
the canonical only in the sent message).

A **completed session mention is atomic**: once a reference sits in the input
it is no longer completion-active, so typing after it never re-opens the menu
and `M-x dsh-emacs-reference` will not swallow it (the web renders the same
mention as an atomic chip). In the composer the completed session mention
renders as an **atomic chip**: the buffer keeps the short `@label` text you
picked, with the canonical `@[label](dsh-session:…)` text stored in a text
property, and the whole short span is treated as one unit for editing
(backspace removes it all; `C-k` on the chip removes it too; typing on it hops
the cursor past it rather than splitting the mention) and RET/mouse-1 jumps to that session. Sending (and the
history copy) expands the short label back to the canonical mention, so the
wire is unchanged — no `display` folding hides a long text behind the label,
the buffer text is exactly what you see. Completed file picks are equally
atomic chips that keep their own `@path` (already the wire text): a backspace
(or `C-k` on it) removes the whole mention and RET/mouse-1 opens the file. A mid-drill
directory token (`@dir/`) is left plain so typing can descend further.

## Caching (stale-while-revalidate)

Both discovery requests run **asynchronously**, including the first `@` or
`TAB`. The cache changes only after both replies settle; late replies from a
completed reference cannot replace a newer request. Repeated reads share one
request, and changed queries use `dsh-emacs-reference-fetch-delay` to debounce
while cached results remain usable. A running request hands off to the latest
query rather than replaying intermediate keystrokes. Empty queries and directory
drills bypass the ordinary debounce.

With corfu-auto enabled, fresh results update the active reference popup in
place, or open a cold popup through Corfu's deferred path. They do not insert
text, steal another buffer's focus, or restart a dismissed popup after `C-g`.
Other frontends read the refreshed table on their next completion; if a cold
`TAB` has no results yet, press `TAB` again after discovery finishes.

Bare-query lists are **pre-fetched** when a session opens for every frontend,
including Corfu (`dsh-emacs-reference-prefetch`, idle gap
`dsh-emacs-reference-prefetch-delay`). A query already started by the user takes
precedence. By default all host-returned results are offered, not necessarily
all files in the workspace: the host can limit a query's results. Set
`dsh-emacs-reference-max-files` or `dsh-emacs-reference-max-sessions` to cap a
section further; `nil` keeps every host result. Server discovery latency still
exists, but no synchronous discovery request blocks completion.

## What the server-side mention costs the target session

References are read-only: the source log is never modified, resumed or
granted authority. The injected snapshot is untrusted background — the server
warns the model not to follow instructions from it unless the current user
repeats them — and target compaction folds it like any other history. Up to
three references per message, each independently size-capped, enforced by the
host.

> Note: on the transcript, a *user* message that echoes a completed `@`
> reference renders it as a clickable link instead of the raw text — a session
> mention shows just its `@label` (the opaque id is never displayed), a file or
> directory mention keeps its `@path`. Any boundary `@word` is treated as a
> file reference (so extensionless files like `@LICENSE` link too); only
> obvious non-references are skipped — a `@` inside a word such as an email
> (`mail@example`) and a lone `@`. RET or mouse-1 opens the reference: a
> session jumps to that session's chat buffer, a file opens under the session's
> working directory (`find-file` of `cwd + path`). The same collapse applies
> wherever a goal objective is shown — the Goal Row and its tooltip,
> `C-c C-g ?` and the goal tool card — since a goal objective is a projection
> of the message that named it. The buffer still holds the
> canonical text, so the wire is unchanged. Assistant bodies render via the
> markdown layer and are not linkified. When history is re-seeded by a
> `session/follow` snapshot (a first or cold open, or a reconnect), dsh may
> already have collapsed a sent session mention to its readable
> `@label` (the canonical id is not in the message text); the real
> `sessionId`/`label` then arrive in the immediately-following
> `session-reference` recall context, and the reseed renderer pairs them so
> the `@label` still links and jumps correctly.

## Assistant Markdown file links

Assistant replies can contain explicit Markdown links to local files, with
any label (including a function name). RET or mouse-1 opens the target using
the chat working directory captured when the link was rendered, even if a
later click is dispatched from another buffer. A function name in the label
is display text, not a symbol lookup.

- Prefer `[label](<path with spaces (draft).el#L10>)` for paths with spaces.
  Bare destinations accept balanced parentheses (up to 32 levels) and ASCII
  punctuation escapes such as `\(`. An optional quoted or parenthesized title
  is parsed, not appended to the file name; titles are not displayed.
- `#L10`, `#L10-L20`, `#L10-20`, `:10` and `:10-20` navigate to the start
  line, without selecting a range. `#L10C3` and `:10:3` additionally position
  at the one-based character column. Zero, leading-zero and reversed ranges
  are rejected. Valid positions beyond the file/line end are clamped;
  a narrowed destination buffer is widened for an explicit position.
- URI escapes are decoded exactly once, after splitting the position suffix:
  `%20` is a space, `%2520` is a literal `%20`, `%23` is a literal `#`, and
  `%3F` is a literal `?`. Invalid escapes, controls and unencoded queries are
  rejected. Use percent encoding for reserved characters in actual names.
- Native `file:` URLs remain supported, including an empty authority or
  `localhost`. Other authorities, explicit credentials/ports and TRAMP/UNC
  destinations are not local links. These native file URLs and colon/column
  positions are Emacs extensions: the audited Web client does not accept
  `file:` links and supports only `#L10` / `#L10-L20` line positions.
- Only HTTP, HTTPS and mailto links go to `browse-url`. Missing local files,
  invalid positions and unsupported schemes report a local error; they do not
  fall through to the browser or silently create a new file buffer.

Images use the same local path decoding and chat working directory, including
ordinary relative destinations such as `![preview](images/plot.png)`. The file
must be readable, regular and image-supported, and Emacs must have a graphical
display. Missing files, remote HTTP(S) images and non-graphical displays keep
image syntax rather than fetching content. A standalone image with a simple
absolute, `./` or `../` path containing spaces retains the limited legacy/Web
compatibility; use angle brackets when the name also contains parentheses,
quotes or other Markdown delimiters.

Explicit bare path lines are literal filesystem paths, not percent-encoded
Markdown URLs; bare `file://` lines still use URI semantics. Literal paths
do not consume backticks or deletion markers in filenames;
a bare image waits for a newline or final message before acquiring display
and click properties. `@` references and deliverables likewise keep literal
paths and their existing session-cwd navigation; they do not gain Markdown
URI decoding or line-suffix parsing.

This is a single-line inline-resource renderer, not a complete CommonMark AST.
Multiline labels/destinations, reference-style links and HTML entity references
in destinations are not resolved as file links. Entity-bearing resources stay
literal rather than guessing a target. Inline code delimiters must close with
a backtick run of the same length on the same line; fenced code and unfinished
inline code keep their protection. See the [resource boundary decision](../postmortem/150-markdown-resource-boundaries.md).
