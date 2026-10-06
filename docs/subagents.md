# Subagent Integration

**Status: implemented, uncommitted.** Expand children in the session list or
select them through the minibuffer, then open their ordinary chat buffers
with a direct-parent address. Xref owns
return history. There is no dedicated tree buffer, browser keymap or timer.

The protocol prerequisite was verified against installed dsh 0.2.0-rc.2:
`session/projections` accepts running and settled child ids without activating
an Agent. The original real-server E2E passed history paging, continuation,
stop and reconnect recovery. The minibuffer real-Emacs E2E passed **33 checks**. It drives the real minibuffer
and checks return to the originating chat position and other-window selection.

Decision records: [075](../postmortem/075-subagent-conversations.md) for protocol
and capability boundaries; [076](../postmortem/076-subagent-minibuffer.md) for
the minibuffer workflow; [077](../postmortem/077-session-list-subagents.md)
for inline session-list expansion and
[078](../postmortem/078-session-list-row-updates.md) for bounded row updates.

## User workflow

In the session list, `TAB` expands or collapses a session's direct children.
Only known nonempty catalogs show an expansion arrow; unknown and empty
catalogs have none. `TAB` can explicitly load an unknown catalog.
Child rows are indented and show mode and activity; `TAB` on a child expands
another level, and `RET` opens through that child's exact direct parent.
`TAB` on workspace headers retains its existing workspace-folding behavior.
Opening the list from a child reveals its ancestors and focuses its row.
Refreshing preserves child expansion and each window's selected row.

Missing catalogs load only when expanded or needed to reveal the current child.
Loading, empty catalogs and errors have distinct rows. Collapse and expand to
retry a failed read. Cold children remain navigable without a session summary;
rename, archive and fork are refused locally. `i` shows child details.

From a chat, run `M-x dsh-emacs-list-subagents` or click the mode-line child
count. Standard `completing-read` lists the conversation's **direct children**:

```text
Subagent: explore-cache [child-id]    continuable  running  192.0s  12400 total tok (incl. cache)
          review-diff [child-id]     one-shot  completed  8.1s
```

Use the user's configured completion frontend and its ordinary navigation,
filtering and completion keys. `RET` enters the selected chat; `C-g` cancels
without navigation or an xref entry. Full ids disambiguate duplicate labels.
`C-u M-x dsh-emacs-list-subagents` opens the chosen child in another window,
honoring Emacs display rules. No extra chat prefix or minibuffer action map
is installed.

Run the command again **inside a child** to select its children. This avoids
fetching an entire descendant tree and keeps the direct parent unambiguous.
`M-,` returns to the actual originating buffer and position. The separate
`dsh-emacs-subagent-open-parent` command opens the direct parent; it is not a
replacement for navigation history.

`dsh-emacs-subagent-stop` uses the same picker and a standard confirmation to
stop a known running continuable child. Inside its chat, `C-c C-b` uses the
existing interrupt gesture. `dsh-emacs-subagent-describe` chooses a child and
opens standard help with its identity and token breakdown. These are named
commands, not additional minibuffer key bindings.

`dsh-emacs-subagent-refresh` refreshes the current conversation's cold
projections and parent availability. A missing root catalog is fetched when
opening the picker; failures are reported distinctly from an empty catalog.
Known catalogs are reused. Missing child metrics are fetched asynchronously;
annotations use the available state when the completion frontend renders them.
There is no periodic redraw or polling.

## Mode line and child input

The child count uses a 1px SVG with a brain above three downward branches in
the existing muted `dsh-emacs-modeline-face`, with the total alone beside it.
Without SVG support, it falls back to `nerd-icons`' `nf-md-source_branch`,
then `Sub`. `Sub3` means
three direct children; the running count is in the tooltip and activity is
shown in completion annotations. `S` stays reserved for steering messages.
Empty catalogs have no count
indicator. A child chat also displays its direct parent, label and mode.

