defmodule ExAgent.Scenarios.OutputHistoryReplayTest do
  @moduledoc """
  Regression: when the model emits MORE than one output (final_result) tool call
  in a single response, every call must get a ToolReturn so the assistant→
  tool_result pairing stays 1:1. Without that, OpenAI/Anthropic reject the next
  request (N tool_calls but only 1 tool_result) and the conversation is stuck.
  """

  use ExUnit.Case, async: true

  alias ExAgent.Message
  alias ExAgent.Message.Part

  defmodule Out do
    @moduledoc false
    use Ecto.Schema
    @primary_key false
    embedded_schema do
      field(:v, :string)
    end

    def changeset(s, a),
      do: s |> Ecto.Changeset.cast(a, [:v]) |> Ecto.Changeset.validate_required([:v])
  end

  test "two final_result calls in one response → every call gets a ToolReturn" do
    model = %ExAgent.Models.Test{
      script: [
        {:tool_calls,
         [
           %Part.ToolCall{tool_name: "final_result", args: %{"v" => "a"}, tool_call_id: "out1"},
           %Part.ToolCall{tool_name: "final_result", args: %{"v" => "b"}, tool_call_id: "out2"}
         ]}
      ]
    }

    agent = ExAgent.new(model: model, output: Out)
    assert {:ok, %{output: %Out{v: "a"}, messages: messages}} = ExAgent.run(agent, "go")

    # Every tool_call_id present in the assistant response must have a matching
    # ToolReturn in the following request — the 1:1 invariant that providers need.
    returns =
      Enum.flat_map(messages, fn
        %Message.Request{parts: parts} ->
          Enum.filter(parts, &match?(%Part.ToolReturn{}, &1))

        _ ->
          []
      end)

    return_ids = Enum.map(returns, & &1.tool_call_id) |> Enum.sort()
    assert return_ids == ["out1", "out2"]
  end
end
