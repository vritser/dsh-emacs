# AGENTS.md — dsh-emacs development rules

## Verification (run after every change — never skip)

- One-shot paren balance check (all 11 files):
  ```sh
  emacs -Q --batch -l scripts/check-lisp.el
  # single file: emacs -Q --batch -l scripts/check-lisp.el -- foo.el
  # exit 0 = all pass; exit 1 = failure (invalid-read-syntax "]" N etc.)
  ```
  Full unit tests: `emacs -Q --batch -l test/dsh-test.el`
- Clean load: `emacs -Q --batch -L . -l dsh-emacs.el` should print nothing and exit 0
- For function-level repros prefer a minimal batch: `emacs -Q --batch -L . --eval '(...)'`

## Elisp editing discipline

- Ideally change one logic block at a time; verify with the commands above
  immediately after each change, before moving on
- **Structural rewrites** (changing call nesting depth, e.g.
  `(cdr (assq 'k v))` → `(accessor v)`) must keep the paren net balance
  equal between old and new snippets (`(` = +1, `)` = -1, ignoring
  comments and strings; use check script below)
- Never count long `)` runs by eye; rely on **read-level balance**
  (a clean batch read of the full file means it is balanced)
- One-shot paren balance check (all 11 files):
  ```sh
  emacs -Q --batch -l scripts/check-lisp.el
  # single file: emacs -Q --batch -l scripts/check-lisp.el -- foo.el
  # exit 0 = all pass; exit 1 = failure (invalid-read-syntax ")" N etc.)
  ```
- Compile-time issues (undefined functions/variables, macro misuse):
  `emacs -Q --batch -L . -f batch-byte-compile <file>`
  (only look at `Error`; `Warning` can be ignored)
- Optional coverage report (testcover line/branch coverage, ~1s):
  `emacs -Q --batch -l scripts/check-coverage.el`
  prints per-definition coverage and defs below 80%; `dsh-emacs-protocol.el`
  is excluded (testcover's edebug copy breaks cl-defstruct values)

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

- `check-parens` false-positives on the comment line `;; 2)` around line
  745 of test/dsh-test.el; do not use it as the sole judge
- When editing big functions like select-model-prompt, the closing paren
  count equals the call nesting depth; one paren off can leak the
  `(quit …)` handler into the body or swallow whole functions
  (symptoms: void-function / void-variable)
- For parens use the old/new snippet net-balance check, not eye-counting
  long `)` runs; equal balance is necessary but not sufficient — the
  read-level check is final
- When `check-lisp.el` reports FAIL, its `scan-error` message already
  carries the offending character offset; map it to a line in Emacs
  instead of re-counting parens by hand or rolling your own counter:
  ```sh
  emacs -Q --batch --eval '(
    with-temp-buffer
    (insert-file-contents "dsh-emacs.el")
    (goto-char 36353)              ; ^ offset from the scan-error
    (princ (format "line %d: %s\n"
                   (line-number-at-pos)
                   (buffer-substring (line-beginning-position)
                                     (line-end-position)))))'
  ```
- dsh server RPC names must match the real registry: there is no
  `session.delete` or `session.update` in dsh 0.1.1-rc.1
  (`session.rename` and `workspace.archiveSession` are the real ones);
  HTTP 404 usually means the method does not exist on this server version
- dsh web visible-session rule (mirror it):
  `origin !== "subagent" && !archived && (!blank || current)`