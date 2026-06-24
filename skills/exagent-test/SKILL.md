---
name: exagent-test
description: >
  Use this skill when writing or running tests for apps that use the `exagent`
  Hex package: testing the agent loop offline with the deterministic
  `ExAgent.Models.Test` model (no API key, no network), scripting tool calls and
  responses, asserting on the `%ExAgent.run/3` result, or running exAgent's own
  example/test commands. Triggers: test exagent, TestModel, Models.Test, scripted
  model, offline agent test, testear agente sin API key, tool_calls script,
  mix test exagent, ExUnit agent, run_stream test, assert agent output.
---

# exagent-test — test the agent loop offline with the TestModel

`ExAgent.Models.Test` is a **deterministic, in-process model** — a drop-in
replacement for a real provider that never hits the network. It is the workhorse
for unit-testing agents and the whole model⇄tools loop with zero cost and zero
flakiness.

## Prerequisites

Host app depends on `{:exagent, "~> 1.0"`. ExUnit is Elixir's built-in test
framework (`use ExUnit.Case, async: true`).

## Workflow

### 1. Use the TestModel instead of a real provider

```elixir
agent = ExAgent.new(model: "test", instructions: "Be concise.")
{:ok, %{output: text}} = ExAgent.run(agent, "anything")
# text == "a test response" (the default reply)
```

`%ExAgent.Models.Test{}` config forms:
- `%Test{}` — always replies with the generic text `"a test response"`.
- `%Test{label: "x"}` — replies with the fixed string `"x"`.
- `%Test{script: [...]}` — returns each item **in order**; an item may be:
  - a `String.t` → wrapped as a text part,
  - a `{:tool_calls, [%ExAgent.Message.Part.ToolCall{...}]}` tuple,
  - a full `ExAgent.Message.Response`,
  - or a function `fn messages, params -> item` (0/1/2-arity) for dynamic scripts.
- When the script is exhausted, it falls back to the default response.

### 2. Script a tool call then a final answer (the common pattern)

```elixir
alias ExAgent.Message.Part

model = %ExAgent.Models.Test{
  script: [
    {:tool_calls, [%Part.ToolCall{tool_name: "get_balance", args: %{}}]},
    "Your balance is ready."
  ]
}

agent = ExAgent.new(model: model, instructions: "You are a bank assistant.", tools: MyApp.Tools.tools())

assert {:ok, %{output: "Your balance is ready."}} = ExAgent.run(agent, "balance?", deps: %{customer_id: 2})
```

This exercises the **full loop** (model → tool execution → model → final) offline.
Pass the struct directly as `model:` (not a `"test"` string) when you need a script.

### 3. Assert on the result map

`ExAgent.run/3` returns `{:ok, result}` where `result` has:
- `:output` — the final answer (string, or the struct if `output:` is set),
- `:messages` — full `[Message.t()]` history,
- `:new_messages` — only this run's messages,
- `:usage` — `%{input_tokens:, output_tokens:}`,
- `:run_step` — number of model⇄tool iterations,
- `:model` — the (possibly updated) model struct.

```elixir
{:ok, result} = ExAgent.run(agent, "hi")
assert result.usage.output_tokens > 0
assert length(result.messages) >= 2          # at least request + response
```

### 4. Test streaming

`request_stream/4` on the TestModel streams the scripted text in word chunks:

```elixir
model = %ExAgent.Models.Test{label: "hello world"}
agent = ExAgent.new(model: model)

events = ExAgent.run_stream(agent, "go") |> Enum.to_list()

assert Enum.any?(events, &match?({:delta, _}, &1))     # text deltas were emitted

{:result, final} = Enum.find(events, &match?({:result, _}, &1))
assert final.output == "hello world"
```

### 5. Test stateful agents (Server) and the model threading

`ExAgent.Server` threads the **updated** model struct between runs, so a scripted
TestModel advances through its script across consecutive `chat/3` calls:

```elixir
model = %ExAgent.Models.Test{script: ~w(first second third)}
{:ok, pid} = ExAgent.AgentSupervisor.start_agent(agent: ExAgent.new(model: model), agent_id: "t")

assert {:ok, %{output: "first"}} = ExAgent.Server.chat(pid, "1")
assert {:ok, %{output: "second"}} = ExAgent.Server.chat(pid, "2")   # script index advanced
```

## Test tags (exAgent's own suite — mirror this in your app)

| tag | meaning |
|---|---|
| `:integration` | real provider calls — **opt in** with `--only integration` (or `--include integration`). Excluded by default. |
| `:postgres` | needs a Postgres DB for `Store.Postgres` — **auto-skipped** when the DB is unavailable. |
| `:mcp_e2e` | spawns a real stdio MCP server — **auto-skipped** when `python3` is absent. |

In your app, gate real-provider tests behind `@tag :integration` so the default
suite stays offline/fast/free.

## Commands

```bash
mix run examples/demo.exs              # smoke a scripted loop, no key
mix run examples/stateful_agent.exs    # stateful Server + events, no key

MIX_ENV=test mix test                  # full suite
MIX_ENV=test mix test --only integration   # run real-provider tests too
mix test path/to/file_test.exs:42      # one test by file:line
```

> Note: exAgent's `mix check` alias runs tests in the **dev** env; in a host app
> always use `MIX_ENV=test mix test`.

## Gotchas

- Pass the model as a **struct** (`%ExAgent.Models.Test{script: ...}`), not the
  string `"test"`, when you need scripting. `"test"` only gives the default reply.
- A scripted `{:tool_calls, [...]}` item makes the loop **execute** your tools —
  so the tool must exist on the agent (`tools:`) or the run errors. To test the
  model in isolation, script plain strings/responses instead.
- The TestModel sets tiny `usage` (`input: 1, output: 1` per response, or one
  output token per tool call) — don't assert exact real-world token counts.
- Functions in a script are resolved lazily per step (`fn messages, params -> item`),
  handy for asserting the model *received* prior tool results.
- `async: true` is fine: the TestModel is pure and each run is isolated.
  But tests that touch the shared `Store.ETS` table or start Servers with the
  same `agent_id` can collide — use unique ids per test in that case.

## Validation

- A test using `%Test{script: [...]}` should finish in milliseconds with no network.
- `ExUnit.Case` with `async: true` + the TestModel = hermetic, parallelizable suite.
- If a scripted tool call isn't executed, confirm the tool is in `tools:` and its
  `name` matches the `Part.ToolCall.tool_name` exactly (string).

## Troubleshooting

- `{:error, {:tool_retries_exhausted, _}}` in a scripted test → the scripted tool
  call name doesn't match a tool on the agent, or the tool returns `{:error, _}`.
- Script seems to "repeat" → you reused one `%Test{}` struct across agents sharing
  state; build a fresh struct per test (the `:index`/`:received` fields are mutable).
- Streaming test asserts no deltas → you used `%Test{}` with no `label`/`script`;
  streaming falls back to `"a test response"` split into words.
