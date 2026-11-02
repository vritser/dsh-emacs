# 168 — Keep composer edits at command boundaries

## Background

The uncommitted composer changes built on `108ea2b` (core ownership across
reloads) added global advice on `command-execute`, `insert` and
`insert-and-inherit` to route arbitrary editing commands from the transcript.
Retrying a whole command read interactive parameters twice; intercepting
primitive insertions then needed a dynamic flag to distinguish command edits
from renderer writes. Reload also refreshed Doom icons directly in two paths,
and dispatch trimmed messages before the final send paths trimmed them again.

Implementation: `refactor: keep composer edits and reload state with their owners`.
It refines the lifecycle documented in [115](115-source-hot-reload.md) while
retaining its live-state preservation.

## Decision

Route explicitly supported editing commands in the chat's pre-command hook.
Keep `dsh-emacs-composer-typing-commands` extensible, include stock register
insertion and chat paste by default, and remove global command/insertion
interception and automatic rescue. Unlisted commands keep normal read-only
errors. Reapply reference-chip protection after moving to the composer.

Give reload one completion function. A current loader cancels the pending
fallback and completes synchronously; a previous loader already executing its
old body uses the named deferred completion. Modeline owns image caches and
optional backend icon refresh. Final plain and deferred submit paths normalize
their own outgoing text and retain the original message for rollback.

Composer and reference guards query actual advice membership instead of
keeping separate installation flags. The Doom adapter supplies the list icon
through `doom-modeline-icon-for-buffer` and uses the public major-mode icon
option to suppress duplicate chat icons during refresh. Doom updates its own
cache; the client neither declares nor writes Doom's private cache variable.

## Why

A command boundary runs before interactive argument reading and before edits,
so routing does not have to infer the origin of each primitive insertion or
replay a partly executed command. Explicit support costs less than promising
transparent compatibility with arbitrary commands, mouse placement and native
insertion paths. The register GUI regression remains a supported default path.

The first-upgrade callback remains necessary because redefining the reload
function does not replace an invocation already on the stack. Sharing its
completion work with the normal loader gives that callback a bounded role.
Backend-specific cache repair belongs to modeline. Keeping raw draft text
separate from outgoing text makes failure restoration independent of sending
and echo normalization.

## Consequence

RET, C-j, TAB, register insertion, chat paste and the other configured commands
route to the input. A mode-specific command can be explicitly added when it
edits at point; unlisted commands require the cursor in the input first.
Messages and prompt history use trimmed model text; a failed submit restores
the original whitespace when no newer draft exists. README, customization and
architecture documentation describe these boundaries.

## Known limitations

Commands that select a new location from a mouse event can override point;
they require a click in the editable input. Configured third-party commands
remain responsible for their own argument reading and region semantics.
Already-loaded definitions removed by this change stay resident under the
reload policy in 115; restart Emacs when testing removal of the old global
advice. The first upgrade retains a zero-delay completion callback as explicit
lifecycle debt; source loading remains non-transactional.
