# 180 — Own input state and editing in one module

## Background

After the model, interaction and attachment extractions and the rendering
refactors in 174–179, the entry point still owned input geometry, deletion
guards, undo, completion and history alongside session and send coordination.
The consumed-text contract in [093](093-consumed-input-undo.md) and command
routing in [168](168-composer-command-boundaries.md) require these operations
to share the same editable region and hook ordering.

## Decision

`dsh-emacs-input.el` owns input options, marker and undo/history state,
geometry repair, editing guards, layout setup, local CAPFs, history seeding
and browsing, and the read/replace/consume operations. Chat mode invokes
completion setup and editing setup at their original initialization points.
The coordinator applies subagent availability and decides when sends consume
input or failed submissions qualify for restoration.

Implementation is the working-tree input extraction based on `b851763`,
after the session refactor in 179 and its GUI test correction. The file
ownership described in [093](093-consumed-input-undo.md) and
[176](176-attachment-state-owner.md) is updated here. Their consumption,
attachment and rollback behavior contracts continue to apply.

## Why

Input changes now have one owner for both state and its modification. A send
calls the consumption operation, which records undoable editor text and
resets history navigation together. Transcript history seeds the same owner.
Completion setup installs the token owners and local CAPFs in their existing
order. The two setup calls preserve the relative order of reference, editing
and chat lifecycle hooks.

The coordinator needs session identity and transaction eligibility. Keeping
those decisions there lets input operations serve editing, history recall,
shell submissions and asynchronous send recovery through the same boundary.

## Consequence

The entry point assembles the input owner and calls its operations. Caller
declarations and the syntax-check inventory identify the new source file.
Existing function names, configuration, keys and autoload entry points retain
their contracts. The moved commands had no autoload cookies in the baseline.
The input module directly requires its protocol, UI, face and token owners.
The coordinator identity and renderer anchor seams use declarations.

## Known limitations

Input shares the chat buffer with transcript and Composer content. Renderer
and Composer still read the shared marker for insertion geometry. History
navigation needs the assembled package's session resolver. Subagent input
availability remains a coordinator policy. Undo still rebuilds from current
input or one consumed text as specified by 093.
