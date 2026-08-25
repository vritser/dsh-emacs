# AGENTS.md — dsh-emacs 开发规则

## 验证（改完必跑，不得省略）

- 全量单测：`emacs -Q --batch -l test/dsh-test.el`
  （当前基准：177 项通过、0 失败）
- 加载洁癖：`emacs -Q --batch -L . -l dsh-emacs.el` 应无输出退出码 0
- 函数级复现优先用最小 batch：`emacs -Q --batch -L . --eval '(...)'`

## Elisp 修改纪律

- 理想一次只改一个逻辑块；改完**立即**用上面的命令验证，再改下一处
- **结构性替换**（增减调用嵌套层数，如 `(cdr (assq 'k v))` → `(accessor v)`）
  必须核对新旧片段括号净差：新旧各自 net balance 应相等
  （`(`=+1、`)`=-1，忽略注释与字符串；可用 python 或下方 check 脚本）
- 连续括号（`))))))))`）禁止肉数；以 **read 级平衡**为准
  （batch 能无错读完整文件即配平）
- read 平衡检查（一键，含 11 个文件）：
  ```sh
  emacs -Q --batch -l scripts/check-lisp.el
  # 指定单文件：emacs -Q --batch -l scripts/check-lisp.el -- foo.el
  # 退出码 0 = 全部通过；1 = 存在失败（invalid-read-syntax ")" N 等）
  ```
- 编译期常见问题（未定义函数/variable、宏滥用）用：
  `emacs -Q --batch -L . -f batch-byte-compile <file>`（只看 `Error`，`Warning` 可忽略）

## 协议层约束

- wire 字段名（`sessionId`、`archivedSessionIds` 等）**只允许**出现在
  `dsh-emacs-protocol.el` 的 `--from-alist` 中，业务代码一律走 `dsh-protocol-*`
  访问器
- 业务函数若需兼容旧测试 fixture，用 `dsh-protocol--struct` 兼容门接受
  wire alist 或已转换 struct 双形态；wire 数组为 vector，转入 struct 后归一为 list

## Commit

- Conventional Commits + 英文单行；双主题用 `;` 分隔
- 标准类型（Angular 惯例，均可使用）：
  - `feat:` 新功能 / `fix:` 修复
  - `docs:` 文档（README/AGENTS/IMPLEMENTATION）
  - `style:` 格式、`refactor:` 重构（不加功能不修 bug）、`perf:` 性能
  - `test:` 测试、`build:` 构建、`ci:` CI、`chore:` 杂项、`revert:` 回滚
- 参考历史：`feat: model picker sticky provider groups; reasoning-effort selection`

## 已知历史坑（勿重复）

- `check-parens` 对 test/dsh-test.el 745 行的注释 `;; 2)` 有误报，别拿它当唯一判据
- 改 select-model-prompt 等大函数时，闭括号层级 = 调用层数；少/多 1 个会让
  `(quit …)` handler 溢出或整段函数被吞（void-function / void-variable 症状）
- 测括号用「新旧片段净差」而非肉眼数连串 `)`；balance 相等 ≠ 配平，
  最终以 read 级检查为准