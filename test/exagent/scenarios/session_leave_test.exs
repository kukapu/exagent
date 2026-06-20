defmodule ExAgent.Scenarios.SessionLeaveTest do
  @moduledoc """
  Regression: the current participant leaving mid-turn used to deadlock the
  session — the policy nilled its `current`, but the Session never re-advanced,
  so no one could ever satisfy can_act?. Covers all three turn policies, the
  empty-roster end, and non-current leave.
  """

  use ExUnit.Case, async: true

  alias ExAgent.Session
  alias ExAgent.Session.Participant

  defp p(id), do: Participant.new(id: id)

  describe "current participant leaving mid-turn advances (RoundRobin)" do
    test "the next participant becomes current and can act" do
      {:ok, session} =
        Session.start_link(
          shared_state: %{log: []},
          policy: :round_robin,
          participants: [p("a"), p("b"), p("c")]
        )

      assert {:ok, "a"} = Session.start(session)
      assert {:ok, _, "b"} = Session.take_turn(session, "a", fn s -> {:ok, s} end)

      # "b" leaves mid-turn. Without the fix this deadlocks.
      assert :ok = Session.leave(session, "b")
      assert Session.current(session) == "c"
      assert Session.status(session) == :running

      assert {:ok, _, "a"} =
               Session.take_turn(session, "c", fn s -> {:ok, %{s | log: ["c" | s.log]}} end)
    end
  end

  describe "current participant leaving mid-turn (Initiative)" do
    test "the next in the explicit order becomes current" do
      {:ok, session} =
        Session.start_link(
          shared_state: %{},
          policy: {:initiative, order: ["rogue", "wizard", "fighter"]},
          participants: [p("rogue"), p("wizard"), p("fighter")]
        )

      assert {:ok, "rogue"} = Session.start(session)
      assert {:ok, _, "wizard"} = Session.take_turn(session, "rogue", fn s -> {:ok, s} end)

      assert :ok = Session.leave(session, "wizard")
      assert Session.current(session) == "fighter"

      assert {:ok, _, "rogue"} = Session.take_turn(session, "fighter", fn s -> {:ok, s} end)
    end
  end

  describe "SupervisorPolicy — supervisor leaving while current" do
    test "falls through to workers instead of re-emitting a ghost supervisor" do
      {:ok, session} =
        Session.start_link(
          shared_state: %{},
          policy: {:supervisor, supervisor: "dm", workers: ["rogue", "wizard"]},
          participants: [p("dm"), p("rogue"), p("wizard")]
        )

      assert {:ok, "dm"} = Session.start(session)

      assert :ok = Session.leave(session, "dm")
      assert Session.current(session) == "rogue"
      assert Session.status(session) == :running

      # Only workers remain in the cycle now.
      assert {:ok, _, "wizard"} = Session.take_turn(session, "rogue", fn s -> {:ok, s} end)
    end
  end

  describe "SupervisorPolicy — worker leaving while current" do
    test "the supervisor (next anyway) becomes current; no worker is skipped after" do
      {:ok, session} =
        Session.start_link(
          shared_state: %{},
          policy: {:supervisor, supervisor: "dm", workers: ["rogue", "wizard"]},
          participants: [p("dm"), p("rogue"), p("wizard")]
        )

      assert {:ok, "dm"} = Session.start(session)
      assert {:ok, _, "rogue"} = Session.take_turn(session, "dm", fn s -> {:ok, s} end)

      assert :ok = Session.leave(session, "rogue")
      assert Session.current(session) == "dm"

      # The following worker pick must not skip "wizard".
      assert {:ok, _, "wizard"} = Session.take_turn(session, "dm", fn s -> {:ok, s} end)
    end
  end

  describe "empty roster" do
    test "the last participant leaving transitions the session to :done" do
      {:ok, session} =
        Session.start_link(shared_state: %{}, policy: :round_robin, participants: [p("solo")])

      assert {:ok, "solo"} = Session.start(session)

      assert :ok = Session.leave(session, "solo")
      assert Session.status(session) == :done
      assert Session.current(session) == nil

      assert {:error, {:not_running, :done}} =
               Session.take_turn(session, "solo", fn s -> {:ok, s} end)
    end
  end

  describe "non-current participant leaving" do
    test "does not move the turn and does not skip anyone" do
      {:ok, session} =
        Session.start_link(
          shared_state: %{},
          policy: :round_robin,
          participants: [p("a"), p("b"), p("c")]
        )

      assert {:ok, "a"} = Session.start(session)
      assert :ok = Session.leave(session, "c")
      assert Session.current(session) == "a"
      assert Session.status(session) == :running

      # Next after a is now b (c removed); no one skipped.
      assert {:ok, _, "b"} = Session.take_turn(session, "a", fn s -> {:ok, s} end)
    end
  end
end
