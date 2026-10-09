# 088 — Keep job status in the transcript

## Background

At `a88464a`, background jobs had transcript tool cards, a dedicated manager
and a live `[Jn]` mode-line count. The user requested removing the mode-line
count because the tool rows already indicate job activity.

## Decision

Remove the job segment from the shared native/Doom mode-line composition.
Delete its cache, face, mouse keymap and roster-triggered redraw helper.
Keep the job roster, output streams, live-count menu prompt and `C-c C-j`
manager. This record accompanies the uncommitted change against `a88464a`.

## Why

The duplicate status consumes mode-line space without adding enough value.
Removing its support code avoids keeping unused customization and redraw
work. The roster still serves a current purpose: the manager needs live job
state to inspect output and stop running work, so its subscription remains.

## Consequence

Job management is reached through `C-c C-j` or `dsh-emacs-list-jobs`.
The removed `dsh-emacs-jobs-modeline-face` and `dsh-emacs-jobs-map` have no
compatibility aliases. Mode-line composition tests include a running job
and expect only the remaining status segments; job manager tests remain.

## Known limitations

Job activity is no longer visible as a separate count when its tool rows
are off screen. The manager remains available from the chat keymap.
