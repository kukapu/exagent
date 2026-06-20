defmodule ExAgent.Scenarios.MultiAgentTest do
  @moduledoc """
  Scenario 3 — a customer-support triage coordinated by `ExAgent.Session`.

  Composes the multi-agent stack into one workflow:

    * `ExAgent.Session` with the three turn policies (RoundRobin, Initiative,
      SupervisorPolicy), coordinating real `ExAgent.Server` agents + a human.
    * `ExAgent.Session.SharedState` (single-writer) — agents propose transcript
      mutations through their `RunContext.deps`; the Session is the only writer.
    * `ExAgent.Coordination.delegation_tool/2` — a supervisor agent delegates a
      sub-task to a specialist (agent-as-tool, usage merged up the tree).
    * `ExAgent.Coordination.handoff/2` — direct control transfer bypassing the
      policy; plus session events on the session topic.

  Everything offline (`ExAgent.Models.Test`).
  """

  use ExUnit.Case, async: true

  alias ExAgent.{Coordination, Event, Message.Part, Models.Test, PubSub, Server, Session}
  alias ExAgent.Session.{Participant, SharedState}

  # Shared state shape: a running transcript of who said what.
  defmodule State do
    def new, do: %{transcript: [], resolved: 0}
    def append(%{transcript: t} = s, who, msg), do: %{s | transcript: [{who, msg} | t]}
    def resolve(s), do: %{s | resolved: s.resolved + 1}
  end

  describe "RoundRobin — two agents mutate shared state via SharedState" do
    test "each agent's tool proposes a change only on its own turn" do
      # Agent "a": its tool appends "from-a" to the transcript.
      a =
        start_agent(
          id: "a",
          script: [
            {:tool_calls, [%Part.ToolCall{tool_name: "speak", args: %{"msg" => "from-a"}}]},
            "a done"
          ],
          tool: "speak"
        )

      # Agent "b": appends "from-b".
      b =
        start_agent(
          id: "b",
          script: [
            {:tool_calls, [%Part.ToolCall{tool_name: "speak", args: %{"msg" => "from-b"}}]},
            "b done"
          ],
          tool: "speak"
        )

      {:ok, game} =
        start_session(
          policy: :round_robin,
          participants: [
            Participant.new(id: "a", kind: :agent, ref: a),
            Participant.new(id: "b", kind: :agent, ref: b)
          ]
        )

      {:ok, "a"} = Session.start(game)

      # Drive turn a, then b. Each chat passes a SharedState handle as deps.
      drive(game, "a", a)
      assert Session.current(game) == "b"
      drive(game, "b", b)

      # Both contributions landed, in turn order (b's is newest, prepended).
      state = Session.read_state(game)
      assert {"b", "from-b"} in state.transcript
      assert {"a", "from-a"} in state.transcript
    end

    test "propose_change fails with :not_your_turn outside the participant's turn" do
      {:ok, game} =
        start_session(
          policy: :round_robin,
          participants: [Participant.new(id: "a"), Participant.new(id: "b")]
        )

      {:ok, "a"} = Session.start(game)

      # "b" is NOT the current participant — its proposal must be refused.
      handle = SharedState.new(game, "b")

      assert {:error, :not_your_turn} =
               SharedState.propose_change(handle, fn s -> {:ok, s} end)

      # "a" (current) can propose.
      handle_a = SharedState.new(game, "a")
      assert {:ok, _} = SharedState.propose_change(handle_a, &{:ok, &1})
    end
  end

  describe "delegation_tool — supervisor delegates to a specialist inside a run" do
    test "the specialist's output returns to the parent AND usage is merged" do
      alias ExAgent.Message
      alias ExAgent.Message.Usage

      # A specialist agent that knows the answer.
      specialist =
        ExAgent.new(
          model: %Test{
            script: [
              Message.new_response([%Part.Text{content: "refund: $42"}],
                usage: %Usage{input_tokens: 8, output_tokens: 3},
                model_name: "test"
              )
            ]
          }
        )

      # The parent (triage) agent delegates via the tool, then reports.
      parent =
        ExAgent.new(
          model: %Test{
            script: [
              {:tool_calls,
               [%Part.ToolCall{tool_name: "ask_billing", args: %{"prompt" => "refund?"}}]},
              "triaged"
            ]
          },
          tools: [Coordination.delegation_tool(specialist, name: "ask_billing")]
        )

      assert {:ok, %{output: "triaged", usage: usage}} = ExAgent.run(parent, "help")

      # Parent's 1/1 + specialist's contributed 8/3 = at least 9/4.
      assert usage.input_tokens >= 9 and usage.output_tokens >= 4
    end
  end

  describe "SupervisorPolicy + SharedState — triage alternates with workers" do
    test "the supervisor resolves one ticket per worker turn" do
      triage =
        start_agent(
          id: "triage",
          script: [
            {:tool_calls, [%Part.ToolCall{tool_name: "speak", args: %{"msg" => "triaging"}}]},
            "ok"
          ],
          tool: "speak"
        )

      billing =
        start_agent(
          id: "billing",
          script: [
            {:tool_calls, [%Part.ToolCall{tool_name: "resolve", args: %{}}]},
            "resolved"
          ],
          tool: "resolve"
        )

      {:ok, game} =
        start_session(
          policy: {:supervisor, supervisor: "triage", workers: ["billing"]},
          participants: [
            Participant.new(id: "triage", kind: :agent, ref: triage),
            Participant.new(id: "billing", kind: :agent, ref: billing)
          ]
        )

      {:ok, "triage"} = Session.start(game)

      # Sequence: triage → billing → triage.
      drive(game, "triage", triage)
      assert Session.current(game) == "billing"
      drive(game, "billing", billing)
      assert Session.current(game) == "triage"

      state = Session.read_state(game)
      assert {"triage", "triaging"} in state.transcript
      assert state.resolved == 1
    end
  end

  describe "Initiative — explicit order" do
    test "cycles in the given order; unordered participants appended after" do
      {:ok, game} =
        start_session(
          policy: {:initiative, order: ["c", "a"]},
          participants: [
            Participant.new(id: "a"),
            Participant.new(id: "b"),
            Participant.new(id: "c")
          ]
        )

      {:ok, first} = Session.start(game)
      assert first == "c"

      assert {:ok, _, "a"} = Session.take_turn(game, "c", fn s -> {:ok, s} end)
      # "b" was unordered → appended after the explicit order.
      assert {:ok, _, "b"} = Session.take_turn(game, "a", fn s -> {:ok, s} end)
      assert {:ok, _, "c"} = Session.take_turn(game, "b", fn s -> {:ok, s} end)
    end
  end

  describe "handoff + session events" do
    test "handoff bypasses the order; events flow on the session topic" do
      {:ok, game} =
        start_session(
          policy: :round_robin,
          pubsub: :local,
          participants: [
            Participant.new(id: "a"),
            Participant.new(id: "b"),
            Participant.new(id: "human", kind: :human)
          ]
        )

      :ok = PubSub.subscribe({PubSub.Local, []}, Event.session_topic(session_id(game)))
      {:ok, "a"} = Session.start(game)

      assert_receive {:exagent_event, %Event{type: :session_started}}

      # Hand off directly to the human, skipping "b".
      assert {:ok, "human"} = Coordination.handoff(game, "human")
      assert Session.current(game) == "human"

      assert_receive {:exagent_event, %Event{type: :session_turn_changed}}
    end
  end

  describe "pause / resume / close lifecycle" do
    test "paused session refuses turns; close ends the session" do
      {:ok, game} =
        start_session(
          policy: :round_robin,
          participants: [Participant.new(id: "a"), Participant.new(id: "b")]
        )

      {:ok, "a"} = Session.start(game)
      :ok = Session.pause(game)

      assert {:error, :paused} = Session.take_turn(game, "a", fn s -> {:ok, s} end)

      :ok = Session.resume(game)
      assert {:ok, _, "b"} = Session.take_turn(game, "a", fn s -> {:ok, s} end)

      :ok = Session.close(game)

      assert {:error, {:not_running, :closed}} =
               Session.take_turn(game, "b", fn s -> {:ok, s} end)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Start an ExAgent.Server whose single tool either "speaks" (appends msg) or
  # "resolves" (increments the resolved counter) through its SharedState handle.
  # The agent's participant id is baked into the tool closure so the transcript
  # records WHO acted, not just which tool ran.
  defp start_agent(opts) do
    id = Keyword.fetch!(opts, :id)
    kind = Keyword.fetch!(opts, :tool)

    tool =
      case kind do
        "speak" -> speak_tool(id)
        "resolve" -> resolve_tool(id)
      end

    agent =
      ExAgent.new(
        model: %Test{script: Keyword.fetch!(opts, :script)},
        tools: [tool]
      )

    start_supervised!({Server, agent: agent, agent_id: id})
  end

  defp speak_tool(id) do
    ExAgent.Tool.new(
      name: "speak",
      description: "append a message",
      parameters_json_schema: %{
        "type" => "object",
        "properties" => %{"msg" => %{"type" => "string"}},
        "required" => ["msg"]
      },
      takes_ctx: true,
      call: fn ctx, %{"msg" => msg} ->
        handle = ctx.deps
        {:ok, _} = SharedState.propose_change(handle, &{:ok, State.append(&1, id, msg)})
        {:ok, "ok"}
      end
    )
  end

  defp resolve_tool(id) do
    ExAgent.Tool.new(
      name: "resolve",
      description: "resolve a ticket",
      parameters_json_schema: %{type: "object", properties: %{}},
      takes_ctx: true,
      call: fn ctx, _ ->
        handle = ctx.deps

        {:ok, _} =
          SharedState.propose_change(
            handle,
            &{:ok, State.append(&1, id, "resolved") |> State.resolve()}
          )

        {:ok, "resolved"}
      end
    )
  end

  defp start_session(opts) do
    sid = "multi-#{:erlang.unique_integer([:positive])}"

    Session.start_link(
      shared_state: State.new(),
      policy: Keyword.fetch!(opts, :policy),
      participants: Keyword.fetch!(opts, :participants),
      session_id: sid,
      pubsub: Keyword.get(opts, :pubsub)
    )
  end

  # Drive one agent turn: give it the SharedState handle, run a chat, end turn.
  defp drive(game, id, server) do
    handle = SharedState.new(game, id)
    assert {:ok, _} = Server.chat(server, "your turn", deps: handle)
    assert {:ok, _next} = Session.end_turn(game, id)
    :ok
  end

  defp session_id(game), do: :sys.get_state(game).session_id
end
