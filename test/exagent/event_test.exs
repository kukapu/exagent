defmodule ExAgent.EventTest do
  use ExUnit.Case, async: true

  alias ExAgent.Event

  describe "new/1" do
    test "fills id, occurred_at, version, payload and metadata defaults" do
      event = Event.new(type: :run_started, seq: 0)

      assert %Event{} = event
      assert event.type == :run_started
      assert event.seq == 0
      assert event.version == 1
      assert String.starts_with?(event.id, "evt_")
      assert %DateTime{} = event.occurred_at
      assert event.payload == %{}
      assert event.metadata == %{}
    end

    test "requires :type and :seq" do
      assert_raise ArgumentError, fn -> Event.new(type: :run_started) end
      assert_raise ArgumentError, fn -> Event.new(seq: 0) end
    end

    test "honours explicit fields and correlation ids" do
      event =
        Event.new(
          type: :tool_call_finished,
          seq: 7,
          source: :run,
          run_id: "run_abc",
          request_id: "req_1",
          agent_id: "agent_dm",
          payload: %{tool_name: "roll_dice", success: true}
        )

      assert event.seq == 7
      assert event.source == :run
      assert event.run_id == "run_abc"
      assert event.request_id == "req_1"
      assert event.agent_id == "agent_dm"
      assert event.payload.tool_name == "roll_dice"
    end
  end

  describe "topics" do
    test "agent_topic/1" do
      assert Event.agent_topic("dm") == "exagent:agent:dm"
      assert Event.agent_topic(nil) == "exagent:agent"
    end

    test "session_topic/1" do
      assert Event.session_topic("game_1") == "exagent:session:game_1"
      assert Event.session_topic(nil) == "exagent:session"
    end
  end

  describe "serialization" do
    test "round-trips through JSON with all envelope fields" do
      event =
        Event.new(
          type: :run_finished,
          seq: 3,
          source: :run,
          agent_id: "agent_x",
          run_id: "run_1",
          request_id: "req_1",
          payload: %{steps: 2, usage: %{input_tokens: 10, output_tokens: 4}}
        )

      json = Jason.encode!(event)
      decoded = Jason.decode!(json)

      assert decoded["type"] == "run_finished"
      assert decoded["seq"] == 3
      assert decoded["source"] == "run"
      assert decoded["agent_id"] == "agent_x"
      assert decoded["payload"]["steps"] == 2
      assert decoded["payload"]["usage"]["input_tokens"] == 10
      assert String.starts_with?(decoded["id"], "evt_")
    end
  end
end
