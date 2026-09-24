# 063 — Clipboard image paste into the chat input

_Status: Complete._

Implementation: `feat: paste clipboard images into the chat input`
(`dsh-emacs.el`, `dsh-emacs-composer.el`, `dsh-emacs-faces.el`, tests in
`test/dsh-test.el`).

## Background

Attachments existed only as one-shot sends: `C-c C-a`
(`dsh-emacs-attach-file`) and `drag-n-drop` read a file and immediately called
`dsh-emacs--submit-prompt` with a caption derived from the file name.  There
was no way to paste a screenshot or a copied image into a message being
composed, which is the ordinary flow in dsh web and every chat client.

The clipboard is the hard part, and it is platform-specific.  Probed on this
project's macOS build (Emacs 31 NS, `gui-get-selection 'CLIPBOARD 'TARGETS`):
the pasteboard exposes **only `image/tiff`**; `image/png`, `image/jpeg`,
`image/gif` and `image/webp` all return empty strings even when the source
application put a PNG flavor on the pasteboard.  The dsh host accepts only the
`dsh-emacs-attach-media-types` MIME flavors (png/jpeg/webp/gif), so the raw
selection bytes could not be sent as-is.

## Decision

`C-c C-v` (`dsh-emacs-attach-clipboard-image`) stages the clipboard image in
the buffer-local `dsh-emacs--pending-attachments` list instead of sending it.
The Composer renders that list as a third read-only row (the SVG Repo
`file-send' icon, file names, clickable `✕`); `C-c C-c` consumes the staged set
and appends each image
to `session/prompt` as a `{type:'image'}` content part after the text part; an
empty caption falls back to the image name; `C-c C-d`
(`dsh-emacs-clear-attachments`) discards the staged set, and a failed submit
puts it back while nothing newer is staged.

Ownership stays with `dsh-emacs.el` (acquisition, staging, submit) and
`dsh-emacs-composer.el` (presentation), mirroring the queue: Composer reads the
pending list through `dsh-emacs-pending-attachments` and keeps no copy, and the
row's content signature carries only image names, never the bytes.  On Emacs
29+ a per-chat-buffer `yank-media-handler` for `image/.*` feeds the same state.
Acquisition tries each accepted MIME target directly first, validates it
against its magic number, and otherwise converts macOS TIFF bytes to PNG with
the system `sips` tool in a temporary directory.

`s-v` (`dsh-emacs-paste`) is bound in the chat mode map to
the same staging path, with a `yank` fallback when the clipboard holds no
image.  Stock Emacs maps `s-v` to `yank` globally; the mode-local override
is what makes the system paste gesture mean "paste the picture" in a chat.

The staged set is cleared BEFORE the submit call, not after: a failure
callback that a transport invokes synchronously (before the submit returns)
then sees an empty staging area and can restore the submit's own text and
images, and a synchronous throw restores the exact pre-submit draft from
`dsh-emacs-send-or-stop` before the error surfaces.  Clearing after the call
was tried and lost the whole draft in exactly that instant-callback case.

A prompt that carries attachments is never recorded for `M-p` recall, on
either path: the submit paths skip it (a text-only replay would drop the
images), and `dsh-emacs--seed-input-history` records only messages whose
content is entirely text.  Without the backfill rule the synthesized
image-name caption came back as a prompt on reopen, refresh or reconnect.

## Why

Staging rather than immediate send: the image accompanies a caption the user is
still typing, which is exactly what the one-shot `C-c C-a`/drop path cannot
express, and it matches dsh web's composer.  A dedicated `C-c C-v` command
rather than rebinding `C-y`: `yank` must keep its text semantics, and a browser
clipboard commonly carries a URL or other text flavor beside the image, so
sniffing inside `yank` would change ordinary pasting.  `yank-media` alone was
rejected as the only entry point because it is Emacs 29+ (the package supports
27.1) and on macOS it auto-selects the TIFF flavor, which is not a host type —
the handler needs the same conversion regardless.

`s-v` gets the image-preferred dispatch that `C-y` does not: it is the
system paste gesture, whose meaning with a picture on the clipboard is the
picture, and it is already the key the user reaches for.  `C-y` stays the
canonical Emacs yank, which is also the escape hatch when a clipboard carries
both flavors and the text is wanted.  The fallback is `yank` itself, so a
text-only clipboard behaves exactly as before.

`sips` over the alternatives: it ships with macOS (`osascript` PNG extraction
and the `pngpaste` utility both assume a PNG flavor is present, which the
probe showed is not guaranteed), needs no new dependency, and is invoked only
on the TIFF path.  Magic-number validation exists because a selection can
advertise a flavor and still return unrelated bytes; staging those would defer
the failure to the host instead of the paste.  Refusing unaccepted types in the
`yank-media` handler (rather than converting anything) keeps the
`dsh-emacs-attach-media-types` option as the single acceptance list.

## Consequence

New user surface: `C-c C-v`, `C-c C-d` and `s-v` (`dsh-emacs-paste`), the
Composer Attachments row, `dsh-emacs-pending-attachments`, and faces
`dsh-emacs-composer-attachment-face` / `-body-face`.  `dsh-emacs-send-or-stop`
now treats staged images like text for its empty/`!`-line decisions: an empty
input with images is not "empty", and a `!` line with images is caption text
that goes to the model, consistent with `dsh-emacs--submit-prompt`.  The
submit functions restore staged images on transport failure.  `C-c C-a` and
drag-and-drop keep their immediate-send behavior; only the new paste path
stages.  Docs updated: README, `docs/customization.md`, `docs/architecture.md`
(Composer section).

## Known limitations

- TIFF conversion depends on macOS `sips`; on other systems only the directly
  exposed MIME targets work (X11/pgtk publish them, terminal Emacs generally
  does not).
- The row lists file names, not thumbnails; the geometry contract keeps every
  Composer row on one visual line.
- Drag-and-drop and `C-c C-a` deliberately remain one-shot sends rather than
  joining the staged set.
- Staged images are buffer-local and not persisted: killing the buffer (or
  re-initializing the mode) discards them.
- The `s-v` binding only fires where a super modifier exists (macOS);
  elsewhere `M-x dsh-emacs-paste`, `C-c C-v` and `M-x yank-media` remain.
- `s-v` prefers the image when the clipboard carries both an image and
  text; there is no prompt to choose (use `C-y` for the text).
- The Attachments row icon is a third-party SVG Repo asset (`file-send`,
  www.svgrepo.com) embedded with attribution; confirm its license before
  redistributing the package.
