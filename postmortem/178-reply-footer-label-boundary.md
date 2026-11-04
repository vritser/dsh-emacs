# 178 — Keep footer label composition with its data boundary

## Background

At baseline `702f40c`, `dsh-emacs-render--reply-footer` combined label
composition with transcript placement. The same function accumulated per-turn
usage, decided whether the history was complete, built Copy/Fork buttons and
duration text, located the final reply segment, removed superseded footers,
resolved the tail fragment, inserted the fragment and repaired duplicate blank
lines. Testing a label rule therefore required a chat buffer and rendered
transcript, even though most of the inputs were already a turn summary.

[084](084-reply-footer.md) and [086](086-reply-footer-turn-tail.md) define the
existing placement and tail behavior. [177](177-attempt-card-classification.md)
had just isolated attempt-card correlation from transcript mutation; the footer
label has the same data/presentation boundary but different inputs and labels.

## Decision

Extract `dsh-emacs-render--reply-footer-label` inside the renderer. It accepts
the turn number, the existing turn summary, the configured item list and the
subagent flag, and returns a propertized label or nil. It owns usage
accumulation and completeness, Copy/Fork payloads, elapsed-time formatting,
item de-duplication/order and the meta face.

`dsh-emacs-render--reply-footer` retains transcript boundaries, visibility
reconciliation, superseded-footer deletion, tail resolution, fragment
insertion, padding and duplicate-blank-line handling. No module, state mirror
or public API is added. Implementation: the staged footer batch based on
`702f40c`.

## Why

Label composition needs only the turn summary, item configuration and subagent
flag; it does not need the transcript. Direct tests can now distinguish usage
completeness, missing reports, duration boundaries, item order, button payloads
and subagent suppression without building a reply buffer. The placement rules
remain covered by the existing render tests, where transcript state is the
subject.

Moving label formatting into the fragment or mode-line layer would give those
modules ownership of reply presentation facts. Splitting out further helpers
would leave the data rules coupled to position. Keeping one extraction inside
the renderer separates the computation without adding an abstraction tier.

## Consequence

Displayed footer labels, item order, button payloads, usage/duration help and
Fork suppression are unchanged. The label helper is pure with respect to the
turn summary, item list and buffer; it returns fresh propertized text and does
not mutate its inputs. The footer coordinator keeps its marker and visibility
lifecycle. Architecture documentation records the data/placement boundary.
No user-visible change requires a changelog entry.

The render subsystem passes its focused tests, including the new direct label
tests; the full `scripts/verify.sh` gate passes.

## Known limitations

The label helper trusts its caller to supply a turn summary containing the
final reply sequence and text. It does not find the final reply segment, decide
whether a footer should be visible, remove older footers or insert the
fragment. Button activation still requires the live chat buffer and session
context; the label only carries the properties used by that action.
