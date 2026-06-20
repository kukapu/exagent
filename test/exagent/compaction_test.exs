defmodule ExAgent.CompactionTest do
  use ExUnit.Case, async: true

  alias ExAgent.Compaction
  alias ExAgent.Compaction.Summary
  alias ExAgent.Message.{Part, Request}
  alias ExAgent.Models.Test

  describe "estimate_tokens/1" do
    test "roughly counts text characters / 4" do
      # 40 characters of text → ~10 tokens.
      msgs = [%Request{parts: [%Part.User{content: String.duplicate("a", 40)}]}]
      assert Compaction.estimate_tokens(msgs) == 10
    end
  end

  describe "Summary.compact/2" do
    test "replaces old messages with a summary, keeping the recent window" do
      history = for i <- 1..20, do: msg("message number #{i} with some padding text")
      # ~ 20 * ~40 chars / 4 ≈ 200 tokens; threshold 50 forces compaction.
      opts = [threshold_tokens: 50, keep_recent: 4, summarize: fn _old -> "SUMMARY" end]

      assert {:ok, compacted} = Summary.compact(history, opts)

      # 4 recent kept + 1 summary.
      assert length(compacted) == 5
      [%Request{parts: [%Part.System{content: sys}]} | recent] = compacted
      assert String.contains?(sys, "SUMMARY")
      # The last kept message is the last of the original history.
      last = List.last(recent)

      assert %Part.User{content: "message number 20 with some padding text"} =
               hd(last.parts)
    end

    test "leaves the history alone when under the threshold" do
      history = [msg("short"), msg("also short")]
      opts = [threshold_tokens: 10_000, keep_recent: 4, summarize: fn _ -> "S" end]
      assert {:no_change} = Summary.compact(history, opts)
    end

    test "does nothing without a :summarize function" do
      history = for _ <- 1..30, do: msg("padding padding padding padding padding")
      assert {:no_change} = Summary.compact(history, threshold_tokens: 1, keep_recent: 2)
    end
  end

  describe "as a Capability wired into a run" do
    test "compacts the history before the first model request" do
      history = for i <- 1..20, do: msg("turn #{i} lorem ipsum dolor sit amet consectetur")

      compaction = %Compaction.Capability{
        compactor: Summary,
        opts: [threshold_tokens: 50, keep_recent: 4, summarize: fn _old -> "EARLIER" end]
      }

      agent = ExAgent.new(model: %Test{label: "done"}, capabilities: [compaction])

      assert {:ok, %{messages: messages}} =
               ExAgent.run(agent, "the latest turn", message_history: history)

      # Compaction happened: far fewer than the 20-item history, and the
      # summary is the first message.
      assert length(messages) < 20
      assert %Request{parts: [%Part.System{content: sys} | _]} = hd(messages)
      assert String.contains?(sys, "EARLIER")

      # The user's current prompt survived in the recent window.
      assert Enum.any?(messages, fn
               %Request{parts: parts} ->
                 Enum.any?(parts, &match?(%Part.User{content: "the latest turn"}, &1))

               _ ->
                 false
             end)
    end

    test "untouched when the history is small" do
      history = [msg("hi"), msg("yo")]

      compaction = %Compaction.Capability{
        compactor: Summary,
        opts: [threshold_tokens: 50, keep_recent: 4, summarize: fn _ -> "X" end]
      }

      agent = ExAgent.new(model: %Test{label: "done"}, capabilities: [compaction])

      assert {:ok, %{messages: messages}} =
               ExAgent.run(agent, "again", message_history: history)

      # history(2) + first_request + response = 4; no compaction, no summary.
      refute Enum.any?(messages, fn
               %Request{parts: parts} ->
                 Enum.any?(parts, &match?(%Part.System{content: "Summary" <> _}, &1))

               _ ->
                 false
             end)
    end
  end

  defp msg(text), do: %Request{parts: [%Part.User{content: text}], timestamp: DateTime.utc_now()}
end
