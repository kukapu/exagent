defmodule ExAgent.Scenarios.CoreLoopSafetyTest do
  @moduledoc """
  Regression tests for core-loop robustness found by the bug-hunting pass:

    * a tool task that raises (malformed args, buggy capability) MUST NOT crash
      the caller — run/3 must still return {:error, _} (the linked-task EXIT
      used to propagate and kill the agent process),
    * a user changeset that raises on its input MUST surface as a retryable
      validation error, not crash the run,
    * `:max_steps` is now configurable (was hardcoded to 50, silently ignored).
  """

  use ExUnit.Case, async: true

  alias ExAgent.Message.Part
  alias ExAgent.Models.Test

  describe "a raising tool task does not crash the caller" do
    test "malformed tool_call args (integer) → run returns {:error, _}, not EXIT" do
      # args_as_map/1 raises FunctionClauseError on a non-nil/map/binary value.
      model = %Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "f", args: 42, tool_call_id: "i"}]},
          "final"
        ]
      }

      tool =
        ExAgent.Tool.new(
          name: "f",
          description: "f",
          parameters_json_schema: %{type: "object", properties: %{}},
          takes_ctx: false,
          call: fn _ -> {:ok, "ok"} end
        )

      agent = ExAgent.new(model: model, tools: [tool])

      # Before the fix this printed "** (EXIT from ...)" and killed the process.
      # Now the failure is contained: the tool is retried within budget, the
      # model moves on, and run/3 returns its normal {:ok,_}|{:error,_} shape.
      assert {:ok, %{output: "final"}} = ExAgent.run(agent, "go")
    end

    test "a capability that raises in before_tool_execute is contained" do
      defmodule BoomCap do
        use ExAgent.Capability

        @impl true
        def before_tool_execute(_, _ctx, _call), do: raise("boom in capability")
      end

      model = %Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "f", args: %{}, tool_call_id: "i"}]},
          "final"
        ]
      }

      tool =
        ExAgent.Tool.new(
          name: "f",
          description: "f",
          parameters_json_schema: %{type: "object", properties: %{}},
          takes_ctx: false,
          call: fn _ -> {:ok, "ok"} end
        )

      agent = ExAgent.new(model: model, tools: [tool], capabilities: [BoomCap])

      assert {:ok, %{output: "final"}} = ExAgent.run(agent, "go")
    end
  end

  describe "a user changeset that raises surfaces as a retryable error" do
    test "changeset raising on input does not crash the run" do
      defmodule Fragile do
        use Ecto.Schema
        @primary_key false
        embedded_schema do
          field(:v, :string)
        end

        # A reasonable "assume the key is present" style that raises on %{}.
        def changeset(_schema, attrs) do
          _ = Map.fetch!(attrs, :forced_key)
          Ecto.Changeset.cast(struct(__MODULE__), attrs, [:v])
        end
      end

      model = %Test{
        script: [
          {:tool_calls,
           [%Part.ToolCall{tool_name: "final_result", args: %{"v" => "x"}, tool_call_id: "o"}]},
          {:tool_calls,
           [%Part.ToolCall{tool_name: "final_result", args: %{"v" => "y"}, tool_call_id: "o2"}]}
        ]
      }

      agent = ExAgent.new(model: model, output: Fragile, output_retries: 1)

      # Before the fix this raised KeyError. Now it's a retryable validation
      # error that exhausts retries and returns a clean error.
      assert {:error, {:unexpected_model_behavior, {:output_retries_exhausted, _}}} =
               ExAgent.run(agent, "go")
    end
  end

  describe ":max_steps is configurable" do
    test "a lower max_steps trips the guard earlier than the default 50" do
      call = %Part.ToolCall{tool_name: "loop", args: %{}}

      tool =
        ExAgent.Tool.new(
          name: "loop",
          description: "loop",
          parameters_json_schema: %{type: "object", properties: %{}},
          takes_ctx: false,
          call: fn _ -> {:ok, "again"} end
        )

      # Model would call the tool forever.
      forever = {:tool_calls, [call]}
      model = %Test{script: List.duplicate(forever, 50)}

      agent = ExAgent.new(model: model, tools: [tool], max_steps: 3)

      assert {:error, {:max_steps_exceeded, 3}} = ExAgent.run(agent, "go")
    end
  end
end
