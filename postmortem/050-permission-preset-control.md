# 050 — Show and switch the session's permission preset

## Background

Sandbox mode and approval policy are the session's most consequential knobs:
they decide whether the agent may write outside the workspace or run
commands without asking.  No dsh-emacs surface read them.  The host already
exposed the fold, but through a projection this client never consumed: dsh
0.1.5's `permissions` cell carried `{ options, currentValue }`, and nothing
in `dsh-emacs-events.el` handled the key (`dsh-emacs-events--host-apply-projection`
dispatched only `contextPressure` / `title` / `goal`), so a user could only
inspect or change the mode from another client.

dsh 0.1.6 split the two halves apart (`0a15e36e7f`):

- the `permissions` session projection **narrowed** to `{ currentValue }`
  (a configured preset key, the live `auto`, or the derived `custom`);
- the selectable options moved to the process-level unary Remote
  `permissionPresets/catalog` → `{ options: [{ value, name, description? }] }`;
- the **write path stayed the `/permission` slash command** — the namespace
  deliberately has no write Remote, because switching is a recorded session
  command (`permission/preset` event) whose side effects (sandbox mode +
  approval policy setters, Auto admission) belong to the command layer.

The first cut rendered the preset key as a word (`workspace-write`).  That
made the mode line unusable: `danger-full-access` alone is 18 columns on a
line that already carries model, effort and agent preset, and a full-width
Emacs window clipped it.  The segment therefore had to be an **icon**.

## Decision

- **protocol** (`dsh-emacs-protocol.el`):
  `dsh-protocol-permission-catalog` + `dsh-protocol-permission-option` with
  the `--from-alist` constructors, so the option names live where every
  other wire field name lives.
- **events** (`dsh-emacs-events.el`): a `permissions` case in both projection
  paths (`dsh-emacs-events--host-apply-projection` for `session/control`
  frames and `dsh-emacs-events--apply-snapshot-projections` for the follow
  snapshot) plus `dsh-emacs--events-apply-permission-projection`, which
  writes the value into the session's chat buffer.
- **faces** (`dsh-emacs-faces.el`): `dsh-emacs-modeline-permission-face`
  (plain) and `dsh-emacs-modeline-permission-warn-face` (red, for
  `danger-full-access` and `custom`).
- **modeline** (`dsh-emacs-modeline.el`): a buffer-local
  `dsh-emacs--modeline-permission`, the `permission` segment, and
  `dsh-emacs-modeline-set-permission`; the segment joins the default
  `dsh-emacs-modeline-format-spec` between `preset` and `ctx`.  The icon is
  dsh web's shield design set, copied verbatim as `__C__`-templated SVG
  (`dsh-emacs--permission-icon-svgs`: check / pencil / exclamation) plus the
  matching Nerd Font Material Design Icons names
  (`dsh-emacs--permission-icon-names`: `nf-md-shield_check` / `_edit` /
  `_alert`).  `dsh-emacs-modeline-permission-style` (`icon` default, `text`)
  selects icon or text.
- **command** (`dsh-emacs.el`): `M-x dsh-emacs-set-permission` reads the
  catalog asynchronously (the `dsh-emacs-select-model` pattern), prompts via
  `dsh-emacs--set-permission-prompt`, and runs
  `dsh-emacs-command-execute` with `/permission <value>`.

## Why

- **Visibility first, at one cell**: the projection is pushed for free on
  chat open and on every change, and the shield costs a single column rather
  than a word.  A mode the user cannot see is a mode they will be surprised
  by, so the segment stays on by default — the icon is what makes that
  affordable.
- **The icon is the product's own icon set**: the three shields are dsh web's
  permission design set (design set 1556, `ui-permission-presets`), so an
  Emacs user and a web user read the same symbol.  The Nerd Font names mirror
  the same marks (check / pencil / exclamation).
