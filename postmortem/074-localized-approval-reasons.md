# 074 — Select the host's localized approval reason

## Background

The dsh 0.2.0 approval waterfall includes `displayReason`, a language-to-text
map alongside the original `reason`. At `68a6393`, the event dispatcher read
only `reason`, so prompts and notifications lost the supplied translation.
The gap was in protocol decoding and presentation selection; the approval
queue and decision transport already worked.

## Decision

Decode the request into `dsh-protocol-approval-request`, retaining the raw
reason and valid translations separately. Select one display reason before
queueing. `dsh-emacs-approval-language` defaults to the Emacs message locale
and permits an explicit language tag. Try the full tag, base language,
English, then the raw reason. Keep the existing prompt, command detail and
allow/reject lifecycle.

## Why

Locale discovery belongs to the client; wire fields and malformed-value
handling belong to the protocol constructor. Selecting once makes queued
prompts agree with their notifications even if the setting later changes.
An explicit option is useful because an English editor locale does not imply
that the user wants English explanations. The fallback preserves useful text
when translations are missing, without translating commands or sending text
to another service. No general localization framework is needed for this
single host-provided field.

## Consequence

The feature changes presentation only. The raw reason and incoming request
remain intact; the host still owns its audit record. Wire-to-reader tests
cover language selection, fallback, notifications, queueing and the unchanged
decision response. Existing approval tests cover allow, reject, cancellation,
deduplication and command details. This record accompanies
`feat: localize approval reasons`, based on `68a6393`.

## Known limitations

Only supplied translations can be shown. The surrounding yes/no reader and
other client text retain their existing language. A locale such as `zh-Hant-TW`
tries that exact tag, then `zh`; intermediate script tags are not inferred.
