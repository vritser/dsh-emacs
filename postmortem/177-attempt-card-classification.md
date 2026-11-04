# 177 — Classify attempt cards independently of transcript mutation

## Background

At baseline `3c68b11`, the render layer's
`dsh-emacs-render--note-attempt-outcome` combined fact retention and ordering,
retry/outcome correlation, fragment updates and the marker boundary used by
trimming. Testing a correlation rule therefore required transcript setup.
[121](121-single-attempt-feedback.md) defines the existing behavior, including
late history pages and preserving earlier started retries after turn failure.

## Decision

Keep correlation in the renderer, but extract it into the pure
`dsh-emacs-render--attempt-cards` function. It accepts one turn's already
merged, seq-ordered decoded facts and returns fresh card plists, newest
attempt first. Each card carries the attempt event, label and causal event;
event objects are borrowed without mutation.

The existing coordinator retains fact merging, sorting, cache publication,
fragment updates and marker maintenance. No module, state mirror or public
API is added. Implementation: this uncommitted batch based on `3c68b11`.
All behavior decisions in 121 remain in effect.

## Why

Classification has a useful data boundary: it needs ordered facts and produces
card descriptions without reading the transcript. Direct tests can distinguish
retry id, step and number mismatches, recovery without retry events, terminal
reasons and input mutation without arranging a chat buffer. Existing render
tests still verify history ordering, folding, body preservation and trimming.

Moving correlation into protocol decoding would give the wire layer ownership
of presentation labels and retained turn history. Splitting the buffer updates
into more helpers would leave the data rules coupled to transcript state.
This extraction separates the computation while keeping one owner for the
existing rendering lifecycle.

## Consequence

Commands, options and displayed cards retain their behavior. The extracted
state machine is unchanged apart from indentation; the fragment and marker
code is unchanged. Architecture documentation records the input and ownership
boundary. No user-visible change requires a changelog entry.

Tests cover terminal reasons, retry identity, same-step recovery, retry pairing
and fresh results with unchanged inputs. A deliberate started-to-scheduled
substitution in an isolated process makes the retry identity test fail.

## Known limitations

The classifier trusts its caller to supply a single turn's ordered, decoded
facts. It does not merge arrivals, deduplicate sequences or manage cache
lifetime. Each update still replays the retained facts for that turn; trimming
continues to release them through the existing marker boundary.
