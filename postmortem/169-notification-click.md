# 169 - Notification click returns to the chat

## Background

Run-finished, ask-question and approval notifications told the user that a
chat needed attention but were dead ends.  The render layer posted them
through `ns-do-applescript`, `osascript`, `notifications-notify` or
`notify-send`, with no action attached.  On macOS the in-process AppleScript
notification activates Emacs when clicked, but lands in whatever buffer was
current; D-Bus and the command-line backends did not use the notification
protocol's action support at all.

Implementation: `feat: reopen chats from desktop notifications`, built on
`108ea2b`.

## Decision

`dsh-emacs-notify--post` attaches the backend action in `dsh-emacs-render.el`.
The session coordinator owns `dsh-emacs-notify--open`: reuse a live chat,
reopen a closed child through its direct parent's catalog, or open an ordinary
cached session, then focus the graphical frame. Child navigation goes through
`dsh-emacs-open-subagent` to preserve its parent and mode even without a
session summary; a child summary alone is never treated as an ordinary root.
GNU/Linux D-Bus notifications register an `Open session` action with
`notifications-notify` using its flat key/title string list. On macOS, when
`terminal-notifier` is installed and an Emacs server is running, the
notification's `-execute` runs
`emacsclient --eval '(dsh-emacs-notify--open "<session>")'` and `-activate`
raises the Emacs bundle.  Without those two prerequisites the existing
in-process banner remains, because it still has the best click behavior
available without an action API.

## Why

The notification happened in the render layer, but the destination is a chat
session owned by the coordinator, so the action is a small callback across
that existing cyclic boundary rather than new state.  macOS's built-in
`display notification` has no action parameter; a focus hook that guessed a
click from `focus-in-hook` was rejected because an ordinary Cmd-Tab would
then yank the buffer.  `terminal-notifier` is optional and only chosen when
the Emacs server can answer `emacsclient`; otherwise the notification would
silently do nothing on click.  The D-Bus path needs no extra process and no
new user option.

## Consequence

Users can click a notification to land in the session that produced it,
including a closed child whose address remains in the parent's catalog.
`dsh-emacs-enable-notifications` keeps its meaning and default.  macOS users
need `terminal-notifier` plus an Emacs server to get the action; the bundle
identifier is the standard `org.gnu.Emacs`.  Docs live in
`docs/customization.md`; the notification tests use the real Emacs D-Bus
notification encoder with a mocked transport and cover child address
recovery, live-chat reuse, the macOS command line, the no-server fallback,
and the missing-session message.

## Known limitations

The D-Bus action depends on the desktop notification service advertising
action support.  The macOS path depends on a non-default optional tool and on
an emacsclient server; neither is installed by dsh-emacs.  Only the default
Emacs server socket and the `org.gnu.Emacs` bundle id are assumed.  A
notification for an unavailable session reports that it is gone. Closed
children require a cached catalog entry; the click does not fetch a missing
catalog or guess a child address from a session summary.
