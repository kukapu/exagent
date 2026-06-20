# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.2] — Deep bug-hunt fixes

A parallel three-agent bug-hunting pass (core loop, runtime layer, coverage)
surfaced a batch of real correctness and robustness bugs. All confirmed bugs
have regression tests in `test/exagent/scenarios/`.

### Crashes → clean `{:error, _}` (provider & loop)

- **Providers no longer crash on malformed responses.** OpenAI/OpenRouter
  parsing handles empty/absent `choices`, `tool_calls: null`, malformed
  `tool_call` entries, and partial `usage` (was `FunctionClauseError` /
  `Protocol.UndefinedError`). Anthropic/Z.AI parsing handles `content: null` /
  missing `content` (was `Protocol.UndefinedError`). Providers occasionally
  return 200s with these shapes (content filters, overload, safety routing).
- **A raising tool task no longer kills the agent process.** Tool execution
  wraps each task so a raise (malformed `args`, a buggy capability hook) becomes
  `{:error, _}` instead of a linked EXIT that violated `run/3`'s contract. The
  `{:exit, _}` clause is now reachable for real.
- **`Part.ToolCall.args_as_map/1`** has a catch-all for non-conforming args
  types (was `FunctionClauseError`).
- **`OutputSchema`** wraps the user's `changeset/2` in a rescue; a changeset
  that raises on its input now surfaces as a retryable validation error instead
  of crashing the run.

### Correctness

- **Multiple output (`final_result`) tool calls in one response** no longer
  leave the history un-replayable: every call gets a `ToolReturn` (was 1:N,
  which OpenAI/Anthropic reject on the next request).
- **The current participant leaving a Session mid-turn** no longer deadlocks it.
  All three turn policies (RoundRobin, Initiative, SupervisorPolicy) now
  re-advance to the next participant; an empty roster transitions to `:done`.
  Index/worker-index realignment prevents skipping the next participant after a
  leave. SupervisorPolicy clears a departed supervisor instead of re-emitting a
  ghost id.
- **`ExAgent.Server` streaming handlers** now guard on the current `run_id`, so
  a stale `:stream_done`/`:stream_delta` from an aborted run can't corrupt the
  next run's history or emit a bogus `:run_finished`.
- **`abort/1`** no longer crashes when the task already exited naturally
  (`terminate_child` returns `{:error, :not_found}` in the abort-vs-completion
  race; was a hard `:ok =` match).
- **A pubsub backend returning `{:error, _}`** (Phoenix not loaded, registry
  outage) no longer crashes the Server/Session — it logs and continues.

### Robustness / observability

- **Checkpoint & rehydrate failures are now logged** (were silently swallowed),
  so non-encodable metadata or a broken store doesn't invisibly disable all
  persistence until a restart loses the conversation.
- **`:max_steps` is now configurable** via `ExAgent.new(max_steps: n)` (was
  hardcoded to 50 and silently ignored).
- **`Server.stream/3`** forwards `:deps`/`:model_settings` like `chat/3`/
  `send_message/3` (were silently dropped).

### Minor

- `format_retry/1` (OpenAI + Anthropic) has a catch-all for non-binary/list
  content. Anthropic `tool_call` for binary input no longer double-decodes JSON.

276 offline tests (+22 `:integration`, +6 `:mcp_e2e`).

## [0.5.1] — Scenario hardening + bug fixes

A full **integration scenario suite** (`test/exagent/scenarios/`) that composes
every layer of the framework into real-world stories, plus the bugs it surfaced.

### Bug fixes (found by the scenario suite)

- **`ExAgent.OutputSchema.json_schema/1`** now reflects changeset-level
  constraints in the JSON Schema sent to the model: `validate_inclusion` →
  `enum`, `validate_number` → `minimum`/`maximum`/`exclusiveMinimum`/
  `exclusiveMaximum`, `validate_length` → `minLength`/`maxLength`,
  `validate_exclusion` → `not.enum`. Previously a `validate_inclusion(:category,
  [...])` was invisible to the model, so every structured-output call needed
  wasteful retries (or failed outright). This is the change that makes
  structured output reliable against real LLMs.
