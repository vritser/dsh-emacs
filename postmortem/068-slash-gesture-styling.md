# 068 — Slash gestures are accented from catalog evidence, not from shape

## Background

The client renders a sent prompt as an ordinary user block.  A `/name` line is
not ordinary text though: it is the token the host acts on — `commands.execute`
for a registered command, and a skill gesture the host's `skill` tool expands
from the prompt text (postmortem/067).  Until now the transcript showed
`/dsh-emacs-skill-probe` and `/usr/bin` with exactly the same face, so a user
could not tell what the host had picked up.

dsh web does distinguish them: its user-text projection decorates a `/name`
token as a skill chip, and it only does so for names the host itself confirmed
for that message — the `skill-invocation` copies the host appends right after
the messages it scanned.

## Decision

Accent a `/name` token in a user message when a **cached catalog confirms the
name**: `/usr/bin`-style tokens, fractions, unknown names and
punctuation-suffixed prose stay plain.  Two faces carry the catalog description
on `help-echo` and never change the token text: `dsh-emacs-slash-command-face`
(blue, boxed) for a command the host executes, `dsh-emacs-slash-skill-face`
(violet, **no** border) for a gesture the host only expands — the border itself
is the cue for "this one runs".

Classification lives in `dsh-emacs-command.el` (which owns the `/` token and
the catalogs), the application in `dsh-emacs-render.el`:

- `dsh-emacs-command-fontify-gestures` styles the user-block string before it
  is inserted (properties travel with it, and the block's own face is appended
  after, so nothing is clobbered);
- `dsh-emacs-command-decorate-skill-gesture` accents a token in an already
  inserted, read-only block, driven by the host's hidden `skill-invocation`
  copy (`data.source.kind`), which is authoritative evidence that the gesture
  in the message above was a skill.

## Why

- **Catalog-confirmed beats shape-alone.** A word-bounded `/token` grammar is
  not enough: `/usr/bin`, `/tmp`, `5/8` and `http://…` are ordinary prose, and
  accenting them would be noise the user cannot turn off per message.  The
  catalogs are already cached per session for the `/` completion, so the
  confirmation is free.
- **Reading must not fetch.** The renderer runs inside the event stream: a
  synchronous `skills/list` there would block the transcript on the network
  (and could re-enter the stream).  The cost is that a message rendered before
  its catalog lands stays plain — which is exactly what the evidence path
  fixes.
- **The host's injection closes the replay race.** On a replayed transcript,
  the follow snapshot and the open-session prefetch race: whichever wins, the
  user message can render before the skill catalog is cached.  The hidden
  `skill-invocation` copy arrives in the same ordered stream right after the
  message it belongs to, so accenting from it styles history reliably and
  without a re-render pass.
- **Host evidence settles name collisions.** An inline or queued skill can
  share a name with a command without passing through command admission. The
  evidence pass replaces that command styling, while keeping an existing skill
  tooltip and the user block's other faces. Repeated evidence cannot downgrade
  a cached description to the name-only fallback.
- **Rejected: style every slash-shaped token.** Always-on styling would remove
  the timing dependence, but it would accent paths and fractions (the grammar
  cannot tell `/tmp` from `/goal`) and cannot say command vs skill.
- **Rejected: re-fontify the transcript when a catalog lands.** It would cover
  commands too, but it needs a "catalog updated" signal across modules
  (dsh-emacs-skill.el would have to reach into the transcript) and re-scans
  every message for a cosmetic gain the evidence path already delivers for
  skills.
- **Rejected: retro-decorate from the catalog instead of the injection.** The
  injection is the host's own statement that it expanded a gesture; the catalog
  only says a name exists.  Using the injection also keeps working when the
  catalog fetch failed or is stale.

## Consequence

- New faces `dsh-emacs-slash-command-face` / `dsh-emacs-slash-skill-face` and
  their palette options (`dsh-emacs-color-slash-command(-dark)`,
  `dsh-emacs-color-slash-skill(-dark)`), documented in `docs/ui-styling.md`.
- New command-module surface: `dsh-emacs-command-fontify-gestures`,
  `dsh-emacs-command-decorate-skill-gesture`, and the internal
  `dsh-emacs-slash-gesture` text property that marks an accented token.
- `dsh-emacs-render--insert-user-block` now styles the user text and handles
  the `skill-invocation` source kind (still rendering nothing for it).
- The command catalog's chip is what makes a *queued* slash line legible:
  `commands.execute` normally replaces the line with a command card, so a
  command token only appears as user text when input was queued.

## Known limitations

- No input-area (composer) styling: the draft shows the raw `/name` text.
- A command token rendered before `commands/list` was cached stays plain, since
  no injection exists to re-accent it; only skills have host evidence.
- The evidence pass targets the nearest preceding user message, which is the
  right one for this client (one prompt per step).  A host batch carrying
  several direct messages in one step would only accent the last of them.
- `M-x dsh-emacs-skill-catalog-refresh` does not re-accent tokens already
  rendered plain; a new send (or its injection) does.
