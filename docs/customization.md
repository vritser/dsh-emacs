# Customization Options

The most commonly used options, straight in your config:

```elisp
(setq dsh-emacs-base-url "http://127.0.0.1:3080")  ; dsh service URL; a `?token=...` query (the URL dsh prints) is read for auth and stripped before paths are appended
(setq dsh-emacs-server-auth-token nil)         ; launch token for dsh web 0.1.2-rc.1+; nil = auto-captured from a server dsh-emacs starts itself.  Set it for a server YOU run externally (a fresh random value every server restart).  When pointing at an external auth-requiring server with no token set, dsh-emacs asks you for it; a token that successfully authenticates is remembered here automatically (saved), so the next session reuses it — only a stale token (validation fails after a server restart) re-prompts, pre-filled for editing.  Successful authentication also caches the cookie instead of showing a Basic username/password prompt
(setq dsh-emacs-history-window 30)                  ; messages fetched when opening a session (maxMessages): larger = fuller history but slower opening (GC/parsing scale with it)
(setq dsh-emacs-show-reasoning t)                  ; show reasoning content (on by default; nil = hide, unlike dsh web)
(setq dsh-emacs-show-tool-calls t)                 ; show tool calls
(setq dsh-emacs-default-cwd default-directory)     ; fallback working directory for new sessions (interactive ones use the current buffer's default-directory first)
(setq dsh-emacs-new-session-auto-project t)        ; auto-detect the Emacs project of the working directory and place new sessions in its workspace (nil = always start in CWD)
(setq dsh-emacs-default-model "claude-opus-4-5")   ; default model name
(setq dsh-emacs-default-preset "standard")         ; default agent preset for new sessions (nil = host default; "standard"/"minimal"/"code"/"cordis" or a user preset id)
(setq dsh-emacs-model-group-format #(" %s " 0 4 (face vertico-group-title))) ; provider group-header format inside the model picker (nil = hide group titles)
(setq dsh-emacs-input-history-length 50)           ; prompts kept for M-p / M-n recall
(setq dsh-emacs-input-history-cross-session nil)   ; M-p / M-n recall only the current session's prompts (nil, default); t = recall prompts from every session
(setq dsh-emacs-busy-enter-behavior 'queue)          ; what C-c C-c does while a turn runs: `queue` lines input up as the next turn (default), `steer` wakes the running agent before its next step, `stop` interrupts like before; `C-u C-c C-c` explicitly steers one message regardless of this setting, an empty input always interrupts, and `C-c C-b` interrupts explicitly (C-c C-q manages the queue)
(setq dsh-emacs-question-skip-key "s")       ; key that skips the current ask question inside the minibuffer chooser (nil = no shortcut; option-less free-text questions still skip on empty input)
(setq dsh-emacs-ui-label-separator "·")            ; separator between Think/Tool title and its right-side summary ("" = plain gap)
(setq dsh-emacs-tool-titles '(("pwsh" . "PowerShell"))) ; tool name -> display title overrides (icons stay per variant; unnamed tools get a humanized name, e.g. grep -> "Grep")
(setq dsh-emacs-attach-media-types '("image/png" "image/jpeg" "image/webp" "image/gif")) ; accepted upload types
(setq dsh-emacs-session-auto-refresh-interval nil) ; seconds between automatic session-list refreshes (nil = off)
(setq dsh-emacs-reference-auto-complete t)          ; typing "@" in the input pops the file/directory/session reference menu (TAB and M-x dsh-emacs-reference always work; see docs/reference.md)
(setq dsh-emacs-reference-prefetch t)               ; open-session pre-fetch of the bare "@" candidate lists (files + session roster) on an idle timer
(setq dsh-emacs-reference-prefetch-delay 0.5)       ; idle gap before the @ pre-fetch runs
(setq dsh-emacs-reference-fetch-delay 0.15)         ; idle debounce before a typed @ token re-fetches its candidates
(setq dsh-emacs-reference-max-files nil)            ; file/directory candidates shown in the "@" popup (nil = all host results)
(setq dsh-emacs-reference-max-sessions nil)         ; session candidates shown in the "@" popup (nil = all host results)
(setq dsh-emacs-modeline-enabled t)                  ; whether the mode-line stats are enabled
```

## `ask` question prompts

Answering an `ask` prompt happens in a **static key menu**, not a typing
prompt: the numbered option list never narrows as you press keys.

- `1`–`9` pick that option immediately (`0` = the 10th option);
- `t` switches to the `Type answer…` free-text path;
- the `dsh-emacs-question-skip-key` binding (default `s`) answers the
  question with an empty selection and moves on;
- `RET` confirms the preselected first option, `C-g` abandons the whole
  group.

Multi-select questions keep plain comma-separated typing (digits are typed
text there), and option-less questions read free text directly.  Without a
list-rendering completion UI (vertico, icomplete, fido, ivy) the numbered
options are embedded in the prompt itself, so the same keys work on a bare
minibuffer.

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
