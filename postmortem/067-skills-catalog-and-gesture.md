# 067 — Skills: the catalog is client-side, invocation is a prompt gesture

## Background

dsh skills are host-side instruction bundles (`SKILL.md` plus resources) that a
Session sees through its cwd and agent-preset composition. The `skills`
namespace has one endpoint — `skills/list` — and the client never called it, so
a skill the host could serve was invisible in Emacs: no completion, no picker,
no way to discover the name a `/name` gesture needs. The catalog is a unary
read, so adopting it requires no new stream.

The investigation that shaped the design is about the *invocation* side, not
the catalog. Reading the host (`@deepseek-ai/dsh-tool-skill`,
`@deepseek-ai/dsh-skill`) shows there is **no skill-invocation Remote at all**:
the tool holds one `agent/pre-step` hook that scans the claimed batch's direct
user text for the gesture `(^|\s)/name(?=\s|$)`, deduplicates the names in
first-seen order, and appends each matched skill body as a user message
(`<skill_content …>`). dsh web mirrors that: its `skill` input source has no
`matchEnter`, so picking a skill only inserts `/name ` and the ordinary prompt
send carries the gesture.

## Decision

Adopt `skills/list` as a new client module, `dsh-emacs-skill.el`, that owns the
per-session catalog (fetch/cache/prefetch/refresh, `dsh-protocol-skill` +
`dsh-protocol-skill-list` in the protocol layer), the row label and the
`SKILL.md` opener; and make the `/` surface in `dsh-emacs-command.el` serve both
catalogs: the `/` completion and the `M-x dsh-emacs-command` slash menu list
commands and skills in one list, marking user-only skills.

No new send path: a `/name` line still goes to `commands.execute` first, and a
skill name — not being a registered command — takes the existing admission-miss
fallback to an ordinary prompt, which is exactly where the host expands the
gesture. That is web's end state, reached by the path the client already had.

## Why

- **The gesture lives in the prompt, so the client's job is naming it.** A
  dedicated "run skill" RPC would have to be invented client-side and would
  still have to reproduce the host's text-scanning semantics (multiple gestures
  per message, dedup, `userInvocable` filtering). Reading the catalog and
  inserting the text the user could have typed keeps the client honest about
  what the wire actually supports — `rpc.md` §4.2 records the same conclusion.
- **One `/` menu, two catalogs.** The user types one token; dsh web registers
  the skill source on the same `trigger: "/"` with the command source. Splitting
  the Emacs completion into two `completion-at-point-functions` entries would
  not work (the first non-nil entry wins for a region), so the merge point is
  the existing capf. The `M-x` menu merges for the same reason: a user who does
  not know which namespace an item lives in should not have to guess between two
  commands, and the host's own distinction is invisible at pick time anyway.
  The menu dispatches on the item type — a command runs (its hint is read), a
  skill inserts its gesture — so the two namespaces stay distinct where it
  matters, in what happens next.
- **A separate module, not more of `dsh-emacs-command.el`.** `skills/list` is a
  different namespace with its own args shape (`{request: {sessionId}}`, unlike
  `commands/list`'s `agentId` scope lookup), its own optional fields
  (`path?`/`whenToUse?`) and its own lifetime knob; `dsh-emacs-jobs.el` and
  `dsh-emacs-reference.el` set the precedent that a namespace with its own
  catalog gets a file. The `/` token, its completion and the menu stay in the
  command module because that module owns the token; `dsh-emacs-skill.el`
  exposes only data and skill-specific actions (`dsh-emacs-skill-label`,
  `dsh-emacs-skill-open`), so the dependency stays one-way (command → skill).
- **An empty catalog is cached.** Unlike `commands/list`, a session with no
  skills is common; caching "fetched, zero items" (a separate
  `dsh-emacs-skill--fetched-p` check, since `nil` and "not fetched" are
  indistinguishable through the public reader) keeps TAB from paying a round
  trip on every press.
- **A superseded response is dropped.** Both catalogs refresh by
  invalidate-then-fetch, so a slow older response could otherwise land after
  the newer one and restore the stale list — a defect the command catalog had
  carried since it was written. Every fetch now carries a per-session stamp,
  and only the current one may write the cache or clear the in-flight flag; the
  same guard went into the command catalog while the two are read side by side
  by one menu.
- **Rejected: a separate skill picker.** A second `M-x` command would have to
  duplicate the menu shell (candidate building, `completing-read`, the row
  format) and would leave the user deciding "is this a command or a skill?"
  before they can even look. The cost of merging — one `pcase` on the picked
  item — is smaller than the duplication.
- **Rejected: making a skill pick execute immediately.** Web's pick inserts
  text, and skills accept trailing free-form arguments; submitting on pick
  would take the argument input away. The menu's prefix argument instead opens
  the `SKILL.md` the host reports via `path?` — the one client use of a field
  that otherwise only matters to providers.
- **Rejected: routing a known skill name straight to `session/prompt`.** It
  would save one declined `commands.execute` round trip, but only while the
  command catalog is cached, and it would make dispatch depend on a possibly
  stale local catalog. The host stays the admission authority.

## Consequence

- New module `dsh-emacs-skill.el`; new protocol views `dsh-protocol-skill`
  (name, description, when-to-use, model-invocable, path) and
  `dsh-protocol-skill-list` (`skills`); the overview comment in
  `dsh-emacs-protocol.el` and the module map in `docs/architecture.md` list it.
- New user surface: the `M-x dsh-emacs-command` slash menu now lists commands
  and skills together (a skill pick inserts `/name `; `C-u` opens the picked
  skill's file, while commands ignore the prefix), `M-x
  dsh-emacs-skill-catalog-refresh`, the options `dsh-emacs-skill-prefetch` /
  `dsh-emacs-skill-prefetch-delay`, and skill rows (with a `user-only` marker)
  in the `/` completion and the menu.
- `dsh-emacs-command` dispatches on the picked item's type and gained
  `dsh-emacs-command--run` / `--insert-gesture`; the completion and the menu
  share `dsh-emacs-skill-label`, so the user-only wording exists once. A
  gesture inserted mid-text gets a leading space, because the host's grammar
  only accepts `(^|\s)` before the slash.
- `dsh-emacs-command-catalog-fetch` gained the supersede guard too (a
  pre-existing race, fixed alongside under the same "one menu, one list"
  concern); `CHANGELOG.md` carries it as its own Fixed entry so it can be
  split into a separate commit.
- `dsh-emacs-command-completion-at-point` now fetches and merges both catalogs;
  its annotation function describes skills too. `docs/skills.md` documents the
  gesture, and `docs/slash-commands.md`/`README.md` cross-reference it.

## Known limitations

- A skill gesture still costs one declined `commands.execute` round trip before
  the prompt fallback, and briefly renders the optimistic command row (cleaned
  up in the same event-loop turn).
- `whenToUse` is decoded but not displayed; the menus show `description` only,
  as dsh web's slash menu does.
- No skill-body preview in Emacs beyond opening the `SKILL.md` file; providers
  that ship no `path` cannot be read at all.
- The catalog is not invalidated on an agent-preset change by itself; the user
  re-reads it with `M-x dsh-emacs-skill-catalog-refresh`.
