# 080 — Add providers through ordinary minibuffer prompts

## Background

The configuration-file command in 079, developed after `3dd9f7d`, only removed
the file-opening step. The user found it insufficient: adding a provider still
required finding the configuration shape and arranging credentials manually.
The rejected alternative was a general settings UI, not task-specific commands.

## Decision

Add `dsh-emacs-add-provider` in a provider-owned module. Read the host's
configuration schema and provider directory, select a catalog route or name a
custom route, and gather endpoint, protocol, model IDs and API key through
standard minibuffer readers. Keep the file command for advanced configuration.

## Why

A concrete setup command eliminates configuration syntax work without adding
forms, persistent drafts or a second settings model. The server already owns
schema validation and storage. Its Schemastery schema is a reference graph,
so decoding belongs in the protocol module. Protocol choices come from that
schema; provider ownership comes from the directory, including renamed entry
ids. Existing settings receive field operations so editing an endpoint or key
cannot replace model capabilities, headers or fields outside this command.

Namespace revision checks protect the profile write. Save that profile before
the key, matching the server's Web setup flow: validation/conflict rejection
cannot replace a credential used by an existing provider. There is no
cross-service transaction, so a later key failure must report the saved profile
and permit retrying its key. The command reuses the existing credential ref,
and a blank key preserves authentication rather than deleting a credential.

## Consequence

Provider setup works on the connected local or remote host without a chat
session. Existing model selection stays independent. The command checks the
server URL at asynchronous boundaries, uses password input for keys, and does
not persist a local draft. Unit tests cover real schema references, explicit
false, payloads, preserved fields, conflicts, cancellation and partial success.
An isolated dsh service verifies storage, credential redaction and immediate
catalog visibility; the repository E2E suite exercises the real transport.
README, customization, architecture and CHANGELOG 0.6.0 document this surface.
This record describes uncommitted work after `3dd9f7d` and 079.

## Known limitations

The command covers the pi-ai provider shape, not account sign-in or every
adapter family's editor. It accepts model IDs directly; model discovery and
advanced capability editing remain in Web/configuration files. Existing routes
only expose endpoint/key editing here. Credential writes have no CAS or joint
transaction with settings. A transport failure can leave an uncertain write
outcome; no rollback is attempted, and retrying requires user action.
