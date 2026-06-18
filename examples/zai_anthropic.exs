# Run with:  mix run examples/zai_anthropic.exs
#
# Live smoke test against Z.AI's Anthropic-compatible endpoint using the cheap
# GLM-4.5-Air model — exercises the native Anthropic Messages format
# (top-level system, content blocks, tool_use/tool_result).
#
#   export ZAI_API_KEY=<your z.ai key>
#   mix run examples/zai_anthropic.exs

key = System.get_env("ZAI_API_KEY") || System.get_env("ANTHROPIC_AUTH_TOKEN")

unless key do
  IO.puts("ZAI_API_KEY (or ANTHROPIC_AUTH_TOKEN) not set — skipping live request.")
  IO.puts("Get a key at https://z.ai/manage-apikey/apikey-list")
  System.halt(0)
end

alias ExAgent.{Tool}

model =
  ExAgent.Models.Anthropic.new(
    model: System.get_env("ZAI_MODEL", "glm-4.5-air"),
    auth_token: key,
    base_url: "https://api.z.ai/api/anthropic"
  )

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
    call: fn %{"city" => city} -> {:ok, "#{city}: 22C, clear"} end
  )

agent =
  ExAgent.new(
    model: model,
    instructions: "Be concise. Use tools when asked about the weather.",
    tools: [weather],
    model_settings: [max_tokens: 1024, temperature: 0]
  )

{:ok, result} = ExAgent.run(agent, "What's the weather like in Madrid? Answer in one sentence.")

IO.puts("=== OUTPUT ===")
IO.puts(result.output)

IO.puts("\n=== USAGE (real) ===")
IO.inspect(result.usage, label: "usage")

IO.puts("\n=== MESSAGE COUNT ===")
IO.puts(length(result.messages))
