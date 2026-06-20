defmodule ExAgent.Scenarios.SupportAgentTest do
  @moduledoc """
  Scenario 1 — a one-shot "support ticket classifier" agent.

  Composes the core loop with: `deftool` + `Tool.new`, structured output via an
  Ecto schema (with a validation retry), a tool that *contributes token usage*,
  `ExAgent.CostGuard` halting a runaway budget, a `Capability` that spies on
  tool results, `ExAgent.UsageLimits.tool_calls_limit`, and a `:deny`
  permission blocking a destructive tool.

  Everything runs offline against `ExAgent.Models.Test`.
  """

  use ExUnit.Case, async: true

  alias ExAgent.Message.Part
  alias ExAgent.Message.Usage
  alias ExAgent.Models.Test
  alias ExAgent.{CostGuard, Permissions, Tool, UsageLimits}

  # A capability that collects every tool result into a target process.
  defmodule ToolSpy do
    use ExAgent.Capability
    defstruct [:to]

    @impl true
    def after_tool_execute(%__MODULE__{to: to}, _ctx, tool_call, result) do
      send(to, {:spied, tool_call.tool_name, result})
      result
    end
  end

  # Tools declared with `use ExAgent.Tools` (deftool + tool_plain).
  defmodule SupportTools do
    use ExAgent.Tools

    @doc "Look up a customer by id and return their plan."
    deftool lookup_user(_ctx, user_id :: integer()) do
      {:ok, "user #{user_id} is on the pro plan"}
    end
  end

  describe "structured output via Ecto schema (happy + retry path)" do
    test "model calls a function tool, then the final_result tool → validated struct" do
      # The model: first looks the user up, then returns the classified ticket.
      model = %Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "lookup_user", args: %{"user_id" => 42}}]},
          {:tool_calls,
           [
             %Part.ToolCall{
               tool_name: "final_result",
               args: %{"category" => "billing", "priority" => 2, "summary" => "refund please"}
             }
           ]}
        ]
      }

      agent =
        ExAgent.new(
          model: model,
          output: ExAgent.Test.Ticket,
          tools: SupportTools.tools()
        )

      assert {:ok, %{output: ticket, usage: usage, messages: messages}} =
               ExAgent.run(agent, "I want a refund")

      # Structured output is a validated struct, not a raw map.
      assert %ExAgent.Test.Ticket{category: "billing", priority: 2, summary: "refund please"} =
               ticket

      # The function tool actually ran (its ToolReturn is in the history).
      assert find_tool_return(messages, "lookup_user") =~ "pro plan"

      # Usage accumulated across the two model requests (TestModel reports 1/1).
      assert usage.input_tokens > 0 and usage.output_tokens > 0
    end

    test "invalid output args trigger one retry, then a valid call succeeds" do
      model = %Test{
        script: [
          # Bad category — the changeset rejects it → loop retries.
          {:tool_calls,
           [
             %Part.ToolCall{
               tool_name: "final_result",
               args: %{"category" => "nope", "priority" => 9, "summary" => "x"}
             }
           ]},
          # Valid on the second attempt.
          {:tool_calls,
           [
             %Part.ToolCall{
               tool_name: "final_result",
               args: %{"category" => "bug", "priority" => 3, "summary" => "it crashes"}
             }
           ]}
        ]
      }

      agent =
        ExAgent.new(
          model: model,
          output: ExAgent.Test.Ticket,
          output_retries: 2
        )

      assert {:ok, %{output: ticket}} = ExAgent.run(agent, "report a bug")
      assert %ExAgent.Test.Ticket{category: "bug", priority: 3} = ticket
    end

    test "exhausting output_retries surfaces an error (model never gets it right)" do
      model = %Test{
        script: [
          {:tool_calls,
           [%Part.ToolCall{tool_name: "final_result", args: %{"category" => "bad"}}]},
          {:tool_calls,
           [%Part.ToolCall{tool_name: "final_result", args: %{"category" => "worse"}}]}
        ]
      }

      agent = ExAgent.new(model: model, output: ExAgent.Test.Ticket, output_retries: 1)

      assert {:error, {:unexpected_model_behavior, {:output_retries_exhausted, _}}} =
               ExAgent.run(agent, "x")
    end
  end

  describe "tools that contribute token usage" do
    test "a tool returning {:ok, value, %Usage{}} merges into the run usage" do
      # A tool built by hand that contributes sub-agent-like usage.
      delegate =
        Tool.new(
          name: "summarize",
          description: "summarize",
          parameters_json_schema: %{type: "object", properties: %{}},
          takes_ctx: false,
          call: fn _ ->
            {:ok, "done", %Usage{input_tokens: 40, output_tokens: 10}}
          end
        )

      model = %Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "summarize", args: %{}}]},
          "ok"
        ]
      }

      agent = ExAgent.new(model: model, tools: [delegate])

      assert {:ok, %{usage: usage}} = ExAgent.run(agent, "go")
      # 2 model requests (1/1 each) + 40/10 contributed by the tool.
      assert usage.input_tokens >= 42 and usage.output_tokens >= 12
    end
  end

  describe "CostGuard halts a runaway budget" do
    test "max_budget_cents stops the loop before the next request" do
      # A model that would loop forever calling a tool.
      noop =
        Tool.new(
          name: "noop",
          description: "noop",
          parameters_json_schema: %{type: "object", properties: %{}},
          takes_ctx: false,
          call: fn _ -> {:ok, "x"} end
        )

      model = %Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "noop", args: %{}}]},
          {:tool_calls, [%Part.ToolCall{tool_name: "noop", args: %{}}]},
          {:tool_calls, [%Part.ToolCall{tool_name: "noop", args: %{}}]}
        ]
      }

      # Absurdly expensive pricing → even one request blows a 5-cent budget.
      pricing =
        CostGuard.estimator(%{input_per_1k_cents: 1_000_000, output_per_1k_cents: 1_000_000})

      agent =
        ExAgent.new(
          model: model,
          tools: [noop],
          usage_limits: %UsageLimits{max_budget_cents: 5, request_limit: 50}
        )

      assert {:error, {:usage_limit_exceeded, :budget_cents, cents}} =
               ExAgent.run(agent, "loop", estimate_cost: pricing)

      assert cents > 5
    end
  end

  describe "tool_calls_limit blocks an over-sized batch" do
    test "a parallel batch that would exceed the limit runs nothing" do
      a = tool("a")
      b = tool("b")
      c = tool("c")

      model = %Test{
        script: [
          {:tool_calls,
           [
             %Part.ToolCall{tool_name: "a", args: %{}},
             %Part.ToolCall{tool_name: "b", args: %{}},
             %Part.ToolCall{tool_name: "c", args: %{}}
           ]}
        ]
      }

      agent =
        ExAgent.new(
          model: model,
          tools: [a, b, c],
          usage_limits: %UsageLimits{tool_calls_limit: 2}
        )

      assert {:error, {:usage_limit_exceeded, :tool_calls, 3}} = ExAgent.run(agent, "x")
    end
  end

  describe "Capability spies on tool results" do
    test "after_tool_execute observes every function tool call" do
      model = %Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "lookup_user", args: %{"user_id" => 7}}]},
          "done"
        ]
      }

      agent =
        ExAgent.new(
          model: model,
          tools: SupportTools.tools(),
          capabilities: [%ToolSpy{to: self()}]
        )

      assert {:ok, _} = ExAgent.run(agent, "go")
      assert_received {:spied, "lookup_user", {:ok, %Part.ToolReturn{content: msg}}}
      assert msg =~ "pro plan"
    end
  end

  describe "permission :deny blocks a destructive tool" do
    test "a denied tool returns 'not permitted' and the model still finishes" do
      delete =
        Tool.new(
          name: "delete_account",
          description: "delete",
          parameters_json_schema: %{type: "object", properties: %{}},
          takes_ctx: false,
          call: fn _ -> {:ok, "DELETED"} end
        )

      model = %Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "delete_account", args: %{}}]},
          "could not delete"
        ]
      }

      perms = Permissions.new!(rules: [{"*", :allow}, {"delete_*", :deny}])
      agent = ExAgent.new(model: model, tools: [delete])

      assert {:ok, %{messages: messages}} =
               ExAgent.run(agent, "delete it", permissions: perms)

      assert find_tool_return(messages, "delete_account") =~ "not permitted"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp tool(name) do
    Tool.new(
      name: name,
      description: name,
      parameters_json_schema: %{type: "object", properties: %{}},
      takes_ctx: false,
      call: fn _ -> {:ok, name} end
    )
  end

  defp find_tool_return(messages, name) do
    Enum.find_value(messages, fn
      %ExAgent.Message.Request{parts: parts} ->
        Enum.find_value(parts, fn
          %Part.ToolReturn{tool_name: ^name, content: c} -> c
          _ -> nil
        end)

      _ ->
        nil
    end)
  end
end
