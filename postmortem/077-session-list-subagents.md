# 077 — Expand subagents within the session list

Whole-buffer text diff superseded by [078](078-session-list-row-updates.md).

## Background

The uncommitted subagent work following `68da9c6` exposed children through a
minibuffer picker (076). The user also wanted to see those conversations under
their parents in the existing session list, using TAB to expand and collapse.
The session list already owns workspace folds and restores each window by row
identity (015, 058, 059), so a separate browser would duplicate that behavior.

## Decision

Extend the session list with initially collapsed child rows. TAB toggles the
row's children or the workspace header; RET retains its open/header action.
Keep the minibuffer picker for navigation directly from a chat. Reuse the
existing projection store, cold-read requests and direct-parent open function.
This record describes the working-tree change after `68da9c6`; it has not yet
been committed.

## Why

Expansion belongs to the list buffer, while catalogs remain shared host data.
The renderer only reads caches; expanding a missing catalog starts an
asynchronous read. Its completion repaints using existing row identities so
incoming children do not steal the selected row. Exact parent addresses stay
on child rows, including children without cached session summaries, avoiding
an ordinary-session fallback for nested conversations.

An added regression showed that erasing the list destroyed xref departure
markers during the child's follow snapshot. Rendering now diffs text into the
live buffer with Emacs's `replace-buffer-contents`, preserving markers in
surviving rows. Row properties are reapplied from the new render: the text diff
alone kept stale child addresses in matching whitespace after collapse.
Per-window row restoration from 058 still handles reordered or removed rows.

## Consequence

Children show mode and activity beneath their parent without appearing again
as top-level sessions. Opening the list from a child reveals its ancestry.
Cold reads show loading, empty or error feedback, and re-expansion retries
failures. Unsupported rename, archive and fork actions fail before prompting
or contacting the server. Child input permissions remain owned by the chat.
Tests cover nested navigation, asynchronous reads, retry and refresh stability.
An isolated graphical Emacs probe passed TAB expansion/collapse, RET opening
a read-only child and xref return through the real follow-snapshot handler.

## Known limitations

Expansion lasts for the list buffer's lifetime. Workspace counts continue to
count top-level sessions. The list does not fetch an entire descendant tree or
poll metrics; branches load on demand. Automatic reveal depends on cached
summary or catalog lineage, and children of hidden/archived root sessions are
not promoted to top-level rows.
