# 173 — Native completion acceptance with modified menu actions

## Background

The `C-c C-q` queue menu and `C-c C-j` job menu bound single keys to verbs
and resolved the target from whatever row the completion frontend
highlighted. The shared lookup read Vertico's private `vertico--index` and
`vertico--candidates`. The model picker separately probed `vertico--groups`.
[170](170-event-and-menu-boundaries.md) isolated the highlight lookup in the
UI module and listed the private dependency as a known limitation.

Removing the private read exposed a second problem. Typed-entry resolution
replaced the highlight, but the menus still bound a verb to every letter:

- Ivy's minibuffer text can include the candidate display text, so a fully
  typed label did not match its table entry and silently fell back to the
  first row. `d` then deleted the wrong item.
- With plain letters bound to verbs, typing `delta` fired `d` on the first
  entry before the user finished typing. Input and action shared one phase.

## Decision

The menus keep one completion list. RET runs the default action; modified
action keys bind to the frontend's original RET command. A pre-command hook
records the action, and the returned label resolves through the unique-label
table. The queue/job owner runs the action after completion returns.
Delete-all and refresh exit without selecting a candidate.

No completion frontend's internal state is read. Order stays declarative:
the collection carries `display-sort-function` through
`dsh-emacs-ui--completing-read-ordered`, and menu setup neutralizes
`vertico-sort-override-function`, the one option that outranks that
metadata. The model picker's grouping check uses the public
`vertico-group-format` option, which Vertico itself consults before applying
`group-function` metadata.

## Why

A letter cannot be both input and a command in the same phase. Modified
action keys preserve ordinary filtering while letting users browse before
choosing an action. A two-step action-first prototype removed the ambiguity
but added a prompt and hid the list until an action was chosen; that trade-off
was rejected for the final interaction.

Binding directly to the frontend command matters: some frontends prepare
their candidates in a pre-command hook based on the command being executed.
Calling that command from a wrapper can skip preparation and accept stale
state. The shared hook records intent without replacing the native command.
Every later command restores its own action or the default, so incomplete
acceptance cannot arm a different action for a subsequent RET.

`completing-read`'s return value is the portable selection signal. Frontend
minibuffer text is not: Ivy and Vertico differ in what the minibuffer
contains while a candidate is highlighted, and either can insert display
text that a table lookup does not expect.

## Consequence

Queue: RET or `C-c s` sends, `C-c e` edits, `C-c d` deletes, and `C-c x`
deletes all after confirmation. Jobs: RET shows output, `C-c k` stops after
a confirming `k`, and `C-c r` refreshes. The stop arm window is unchanged;
cancelling confirmation clears its armed state and timer.

Frontend highlight reads and deferred action timers are gone. The UI module
owns one transient menu context; queue and jobs own their action dispatch.
Tests cover native command bindings, default-action restoration, global
actions, label resolution and the stop confirmation. Isolated GUI checks
exercise Ivy, Vertico and stock completion, including navigation to the
second entry, ordinary typing, modified actions and cancellation.

Implementation: this change to `dsh-emacs-ui.el`, `dsh-emacs-queue.el`,
`dsh-emacs-jobs.el` and the ordered-read helper's move out of `dsh-emacs.el`,
based on `ad34f6e`.

## Known limitations

The modified keys require a frontend that uses a minibuffer local map and
exposes its normal RET command there. Ivy, Vertico and stock completion were
tested in Emacs 31.1.50; replacement interfaces such as Helm were not tested.

The model picker falls back to candidate header rows when
`vertico-group-format` is absent or nil, which includes Vertico 1.x with the
old `vertico-group` extension and a user who disabled group titles. Modern
Vertico and stock completion are unaffected.

The list closes before an action's guard runs. A refused action (editing or
sending a queued item that carries an attachment) reports the problem and
leaves the queue unchanged; reopen `C-c C-q` to pick another entry.
