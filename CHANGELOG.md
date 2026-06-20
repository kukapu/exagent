# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — first stable release

The complete, layered agent framework for Elixir. Inspired by pydanticAI's
ergonomics, built on BEAM-native supervision, message passing and durability.

### Layer 0 — one-shot agent loop (`ExAgent.run/3`)

- Model ⇄ tools recursive loop with parallel tool execution, per-tool retry
  budgets, structured-output retry, `max_steps`, and telemetry.
- **Structured output** via any Ecto `embedded_schema`: JSON Schema is derived
  from the schema AND its changeset validations (`validate_inclusion` → `enum`,
  `validate_number` → `minimum`/`maximum`, `validate_length` → `minLength`/
  `maxLength`), so the model can actually comply.
- **`deftool`** macro derives tool JSON Schemas from `::` type annotations.
- **Streaming** via `run_stream/3` (lazy deltas + final result).
- Provider-agnostic: OpenAI, OpenRouter, Anthropic, Z.AI (Anthropic-compatible),
  plus a deterministic `Test` model for offline development.
- Provider parsers are **crash-safe** against malformed real-world responses
  (empty/absent `choices`, `content: null`, `tool_calls: null`, partial `usage`).
- A tool task that raises is **contained** → `{:error, _}`, never a linked EXIT
  that kills the agent process.
- DB-free core: serialize/resume a conversation via `Message.to_json/from_json`.

### Layer 1 — stateful runtime (`ExAgent.Server`)

- A supervised, long-lived agent preserving history, accumulating usage,
  threading stateful models across runs, emitting events.
- Sync `chat/3`, async `send_message/3`, text `stream/3`, `steer/2` (front-of-
  queue), `abort/1`, `set_model/2`, `reset/1`, `history/1`, `usage/1`, `health/1`.
- Runs execute under `ExAgent.TaskSupervisor`, so the server stays responsive to
  `abort/1`/`health/1` and applies backpressure (`:busy` / `:queue_full`).
- Streaming handlers guard on `run_id`: a stale delta from an aborted run can't
  corrupt the next run's history. `abort/1` is race-safe vs natural completion.

### Layer 2 — persistence (`ExAgent.Store` + `Server.Snapshot`)

- Behaviour + `ETS` (in-process) + `Postgres` (durable, optional deps) impls.
- Strictly JSON-serializable snapshots (never pids, secrets or tool closures);
  the live model/tools come from an app-supplied template on restart.
- Checkpoint after every run, rehydrate on restart — survives supervised crashes.
- Cross-store portable: a snapshot round-trips ETS ↔ Postgres unchanged.
- Checkpoint/rehydrate failures are **logged** (never silently swallowed).

### Layer 3 — multi-agent sessions (`ExAgent.Session`)

- Coordinated multi-participant turns over app-defined `shared_state`, with the
  Session as the **single writer**.
- `TurnPolicy` behaviour + `RoundRobin`, `Initiative` (custom order),
  `SupervisorPolicy` (a coordinator alternates with workers).
- `SharedState` handle in `RunContext.deps` so tools read/propose state safely.
- Lifecycle: `start/join/leave/take_turn/update_state/end_turn/pause/resume/close`.
- **Leaving mid-turn never deadlocks**: the next participant is advanced (all
  three policies); an empty roster transitions to `:done`.

### Coordination (`ExAgent.Coordination`)

- `delegation_tool/2` — agent-as-tool with **shared usage** up the tree.
- `handoff/2` — direct control transfer bypassing the turn policy.

### Robustness & safety

- `Compaction` behaviour + `Summary` impl + `Capability` hook: shrink long
  histories (LLM-driven summary + recent window) before they exceed the context
  window, keeping `new_messages` accurate.
- `UsageLimits` + `CostGuard`: request/token/tool-calls/budget caps.
- Anthropic prompt caching (`cache: true`).
- `Permissions`: per-tool `allow`/`ask`/`deny` globs, fail-closed, wired into
  the loop via `:permissions` + `:approve`.

### External tools (MCP)

- `ExAgent.MCP.Client` (stdio JSON-RPC) consumes any
  [Model Context Protocol](https://modelcontextprotocol.io) server's tools and
  exposes them as `ExAgent.Tool`s. Handshake is resilient to frames split across
  data chunks; transport exits and errors surface cleanly.

### Events & PubSub

- Versioned `ExAgent.Event` envelopes (distinct from `:telemetry`).
- `ExAgent.PubSub` behaviour: `None` (default), `Local` (Registry), `Phoenix`
  (dynamic, no hard dependency). A backend returning `{:error, _}` degrades
  gracefully (logs, never crashes the stateful owner).

### Packaging

- `config/` is excluded from the published package; `ecto_sql` + `postgrex` are
  optional (test-only) deps — exAgent stays DB-free unless you opt into the
  Postgres store.
