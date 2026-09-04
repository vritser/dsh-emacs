# 010 — @ File/Session References (the Web @ Directive)

## Background

The web client's `@` directive — type `@` in the composer, pick a file or a
dsh-session from one combined menu, and the host injects the referenced
session as frozen untrusted context on the next turn — had no Emacs client
equivalent.  The server side was already complete and composition-agnostic:
`dsh-session-reference` parses the canonical `@[label](dsh-session:…)`
mention at `agent/pre-step` for ANY client that sends it as plain prompt
text, and the typert Remotes (`fileReferences/list`,
`sessionReferenceResolver/candidates`) are plain HTTP POSTs on the same
`/api/<ns>/<method>` surface dsh-emacs already uses for `commands.*`.  The
work was purely the composer half: token grammar, candidate discovery,
menu integration, and mention insertion — exactly what
`dsh-client-ui-reference` does for the browser.

A naive port would have copied the web's per-keystroke live fetch verbatim:
that model cost the web 1139 ms of server-side log reads per keystroke on a
342-session store before its 2026-08-27 discovery fix, and an Emacs client
has the same server behind it (plus synchronous `url-retrieve` blocking if
completion queries the network inline).

## Decision

New self-contained module `dsh-emacs-reference.el` — the composer side
only, no cross-session read logic (which stays host-side).  The web
`grammar.ts` (`activeAtToken` / `formatFileMention`) is ported verbatim so
`@path` / `@"path with spaces` tokens, whitespace quoting, and
un-representable-path skipping behave identically; candidates normalize
through two new `dsh-protocol-*` structs in `dsh-emacs-protocol.el` (wire
names stay out of business code).  The candidate cache answers with the
**previous query's list while a refresh builds the new one**
(stale-while-revalidate), the same decision the web's discovery fix took:
the first trigger of a query fetches synchronously once (the slash
catalog's first-TAB pattern), every later keystroke re-fetches on an idle
debounce and installs only if the requested query is unchanged, and a
superseded fetch re-arms for the newer query — fast typing never blocks and
never dead-ends.  The popup itself reuses the client's existing
`completion-at-point` infrastructure (corfu trigger character `@`, TAB, and
a content-driven post-command fallback identical in shape to
`dsh-emacs--slash-auto-complete`), so no new completion UI was built.  A
completed session mention is excluded from active-token detection: the web
keeps it behind an atomic chip, and our raw-text equivalent must not let
typing after a pick re-open the menu or let M-x insert swallow the mention.

## Why

- **The grammar and the wire must match the web exactly**: the server parses
  mentions with its own canonical-URI grammar, and paths are inserted with
  `formatFileMention` semantics; any drift means a pick that works in the
  web breaks (or worse, corrupts) in Emacs.  Porting `grammar.ts` verbatim
  removes the guesswork.
- **Stale-while-revalidate over live per-keystroke fetch**: the web's own
  postmortem proves live fetch is the wrong cost model at typing speed; the
  stale cache is filterable by the completion UI as it stands, so typing
  never waits.
- **The explicit `dsh-emacs-reference-*` options mirror the slash
  auto-complete split** (`dsh-emacs-slash-auto-complete`): users who turned
  off one trigger can keep the other.
- Rejected: implementing discovery with ordinary filesystem tools
  (`bash`, `find`, `read`) — recursive ranked discovery is editor-latency
  work the host already does, and the session side would have duplicated
  log reads; reading session logs for titles — the server's projection
  cache exists precisely so UIs do not (the web's "a discovery label is a
  projection read, never a log read" rule).

## Consequence

Typing `@` in a chat buffer opens a files-first/sessions-second menu with
live host-filtered candidates at honest typing latency; picking a session
inserts the canonical mention, and the frozen-snapshot context is attached
server-side with zero client involvement.  The module is ~600 lines of
self-contained Elisp with unit coverage of grammar, normalization, the
fetch state machine, capf negotiation, and insertion.  Known limitation,
deliberately accepted: the transcript renders the mention as raw
`@[label](dsh-session:…)` text (custom chip rendering, which the web's
chat row does, is a separate surface decision); pasted mention text in a
message works because parsing is server-side.  `dsh-emacs-reference--combine`
caps rows at `-max-files` / `-max-sessions`, so very large workspaces show
the ranked head rather than the web's full index.

## Commits

(not yet committed — working tree)