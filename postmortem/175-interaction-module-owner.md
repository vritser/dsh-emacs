# 175 — Keep question and approval state with their interaction owner

## Background

Baseline `972e6e6` had extracted model selection as recorded in
[174](174-model-selection-owner.md), while question and approval readers and
their lifecycle remained another large unrelated concern in the entry point.
[124](124-shared-interaction-owner.md) had already established one owner for
the shared prompt slot, but events still declared its handlers back into the
coordinator. Loading events alone could not retire question/approval frames.

## Decision

Move the existing shared slot, queues, reader context, options, cancellation,
timed wait claims, late answers, projection mirror and outcome submission to
`dsh-emacs-interaction.el`. Events requires that owner directly; the entry
point assembles it. Rendering and stream operations use declarations across
the cyclic boundary. Plan retains its document review and declares outcome
submission against the interaction module. Public command autoload cookies
explicitly keep `dsh-emacs` as their target.

Implementation: this uncommitted working-tree batch based on `972e6e6`, after
the model extraction in 174.

## Why

One existing resource and its complete lifecycle form a concrete boundary.
Moving both handlers together preserves the shared state established by 124;
splitting questions and approvals would scatter its ownership again. Events
can now route cancellation without relying on the entry point to define its
callbacks. Moving options and state with their consumers prevents an apparent
split that still leaves reader state in the coordinator. Request handling
continues to rely on the fully assembled package for notifications and
transcript settlement.

The earlier decision against a module addressed fixing two competing owners.
This change keeps that scheduler intact and addresses its placement among
unrelated input/session workflows. It adds no scheduler registry, context
struct, forwarding commands or shared-state module. Cached chat names still
belong to the coordinator, and Plan decisions still bypass the prompt slot.

## Consequence

The module owns synchronous prompt access; each timed claim remains a local
resource held through its asynchronous acknowledgement. Per-kind FIFO and
current-kind-first handoff, cancellation by kind plus event id, late-answer
cleanup, duplicate notification gates and generation retirement retain their
existing behavior. Public commands, defaults, keys and option names are
unchanged. Architecture and tooling track the new owner; no user-visible
changelog entry is needed for this internal extraction.

The full `scripts/verify.sh` gate passes. Fresh-process tests generate real
autoloads for both commands, load the interaction owner without its consumers,
and route host cancellation without loading the coordinator. The two autoload
suites share generation and fresh-process helpers in test support; current
Emacs uses `loaddefs-generate`, with the older API confined to the Emacs 28
fallback. A fresh-process label test checks that an unloaded coordinator's
name formatter falls back to the raw session id. A real terminal
Emacs probe runs stock completion and installed Vertico over 12 cases; before
and after logs match byte for byte. These cover numbered multi-select, label
prefixes, free text, empty/shortcut skips, partial matches, reentrant question
and approval queues, remote cancellation and user quit. Maximum minibuffer
depth is one; the timed claim survives subsequent prompts and closes exactly
once after acknowledgement. RPC and stream endpoints are mocked in that
probe, while readers and keyboard acceptance are real.

## Known limitations

Loading events alone supports cancellation, not complete question/approval
requests or question projection settlement. Those paths require the entry
point's session context, notification handler and renderer. The label helper's
dynamic formatter fallback is limited to display text; it does not make these
other consumers optional. The cancellation test establishes only that narrow
standalone contract.

Continuous arrivals of the current kind can still delay the other queue.
Generation retirement clears queued frames without forcibly closing the
active reader. Those are existing scheduling policies, not addressed here.
Input editing and attachments remain in the entry point for separate work.

GUI acceptance remains unverified: the installed graphical Emacs exits with
status 134 before loading the probe, including against the pre-extraction
snapshot. Terminal acceptance does not establish graphical focus, posframe
behavior or perceived rendering.
