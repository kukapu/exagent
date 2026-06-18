defmodule ExAgent.StructuredOutputTest do
  use ExUnit.Case, async: true

  alias ExAgent
  alias ExAgent.Message.Part
  alias ExAgent.Test.WeatherReport

  @valid_args ~s({"city":"Madrid","temp_c":22.0,"condition":"sunny"})
  @invalid_args ~s({"city":"Madrid","temp_c":200})

  describe "structured output via the output tool" do
    test "valid output call → returns a validated struct" do
      model = %ExAgent.Models.Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "final_result", args: @valid_args}]}
        ]
      }

      agent = ExAgent.new(model: model, output: WeatherReport)

      assert {:ok, %{output: %WeatherReport{} = wr}} = ExAgent.run(agent, "weather?")
      assert wr.city == "Madrid"
      assert wr.temp_c == 22.0
      assert wr.condition == :sunny
    end

    test "invalid output → retry → then valid succeeds, and a Retry part is recorded" do
      model = %ExAgent.Models.Test{
        script: [
          {:tool_calls,
           [%Part.ToolCall{tool_name: "final_result", args: @invalid_args, tool_call_id: "out1"}]},
          {:tool_calls,
           [%Part.ToolCall{tool_name: "final_result", args: @valid_args, tool_call_id: "out2"}]}
        ]
      }

      agent = ExAgent.new(model: model, output: WeatherReport, output_retries: 2)

      assert {:ok, %{output: wr, messages: messages}} = ExAgent.run(agent, "weather?")

      assert wr.temp_c == 22.0

      # The first invalid attempt should have produced a tool-scoped retry so
      # provider history can be replayed without a dangling tool call.
      assert %Part.Retry{tool_name: "final_result", tool_call_id: "out1"} =
               find_part(messages, ExAgent.Message.Part.Retry)
    end

    test "invalid output that never recovers → error after retries exhausted" do
      model = %ExAgent.Models.Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "final_result", args: @invalid_args}]},
          {:tool_calls, [%Part.ToolCall{tool_name: "final_result", args: @invalid_args}]}
        ]
      }

      agent = ExAgent.new(model: model, output: WeatherReport, output_retries: 1)

      assert {:error, {:unexpected_model_behavior, {:output_retries_exhausted, _}}} =
               ExAgent.run(agent, "weather?")
    end

    test "text response in structured mode is ignored, model asked to call the tool" do
      model = %ExAgent.Models.Test{
        script: [
          "I think the weather is fine.",
          {:tool_calls, [%Part.ToolCall{tool_name: "final_result", args: @valid_args}]}
        ]
      }

      agent = ExAgent.new(model: model, output: WeatherReport, output_retries: 3)

      assert {:ok, %{output: %WeatherReport{city: "Madrid"}}} = ExAgent.run(agent, "weather?")
    end
  end

  describe "output tool is sent to providers" do
    test "the OpenAI adapter encodes output_tools in the tools payload" do
      model = %ExAgent.Models.Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "final_result", args: @valid_args}]}
        ]
      }

      agent = ExAgent.new(model: model, output: WeatherReport)

      # Build the params the agent would hand a provider, then encode.
      {:ok, %{messages: messages}} = ExAgent.run(agent, "weather?")

      # The first model response must have been a final_result tool call.
      assert Enum.any?(messages, fn
               %ExAgent.Message.Response{parts: parts} ->
                 Enum.any?(parts, &match?(%Part.ToolCall{tool_name: "final_result"}, &1))

               _ ->
                 false
             end)
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
