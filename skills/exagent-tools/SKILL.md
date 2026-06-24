---
name: exagent-tools
description: >
  Use this skill when the user wants to define or wire agent tools with the
  `exagent` Hex package: the `use ExAgent.Tools` macro, `deftool`/`tool_plain`
  with `name :: Type` annotations for auto-derived JSON Schema, tools that need
  the `RunContext` (dependency injection / `ctx`), or building a single tool by
  hand with `ExAgent.Tool.new/1`. Triggers: exagent tools, deftool, tool_plain,
  crear herramienta/tool de agente, RunContext, tool schema, ExAgent.Tools,
  tools/0, inyectar dependencias en tool.
---

# exagent-tools — define tools as plain Elixir functions

Tools are plain functions whose **JSON Schema is derived from `::` type
annotations** and `@doc` strings — no hand-written schemas. Define them in a
module, then pass `Modulo.tools()` to `ExAgent.new/1`.

## Prerequisites

Host app depends on `{:exagent, "~> 1.0"}` (see `exagent-run-agent`).

## Workflow

### 1. Define a tools module

```elixir
defmodule MyApp.Tools do
  use ExAgent.Tools

  @doc "Get the weather for a city."
  deftool get_weather(ctx, city :: String.t(), days :: integer()) do
    {:ok, "#{city}: sunny (#{days}d)"}
  end

  @doc "Add two numbers."
  tool_plain add(a :: integer(), b :: integer()) do
    {:ok, a + b}
  end
end
```

### 2. Wire it into an agent

```elixir
agent = ExAgent.new(model: "openai:gpt-4o", tools: MyApp.Tools.tools())
```

`use ExAgent.Tools` generates `tools/0` (list of `ExAgent.Tool.t()`),
`tool/1` (lookup by string/atom name) and `__exagent_tool_names__/0`.

## The two macros

| macro | first arg | when to use |
|---|---|---|
| `deftool name(ctx, params...)` | **`RunContext`** (named `ctx` by convention) | the tool needs injected deps, the user, a DB record, a `SharedState` handle, etc. |
| `tool_plain name(params...)` | none (just params) | pure/stateless tools. |

Rules:
- Every parameter is written `name :: Type`; supported types live in
  `ExAgent.Schema` (`String.t`, `integer`, `float`, `boolean`, …). **Untyped
  params collapse to an unconstrained schema** — annotate for better model output.
- A tool may return `value`, `{:ok, value}`, or `{:error, reason}`.
- `@doc` **above** the tool becomes its description sent to the model — write it.
- A tool that **raises** is contained: exAgent catches it → `{:error, _}`, it never
  crashes the agent run.

### Reading injected deps via `ctx`

`RunContext.deps` holds whatever you passed as `deps:` to `run/3`:

```elixir
deftool get_balance(ctx) do
  %ExAgent.RunContext{deps: %{customer_id: id}} = ctx
  {:ok, MyApp.Balance.for(id)}
end

ExAgent.run(agent, "what's my balance?", deps: %{customer_id: 42})
```

### Building a single tool by hand

When you can't use the macro (dynamic tools, MCP, closures), build a struct
directly:

```elixir
alias ExAgent.{Tool, RunContext}

balance_tool =
  Tool.new(
    name: "get_balance",
    description: "Return the account balance for the current customer.",
    parameters_json_schema: %{type: "object", properties: %{}},
    takes_ctx: true,
    call: fn %RunContext{deps: %{customer_id: id}}, _args -> {:ok, 123.45 * id} end
  )

agent = ExAgent.new(model: "test", tools: [balance_tool])
```

`takes_ctx: true` → `call` is `fn ctx, args -> ...`; `false` → `fn args -> ...`.

## Consuming external tools (MCP)

Any Model Context Protocol server's tools become plain `ExAgent.Tool`s:

```elixir
{:ok, fs} = ExAgent.MCP.Client.start_link(command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "./data"])
{:ok, tools} = ExAgent.MCP.Client.tools(fs)
agent = ExAgent.new(model: "anthropic:claude-3-5-haiku", tools: tools)
```

## Gotchas

- `deftool name/0` with **no `ctx`** raises `ArgumentError` at compile time —
  `deftool` always needs the context arg as first param. Use `tool_plain` if you
  want no context at all.
- The `@doc` is pulled at compile time via `Code.fetch_docs/1`. If you skip
  `@doc`, the model gets a tool with no description (worse tool selection).
- Schema is derived from `::` — **a bare `param` (no `::`) yields an unconstrained
  param**, so annotate everything you want validated/typed.
- Tool args arrive as a map keyed by **string** names; the macro maps them to the
  function's positional args. You just read the named function args, not the map.
- Tools run in the supervised task pool. Make side-effectful tools idempotent if
  you wrap runs in a retrying job (Oban) — see `examples/durable_oban.exs`.
- Don't mutate global state from a tool and expect the run to observe it — return
  data, or (in a Session) propose changes via the `SharedState` handle (see
  `exagent-session`).

## Validation

- Inspect generated tools in `iex -S mix`: `MyApp.Tools.tools() |> Enum.map(& &1.name)`.
- Test the loop offline without a key by scripting a tool call with the TestModel:

```elixir
alias ExAgent.Message.Part
model = %ExAgent.Models.Test{script: [
  {:tool_calls, [%Part.ToolCall{tool_name: "get_weather", args: %{"city" => "Madrid", "days" => 3}}]},
  "Done."
]}
agent = ExAgent.new(model: model, tools: MyApp.Tools.tools())
{:ok, %{output: _}} = ExAgent.run(agent, "weather?")
```

## Troubleshooting

- Tool never called → its `@doc`/name is unclear, or a param is untyped so the
  model is unsure what to send. Annotate types and write a precise `@doc`.
- `{:error, {:tool_retries_exhausted, _}}` → the tool keeps raising/returning
  `{:error, _}`. Each `ExAgent.Tool` has `max_retries` (default 1); raise it.
- Wrong arg types from the model → tighten the `::` annotation (e.g.
  `integer()` not bare) so the JSON Schema constrains the model.
