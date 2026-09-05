# 014 — Prefix Argument Explicitly Selects Steer

## Background

The queue/steer workflow introduced `C-u C-c C-c` as a temporary inversion
of `dsh-emacs-busy-enter-behavior`.  This made the same key send different
modes depending on configuration: it steered from `queue`, queued from
`steer`, and was ignored by `stop`, which interrupted the turn.

## Decision

While a turn is running, `C-u C-c C-c` explicitly submits the current input
with `mode: "steer"`.  It does so for all three configured busy-enter
behaviors.  Plain `C-c C-c` continues to follow the configured behavior, and
empty input continues to interrupt.

## Why

A prefix action should have one predictable meaning.  Explicit steer is also
the useful override for users who keep `stop` as their default: they can
redirect a running turn without changing the option first.

## Consequence

The key is now a stable steer gesture rather than a queue/steer toggle.
Users who configure `steer` no longer use the prefix to queue; they can set
the default to `queue` when queueing should be the ordinary action.

Tests cover the prefix with `queue`, `steer`, and `stop` defaults.

## Known limitations

The prefix only changes handling while a turn is running.  When idle,
`C-u C-c C-c` starts an ordinary turn, as `C-c C-c` does.
