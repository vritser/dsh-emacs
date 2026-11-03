# 174 — Give model selection its own owner

The deferred question/approval extraction is addressed by
[175](175-interaction-module-owner.md); the model ownership decision remains
in effect.

## Background

On baseline `26782bc`, the entry point owned model catalog presentation,
completion frontend integration, model/effort readers and their mutation RPCs
alongside session and submit coordination. The UI callback
`dsh-emacs--select-model-prompt` mixed reading with mutation and display updates.
Changing the picker required navigating unrelated session and input workflows.

## Decision

Move model/effort selection, model options and completion-icon registration to
`dsh-emacs-model.el`. Readers consume decoded catalog/current-selection values
and return lightweight lists; catalog callbacks decode, read, submit the
protocol-encoded selection and update display after success. Keep session
identity and cache access in the coordinator, and provider setup in its existing
module. Public command and option names remain the same.

Implementation: the working-tree change based on `26782bc`; not committed.

## Why

The picker is an existing cohesive feature with its own tests and frontend
policy. Separating its readers from RPC submission makes their output and lack
of mutations directly testable. Moving functions without their options and
registrations would leave ownership split. A generic picker framework, new
context struct or shared-state file would add indirection without solving this
specific boundary. Permission selection remains outside this module because
it uses a different catalog and command workflow.

## Consequence

The entry point assembles the feature instead of implementing it. Modeline
updates and cache refresh retain their existing success ordering. The syntax
gate and coverage instrumentation include the new module. Architecture docs
record the owner; keys, defaults, option semantics and command names remain
unchanged. The startup regression repair is recorded in the changelog.

`scripts/verify.sh` passes, including both the ordinary and Motion Line unit
suites. The model-selection subsystem has 45 passing tests. A real terminal
Emacs probe exercised stock completion and installed Vertico across 13 cases;
the baseline and refactored logs match byte for byte for candidates, grouping,
reader returns, selection requests and refresh counts. The probe covers
duplicate IDs, empty RET, cancellation, current-effort defaults, effort-only
selection, rejected provider headers and Vertico's explicit empty-input exit.

Review caught a startup regression missed by the already-initialized suite:
ordinary command autoload cookies started loading only the model module,
leaving coordinator functions undefined. Explicit command cookies retain
`dsh-emacs` as their autoload target. A fresh-process regression generates the
actual autoloads and invokes each command without a prior require; the missing
session now reaches its normal user error instead of a void-function error.

## Known limitations

Input editing, attachments and question/approval interactions still live in
the entry point. This batch does not address those independent boundaries.
Model and effort prompts keep distinct success messages and display updates;
they do not share a generic mutation helper. Frontend acceptance remains native:
an empty minibuffer can accept Vertico's highlighted first candidate, whereas
an empty string returned by the reader preserves the model.

GUI acceptance remains unverified. Direct invocation of the installed
`/Applications/Emacs.app` exited with status 134 before the probe loaded;
LaunchServices returned `kLSNoExecutableErr` (-10827). Terminal frontend results
do not establish graphical focus, posframe behavior or perceived rendering.
