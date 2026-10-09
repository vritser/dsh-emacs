# 087 — Expand only confirmed child catalogs

## Background

At `9ef890f`, session rows without known children had no disclosure arrow,
but TAB still recorded them as expanded and fetched their catalogs. Empty
catalogs produced a "No subagents" row. The user requested that only sessions
with subagents expand.

## Decision

Gate manual expansion on the same nonempty catalog that enables the arrow.
TAB on empty or unknown catalogs leaves text, focus and fold state unchanged
and sends no request. Suppress empty placeholders even if an older expansion
preference remains. This change is uncommitted against `9ef890f`.

## Why

A disclosure control should describe an available branch. Discovery through
an invisible control made leaf rows behave like expandable parents. Catalog
discovery remains available from the parent chat's picker and explicit refresh.
Opening the list from a known child is different: cached lineage establishes
that its ancestors have children, so loading those catalogs still serves a
concrete navigation target. The render snapshot must retain that pending jump
to keep its loading/error feedback visible.

## Consequence

Workspace folding, nested expansion, retained fold preferences and direct-parent
navigation keep their existing behavior. No public command is removed. Tests
cover no-op TAB for unknown, loading, failed and empty catalogs, removal of
empty placeholders, normal nested folds and automatic ancestor discovery.

## Known limitations

Without a confirmed catalog, manual TAB cannot discover children. Host
projections, the chat picker or explicit refresh must populate the catalog first.
