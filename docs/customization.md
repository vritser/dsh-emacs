# Customization Options

## Example configuration

If you already use `use-package`, this is an alternative to the README's
minimal loading configuration. Adjust `:load-path` to your checkout:

```emacs-lisp
(use-package dsh-emacs
  :load-path "~/dsh-emacs"
  :commands (dsh-emacs dsh-emacs-new-session)
  :custom
  (dsh-emacs-base-url "http://127.0.0.1:3080") ; server address
  (dsh-emacs-default-preset "code")           ; preset for new sessions
  (dsh-emacs-server-start-on-init t)          ; start the server eagerly
  :bind (("C-x d" . dsh-emacs)
         :map dsh-emacs-mode-map
         ("C-c C-a" . dsh-emacs-attach-file)))
```

Provider credentials and model configuration belong to dsh; open its web UI
with `M-x dsh-emacs-open-web`. Select the current session's model with
`C-c C-m`. `dsh-emacs-default-model` supplies a display fallback and does not
choose the model used by a session.

## Common options

The most commonly used options, straight in your config:

```elisp
(setq dsh-emacs-base-url "http://127.0.0.1:3080")  ; dsh service URL; a `?token=...` query (the URL dsh prints) is read for auth and stripped before paths are appended
(setq dsh-emacs-server-auth-token nil)         ; launch token for dsh web 0.1.2-rc.1+; nil = auto-captured from a server dsh-emacs starts itself.  Set it for a server YOU run externally (a fresh random value every server restart).  When pointing at an external auth-requiring server with no token set, dsh-emacs asks you for it; a token that successfully authenticates is remembered here automatically (saved), so the next session reuses it — only a stale token (validation fails after a server restart) re-prompts, pre-filled for editing.  Successful authentication also caches the cookie instead of showing a Basic username/password prompt
(setq dsh-emacs-history-window 30)                  ; messages fetched when opening a session (maxMessages): larger = fuller history but slower opening (GC/parsing scale with it).  Also the page size `C-c C-o` (dsh-emacs-load-older-history) fetches per press
(setq dsh-emacs-show-reasoning t)                  ; show reasoning content (on by default; nil = hide, unlike dsh web)
(setq dsh-emacs-show-tool-calls t)                 ; show tool calls
(setq dsh-emacs-stream-markdown-limit 8192)        ; pending characters before idle formatting; nil = synchronous
(setq dsh-emacs-default-cwd default-directory)     ; fallback working directory for new sessions (interactive ones use the current buffer's default-directory first)
(setq dsh-emacs-new-session-auto-project t)        ; auto-detect the Emacs project of the working directory and place new sessions in its workspace (nil = always start in CWD)
(setq dsh-emacs-default-model "claude-opus-4-5")   ; default model name
(setq dsh-emacs-default-preset "standard")         ; default agent preset for new sessions (nil = host default; "standard"/"minimal"/"code"/"cordis" or a user preset id)
(setq dsh-emacs-model-group-format #(" %s " 0 4 (face vertico-group-title))) ; provider group-header format inside the model picker (nil = hide group titles)
(setq dsh-emacs-input-history-length 50)           ; prompts kept for M-p / M-n recall
(setq dsh-emacs-input-history-cross-session nil)   ; M-p / M-n recall only the current session's prompts (nil, default); t = recall prompts from every session
(setq dsh-emacs-word-completion-limit 100000)      ; how many characters above the input TAB searches when completing an ordinary word from the draft/transcript (nil = whole buffer)
(setq dsh-emacs-busy-enter-behavior 'queue)          ; what C-c C-c does while a turn runs: `queue` lines input up as the next turn (default), `steer` wakes the running agent before its next step, `stop` interrupts like before; `C-u C-c C-c` explicitly sends a nonempty message with steer mode regardless of this setting or the local busy indicator, an empty input interrupts a running turn, and `C-c C-b` interrupts explicitly (C-c C-q manages the queue)
(setq dsh-emacs-question-skip-key "C-c C-s") ; key that skips the current ask question inside the reader (nil = no shortcut; empty input also skips)
(setq dsh-emacs-ui-label-separator "·")            ; separator between Think/Tool title and its right-side summary ("" = plain gap)
(setq dsh-emacs-tool-titles '(("pwsh" . "PowerShell"))) ; tool name -> display title overrides (icons stay per variant; unnamed tools get a humanized name, e.g. grep -> "Grep")
(setq dsh-emacs-attach-media-types '("image/png" "image/jpeg" "image/webp" "image/gif")) ; accepted upload types (`C-c C-a' file attach, `C-c C-v' clipboard paste, `M-x yank-media')
(setq dsh-emacs-session-auto-refresh-interval nil) ; seconds between automatic session-list refreshes (nil = off)
(setq dsh-emacs-workspaces-collapsed-by-default nil) ; workspace and Ungrouped groups start expanded (t = collapsed); TAB/RET overrides a group in the current list buffer
(setq dsh-emacs-composer-goal-actions t)             ; show pause/resume/edit/clear buttons on the Goal Row (nil = hide them; C-c C-g keys still work; C-c C-g a / dsh-emacs-goal-actions-toggle toggles the current buffer)
(setq dsh-emacs-reference-auto-complete t)          ; typing "@" in the input pops the file/directory/session reference menu (TAB and M-x dsh-emacs-reference always work; see docs/reference.md)
(setq dsh-emacs-reference-prefetch t)               ; open-session pre-fetch of the bare "@" candidate lists (files + session roster) on an idle timer
(setq dsh-emacs-reference-prefetch-delay 0.5)       ; idle gap before the @ pre-fetch runs
(setq dsh-emacs-reference-fetch-delay 0.15)         ; idle debounce before a typed @ token re-fetches its candidates
(setq dsh-emacs-reference-max-files nil)            ; file/directory candidates shown in the "@" popup (nil = all host results)
(setq dsh-emacs-reference-max-sessions nil)         ; session candidates shown in the "@" popup (nil = all host results)
(setq dsh-emacs-skill-prefetch t)                   ; open-session pre-fetch of the `skills.list' catalog that shares the "/" menu with slash commands (see docs/skills.md)
(setq dsh-emacs-skill-prefetch-delay 0.5)           ; delay before the skill pre-fetch runs
(setq dsh-emacs-modeline-enabled t)                  ; whether the mode-line stats are enabled
(setq dsh-emacs-modeline-show-step nil)              ; show the running turn's step badge next to the spinner (nil = hide it)
(setq dsh-emacs-shell-require-confirm nil)          ; ask y-or-n-p before running a `!` line (nil = run immediately, like M-!)
(setq dsh-emacs-shell-max-output 50000)             ; cap on a `!` command's captured output shown in the transcript
(setq dsh-emacs-shell-null-stdin t)                 ; close `!` commands' input pipe immediately (EOF, independent of shell syntax)
(setq dsh-emacs-shell-timeout nil)                  ; nil = no limit; positive integer seconds only (surviving background children are untracked)
(setq dsh-emacs-jobs-kill-arm-seconds 3)           ; how long the `k' press in the `C-c C-j' background-job menu stays armed before a second press stops the job (matches dsh web's two-press stop)
```

## Reply footer

`dsh-emacs-reply-footer-items` controls the row at the end of each finished
turn, below its replies, tool/thinking cards, Deliverables and diagnostics,
with one blank line above the row. Copy and Fork target the last visible
text reply, even when other content follows it.
The default is `(copy fork usage
duration)`; list order is display order, omitted items are hidden, and nil
disables the whole row. Refresh an existing conversation (`C-c C-r`) after
changing the option.

```emacs-lisp
(setq dsh-emacs-reply-footer-items '(copy fork usage duration))
;; Actions only:
;; (setq dsh-emacs-reply-footer-items '(copy fork))
;; Statistics first:
;; (setq dsh-emacs-reply-footer-items '(usage duration copy fork))
;; Hide:
;; (setq dsh-emacs-reply-footer-items nil)
```

- `copy`: copy that last reply's original Markdown, without tool cards or
  footer text. Click or press `RET` on the button; `TAB`/`S-TAB` from a button
  navigate buttons. Existing copy keybindings retain their behavior.
- `fork`: create and open a child through that reply's durable event sequence.
  Hidden in subagent conversations; the existing command also enforces that
  restriction. The current session is unaffected.
- `usage`: sum reported input, output, cache-read and cache-write tokens
  across this turn's assistant messages/attempts, with a hover breakdown.
  These are per-turn counts, separate from the mode line's cumulative usage;
  they do not add separate compaction or delegated-child usage. If the loaded
  history lacks the turn start, or an attempt/message has no usage, the
  reported subtotal is marked `≥`. No reported counts shows `—`. Loading
  older history completes the same row without counting an event twice.
- `duration`: server `turn/end.time - turn/start.time`, including model work,
  tools, retries and user waits. Missing timestamps, reversed timestamps or
  synthetic fork endings show `—`. Historical replay never uses the current
  wall clock to invent a duration.

There is one row per completed turn, including interrupted/failed turns
that have a committed text reply. Streaming, unfinished turns and turns
without visible committed assistant text have no row. The footer precedes
any subsequent deliverables or error card and stays outside copied replies.

## Session and workspace controls

These default keys apply in the session list opened by `M-x dsh-emacs`:

| Key | Action |
|---|---|
| `RET` | Open the session or subagent under point; on a group header, toggle folding |
| `c` / `C` | Create a session / create with a chosen agent preset |
| `r` | Rename the session under point |
| `f` | Fork the session through its latest completed turn |
| `d` | Archive the session without deleting it |
| `u` | Restore an archived session (pick from the archive set) |
| `/` | Search |
| `g` | Refresh |
| `TAB` | Toggle a workspace header or a session's direct subagents |
| `W` | Create a workspace |
| `R` | Rename the workspace under point |
| `D` | Delete the workspace under point |
| `M` | Move the session under point to another workspace |
| `w` | Filter by workspace; empty input clears the filter |

### Forking conversations

In a chat buffer, `C-c C-y` (`dsh-emacs-fork-message-at-point`) creates and
opens a new conversation through the assistant reply at point. Place point
in its text or a rendered code block; replies loaded through older-history
paging work too. The child inherits the selected reply and preceding
events, without later conversation. The original conversation is unchanged.

The reply must have been committed by the server. Live partial replies,
user messages, thinking/tool cards and the input area are not selectable
boundaries. Subagent conversations cannot be forked. This command uses
the exact inclusive `atSeq` semantics documented for dsh 0.1.7 and newer;
the server closes any open turn/step in the inherited prefix.

Session-list `f` and `M-x dsh-emacs-fork-session` select the latest completed
turn instead. Lisp callers can pass an optional event sequence as the second
argument to `dsh-emacs-fork-session` (zero is valid).

### Renaming and grouping

The same `session/rename` RPC is available without leaving a chat buffer:
`M-x dsh-emacs-rename-session` there names the session you are in (no session
picker), prefilled with its current title; outside a chat buffer it asks for
the session with completion.

Workspace and `Ungrouped` groups start expanded by default. Set
`dsh-emacs-workspaces-collapsed-by-default` to non-nil to start with all
groups collapsed. `M-x dsh-emacs-collapse-workspaces` and
`M-x dsh-emacs-expand-workspaces` fold or unfold every group in the list.

Subagents start collapsed beneath their parent session. `TAB` on a session
row expands its direct children; repeat on a child to reveal nested children.
Only sessions with a known nonempty child catalog show an expansion arrow;
unknown and empty catalogs show none and `TAB` leaves them unchanged without
requesting data.
`RET` opens the child through its direct parent, and `M-,` returns to the
departing list row. Child rows show mode and activity; `i` adds their id and
available metrics. `r`, `d` and `f` are unavailable on child rows.

Missing ancestor catalogs load asynchronously when revealing the current child,
with loading and error feedback. Other unknown catalogs can be discovered from
the parent chat using the subagent picker or `dsh-emacs-subagent-refresh`.
Empty catalogs add no placeholder row. Workspace context, child expansion and
per-window cursor positions survive refreshes. Collapsing a parent retains its
children's expansion choices.

Opening the list (`M-x dsh-emacs`, `C-c C-l`) puts the cursor on the current
session's row and scrolls it into view; for a subagent, its ancestors and
workspace are expanded. When a session sits in a folded group, the group
is unfolded to show it, and a `w` workspace filter that
would hide the row is cleared. Refreshing the list in place (`g`, events,
auto-refresh) instead keeps the row you are on. If archiving or deleting removes
that row, focus moves to the next surviving row in the previous list order,
or the preceding row when none follows. Opening a list that is
already live reuses the cached rows — the server's event stream keeps them
current — and makes no session-list request. Missing ancestor catalogs are
fetched when opening the list from a child. A cold list (nothing fetched yet) is
fetched, and `g` refreshes on demand. Re-opening keeps the list's state:
folded groups stay folded and an active `w` filter stays set.

## Permission presets

`M-x dsh-emacs-set-permission` switches the current session's permission
preset (the sandbox mode + approval policy bundle). The candidate list comes
from the host's process-level `permissionPresets/catalog`, each row showing
the host's label and description, and the switch runs the `/permission`
slash command — the namespace's only write path — so the result appears in
the transcript as a command row and the mode line's `permission` segment
follows the recorded event. The derived `custom` state is shown in the mode
line when the effective knobs match no preset, but is never offered as a
switch target.

There is no default keybinding: the switch is deliberate and the mode-line
segment already reports the current value. The segment itself is a shield
icon (one cell): the dsh-web SVG shield where Emacs can draw SVG, else the
Nerd Font shield glyph when `nerd-icons` is installed, else a short token.
Set `dsh-emacs-modeline-permission-style` to `text` to show the full preset
name instead, or remove `permission` from `dsh-emacs-modeline-format-spec`
like any other segment (see [Mode-line Status](modeline.md)).

## Goal actions

The composer shows the session's current goal above the input. In a chat
buffer, `C-c C-g` opens the goal-action prefix:

| Key | Action |
|---|---|
| `C-c C-g p` | Pause the goal |
| `C-c C-g r` | Resume the goal |
| `C-c C-g e` | Edit the objective |
| `C-c C-g d` | Clear the goal |
| `C-c C-g a` | Toggle inline action buttons in this buffer |
| `C-c C-g ?` | Show the full objective and blocked reason |

`dsh-emacs-composer-goal-actions` controls whether inline action buttons are
shown by default. Hiding them leaves the keyboard commands available.
Steering items take priority in the separate Next Message preview; hover for
the full text or use `C-c C-q` to manage pending messages.

## Markdown responsiveness

`dsh-emacs-stream-markdown-limit` defaults to **8192 characters**. Reply text
still appears through the normal stream batching. Once an unfinished line
exceeds this pending range, its new Markdown remains literal until a newline
or the final message. Smaller lines keep their existing live styling.

Large ready regions are prepared after at least **0.1 seconds of idle time**,
checked by a one-shot timer every 0.1 seconds while work is pending, one
reply per callback. User input interrupts preparation; visible text remains
intact and a later idle period retries. The complete result then replaces the
pending region. Large final-only replies and history messages use the same
path. Read-only protection and event navigation are present before styling.

Set the option to **nil** to disable automatic deferral for new work. This is
a character threshold, not a guaranteed frame-time budget: publishing the
result, property installation, GC and redisplay still take synchronous work.
An interrupted attempt may repeat computation; a formatting error is reported
and leaves the raw reply visible. See
[decision record 036](../postmortem/036-bounded-stream-markdown.md).

## Approval prompts

`dsh-emacs-approval-language` selects the language of approval reasons supplied
by a dsh 0.2.0 host. Its default, **nil**, uses the first nonempty value from
`system-messages-locale`, `LC_ALL`, `LC_MESSAGES`, and `LANG`, then English.
Set a language tag explicitly when your preferred reading language differs
from the editor's message locale:

```elisp
(setq dsh-emacs-approval-language "zh")
```

Lookup tries the full language tag, its base language, English (`en`), then
the original `reason`. Tags are case-insensitive; underscores and POSIX locale
suffixes are accepted (`zh_CN.UTF-8` selects `zh-cn`, then `zh`). Empty or
invalid translation values are skipped. Older hosts without localized reasons
keep displaying their original text.

The selected reason is fixed when the approval enters the queue, keeping the
prompt and notification consistent. Notifications still prefer the actual
command when it is available. This option selects host-provided text only;
it does not translate commands, the yes/no reader, or the saved audit record.

## `ask` question prompts

Each question is one minibuffer read. The question text is the prompt, the
options are the completion candidates, and each candidate carries its own
description as a completion annotation (visible in the `*Completions*`
buffer or in the frontend's list), styled with `dsh-emacs-meta-face` — the
same face the transcript's ask card gives it, rather than whatever
`completions-annotations` default the frontend would otherwise apply.
Nothing is toggled in place and the reader never reopens, so the menu can
neither flicker nor reorder.

| Key | Single choice | Multiple choices |
|---|---|---|
| typing | Narrows the candidates as usual | The answer itself, comma-separated |
| `RET` | Accept the chosen candidate | Submit every comma-separated value |
| `C-c C-s` (default) | Skip the question | Skip the question |
| empty input | Skip the question | Skip the question |
| `C-g` | Abandon the whole question group | Abandon the whole question group |

Multiple choice uses Emacs' standard `completing-read-multiple`: type the
options separated by `crm-separator` (default `,`), for example `2,3` or
`alpha,beta`. Both the number and the label work — the number is part of the
candidate, and a bare number addresses the option at that position — so
either form round-trips to the same answer. Values are submitted in the order
the question offered the options, not the order they were typed. The prompt
says `2,3 or names, or your own text; empty = skip`. An unambiguous
prefix of a label resolves to it (`alph` finds `Alpha`); an ambiguous prefix
is not guessed and instead becomes the answer text, exactly like an
unmatched input at any Emacs completion prompt — there is no separate
"type an answer" candidate, the reader's text *is* the answer.  A
single-choice question accepts exactly one value.

The skip shortcut is controlled by `dsh-emacs-question-skip-key`; nil disables
it.  It uses a prefix key because the reader's text is the answer, so a bare
letter would make that letter untypable. Questions without options read free text directly and skip on empty input.

`dsh-emacs-question-help-display` controls the echo-area detail:

| Value | Display |
|-------|---------|
| `echo-area` (default) | The question's own detail in the bottom echo area, without message logging |
| `nil` | No detail; answering is unchanged |

```elisp
(setq dsh-emacs-question-help-display nil)
```

Only the question's detail goes to the echo area; option descriptions ride
along with their candidates instead, so they do not compete for that space.
Command errors and status messages take priority. On exit, cleanup removes
only the question's own message and preserves an unrelated message that has
replaced it.

### Timed questions (dsh 0.2.0)

A dsh 0.2.0 `ask_user_question` call may carry a foreground window (120
seconds by default). While the prompt is on screen Emacs holds the host's
foreground wait, so the window cannot expire and discard what you are typing.
Submitting keeps that protection until the host responds.
If the window does close before an answer — for example because the question
was queued behind another session's prompt — the question becomes **pending**
instead of lost:

- the transcript's ask row reads `❓ Ask question · pending`, and its expanded
  body keeps the questionnaire and names the recovery command;
- `M-x dsh-emacs-answer-question` (`C-c C-p`) lists the session's pending
  questions (one call is answered directly; several are chosen by their first
  question), asks them with the same reader, and submits the batch as a late
  reply. Incoming questions and approvals wait until this picker and reader
  close, including when you cancel with `C-g`;
- when the host records that reply the original card completes to
  `N/M answered` with the chosen options marked, and the answers also arrive in
  the transcript history on the next open or when loading older messages.

If another client answers the question before your reply is accepted, Emacs
reports that it is no longer waiting for an answer instead of reporting success.

The pending state comes from the host's `userQuestions` projection, so a
question asked while Emacs was disconnected is still answerable. On dsh 0.1.7
there is no timed mode and none of this appears.

`M-x dsh-emacs-question-preview` runs a local three-question sample batch
through the same reader — a multi-select with option descriptions, a
single-select, and an option-less free-text question — so it also shows the
`Question N/M` framing. It honors the display setting, sends no RPC, and
prints the whole batch's answers when you finish.

## Adding providers

`M-x dsh-emacs-add-provider` configures the connected dsh server without
opening a settings buffer or requiring an active chat session:

1. Select a catalog provider with completion, or type a new route name such
   as `my-gateway` (lowercase letters, digits and hyphens; start with a letter).
2. Enter the base URL. For a catalog provider, empty input keeps its default.
3. For a new custom route, select a protocol from the server's supported
   choices and enter one or more comma-separated model IDs. For a new catalog
   provider, leave model IDs empty to keep its built-in catalog.
4. Enter the API key in the password minibuffer. Empty input keeps an existing
   credential, or leaves provider-native authentication in use when none is
   configured. The prompt identifies the credential being replaced.

Completing the prompts saves the provider. `C-g` before submission cancels
without writing. `C-c C-m` in a chat buffer fetches the model catalog afresh,
so newly added models are available without restarting Emacs. This does not
automatically change any session's selected model.

Re-selecting an existing provider edits only its endpoint and API key; its
model definitions, protocols, custom headers and other fields are preserved.
An empty endpoint keeps the current value. Use the configuration-file or Web
entry for those advanced fields, including model capabilities and reasoning.

This command supports the pi-ai provider configuration shape, including
renamed settings namespaces. Other provider families and OAuth/account login
flows continue through `M-x dsh-emacs-open-web`. It uses the server's settings,
provider-directory and credential APIs; a read-only or unsupported server
reports an error instead of writing local configuration files.

API keys go to dsh's credential store; provider settings contain only the
credential reference. Settings are saved with the revision read at command
start: a concurrent change is rejected, and the key is not written. The
profile is saved before its key. If that second write fails, the command
reports partial success; re-run it, select the saved provider and enter the
key again. A changed server URL stops subsequent writes. Transport failures
can leave a write's outcome uncertain; inspect the original server before
retrying. Neither profiles nor credentials are automatically rolled back.

## Editing dsh configuration

Run `M-x dsh-emacs-edit-config` and select the existing configuration file
actually used by your dsh service. The command opens it with `find-file`,
using your normal major mode, completion, undo and save behavior. Save with
`C-x C-s`; dsh owns loading and validation, including when edits take effect.
The command does not install save hooks, send configuration RPCs or restart
the service, and works while the service is offline.

The selected path is remembered separately for each server base URL during
this Emacs session. `C-u M-x dsh-emacs-edit-config` chooses another file,
including when the remembered file has moved or the same server address now
uses a different configuration. Cancelling or failing to open a replacement
keeps the previous choice. No choice is written to your Emacs configuration.

The file location is not discovered or assumed to be `~/.dsh/settings.yaml`.
For a remote service, enter the actual TRAMP path, for example
`/ssh:user@host:/path/to/settings.yaml`; an HTTP address is not an SSH mapping.
Without filesystem access, use `M-x dsh-emacs-open-web` instead.
There is no default keybinding or additional package dependency.

## Server options

The full server bootstrap behavior lives in `dsh-emacs-server.el`:

```elisp
(setq dsh-emacs-server-auto-start t)         ; spawn `dsh web --no-open' when nothing answers at `dsh-emacs-base-url'
(setq dsh-emacs-server-start-on-init nil)    ; eager background start 1s after after-init-hook
(setq dsh-emacs-server-wait-seconds ...)     ; how long to wait for the server to become ready
(setq dsh-emacs-server-install-command "...") ; install command for a missing `dsh' CLI
```

Remote deployments need nothing special: a non-loopback base URL is only probed
for reachability — dsh-emacs never spawns or installs a local server for it.
HTTPS base URLs (including `https://user:pass@host` Basic-Auth endpoints) are
probed through TLS.
