# Customization Options

The most commonly used options, straight in your config:

```elisp
(setq dsh-emacs-base-url "http://127.0.0.1:3080")  ; dsh service URL
(setq dsh-emacs-history-window 30)                  ; messages fetched when opening a session (maxMessages): larger = fuller history but slower opening (GC/parsing scale with it)
(setq dsh-emacs-history-refetch-max-rounds 6)       ; max backfill rounds during load gaps: improves coverage when events are still arriving at high rate right after opening, at the cost of more small parse chunks
(setq dsh-emacs-show-reasoning t)                  ; show reasoning content (on by default; nil = hide, unlike dsh web)
(setq dsh-emacs-show-tool-calls t)                 ; show tool calls
(setq dsh-emacs-default-cwd default-directory)     ; working directory for new sessions
(setq dsh-emacs-default-model "claude-opus-4-5")   ; default model name
(setq dsh-emacs-default-preset "standard")         ; default agent preset for new sessions (nil = host default; "standard"/"minimal"/"code"/"cordis" or a user preset id)
(setq dsh-emacs-model-group-format #(" %s " 0 4 (face vertico-group-title))) ; provider group-header format inside the model picker (nil = hide group titles)
(setq dsh-emacs-input-history-length 50)           ; prompts kept for M-p / M-n recall
(setq dsh-emacs-ui-label-separator "·")            ; separator between Think/Tool title and its right-side summary ("" = plain gap)
(setq dsh-emacs-tool-titles '(("pwsh" . "PowerShell"))) ; tool name -> display title overrides (icons stay per variant; unnamed tools get a humanized name, e.g. grep -> "Grep")
(setq dsh-emacs-attach-media-types '("image/png" "image/jpeg" "image/webp" "image/gif")) ; accepted upload types
(setq dsh-emacs-session-auto-refresh-interval nil) ; seconds between automatic session-list refreshes (nil = off)
(setq dsh-emacs-modeline-enabled t)                  ; whether the mode-line stats are enabled
```

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