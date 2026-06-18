# Live structured-output test against Z.AI (Anthropic format) with glm-4.5-air.
#
#   set -a && . ./.env && set +a && mix run examples/structured_output.exs
#
# The model is forced to call the `final_result` output tool whose args match a
# JSON Schema derived from an Ecto schema; we validate them with a changeset.

key = System.get_env("ZAI_API_KEY") || System.get_env("ANTHROPIC_AUTH_TOKEN")

unless key do
  IO.puts("ZAI_API_KEY not set — skipping.")
  System.halt(0)
end

defmodule Extract do
  use Ecto.Schema

  @primary_key false
  embedded_schema do
    field(:name, :string)
    field(:age, :integer)
    field(:mood, Ecto.Enum, values: [:happy, :sad, :neutral])
  end

  def changeset(s, a) do
    s
    |> Ecto.Changeset.cast(a, [:name, :age, :mood])
    |> Ecto.Changeset.validate_required([:name, :age])
    |> Ecto.Changeset.validate_number(:age, greater_than: 0, less_than: 150)
  end
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
    output: Extract,
    instructions: "Extract structured data from the user's message.",
    model_settings: [max_tokens: 512, temperature: 0]
  )

{:ok, result} =
  ExAgent.run(agent, "Hi! I'm Mara, I'm 30 years old, and I'm feeling pretty happy today.")

IO.puts("=== STRUCTURED OUTPUT ===")
IO.inspect(result.output, label: "output")
IO.puts("\nname: #{result.output.name}, age: #{result.output.age}, mood: #{result.output.mood}")
IO.puts("\n=== USAGE ===")
IO.inspect(result.usage, label: "usage")
