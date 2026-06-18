defmodule ExAgent.ToolsTest do
  use ExUnit.Case, async: true

  alias ExAgent.{RunContext, Tool}
  alias ExAgent.Message.Part
  alias ExAgent.Test.SampleTools

  describe "tools/0 (macro-defined)" do
    test "returns Tool structs with derived schemas and descriptions" do
      tools = SampleTools.tools()
      names = Enum.map(tools, & &1.name)
      assert names == ["get_weather", "add", "ping"]

      weather = SampleTools.tool(:get_weather)
      assert %Tool{} = weather
      assert weather.description == "Get the weather for a city."
      assert weather.takes_ctx == true

      assert weather.parameters_json_schema == %{
               type: "object",
               properties: %{"city" => %{type: "string"}, "days" => %{type: "integer"}},
               required: ["city", "days"]
             }

      add = SampleTools.tool(:add)
      assert add.takes_ctx == false

      assert add.parameters_json_schema.properties == %{
               "a" => %{type: "integer"},
               "b" => %{type: "integer"}
             }

      assert SampleTools.tool(:ping).parameters_json_schema == %{
               type: "object",
               properties: %{},
               required: []
             }
    end
  end

  describe "call closure" do
    test "maps string-keyed args to positional, with ctx" do
      weather = SampleTools.tool(:get_weather)
      ctx = %RunContext{}
      assert weather.call.(ctx, %{"city" => "Madrid", "days" => 3}) == {:ok, "Madrid (3d)"}
    end

    test "plain tool maps args without ctx" do
      add = SampleTools.tool(:add)
      assert add.call.(%{"a" => 2, "b" => 3}) == {:ok, 5}
    end

    test "the real function is still callable directly" do
      assert SampleTools.add(2, 3) == {:ok, 5}
    end
  end

  describe "integration with the agent loop" do
    test "agent executes a macro-defined tool, then finalizes" do
      model = %ExAgent.Models.Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "add", args: ~s({"a":2,"b":40})}]},
          "the sum is ready"
        ]
      }

      agent = ExAgent.new(model: model, tools: SampleTools.tools())

      assert {:ok, %{output: "the sum is ready", messages: messages}} = ExAgent.run(agent, "add")

      assert %Part.ToolReturn{tool_name: "add", content: 42} =
               find_part(messages, ExAgent.Message.Part.ToolReturn)
    end

    test "deftool with ctx receives the RunContext" do
      weather = SampleTools.tool(:get_weather)

      model = %ExAgent.Models.Test{
        script: [
          {:tool_calls,
           [%Part.ToolCall{tool_name: "get_weather", args: ~s({"city":"X","days":1})}]},
          "done"
        ]
      }

      agent = ExAgent.new(model: model, tools: [weather])
      assert {:ok, %{output: "done"}} = ExAgent.run(agent, "w", deps: %{name: "Kukapu"})
    end
  end

  defp find_part(messages, mod) do
    matcher = fn
      %struct{} = part -> if struct == mod, do: part, else: nil
      _ -> nil
    end

    Enum.find_value(messages, fn
      %ExAgent.Message.Request{parts: parts} -> Enum.find_value(parts, matcher)
      %ExAgent.Message.Response{parts: parts} -> Enum.find_value(parts, matcher)
      _ -> nil
    end)
  end
end
