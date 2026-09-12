# 042 — Question prompts: multiple selection and floating explanations

Records 043–048 recorded successive presentations of this feature —
a dedicated side window, a recursive bottom form, floating tips anchored
at the cursor, then the option row, then re-styled and re-positioned, and
finally a configurable display surface. They are folded into this record;
only the surviving decisions and the rejected alternatives remain.

## Background

The static question chooser introduced by `f0c37db` made single-choice
questions a numbered key menu. At baseline `9d5611a`, multiple-choice
questions still used comma-separated completion, so digits became typed
text and selections had no visible toggle state. The UI read labels from
wire alists and omitted question details and option descriptions. The
failing layers were the question UI and protocol decoding; the waterfall
transport from postmortem 009 already carried the necessary payload.

## Decision

Decode `user-questions/request` items into protocol structs, extend the
existing numbered chooser to toggle multiple selections, and show the
question detail plus the highlighted option's description as floating help.
`dsh-emacs-question-help-display` chooses the surface: `tooltip` (default),
`echo-area`, or nil. The change is an uncommitted working-tree change on
`9d5611a`; there is no commit for the rejected prototypes.

## Why

A stock completion read already owns navigation and candidate acceptance.
Repeating that read after each toggle gives the user persistent selection
marks without coupling updates to private completion front-end internals;
selected labels stay in their offered roster order. Setup runs after
front-end hooks so they cannot replace the menu bindings. `SPC` uses
Icomplete's public candidate-acceptance command, since plain Icomplete RET
can accept the default instead of the highlighted option; other front-ends
supply their existing RET action. RET itself submits the marked set.
Direct digit, type, skip and submit shortcuts return through a catch/throw
scoped to the completion read, which preserves front-end cleanup while
bypassing front-end-dependent return values (Ivy returns its selected
candidate even when a command inserts a different string).

Explanation text belongs near the option rather than in every candidate.
Stock tooltips neither take focus nor split windows, but ordinary tooltip
mode hides its tip before each command, so the question's minibuffer owns
post-command refresh and per-question exit cleanup. The text follows the
selected glyph: a candidate index is not a screen row, because scrolling,
wrapping and posframe placement change geometry, while Vertico and Icomplete
already mark their selection with faces. Reading the displayed glyph matrix,
including overlay strings, follows that geometry without duplicating a
front-end's layout algorithm or calling its private display functions.
Icomplete rotates its candidate cache, so its first candidate must be
resolved back to the roster; Vertico indexes a fixed roster; inactive
front-end state must not mask the active one. Free-text input documents the
question itself.

`x-show-tip` with local frame parameters and a package face keeps colors
local, which the older `tooltip-show` cannot do without changing the user's
global tooltip face. NS `frame-edges` reports child coordinates relative to
the parent despite promising display coordinates, and NS `compute_tip_xy`
treats `bottom` like `top`; the reader converts through the parent chain and
moves the rendered frame using its measured height, which preserves the
renderer's own wrapping and padding. Echo-area output uses `message` with
logging disabled and remembers its last text, clearing the echo area only
while it still holds that text, so a later error or status message survives.
The Emacs 27.1 legacy path stays intact; protocol normalization remains in
the protocol module, as in postmortem 019.

Rejected alternatives: a dedicated side window for the whole form and a
recursive bottom editor both demanded switching focus away from the
conversation, which is what the user asked to avoid; an Eldoc documentation
provider was dropped because its display lands in a window the completion
UI's child frame covers and does not supply echo-area help while answering;
a backend registry for display surfaces would have been a wrapper layer for
three branches.

## Consequence

Multiple-choice questions show `[ ]` / `[x]` marks: digits or `SPC` toggle,
RET submits the marked set, and `t` accepts a custom answer alongside them.
Skip clears the current question's selection, and C-g still abandons the
whole waterfall. Exposed surfaces are `dsh-emacs-question-help-display`,
`dsh-emacs-question-tip-face` (in `dsh-emacs-faces.el`) and the local
`dsh-emacs-question-preview` command, which runs the production reader
without a server and honors the display setting. There is no change to the
answer RPC. README, customization and architecture docs and the 0.4.0
changelog document the workflow; tests cover selection, help text, frontend
selection, tip positioning, local hooks, cleanup and answer serialization.

## Known limitations

Digit shortcuts cover ten options. A toggle reopens completion and may reset
the highlighted row. Only Vertico and Icomplete expose a readable selection,
and other frontends document the first option; glyph inspection is bounded
by the visible completion window, so a supported frontend without a visible
highlight hides the tip until a row is displayed. Tips are capped at 48
columns and 24 lines, so long descriptions clip. The NS adjustment happens
immediately after the primitive renders the tip, so it is not atomic; this
is explicit platform compensation debt, to revisit if Emacs fixes its NS
coordinate contracts. Terminal frames show a compact minibuffer message
instead of a tip. The echo area shares space with a normal minibuffer, so
help temporarily replaces the visible prompt until the next input, and it
can show only `max-mini-window-height' — a quarter of the frame by default.
Longer explanations are therefore clamped to that budget and marked with a
trailing `…` rather than left to be cut off silently; raising the variable
buys room, and `echo-area` still provides no separate documentation buffer.
The native macOS appearance was verified by a bounded probe rather than an
interactive session.
