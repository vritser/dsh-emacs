# 069 — `/name` completion follows the host's gesture boundary, catalog-confirmed mid-message

## Background

The `/` completion (record 011; merged with the skill catalog in record 067)
only answered while the **whole input** from the `❯ ` prompt to point was a
bare `/name` token: the module's `--completion-prefix-p` predicate was applied
to the entire pre-point text.  The host's gesture grammar is
`(^|\s)/name(?=\s|$)` (record 067), so a gesture is legal after **any**
whitespace, and the client's own docs advertise mid-sentence invocation
("please `/review` this diff").  A gesture typed inside a sentence therefore
could not be completed, and corfu's `/` auto-trigger — which fires wherever
the character is typed, because that contribution is unchanged — popped over a
source that had just declined.

## Decision

Complete the `/name` token that **ends at point**, wherever the host accepts a
gesture, with one shared token grammar:

- `dsh-emacs-command--completion-token-regexp` owns the shape (slash at the
  input start or after whitespace, name `[a-z0-9_-]`); the whole-input
  predicate `dsh-emacs-command--completion-prefix-p` is derived from it and
  keeps its meaning for the path/word reservation, and the menu's insert uses
  `dsh-emacs-command--completion-token-start` so "insert `/name `" replaces
  the same region completion does.
- Mid-message the token is claimed **only when the catalogs actually complete
  it** — the style-aware `completion-try-completion` gate the path source
  already uses (record 062).  Otherwise the source declines and path/word
  completion handle the text.
- At the input start the token stays this source's even when the catalog is
  empty or unavailable: the path and word sources reserve it, exactly as in
  record 062.

## Why

