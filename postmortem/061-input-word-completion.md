# 061 — Word completion from the chat buffer

_Status: Complete._

Implementation commit: `feat: complete ordinary words in the chat input`.

## Background

The chat input had two completion sources: slash commands
(`dsh-emacs-command-completion-at-point`, record 011) and `@` references
(`dsh-emacs-reference-completion-at-point`, record 010). Both own a token
grammar, and `dsh-emacs-mode` installed exactly those two in the
buffer-local `completion-at-point-functions` — replacing the global
defaults. Nothing completed an ordinary word, so a term seen in an earlier
message, a tool result, or a few words earlier in the same draft had to be
retyped or copied from the transcript.

## Decision

Add a third source, `dsh-emacs-word-completion-at-point`, last in
`completion-at-point-functions`. It completes the run of letters, digits,
`_` and `-` when that run lies inside the editable input
(after `dsh-emacs--input-marker`) and has a non-empty prefix before point.
The replacement region includes the suffix after point, so editing inside
a word cannot duplicate its tail. Candidates are the words
in the buffer above the token, found by one backward regexp scan bounded by
the new option `dsh-emacs-word-completion-limit` (default 100000
characters; nil scans the whole buffer), de-duplicated and returned
nearest-first, with display and cycle sorting metadata that preserves this
order in the front-end. Matching follows `completion-ignore-case`, the same
option the front-end filters the returned candidates with, so the two agree
about whether `stre` reaches `Streamed`. The source is registered as
`:exclusive 'no` so a user-supplied CAPF can still contribute.

## Why

The completion-at-point contract is what every front-end already speaks, so
one CAPF serves corfu, company and stock `TAB` without dsh-emacs driving a
popup — the same reason the slash and reference sources are CAPFs. The
buffer is already the data source: the transcript is right there above the
input, so no new cache, fetch or module state is needed, and the source is
correct for free after a history reload.

A backward scan never materializes the region. The review compared both
approaches on the same default 100000-character window of a roughly
267000-character documentation corpus: the implementation's scan with a
one-character prefix took 3.05 ms (949 matches, 290 unique words), versus
6.95 ms for collecting every word (10361 tokens, 2208 unique words).
That is about 2.3 times faster in that sample; it is not a comparison with
the earlier synthetic dense-match measurement or a general speedup claim.
Both approaches must scan the bounded window, but prefix filtering avoids
allocating strings and probing the hash table for nonmatching words.
Deduplication reduces the result to the distinct matching words; more
distinct matches can still produce a larger popup.

Nearest-first is useful because the user is working at the bottom of the
transcript. Hyphen joining matches this project's identifier-heavy
vocabulary (`dsh-emacs-mode`, `read-only`) in the same way `dabbrev`'s
syntax-table default would in an Emacs Lisp buffer. Filtering by the typed
prefix gives up style-only matches (`flex` scattered characters), while
prefix matches are accepted by the completion styles. Case handling reads
`completion-ignore-case` rather than inventing a `dabbrev`-style rule, so
the candidates this source returns always survive the front-end's own
filtering.

Alternatives: reusing `dabbrev` would have brought cross-buffer search and
its own user options, but `dabbrev-capf` does not exist on the 27.1
baseline, and making the custom scan diverge by Emacs version would be two
behaviors to test. Completing only the draft (cheap, no limit option) would
miss the transcript, which is where the words the user wants actually live.

## Consequence

Users get word completion in the chat input on `TAB` and through auto-popups,
documented in README and `docs/customization.md`
(`dsh-emacs-word-completion-limit`). The two token-specific sources keep
their precedence: the word source explicitly declines the command CAPF's
case-sensitive `/[a-z0-9_-]*` prefix and `@path` tokens even when the earlier
sources return nil for empty catalogs. Uppercase slash text and words after
punctuation still complete normally. Reference recognition reuses the
reference module's parser, including quoted paths.
Unit tests cover the region, transcript and draft sources, nearest-first
de-duplication, hyphen/underscore tokens,
case sensitivity with and without `completion-ignore-case`, the limit (set
and nil), and the decline cases (outside the input, empty token, no match,
command/reference token). Actual `completion-at-point` calls also cover
mid-word replacement, empty catalogs, and nearest-first stock display.

The empty-token guard in `dsh-emacs--word-completion-start` is load-bearing:
an empty prefix makes the candidate regexp match the empty string at every
position, and the backward search then never terminates. It is covered by
`word-capf-empty-token-nil` and `word-capf-empty-input-nil`.

## Known limitations

Only the current buffer is searched — unlike `dabbrev`, no other buffer or
cross-session text contributes. Words further above the limit are invisible
until the option is raised or set to nil. Candidates are not ranked by
frequency, and the option is a character count rather than a line or message
count, so its effect depends on how verbose the transcript is.

Stock Emacs and Corfu GUI acceptance checks ran on Emacs 31.1.50. Emacs 27.1
was not available locally for a manual mid-word TAB check; the package's
declared minimum version remains 27.1.
