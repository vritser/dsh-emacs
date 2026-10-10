# 090 — Manual navigation cancels pending list jumps

## Background

Review of the uncommitted project-entry change after `bbdae5d` found that an
unmatched project remained pending after manual navigation. A later workspace
arrival could therefore replace the user's chosen row and viewport. Record
089 acknowledged this lifetime, but real command-loop regression tests now
demonstrate the unwanted jump after both movement and folding. A second test
confirmed that a late result could recenter a list in an unselected window.

## Decision

A buffer-local pre-command hook cancels both pending navigation targets on
the next explicit list command. Background renders do not cancel them.
Project centering operates only when the list is the selected window, after
the opener selects it and the renderer places point on the target header.

## Why

Any new list command expresses a newer user intent than the earlier open.
One command-loop hook covers keyboard navigation, mouse commands, folding
and filtering without maintaining a command whitelist. Keeping the hook
local preserves unrelated buffers and permits normal asynchronous startup.
The selected window is the precise centering destination; searching across
frames can scroll a view the user is no longer interacting with.

## Consequence

Late workspace data cannot revive a canceled jump. Unit tests cover real
navigation/fold commands, warm and cold centering, buffer-start clamping,
window selection, independent views, and ordinary viewport restoration.
Path matching consumes the same workspace snapshot as the renderer. The
README, customization guide and changelog state the resulting contract.

## Known limitations

Centering is bounded by the buffer start: early headers remain above the
window midpoint. A background result can update the list's focus, but does
not recenter an unselected view. These changes still do not create missing
workspaces or map remote filesystem paths.

Existing view-restoration debt: an empty-workspace placeholder shares its
header's row identity, so a viewport starting on that placeholder can move
to the header on refresh. The viewport regression here anchors on a header;
separating those row identities is deferred from this navigation change.
