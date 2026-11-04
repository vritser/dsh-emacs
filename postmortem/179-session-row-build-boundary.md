# 179 — Separate session row construction from installation

## Background

At baseline `6d50a2a`, `dsh-emacs-session--render` mixed temporary-buffer row
construction with target-buffer installation. It prepared jumps, copied the
target's fold/expansion/jump state into a temporary buffer, built the rows and
a fresh row cache, then installed the text, replayed properties, published the
cache, and finally restored focus and window positions. The row cache was a
local captured around the whole sequence.

[082](082-session-list-focus.md) defines the focus and window restoration
policy. The temporary-buffer construction uses the target's visual state; the
installation step must keep markers and reuse unchanged row text.

## Decision

Extract `dsh-emacs-session--build-rows` for the temporary list and fresh visual
cache. It accepts the target buffer, already-prepared groups and the empty-list
flag, copies the target's visual state, and returns via the temporary buffer's
contents and cache.

Keep `dsh-emacs-session--update-rows` as the installation owner, extending it
to replay source properties and publish the source cache only after property
installation succeeds. `dsh-emacs-session--render` retains jump preparation,
focus/window restoration and highlighting. No module, buffer mirror, state
struct or public API is added. Implementation: the staged session batch based
on `6d50a2a`.

## Why

Building rows needs the target's current folds, expansions, filter and pending
jump, but it does not change the target buffer. Installation needs the target
and the completed source. Splitting at that boundary makes the temporary build
callable and lets the tests exercise property replay and cache publication
without arranging a full render, while keeping marker movement and focus order
in one coordinator.

Publishing the cache from `--update-rows` keeps it atomic with the property
installation: a failed property replay leaves the previous cache published and
the next render retries the update. Moving cache publication into the builder
would publish it before the target text accepted the source. Moving the whole
sequence into a new module would separate the cache from the render lifecycle
it protects.

## Consequence

The render sequence is unchanged: prepare jumps, build, install text/move rows,
replay properties, publish cache, restore focus and windows. The old cache is
retained when property installation fails. Architecture documentation records
the build/install/coordinate boundary. No user-visible change requires a
changelog entry.

The session subsystem passes its focused tests, including a direct
property-replay/cache-publication failure test; the full `scripts/verify.sh`
gate passes.

## Known limitations

`dsh-emacs-session--build-rows` trusts its caller to prepare jumps and pass the
group list. `dsh-emacs-session--update-rows` trusts the source cache to describe
the text being installed. The functions do not own focus, window positions,
highlighting, row visibility policy or the caller's error recovery. A direct
`--update-rows` call now also republishes the cache, which is the explicit
installation contract used by the renderer and the tests.
