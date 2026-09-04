# 011 — Slash-command completion becomes a cooperative backend

> **Status**: in the working tree, unreleased (0.3.0).  Documented under the
> `## 0.3.0 - Unreleased` breaking-change banner "Slash-command auto-pop now
> goes through the user's own completion front-end".

## Background

0.2.0 shipped slash-command completion where dsh-emacs **drove the completion
front-end** instead of acting as a plain backend.  In `dsh-emacs-mode` it ran
two self-driven popup paths whenever the user typed `/`:

- a content-driven `post-command` hook (`dsh-emacs--slash-auto-complete`) that
  watched the input text for an in-progress `/name`, armed a 0.1s timer, and
  called `(completion-at-point)` directly to force the list open for stock
  `*Completions*` / vertico / icomplete — with its own dedup bookkeeping
  (`dsh-emacs--slash-pop-token` / `-timer`);
- for corfu users, a block that buffer-locally force-enabled `corfu-auto`,
  appended `/` to `corfu-auto-trigger`, and hooked corfu's private
  `corfu-auto--post-command` (a `--` symbol) so the popup also fired for them.

This is the smell the review flagged: a completion *backend* that imperatively
pokes `completion-at-point` and re-hooks a front-end's internals on a timer.
It also fought the UI it targeted (under `corfu-mode`, `completion-at-point`
routes into `corfu--in-region-1`, which restarts/quits an open popup and may
auto-insert the token), and the plain-vs-idle timer choice was a symptom of
forcing a front-end behavior that has no such concept.

## Decision

dsh-emacs becomes **completion-backend-only**: it registers
`completion-at-point-functions` in chat buffers and never enables or drives
any front-end.  Auto-pop is restored **cooperatively** — dsh-emacs only
contributes `/` to a front-end whose auto mode the *user* already turned on,
and that front-end's own engine does the popping:

- **corfu**: when `corfu-auto` is on, `dsh-emacs-command-auto-trigger-setup`
  adds `/` buffer-locally to `corfu-auto-trigger` in chat buffers.  This is
  corfu's documented trigger (from `corfu-auto.el`, "characters which trigger
  auto completion… `corfu-auto-prefix' is ignored"), so corfu pops immediately
  on `/`.  dsh-emacs never sets `corfu-auto`/`corfu-mode` and never hooks
  `corfu-auto--post-command`.
- **company**: no code — company reaches the buffer's capf through its default
  `company-capf` backend and auto-shows on its own idle delay.
- **stock `*Completions*` / vertico / icomplete**: no auto channel exists, so
  `/` completes on `TAB` only.

Owner: `dsh-emacs-command.el` (`dsh-emacs-command-auto-trigger-setup`, the
option `dsh-emacs-slash-auto-complete`); entry from `dsh-emacs-mode`.
Removed: `dsh-emacs--slash-auto-complete`, `dsh-emacs--slash-token`,
`dsh-emacs--slash-pop-token` / `-timer`, the `post-command` hook, and the
corfu force-enable block.  The option keeps its name and default (`t`) but its
meaning narrows to "whether `/` is contributed at all".

## Why

- Emacs' convention is that a package **provides** a completion backend via
  `completion-at-point-functions` and lets the installed front-end decide when
  to show and how to dismiss.  Reaching into `completion-at-point` from a timer
  or hooking a front-end's private `--` function makes the package a UI driver,
  duplicating lifecycle logic the front-end already owns.
- Auto-pop on typing is itself a front-end feature (corfu-auto / company idle);
  stock Emacs has no such concept.  So "web-style popup on `/`" is only
  achievable *with* those front-ends, through their documented auto trigger —
  hence contribute, never enable.
- Rejected alternatives: (a) keep the hand-rolled timer — it drives the
  front-end, needs idle/plain-timer contortions, and misbehaves under
  `corfu-mode`; (b) buffer-locally force-enable `corfu-auto` — it mutates the
  user's front-end configuration and enables auto the user didn't ask for;
  (c) drop auto entirely (pure TAB) — over-corrects, losing a genuinely useful
  corfu/company experience the front-ends support natively.
- `corfu-auto` activation was verified in corfu core: `corfu-mode`, when
  `corfu-auto` is non-nil, `(require 'corfu-auto)` and adds
  `corfu-auto--post-command` locally — so "user enabled corfu auto" is a stable,
  readable signal (`bound-and-true-p corfu-auto`) independent of buffer/mode
  ordering; contributing an inert buffer-local trigger before corfu-mode turns
  on is harmless.

## Consequence

- Behavior change (breaking, 0.3.0): stock/vertico/icomplete users no longer
  get an auto-popup on `/` (TAB-only); corfu users only when they have
  `corfu-auto` on.  The previous behavior auto-popped unconditionally.
- The removed internals and the force-enable block are gone (delete, don't
  deprecate); no compat shims.
- Tests in `test/dsh-test.el` cover the cooperative cases: `/` is added only
  when `corfu-auto` is on, only when the option is on, is never added as a
  corfu hook, and setup is idempotent.
- Docs: `docs/slash-commands.md` (three-branch Completion section),
  CHANGELOG; README / `docs/customization.md` never claimed the removed
  behavior and need no change.

## Known limitations

- The active front-end is read when a chat buffer opens; turning a front-end's
  auto on after opening a session does not retroactively add `/` to that buffer.
- company auto-show respects the user's `company-minimum-prefix-length`, so a
  bare `/` does not pop — only `/go…` onward.  Making `/` pop under company
  would require overriding that option, which is out of scope (never touch the
  user's front-end config).
- No auto channel for stock `*Completions*` / vertico / icomplete — by design.
