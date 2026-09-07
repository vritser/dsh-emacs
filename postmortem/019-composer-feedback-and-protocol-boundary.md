# 019 — Composer feedback and protocol ownership

## Background

Goal controls introduced in `a6ff8d2` safely guarded asynchronous responses,
but the UI hid pending state and blocked reasons. Display normalization also
leaked into editing. SVG display widths exceeded their backing text budgets.
The failing layers were Composer UI/rendering and inbound protocol ownership.

## Decision

Preserve source objectives for editing, expose full details through a standard
help buffer (`C-c C-g ?`), and show pending operation labels while withholding
inline actions. Decode projection and RPC goal cores in the protocol module.
These changes remain uncommitted pending explicit user instruction.

## Why

A compact status row should support inspection without becoming an editor.
Stock help buffers support keyboard use and multiline content with no new
persistent UI state. Narrow rows drop actions before status because commands
remain available through the prefix map. Explicit SVG pixel caps make the
column budget conservative without adding a pixel-measurement renderer.

The existing marker seam and input-area ownership stay in place: moving input
geometry would not address these problems. The request identity guard and
projection precedence remain the authority for asynchronous updates.

## Consequence

Users can inspect blocked reasons, see pending work, and edit without losing
source formatting. Protocol decoding has one owner; Composer compares structs.
Regression tests cover source preservation, pending failures, reason-only
updates, compact status visibility, and SVG width budgets. Evidence: the
working-tree changes to composer, protocol and tests building on `a6ff8d2`.

## Known limitations

A shared buffer uses the narrowest displayed window's layout, so wider windows
may show a shortened objective. Fonts with variable glyph widths or text
scaling still need visual verification; layout uses canonical frame columns.
Goal controls retain their existing RET/mouse keymaps and prefix shortcuts.
