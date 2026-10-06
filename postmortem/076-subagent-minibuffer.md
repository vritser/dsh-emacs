# 076 — Select subagents through the minibuffer

Session-list visibility superseded by [077](077-session-list-subagents.md).
The minibuffer workflow remains available.

## Background

The uncommitted implementation after `68da9c6` used a dedicated special-mode
tree (075). The user wanted to choose a child and enter its conversation with
less intermediate UI. The tree required a mode, keymap, folds, timer and
marker repair even though the actual work happened in ordinary chat buffers.

## Decision

Replace the tree with `completing-read` over direct children. Preserve catalog
order and use full ids to disambiguate labels. Annotate mode, activity, duration
and cumulative usage. `RET` opens, a command prefix selects another window,
and ordinary `C-g` cancels. Entering a child and invoking the picker again
navigates another level. Keep xref's return stack and the Nerd Font count
indicator; stop and details use the same picker.

## Why

This reuses the user's completion frontend without imposing a new navigation
mode or action keymap. A full xref results backend would still introduce a
results surface without improving the choose-and-enter flow. Direct children
preserve exact parent authority and avoid cold-reading the entire tree.

Delete the tree-only code rather than keeping an alternative UI or compatibility
commands. This change and 075 remain uncommitted; no released command needs a
migration shim. The implementation following `68da9c6` is the evidence until
the feature's eventual commit.

## Consequence

There is no browser window, fold state, display timer or row-marker repair.
Cancel leaves the originating chat and xref history untouched. Missing root
catalogs are read at command time, with failures distinct from empty results;
asynchronous child metrics and explicit refresh reuse the existing store.
Protocol routes and input guards from 075 are unchanged. The real-Emacs E2E
passed 33 checks, including actual minibuffer selection and xref return. Its
return-position assertion uses a marker because streaming parent output moves
text positions while the child is viewed.

## Known limitations

The picker lists one level at a time. Completion annotations use state available
when the frontend renders; they are not a continuously ticking dashboard.
Optional detailed inspection still uses a standard help buffer. Delegation E2E
needs a working provider and real graphical Emacs for the minibuffer path.
