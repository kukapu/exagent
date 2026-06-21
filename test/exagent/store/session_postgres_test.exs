defmodule ExAgent.Store.SessionPostgresTest do
  use ExUnit.Case, async: false

  @moduletag :postgres

  alias ExAgent.Session.{Participant, Snapshot}
  alias ExAgent.{Session, Store}

  @repo ExAgent.TestRepo
  @store {ExAgent.Store.Postgres, @repo}

  test "round-trips a session snapshot via Postgres" do
    id = "pg-sess-#{:erlang.unique_integer([:positive])}"

    {:ok, session} =
      Session.start_link(
        shared_state: %{scene: "tavern", round: 1},
        policy: :round_robin,
        participants: [Participant.new(id: "a"), Participant.new(id: "b")],
        session_id: id
      )

    {:ok, "a"} = Session.start(session)
    {:ok, _, "b"} = Session.take_turn(session, "a", fn s -> {:ok, %{s | scene: "crypt"}} end)

    snap = Snapshot.new(:sys.get_state(session))

    assert :ok = Store.save_session_snapshot(@store, snap)

    assert {:ok, loaded} = Store.load_session_snapshot(@store, id)
    assert loaded.session_id == id
    assert loaded.shared_state["scene"] == "crypt"
    assert loaded.current == "b"
    assert loaded.policy_mod == ExAgent.Session.TurnPolicy.RoundRobin

    assert :ok = Store.delete_session_snapshot(@store, id)
    assert {:error, :not_found} = Store.load_session_snapshot(@store, id)
  end
end
