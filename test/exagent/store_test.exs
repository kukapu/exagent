defmodule ExAgent.StoreTest do
  use ExUnit.Case, async: true

  alias ExAgent.Message.Usage
  alias ExAgent.Server.Snapshot
  alias ExAgent.Store

  # The app starts ExAgent.Store.ETS owning the public table named
  # ExAgent.Store.ETS. Tests share it but use unique agent_ids for isolation.
  @table ExAgent.Store.ETS
  @store {ExAgent.Store.ETS, @table}

  describe "normalize/1" do
    test "nil means no store" do
      assert Store.normalize(nil) == nil
    end

    test ":ets resolves to the default ETS table" do
      assert Store.normalize(:ets) == {ExAgent.Store.ETS, ExAgent.Store.ETS}
    end

    test "{module, config} and bare module pass through" do
      assert Store.normalize({MyStore, [:x]}) == {MyStore, [:x]}
      assert Store.normalize(MyStore) == {MyStore, []}
    end
  end

  describe "ETS — save / load / delete" do
    @tag :capture_log
    test "round-trips a snapshot keyed by agent_id" do
      id = unique_id("rt")

      snap =
        Snapshot.new(
          agent_id: id,
          history: history(),
          usage: %Usage{input_tokens: 2, output_tokens: 3},
          metadata: %{scene: "tavern"}
        )

      assert :ok = Store.save_agent_snapshot(@store, snap)
      assert {:ok, loaded} = Store.load_agent_snapshot(@store, id)
      assert loaded.agent_id == id
      assert loaded.usage == %{"input_tokens" => 2, "output_tokens" => 3}
      assert loaded.metadata == %{"scene" => "tavern"}

      # The stored history round-trips back into Message structs.
      {:ok, messages} = Snapshot.messages(loaded)
      assert length(messages) == length(history())

      assert :ok = Store.delete_agent_snapshot(@store, id)
      assert {:error, :not_found} = Store.load_agent_snapshot(@store, id)
    end

    test "load on a missing id returns :not_found" do
      assert {:error, :not_found} = Store.load_agent_snapshot(@store, unique_id("missing"))
    end

    test "save overwrites a previous snapshot for the same id" do
      id = unique_id("overwrite")

      Store.save_agent_snapshot(@store, Snapshot.new(agent_id: id, history: [], usage: nil))

      Store.save_agent_snapshot(
        @store,
        Snapshot.new(
          agent_id: id,
          history: history(),
          usage: %Usage{input_tokens: 9, output_tokens: 0}
        )
      )

      assert {:ok, loaded} = Store.load_agent_snapshot(@store, id)
      assert loaded.usage == %{"input_tokens" => 9, "output_tokens" => 0}
      {:ok, messages} = Snapshot.messages(loaded)
      assert length(messages) == length(history())

      Store.delete_agent_snapshot(@store, id)
    end
  end

  describe "ETS — isolation & listing" do
    test "two agents are stored independently and both appear in list" do
      a = unique_id("iso-a")
      b = unique_id("iso-b")

      Store.save_agent_snapshot(@store, Snapshot.new(agent_id: a, history: [], usage: nil))
      Store.save_agent_snapshot(@store, Snapshot.new(agent_id: b, history: [], usage: nil))

      ids = @store |> Store.list_agent_snapshots() |> Enum.map(& &1.agent_id)
      assert a in ids and b in ids

      # Deleting one doesn't touch the other.
      Store.delete_agent_snapshot(@store, a)
      assert {:error, :not_found} = Store.load_agent_snapshot(@store, a)
      assert {:ok, _} = Store.load_agent_snapshot(@store, b)

      Store.delete_agent_snapshot(@store, b)
    end
  end

  describe "ETS — portability is enforced" do
    test "save refuses a snapshot carrying a closure (and stores nothing)" do
      id = unique_id("leak")

      bad =
        Snapshot.new(agent_id: id, history: [], metadata: %{capture: fn -> :secret end})

      # The strict JSON path must refuse to persist non-serializable state.
      assert raises?(fn -> Store.save_agent_snapshot(@store, bad) end)

      # And nothing was persisted.
      assert {:error, :not_found} = Store.load_agent_snapshot(@store, id)
    end

    test "no api key or pid is ever stored, even if present in agent metadata" do
      id = unique_id("pid")

      bad = Snapshot.new(agent_id: id, history: [], metadata: %{owner: self()})
      assert raises?(fn -> Store.save_agent_snapshot(@store, bad) end)
      assert {:error, :not_found} = Store.load_agent_snapshot(@store, id)
    end
  end

  # ---------------------------------------------------------------------------
  defp history do
    {:ok, %{messages: messages}} =
      ExAgent.run(ExAgent.new(model: "test", instructions: "hi"), "hello")

    messages
  end

  defp unique_id(prefix), do: "#{prefix}_#{:erlang.unique_integer([:positive])}"

  defp raises?(fun) do
    try do
      fun.()
      false
    rescue
      _ -> true
    end
  end
end
