# Run with:  mix run examples/openrouter.exs
#
# Real smoke test against OpenRouter. Requires OPENROUTER_API_KEY in your env.
#
#   export OPENROUTER_API_KEY=sk-or-...
#   mix run examples/openrouter.exs
#
# It exercises the full path: our Message structs -> JSON -> OpenRouter ->
# JSON -> our Response, plus a real tool call handled by the agent loop.

key = System.get_env("OPENROUTER_API_KEY")

unless key do
  IO.puts("OPENROUTER_API_KEY not set — skipping live request.")
  System.halt(0)
end

alias ExAgent.{Tool}

# A free / very cheap model on OpenRouter. Swap for any slug you have access to.
model =
  ExAgent.Models.OpenRouter.new(
    model: System.get_env("OPENROUTER_MODEL", "openai/gpt-4o-mini"),
    app_title: "exagent smoke test"
  )

# A simple function tool so we can see a real tool-call round trip.
weather =
  Tool.new(
    name: "get_weather",
    description: "Get the current weather for a city.",
    parameters_json_schema: %{
      type: "object",
      properties: %{city: %{type: "string", description: "City name"}},
      required: ["city"]
    },
    takes_ctx: false,
    # Stand-in for a real weather call.
    call: fn %{"city" => city} -> {:ok, "#{city}: 22C, clear"} end
  )

agent =
  ExAgent.new(
    model: model,
    instructions: "Be concise. Use tools when asked about the weather.",
    tools: [weather],
    model_settings: [max_tokens: 200, temperature: 0]
  )

prompt = "What's the weather like in Madrid? Then answer in one sentence."
{:ok, result} = ExAgent.run(agent, prompt)

IO.puts("=== OUTPUT ===")
IO.puts(result.output)

IO.puts("\n=== USAGE (real) ===")
IO.inspect(result.usage, label: "usage")

IO.puts("\n=== MESSAGE COUNT ===")
IO.puts(length(result.messages))
