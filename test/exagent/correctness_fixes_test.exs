defmodule ExAgent.CorrectnessFixesTest do
  use ExUnit.Case, async: true

  # Tests locking in the iteration-A correctness fixes against ExAgent's intent.
  alias ExAgent.{Tool}
  alias ExAgent.Message, as: Msg
  alias ExAgent.Message.{Part, Usage}
  alias ExAgent.Test.WeatherReport

  defp find_part(messages, mod) do
    matcher = fn
      %struct{} = part -> if struct == mod, do: part, else: nil
      _ -> nil
    end

    Enum.find_value(messages, fn
      %Msg.Request{parts: parts} -> Enum.find_value(parts, matcher)
      %Msg.Response{parts: parts} -> Enum.find_value(parts, matcher)
      _ -> nil
    end)
  end

  describe "per-tool retry budget (BUG 1)" do
    test "a persistently-failing tool terminates at its max_retries, not max_steps" do
      always_fail =
        Tool.new(
          name: "boom",
          description: "always fails",
          parameters_json_schema: %{type: "object"},
          takes_ctx: false,
          call: fn _args -> {:error, "kaboom"} end
        )

      # model keeps re-calling the failing tool
      call = %Part.ToolCall{tool_name: "boom", args: %{}}

      model = %ExAgent.Models.Test{
        script: [
          {:tool_calls, [call]},
          {:tool_calls, [call]},
          {:tool_calls, [call]}
        ]
      }

      agent = ExAgent.new(model: model, tools: [always_fail])

      # max_retries defaults to 1 → 1 failure tolerated, 2nd consecutive failure errors.
      assert {:error, {:unexpected_model_behavior, {:tool_retries_exhausted, "boom", _}}} =
               ExAgent.run(agent, "x")
    end

    test "a tool that raises ModelRetry is treated as a retryable failure" do
      retrier =
        Tool.new(
          name: "flaky",
          description: "raises ModelRetry",
          parameters_json_schema: %{type: "object"},
          takes_ctx: false,
          call: fn _args -> raise(ExAgent.ModelRetry, "please try again") end
        )

      model = %ExAgent.Models.Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "flaky", args: %{}}]},
          "recovered"
        ]
      }

      agent = ExAgent.new(model: model, tools: [retrier], output_retries: 5)
      assert {:ok, %{output: "recovered"}} = ExAgent.run(agent, "x")
    end
  end

  describe "dangling tool calls / replayable history (BUG 2)" do
    @valid ~s({"city":"Madrid","temp_c":22.0,"condition":"sunny"})
    @invalid ~s({"city":"Madrid","temp_c":200})

    test "a valid output call appends a ToolReturn so history is replayable" do
      model = %ExAgent.Models.Test{
        script: [{:tool_calls, [%Part.ToolCall{tool_name: "final_result", args: @valid}]}]
      }

      agent = ExAgent.new(model: model, output: WeatherReport)
      {:ok, %{messages: messages}} = ExAgent.run(agent, "w")

      assert %Part.ToolReturn{tool_name: "final_result"} = find_part(messages, Part.ToolReturn)
    end

    test "sibling function calls get stub returns when a final result is also present" do
      fn_tool =
        Tool.new(
          name: "lookup",
          description: "some fn tool",
          parameters_json_schema: %{type: "object"},
          takes_ctx: false,
          call: fn _ -> {:ok, "x"} end
        )

      model = %ExAgent.Models.Test{
        script: [
          {:tool_calls,
           [
             %Part.ToolCall{tool_name: "final_result", args: @valid, tool_call_id: "out1"},
             %Part.ToolCall{tool_name: "lookup", args: %{}, tool_call_id: "fn1"}
           ]}
        ]
      }

      agent = ExAgent.new(model: model, output: WeatherReport, tools: [fn_tool])
      {:ok, %{output: %WeatherReport{}, messages: messages}} = ExAgent.run(agent, "w")

      returns =
        Enum.filter(Msg.parts(messages), &match?(%Part.ToolReturn{}, &1))
        |> Enum.map(& &1.tool_name)
        |> MapSet.new()

      # both the output tool and the un-executed sibling got a return (no dangling call)
      assert MapSet.subset?(MapSet.new(["final_result", "lookup"]), returns)
    end

    test "validation retries also stub sibling tool calls" do
      fn_tool =
        Tool.new(
          name: "lookup",
          description: "some fn tool",
          parameters_json_schema: %{type: "object"},
          takes_ctx: false,
          call: fn _ -> {:ok, "x"} end
        )

      assert_retry_history = fn messages, _params ->
        parts = Msg.parts(messages)

        assert Enum.any?(parts, fn
                 %Part.Retry{tool_name: "final_result", tool_call_id: "out1"} -> true
                 _ -> false
               end)

        assert Enum.any?(parts, fn
                 %Part.ToolReturn{tool_name: "lookup", tool_call_id: "fn1"} -> true
                 _ -> false
               end)

        {:tool_calls,
         [%Part.ToolCall{tool_name: "final_result", args: @valid, tool_call_id: "out2"}]}
      end

      model = %ExAgent.Models.Test{
        script: [
          {:tool_calls,
           [
             %Part.ToolCall{tool_name: "final_result", args: @invalid, tool_call_id: "out1"},
             %Part.ToolCall{tool_name: "lookup", args: %{}, tool_call_id: "fn1"}
           ]},
          assert_retry_history
        ]
      }

      agent =
        ExAgent.new(model: model, output: WeatherReport, tools: [fn_tool], output_retries: 2)

      assert {:ok, %{output: %WeatherReport{}}} = ExAgent.run(agent, "w")
    end
  end

  describe "finish_reason edge cases (BUG 3)" do
    test ":length -> max_tokens error instead of looping" do
      truncated = fn -> Msg.new_response([], finish_reason: :length, model_name: "m") end

      model = %ExAgent.Models.Test{script: [truncated, truncated]}
      agent = ExAgent.new(model: model, output_retries: 3)

      assert {:error, {:max_tokens_exceeded, "m"}} = ExAgent.run(agent, "x")
    end

    test ":content_filter -> error" do
      filtered = fn -> Msg.new_response([], finish_reason: :content_filter, model_name: "m") end

      model = %ExAgent.Models.Test{script: [filtered]}
      agent = ExAgent.new(model: model)

      assert {:error, {:content_filter, "m"}} = ExAgent.run(agent, "x")
    end
  end

  describe "new_messages is the delta, not the whole history (BUG 5)" do
    test "with a prior message_history" do
      prior = [
        Msg.new_request([%Part.User{content: "earlier"}]),
        Msg.new_response([%Part.Text{content: "hi"}])
      ]

      model = %ExAgent.Models.Test{label: "ok"}
      agent = ExAgent.new(model: model)

      {:ok, %{messages: all, new_messages: new}} =
        ExAgent.run(agent, "again", message_history: prior)

      assert length(new) < length(all)
      # the prior history is excluded from new_messages
      refute Enum.take(new, 2) == prior
    end

    test "without history, new == all" do
      model = %ExAgent.Models.Test{label: "ok"}
      agent = ExAgent.new(model: model)
      {:ok, %{messages: all, new_messages: new}} = ExAgent.run(agent, "x")
      assert all == new
    end
  end

  describe "usage.details are summed across responses (BUG 6)" do
    test "details with the same key accumulate" do
      fn_tool =
        Tool.new(
          name: "t",
          description: "t",
          parameters_json_schema: %{type: "object"},
          takes_ctx: false,
          call: fn _ -> {:ok, "x"} end
        )

      r1 =
        fn ->
          Msg.new_response([%Part.ToolCall{tool_name: "t", args: %{}}],
            usage: %Usage{input_tokens: 1, output_tokens: 1, details: %{"total_tokens" => 5}}
          )
        end

      r2 =
        fn ->
          Msg.new_response([%Part.Text{content: "done"}],
            usage: %Usage{input_tokens: 1, output_tokens: 1, details: %{"total_tokens" => 7}}
          )
        end

      model = %ExAgent.Models.Test{script: [r1, r2]}
      agent = ExAgent.new(model: model, tools: [fn_tool])

      {:ok, %{usage: usage}} = ExAgent.run(agent, "x")

      assert usage.details == %{"total_tokens" => 12}
    end
  end
end
