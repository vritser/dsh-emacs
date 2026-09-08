# 025 — Fragment Middle-Span Updates

Lookup, repeated-rendering and full visual-property refresh limitations
superseded by 026; the middle-span replacement contract remains in effect.

## Background

The snapshot implementation in `6741dc9` replaced the whole fragment on
updates. Even a small body edit displaced markers inside otherwise unchanged
title and body text. Identical-render skipping addresses only no-op updates.

## Decision

Preserve the common character prefix and suffix and replace the single
middle span. Refresh all text properties from the rendered snapshot within
the atomic change group. Keep full rendering and the existing lookup.

## Why

One contiguous replacement preserves stable surrounding text without a
general edit-distance algorithm or an index lifecycle. Character comparison
and property refresh are separate because hidden state, faces and keymaps
can change even when displayed characters do not. Normal completion of the
atomic group is necessary: a nonlocal return rolls its changes back.

## Consequence

Interior markers in retained text survive body updates. Property-only
updates retain every character. Tests cover marker preservation, properties,
hidden content, layout changes, neighbors and rollback. This record describes
uncommitted work against `6741dc9`.

## Known limitations

Multiple disjoint edits replace the span between the first and last change.
Rendering, text comparison and property refresh still process the card;
identity lookup still scans the buffer. This reduces text mutation, not all
rendering work, and has not established an end-to-end latency improvement.
