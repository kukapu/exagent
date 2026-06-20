defmodule ExAgent.Scenarios.LongContextTest do
  @moduledoc """
  Scenario 4 — keeping a long conversation bounded and coherent.

  Composes `ExAgent.Compaction.Summary` (via `ExAgent.Compaction.Capability`)
  with the real agent loop, covering things `compaction_test.exs` does not:

    * an **LLM-driven** `:summarize` fn that itself calls `ExAgent.run/3`
      (the recursive pattern from the docs),
    * the loop still **completes a tool-call round-trip** after compaction
      (the compacted history is a valid conversation, not just shorter),
    * the `:summarize` fn receives exactly the *old* messages, not the window,
    * a **custom compactor** implementing the behaviour, and
    * an invariant check on `result.new_messages` after compaction fires.
  """

  use ExUnit.Case, async: true

  alias ExAgent.Compaction
  alias ExAgent.Message
  alias ExAgent.Message.{Part, Request}
  alias ExAgent.Models.Test

  describe "LLM-driven :summarize (recursive agent)" do
    test "the summarize fn runs a cheap agent and its text becomes the summary" do
      history = for i <- 1..20, do: user_msg("turn #{i} with padding text abcd efgh")

      # A summarizer "agent": a TestModel that returns a canned summary.
      summarizer = ExAgent.new(model: %Test{label: "SUMMARY OF PAST TURNS"})

      compaction = %Compaction.Capability{
        compactor: Compaction.Summary,
        opts: [
          threshold_tokens: 50,
          keep_recent: 4,
          summarize: fn old_msgs ->
            {:ok, %{output: text}} = ExAgent.run(summarizer, prompt_for(old_msgs))
            text
          end
        ]
      }

      agent = ExAgent.new(model: %Test{label: "done"}, capabilities: [compaction])

      assert {:ok, %{messages: messages}} =
               ExAgent.run(agent, "latest", message_history: history)

      [%Request{parts: [%Part.System{content: sys} | _]} | _] = messages
      assert sys =~ "SUMMARY OF PAST TURNS"
    end
  end

  describe "the loop still works after compaction (tool round-trip)" do
    test "a compacted run can still call a tool and produce a final answer" do
      # Large history so compaction definitely fires.
      history = for i <- 1..20, do: user_msg("background turn #{i} lorem ipsum dolor")

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
          {:tool_calls, [%Part.ToolCall{tool_name: "add", args: %{"a" => 2, "b" => 3}}]},
          "the sum is 5"
        ]
      }

      compaction = %Compaction.Capability{
        compactor: Compaction.Summary,
        opts: [threshold_tokens: 50, keep_recent: 4, summarize: fn _ -> "PAST" end]
      }

      agent = ExAgent.new(model: model, tools: [add], capabilities: [compaction])

      assert {:ok, %{output: "the sum is 5", messages: messages}} =
               ExAgent.run(agent, "add two", message_history: history)

      # Compaction fired (far fewer than the 20-item history)...
      assert length(messages) < 12

      # ...and the tool genuinely executed (its ToolReturn is in the history).
      assert find_return(messages, "add") != nil
    end
  end

  describe ":summarize receives exactly the old messages, not the recent window" do
    test "the old set has length(history) - keep_recent items" do
      history = for i <- 1..16, do: user_msg("msg #{i} padded padded padded padded")

      parent = self()

      compaction = %Compaction.Capability{
        compactor: Compaction.Summary,
        opts: [
          threshold_tokens: 50,
          keep_recent: 6,
          summarize: fn old ->
            send(parent, {:old_count, length(old)})
            "S"
          end
        ]
      }

      agent = ExAgent.new(model: %Test{label: "ok"}, capabilities: [compaction])

      ExAgent.run(agent, "now", message_history: history)

      # Only the prior history (16 items) is compacted; this run's first request
      # is kept separate. keep_recent 6 → old = 16 - 6 = 10.
      assert_received {:old_count, 10}
    end
  end

  describe "a custom compactor implementing the behaviour" do
    test "is invoked and its result is used as the request messages" do
      parent = self()

      # A compactor that records the call and trims to the last 2 messages.
      defmodule LastTwo do
        @behaviour ExAgent.Compaction

        @impl true
        def compact(messages, opts) do
          send(opts[:parent], {:compact_called, length(messages)})
          {:ok, Enum.take(messages, -2)}
        end
      end

      compaction = %Compaction.Capability{compactor: LastTwo, opts: [parent: parent]}

      history = for i <- 1..10, do: user_msg("h #{i}")

      model = %Test{
        script: [
          fn messages, _params ->
            send(parent, {:model_saw, length(messages)})
            "done"
          end
        ]
      }

      agent = ExAgent.new(model: model, capabilities: [compaction])

      assert {:ok, _} = ExAgent.run(agent, "go", message_history: history)

      # Compactor was called with only the prior history (10, not 10+1)...
      assert_received {:compact_called, 10}
      # ...and the model received the compacted 2 + this run's first request = 3.
      assert_received {:model_saw, 3}
    end
  end

  describe "new_messages invariant after compaction" do
    test "the run's :new_messages is still populated when compaction fires" do
      history = for i <- 1..20, do: user_msg("turn #{i} padding padding padding padding")

      compaction = %Compaction.Capability{
        compactor: Compaction.Summary,
        opts: [threshold_tokens: 50, keep_recent: 4, summarize: fn _ -> "PAST" end]
      }

      agent = ExAgent.new(model: %Test{label: "done"}, capabilities: [compaction])

      assert {:ok, %{new_messages: new, messages: all}} =
               ExAgent.run(agent, "latest", message_history: history)

      # new_messages should reflect this run's additions (request + response at
      # least), not be emptied by the history rewrite.
      assert length(new) >= 2
      assert length(new) < length(all)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp user_msg(text),
    do: %Request{parts: [%Part.User{content: text}], timestamp: DateTime.utc_now()}

  defp prompt_for(old_msgs) do
    "Summarize #{length(old_msgs)} earlier messages."
  end

  defp find_return(messages, name) do
    Enum.find_value(messages, fn
      %Message.Request{parts: parts} ->
        Enum.find(parts, &match?(%Part.ToolReturn{tool_name: ^name}, &1))

      _ ->
        nil
    end)
  end
end