Continuable children accept text through `C-c C-c`, with existing queue/steer
semantics (`C-u C-c C-c` steers). Input requires explicit current-generation
availability of the **direct parent's Agent**. One-shot, unknown-mode and
unavailable-parent conversations are read-only. Disconnect closes input;
reconnect invalidates old availability and refreshes summaries before reopening
eligible composers. Stop does not depend on the parent being available.

The entry point owns a buffer-local address and read-only presentation flag.
Opening a child and reconstructing the input region reapply `buffer-read-only`;
when input becomes eligible, ordinary transcript text properties continue to
protect history. Composer renders the reason. **Read-only is presentation;
command/submission guards are the enforcement boundary.**

## Protocol contracts

- Child follow and history paging both use
  `{kind:'subagent', parentSessionId, childSessionId, mode}`. For a grandchild,
  `parentSessionId` is the child immediately above it, never the root.
- The durable catalog can carry mode `unknown`; the child's own identity
  projection upgrades it. Reading history must not activate the Agent.
- `subagents/prompt` sends `{request:{requestId,parentSessionId,childSessionId,
  mode:'continuable',delivery:'queue'|'steer',content,clientTimeZone}}`.
  Acceptance is distinct from execution. Existing optimistic queue feedback
  and failed-submit draft restoration are reused.
- `subagents/interruptByParent` sends
  `{childSessionId,parentSessionId,mode:'continuable'}`. Missing, idle or already
  finished targets are accepted. Receipt means "stop requested"; only actual
  settlement clears the child's busy state.
- There is no client-side spawn endpoint or command. The parent model creates
  children. `subagents/list` is not required by this projection model.
- `session/projections {sessionId}` is a cold, non-activating read, including
  children. [rpc.md](rpc.md) states the verified exception to the ordinary
  session mutation restrictions. A future host rejecting child reads requires
  revisiting this model rather than silently dropping metrics.

## State and ownership

`dsh-emacs-subagent.el` owns an equal hash keyed by session id. Each value is a
plain plist:

```elisp
;; :cells    alist: projection key -> dsh-protocol-subagent-cell
;;           subagentCatalog / subagent / subagentTiming / tokenUsage
;; :state    nil / ready / loading / error
;; :request  generation-scoped cold-read token, nil after completion
;; :error    remote error body
;; :summary-revision  counter protecting newer live summaries
;; :availability-revision  counter for full summaries and removals only
```

Cells retain `seq`, presence and the decoded payload independently. Control
baselines and follow snapshots use `asOfSeq` as a cut for all four keys,
including absent values. Deltas advance only their own key. A strictly newer
watermark wins; an older cold result cannot erase newer activity-independent
usage or identity. Cells survive without an open chat buffer and across
reconnects.

Cold refresh requests are deduplicated by their request token. A live catalog
update cannot prematurely clear the in-flight state. Asynchronous callbacks
belong to a host-owned hidden buffer, so closing the originating chat cannot
strand loading state. Generation changes invalidate stale responses. The
picker's initial synchronous read also checks the generation before applying
its response; cancellation cannot later open a minibuffer from a callback.

The session cache supplies live activity and availability separately:

- `agent-available` is `t`, `:unavailable`, or `nil` (unknown). Missing fields,
  placeholders and old-generation rows must not be mistaken for explicit
  unavailability.
- `api-session/added` upserts running, blank, availability and updated-at.
  Existing context pressure, model selection and title projections remain
  intact: summary projection hints do not replace authoritative cells.
- `api-session/status` updates running; `api-session/removed` removes the row.
  A retained child with no summary has unknown activity, while durable
  completion remains independently known from its timing cell.
- Reconnect fetches summaries with the required `session/list` argument shape.
  Running and availability merge against independent revision cuts. A later
  status frame protects running without discarding the refresh's availability;
  a full summary or removal protects both fields from stale responses.

