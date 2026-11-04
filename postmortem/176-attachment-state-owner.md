# 176 — Own staged attachments separately from the send transaction

_Input-state file ownership is superseded by [180](180-input-state-owner.md)._

## Background

Baseline `972e6e6`, followed by the interaction extraction in
[175](175-interaction-module-owner.md), left acquisition, staging and uploads
in the entry point. [094](094-staged-file-attachments.md) explicitly kept
acquisition and submission there, and Composer still called that coordinator
to read or remove an attachment. The send command and failure restoration
also assigned the pending list and refreshed the row directly.

## Decision

Supersede 094's file-placement decision: `dsh-emacs-attachments.el` owns
acquisition, validation, clipboard conversion and per-buffer media setup,
the single buffer-local pending list, its mutations and repaint, and staged
file upload/receipt resolution. The entry point retains the send transaction,
input consumption/undo, routing, optimistic echo and eligibility for restoring
a failed draft. It reads staging through the existing accessor and changes it
through one state-and-repaint operation owned by the attachment module.

Composer requires the attachment owner and still reads the same list. It has
no mirror or mutation policy. Public command autoload cookies keep loading
`dsh-emacs`, preserving initialized chat context. Cyclic Composer callbacks
are declarations, not a reverse require. The old consume-only helper is
removed; no forwarding commands, state struct or compatibility aliases are
introduced.

Implementation: this uncommitted working-tree batch based on `a1c64dd`, after
175. Only the file-placement clause of 094 is superseded; its behavior and
the receipt/undo contracts in [092](092-arbitrary-file-attachments.md) and
[093](093-consumed-input-undo.md) remain in effect.

## Why

The concrete gain is one owner for attachment state and its visible row.
The coordinator no longer assigns that state, and Composer no longer depends
on entry-point attachment functions. Platform acquisition and the media
handler registration live with the capabilities they install. This makes
attachment acquisition/validation independently loadable for tests without
moving input editing or reconstructing send transactions in a second module.

Moving only file helpers would leave state and integration split. Moving the
whole submit chain would put slash, shell, queue, echo and undo policy in the
attachment module. A second draft buffer or copied Composer list would add
new ownership and lifecycle problems. The chosen split instead retains the
existing transaction and its ordering, while centralizing attachment writes.

## Consequence

Acquisition only stages; it neither starts the server nor uploads. Files are
revalidated and uploaded only when sending, in staged order, with fresh
one-time receipts on every retry. Composer reads the one buffer-local list.
The coordinator consumes staging before submission, clears file captions
before uploading, leaves later edits alone, and restores asynchronous failures
only while both current text and staging are empty. Synchronous exceptions
retain their exact pre-submit caption restoration. Mode reinitialization
still discards staging. The extraction itself adds no command, key, option,
default or workflow. This batch also includes a user-visible fix to the
attachment remove cell: only the glyph carries the hover and click target,
recorded in `CHANGELOG.md`. Architecture and tooling track the new owner.

The full `scripts/verify.sh` gate passes, including both unit configurations;
the attachment subsystem has 44 passing tests. New fresh-process checks cover
data preparation without the entry point or Composer and actual generated
autoloads for all four public commands. A mode lifecycle check covers discarded
staging after reinitialization.

Real terminal stock/Vertico runs record six file-picker reads and 14
checkpoints, with identical before/after logs. These cover repeated selection,
image paste, keyboard activation of a per-file remove cell, picker cancellation,
consumption before upload, newer text and staging surviving upload completion,
discard and text-paste fallback. File readers and keyboard commands are real;
clipboard bytes, upload completion and RPC endpoints are fixture-controlled.

## Known limitations

The module loads without entering a chat mode or initializing the coordinator.
File/image data preparation works in isolation; interactive commands, row
updates and sending require the assembled package and chat context. This is
not a standalone attachment UI or an independent submit service.

Uploads remain sequential, whole-file operations, and received file chips
remain display-only as in 092. Staging is still not persisted. Rollback keeps
its existing eligibility rule based on current input and staging.

GUI acceptance remains unverified: the installed graphical Emacs exits with
status 134 before loading the probe, including the pre-extraction snapshot.
Terminal checks do not establish OS pasteboard integration, graphical focus,
pointer-driven drops or perceived rendering. No live-host upload was run for
this extraction.
