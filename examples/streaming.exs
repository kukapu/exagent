# Live streaming test against Z.AI (Anthropic format) with glm-4.5-air.
#
#   set -a && . ./.env && set +a && mix run examples/streaming.exs
#
# Prints text deltas as they arrive (typewriter effect) then the final result.

key = System.get_env("ZAI_API_KEY") || System.get_env("ANTHROPIC_AUTH_TOKEN")

unless key do
  IO.puts("ZAI_API_KEY not set — skipping.")
  System.halt(0)
end

alias ExAgent

model =
  ExAgent.Models.Anthropic.new(
    model: System.get_env("ZAI_MODEL", "glm-4.5-air"),
    auth_token: key,
    base_url: "https://api.z.ai/api/anthropic"
  )

agent =
  ExAgent.new(
    model: model,
    instructions: "Count from 1 to 5 slowly, one number per line.",
    model_settings: [max_tokens: 256, temperature: 0]
  )

IO.puts("=== STREAMING ===")

ExAgent.run_stream(agent, "count!")
|> Stream.each(fn
  {:delta, text} ->
    IO.write(text)

  {:result, %{usage: usage}} ->
    IO.puts("\n\n=== FINAL ===\ntokens in=#{usage.input_tokens} out=#{usage.output_tokens}")

  {:error, reason} ->
    IO.puts("\nERROR: #{inspect(reason)}")
end)
|> Stream.run()
