defmodule ExAgent.Server.SnapshotTest do
  use ExUnit.Case, async: true

  alias ExAgent.Message.{Part, Request, Usage}
  alias ExAgent.Server.Snapshot

  # A small real conversation produced by the loop, to exercise round-trip.
  defp sample_history do
    agent = ExAgent.new(model: "test", instructions: "be concise")
    {:ok, %{messages: messages}} = ExAgent.run(agent, "hi")
    messages
  end

  describe "new/1" do
    test "builds a snapshot with serialized history and mapped usage" do
      history = sample_history()

      snap =
        Snapshot.new(
          agent_id: "agent_x",
          history: history,
          usage: %Usage{input_tokens: 3, output_tokens: 4},
          metadata: %{room: "tavern"}
        )

      assert snap.agent_id == "agent_x"
      assert %DateTime{} = snap.saved_at
      # message_history is a JSON binary (the serialized conversation)
      assert is_binary(snap.message_history)
      assert String.contains?(snap.message_history, "be concise")
      assert snap.usage == %{"input_tokens" => 3, "output_tokens" => 4}
    end
  end

  describe "serialize/deserialize round-trip" do
    test "round-trips a snapshot through JSON" do
      history = sample_history()

      snap =
        Snapshot.new(
          agent_id: "rt",
          history: history,
          usage: %Usage{input_tokens: 5, output_tokens: 6},
          metadata: %{k: "v"}
        )

      binary = Snapshot.serialize(snap)
      assert {:ok, %Snapshot{} = restored} = Snapshot.deserialize(binary)

      assert restored.agent_id == "rt"
      assert restored.usage == %{"input_tokens" => 5, "output_tokens" => 6}
      assert restored.metadata == %{"k" => "v"}
    end

    test "messages/1 reconstructs Message structs after a round-trip" do
      history = sample_history()

      snap = Snapshot.new(agent_id: "rt2", history: history, usage: nil)

      {:ok, restored} = snap |> Snapshot.serialize() |> Snapshot.deserialize()
      {:ok, messages} = Snapshot.messages(restored)

      assert length(messages) == length(history)

      # The first request still carries the system instruction + user prompt.
      [%Request{parts: parts} | _] = messages
      assert Enum.any?(parts, &match?(%Part.System{}, &1))
      assert Enum.any?(parts, &match?(%Part.User{content: "hi"}, &1))
    end

    test "usage_struct/1 rebuilds a Usage struct" do
      snap =
        Snapshot.new(agent_id: "u", history: [], usage: %Usage{input_tokens: 7, output_tokens: 9})

      {:ok, restored} = snap |> Snapshot.serialize() |> Snapshot.deserialize()

      assert %Usage{input_tokens: 7, output_tokens: 9} = Snapshot.usage_struct(restored)
    end

    test "messages/1 on an empty snapshot yields []" do
      snap = %Snapshot{agent_id: "x", message_history: nil}
      assert {:ok, []} = Snapshot.messages(snap)
    end
  end

  describe "serialization is strict (no closures / pids / secrets)" do
    test "serialize/1 raises when metadata contains a function capture" do
      snap = Snapshot.new(agent_id: "bad", history: [], metadata: %{leak: fn -> :ok end})
      assert refuses_to_serialize?(snap)
    end

    test "serialize/1 raises when metadata contains a pid" do
      snap = Snapshot.new(agent_id: "bad", history: [], metadata: %{pid: self()})
      assert refuses_to_serialize?(snap)
    end

    test "a snapshot never carries tool closures or api keys by construction" do
      # The Snapshot struct has no fields for tools/model/api_key — only
      # conversational state. This is a static guarantee, asserted here.
      fields = Snapshot.__struct__() |> Map.from_struct() |> Map.keys()

      refute :tools in fields
      refute :model in fields
      refute :api_key in fields
    end
  end

  # Strict JSON serialization must fail (raise) for non-encodable values. We
  # don't pin the exact exception type (Jason raises Protocol.UndefinedError
  # today); we only assert it refuses to serialize.
  defp refuses_to_serialize?(snap) do
    try do
      Snapshot.serialize(snap)
      false
    rescue
      _ -> true
    end
  end
end
