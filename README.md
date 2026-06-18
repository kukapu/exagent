# ExAgent

**An agent framework for Elixir** — structured output, tool-calling and
streaming for LLMs, powered by the BEAM. Built the Elixir way: recursion,
behaviours, Ecto changesets, concurrent tool execution, supervision and
telemetry.

## Why

Python agent libraries are delightful when types + validation + an agentic loop
work together. ExAgent brings that **ergonomics** (type-derived tool schemas,
structured output with retry, model-agnostic agents) to Elixir, while leaning on
BEAM strengths: cheap concurrency for tools, supervision/durability,
`:telemetry`, and streaming that plugs straight into LiveView.

## Features

- **Agent loop** — recursive `User → Model ⇄ CallTools → End`.
- **Model-agnostic providers** — OpenAI, OpenRouter (OpenAI-Chat format),
  Anthropic + Z.AI/GLM (native Messages API), and an offline `TestModel`.
- **Tools** — `deftool` macro derives JSON Schema from `::` type annotations +
  `@doc`; runs **in parallel** (`Task.async_stream`) with per-tool timeout &
  retry budget.
- **Structured output** — any `embedded_schema` becomes the output spec; JSON
  Schema is derived and validated with a changeset, with retry-on-failure.
- **Streaming** — `run_stream/3` returns a lazy `Stream` of `{:delta, text}` /
  `{:result, map}` over real SSE (OpenAI + Anthropic).
- **Capabilities** — composable middleware (`before_model_request`,
  `after_tool_execute`, …) via a behaviour with no-op defaults.
- **Production bits** — supervised `ExAgent.Finch` pool, typed
  `RequestError`, `UsageLimits` safety net, and `:telemetry` events.

## Quick start

```elixir
def deps do
  [{:exagent, "~> 0.1.0"}]
end
```

```elixir
alias ExAgent

agent = ExAgent.new(model: "test", instructions: "Be concise.")
{:ok, %{output: text}} = ExAgent.run(agent, "Hello!")
```

Set `OPENAI_API_KEY` before using `openai:*` models.

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

### Structured output

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
  end
end

agent = ExAgent.new(model: "anthropic:claude-3-5-haiku", output: WeatherReport)
{:ok, %{output: %WeatherReport{city: "Madrid", temp_c: 22.0, condition: :sunny}}} =
  ExAgent.run(agent, "It's 22 and sunny in Madrid")
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

### Persistence / durable runs

The framework is **DB-free**: it doesn't own a database or job queue. What it
*does* provide is best-effort message-history serialization, so you can persist
a conversation anywhere (Postgres/Redis/ETS/file) and resume it later:

```elixir
alias ExAgent.Message

json = Message.to_json(result.messages)            # store this
{:ok, history} = Message.from_json(json)           # load it back later

ExAgent.run(agent, "follow up", message_history: history)
```

For crash-safe, resumable runs, wrap `ExAgent.run` in an **Oban** job in your
app — see `examples/durable_oban.exs` for a copy-paste recipe (idempotency
keys, checkpoints, retries). Approval workflows can be coordinated in your app
around persisted history. Durability is an application concern, so the library
doesn't force Oban/Postgres on you.

### Models

Resolve from a string or pass a struct:

```elixir
ExAgent.new(model: "openai:gpt-4o")
ExAgent.new(model: "openrouter:deepseek/deepseek-v4-flash")
ExAgent.new(model: "anthropic:claude-3-5-haiku-20241022")
# Z.AI's Anthropic-compatible endpoint (GLM models), needs ZAI_API_KEY:
ExAgent.new(model: "zai:glm-4.5-air")
```

## Examples

- `examples/demo.exs` — offline loop with the TestModel (no API key).
- `examples/openrouter.exs` — live tool-calling via OpenRouter.
- `examples/zai_anthropic.exs` — live native Anthropic format via Z.AI.
- `examples/structured_output.exs` — live structured output via Ecto.
- `examples/streaming.exs` — live SSE streaming.

## Status

Early, feature-complete MVP for the core agent loop. Implemented & verified
against live providers; see the test suite (run `mix test`).

## Notes for host apps

- This library starts a **supervised `ExAgent.Finch`** HTTP pool in its
  `Application`, so it works out of the box. Tune pool size with
  `config :exagent, :finch_pools, %{:default => [size: 32]}`.
- `ExAgent` does not shadow OTP's `Agent` unless you alias it as `Agent`. If you
  use both in the same file, keep the full name or choose a different alias.

## License

MIT
