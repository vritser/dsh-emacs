# Model Picker

`C-c C-m` (`dsh-emacs-select-model`) reads `session.models` and calls
`session.selectModel`. Rows show the model **id** only (the provider name lives
inside the row key, so it stays searchable while filtering); duplicates of the
same id across providers keep their provider visible in the suffix.

- **Sticky provider groups**: the table carries a `group-function` in its
  completion metadata. Modern vertico (and Emacs 27+ `*Completions*` buffers)
  draw one sticky header per provider, recomputed on every filter input, so
  grouping is never lost while searching — no `vertico-group.el`/group-mode
  needed. In completion UIs without group support, provider headers are
  ordinary candidates and colliding ids fall back to a per-row provider suffix.
- **Header style**: inside the picker, `vertico-group-format` is overridden
  buffer-locally by `dsh-emacs-model-group-format` (defaults to just the
  provider name — vertico's stock long separator lines are dropped; other
  completions keep their global format unchanged).
- **Row icons**: the table metadata declares its own `category`
  (`dsh-model`), which keeps row prefixes clean against
  `nerd-icons-completion` by default. Once that package is loaded, the picker
  auto-registers a default chip icon (`nf-cod-chip`) for the category — zero
  configuration. To use a different icon, register the category yourself and
  your entry wins (the auto default is skipped):
  `(add-to-list 'nerd-icons-completion-category-icons '(dsh-model . (nerd-icons-faicon "nf-fa-robot" nerd-icons-blue)))`
- **Reasoning effort**: models that declare `reasoning` options (efforts +
  defaultEffort) get a second mini-prompt right after the model pick.
  Re-picking the current model pre-selects its live `reasoningEffort`; other
  models pre-select their `defaultEffort`. The chosen id is sent as
  `session.selectModel`'s `reasoningEffort`; models without `reasoning` send no
  effort field at all.
- **Behaviour**: empty RET keeps the current model (no RPC), unknown input is
  rejected, `C-g` cancels cleanly inside the RPC filter; when vertico is active
  the picker locally disables extra sorting and pre-selects the first row.