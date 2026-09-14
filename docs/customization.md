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
(setq dsh-emacs-history-window 30)                  ; messages fetched when opening a session (maxMessages): larger = fuller history but slower opening (GC/parsing scale with it)
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
(setq dsh-emacs-busy-enter-behavior 'queue)          ; what C-c C-c does while a turn runs: `queue` lines input up as the next turn (default), `steer` wakes the running agent before its next step, `stop` interrupts like before; `C-u C-c C-c` explicitly sends a nonempty message with steer mode regardless of this setting or the local busy indicator, an empty input interrupts a running turn, and `C-c C-b` interrupts explicitly (C-c C-q manages the queue)
(setq dsh-emacs-question-skip-key "C-c C-s") ; key that skips the current ask question inside the reader (nil = no shortcut; empty input also skips)
(setq dsh-emacs-ui-label-separator "·")            ; separator between Think/Tool title and its right-side summary ("" = plain gap)
(setq dsh-emacs-tool-titles '(("pwsh" . "PowerShell"))) ; tool name -> display title overrides (icons stay per variant; unnamed tools get a humanized name, e.g. grep -> "Grep")
(setq dsh-emacs-attach-media-types '("image/png" "image/jpeg" "image/webp" "image/gif")) ; accepted upload types
(setq dsh-emacs-session-auto-refresh-interval nil) ; seconds between automatic session-list refreshes (nil = off)
(setq dsh-emacs-workspaces-collapsed-by-default nil) ; workspace and Ungrouped groups start expanded (t = collapsed); TAB/RET overrides a group in the current list buffer
(setq dsh-emacs-composer-goal-actions t)             ; show pause/resume/edit/clear buttons on the Goal Row (nil = hide them; C-c C-g keys still work; C-c C-g a / dsh-emacs-goal-actions-toggle toggles the current buffer)
(setq dsh-emacs-reference-auto-complete t)          ; typing "@" in the input pops the file/directory/session reference menu (TAB and M-x dsh-emacs-reference always work; see docs/reference.md)
(setq dsh-emacs-reference-prefetch t)               ; open-session pre-fetch of the bare "@" candidate lists (files + session roster) on an idle timer
(setq dsh-emacs-reference-prefetch-delay 0.5)       ; idle gap before the @ pre-fetch runs
(setq dsh-emacs-reference-fetch-delay 0.15)         ; idle debounce before a typed @ token re-fetches its candidates
(setq dsh-emacs-reference-max-files nil)            ; file/directory candidates shown in the "@" popup (nil = all host results)
(setq dsh-emacs-reference-max-sessions nil)         ; session candidates shown in the "@" popup (nil = all host results)
(setq dsh-emacs-modeline-enabled t)                  ; whether the mode-line stats are enabled
(setq dsh-emacs-modeline-show-step nil)              ; show the running turn's step badge next to the spinner (nil = hide it)
(setq dsh-emacs-shell-require-confirm nil)          ; ask y-or-n-p before running a `!` line (nil = run immediately, like M-!)
(setq dsh-emacs-shell-max-output 50000)             ; cap on a `!` command's captured output shown in the transcript
(setq dsh-emacs-shell-null-stdin t)                 ; close `!` commands' input pipe immediately (EOF, independent of shell syntax)
(setq dsh-emacs-shell-timeout nil)                  ; nil = no limit; positive integer seconds only (surviving background children are untracked)
```

## Session and workspace controls

These default keys apply in the session list opened by `M-x dsh-emacs`:

| Key | Action |
|---|---|
| `RET` | Open the session under point; on a group header, toggle folding |
| `c` / `C` | Create a session / create with a chosen agent preset |
| `r` | Rename the session under point |
| `d` | Archive the session without deleting it |
| `/` | Search |
| `g` | Refresh |
| `TAB` | Toggle folding for the workspace group |
| `W` | Create a workspace |
| `R` | Rename the workspace under point |
| `D` | Delete the workspace under point |
| `M` | Move the session under point to another workspace |
| `w` | Filter by workspace; empty input clears the filter |

Workspace and `Ungrouped` groups start expanded by default. Set
`dsh-emacs-workspaces-collapsed-by-default` to non-nil to start with all
groups collapsed. `M-x dsh-emacs-collapse-workspaces` and
`M-x dsh-emacs-expand-workspaces` fold or unfold every group in the list.

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

## `ask` question prompts

Each question is one minibuffer read. The question text is the prompt, the
options are the completion candidates, and each candidate carries its own
description as a completion annotation (visible in the `*Completions*`
buffer or in the frontend's list). Nothing is toggled in place and the reader
never reopens, so the menu can neither flicker nor reorder.

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

`M-x dsh-emacs-question-preview` runs a local three-question sample batch
through the same reader — a multi-select with option descriptions, a
single-select, and an option-less free-text question — so it also shows the
`Question N/M` framing. It honors the display setting, sends no RPC, and
prints the whole batch's answers when you finish.

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
