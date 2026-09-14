# 042 — Question prompts: one read, comma-separated answers

Records the successive attempts at this feature — a dedicated side window, a
recursive bottom form, floating tips anchored at the cursor and then at the
option row, a remembered acceptance default, a setup lock, in-place toggling,
delayed tips, and finally the single-read reader. They are folded into this
record; only the surviving decisions and the rejected alternatives remain.

## Background

The static question chooser introduced by `f0c37db` made single-choice
questions a numbered key menu. At baseline `9d5611a`, multiple-choice
questions still used comma-separated completion, so digits became typed
text and selections had no visible toggle state. The UI read labels from
wire alists and omitted question details and option descriptions. The
failing layers were the question UI and protocol decoding; the waterfall
transport from postmortem 009 already carried the necessary payload.

## Decision

Decode `user-questions/request` items into protocol structs and answer each
question in **one minibuffer read**: the question text and a hint are the
prompt, the numbered options are the completion candidates, and each
option's description is delivered as a completion annotation.  There is no
"type an answer" candidate: the reader's text is the answer, so text that
names no option is the free-text answer and every question is one read.  A
partly-matched answer (some elements name options, some do not) is kept
whole as text rather than silently trimmed to the elements that matched; a
selection comes back in the question's option order, so the answer cannot
depend on the order the user happened to type.
Multiple choice uses `completing-read-multiple` from the bundled
`crm.el` — the stock comma-separated input path — and single choice takes one
candidate from the same reader. Empty input and the `dsh-emacs-question-skip-key`
shortcut skip the question; `C-g` abandons the whole waterfall. The
question's own detail shows in the echo area
(`dsh-emacs-question-help-display`, default `echo-area`, `nil` to hide).
The change is an uncommitted working-tree change on `9d5611a`; there is no
commit for the rejected prototypes.

## Why

Emacs' completion model has one place to put "which candidate should be
selected" — the `DEFAULT` argument — and the frontends decide what to do with
it. A prompt-based multi-select therefore has only two shapes:

- **read a value once** (what a completion read is for), or
- **re-enter the reader per keypress**, because the marks live in the caller's
  loop and the frontend computes candidates from the input only.

Every earlier iteration took the second shape and then tried to hide its
cost. That cost is structural: the frontend only recomputes candidates when
the input changes, so markup visible in the list cannot be changed in place
without writing frontend-private state (`vertico--candidates`, `--index`,
`--lock-candidate`). Postmortem 011 already ruled that out for the
code-completion path ("hooking a front-end's private `--` function makes the
package a UI driver"); this record extends the same rule to the question
reader, and a prototype that did write that state was removed.

Measurements on both supported frontends showed why the workarounds kept
leaking: a matching `DEFAULT` is bubbled to the first row by Vertico
(`vertico--move-to-front`, after sorting, so `vertico-sort-function` cannot
suppress it) and deliberately by Icomplete ("bubbling the default to top …
so that `icomplete-force-complete-and-exit` will select it"). Toggling with a
remembered default kept the cursor on the marked option but renumbered the
rows; dropping the default kept the order but sent the cursor back to the
first row. `vertico-preselect` cannot substitute for either: it only chooses
between the prompt and the first candidate, and no frontend exposes a public
"start on candidate X" slot.

The single-read shape removes the whole trade-off. `completing-read-multiple`
is the standard Emacs idiom for "select several of these"; the reader states
its own short hint (`2,3 or labels; empty = skip`) instead of CRM's longer
`[comma-separated list]` prefix, which would repeat it. It never reopens, never reorders
and never calls back into a frontend. Option descriptions are public
completion API (`completion-extra-properties`' `:annotation-function`), so
they appear wherever the user's completion UI shows annotations instead of a
tooltip this package has to position. The question's own detail keeps the
existing echo-area surface, which needs no geometry: it uses `message` with
logging disabled, remembers its own last text, and clears only a matching
current message so a later error survives.

Rejected alternatives, kept as history: a dedicated side window and a
recursive bottom editor both demanded switching focus away from the
conversation, which the user asked to avoid; an Eldoc documentation provider
lands in a window the completion UI's child frame covers and supplies no
echo-area help; a floating tooltip following the highlighted row needed glyph
inspection across visible windows, a one-shot idle timer, an NS coordinate
compensation, and a temporary focus observer — a whole subsystem whose only
job was to follow a highlight that no longer exists; reading the frontend's
private candidate state would have made the package a UI driver and was
reverted; and in-place `[ ]/[x]` toggling in the minibuffer is simply not
expressible through the public completion API.

## Consequence

An `ask` prompt is one read, so answering is fast and stable: no reopen, no
flicker, no reordering, and identical behavior under Vertico, Icomplete,
Fido, Ivy, Corfu or the stock minibuffer. Answers round-trip labels
verbatim (a label may itself contain a comma, a number prefix, or a reserved
word like `Submit answer`); an unresolvable value is an error instead of a
silent drop. Exposed surfaces are `dsh-emacs-question-help-display`,
`dsh-emacs-question-skip-key`, and the local `dsh-emacs-question-preview`
command, which runs the production reader without a server. Removed:
`dsh-emacs-question-tip-delay`, the tooltip path, the glyph-position
scanner, the delayed-tip timer and focus observer, the toggle/checkmark
machinery, and the `dsh-emacs-question-tip-face` face (delete, don't
deprecate). There is no change to the answer RPC. README, customization,
architecture and the 0.4.0 changelog document the workflow; tests cover
candidate numbering, label resolution, annotations, single and multiple
answers, skipping, keymap binding, prompt hints, echo-area detail, and
answer serialization.

## Known limitations

Digit shortcuts are gone: with the answer typed as a value, there is no
per-key menu to bind. The numbered candidates remain, so typing `2` or
`alpha` is equivalent. Option descriptions depend on the completion UI
showing annotations (`*Completions*`, Vertico and Icomplete do; a frontend
that ignores annotations shows labels only). The echo area shares space with
the minibuffer, so the detail temporarily replaces the visible prompt until
the next input. Only one value is accepted per single-choice question.
`completing-read-multiple` splits on `crm-separator`, whose default treats
spaces around a comma as part of the separator, so a free-text answer's
words are rejoined with a comma; customize `crm-separator` for different
input.  Because `require-match` is nil, completion can hand back an
unexpanded element, so resolution accepts a bare number, a label, or an
unambiguous (case-insensitive) label prefix — an ambiguous prefix is never
guessed at, it becomes the answer text. Two frontend details had to be accommodated on the way and are worth
remembering: the reader preselects the prompt (a frontend that preselects
the first candidate inserts it into the field, so a bare RET stops meaning
"skip"), and the answer must not be read with `require-match` (a mandatory
match lets the frontend turn a bare RET into its selected candidate).  A
prototype that wrote the completion frontend's private candidate state in
order to toggle marks in place was removed; see the "Why" section.
