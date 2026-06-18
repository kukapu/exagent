defmodule ExAgent.ResumeIntegrationTest do
  use ExUnit.Case, async: true

  # The headline persistence feature: serialize a run's history, deserialize it,
  # and continue the same conversation in a fresh run via message_history:.
  alias ExAgent.{Message, Tool}
  alias ExAgent.Message.Part

  test "serialize → deserialize → resume continues the same conversation" do
    echo =
      Tool.new(
        name: "echo",
        description: "echo",
        parameters_json_schema: %{type: "object"},
        takes_ctx: false,
        call: fn %{"x" => x} -> {:ok, x} end
      )

    # First run: model calls echo("hello"), then finishes.
    model1 = %ExAgent.Models.Test{
      script: [
        {:tool_calls, [%Part.ToolCall{tool_name: "echo", args: %{"x" => "hello"}}]},
        "first answer"
      ]
    }

    agent = ExAgent.new(model: model1, tools: [echo])
    {:ok, %{messages: history, output: "first answer"}} = ExAgent.run(agent, "greet")

    # Persist to JSON and back (simulating PG/Redis/file round-trip).
    json = Message.to_json(history)
    assert byte_size(json) > 0
    {:ok, restored} = Message.from_json(json)
    assert length(restored) == length(history)

    # Second run continues from the restored history: the model receives it, and
    # its new_messages are appended (not the whole thing again).
    parent = self()

    model2 = %ExAgent.Models.Test{
      script: [
        fn messages, _params ->
          send(parent, {:history_seen, length(messages)})
          "second answer"
        end
      ]
    }

    agent2 = ExAgent.new(model: model2, tools: [echo])

    {:ok, %{output: "second answer", new_messages: new, messages: all}} =
      ExAgent.run(agent2, "follow up", message_history: restored)

    # the model on the second run saw the restored history (+ the new user prompt)
    assert_received {:history_seen, n} when n == length(restored) + 1

    # new_messages is only this run's additions, not the whole conversation
    assert length(new) < length(all)
    assert length(all) == length(restored) + 2
  end
end
