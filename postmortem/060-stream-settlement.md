# 060 — Retire all transient blocks together

## Background

The audit on top of `8f7de91` followed the duplicate Think fix. The renderer
already separated alternating text/reasoning blocks (056), but consecutive
blocks of the same type still shared one live body. Final reasoning
corrections appended after folded fragments, and attempt settlement (040)
deleted only the last live text body.

Reconnect had a separate protocol error: it treated the host's compact
stream records as raw deltas. The existing test used raw deltas too, so it
could not detect the omission. The installed host and web client confirmed
that the baseline carries packed records and revision increases per frame.

## Decision

- Keep the block index on both live stream states, and keep the identities
  of folded Think fragments on the uncommitted step.
- Reconcile text before replacing corrected reasoning at its first existing
  position. Equal content leaves every original block in place.
- Give the renderer one `dsh-emacs-render--discard-stream` interface. Failed
  attempts and reconnect snapshots both retire the step's text regions,
  Think fragments, live bodies and their pending work through this owner.
- Expand compact snapshot records in the event consumer, through protocol
  structs for both the frame/baseline header and each compact record. Reject
  duplicate revisions, but treat a revision-1 `start` after a higher
  watermark as a lifecycle reset. Check revision continuity and
  attempt/frame indices against `nextIndex`; a gap retires the logical follow
  stream and requests a fresh snapshot.

## Why

Whether a block is still streaming does not determine whether it is already
visible. A folded block still belongs to its uncommitted attempt. Tracking
that ownership lets settlement remove exactly that output while preserving
settled history and the draft; clearing the whole buffer would lose both.

Text must settle before an earlier Think is replaced: deleting the old
fragment can move the following text's start marker to the insertion point.
Inserting the correction first lets text repair delete it as part of its
own body. Tests cover immediate and deferred Markdown work at this boundary.

A revision watermark alone cannot detect missing chunks. Keep the attempt id
and dense frame counter with its turn/step so a gap, an alien attempt or a
lost `end` is caught. Recovery uses the existing follow snapshot contract and
rotates the stream id, so queued old frames cannot corrupt the new prefix;
reconnecting the entire socket is unnecessary.

The reset trigger must be the revision, not the attempt id: ids are
`<sessionId>:<counter>` and the counter restarts with every Agent lifecycle,
so a genuine reset can carry the id of the attempt it replaces. Keying the
reset on the id missed that case and let the new attempt's chunks merge into
the old live body. The id still identifies chunks and ends inside an open
attempt, but it never decides a reset.

## Consequence

Regression tests exercise adjacent same-kind blocks, delayed block ends,
reasoning corrections/removal, retries with reused indices, packed reconnect
baselines, equal-revision duplicates, counter resets and missing frames
(including a missing final chunk before end). The reconnect fixture matches
the installed host. The earlier text-repair fixture now keeps its two
reasoning blocks separate, so it tests unchanged reasoning rather than
accidentally accepting a duplicated merged body.

Implementation commit: `fix: settle streamed replies without duplicates or
gaps`.

This record extends the stream design in 056 and the attempt-card decision
in 040.

## Known limitations

A changed final reasoning body is authoritative: it replaces the old Think
fragments with one block at their first position. Historical messages still
group reasoning before text rather than reproducing live interleaving (056).
The end-to-end transport test exercises a real server, including replacing a
logical follow stream on the same socket. Counter resets and missing-frame
schedules are controlled regression fixtures.
