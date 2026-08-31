#!/bin/sh
# verify.sh --- 一键机检 "Definition of done"（AGENTS.md "Verification" 的聚合出口）
# 用法: 从仓库根运行 scripts/verify.sh；全部通过 exit 0，任一失败 exit 1。
# 覆盖全部可机器检查的步骤：
#   1. check-lisp 全量（dsh-check:files 默认列表）
#   2. checker 自测（test/check-lisp-test.el）
#   3. 主测试套件（test/dsh-test.el）
#   4. 干净加载：emacs -Q --batch -L . -l dsh-emacs.el 必须无输出且 exit 0
#   5. git diff HEAD --check（空白错误；仅覆盖已跟踪文件）
#   6. 树内 junk 扫描（*.elc / 备份 / 自动保存 / 锁文件 / .DS_Store）
# 不可机检、依赖人工/环境的部分不在此脚本内：
#   - "review git diff" 的实质审阅（不只看空白）
#   - "不自动提交"（由 harness 的 auto-commit 禁用保证，不是本文档承诺）
# 任一 FAIL 即非零退出——跑完才能说 definition of done 达成。

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