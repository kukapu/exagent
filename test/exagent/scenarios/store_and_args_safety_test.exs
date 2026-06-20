defmodule ExAgent.Scenarios.StoreAndArgsSafetyTest do
  @moduledoc """
  Regression tests for:
    * checkpoint / rehydrate failures are now LOGGED (not silently swallowed),
      so non-encodable metadata or a broken store doesn't invisibly disable
      all persistence.
    * `Part.ToolCall.args_as_map/1` has a catch-all so a non-conforming args
      value yields {:error, _} instead of FunctionClauseError.
  """

  use ExUnit.Case, async: true

  alias ExAgent.Message.Part
  alias ExAgent.Models.Test
  alias ExAgent.{Server, Store}

  import ExUnit.CaptureLog

  describe "checkpoint failure is logged, not silent" do
    @tag :capture_log
    test "non-encodable metadata logs a warning and keeps the server running" do
      id = "ckpt-log-#{:erlang.unique_integer([:positive])}"

      logs =
        capture_log(fn ->
          {:ok, server} =
            Server.start_link(
              agent: ExAgent.new(model: %Test{label: "ok"}, instructions: "be brief"),
              agent_id: id,
              store: :ets,
              metadata: %{renderer: fn _ -> :ok end}
            )

          # A run completes; checkpoint raises on the closure in metadata.
          assert {:ok, _} = Server.chat(server, "go")
          # The server is still alive and usable.
          assert %{status: :idle} = Server.health(server)

          Store.delete_agent_snapshot({ExAgent.Store.ETS, ExAgent.Store.ETS}, id)
        end)

      assert logs =~ "checkpoint failed"
    end
  end

  describe "args_as_map catch-all" do
    test "an integer args value returns {:error, _} instead of raising" do
      assert {:error, {:unsupported_args_type, 42}} =
               Part.ToolCall.args_as_map(%Part.ToolCall{
                 tool_name: "f",
                 args: 42,
                 tool_call_id: "i"
               })
    end

    test "a list args value returns {:error, _}" do
      assert {:error, {:unsupported_args_type, [1, 2]}} =
               Part.ToolCall.args_as_map(%Part.ToolCall{
                 tool_name: "f",
                 args: [1, 2],
                 tool_call_id: "i"
               })
    end
  end
end
