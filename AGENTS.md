# AGENTS.md — dsh-emacs development rules

Emacs client for the dsh server: chat UI, session/workspace management, RPC
over WebSocket with a polling fallback. Entry file `dsh-emacs.el`; module
ownership map in `docs/architecture.md`.

- **Baseline: Emacs 27.1** (`;; Package-Requires: ((emacs "27.1"))` in every
  file header). Do not silently raise it; a raise must update all headers,
  README, and CHANGELOG in the same change.
- Do not use Emacs 28+/30+ APIs without a version guard or a local fallback.

## Core principles

- **Question every abstraction**: add a layer, file, or indirection only when
  it solves a current problem; prefer simpler code and clear ownership over
  speculative structure.
- **Refactors must produce net value**: a concrete gain in simplicity, code
  size, robustness, or test value. Moving code, renaming layers, or adding
  wrappers without making the system easier to understand is not a refactor.
- **Root out helper stacking**: one-use wrappers, pass-through functions, and
  accessor piles around a single call site are debt — fix the missing
  ownership boundary, don't add another helper tier.
- **Delete, don't deprecate**: remove unused code entirely; no compatibility
  shims or "removed" tombstones. The one sanctioned compat seam is
  `dsh-protocol--struct` (accepts wire alist or struct, for legacy fixtures).
- **Prefer lightweight Elisp shapes**: `let*`, `pcase-let`, alists/plists for
  short-lived context; `cl-defstruct` is reserved for protocol payloads that
  cross module boundaries (that is exactly `dsh-emacs-protocol.el`).
- **Reduce code by improving the model**: simpler state and control flow, not
  dedup-for-its-own-sake or file extraction to look tidy.

## Verification (run after every change — never skip)

**One-shot gate: `scripts/verify.sh`** — the aggregated "definition of done"
(check-lisp over `dsh-check:files`, checker self-tests, full unit suite, clean
load silent, `git diff --check`, tree junk scan). Exit 0 only when everything
passes; any FAIL is a blocker (see rule 6 below).

The manual loop, in order:

1. **Syntax check with `scripts/check-lisp.el` — MANDATORY, always first.**
   The only sanctioned judge of elisp syntax; every change must pass it.
   Two-phase (forward-sexp walk + real `read` with sentinel), so it rejects
   everything `load` rejects: imbalance, stray/missing closers, unterminated
   strings, `#|` block comments, `]`/`[` cross-closing.
   ```sh
   emacs -Q --batch -l scripts/check-lisp.el            # all files in dsh-check:files
   emacs -Q --batch -l scripts/check-lisp.el -- foo.el  # single file
   # exit 0 = all pass; exit 1 = failure; exit 2 = usage error
   ```
   Pass files explicitly; with no files it acts on the default list in
   `dsh-check:files` (a warning is printed in that case).
2. **Fixing syntax errors — by hand, from the diagnostic report, in order**
   (the playbook below); then re-run step 1 until exit 0.
3. Full unit tests: `emacs -Q --batch -l test/dsh-test.el`; checker
   self-tests: `emacs -Q --batch -l test/check-lisp-test.el`
4. Clean load: `emacs -Q --batch -L . -l dsh-emacs.el` should print nothing
   and exit 0
5. For function-level repros prefer a minimal batch:
   `emacs -Q --batch -L . --eval '(...)'`
6. **Failures stop the pipeline**: any FAIL from steps 1–5 is a blocker —
   fix it and re-run from step 1 before moving on; never carry a failed
   check into later steps or into the final summary.

### check-lisp repair playbook

check-lisp never rewrites files. On failure it prints every problem at
once, ordered by root cause (unterminated string `[first]` → missing
closers `[second]` → stray closers `[third]`), with type / line / column /
absolute offset / context. Fix in that order and **re-run after every
edit**: one error can mask or cause others (a missing closer swallows
following forms, an unterminated string hides everything after it, and
positions in a stale report drift once you edit). Never batch-apply a
whole report blindly.

- Stray `)`/`]` — delete the exact character at the reported line/column.
- Missing closers — the report lists the opener stack (innermost first,
  with coordinates). Placement is an intent judgment: appending at EOF
  silently merges later top-level forms into the open one — read the
  stack and the context before choosing where to close. After fixing,
  compare the `top-level` signature line (printed for every file)
  before/after: a fix that shrinks the form count has swallowed forms —
  reopen and re-place the closers.
- Unterminated string — the blocker: everything after the quote is treated
  as string content (invisible), but any strays before it are reported too.
  Fix the string first (the `[first]` item), then re-run to see the rest.
- Balanced-but-read-rejected (`#|` comments, `]`/`[` cross-closing, dangling
  `#'`) — reported with the original error and its line. Only the
  `原始错误:` (raw error) line keeps the raw format: `scan-error` is
  (message start end) with start an absolute character offset;
  `invalid-read-syntax` is (object line col). Everything else prints line /
  column / offset directly — no raw-error decoding needed.
- After fixing, review `git diff`.

## Elisp editing discipline

- Change one logic block at a time; run the mandatory syntax check
  (verification step 1) immediately after each change, before moving on
