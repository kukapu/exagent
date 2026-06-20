# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] — Multi-agent coordination

Patterns on top of `ExAgent.Session` (pydanticAI complexity levels 2 & 3).

### Added

- `ExAgent.Coordination.delegation_tool/2` — build a tool that runs another
  agent as a sub-task (agent-as-tool). The delegate's token usage is **merged
  into the parent run's usage**, so limits/cost cover the whole delegation tree.
  Accepts a static `ExAgent.t()` or a `(ctx, args -> ExAgent.t())` builder.
- `ExAgent.Coordination.handoff/2` — transfer control between participants in a
  Session directly (BEAM-native programmatic hand-off), bypassing the turn policy.
- `ExAgent.Session.TurnPolicy.SupervisorPolicy` — a coordinator participant
  alternates with each worker (`supervisor, w0, supervisor, w1, …`); registered
  as `:supervisor` / `{:supervisor, supervisor: ..., workers: [...]}`.
- **Core (general)**: tools may now contribute token usage by returning
  `{:ok, value, %ExAgent.Message.Usage{}}`; the loop merges it. Powers
  delegation's shared usage and is useful for any tool that proxies an LLM call.

### Tests

- 172 (was 162): delegation with shared usage, builder delegate, handoff
  (transfer + reject unknown / when not running), SupervisorPolicy sequencing,
  supervisor-at-the-Session-level, tool-contributed usage.

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
