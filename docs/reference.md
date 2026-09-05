# @ References (file & session mentions)

The `@` directive brings relevant work from the current workspace or from
**another conversation** into a new message without resuming or forking the
source session — dsh web's cross-session reference feature, mirrored in
dsh-emacs. Typing `@` after the `❯ ` prompt opens a **combined menu**: file
and directory candidates first, then session candidates.

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
- **Menu**: `M-x dsh-emacs-reference` — `completing-read` over the combined
  cache (files, then directories, then sessions), replacing the active `@`
  token at point.
- **Completion**: `TAB` completes the active `@` token over the cache (a bare
  `@` lists everything). `TAB` is bound to `completion-at-point` in chat
  buffers. Matching is **flexible**: the `@` completion category is bound to the
  built-in `flex` style in chat buffers (independent of your global
  `completion-styles`), so typing a word that appears *anywhere* in a path — e.g.
  `@button` or just `@bu` — narrows to files like
  `@src/components/ui/button.tsx`, not only prefix matches.

Menu rows are short by design: a file names its path, a directory its path
with a trailing slash, a session only its label. Picking a file or directory
inserts its formatted mention (`@path` / `@path/`); picking a session inserts
the canonical `@[label](dsh-session:…)` text — the long mention never
appears in the popup, only in the sent message.

A **completed session mention is atomic**: once `@[label](dsh-session:…)`
sits in the input it is no longer completion-active, so typing after it never
re-opens the menu and `M-x dsh-emacs-reference` will not swallow it (the web
renders the same mention as an atomic chip). In the composer the completed
session mention renders as an **atomic chip**: the buffer keeps the canonical
text (so the wire is unchanged) while the display collapses to just `@label`,
the whole mention is treated as one unit for editing (backspace removes it
all; typing on it hops the cursor past it rather than splitting the mention),
and RET/mouse-1 jumps to that session. Completed file picks are equally
atomic chips that display their own `@path` (no collapse needed — the path is
the wire text): a backspace removes the whole mention and RET/mouse-1 opens
the file. A mid-drill directory token (`@dir/`) is left plain so typing can
descend further.

## Caching (stale-while-revalidate)

The first `@` trigger synchronously fetches both Remotes (the same one-time
round trip the slash catalog makes on first `TAB`). Under corfu-auto that
initial table is filtered natively on every edit and backspace, while a
data-fetch watcher refreshes changed queries from the host in the background;
a trailing slash is an explicit directory drill whose settled results reopen
the popup via corfu's own deferred path. Non-corfu setups answer from the
previous query's cache while the new query is fetched in the background, so
typing never blocks on the network.

The bare-query lists are **pre-fetched** when a session opens for non-Corfu
completion (`dsh-emacs-reference-prefetch`, idle gap
`dsh-emacs-reference-prefetch-delay`); Corfu owns its first fetch so its
native popup lifecycle stays intact. By default all host-returned files,
directories, and sessions are offered. Set
`dsh-emacs-reference-max-files` or `dsh-emacs-reference-max-sessions` to a
number to cap a section when working with a very large index; `nil` keeps all
results.

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
> working directory (`find-file` of `cwd + path`). The buffer still holds the
> canonical text, so the wire is unchanged. Assistant bodies render via the
> markdown layer and are not linkified.