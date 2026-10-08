# 079 — Open configuration as an ordinary file

_Superseded as the primary provider-setup workflow by 080; the file entry
remains available for advanced configuration._

## Background

At `3dd9f7d`, dsh-emacs offered `dsh-emacs-open-web` for configuration and
commands for session choices, but no configuration-file entry. A proposed
schema-driven settings buffer would add forms, drafts, conflict handling and
credential controls. The user preferred ordinary Emacs text editing.

## Decision

Add `dsh-emacs-edit-config` to the existing server module, next to the browser
entry. Read an existing file name and visit it with `find-file`. Remember
successful choices per normalized server URL for this Emacs session; a prefix
argument selects a replacement. Explicit TRAMP paths use normal file handling.

## Why

Emacs already owns file editing, completion, undo and saving. A second settings
editor would duplicate those facilities and the server's configuration model.
Explicit selection works now without guessing a service's filesystem layout.
The settings-document RPC opens a file through the server's native editor; it
does not return a document for this Emacs to visit. HTTP endpoints also do not
identify SSH connections. Keeping choices separate by server prevents a local
selection from being silently reused after switching to a remote service.

## Consequence

The command works offline and adds no dependencies, keybindings or save hooks.
Saving remains an ordinary file operation; dsh controls validation and when
changes take effect. Cancelled or failed opens preserve the previous selection.
README, customization and architecture docs describe the workflow; CHANGELOG
0.6.0 links here. This records uncommitted work following `3dd9f7d`.

## Known limitations

Users must identify an existing configuration file and have filesystem access.
Selections are not persisted across Emacs restarts. A different configuration
behind the same server URL requires selecting again. File watching, reload and
server-side validation feedback are not implemented by this entry command.
Automatic document discovery remains deferred until dsh exposes an appropriate
document-location contract; Web configuration remains available.
