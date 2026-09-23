# 062 — Local file path completion in the chat input

_Status: Complete._

Implementation commit: `feat: complete local file paths in the chat input`.

## Background

Record 061 added a third input completion source (buffer words) beside the
two token owners: slash commands (`dsh-emacs-command-completion-at-point`,
record 011) and `@` references (`dsh-emacs-reference-completion-at-point`,
record 010). `@` does complete file and directory paths, but only the ones the
**host** returns from `fileReferences/list` for the agent's working directory
(`docs/rpc.md` §4.3) — nothing completed a path typed plainly, so
`docs/rp` + `TAB` did nothing, and paths outside the workspace, `./`, `~/` and
absolute paths could not be completed at all.

## Decision

Add a fourth source, `dsh-emacs-path-completion-at-point`, between the
reference source and the word source in
`completion-at-point-functions`. A token counts as a path when the run of
`[:alnum:]_.~/+-` before point contains a slash; the
completion region includes the rest of that run after point, and the
collection is the stock `completion-file-name-table`, evaluated against the
chat buffer's
`default-directory` (the session workspace, synced from the session cwd). The
source claims the token only when `completion-try-completion` finds a match
under the active completion styles, using the full region and cursor offset.
It declines slash-command prefixes and `@` reference tokens even when their
catalogs are empty. No new option.

## Why

`completion-file-name-table` is the completer `find-file` itself uses, so the
rows, case rules, `../` entries and directory drill-down are the ones users
already know, and it reports the directory part as a completion boundary —
returning a pre-filtered list instead would replace the whole token with a
base name and corrupt the path. Reusing it also keeps this module free of
filesystem code.

The separator is the signal. A chat input is mostly prose, so claiming every
token would make `doc` complete to `docs/` instead of the word the user
typed; requiring a slash is the same mental rule as find-file after the
first separator, and it keeps a lone `~` (which `completion-file-name-table`
would expand into every user account) out of the path token grammar. The
style-aware pre-check lets prose containing a slash
fall through when no path matches, while allowing directory shorthand such
as `./s/re` to reach `./sub/report.md` with `partial-completion`.
Once a match exists, the source uses the default exclusive CAPF behavior:
stock Emacs checks non-exclusive sources with a raw `try-completion`, which
would reject the shorthand even after our style-aware check succeeds.
Including the suffix prevents a mid-path TAB from duplicating it.

Slash-command token recognition belongs to the command module. Its shared
predicate is used by command, path and word completion, so the same
case-sensitive prefix stays reserved across all three even when the catalog
is empty or unavailable. The reference module similarly owns `@` parsing.

Completion reads the local filesystem, which is consistent with the other
client-side file features (`!` shell lines, `dsh-emacs-attach-file`) and
needs no round trip. Alternatives: extending the `@` query to local paths
would have mixed two resolutions (server workspace versus Emacs host) behind
one token; a dedicated path module was not worth a file for one CAPF.

## Consequence

Users can complete `docs/rp`, `./src/`, `~/…` and absolute paths on `TAB`, and
auto-popups under corfu/company follow the same source. A bare name stays a
word, and `@` keeps its host-resolved menu. README and the CHANGELOG entry
describe the split; unit tests in `test/dsh-test.el` cover relative
completion, directory drill-down, the separator requirement, the `@` and
prose-slash declines, absolute paths, mid-path replacement, directory
shorthand, empty/failed command catalogs and the token boundary at punctuation.
Filesystem cases use a `make-temp-file` directory; command isolation uses a
deterministic file table, so neither depends on the checkout or system root
layout. The mode-wiring test pins the four-source order. Real TAB commands in
stock Emacs and Corfu GUI sessions also verified suffix handling and directory
shorthand on Emacs 31.1.50.

`skip-chars` sets do not take a hyphen in the middle: `"_-.~"` starts a range
and silently drops both characters, so the path set ends `"…+-"`. The first
draft of the constant did exactly that, and an absolute-path TAB completed
the wrong token; the comment on `dsh-emacs--path-completion-chars` records it.

## Known limitations

Paths with spaces are not completed in plain text — the token ends at the
space; use a quoted `@` reference, which the reference grammar owns. A dsh
server on another host resolves `@` in its own working directory, while this
source reads the machine Emacs runs on, so `@` is the right tool there. Bare
file names do not complete from the filesystem (that is the word source's
token space), and there is no host ranking, ignore rules or `.gitignore`
filtering — this is raw local filename completion.

At the start of the input, `/name` belongs to command completion. Continue
with another `/` or put the absolute path after prose to disambiguate it.

A lone `~` is not a path token (the word source declines it too), so the
every-user list `completion-file-name-table` would produce there is never
offered; `~/` and `~user/` still complete because they carry the separator.

Case follows `completion-ignore-case`, the option the front-end filters with
in a non-minibuffer buffer.  `read-file-name-completion-ignore-case` has no
effect here — binding it inside the CAPF alone would make the claim test
accept a match the front-end then filters out — so on a case-sensitive
filesystem, set `completion-ignore-case` to complete a wrong-case prefix.
