#!/bin/sh
# verify.sh --- one-shot machine check for "Definition of done" (the aggregate
# exit of AGENTS.md "Verification")
# Usage: run scripts/verify.sh from the repository root; exit 0 when all pass,
# exit 1 if anything fails.
# Covers every machine-checkable step:
#   1. check-lisp over the whole default dsh-check:files list
#   2. checker self-tests (test/check-lisp-test.el)
#   3. byte-compile of the production files (Errors count as FAIL;
#      "reference to free variable" does too -- it means "code references a
#      variable that does not exist", exactly the symptom of an unescaped
#      quote in a docstring closing the string early, which the read-level
#      check-lisp cannot see; other Warnings (docstring width, undeclared
#      functions from external packages, ...) are ignored per AGENTS.md
#      discipline.  Intentional cross-module references are silenced with
#      defvar/declare-function declarations.  .elc artifacts are redirected
#      to a temp directory and never land in the repo tree)
#   4. main test suite (test/dsh-test.el)
#   5. clean load: emacs -Q --batch -L . -l dsh-emacs.el must print nothing and exit 0
#   6. git diff HEAD --check (whitespace errors; tracked files only)
#   7. junk scan in the tree (*.elc / backups / autosaves / lock files / .DS_Store)
# Steps that are not machine-checkable and need a human/environment are not in
# this script:
#   - the substantive part of "review git diff" (not just whitespace)
#   - "do not auto-commit" (guaranteed by the harness auto-commit disable, not
#     a promise of this document)
# Any FAIL exits nonzero -- only a full pass means definition of done is met.

set -u
cd "$(dirname "$0")/.." || { echo "verify: cannot cd to repo root" >&2; exit 1; }

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/dsh-verify.XXXXXX") || exit 1
trap 'rm -rf "$tmpdir"' EXIT

fail=0
run() {  # run <label> <log-key> <command...>
  label=$1; key=$2; shift 2
  if "$@" >"$tmpdir/$key.log" 2>&1; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n' "$label"
    sed 's/^/     /' "$tmpdir/$key.log" | tail -n 12
    fail=1
  fi
}

printf '== check-lisp (whole dsh-check:files list) ==\n'
run 'check-lisp'      check     emacs -Q --batch -l scripts/check-lisp.el

printf '\n== checker self-tests ==\n'
run 'check-lisp-test' selftest  emacs -Q --batch -l test/check-lisp-test.el

printf '\n== byte-compile (production files; Errors and free-variable warnings fail) ==\n'
byte_files=$(ls dsh-emacs*.el 2>/dev/null)
if [ -z "$byte_files" ]; then
  printf 'FAIL byte-compile (no dsh-emacs*.el production files)\n'
  fail=1
else
  run 'byte-compile' compile env DSH_BYTE_TMP="$tmpdir" emacs -Q --batch -L . \
    --eval "(require 'bytecomp)" \
    --eval '(setq byte-compile-dest-file-function (lambda (src) (expand-file-name (concat (file-name-nondirectory src) "c") (getenv "DSH_BYTE_TMP"))))' \
    -f batch-byte-compile $byte_files
  # A free-variable warning means the code references a variable that never
  # exists.  Reading Lisp cannot see this (a docstring with an unescaped quote
  # closes the string early and the rest of the line becomes code), and it is a
  # silent runtime bug, so it is a FAIL here rather than a Warning to skip.
  if grep -q 'reference to free variable' "$tmpdir/compile.log"; then
    printf 'FAIL byte-compile (free variable; declare it with defvar/declare-function)\n'
    grep 'reference to free variable' "$tmpdir/compile.log" | sed 's/^/     /'
    fail=1
  fi
fi

printf '\n== full unit suite ==\n'
run 'dsh-test'        dsh       emacs -Q --batch -l test/dsh-test.el

printf '\n== clean load (must be silent, exit 0) ==\n'
if out=$(emacs -Q --batch -L . -l dsh-emacs.el 2>&1); then
  if [ -z "$out" ]; then
    printf 'ok   clean-load\n'
  else
    printf 'FAIL clean-load (emacs printed output)\n%s\n' "$out"
    fail=1
  fi
else
  printf 'FAIL clean-load (nonzero exit)\n'
  fail=1
fi

printf '\n== git diff --check (whitespace; tracked files only) ==\n'
if git diff HEAD --check; then
  printf 'ok   git-diff-check\n'
else
  printf 'FAIL git diff --check\n'
  fail=1
fi

printf '\n== junk scan (*.elc / backup / autosave / lock in tree) ==\n'
junk=$(find . -path './.git' -prune -o -type f \( \
  -name '*.elc' -o -name '*~' -o -name '*.orig' -o -name '*.rej' \
  -o -name '.#*' -o -name '#*#' -o -name '.DS_Store' \) -print)
if [ -z "$junk" ]; then
  printf 'ok   junk-scan\n'
else
  printf 'FAIL junk in tree:\n%s\n' "$junk"
  fail=1
fi

printf '\n== diff stat (eyeball review aid) ==\n'
git diff HEAD --stat

if [ "$fail" -eq 0 ]; then
  printf '\n==> verify PASS\n'
else
  printf '\n==> verify FAIL\n'
fi
exit "$fail"