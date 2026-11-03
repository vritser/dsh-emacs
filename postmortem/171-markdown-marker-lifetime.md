# 171 — End resource marker lifetime before emphasis edits

## Background

The staged Unicode bold-boundary fix on top of `8a378e4` corrected Chinese
and intraword star spans but increased Markdown render time. The user's
`perf3.el` fixture repeats Chinese prose, bold, italics, inline code,
underscores, arithmetic and one link per section. On macOS Emacs 31.1.50,
the 500-section version took about 196–200 ms with interpreted source and
default GC settings, versus about 143 ms before the correctness fix.

CPU sampling located most of the extra time in buffer deletion/insertion,
not Unicode category lookup. The resource scanner left four live markers
per resolved link attached during every later emphasis edit, even though
label text properties already owned resource identity (decision
[150](150-markdown-resource-boundaries.md)). Correctly recognizing more bold
spans multiplied that unnecessary marker maintenance.

## Decision

Keep the existing parser and rendering order, but detach resolved resource
markers after both image and link passes. Only raw resources keep their
markers for destination protection. The bold predicate computes only the
requested opening or closing eligibility, skips unnecessary outer-character
classification and checks escape runs only after a backslash.

## Why

Markers remain necessary while nested images and enclosing links are being
stripped. Afterwards their lifetime has ended: label properties survive
emphasis's delete/reinsert operations, and freezing already uses those
properties. Releasing markers at that boundary removes work from every
subsequent buffer edit without changing resource or emphasis semantics.

A delimiter-only deletion prototype gave a smaller, inconsistent gain; it
still performed the same number of edits with the stale markers attached.
No render cache or GC tuning was added, consistent with decision
[108](108-markdown-allocation.md). The simplified predicate retains Unicode
classification rather than adding an ASCII-specific parser path.

## Consequence

Two sequential comparison rounds, each using the user's three-sample median
and alternating version order, measured the following interpreted-source
times on the same machine:

| Workload | Before optimization | After optimization |
|---|---:|---:|
| 5,414 characters, one render | 8.3–8.7 ms | 8.1–8.2 ms |
| 56,068 characters, one render | 196.2–200.4 ms | 139.5–142.2 ms |
| 525 characters, 200 renders | 270.0–272.8 ms | 264.1–266.6 ms |

A separate byte-compiled comparison measured 85.0 → 49.0 ms for the
56,068-character case. These are batch render costs, not GUI redisplay times.

A five-sample variant comparison on the same fixture attributes the gain to
the marker lifetime: the old predicate with detached markers measured
142–150 ms, while the new predicate with the old marker lifetime measured
193–197 ms. The predicate rewrite is a simplification worth about 1–5% on its
own, depending on how much emphasis the document holds.

An exhaustive probe compared 7,744 delimiter decisions, and 706 mixed and
randomized documents retained identical rendered text and text properties.
The regression test observes marker lifetime before the real emphasis pass,
keeps raw destination markers live and exercises the styled link's RET
command. It fails against the pre-optimization code. No public option or
rendering grammar changes.

The full `scripts/verify.sh` gate passed. An isolated GUI Emacs also passed
five targeted tests and resolved Chinese, English and linked bold labels to
fonts with bold weight in a real chat buffer.

Implementation: `fix: format bold beside CJK text and keep long replies fast`,
on top of `8a378e4`.

## Known limitations

The fixture is rich in links and bold spans; these numbers do not predict
code-fontification or table-layout speed. Short replies retain a small cost
relative to the old, incorrect bold parser, and so does long link-free prose:
byte-compiled, a 32 KB document without links still spends about 3 ms more
(23 versus 20 ms), because the wider delimiter matching inspects every span.
Raw resource markers still track edits because their protected destinations
need positions. The image side of the same boundary cannot run in batch (no
graphical display), so the regression test covers only the link side and raw
image markers. Timing includes GC and varies with the machine; this is not a
latency guarantee.