| Owner | Responsibility |
|---|---|
| `dsh-emacs-protocol.el` | Wire constructors, direct-parent addresses, cell/baseline decoding, tri-state availability and cross-module structs |
| `dsh-emacs-subagent.el` | Sequenced store, cold reads, availability gates, completion candidates/annotations, parent/child navigation and count indicator |
| `dsh-emacs-session.el` | Inline child rows, buffer-local expansion, direct-parent row actions and current-child reveal |
| `dsh-emacs-tokens.el` | Arithmetic over decoded cumulative token usage |
| `dsh-emacs-events.el` | Control/follow projection dispatch, summary upserts and reconnect generation lifecycle |
| `dsh-emacs.el` | Addressed open/page/prompt/stop, input read-only presentation and command boundaries |
| `dsh-emacs-composer.el` | Input-unavailable notice |
| `dsh-emacs-modeline.el` | Indicator placement in native and Doom mode lines |

The existing session list owns its child expansion and row identities; there
is no separate tree mode or display timer. Xref's public marker stack is sufficient; a full
`M-.` backend is not installed. On Emacs 27.1 the default return command is
`xref-pop-marker-stack`; newer Emacs versions may use `xref-go-back`. Existing
user bindings are left intact.

## Metrics

`tokenUsage` is a **cumulative session projection**. Its wire input key is
`uncachedInputTokens`, not `inputTokens`. Protocol decodes uncached input,
output, cache read and cache write; tokens owns their total. Completion
annotations label it `total tok (incl. cache)`, and the details command exposes
the four components. It is neither a billing estimate nor the chat mode line's
`assistant/message` accumulator; never add snapshots into that accumulator.

Duration adds `settledMs` to the active segment. Only a connected, running
child advances against local time; otherwise the segment stops at
`active.through`. Completion annotations update when rendered by the frontend,
not on a custom clock.

## Capability guards and limitations

All child buffers reject ordinary session mutations locally:

| Operation | Child behavior |
|---|---|
| Model/permission selection, rename, fork, archive/unarchive | Reject |
| Slash commands, skill gestures and shell dispatch | Reject |
| Goal mutation and plan decisions | Reject |
| `C-c C-p` late question answer | Reject; host requires the exact live root Agent |
| Attachments, clipboard image staging and attached submission | Reject; this client exposes text-only child follow-up |
| Queue edit/steer/delete/delete-all/send-now | Reject at the update boundary; queue viewer installs no chooser action map |
| History, copy and navigation | Available |
| Text queue/steer | Only continuable children with an explicitly available direct parent |
| Stop | Only continuable; no parent-availability requirement |

Running one-shot children cannot be interrupted by this client: the host
endpoint accepts literal mode `continuable`, and ordinary `session/cancel` is
not a valid fallback. The host can accept image content on child prompts, but
that integration remains deferred. Child sessions appear only beneath their
parents, never as duplicate top-level rows. The picker operates one level at a time, not as a global
recursive search over all descendants.

## Verification

Unit tests cover independent sequence cuts, cold-read deduplication/retry,
stale generation responses, summary merge semantics, availability transitions,
read-only presentation, command refusal, prompt/page addresses and metrics.
Picker tests cover duplicate labels, annotations, cold errors versus empty
catalogs, catalog reuse, cancellation and direct-parent/other-window selection.
Session-list tests cover nested expansion, cold loads and retry, direct-parent
opening, mutation guards, focus preservation and revealing the current child.

`test/dsh-e2e.el` with `DSH_E2E_SUBAGENTS=1` requires a working model provider
and graphical Emacs. It creates both child modes with real delegation, uses
the real minibuffer to select them, verifies xref return and other-window
navigation, pages history, sends follow-up, stops a continuable child, and
checks disconnect/reconnect input gates. Parent disposal/reactivation remains
a deterministic synthetic-summary test rather than a timing-dependent model
scenario. The E2E cleans up its temporary chat buffers and archives its parent.