- **No emoji**, deliberately: an emoji is double-width (it breaks mode-line
  layout) and carries its own colors (it ignores the segment's face), so the
  warning state could not be tinted.  SVG images and font glyphs are one cell
  and take the face color.
- **Precedence SVG → Nerd Font → text**: SVG is exact and needs no font;
  `nerd-icons` is the better terminal answer (real font metrics, no image
  scaling) and is already installed on this machine, but it stays optional
  (`require ... nil t`); text is the honest last resort, and it is the only
  path that can render a host-configured preset outside the design set.
- **The switch has to go through the command**, not a Remote we wish existed:
  `/permission` is the only write path, and using it means the client gets
  the same durable record, same validation (`unknown preset`), same knob
  setters, and same Auto admission check as dsh web — plus a visible
  `command/run` + `command/done` row in the transcript.
- **No optimistic local write**: the segment is driven by the recorded
  `permission/preset` event through the projection, exactly like the ctx% and
  goal cells.  A local guess would have to be reconciled against the
  projection that follows milliseconds later (and against the Auto case,
  where the admitted preset may differ from the requested one).
- **`custom` is display-only, `auto` is context-sensitive**: the catalog is
  the authority on what may be selected, so `custom` (not an option) is never
  offered, and `auto` is offered only while the host publishes it.
- **No keybinding**: the two neighbouring pickers are `C-c C-m` (model), but
  a permission switch can widen the sandbox — a deliberate `M-x` is the right
  friction, and the mode line already answers "what am I in".
- Rejected: a sync RPC in the interactive spec.  It would block during the
  round trip and diverge from `dsh-emacs-select-model`; the async read also
  keeps the `C-g` in the process filter handled in one place.
- Rejected: caching the catalog and refreshing on the
  `permission-presets/catalog-changed` emit.  One local round trip per
  explicit switch is cheaper than a cache with an invalidation edge (the
  emit itself stays an ignored `$events` frame).
- Rejected: the emoji shields (`🛡`/`🔒`).  See the emoji note above; the
  width/color argument is decisive for a mode-line glyph.
- Rejected: hiding the segment unless the session is unrestricted.  It would
  save the same column in the common case but lose `read-only` vs
  `workspace-write` and the `auto`/`custom` states entirely.

## Consequence

- New command `dsh-emacs-set-permission` (no default keybinding); new default
  mode-line segment `permission` (one cell); new option
  `dsh-emacs-modeline-permission-style` (`icon` / `text`); new faces
  `dsh-emacs-modeline-permission-face` /
  `dsh-emacs-modeline-permission-warn-face`; `docs/modeline.md` and
  `docs/customization.md` document all of it; CHANGELOG 0.5.0 `Added`.
- The mode line's default `dsh-emacs-modeline-format-spec` changed; users
  with a customized spec keep their own value.
- Tests in `test/dsh-test.el`: `permission-catalog-parses-options`,
  `permission-segment-renders-beside-preset`,
  `permission-segment-text-style-shows-preset-name`,
  `permission-segment-hidden-when-unset`,
  `permission-svg-covers-the-design-set`,
  `permission-svg-tints-and-leaves-no-placeholder`,
  `permission-svg-only-for-the-design-set`,
  `permission-nerd-icon-uses-the-matching-shield`,
  `permission-nerd-icon-none-for-unknown-values`,
  `permission-short-fallback-bounded`,
  `permission-face-warns-only-when-unrestricted`,
  `permission-display-text-style-faces-the-value`,
  `permission-display-icon-style-falls-back-to-warn-text`,
  `permission-projection-sets-segment`,
  `permission-projection-replaces-value`,
  `permission-projection-ignores-empty-and-unknown`,
  `permission-prompt-offers-catalog-options`,
  `permission-prompt-runs-permission-command`,
  `permission-set-fetches-catalog-and-switches` (the last one caught a real
  arity bug: the command was invoked without the `submittedAttachments`
  argument slot, which silently dropped the result callback).
- The icon path was acceptance-tested in a real GUI Emacs (SVG tinted
  `#c62828` for `danger-full-access`, `#555555` for the confined presets;
  `custom`/`auto` text; Nerd Font glyphs one cell wide inheriting the face).
  Batch runs cannot exercise it, so the unit tests pin the text fallback.
- Later changes must keep the projection as the only source of the displayed
  value; the catalog is options-only.

## Known limitations

- The icon shows one of three confinement levels; a host-configured preset
  outside the design set (or `auto`/`custom`) renders as short text instead,
  and the tooltip is the only place the exact name appears.
- `custom` cannot say which knob diverged, and `auto` looks like any confined
  preset in the segment.
- No per-session permission history or confirmation prompt: switching to an
  unrestricted preset is one `RET` in the picker, and the red shield is the
  only warning.
- The catalog is read on demand; a deployment that drops the permission
  service mid-session hides the segment only after the next snapshot (an
  absent key does not clear an already-set value).
