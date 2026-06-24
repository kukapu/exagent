# ExAgent

[![Hex Version](https://img.shields.io/hexpm/v/exagent.svg)](https://hex.pm/packages/exagent)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/exagent)
[![License](https://img.shields.io/hexpm/l/exagent.svg)](https://github.com/kukapu/exagent/blob/main/LICENSE)
[![CI](https://github.com/kukapu/exagent/actions/workflows/ci.yml/badge.svg)](https://github.com/kukapu/exagent/actions/workflows/ci.yml)

<!-- MDOC -->

**An agent framework for Elixir** — structured output, tool-calling, streaming,
stateful agents, multi-agent sessions and durable persistence, powered by the
BEAM.

ExAgent is **layered and opt-in**: use just the one-shot core, or stack on the
stateful runtime, persistence and coordination as you need them. It is built the
Elixir way — recursion, behaviours, Ecto changesets, cheap concurrency for tools,
supervision/durability, `:telemetry`, and events that plug straight into LiveView.

```
Layer 3  ExAgent.Session          coordinated multi-agent turns + shared state
Layer 2  ExAgent.Store            snapshots: resume after crash / restart
Layer 1  ExAgent.Server           a supervised, stateful, event-emitting agent
Layer 0  ExAgent.run/3            the one-shot model ⇄ tools loop
         ────────────────────────  events (ExAgent.Event) over ExAgent.PubSub
```

## Features

- **One-shot agentic loop** — a model ⇄ tools recursion built as idiomatic Elixir.
- **Type-derived tool schemas** — define tools as plain functions; JSON Schema is
  generated from `name :: Type` annotations and `@doc` strings (no hand-written schemas).
- **Structured output** — any Ecto `embedded_schema` becomes the output spec; JSON
  Schema is derived from the schema **and** its changeset validations, validated
  with retry-on-failure.
- **Streaming** — text deltas as a lazy stream for typewriter/chat UIs.
- **Supervised stateful agents** — keep history, accumulate usage, thread stateful
  models across runs, and emit versioned events over PubSub (LiveView-ready).
- **Durable snapshots & resume** — checkpoint after every run, rehydrate on restart;
  ETS by default, Postgres for multi-node durability (your DB, your repo).
- **Multi-agent sessions** — coordinated turns over shared state with pluggable
  turn policies (`round_robin`, `initiative`, or your own).
- **Orchestration** — delegation (agent-as-tool) and hand-off between participants.
- **Robustness & safety** — context compaction, usage/cost limits, and per-tool
  permissions (`allow` / `ask` / `deny`).
- **Model-agnostic** — OpenAI, OpenRouter, Anthropic and Z.AI built in; bring your
  own by implementing the `ExAgent.Model` behaviour.
- **External tools (MCP)** — consume any Model Context Protocol server's tools.
- **Observable** — `:telemetry` events plus app-level `ExAgent.Event` envelopes.
- **Offline-first testing** — a deterministic [`ExAgent.Models.Test`] model drives the
  full loop with no API key and no network.

## Requirements

- Elixir 1.17+
- Erlang/OTP 25+

## Installation

Add `:exagent` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [{:exagent, "~> 1.0"}]
end
```

The library starts its own supervised `ExAgent.Finch` HTTP pool, a `Registry`
(`ExAgent.PubSub.Local`), a `Task.Supervisor`, an `ExAgent.Store.ETS` table and
an `ExAgent.AgentSupervisor`, so it works out of the box. Tune the Finch pool
with:

```elixir
config :exagent, :finch_pools, %{:default => [size: 32]}
```

> `ExAgent` does not shadow OTP's `Agent` unless you alias it as `Agent`.

## Quick start

The fastest way to try ExAgent is with [`Mix.install/2`] (Livebook or a script) —
using the built-in [`ExAgent.Models.Test`] model, **no API key needed**:

```elixir
Mix.install([
  {:exagent, "~> 1.0"}
])

agent = ExAgent.new(model: "test", instructions: "Be concise.")
{:ok, %{output: text}} = ExAgent.run(agent, "Hello!")
```

Point it at a real provider with a `"provider:model"` string:

```elixir
agent = ExAgent.new(model: "openai:gpt-4o", instructions: "Be concise.")
{:ok, %{output: text}} = ExAgent.run(agent, "Hello!")
```

[hexdocs]: https://hexdocs.pm/exagent
[source]: https://github.com/kukapu/exagent
[`Mix.install/2`]: https://hexdocs.pm/mix/Mix.html#install/2
[`ExAgent.Model`]: https://hexdocs.pm/exagent/ExAgent.Model.html
[`RunContext`]: https://hexdocs.pm/exagent/ExAgent.RunContext.html
[`ExAgent.run/3`]: https://hexdocs.pm/exagent/ExAgent.html#run/3
[`ExAgent.run_stream/3`]: https://hexdocs.pm/exagent/ExAgent.html#run_stream/3
[`ExAgent.Server`]: https://hexdocs.pm/exagent/ExAgent.Server.html
[`ExAgent.Session`]: https://hexdocs.pm/exagent/ExAgent.Session.html
[`ExAgent.Models.Test`]: https://hexdocs.pm/exagent/ExAgent.Models.Test.html
[`ExAgent.Event`]: https://hexdocs.pm/exagent/ExAgent.Event.html
[`ExAgent.PubSub`]: https://hexdocs.pm/exagent/ExAgent.PubSub.html

<!-- MDOC -->

## Table of Contents

- [Layer 0 — the one-shot loop](#layer-0--the-one-shot-loop)
  - [Tools with derived schemas](#tools-with-derived-schemas)
  - [Structured output](#structured-output)
  - [Streaming](#streaming)
  - [Serialization / durable runs](#serialization--durable-runs)
- [Layer 1 — a stateful, supervised agent](#layer-1--a-stateful-supervised-agent)
- [Layer 2 — snapshots & resume](#layer-2--snapshots--resume)
- [Layer 3 — multi-agent sessions](#layer-3--multi-agent-sessions)
- [Coordination](#coordination)
- [Robustness & safety](#robustness--safety)
- [External tools (MCP)](#external-tools-mcp)
- [Events & PubSub](#events--pubsub)
- [Models](#models)
- [Examples](#examples)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [License](#license)

## Layer 0 — the one-shot loop

The core is a small loop: `UserPromptNode → ModelRequestNode ⇄ CallToolsNode → End`.

```elixir
agent = ExAgent.new(model: "test", instructions: "Be concise.")
{:ok, %{output: text}} = ExAgent.run(agent, "Hello!")
```

`run/3` always returns `{:ok, result} | {:error, reason}` (it never raises). The
`result` map carries `:output`, `:messages`, `:new_messages`, `:usage`
(`%{input_tokens:, output_tokens:}`), `:run_step` and the (possibly updated)
`:model`.

### Tools with derived schemas

```elixir
defmodule MyApp.Tools do
  use ExAgent.Tools

  @doc "Get the weather for a city."
  deftool get_weather(ctx, city :: String.t(), days :: integer()) do
    {:ok, "#{city}: sunny"}
  end
end

agent = ExAgent.new(model: "openai:gpt-4o", tools: MyApp.Tools.tools())
```

`deftool` receives the [`RunContext`] as its first arg (named `ctx` by convention);
`tool_plain` takes only parameters. Each parameter is `name :: Type`, so the JSON
Schema is derived for you. A tool may return `value`, `{:ok, value}` or
`{:error, reason}`.

### Structured output

Any `embedded_schema` becomes the output spec; JSON Schema is derived from the
schema **and** its changeset validations (`validate_inclusion` → `enum`,
`validate_number` → `minimum`/`maximum`, `validate_length` → `minLength`/
`maxLength`), then validated with the changeset, with retry-on-failure.

```elixir
defmodule WeatherReport do
  use Ecto.Schema
  embedded_schema do
    field :city, :string
    field :temp_c, :float
    field :condition, Ecto.Enum, values: [:sunny, :rainy, :cloudy]
  end

  def changeset(s, a) do
    s |> Ecto.Changeset.cast(a, [:city, :temp_c, :condition])
      |> Ecto.Changeset.validate_required([:city, :temp_c])
      |> Ecto.Changeset.validate_number(:temp_c, greater_than: -100, less_than: 100)
  end
end
# → the model is told temp_c is a number in (-100, 100) and condition is one of
#   the enum values, so it can comply instead of guessing and being retried.

agent = ExAgent.new(model: "anthropic:claude-3-5-haiku", output: WeatherReport)
{:ok, %{output: %WeatherReport{}}} = ExAgent.run(agent, "It's 22 and sunny in Madrid")
```

### Streaming

```elixir
ExAgent.run_stream(agent, "count to five")
|> Stream.each(fn
  {:delta, t} -> IO.write(t)
  {:result, %{usage: u}} -> IO.puts("\n#{u.output_tokens} tokens")
end)
|> Stream.run()
```

[`ExAgent.run_stream/3`] yields `{:delta, binary}` per chunk then `{:result, map}`. It is
text-focused and best suited to chat/streaming UIs; for a full agentic tool loop
use [`ExAgent.run/3`].

### Serialization / durable runs

The core is **DB-free**: it doesn't own a database or job queue. It provides
best-effort message-history serialization so you can persist a conversation
anywhere and resume it:

```elixir
json = ExAgent.Message.to_json(result.messages)   # store this
{:ok, history} = ExAgent.Message.from_json(json)  # load it back
ExAgent.run(agent, "follow up", message_history: history)
```

For crash-safe, resumable runs, wrap [`ExAgent.run/3`] in an **Oban** job — see
`examples/durable_oban.exs`. Or use Layer 1's built-in store.

## Layer 1 — a stateful, supervised agent

[`ExAgent.Server`] keeps an agent alive across runs: it preserves history,
accumulates usage, threads stateful models, and emits events.

```elixir
{:ok, dm} =
  ExAgent.AgentSupervisor.start_agent(
    agent: ExAgent.new(model: "openai:gpt-4o", instructions: "You are a DM."),
    agent_id: "dm",
    pubsub: :local
  )

{:ok, %{output: _}} = ExAgent.Server.chat(dm, "I enter the tavern.")   # synchronous
{:ok, %{output: _}} = ExAgent.Server.chat(dm, "I pick the lock.")      # sees prior turn

# Async: returns immediately, result arrives as a :run_finished event
{:ok, request_id} = ExAgent.Server.send_message(dm, "describe the room")
ExAgent.Server.abort(dm)      # cancel the in-flight run (stays responsive)
ExAgent.Server.health(dm)     # %{status: :idle, pending: 0}
```

While a run is in flight, `chat/3` returns `{:error, :busy}` and `send_message/3`
enqueues up to `max_pending` (default `8`) then returns `{:error, :queue_full}`.

## Layer 2 — snapshots & resume

Point a Server at a store and it checkpoints after every run and rehydrates on
restart — surviving crashes:

```elixir
ExAgent.AgentSupervisor.start_agent(
  agent: agent_template,
  agent_id: "dm",
  store: :ets          # ExAgent.Store behaviour; ETS ships by default
)
```

The persisted `ExAgent.Server.Snapshot` carries only **serializable** state
(history + usage + metadata): never pids, secrets or tool closures. The live
model/tools come from the app-supplied template on restart. The default
`ExAgent.Store.ETS` is in-process; for durability across nodes, use
`ExAgent.Store.Postgres` (needs `ecto_sql` + `postgrex`):

```elixir
ExAgent.Store.Postgres.migrate(MyApp.Repo)   # once
ExAgent.AgentSupervisor.start_agent(
  agent: agent_template, agent_id: "dm",
  store: {ExAgent.Store.Postgres, MyApp.Repo}
)
```

## Layer 3 — multi-agent sessions

[`ExAgent.Session`] coordinates participants (agents or humans) taking turns over
a piece of shared state, through a pluggable `TurnPolicy`. The Session is the
**single writer** of `shared_state`.

```elixir
alias ExAgent.Session
alias ExAgent.Session.Participant

{:ok, game} =
  Session.start_link(
    shared_state: %{log: []},
    policy: {:initiative, order: ["rogue", "fighter", "wizard"]},
    participants: [
      Participant.new(id: "rogue", kind: :agent),
      Participant.new(id: "fighter", kind: :human)
    ],
    pubsub: :local
  )

:ok = Session.start(game)
{:ok, world, next} =
  Session.take_turn(game, "rogue", fn s -> {:ok, %{s | log: ["rogue acts" | s.log]}} end)
# `next` is now "fighter"; it sees the rogue's change via Session.read_state/1
```

Tools inside an agent run read/propose state through an
`ExAgent.Session.SharedState` handle in `RunContext.deps` — never a mutable
reference. Policies: `RoundRobin`, `Initiative` (custom `:order`),
`SupervisorPolicy` (a coordinator alternates with workers).

## Coordination

`ExAgent.Coordination` adds the classic orchestration patterns on top of a
Session (levels 2 & 3):

```elixir
alias ExAgent.Coordination

# Delegation (agent-as-tool): the parent calls a sub-agent; both runs' tokens
# are counted together.
helper = ExAgent.new(model: "openai:gpt-4o-mini", instructions: "You summarize.")
parent =
  ExAgent.new(
    model: "openai:gpt-4o",
    tools: [Coordination.delegation_tool(helper, name: "summarize")]
  )

# Hand-off: transfer control between participants directly.
{:ok, "wizard"} = Coordination.handoff(session, "wizard")
```

## Robustness & safety

Long sessions and cost stay under control, all opt-in:

```elixir
alias ExAgent.{Compaction, CostGuard, Permissions, UsageLimits}

# Summarize old turns once the context grows (capability hook).
compaction = %Compaction.Capability{
  compactor: Compaction.Summary,
  opts: [threshold_tokens: 6000, keep_recent: 8, summarize: &MyApp.summarize/1]
}

# Per-tool admission control (allow/ask/deny with globs).
perms = Permissions.new!(rules: [{"*", :deny}, {"read", :allow}, {"bash", :ask}])

agent =
  ExAgent.new(
    model: "anthropic:claude-3-5-haiku",       # cache: true → prompt caching
    capabilities: [compaction],
    usage_limits: %UsageLimits{request_limit: 20, tool_calls_limit: 15, max_budget_cents: 25}
  )

ExAgent.run(agent, "go",
  permissions: perms,
  approve: &MyApp.ask_human/1,                 # called on :ask
  estimate_cost: CostGuard.estimator(%{input_per_1k_cents: 250, output_per_1k_cents: 1000})
)
```

## External tools (MCP)

Consume any [Model Context Protocol](https://modelcontextprotocol.io) server's
tools as plain `ExAgent.Tool`s:

```elixir
alias ExAgent.MCP.Client

{:ok, fs} =
  Client.start_link(
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", "./data"]
  )

{:ok, tools} = Client.tools(fs)   # [ExAgent.Tool.t(), ...]
agent = ExAgent.new(model: "anthropic:claude-3-5-haiku", tools: tools)
```

The client owns the stdio JSON-RPC connection (handshake, `tools/list`,
`tools/call`, line buffering); transport exits and errors surface cleanly.

## Events & PubSub

Every layer emits versioned [`ExAgent.Event`] envelopes (distinct from
`:telemetry`). Subscribe to drive a UI:

```elixir
:ok = ExAgent.PubSub.subscribe({ExAgent.PubSub.Local, []}, ExAgent.Event.agent_topic("dm"))

receive do
  {:exagent_event, %ExAgent.Event{type: :run_finished, payload: p}} ->
    IO.puts("done: #{inspect(p)}")
end
```

[`ExAgent.PubSub`] is a behaviour: `None` (default, no-op), `Local` (Registry),
`Phoenix` (delegates to `Phoenix.PubSub` dynamically — no hard dependency), or
your own.

## Models

Resolve from a string or pass a struct:

```elixir
ExAgent.new(model: "openai:gpt-4o")
ExAgent.new(model: "openrouter:deepseek/deepseek-v4-flash")   # one gateway, many backends
ExAgent.new(model: "anthropic:claude-3-5-haiku-20241022")
ExAgent.new(model: "zai:glm-4.5-air")   # Z.AI's Anthropic-compatible endpoint (GLM)
```

The loop is provider-agnostic and the parsers tolerate the malformed responses
real providers occasionally return (empty `choices`, `content: null`, partial
`usage`). Bring your own provider by implementing the [`ExAgent.Model`] behaviour.

## Examples

- `examples/demo.exs` — offline loop with the TestModel.
- `examples/openrouter.exs` — live tool-calling via OpenRouter.
- `examples/structured_output.exs` — live structured output via Ecto.
- `examples/streaming.exs` — live SSE streaming.
- `examples/stateful_agent.exs` — supervised stateful agent + events.
- `examples/multi_agent_session.exs` — two agents, round-robin, shared state.
- `examples/dnd_session.exs` — a mini D&D round: DM + bot + human over a shared
  world, coordinated by a Session (SupervisorPolicy), offline.

Run any of them with `mix run examples/<name>.exs` (live ones need an API key in
the environment).

## Documentation

- [Full module reference on hexdocs][hexdocs]
- [`DESIGN.md`](./DESIGN.md) — architecture, principles and rationale.
- [`ROADMAP.md`](./ROADMAP.md) — development phases and progress.
- [`CHANGELOG.md`](./CHANGELOG.md) — release history.

## Contributing

Bug reports and pull requests are welcome on [GitHub][source].

```bash
mix check                       # compile (warnings-as-errors) + format + test
MIX_ENV=test mix test           # full test suite
mix run examples/demo.exs       # offline smoke test (no API key)
```

The default test suite is fully offline (it uses the TestModel). Tests that need
a live provider are tagged `:integration` (opt in with `--only integration`);
`Store.Postgres` tests are tagged `:postgres` and auto-skip without a database.

## License

Copyright (c) 2025 kukapu

Licensed under the MIT License — see [LICENSE](./LICENSE).

