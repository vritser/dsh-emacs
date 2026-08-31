# AGENTS.md — dsh-emacs development rules

## Verification (run after every change — never skip)

**One-shot gate: `scripts/verify.sh`** — aggregated "definition of done"
check; exit 0 only when every machine-checkable step below passes. Any
FAIL there is a blocker (see step 6).

1. **Syntax check with `scripts/check-lisp.el` — MANDATORY, always first.**
   It is the only sanctioned judge of elisp syntax: every change must pass
   it; syntax errors are fixed by hand from its diagnostic report (type /
   line / column / offset / context) — never by hand-rolled counters or
   eye-counted parens.
   ```sh
   emacs -Q --batch -l scripts/check-lisp.el            # all files in dsh-check:files
   emacs -Q --batch -l scripts/check-lisp.el -- foo.el  # single file
   # exit 0 = all pass; exit 1 = failure; exit 2 = usage error
   ```
   Two-phase (forward-sexp walk + real `read` with sentinel), so it rejects
   everything `load` rejects: imbalance, stray/missing closers, unterminated
   strings, `#|` block comments, `]`/`[` cross-closing.
2. **Fixing syntax errors — by hand, from the diagnostic report, in order:**
   check-lisp never rewrites files. On failure it prints every problem at
   once, ordered by root cause (unterminated string `[first]` → missing
   closers `[second]` → stray closers `[third]`), with type / line / column /
   absolute offset / context.
   Fix in that order and **re-run after every edit**: one error can mask or
   cause others (a missing closer swallows following forms, an unterminated
   string hides everything after it, and positions in a stale report drift
   once you edit). Never batch-apply a whole report blindly.
   - Stray `)`/`]` — delete the exact character at the reported line/column.
   - Missing closers — the report lists the opener stack (innermost first,
     with coordinates). Placement is an intent judgment: appending at EOF
     silently merges later top-level forms into the open one — read the
     stack and the context before choosing where to close. After fixing,
     compare the `top-level` signature line (printed for every file)
     before/after: a fix that shrinks the form count has swallowed forms —
     reopen and re-place the closers.
   - Unterminated string — the blocker: everything after the quote is
     treated as string content (invisible), but any strays before it are
     reported too. Fix the string first (the `[first]` item), then re-run
     to see the rest.
   - Balanced-but-read-rejected (`#|` comments, `]`/`[` cross-closing,
     dangling `#'`) — reported with the original error and its line.
   - After fixing, re-run step 1 until exit 0, and review `git diff`.
   - Pass files explicitly; with no files it acts on the default list in
     `dsh-check:files` (a warning is printed in that case).
3. Full unit tests: `emacs -Q --batch -l test/dsh-test.el`; checker
   self-tests: `emacs -Q --batch -l test/check-lisp-test.el`
4. Clean load: `emacs -Q --batch -L . -l dsh-emacs.el` should print nothing
   and exit 0
5. For function-level repros prefer a minimal batch:
   `emacs -Q --batch -L . --eval '(...)'`
6. **Failures stop the pipeline**: any FAIL from steps 1–5 is a blocker —
   fix it and re-run from step 1 before moving on; never carry a failed
   check into later steps or into the final summary.

## Elisp editing discipline

- Ideally change one logic block at a time; run the mandatory syntax check
  (step 1 above) immediately after each change, before moving on
- **Structural rewrites** (changing call nesting depth, e.g.
  `(cdr (assq 'k v))` → `(accessor v)`) must keep the paren net balance
  equal between old and new snippets (`(` = +1, `)` = -1, ignoring
  comments and strings); equal balance is necessary but not sufficient —
  the read-level check via `scripts/check-lisp.el` is final
- Never count long `)` runs by eye; rely on read-level balance (a clean
  batch run of `scripts/check-lisp.el` means the file is balanced)
- Compile-time issues (undefined functions/variables, macro misuse):
  `emacs -Q --batch -L . -f batch-byte-compile <file>`
  (only look at `Error`; `Warning` can be ignored)
- Optional coverage report (testcover line/branch coverage, ~1s):
  `emacs -Q --batch -l scripts/check-coverage.el`
  prints per-definition coverage and defs below 80%; informational only —
  low coverage is a hint to add tests, not a blocker. `dsh-emacs-protocol.el`
  is excluded (testcover's edebug copy breaks cl-defstruct values)
- Scratch/probe files and test fixtures live in temp locations
  (`make-temp-file` or outside the repo tree), never in the tree itself;
  check-lisp is diagnostics-only and never rewrites files — any tool that
  does write repo files is an anomaly, and the result is reviewed via
  `git diff`.

## Protocol-layer constraint

- Wire field names (`sessionId`, `archivedSessionIds`, …) must appear
  **only** in the `--from-alist` constructors inside
  `dsh-emacs-protocol.el`; business code reads through `dsh-protocol-*`
  accessors exclusively
- Business functions that must accept legacy test fixtures use the
  `dsh-protocol--struct` compat gate to take either a wire alist or an
  already-converted struct; wire arrays are vectors and are normalized to
  lists inside the structs

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
- Recent example: `fix: restore mode-line busy after stream reconnect`

## Known pitfalls (do not repeat)

- One paren off in a big form can **leak a clause or handler into the body**:
  a `(t …)` cond clause absorbed as a second body form runs as a plain
  function call (`void-function t`) — symptoms: void-function /
  void-variable.
- check-lisp prints line / column / offset directly for every problem item,
  so no raw-error decoding is needed there. Only the `原始错误:` (raw error)
  line keeps the raw format: `scan-error` is (message start end) with start
  an absolute character offset; `invalid-read-syntax` is (object line col).
  Never count parens by eye or roll your own counters — fix in report order,
  re-run after every edit (step 2), and let check-lisp itself be the final
  judge (re-run it after any change).
- If check-lisp.el itself is unbalanced, it cannot bootstrap (the
  diagnostics build has no fixer): locate the imbalance with the last
  loadable revision (`git show :scripts/check-lisp.el`) or a mechanical
  scanner, then edit precisely — never by hand-counting.

## Definition of done (before finishing any change)

- `scripts/verify.sh` exits 0 — one-shot gate covering every machine-checkable
  step: check-lisp over `dsh-check:files`, checker self-tests, the full unit
  suite, clean load (silent), `git diff --check`, and a tree junk scan
- `git diff` reviewed for unintended changes (substantive review — not
  machine-checkable)
- Nothing committed — commits happen only when the user explicitly asks
  (enforced by the harness's auto-commit disable, not by this file)
