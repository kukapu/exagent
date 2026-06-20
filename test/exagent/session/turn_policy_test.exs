defmodule ExAgent.Session.TurnPolicyTest do
  use ExUnit.Case, async: true

  alias ExAgent.Session.Participant
  alias ExAgent.Session.TurnPolicy

  defp ctx, do: %{shared_state: %{}, participants: []}

  defp ids(seq), do: Enum.map(seq, fn {:ok, id, _} -> id end)

  describe "RoundRobin" do
    alias ExAgent.Session.TurnPolicy.RoundRobin

    test "cycles participants in insertion order, forever" do
      state = RoundRobin.init(participants: [p("a"), p("b"), p("c")])

      # One full round…
      {:ok, a, s1} = RoundRobin.next_participant(state, ctx())
      {:ok, b, s2} = RoundRobin.next_participant(s1, ctx())
      {:ok, c, s3} = RoundRobin.next_participant(s2, ctx())
      # …then it wraps around.
      {:ok, a2, _} = RoundRobin.next_participant(s3, ctx())

      assert [a, b, c, a2] == ["a", "b", "c", "a"]
    end

    test "can_act? reflects only the current participant" do
      state = RoundRobin.init(participants: [p("a"), p("b")])
      {:ok, _a, s1} = RoundRobin.next_participant(state, ctx())

      assert RoundRobin.can_act?(s1, "a", ctx()) == true
      assert RoundRobin.can_act?(s1, "b", ctx()) == false

      {:ok, b, s2} = RoundRobin.next_participant(s1, ctx())
      assert b == "b"
      assert RoundRobin.can_act?(s2, "a", ctx()) == false
      assert RoundRobin.can_act?(s2, "b", ctx()) == true
    end

    test "joining appends to the cycle; leaving removes" do
      state = RoundRobin.init(participants: [p("a"), p("b")])

      state = RoundRobin.participant_joined(state, p("c"))
      assert ids(take(state, 3)) == ["a", "b", "c"]

      state = RoundRobin.participant_left(state, "b")
      assert ids(take(state, 2)) == ["a", "c"]
    end

    test "an empty roster is done" do
      state = RoundRobin.init(participants: [])
      assert {:done, _} = RoundRobin.next_participant(state, ctx())
    end
  end

  describe "Initiative" do
    alias ExAgent.Session.TurnPolicy.Initiative

    test "respects the given order" do
      state =
        Initiative.init(
          participants: [p("a"), p("b"), p("c")],
          order: ["c", "a", "b"]
        )

      assert ids(take(state, 4)) == ["c", "a", "b", "c"]
    end

    test "appends participants missing from :order and ignores unknown ids" do
      state =
        Initiative.init(
          participants: [p("a"), p("b"), p("d")],
          order: ["b", "zzz_unknown"]
        )

      # "b" first (from order), then a and d appended in insertion order.
      assert ids(take(state, 3)) == ["b", "a", "d"]
    end

    test "without :order it falls back to insertion order" do
      state = Initiative.init(participants: [p("x"), p("y")])
      assert ids(take(state, 2)) == ["x", "y"]
    end
  end

  # ---------------------------------------------------------------------------
  defp p(id), do: Participant.new(id: id)

  # Pull `n` participants off a policy state, returning the {:ok, id, state} triples.
  defp take(state, n), do: take(state, n, [])

  defp take(_state, 0, acc), do: Enum.reverse(acc)

  defp take(state, n, acc) do
    case TurnPolicy.next_participant(state, ctx()) do
      {:ok, id, next} -> take(next, n - 1, [{:ok, id, next} | acc])
      {:done, _} -> Enum.reverse(acc)
    end
  end
end