- **Structural rewrites** (changing call nesting depth, e.g.
  `(cdr (assq 'k v))` → `(accessor v)`) must keep the paren net balance
  equal between old and new snippets (`(` = +1, `)` = -1, ignoring comments
  and strings); equal balance is necessary but not sufficient — the
  read-level check via `scripts/check-lisp.el` is final
- Never count long `)` runs by eye; rely on read-level balance (a clean
  batch run of `scripts/check-lisp.el` means the file is balanced)
- Compile-time issues (undefined functions/variables, macro misuse):
  `emacs -Q --batch -L . -f batch-byte-compile <file>`
  (only look at `Error`; `Warning` can be ignored)
- Intentional lazy/cyclic module boundaries: add `declare-function` /
  `defvar` forward declarations rather than new top-level `require`s; a
  `declare-function` pointing at another package's private (`--`) symbols
  is a design smell — move the interface to the owner module instead
- Scratch/probe files and test fixtures live in temp locations
  (`make-temp-file` or outside the repo tree), never in the tree itself;
  check-lisp is diagnostics-only and never rewrites files — any tool that
  does write repo files is an anomaly, and the result is reviewed via
  `git diff`.

## Naming and style

- **Public symbols use `dsh-emacs-`; private, `dsh-emacs--`.** No double dash
  for anything user-facing (commands, options, faces). Exceptions by design:
  `dsh-emacs` (the mode) and `dsh-protocol-*` / `dsh-protocol--*` (struct
  accessors and helpers in the protocol module).
- Files of the same `dsh-emacs-*` subsystem may call each other's `--`
  symbols (they are one package), but must carry `declare-function` /
  `defvar` declarations so byte-compilation stays honest.
- `dsh-check:*` is the internal namespace of `scripts/check-lisp.el` (a dev
  tool, not package API).
- Lowercase words separated by hyphens; no `snake_case` or `camelCase`.
  Predicates: single-word names end in `p`, multi-word in `-p`.
- Prefix unused lexical variables and arguments with `_`.
- Emacs indentation is authoritative: indent with spaces, no hard tabs, no
  manual alignment against the text; keep lines near 80 columns where
  feasible; trailing closers stay together; blank line between unrelated
  top-level forms.
- Prefer flat control flow: `if-let*`, `when-let*`, `pcase`, `pcase-let`
  over deep `let` → `if` nesting; `when` for one positive branch, `unless`
  for one negated branch; no redundant `progn`.
- Destructure instead of repeated accessors (`pcase-let` over multiple `nth`
  / `plist-get`); `cl-loop` over `dolist` + manual accumulators; `dolist`
  (not `mapcar`) when the result is discarded.
- `#'function-name` when passing a function value in executable code; named
  functions (not forwarding lambdas) for hooks, advice, and long-lived
  registrations.
- Macros only for syntax: if a function can express the behavior, use a
  function; every new/modified macro declares its `cl-edebug` spec and an
  `indent` property when the body isn't a plain call shape.
- State placement: `defcustom` under `defgroup dsh-emacs` for user options,
  plain `defvar` for shared state, `defvar-local` for buffer state (chat
  buffers keep their session/process state buffer-local).
- Comments and docstrings may be English or Chinese — the tree mixes both;
  match the file you are editing.

## Architecture and boundaries

- **One responsibility per file**, per the module map in
  `docs/architecture.md`: wire payloads → `dsh-emacs-protocol.el`; push-frame
  dispatch and transport → `dsh-emacs-events.el`; buffer rendering →
  `dsh-emacs-render.el`; faces/theme → `dsh-emacs-faces.el`; session list UI →
  `dsh-emacs-session.el`; mode-line → `dsh-emacs-modeline.el`; server
  lifecycle → `dsh-emacs-server.el`. Do not mix protocol parsing with
  rendering.
- **`dsh-emacs.el` is the entry point and RPC client** — new self-contained
  feature surfaces belong in the owning module, not in a growing grab bag.
- **Loading a file must not change editing behavior** (no modes enabled, no
  hooks fired); registration side effects allowed at load are package-level
  ones (`auto-mode-alist`, `add-to-list 'minor-mode-map-alist`, …). The
  clean-load check (verification step 4) must stay silent.
- Reuse stock Emacs infrastructure (`completing-read`, `read-only-mode`,
  standard hooks) before inventing parallel mechanisms.

## Protocol-layer constraint

- Wire field names (`sessionId`, `archivedSessionIds`, …) must appear
  **only** in the `--from-alist` constructors inside
  `dsh-emacs-protocol.el`; business code reads through `dsh-protocol-*`
  accessors exclusively
- Business functions that must accept legacy test fixtures use the
  `dsh-protocol--struct` compat gate to take either a wire alist or an
  already-converted struct; wire arrays are vectors and are normalized to
  lists inside the structs

## Diagnosis and error handling

- **Find the root cause before changing behavior**: do not patch UI timing,
  cache invalidation, or command flow until you can name the failing layer
  (transport / protocol / events / render / modeline / UI) and explain why
  it is responsible.
