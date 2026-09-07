# 020 — Next Message shares the Composer region

## Background

The queue preview from 003 modified the input prompt, locating its face run
and matching the old prefix before removing it. Goal chrome (`a6ff8d2`, 017)
and its later feedback improvements (`1b236ce`, 019) introduced a separate
marker boundary above that same prompt. Two presentation mechanisms owned
adjacent parts of the input area. The problem was UI geometry, not transport
or queue ordering.

## Decision

Composer owns one bounded read-only region containing an optional Goal Row
followed by an optional Next Message row. The queue module retains its mirror,
selection and visibility rules, feedback, commands, and burst repaint timing.
This working-tree change builds on `1b236ce`; no commit is made automatically.

## Why

A start marker alone encoded the assumption that chrome was one physical line.
A start/end pair gives Composer the exact region it may replace, independently
of which rows exist, without scanning or matching preview text. The input
prompt can stay plain, and repainting preserves the draft and cursor.

Composer reads the queue's selected visible item instead of holding another
queue snapshot. This preserves one owner for steering priority and transient
suppression. Keeping the existing queue repaint schedule avoids introducing
new timing behavior while moving presentation. A generic row registry or a
new input module would add indirection without solving another current problem.

## Consequence

Next Message gets its own line, an SVG clock without a redundant `Next:` label
(`Next:` remains the text fallback), window-width fitting, and a full-text
tooltip.
The old prefix state, prompt scanning, byte comparisons and replacement code
are deleted. Both rows use the same insertion boundary and region lifecycle;
either can disappear without removing the other or transcript content.

Tests assert the actual displayed row, retain existing burst/steer/delete and
suppression coverage, and add region transitions, draft/cursor preservation,
streamed transcript, input rebuild, idempotence, and next-only resize checks.
The rationale is linked from CHANGELOG; current ownership is in architecture.

## Known limitations

A single buffer still uses its narrowest viewing window's column budget.
Queue transient suppression, including its existing two-second defensive
transport timeout, is preserved. That timeout remains compensating state in
the queue layer, not a new Composer timing mechanism. Queue controls remain
in the minibuffer manager (`C-c C-q`); no inline action strip is added.
