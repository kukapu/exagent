# Run with: mix run examples/demo.exs
#
# A self-contained demo of the agent loop using the in-process TestModel —
# no API key needed. Shows: instructions, a tool that takes the RunContext
# (dependency injection), and the final structured result.

alias ExAgent.{Tool, RunContext}
alias ExAgent.Message.Part

balance_tool =
  Tool.new(
    name: "get_balance",
    description: "Return the account balance for the current customer.",
    parameters_json_schema: %{type: "object", properties: %{}},
    takes_ctx: true,
    call: fn %RunContext{deps: %{customer_id: id}}, _args ->
      {:ok, 123.45 * id}
    end
  )

# The TestModel is scripted: first it calls the tool, then it writes the final answer.
model = %ExAgent.Models.Test{
  script: [
    {:tool_calls, [%Part.ToolCall{tool_name: "get_balance", args: %{}}]},
    "Your balance is ready. (final answer)"
  ]
}

agent =
  ExAgent.new(
    model: model,
    instructions: "You are a bank assistant.",
    tools: [balance_tool]
  )

{:ok, result} = ExAgent.run(agent, "What's my balance?", deps: %{customer_id: 2})

IO.puts("=== OUTPUT ===")
IO.inspect(result.output, label: "output")

IO.puts("\n=== MESSAGE HISTORY ===")

Enum.each(result.messages, fn msg ->
  case msg do
    %ExAgent.Message.Request{parts: parts} ->
      IO.puts("[Request]")
      Enum.each(parts, &IO.inspect/1)

    %ExAgent.Message.Response{parts: parts} ->
      IO.puts("[Response]")
      Enum.each(parts, &IO.inspect/1)
  end
end)

IO.puts("\n=== USAGE ===")
IO.inspect(result.usage, label: "usage")
