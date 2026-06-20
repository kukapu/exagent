defmodule ExAgent.CoordinationTest do
  use ExUnit.Case, async: true

  alias ExAgent.Coordination
  alias ExAgent.Message
  alias ExAgent.Message.{Part, Usage}
  alias ExAgent.Session
  alias ExAgent.Session.Participant

  describe "delegation_tool/2 (agent-as-tool, shared usage)" do
    test "the parent calls the delegate; both runs' usage is merged" do
      # The delegate returns a known answer with a known, identifiable usage.
      delegate_response =
        Message.new_response([%Part.Text{content: "delegated answer"}],
          usage: %Usage{input_tokens: 5, output_tokens: 5},
          model_name: "test"
        )

      delegate =
        ExAgent.new(
          model: %ExAgent.Models.Test{script: [delegate_response]},
          instructions: "you are a helper"
        )

      parent_model = %ExAgent.Models.Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "ask_helper", args: %{"prompt" => "help"}}]},
          "parent final"
        ]
      }

      parent =
        ExAgent.new(
          model: parent_model,
          tools: [Coordination.delegation_tool(delegate, name: "ask_helper")]
        )

      assert {:ok, %{output: "parent final", usage: usage, messages: messages}} =
               ExAgent.run(parent, "please delegate")

      # Parent made 2 requests (1 in/1 out each from the TestModel) plus the
      # delegate's contributed 5/5 — proving usage is shared up the tree.
      assert usage.input_tokens == 7
      assert usage.output_tokens == 7

      # The delegate's output flowed back as the tool return.
      assert %Part.ToolReturn{content: "delegated answer"} = find_return(messages, "ask_helper")
    end

    test "a builder delegate receives the parent's context" do
      # The delegate is built per-call from ctx.deps, so the parent's
      # dependencies reach the sub-agent.
      builder = fn _ctx, _args ->
        ExAgent.new(model: %ExAgent.Models.Test{label: "from builder"})
      end

      parent_model = %ExAgent.Models.Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "delegate", args: %{"prompt" => "x"}}]},
          "done"
        ]
      }

      parent =
        ExAgent.new(model: parent_model, tools: [Coordination.delegation_tool(builder)])

      assert {:ok, %{messages: messages}} = ExAgent.run(parent, "go")
      assert %Part.ToolReturn{content: "from builder"} = find_return(messages, "delegate")
    end
  end

  describe "handoff/2 (direct control transfer in a Session)" do
    setup do
      {:ok, session} =
        Session.start_link(
          shared_state: %{log: []},
          policy: :round_robin,
          participants: [
            Participant.new(id: "a"),
            Participant.new(id: "b"),
            Participant.new(id: "c")
          ]
        )

      {:ok, _} = Session.start(session)
      %{session: session}
    end

    test "transfers control to the target, skipping the normal order", %{session: session} do
      # Round-robin starts at "a"; hand off directly to "c".
      assert Session.current(session) == "a"
      assert {:ok, "c"} = Coordination.handoff(session, "c")
      assert Session.current(session) == "c"

      # "b" is NOT current now (we handed control to "c"), so it can't act yet.
      assert {:error, :not_your_turn} =
               Session.take_turn(session, "b", fn s -> {:ok, s} end)

      # "c" can act; afterwards the normal round-robin order resumes from here.
      assert {:ok, _state, next} =
               Session.take_turn(session, "c", fn s -> {:ok, %{s | log: ["c" | s.log]}} end)

      assert next == "b"
    end

    test "rejects an unknown participant", %{session: session} do
      assert {:error, :not_a_participant} = Coordination.handoff(session, "zzz")
    end

    test "rejects handoff when not running" do
      {:ok, session} =
        Session.start_link(
          shared_state: %{},
          policy: :round_robin,
          participants: [Participant.new(id: "a")]
        )

      # Not started yet → not running.
      assert {:error, {:not_running, :created}} = Coordination.handoff(session, "a")
    end
  end

  describe "supervisor policy (Session-level)" do
    test "a supervisor participant alternates with two workers" do
      {:ok, session} =
        Session.start_link(
          shared_state: %{log: []},
          policy: {:supervisor, supervisor: "dm", workers: ["bot1", "bot2"]},
          participants: [
            Participant.new(id: "dm"),
            Participant.new(id: "bot1"),
            Participant.new(id: "bot2")
          ]
        )

      {:ok, first} = Session.start(session)
      assert first == "dm"

      # dm → bot1 → dm → bot2 …
      {:ok, _, n1} = Session.take_turn(session, "dm", fn s -> {:ok, s} end)
      assert n1 == "bot1"

      {:ok, _, n2} = Session.take_turn(session, "bot1", fn s -> {:ok, s} end)
      assert n2 == "dm"

      {:ok, _, n3} = Session.take_turn(session, "dm", fn s -> {:ok, s} end)
      assert n3 == "bot2"
    end
  end

  # ---------------------------------------------------------------------------
  defp find_return(messages, tool_name) do
    Enum.find_value(messages, fn
      %Message.Request{parts: parts} ->
        Enum.find(parts, &match?(%Part.ToolReturn{tool_name: ^tool_name}, &1))

      _ ->
        nil
    end)
  end
end
