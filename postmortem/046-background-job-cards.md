# 046 — Background-job cards

## Background

dsh runs background work through `bash` / `pwsh` with `run_in_background`, and
exposes `@deepseek-ai/dsh-tool-jobs`' `job_output`, `job_list` and `job_kill`
to read, list and cancel it.  At the `233bdfb` baseline the renderer knew none
of the three names: they are absent from `dsh-emacs--tool-variants` and
`dsh-emacs-tool-titles`, so every job call fell through to the generic ioCard.
Its `IN` was the pretty-printed argument JSON (`{"job_id": …}`) and its `OUT`
the raw result text with the Host's status line buried inside it as data.

The Host's model-facing text already carries the structure, and there is no
result `meta` for these tools: a `job_output` result ends with
`[status: <status>[, <detail>]]`; `job_list` prints one
`id [kind] status — label` line per job; `job_kill` prints a one-line
acknowledgement.

## Decision

Render the three job tools as their own card in `dsh-emacs-render.el`:
`dsh-emacs-render--job-card-body` draws the result text (never the argument
JSON) as indented rows and splits a `job_output`'s trailing status line into a
state-colored footer; a nonzero `exit code` detail overrides the success
color of `completed`.  `job_list` colors each row's lifecycle status token
(a label that spans lines stays indented under its row).  `Job Output` /
`Jobs` / `Kill Job` titles are added to `dsh-emacs-tool-titles`.
The existing summary-key table gains tool-specific priorities so `job_output`
and `job_kill` select `job_id` regardless of argument order.

## Why

The output is the whole point of `job_output`, and the generic card buries it
under the args JSON.  Splitting the status line is the same move the bash card
makes for `[exit code: N]`: the Host put the state in the text, so the renderer
parses it there instead of inventing a wire field.

The Host's `completed` means the background process exited; even a nonzero
exit gets that status.  The footer must use the exit detail to distinguish
command failure.  Likewise, once the card drops argument JSON, the summary
must reliably identify the job: selecting the first string could display a
cancellation reason instead when it precedes `job_id`.

dsh web has no job view to mirror — `presentTaskCall` returns a `generic` card
— so this shape is the client's own.  Keying it on the tool name keeps it
small: a job tool from another producer with the same names gets the same card,
and any result that loses its status line falls back to the unchanged ioCard.

Rejected: a live jobs mirror surface (the `jobs` frames and `session/control`
record that `dsh-emacs-events.el` drops).  The tool results already answer
"what did the job print"; a running-jobs strip needs its own placement and
refresh design, and was deliberately deferred rather than guessed at.

## Consequence

A `job_output` row shows the job's output plus a footer in the face matching
the job status (success for `completed` unless its exit code is nonzero,
error for `failed`, stopped for `killed`/`stopping`, pending for `running`);
`job_list` shows one row per job with its lifecycle status colored and
`job_kill` its acknowledgement.  Argument JSON is gone; `job_output` and
`job_kill` headers carry the job id as their summary.  No new faces or user
options.

Docs touched: CHANGELOG 0.4.0 `Added` / `Fixed`, `docs/ui-styling.md`.
Assertions in `test/dsh-test.el` cover output, list and kill cards, footer
colors for zero and nonzero exits, job-id summaries when the reason comes
first, and the no-status fallback to the ioCard.

## Known limitations

- `job_list` carries lifecycle status without exit details, so its
  `completed` color cannot distinguish command success from failure.  Read
  the job with `job_output` for the exit detail.
- The status line is recognized only as the final `\n[status: …]` line; a
  producer that changes that marker silently reverts the row to the ioCard.
- There is still no live job list: `jobs` frames/records stay dropped, so a
  running job's progress is visible only through its `job_output` reads.
- A background `bash` row still renders as a terminal card whose output is the
  `started background job <id>` acknowledgement; it is not retitled as a job.
