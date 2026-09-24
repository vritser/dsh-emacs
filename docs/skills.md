# Skills

dsh **skills** are host-side instruction bundles (`SKILL.md` plus optional
resources). A session sees the skills its working directory and agent preset
expose; the host lists the user-invocable ones through `skills.list`.

**There is no "run skill" RPC.** Invoking a skill is an ordinary prompt whose
text carries a `/name` gesture: the host's skill tool scans the direct user
input for `(^|\s)/name(?=\s|$)`, deduplicates the names it finds, and injects
each skill body as a user message before the next step. dsh-emacs therefore
only helps you *name* the gesture — discovery, completion and insertion — and
the normal send path delivers it.

## Three ways to invoke one

- **Type it**: `/review check the parser` + `C-c C-c`. The gesture works
  anywhere a word can start, so it also reads naturally inside a sentence
  ("please `/review` this diff").
- **Complete it**: `TAB` (or the front-end's auto popup) after `/` lists
  commands and skills together, from the same catalog the command completion
  uses. The token completes at the start of the input or after any whitespace,
  so a gesture already inside a sentence finishes in place (`please /rev` +
  `TAB` → `please /review `); mid-sentence it is claimed only when a skill or
  command actually matches, which leaves prose and paths to their own
  completion. A long name matches by word — `/probe` finds
  `dsh-emacs-skill-probe` (the `/` list defaults to prefix matching plus the
  built-in `flex` style, like `@` references). A user-only skill is marked
  `user-only` in the annotation.
- **Pick it**: `M-x dsh-emacs-command` is the one slash menu — it offers the
  session's commands *and* skills with their descriptions. Picking a skill
  inserts `/name ` at the cursor, replacing any `/name` token being typed
  there, ready for arguments — the same pick behavior as dsh web (`C-u` opens
  the picked skill's `SKILL.md` instead, for providers that ship no file it
  reports that; commands in that menu still run). When the cursor sits right
  after a word that is not such a token, a separating space is inserted too,
  because the host only accepts the gesture at the start of the message or
  after whitespace.

## What the host does with the line

A `/name` line is first offered to `commands.execute`, exactly like a slash
command. Skills are not registered commands, so the host declines the name and
dsh-emacs re-sends the line as an ordinary prompt (the admission-miss
fallback) — which is where the skill tool expands the gesture. Nothing extra
is sent for the skill itself: the turn proceeds with the injected instructions
and the assistant's reply is a normal reply, in the same transcript.

A skill name that does collide with a registered command runs the **command**
(host admission wins), the same as in dsh web.

In the transcript the gesture is **accented in violet with no border**, its
description on hover, so a sent `/name` reads as something the host acted on;
an ordinary slash command gets a blue bordered chip, and text that only looks
like a path or a fraction stays plain. See
[UI styling](ui-styling.md#slash-gestures-in-user-messages).

## Model-invocable vs user-only

`modelInvocable` (from the host) decides whether the model may also load the
skill through the `skill` tool. Skills without it are **user-only**: you can
still invoke them, and dsh-emacs marks them in the `/` completion annotation
and in the slash menu row; the model just cannot reach for them on its own.

## Catalog lifetime

The catalog is a cold read of the session's current composition, cached per
session. Opening a chat buffer pre-fetches it on a short timer
(`dsh-emacs-skill-prefetch`, `dsh-emacs-skill-prefetch-delay`) so the first `/`
does not block on a round trip; if the agent preset changes while a session
stays open, `M-x dsh-emacs-skill-catalog-refresh` re-reads it. A session with
no skills is remembered as such, so `TAB` does not re-fetch it every time.

`whenToUse` is a model-facing hint and is not shown in the client's menus.

Synchronous completion lookups and asynchronous refreshes share request
ordering: an older response cannot replace a newer catalog or clear its
in-flight request.