- **One failed fix narrows the hypothesis; two stop the patching loop**:
  after two failed fixes on the same issue, switch to diagnosis only — no
  third speculative patch.
- **Fix the right layer**: if the real problem is in the RPC/events stream or
  the protocol structs, move the fix there instead of compensating in the
  renderer or mode-line.
- **Errors must surface, not hide**: no `condition-case nil` swallowing
  internal failures; only boundary code (RPC callbacks, process filter,
  top-level command) converts exceptions into messages.
- `user-error` for user-caused problems, `error` for programmer bugs; error
  text describes the current problem, not a lecture about what to do next.
- Flag compensating code (silent fallbacks, re-reading data a caller already
  has, timing hacks) as design debt in the final summary or a docs note —
  do not let debt discovery delay the current change.

## Testing

- **Tests must fail when the code is wrong**: assert specific, distinguishable
  output values; if breaking the function under test doesn't turn the test
  red, the test is worthless.
- **Red before green for real bug fixes**: write the failing reproduction
  first; updating an existing test that already proves the path is
  sufficient for small expectation changes.
- **Match test weight to change size**: comments, docs, and mechanical
  refactors are not red/green exercises; for pure cosmetic tweaks (face,
  padding, truncation, display order) don't add tests unless the text
  carries a real contract (state visibility, command availability, previously
  regressed behavior).
- Unit tests live in `test/dsh-test.el` (ERT, no server needed); checker
  self-tests in `test/check-lisp-test.el`. `test/dsh-e2e.el` drives a **real
  dsh server** and is deliberately outside the verify gate — run it manually
  when touching the event stream / RPC round-trip paths.
- Mock the RPC seam (`dsh-emacs--rpc-async` et al.) instead of spawning
  servers in unit tests; fixtures are wire-shaped alists fed through the
  compat gates.
- Optional coverage report (testcover line/branch, ~1s):
  `emacs -Q --batch -l scripts/check-coverage.el` — per-definition coverage,
  defs below 80%; informational only, low coverage is a hint not a blocker.
  `dsh-emacs-protocol.el` is excluded (testcover's edebug copy breaks
  cl-defstruct values).

## Documentation and changelog

- Any user-visible change (behavior, keybindings, defaults, `defcustom`s)
  adds a `CHANGELOG.md` entry in the same change, under
  `## X.Y.Z - Unreleased` (the planned next version — pre-1.0: fixes →
  patch, features → minor; unreleased sections stay undated, the date is
  filled in only when the release is cut). If a `Breaking Changes`
  category is needed, it goes before `Added`. Single-concern entries:
  one bold lead + what users experience, not a commit dump.
- Pre-1.0 breaking changes (renamed/removed public options without
  aliases) are listed under `Breaking Changes` of the next minor; no
  compat shims are retained (see Core principles).
- Keybinding / default / customization changes also update `README.md` and
  the matching `docs/*.md` (customization, modeline, slash-commands, …) in
  the same change.
- If code and docs diverge, treat code as source of truth and fix the docs
  immediately; never invent commands, capabilities, or behaviors in docs —
  verify them from code or tests.

## Commit

- **Auto-commit is disabled**: only commit when the user explicitly says
  so; keep changes in the working tree until then. `git add` (staging)
  without committing is fine when needed.
- **One atomic commit per topic**: changes mixing several concerns (e.g. a
  `feat` and a `fix`) are split into one commit per concern first; a
  subject that needs several topics is a sign to split further.
- Conventional Commits, English single-line summary — **keep it short**:
  one concise clause `<type>: verb + what changed`, e.g.
  `fix: restore mode-line busy after stream reconnect`. Do not enumerate
  details in the subject line (long multi-clause summaries get reworded).
- Local, unpushed history may be rewritten (reword/split/rebase) when the
  user asks for it.
- Standard types (Angular convention, all usable):
  - `feat:` new feature / `fix:` bug fix
  - `docs:` documentation (README/AGENTS/IMPLEMENTATION)
  - `style:` formatting, `refactor:` (no behavior change), `perf:` perf
  - `test:` tests, `build:` build, `ci:` CI, `chore:` misc, `revert:` rollback

## Known pitfalls (do not repeat)

- One paren off in a big form can **leak a clause or handler into the body**:
  a `(t …)` cond clause absorbed as a second body form runs as a plain
  function call — symptoms: void-function `t` / void-variable. The
  read-level check catches the imbalance; the runtime symptom tells you
  which form to re-read.
- If `check-lisp.el` itself is unbalanced, it cannot bootstrap (the
  diagnostics build has no fixer): locate the imbalance with the last
  loadable revision (`git show :scripts/check-lisp.el`) or a mechanical
  scanner, then edit precisely — never by hand-counting.

## Definition of done (before finishing any change)

- `scripts/verify.sh` exits 0 — one-shot gate for every machine-checkable
  step
- `git diff` reviewed line-by-line for unintended changes (substantive
  review — not machine-checkable)
- CHANGELOG / affected docs updated in the same change when user-visible
- Nothing committed — commits happen only when the user explicitly asks
  (enforced by the harness's auto-commit disable, not by this file)
