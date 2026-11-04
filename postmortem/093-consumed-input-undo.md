# 093 — One consumed-input undo lifetime

_Input-state file ownership is superseded by [180](180-input-state-owner.md)._

Implementation commit: `fix: keep sent input undoable through later writes`.

## Background

Commit `580f906` scoped undo to the editable input (postmortem/054): transcript
writes leave no undo record, but invalidate absolute input positions, so the
next command rebuilds from current input. A send's deletion record only
survived its own echo when clearing happened afterwards; a later reply erased
it. File upload fixes retained consumed text separately, giving file captions
a longer undo lifetime than plain/image sends. This was an input-state model
problem, not a transport or renderer problem.

## Decision

Keep the positional rebuild and stock Emacs undo, but reconstruct from current
input or one pending consumption for every submission kind. The existing
`dsh-emacs--clear-input` owns consumption and history-navigation reset;
`dsh-emacs--input-undo-history` alone converts that state to positional records.
No state beyond that single consumption — and no wrapper, module or custom undo
command — is required.

## Why

The undo source must outlive text leaving the input. Capturing actual editor
text at the shared deletion boundary preserves reference-chip properties,
avoids synthesized attachment captions, and removes the upload-only capture.
Saving after deletion respects the change hook that invalidates prior state.
Input edits, including undo and failure restoration, take ownership; callbacks
must never reinstall old consumption. Navigation also resets at consumption,
not when a delayed RPC success arrives during newer editing.

Moving input to a separate buffer would disturb existing geometry. Narrowing
alone does not isolate absolute undo positions. Keeping input during upload
would require concurrency and draft-version state merely to avoid an order
constraint; saving one consumption solves the present inconsistency with the
state already available. Shifting every native undo-entry shape remains the
fragile alternative rejected in postmortem/054.

## Consequence

Plain, image and file sends can restore their input after a reply has moved the
input marker, until another input edit takes over. Attachments are not restored
and the server submission is not undone. Empty submissions do not invent text.
Deferred, slash and shell submissions share the same consumption boundary.
Regression coverage includes reply writes, undo/redo, editing back to empty,
failure restoration, out-of-order completion, newer history navigation,
reference properties and resetting the input layout. Architecture and changelog
describe the shared model; historical transcript-isolation decisions remain.

## Known limitations

Only the latest consumption is retained, not a submit-history stack. Transcript
writes still collapse editing granularity and discard old redo records. After
undo restores the text, redo clears it through native undo; consumption is not
rearmed, so a later rebuild on empty input has no restore step. State is local
to the buffer and does not survive layout/session reload. Prompt failure
rollback retains its existing empty-input/empty-staging eligibility rule; this
change does not introduce submission identities or alter that policy.