- **`ExAgent.Compaction.Capability`** now compacts only the *prior* history
  (before this run's additions) and keeps `first_new_message_index` consistent,
  so `result.new_messages` is still accurate after compaction fires. Previously
  compaction rewrote the whole `state.messages`, leaving the index stale and
  `new_messages` empty.
- **`ExAgent.AgentSupervisor`** raised its `max_restarts` to 100/5s. The
  default `3/5s` was far too tight for a host running many agents (or a test
  suite crashing several): a small burst of unrelated agent crashes terminated
  the whole `DynamicSupervisor`, its parent restarted it empty, and **every**
  agent vanished. Each agent is independent — one crash must never cascade.

### Scenario suite (`test/exagent/scenarios/`)

Seven end-to-end scenarios that compose the layers (previously only covered in
isolation): a support-ticket classifier (tools + structured output + cost guard
+ capabilities + permissions), a stateful-agent lifecycle (Server + events +
stream + queue ordering + telemetry), a multi-agent triage (Session + three
policies + SharedState + delegation + handoff), long-context compaction (incl.
LLM-driven summary + a custom compactor), external tools + admission control
(MCP tools running inside the loop + permissions gating them), crash recovery
(cross-store ETS↔Postgres portability, reset-then-crash, mid-run crash), and a
real-provider matrix over **nine models via OpenRouter** (DeepSeek, MiniMax,
Xiaomi, Anthropic, Google, OpenAI, Z.AI, Moonshot, Qwen) validating wire-format
parsing, tool round-trips, streaming and structured output.

251 offline tests (+22 opt-in `:integration` against real APIs, +6 `:mcp_e2e`).

## [0.5.0] — MCP client

- `ExAgent.MCP.Client` — a Model Context Protocol client over the stdio
  transport. Spawns an MCP server, performs the `initialize` handshake, lists
  its tools, and exposes each as an `ExAgent.Tool` whose execution forwards a
  `tools/call` to the server. JSON-RPC correlation + line buffering over the
  Port; failures (server exit, errors) surface cleanly.
- `ExAgent.MCP.Protocol` — pure JSON-RPC 2.0 encode/decode + MCP→ExAgent tool
  mapping (the testable core, separated from the transport).
- Tested with a deterministic in-process mock transport (handshake, tools,
  call, line buffering, error responses, transport exit) **and** a real
  end-to-end spawn of a python MCP server over a Port. 213 tests (was 198).

## [0.4.0] — Durable Postgres store

- `ExAgent.Store.Postgres` — a durable `ExAgent.Store` over a host-supplied
  `Ecto.Repo` (exAgent never owns the DB). `ecto_sql` + `postgrex` are
  **optional** deps; the rest of exAgent stays DB-free. Snapshots are stored as
  strict JSON (never raw terms), with an idempotent `migrate/1`. Enables resume
  across crashes and nodes.
- `examples/dnd_session.exs` — a mini D&D round (DM + bot + human over a shared
  world, coordinated by a Session with SupervisorPolicy), run offline. Proves the
  full multi-agent stack for the D&D use case.
- 198 tests (was 194); the `:postgres` tag auto-skips when no DB is reachable.

## [0.3.0] — Coordination, robustness & permissions

Multi-agent orchestration, long-session safety nets, and per-tool admission
control — all opt-in, all offline-tested. 194 tests (was 162).

### Coordination (pydanticAI levels 2 & 3)

- `ExAgent.Coordination.delegation_tool/2` — build a tool that runs another
  agent as a sub-task (agent-as-tool). The delegate's token usage is **merged
  into the parent run's usage**, so limits/cost cover the whole delegation tree.
  Accepts a static `ExAgent.t()` or a `(ctx, args -> ExAgent.t())` builder.
- `ExAgent.Coordination.handoff/2` — transfer control between participants in a
  Session directly (BEAM-native programmatic hand-off), bypassing the turn policy.
- `ExAgent.Session.TurnPolicy.SupervisorPolicy` — a coordinator participant
  alternates with each worker (`supervisor, w0, supervisor, w1, …`); registered
  as `:supervisor` / `{:supervisor, supervisor: ..., workers: [...]}`.

### Robustness / cost

- `ExAgent.Compaction` (behaviour) + `Summary` impl + `Capability` hook —
  shrink a long history to a summary + recent window on `before_model_request`,
  so a session stays within a model's context window.
- `ExAgent.UsageLimits` — new `tool_calls_limit` (a batch that would exceed it
  runs nothing) and `max_budget_cents` (halts via an `:estimate_cost` function).
  New `check_tool_calls/3`; cost checked in `check_before_request`.
- `ExAgent.CostGuard.estimator/1` — turn a pricing map into the
  `(usage -> cents)` function for `max_budget_cents`. No pricing table baked in.
- Anthropic **prompt caching**: `cache: true` on `ExAgent.Models.Anthropic`
  adds `cache_control` breakpoints to the last system block and last tool.

### Permissions

- `ExAgent.Permissions` — per-tool `:allow` / `:ask` / `:deny` with glob rules
  (last-match wins, fail-closed `:ask`). Wired into `run/3` via `:permissions`
  and `:approve`; a denied tool returns a "not permitted" message to the model.

### Core (general, backwards compatible)

- Tools may now contribute token usage by returning
  `{:ok, value, %ExAgent.Message.Usage{}}`; the loop merges it.
- `ExAgent.PubSub.Phoenix` validated end-to-end against a real LiveView PubSub.

## [0.2.0] — Stateful runtime, sessions & persistence

The first release with the full **layered runtime** on top of the existing
one-shot core. Nothing one-shot broke — the new layers are opt-in. See
`DESIGN.md` for the architecture and `ROADMAP.md` for the phased plan.

### Layer 1 — Stateful agent (`ExAgent.Server`)

- `ExAgent.Server` — a supervised, long-lived agent that preserves conversation
  history, accumulates usage, threads stateful models across runs, and emits
  events. API: `chat/3`, `send_message/3` (async → event), `stream/3`,
  `steer/2`, `abort/1`, `set_model/2`, `history/1`, `usage/1`, `health/1`.
- `ExAgent.AgentSupervisor` — `DynamicSupervisor` to start/stop agents by id.
- Runs execute under `ExAgent.TaskSupervisor`, so a Server keeps answering
  `abort/1`, `health/1` and backpressure (`:busy` / `:queue_full`) during long
  runs.
- `reset/1` — clear the conversation history and accumulated usage (e.g. a chat
  UI's "clear" button); only when idle.

### Layer 2 — Persistence (`ExAgent.Store`)

- `ExAgent.Store` behaviour + `ExAgent.Store.ETS` (dev/test default).
- `ExAgent.Server.Snapshot` — a **strictly JSON-serializable** checkpoint
  (history + usage + metadata). By construction it never carries pids, secrets
  or tool closures; the live model/tools come from an app-supplied template on
  restart.
- `ExAgent.Server` checkpoints after every run and rehydrates history/usage on
  restart (`store: :ets`). Survives supervised-agent crashes.

### Layer 3 — Session & coordination (`ExAgent.Session`)

- `ExAgent.Session` — a coordinated, multi-participant interaction with shared
  state and turn-taking. Lifecycle `start/join/leave/take_turn/pause/resume/close`.
  The Session is the **single writer** of `shared_state`.
- `ExAgent.Session.TurnPolicy` behaviour + `RoundRobin` / `Initiative` impls
  (dispatch by struct, like `ExAgent.Model`).
- `ExAgent.Session.Participant` and `ExAgent.Session.SharedState` (a handle for
  `RunContext.deps` so tools read/propose through the Session).

### Cross-cutting

- `ExAgent.Event` — versioned, serializable event envelope (the UI/runtime
  contract; distinct from `:telemetry`).
- `ExAgent.PubSub` behaviour + `None` / `Local` (Registry) / `Phoenix` (dynamic,
  no hard dependency) impls. Agents publish on `"exagent:agent:<id>"`, sessions
  on `"exagent:session:<id>"`.

### Core additions (backward compatible)

- `ExAgent.run/3` accepts `:on_event` (loop event sink, no-op by default),
  `:prepend_instructions`, and `:run_id`. The result map now also exposes
  `:model` (the possibly-updated model, so stateful models thread across runs).

### Docs & examples

- `DESIGN.md`, `ROADMAP.md`. New examples: `examples/stateful_agent.exs`,
  `examples/multi_agent_session.exs`. ex_doc module groups by layer.
- 159 tests (was 96), stable across repeated runs.

## [0.1.1]

- Fix structured-output JSON Schema generation for `embeds_many` / `embeds_one`.

## [0.1.0]

- Initial release: agent loop, providers (OpenAI / Anthropic / Z.AI / OpenRouter
  / Test), `deftool`-derived tool schemas, Ecto structured output with retry,
  streaming, capabilities, `UsageLimits`, telemetry, message-history
  serialization.
