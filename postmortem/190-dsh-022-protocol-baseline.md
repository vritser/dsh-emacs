# 190 — Follow the dsh 0.2.2 wire protocol

## Background

The protocol layer targeted dsh 0.2.1-rc.2 (`687f282` upstream).
The 0.2.2-rc.1 tag (`66491b0` upstream) batches control projections, makes
follow activation explicit and requires complete image references for reads.
Old requests either fail validation or silently stop updating live state.

## Decision

Target the release-tag protocol. Decode each batch into the existing typed
projection cells, preserving the event watermark and omitted-key semantics.
Request activation when opening chat streams. Retain each image's complete
reference for both background fetches and later user retries.

## Why

The existing cell consumers own queue, Plan, question and subagent state.
Changing the wire decoder and event dispatch keeps those responsibilities
intact. Repainting after the batch avoids displaying a partially applied event.
Image metadata must come from the message reference; an ID cannot reconstruct
the byte length or dimensions that the new host validates.

## Consequence

Upgrade the server with this client. No old single-cell stream fallback is
introduced. Existing chat commands and browser-cookie authentication continue.
The RPC reference records the tag comparison separately from later master
changes. Client implementation: `fix: align with dsh 0.2.2-rc.1`.

## Known limitations

The source checkout has no installed build dependencies, and the CLI on PATH
is 0.2.1-rc.2. Local regression tests do not constitute live 0.2.2 validation.
The additional passive observation endpoints are not needed by the existing
follow/paging workflow. The host's attachment endpoint authorizes a Session
scope but no longer checks whether that Session's history references the image.
