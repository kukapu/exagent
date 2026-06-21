defmodule ExAgent.SessionPersistenceTest do
  @moduledoc """
  `ExAgent.Session` checkpoints its coordination state (shared_state + turn
  position + status + roster) to a store and rehydrates on restart — the
  session counterpart to `ExAgent.Server`'s persistence. The live participant
  `ref`s come from the app on restart; only the serializable parts restore.
  """

  use ExUnit.Case, async: false

  alias ExAgent.{Session, Store}
  alias ExAgent.Session.{Participant, Snapshot}

  @ets {ExAgent.Store.ETS, ExAgent.Store.ETS}

  describe "snapshot serialize/deserialize round-trip" do
    test "shared_state + policy_state + current survive strict JSON" do
      # Build a real Session.State-shaped snapshot via a live session, then
      # round-trip it through serialize/deserialize.
      {:ok, session} =
        Session.start_link(
          shared_state: %{scene: "tavern", log: ["a", "b"]},
          policy: {:initiative, order: ["rogue", "wizard"]},
          participants: [Participant.new(id: "rogue"), Participant.new(id: "wizard")],
          session_id: "rt-#{unique()}"
        )

      {:ok, "rogue"} = Session.start(session)

      {:ok, _, "wizard"} =
        Session.take_turn(session, "rogue", fn s -> {:ok, %{s | scene: "crypt"}} end)

      state = :sys.get_state(session)
      snap = Snapshot.new(state)
      json = Snapshot.serialize(snap)
      assert byte_size(json) > 0

      assert {:ok, recovered} = Snapshot.deserialize(json)
      assert recovered.session_id == state.session_id
      # Atom keys round-trip as strings (strict JSON); shared_state is a map.
      assert recovered.shared_state["scene"] == "crypt"
      assert recovered.current == "wizard"
      assert recovered.policy_mod == ExAgent.Session.TurnPolicy.Initiative
      # The policy struct round-tripped (Initiative keeps index/current).
      assert is_struct(recovered.policy_state, ExAgent.Session.TurnPolicy.Initiative)
      assert recovered.policy_state.current == "wizard"
    end

    test "a non-serializable shared_state is refused (strict JSON)" do
      {:ok, session} =
        Session.start_link(
          shared_state: %{oops: fn -> :secret end},
          participants: [Participant.new(id: "a")],
          session_id: "bad-#{unique()}"
        )

      state = :sys.get_state(session)

      assert_raise Protocol.UndefinedError, fn ->
        Snapshot.serialize(Snapshot.new(state))
      end
    end
  end

  describe "rehydrate across a restart (ETS)" do
    test "a fresh session restores shared_state + current + status" do
      id = "reh-#{unique()}"

      # First session: advance a couple turns.
      {:ok, a} =
        Session.start_link(
          shared_state: %{log: []},
          policy: :round_robin,
          participants: [Participant.new(id: "x"), Participant.new(id: "y")],
          session_id: id,
          store: :ets
        )

      {:ok, "x"} = Session.start(a)
      {:ok, _, "y"} = Session.take_turn(a, "x", fn s -> {:ok, %{s | log: ["x" | s.log]}} end)
      :ok = GenServer.stop(a, :normal)

      # A new session with the same id + store restores everything.
      {:ok, b} =
        Session.start_link(
          shared_state: %{log: []},
          policy: :round_robin,
          participants: [Participant.new(id: "x"), Participant.new(id: "y")],
          session_id: id,
          store: :ets
        )

      # shared_state restored (atom keys → strings via JSON; x's log survived).
      assert Session.read_state(b)["log"] == ["x"]
      # Turn position restored: it's y's turn now.
      assert Session.current(b) == "y"
      assert Session.status(b) == :running

      # It keeps playing from where it left off.
      assert {:ok, _, "x"} =
               Session.take_turn(b, "y", fn s -> {:ok, %{s | "log" => ["y" | s["log"]]}} end)

      assert Session.read_state(b)["log"] == ["y", "x"]

      Store.delete_session_snapshot(@ets, id)
    end

    test "start with a store but no prior snapshot just starts fresh" do
      id = "empty-#{unique()}"

      {:ok, session} =
        Session.start_link(
          shared_state: %{log: []},
          policy: :round_robin,
          participants: [Participant.new(id: "a")],
          session_id: id,
          store: :ets
        )

      assert Session.read_state(session).log == []
      assert {:ok, "a"} = Session.start(session)

      Store.delete_session_snapshot(@ets, id)
    end

    test "participant refs come from the app on restart (not the snapshot)" do
      # The snapshot stores only ids/kinds; the live agent refs must be
      # re-attached by the app when starting the new session.
      id = "refs-#{unique()}"

      {:ok, a} =
        Session.start_link(
          shared_state: %{},
          policy: :round_robin,
          participants: [Participant.new(id: "p", kind: :agent, ref: self())],
          session_id: id,
          store: :ets
        )

      {:ok, "p"} = Session.start(a)
      :ok = GenServer.stop(a, :normal)

      # App re-supplies a new ref (a different pid) for the same participant.
      new_ref = spawn(fn -> :timer.sleep(:infinity) end)

      {:ok, b} =
        Session.start_link(
          shared_state: %{},
          policy: :round_robin,
          participants: [Participant.new(id: "p", kind: :agent, ref: new_ref)],
          session_id: id,
          store: :ets
        )

      [p] = Session.participants(b)
      assert p.id == "p"
      assert p.ref == new_ref

      Store.delete_session_snapshot(@ets, id)
      Process.exit(new_ref, :kill)
    end
  end

  defp unique, do: :erlang.unique_integer([:positive])
end
