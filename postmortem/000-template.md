# NNN — One-Line Slug

_Optional status line: `Status: Complete` / `Superseded by NNK` (see rules
below).  One page, prose, citations to commits/files as evidence.  English or
Chinese — match the surrounding record._

## Background

What existed before and the problem it created.  Name the failing layer
(transport / protocol / events / render / modeline / UI) when one owns it.
Cite the relevant commits (7-hex sha) so the record stays verifiable.

## Decision

What was chosen, in one clear sentence, then the mechanics: which module owns
the behavior, which public surface changes, which old surface is removed.

## Why

The reasoning — never restate the code.  Why this approach over the
alternatives considered, what concrete problem it solves now, and any
tradeoff explicitly accepted.  Rejected alternatives belong here, each with
one line on why not.

## Consequence

What changed for users and developers: new/changed/removed commands, options,
faces, behavior, docs touched.  What must be kept in mind by later changes.

## Known limitations

Deliberately deferred or accepted limits.  A later entry that lifts one
starts with "Superseded by NNK" at the top of this file — do not rewrite the
body of an old record to match current behavior.

---

_Writing rules (also in AGENTS.md, §Postmortems):_

- Write one when: adding or changing a user-visible workflow; choosing
  between non-obvious architectural approaches; abandoning or reverting an
  approach; removing a public option or command; deliberately deferring a
  known limitation.  Bug-fix-only changes do not need one.
- Read the relevant records before significant changes — they are constraints
  and rationale, not proof the code still matches them.
- User-visible changes link back from `CHANGELOG.md` as
  `(rationale: postmortem/NNN)`; the postmortem cites commits as evidence.