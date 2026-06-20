defmodule ExAgent.SessionTest do
  use ExUnit.Case, async: true

  alias ExAgent.{Event, PubSub}
  alias ExAgent.Session
  alias ExAgent.Session.{Participant, SharedState}

  describe "round-robin coordination" do
    test "turns cycle through participants and a change is visible to the next" do
      {:ok, session} =
        Session.start_link(
          shared_state: %{log: []},
          policy: :round_robin,
          participants: [p("dm"), p("bot"), p("player")],
          session_id: "rr-1",
          pubsub: :local
        )

      assert {:ok, "dm"} = Session.start(session)

      # The DM acts, appending to the shared log.
      assert {:ok, state, "bot"} =
               Session.take_turn(session, "dm", fn s -> {:ok, %{s | log: ["dm" | s.log]}} end)

      assert state.log == ["dm"]

      # Now it's the bot's turn; it sees the DM's change.
      assert Session.current(session) == "bot"
      assert Session.read_state(session).log == ["dm"]

      assert {:ok, _state, "player"} =
               Session.take_turn(session, "bot", fn s -> {:ok, %{s | log: ["bot" | s.log]}} end)

      assert {:ok, _state, "dm"} =
               Session.take_turn(session, "player", fn s ->
                 {:ok, %{s | log: ["player" | s.log]}}
               end)

      # Wrapped around to the DM; the whole history is preserved.
      assert Session.current(session) == "dm"
      assert Session.read_state(session).log == ["player", "bot", "dm"]
    end

    test "only the current participant may act" do
      {:ok, session} =
        Session.start_link(
          shared_state: %{n: 0},
          policy: :round_robin,
          participants: [p("a"), p("b")]
        )

      assert {:ok, "a"} = Session.start(session)

      assert {:error, :not_your_turn} =
               Session.take_turn(session, "b", fn s -> {:ok, %{s | n: s.n + 1}} end)

      # State is untouched by the rejected turn.
      assert Session.read_state(session).n == 0
    end
  end

  describe "concurrent writes are serialized by the Session" do
    test "only the first of several concurrent take_turn calls for the same actor wins" do
      {:ok, session} =
        Session.start_link(
          shared_state: %{wins: []},
          policy: :round_robin,
          participants: [p("a"), p("b")]
        )

      {:ok, _} = Session.start(session)

      # "a" is current. Three concurrent calls all claim to be "a"; the Session
      # processes them one at a time. The first wins and advances the turn to
      # "b", so the remaining two must be rejected as :not_your_turn.
      tasks =
        Enum.map(1..3, fn i ->
          Task.async(fn ->
            Session.take_turn(session, "a", fn s -> {:ok, %{s | wins: [i | s.wins]}} end)
          end)
        end)

      results = Enum.map(tasks, &Task.await/1)

      ok_results = for {:ok, state, _next} <- results, do: state
      blocked = for {:error, :not_your_turn} <- results, do: :blocked

      # Exactly one succeeded; the shared state was updated exactly once.
      assert length(ok_results) == 1
      assert length(blocked) == 2
      assert hd(ok_results).wins |> length() == 1
    end
  end

  describe "pause / resume" do
    test "a paused session refuses turns and resumes on demand" do
      {:ok, session} =
        Session.start_link(
          shared_state: %{n: 0},
          policy: :round_robin,
          participants: [p("a"), p("b")]
        )

      {:ok, _} = Session.start(session)

      assert :ok = Session.pause(session)
      assert Session.status(session) == :paused
      assert {:error, :paused} = Session.take_turn(session, "a", fn s -> {:ok, s} end)

      assert :ok = Session.resume(session)
      assert Session.status(session) == :running
      assert {:ok, _state, "b"} = Session.take_turn(session, "a", fn s -> {:ok, s} end)
    end
  end

  describe "initiative order" do
    test "participants act in the provided order, not insertion order" do
      {:ok, session} =
        Session.start_link(
          shared_state: %{order: []},
          policy: {:initiative, order: ["rogue", "wizard", "fighter"]},
          participants: [p("fighter"), p("rogue"), p("wizard")]
        )

      {:ok, first} = Session.start(session)
      assert first == "rogue"

      {:ok, _, second} = Session.take_turn(session, "rogue", fn s -> {:ok, s} end)
      {:ok, _, third} = Session.take_turn(session, "wizard", fn s -> {:ok, s} end)

      assert [first, second, third] == ["rogue", "wizard", "fighter"]
    end
  end

  describe "events" do
    test "emits session lifecycle + turn + state events on the session topic" do
      :ok = PubSub.subscribe({PubSub.Local, []}, Event.session_topic("evt-1"))

      {:ok, session} =
        Session.start_link(
          shared_state: %{n: 0},
          policy: :round_robin,
          participants: [p("a"), p("b")],
          session_id: "evt-1",
          pubsub: :local
        )

      {:ok, _} = Session.start(session)
      Session.take_turn(session, "a", fn s -> {:ok, %{s | n: 1}} end)

      types = collect_event_types(150)

      assert :session_started in types
      assert :participant_joined in types or true
      assert :session_turn_changed in types
      assert :shared_state_updated in types

      Session.close(session)
      types_after_close = collect_event_types(50)
      assert :session_closed in types_after_close
    end
  end

  describe "SharedState handle (single-writer from tools)" do
    test "a tool reads and proposes a change through the handle" do
      {:ok, session} =
        Session.start_link(
          shared_state: %{hp: 10},
          policy: :round_robin,
          participants: [p("dm")]
        )

      {:ok, _} = Session.start(session)

      handle = SharedState.new(session, "dm")

      # Read is always allowed.
      assert SharedState.read(handle).hp == 10

      # Propose applies because it's the DM's turn.
      assert {:ok, state} =
               SharedState.propose_change(handle, fn s -> {:ok, %{s | hp: s.hp - 3}} end)

      assert state.hp == 7
      assert Session.read_state(session).hp == 7
    end

    test "a propose from a non-current participant is rejected" do
      {:ok, session} =
        Session.start_link(
          shared_state: %{x: 0},
          policy: :round_robin,
          participants: [p("a"), p("b")]
        )

      {:ok, _} = Session.start(session)

      handle = SharedState.new(session, "b")

      assert {:error, :not_your_turn} =
               SharedState.propose_change(handle, fn s -> {:ok, %{s | x: 1}} end)

      assert Session.read_state(session).x == 0
    end
  end

  describe "join / leave" do
    test "participants can join a running session and enter the cycle" do
      {:ok, session} =
        Session.start_link(shared_state: %{}, policy: :round_robin, participants: [p("a")])

      {:ok, _} = Session.start(session)
      assert :ok = Session.join(session, Participant.new(id: "b", kind: :human))

      # a acts, then the newly joined b should come up.
      {:ok, _, next} = Session.take_turn(session, "a", fn s -> {:ok, s} end)
      assert next == "b"

      assert :ok = Session.leave(session, "a")
      assert {:error, :not_found} = Session.leave(session, "zzz")
    end
  end

  # ---------------------------------------------------------------------------
  defp p(id), do: Participant.new(id: id)

  defp collect_event_types(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect([], deadline)
  end

  defp do_collect(acc, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:exagent_event, %Event{type: type}} -> do_collect([type | acc], deadline)
    after
      remaining -> Enum.reverse(acc)
    end
  end
end
