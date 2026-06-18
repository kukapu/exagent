defmodule ExAgent.IterationCTest do
  use ExUnit.Case, async: true

  alias ExAgent.{Model, Tool, UsageLimits}
  alias ExAgent.Message.Part

  # A capability that keeps only the last N messages sent to the model
  # (history processor — the canonical capability use case).
  defmodule HistoryWindow do
    use ExAgent.Capability
    defstruct [:n]

    @impl true
    def before_model_request(%__MODULE__{n: n}, state),
      do: %{state | request_messages: Enum.take(state.messages, -n)}
  end

  # A capability that collects tool results into a target process.
  defmodule ToolSpy do
    use ExAgent.Capability
    defstruct [:to]

    @impl true
    def after_tool_execute(%__MODULE__{to: to}, _ctx, tool_call, result) do
      send(to, {:tool_result, tool_call.tool_name, result})
      result
    end
  end

  describe "UsageLimits" do
    test "check_before_request returns :ok under the limits" do
      limits = %UsageLimits{request_limit: 5, total_tokens_limit: 1000}
      usage = %ExAgent.Message.Usage{input_tokens: 10, output_tokens: 5}

      assert :ok = UsageLimits.check_before_request(limits, usage, 1)
    end

    test "detects each kind of exceeded limit" do
      usage = %ExAgent.Message.Usage{input_tokens: 50, output_tokens: 30}

      assert {:error, {:usage_limit_exceeded, :request_limit, 3}} =
               UsageLimits.check_before_request(%UsageLimits{request_limit: 3}, usage, 3)

      assert {:error, {:usage_limit_exceeded, :total_tokens, 80}} =
               UsageLimits.check_before_request(%UsageLimits{total_tokens_limit: 80}, usage, 0)

      assert {:error, {:usage_limit_exceeded, :input_tokens, 50}} =
               UsageLimits.check_before_request(%UsageLimits{input_tokens_limit: 50}, usage, 0)
    end

    test "a looping run is stopped by request_limit" do
      call = %Part.ToolCall{tool_name: "noop", args: %{}}

      noop =
        Tool.new(
          name: "noop",
          description: "noop",
          parameters_json_schema: %{type: "object"},
          takes_ctx: false,
          call: fn _ -> {:ok, "x"} end
        )

      # model keeps calling the tool forever
      model = %ExAgent.Models.Test{
        script: [{:tool_calls, [call]}, {:tool_calls, [call]}, {:tool_calls, [call]}]
      }

      agent =
        ExAgent.new(model: model, tools: [noop], usage_limits: %UsageLimits{request_limit: 2})

      assert {:error, {:usage_limit_exceeded, :request_limit, 2}} = ExAgent.run(agent, "x")
    end
  end

  describe "ModelProfile" do
    test "TestModel returns a permissive default profile" do
      assert %ExAgent.ModelProfile{supports_tools: true} =
               Model.profile(%ExAgent.Models.Test{})
    end

    test "Anthropic advertises thinking support; OpenAI does not" do
      assert Model.profile(%ExAgent.Models.Anthropic{model: "x"}).supports_thinking == true
      assert Model.profile(%ExAgent.Models.OpenAI{model: "x"}).supports_thinking == false
    end

    test "OpenAI supports native JSON-schema output; Anthropic does not" do
      assert Model.profile(%ExAgent.Models.OpenAI{model: "x"}).supports_json_schema_output ==
               true

      assert Model.profile(%ExAgent.Models.Anthropic{model: "x"}).supports_json_schema_output ==
               false
    end
  end

  describe "Capabilities / hooks" do
    test "before_model_request can shrink the messages sent to the model" do
      parent = self()

      script = fn messages, _params ->
        send(parent, {:seen, length(messages)})
        "done"
      end

      model = %ExAgent.Models.Test{script: [script]}

      history =
        Enum.map(1..5, fn i ->
          ExAgent.Message.new_request([%Part.User{content: "m#{i}"}])
        end)

      agent =
        ExAgent.new(
          model: model,
          capabilities: [%HistoryWindow{n: 2}]
        )

      ExAgent.run(agent, "go", message_history: history)

      assert_received {:seen, 2}
    end

    test "after_tool_execute observes tool results" do
      add =
        Tool.new(
          name: "add",
          description: "add",
          parameters_json_schema: %{type: "object"},
          takes_ctx: false,
          call: fn %{"a" => a, "b" => b} -> {:ok, a + b} end
        )

      model = %ExAgent.Models.Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "add", args: %{"a" => 2, "b" => 3}}]},
          "done"
        ]
      }

      agent = ExAgent.new(model: model, tools: [add], capabilities: [%ToolSpy{to: self()}])
      {:ok, _} = ExAgent.run(agent, "x")

      assert_received {:tool_result, "add", {:ok, %Part.ToolReturn{content: 5}}}
    end

    test "a module capability via `use ExAgent.Capability` is a no-op until overridden" do
      defmodule NoOpCap do
        use ExAgent.Capability
      end

      model = %ExAgent.Models.Test{label: "ok"}
      agent = ExAgent.new(model: model, capabilities: [NoOpCap])
      assert {:ok, %{output: "ok"}} = ExAgent.run(agent, "x")
    end
  end
end
