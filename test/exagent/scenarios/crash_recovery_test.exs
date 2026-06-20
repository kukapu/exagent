defmodule ExAgent.Scenarios.CrashRecoveryTest do
  @moduledoc """
  Scenario 6 — durability and crash-recovery edge cases.

  `server_persistence_test.exs` and `store/postgres_test.exs` cover the happy
  rehydration paths per store. This scenario stresses the invariants that only
  matter in composition:

    * **cross-store portability** — a snapshot saved to ETS round-trips through
      Postgres unchanged (the dev→prod store migration),
    * a **tool-call conversation** survives Snapshot serialize/deserialize and
      can drive a fresh run (more Part types than plain text),
    * **reset → crash → rehydrate** starts empty (the empty checkpoint wins),
    * a **crash mid-run** rehydrates the last *completed* turn, not a partial.

  PG-specific tests carry the `:postgres` tag (auto-skipped without a DB).
  """

  use ExUnit.Case, async: true

  alias ExAgent.Message
  alias ExAgent.Message.{Part, Usage}
  alias ExAgent.Models.Test
  alias ExAgent.Server.Snapshot
  alias ExAgent.{Server, Store}

  @ets {ExAgent.Store.ETS, ExAgent.Store.ETS}
  @pg {ExAgent.Store.Postgres, ExAgent.TestRepo}

  describe "Snapshot round-trip of a tool-call conversation" do
    test "a history with ToolCall/ToolReturn survives and can continue a run" do
      add =
        ExAgent.Tool.new(
          name: "add",
          description: "add",
          parameters_json_schema: %{
            "type" => "object",
            "properties" => %{"a" => %{"type" => "integer"}, "b" => %{"type" => "integer"}}
          },
          takes_ctx: false,
          call: fn %{"a" => a, "b" => b} -> {:ok, a + b} end
        )

      model = %Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "add", args: %{"a" => 1, "b" => 2}}]},
          "first answer"
        ]
      }

      {:ok, %{messages: history}} = ExAgent.new(model: model, tools: [add]) |> ExAgent.run("go")

      # Serialize → deserialize → recover messages.
      snap =
        Snapshot.new(
          agent_id: "rt",
          history: history,
          usage: %Usage{input_tokens: 2, output_tokens: 2}
        )

      {:ok, recovered} = Snapshot.deserialize(Snapshot.serialize(snap))
      {:ok, messages} = Snapshot.messages(recovered)
      assert length(messages) == length(history)

      # The recovered history contains the ToolCall and its ToolReturn.
      parts = Message.parts(messages)
      assert Enum.any?(parts, &match?(%Part.ToolCall{tool_name: "add"}, &1))
      assert Enum.any?(parts, &match?(%Part.ToolReturn{tool_name: "add"}, &1))

      # A fresh run can continue from the recovered history.
      assert {:ok, %{output: "next"}} =
               ExAgent.new(model: %Test{label: "next"})
               |> ExAgent.run("follow up", message_history: messages)
    end
  end

  describe "reset → crash → rehydrate starts empty (ETS)" do
    test "the empty checkpoint wins over the prior conversation" do
      id = unique("reset_crash")
      name = :"agent_#{id}"

      {:ok, pid} =
        ExAgent.AgentSupervisor.start_agent(
          agent:
            ExAgent.new(model: %Test{script: ["one", "two", "three"]}, instructions: "be brief"),
          agent_id: id,
          store: :ets,
          name: name
        )

      assert {:ok, _} = Server.chat(name, "first")
      assert {:ok, _} = Server.chat(name, "second")
      assert length(Server.history(name)) == 4

      # Reset checkpoints an EMPTY snapshot.
      assert :ok = Server.reset(name)

      Process.exit(pid, :kill)
      assert wait_for_restart(name)

      # Rehydrated state is empty (reset won), not the 4-message conversation.
      assert Server.history(name) == []
      assert Server.usage(name).input_tokens == 0

      cleanup_ets(id)
      ExAgent.AgentSupervisor.stop_agent(Process.whereis(name))
    end
  end

  describe "crash mid-run rehydrates the last completed turn (ETS)" do
    test "a partial (un-checkpointed) run is not visible after restart" do
      id = unique("midrun_crash")
      name = :"agent_#{id}"

      # Two fast turns checkpoint; the third is a slow in-flight run we kill.
      {:ok, pid} =
        ExAgent.AgentSupervisor.start_agent(
          agent:
            ExAgent.new(
              model: %Test{
                script: [
                  "one",
                  "two",
                  fn ->
                    Process.sleep(2_000)
                    "slow"
                  end
                ]
              },
              instructions: "be brief"
            ),
          agent_id: id,
          store: :ets,
          name: name
        )

      # Two completed turns → checkpointed (history = 4).
      assert {:ok, _} = Server.chat(name, "first")
      assert {:ok, _} = Server.chat(name, "second")
      assert length(Server.history(name)) == 4

      # Start a slow async run, kill the server while it is in flight.
      {:ok, _} = Server.send_message(name, "slow")
      wait_for_status(name, :running)
      Process.exit(pid, :kill)

      assert wait_for_restart(name)

      # The in-flight run never checkpointed, so history is the last completed
      # turn (4 messages), not 5+ with a half-written partial.
      assert length(Server.history(name)) == 4

      cleanup_ets(id)
      ExAgent.AgentSupervisor.stop_agent(Process.whereis(name))
    end
  end

  describe "cross-store portability (ETS ↔ Postgres)" do
    @moduletag :postgres

    test "a snapshot saved to ETS round-trips through Postgres unchanged" do
      id = unique("xstore")

      # Produce a real conversation history (with a tool call).
      add =
        ExAgent.Tool.new(
          name: "add",
          description: "add",
          parameters_json_schema: %{type: "object", properties: %{}},
          takes_ctx: false,
          call: fn _ -> {:ok, 42} end
        )

      model = %Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "add", args: %{}}]},
          "done"
        ]
      }

      {:ok, %{messages: history, usage: usage}} =
        ExAgent.new(model: model, tools: [add]) |> ExAgent.run("go")

      snap = Snapshot.new(agent_id: id, history: history, usage: usage, metadata: %{from: "ets"})

      # ETS → load → PG → load. Same conversation each time.
      :ok = Store.save_agent_snapshot(@ets, snap)
      {:ok, from_ets} = Store.load_agent_snapshot(@ets, id)

      :ok = Store.save_agent_snapshot(@pg, from_ets)
      {:ok, from_pg} = Store.load_agent_snapshot(@pg, id)

      {:ok, msgs_ets} = Snapshot.messages(from_ets)
      {:ok, msgs_pg} = Snapshot.messages(from_pg)

      assert length(msgs_pg) == length(msgs_ets)
      assert from_pg.agent_id == id
      assert from_pg.metadata == %{"from" => "ets"}

      Store.delete_agent_snapshot(@ets, id)
      Store.delete_agent_snapshot(@pg, id)
    end
  end

  # ---------------------------------------------------------------------------
  defp unique(prefix), do: "#{prefix}_#{:erlang.unique_integer([:positive])}"

  defp cleanup_ets(id), do: Store.delete_agent_snapshot(@ets, id)

  defp wait_for_restart(name, tries \\ 400) do
    cond do
      tries <= 0 ->
        false

      Process.whereis(name) != nil and restart_ready?(name) ->
        true

      true ->
        Process.sleep(5)
        wait_for_restart(name, tries - 1)
    end
  end

  defp restart_ready?(name) do
    try do
      %{status: _} = Server.health(name)
      true
    rescue
      _ -> false
    catch
      :exit, _ -> false
    end
  end

  defp wait_for_status(server, status, tries \\ 100) do
    cond do
      tries <= 0 ->
        flunk("never reached #{inspect(status)}")

      Server.health(server).status == status ->
        :ok

      true ->
        Process.sleep(5)
        wait_for_status(server, status, tries - 1)
    end
  end
end