- **The boundary was the bug.** The source asserted client state ("the input
  starts with `/`") instead of the host's rule, so it diverged precisely where
  the documentation promised gestures worked.
- **Catalog-confirmed is the rule this module already applies.** Record 068
  refuses to accent a `/name` shape without catalog evidence because shape
  cannot tell `/usr` from `/goal`.  The same argument holds for claiming a
  completion region: mid-message `/usr` is a plausible absolute-path first
  component, so only a matching catalog entry may take the token.  At the
  input start the user is unambiguously composing a command, so the older
  reservation (empty catalog still reserves) is preserved.
- **A style-aware gate, not a filtered list.** `completion-try-completion`
  answers "would the user's own styles complete this?" without narrowing the
  candidates, so non-prefix styles (partial-completion, flex, orderless) keep
  the whole table, and a token that matches nothing never shadows the next
  source.
- **Rejected: claim every word-bounded `/token`.** It would take `see /usr`
  away from path completion — the popup would open empty and `TAB` would stop
  completing absolute paths.
- **Rejected: `:exclusive no` instead of the gate.** The metadata is Emacs
  28+; this package targets 27.1, where it is silently ignored — the same
  mid-message token would then shadow path completion on old Emacsen.  It also
  duplicates the try-completion test inside the framework's dispatcher.
- **Rejected: leave the menu insert appending at point.** Two "insert `/name `"
  paths that disagree would corrupt text: `seed the /rev` + picking `review`
  would become `seed the /rev /review `.
- **Rejected: fetch the catalog only at the input start.** Mid-message
  completion would silently not work on the first trigger of a fresh session;
  the per-session prefetch already has both catalogs cached in practice, so
  the extra synchronous fetch on a prose `/token` is rare.

## Consequence

- `/name` completes mid-sentence for commands and skills alike, and
  `M-x dsh-emacs-command` replaces such a token instead of appending to it.
- Real front-end verification (vertico, Emacs 31.1.50, `TAB` through
  `execute-kbd-macro`): `please /rev` → completion region exactly the token,
  buffer `please /review `; `see /usr` → the command source declines and path
  completion produces `see /usr/`; `please /` lists all candidates with their
  annotations; `x/rev` declines.
- Tests: `command-capf-completes-mid-sentence-token`,
  `command-capf-mid-sentence-completion-replaces-token`,
  `command-capf-declines-unknown-mid-sentence-token`,
  `command-capf-declines-slash-inside-a-word`,
  `slash-gesture-replaces-mid-sentence-token`.
- Docs updated: `docs/slash-commands.md`, `docs/skills.md`, `README.md`, and
  the completion comment in `dsh-emacs-mode`.
- The completion region for a mid-message token is the token start, not the
  input start, so the front-end replaces exactly what the user is typing.

## Follow-up: matching — the `/` list maps its category to `flex`

The original report could also be read as "the candidate must match from its
first letter", which is a different axis; measuring the two separately showed
they are independent:

- **Matching inside the name** (`/probe` → `dsh-emacs-skill-probe`) needed no
  client code — the catalog is handed to the front-end whole and
  `completion-styles` does the matching.  Measured: `basic`,
  `partial-completion`, `substring`, `initials` and `orderless` all fail on
  `/probe`, because the token's leading `/` has to match the candidate's own
  slash; only `flex` can skip into the middle of the name.
- **Token position** (`please /rev`) cannot be fixed by any style: with the
  pre-change capf the source returned nil there under `basic`, `flex` and
  `orderless` alike, so no style was ever consulted.  That is the change above.

The style axis is then made the default for this list with the mechanism `@`
references already use: `dsh-emacs-command-completion-at-point` wraps its
candidate list in `dsh-emacs--completion-table-with-metadata` carrying
`(category . dsh-emacs-command)`.  Both categories register their styles where
a package is meant to — at load time in `completion-category-defaults`, the
way `eglot-capf`, `ecomplete` and `project-buffer` do — while
`completion-category-overrides` stays the user's knob.
`completion--nth-completion` reads the category from the table and
`completion--styles` prepends the category's styles to the user's, so the list
matches with `basic` first and `flex` second (`(styles basic flex)`) and the
user's own styles follow.  The module still matches nothing itself.

**Why defaults and not a buffer-local override.**  The first cut set the
category's styles through `dsh-emacs-mode`'s buffer-local
`completion-category-overrides`, which looked scoped but silently took the knob
away from the user: the mode prepended its entry, `completion-category-get`
returns the first matching entry, and so a user's own override for the same
category was ignored even when set before the session opened (measured: with
`completion-category-overrides` set to `(styles basic)`, `/probe` still
completed).  As package defaults the same behavior is restored while a user
override wins again (`command-capf-user-style-override-wins`, and
`completion-categories-registered-as-defaults` pins the registration).
`define-completion-category` (Emacs 31+, used by `project-buffer` for a parent
category) was considered and skipped: these categories have no parent and no
properties beyond `styles`, so it would add a version guard for documentation
alone.

**Why `basic` first.** Prefixes keep stock prefix completion, while `flex`
catches `/probe`, which no prefix matches. Matching and accepting a candidate
are separate: candidate strings contain only `/name`, and the completion exit
function adds or reuses a separator when the status is `finished` or `sole`.
An `exact` match remains editable because it may prefix a longer name.

An earlier draft kept a trailing space in each candidate and tried to prevent
premature insertion by putting `basic` before `flex`. That covered ambiguous
prefixes, but `/review` matching `code-review` and `design-review` still merged
the shared space into the unfinished token. Removing the separator from the
table fixes the cause; changing matching styles alone does not. Regression
tests exercise the real completion path, including an existing separator.

**The user's configuration still wins.** Clearing
`completion-category-defaults` after this package loads removes these defaults.
A configuration that deliberately clears them can opt back in with
`(dsh-emacs-command (styles basic flex))` in `completion-category-overrides`.

**Why the table, not the CAPF plist.**  The category is read from the metadata
that `completion--nth-completion` derives, and every in-tree source declares it
in the completion table (`bookmark`, `comint`, `dabbrev`, `ecomplete`,
`help-fns`, `imenu`, `info`, `minibuffer` itself, …).  A `:category` in the
CAPF props is documented through `completion-extra-properties` and also works
(measured), but the table form is what built-ins use and what a front-end that
reads the table directly — corfu's in-region backend — sees; the props keep
carrying `:annotation-function` and `:company-kind`.  The claim gate passes the
same table, so it matches under exactly the styles the front-end will use; no
`metadata` argument to `completion-try-completion` is needed (that argument is
newer than the 27.1 baseline).  Verified by mutation: with the category
stripped from the table, `/probe` no longer completes and the mid-sentence capf
declines — the three new tests
(`command-capf-flex-matches-inside-a-name`,
`command-capf-flex-claims-mid-sentence-token`,
`command-capf-flex-still-declines-unknown-token`) go red, so they pin both
halves of the wiring.

**Cost, measured** on a realistic catalog (`compact`, `export`, `feedback`,
`goal`, `permission`, `plan` plus `review`, `notes`,
`dsh-emacs-skill-probe`): one-letter tokens keep one candidate (`/c` `/d` `/e`
`/f` `/g` `/n` `/r`), `/p` keeps two, and only `/probe` goes 0 → 1.  Flex
anchors a pattern character to a word start, so `/r` does not drag in
`…-probe`.

## Known limitations

- A mid-message token runs the module's synchronous catalog fetch on first use
  even when nothing will match; the prefetch normally prevents the round trip,
  but a fresh session with an uncached catalog pays it for prose such as
  `see /usr`.
- The catalog overrules the filesystem for a lowercase `/name` that prefixes a
  catalog entry even when the user meant a path, and a bare `/` mid-message
  lists commands and skills instead of the filesystem root.  Paths whose first
  component is outside the token grammar (uppercase or punctuation, e.g.
  `/Users`) or matches no catalog entry still complete as paths, and `./` /
  `~/` are unaffected.
- A catalog name that also exists as a real directory first component
  (`/usr`) stays with the catalog — the client has no other confirmation to
  go on without asking the host.
- Point inside the name completes the part before point only (the region ends
  at point), like every other source in this client.
- The extra `basic` + `flex` styles are unconditional package defaults, like
  the `@` reference category's `flex`: there is no option to turn them off, but
  a user's `completion-category-overrides` entry for `dsh-emacs-command`
  replaces them (the standard precedence).
