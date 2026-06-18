defmodule ExAgent.StreamingTest do
  use ExUnit.Case, async: true

  alias ExAgent
  alias ExAgent.Message.{Part, Request}

  describe "ExAgent.run_stream/3 (offline via TestModel)" do
    test "emits text deltas then a final :result" do
      model = %ExAgent.Models.Test{label: "hello streaming world"}
      agent = ExAgent.new(model: model, instructions: "be brief")

      events = agent |> ExAgent.run_stream("hi") |> Enum.to_list()

      deltas = for {:delta, text} <- events, do: text
      assert Enum.join(deltas) == "hello streaming world"

      assert {:result, %{output: output, usage: usage}} = List.last(events)
      assert output == "hello streaming world"
      assert usage.output_tokens > 0
    end

    test "is consumable incrementally with reduce" do
      model = %ExAgent.Models.Test{label: "one two three"}
      agent = ExAgent.new(model: model)

      acc =
        ExAgent.run_stream(agent, "x")
        |> Enum.reduce(<<>>, fn
          {:delta, text}, acc -> acc <> text
          {:result, _}, acc -> acc
        end)

      assert acc == "one two three"
    end

    test "preserves instructions + user prompt in the streamed history" do
      model = %ExAgent.Models.Test{label: "ok"}
      agent = ExAgent.new(model: model, instructions: "be brief")

      {:result, %{messages: messages}} =
        ExAgent.run_stream(agent, "hi") |> Enum.to_list() |> List.last()

      assert [
               %Request{parts: [%Part.System{content: "be brief"}, %Part.User{content: "hi"}]},
               %ExAgent.Message.Response{}
             ] = messages
    end

    test "a :result still carries assembled usage" do
      model = %ExAgent.Models.Test{label: "tokens"}
      agent = ExAgent.new(model: model)

      {:result, %{usage: usage}} = ExAgent.run_stream(agent, "x") |> Enum.to_list() |> List.last()

      assert usage.input_tokens > 0
    end
  end
end
