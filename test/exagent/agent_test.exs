defmodule ExAgent.AgentTest do
  use ExUnit.Case, async: true

  alias ExAgent.{Tool, UsageLimits}
  alias ExAgent.Message.{Part, Request, Response, Usage}

  describe "text agent (no tools)" do
    test "returns the model text response" do
      agent = ExAgent.new(model: "test", instructions: "be concise")

      assert {:ok, %{output: "a test response"}} = ExAgent.run(agent, "hi")
    end

    test "threads instructions into the first request" do
      agent = ExAgent.new(model: "test", instructions: "you are helpful")

      {:ok, %{messages: messages}} = ExAgent.run(agent, "hi")

      assert %Request{
               parts: [%Part.System{content: "you are helpful"}, %Part.User{content: "hi"} | _]
             } =
               hd(messages)
    end

    test "records usage" do
      agent = ExAgent.new(model: "test")
      {:ok, %{usage: usage}} = ExAgent.run(agent, "hi")
      assert usage.input_tokens > 0 and usage.output_tokens > 0
    end
  end

  describe "tool calling" do
    setup do
      weather =
        Tool.new(
          name: "get_weather",
          description: "Get the weather for a city",
          parameters_json_schema: %{
            type: "object",
            properties: %{city: %{type: "string"}},
            required: ["city"]
          },
          takes_ctx: false,
          call: fn %{"city" => city} -> {:ok, "sunny in #{city}"} end
        )

      %{weather: weather}
    end

    test "calls the tool, feeds the return back, then finalizes", %{weather: weather} do
      model = %ExAgent.Models.Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "get_weather", args: ~s({"city":"Madrid"})}]},
          "Final answer"
        ]
      }

      agent = ExAgent.new(model: model, tools: [weather])

      assert {:ok, %{output: "Final answer", messages: messages}} = ExAgent.run(agent, "weather?")

      # the conversation must contain: request, tool-call response, tool-return request, final response
      kinds = Enum.map(messages, & &1.__struct__)

      assert kinds == [
               Request,
               Response,
               Request,
               Response
             ]

      tool_return =
        Enum.find_value(messages, fn
          %Request{parts: parts} -> Enum.find(parts, &match?(%Part.ToolReturn{}, &1))
          _ -> nil
        end)

      assert %Part.ToolReturn{tool_name: "get_weather", content: "sunny in Madrid"} = tool_return
    end

    test "passes the RunContext to a tool that takes ctx" do
      ctx_tool =
        Tool.new(
          name: "whoami",
          description: "Echo the dep",
          parameters_json_schema: %{type: "object", properties: %{}},
          takes_ctx: true,
          call: fn ctx, _args -> {:ok, ctx.deps.name} end
        )

      model = %ExAgent.Models.Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "whoami", args: %{}}]},
          "done"
        ]
      }

      agent = ExAgent.new(model: model, tools: [ctx_tool])

      assert {:ok, %{messages: messages}} =
               ExAgent.run(agent, "who?", deps: %{name: "Kukapu"})

      assert %Part.ToolReturn{content: "Kukapu"} =
               find_part(messages, ExAgent.Message.Part.ToolReturn)
    end

    test "turns invalid tool args into a retry prompt to the model", context do
      weather = context.weather

      model = %ExAgent.Models.Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "get_weather", args: "not valid json {"}]},
          "recovered"
        ]
      }

      agent = ExAgent.new(model: model, tools: [weather])

      assert {:ok, %{output: "recovered", messages: messages}} = ExAgent.run(agent, "weather?")

      assert %Part.Retry{tool_name: "get_weather"} =
               find_part(messages, ExAgent.Message.Part.Retry)
    end
  end

  describe "tools contributing usage" do
    test "a tool returning {:ok, value, %Usage{}} merges into the run usage" do
      costly =
        Tool.new(
          name: "costly",
          description: "A tool that does its own LLM work and reports usage",
          parameters_json_schema: %{type: "object", properties: %{}},
          takes_ctx: false,
          call: fn _args ->
            {:ok, "expensive result", %Usage{input_tokens: 50, output_tokens: 50}}
          end
        )

      model = %ExAgent.Models.Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "costly", args: %{}}]},
          "final answer"
        ]
      }

      agent = ExAgent.new(model: model, tools: [costly])

      assert {:ok, %{output: "final answer", usage: usage}} = ExAgent.run(agent, "go")

      # Parent made two model requests (1/1 each from the TestModel) plus the
      # tool's contributed 50/50.
      assert usage.input_tokens == 52
      assert usage.output_tokens == 52
    end
  end

  describe "limits" do
    test "fails when the output retry budget is exhausted" do
      # a model that always answers with nothing actionable
      empty = fn -> ExAgent.Message.new_response([], model_name: "test") end

      # script is consumed then falls back; keep feeding empty by repeating it.
      model = %ExAgent.Models.Test{script: [empty, empty, empty, empty]}

      agent =
        ExAgent.new(
          model: model,
          output_retries: 0
        )

      assert {:error, {:unexpected_model_behavior, {:output_retries_exhausted, _}}} =
               ExAgent.run(agent, "loop?")
    end

    test "tool_calls_limit rejects a batch that would exceed it (none run)" do
      echo =
        Tool.new(
          name: "echo",
          description: "echo",
          parameters_json_schema: %{type: "object", properties: %{}},
          takes_ctx: false,
          call: fn _ -> {:ok, "ok"} end
        )

      model = %ExAgent.Models.Test{
        script: [
          {:tool_calls,
           [
             %Part.ToolCall{tool_name: "echo", args: %{}},
             %Part.ToolCall{tool_name: "echo", args: %{}},
             %Part.ToolCall{tool_name: "echo", args: %{}}
           ]},
          "final"
        ]
      }

      agent =
        ExAgent.new(model: model, tools: [echo], usage_limits: %UsageLimits{tool_calls_limit: 2})

      assert {:error, {:usage_limit_exceeded, :tool_calls, 3}} = ExAgent.run(agent, "go")
    end

    test "max_budget_cents halts the run via an estimate_cost function" do
      echo =
        Tool.new(
          name: "echo",
          description: "echo",
          parameters_json_schema: %{type: "object", properties: %{}},
          takes_ctx: false,
          call: fn _ -> {:ok, "ok"} end
        )

      model = %ExAgent.Models.Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "echo", args: %{}}]},
          {:tool_calls, [%Part.ToolCall{tool_name: "echo", args: %{}}]},
          {:tool_calls, [%Part.ToolCall{tool_name: "echo", args: %{}}]},
          "final"
        ]
      }

      agent =
        ExAgent.new(model: model, tools: [echo], usage_limits: %UsageLimits{max_budget_cents: 2})

      # 1 cent per input token; the TestModel reports 1 input token per response.
      assert {:error, {:usage_limit_exceeded, :budget_cents, 2}} =
               ExAgent.run(agent, "go", estimate_cost: fn u -> u.input_tokens end)
    end

    test "CostGuard.estimator/1 converts pricing into a cost function" do
      estimator =
        ExAgent.CostGuard.estimator(%{input_per_1k_cents: 250, output_per_1k_cents: 1000})

      # 1000 input + 500 output tokens = 250 + 500 = 750 cents ($7.50).
      assert estimator.(%Usage{input_tokens: 1000, output_tokens: 500}) == 750
    end
  end

  defp find_part(messages, mod) do
    matcher = fn
      %struct{} = part -> if struct == mod, do: part, else: nil
      _ -> nil
    end

    Enum.find_value(messages, fn
      %Request{parts: parts} -> Enum.find_value(parts, matcher)
      %Response{parts: parts} -> Enum.find_value(parts, matcher)
      _ -> nil
    end)
  end
end
