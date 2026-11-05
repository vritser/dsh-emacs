# 184 — Track pending submissions before consuming drafts

## Background

At `7b03e89` (v0.8.0), the session coordinator consumed input and attachment
staging before an asynchronous upload or submission settled. Busy state tracks
the server's turn, not a submission's acceptance. Source reload guarded session
creation and history loading but could proceed during an upload, a command
admission response or its fallback to an ordinary prompt. The planned
connection preflight also needs to distinguish an empty composer from work
that still owns its consumed content.

## Decision

Track unsettled submission steps in a buffer-local list owned by the session
coordinator. Register before consuming staging/input, keep a step registered
through its callback, and release that identity after completion or a startup
error/quit. A continuation registers its own step before the preceding callback
returns. Use this state in the existing source-reload preflight immediately.

## Why

Concurrent submissions need independent identities; a single boolean can be
cleared by the wrong callback. Keeping ownership through callbacks covers
rollback and the upload → command admission → prompt fallback chain without
passing a new transaction argument through all routing functions. The same
tracking covers direct plain sends used by queue Send Now. The brief staging
handoff is tracked too: repainting an emptied staging row must not expose a
gap before the upload has registered.

This belongs with submission coordination, not the renderer or generic HTTP
transport: local preparation and multi-request handoffs are part of the same
user action. The transport separately reports malformed response headers as a
failed request, so an incomplete response does not bypass the normal failure
callback and strand the step.

## Consequence

Reload reports the blocking buffer while an upload or submission is pending.
After acceptance, normal streaming remains reloadable. Existing input rollback
and attachment restoration remain in their owners. Errors propagate after
releasing the step; repeated completion and completion after origin closure do
not mutate another chat or settle a different operation. Local shell execution
retains its existing process ownership and does not become a network submission.

This is uncommitted work based on `7b03e89`, following the uncommitted startup
cancellation work in 183. Tests drive the public send/reload paths, upload and
command fallback, concurrent same-text sends, origin changes/closure, exceptions
and truncated HTTP responses. CHANGELOG and the customization/architecture docs
describe the new reload preflight.

The full verification gate and 107 affected subsystem tests passed. A real GUI
send-key/reload probe checked rejection during an upload and preservation of a
newer draft after failure, with the network mocked. Both isolated Docker services
passed real file upload followed by prompt rejection for a nonexistent session:
reload was blocked while pending, then the original text and staged file were
restored and the pending state cleared. These checks do not exercise switching.

## Known limitations

This is a prerequisite for connection teardown, not an implementation of
connect/disconnect. Queue edits, provider/configuration writes, active readers
and other service resources still need their own preflight and cleanup audit.
No connection generation is attached to business callbacks yet.

Operations already dispatched by older loaded code have no new tracking record;
finish them before upgrading the running definitions. Closing the originating
buffer does not revoke work already accepted by the server. A request with no
response remains pending; this change does not introduce a new transport timeout
or guess that an operation finished based on elapsed time.
