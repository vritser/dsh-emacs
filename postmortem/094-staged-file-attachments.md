# 094 — Stage file attachments before sending

File placement superseded by [176](176-attachment-state-owner.md);
the staging, submit timing, receipt and rollback behavior remains in effect.

Builds on `b58c8c2` (clipboard staging,
[063](063-clipboard-image-paste.md)) and `1cf0c05` (arbitrary files,
[092](092-arbitrary-file-attachments.md)); input consumption and undo remain
as recorded in `4782e74` ([093](093-consumed-input-undo.md)).

## Background

Clipboard images already joined a draft through the buffer-local pending
attachment list, while `C-c C-a` asked for a caption and sent one file
immediately. Drag-and-drop likewise submitted its files immediately. The UI
entry points made it difficult to gather files and compose one message even
though staging, the Composer row, mixed image/file submission and rollback
already supported a list. The gap was in acquisition, not transport.

## Decision

Reuse the existing staging path for file selection and drag-and-drop.
`dsh-emacs-attach-file` now takes only `(file)`. Its interactive `C-c C-a`
entry calls standard `read-file-name` once with `mustmatch` t, validates the
file and appends one attachment through `dsh-emacs--stage-attachments`.
Repeated invocations add files to the same pending list. There is no caption
prompt, server startup, network request or immediate submission.

Drag-and-drop retains its existing `y-or-n-p` confirmation and filtering,
then appends all valid files in their existing order. Clipboard acquisition
is unchanged. `C-c C-c` submits the whole staged set with the current input,
and a blank input sends the staged file names as the message text. The row
lists each staged name with its own remove cell
(`dsh-emacs--remove-attachment`); `C-c C-d` clears the whole set. Acquisition
and submission stay in `dsh-emacs.el`; Composer renders the same list without
a second copy and calls back only for that per-file removal.

## Why

The existing pending list already supplies accumulation, visibility, clearing
and failed-send restoration. Feeding it from every acquisition entry point
lets users compose a message before submitting, with no new attachment state
or upload lifecycle. File receipts are still minted only at submission, as
required by 092.

A new multi-select selector would add a selection UI and completion rules for
a problem repeated standard file reads already solve. A separate
`dsh-emacs-attach-files` command would leave two file commands with different
send behavior; changing the established command gives the existing key the
same staging semantics as paste. Retaining a caption argument would preserve
a second place to compose text, so it is removed rather than kept as a
compatibility shim. The drop confirmation remains the user's admission step
before files enter the draft.

## Consequence

This is a behavior and public API break: callers use
`(dsh-emacs-attach-file file)`, and sending requires the ordinary send command.
Text is composed in the chat input. Selecting or dropping files no longer
requires a running dsh server. Existing image encoding, file upload limits,
submit-time revalidation, queue/steer behavior and rollback remain owned by
the existing paths. README, architecture and customization docs describe the
shared workflow; the unreleased changelog records the break and links here.

## Known limitations

- One file is selected per `C-c C-a` invocation. Repeat it or drop several
  files to build a larger set; no multi-select picker is introduced.
- Mixed-invalid drops retain the existing filtering: invalid entries are
  omitted, valid entries keep their order, and a drop with no attachable
  files reports that result. This change does not add per-file rejection
  reporting or make the whole drop fail atomically.
- Staging remains buffer-local and is lost when the chat buffer is killed or
  its mode reinitialized. The row shows file names only, so a long staged set
  is truncated like the other Composer rows; `C-c C-d` still clears it all.
