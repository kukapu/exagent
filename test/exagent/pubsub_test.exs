defmodule ExAgent.PubSubTest do
  use ExUnit.Case, async: true

  alias ExAgent.{Event, PubSub}

  describe "normalize/1" do
    test "nil and :none resolve to None" do
      assert PubSub.normalize(nil) == {ExAgent.PubSub.None, []}
      assert PubSub.normalize(:none) == {ExAgent.PubSub.None, []}
    end

    test ":local resolves to Local" do
      assert PubSub.normalize(:local) == {ExAgent.PubSub.Local, []}
    end

    test "bare module resolves to {module, []}" do
      assert PubSub.normalize(MyPub) == {MyPub, []}
    end

    test "{module, config} passes through" do
      assert PubSub.normalize({MyPub, [server: :x]}) == {MyPub, [server: :x]}
    end
  end

  describe "None" do
    test "broadcast is a no-op" do
      assert PubSub.broadcast({ExAgent.PubSub.None, []}, "any", event()) == :ok
    end

    test "subscribe is unsupported" do
      assert {:error, {:subscribe_unsupported, ExAgent.PubSub.None}} =
               PubSub.subscribe({ExAgent.PubSub.None, []}, "any")
    end
  end

  describe "Local" do
    test "subscribers receive {:exagent_event, event} in order" do
      topic = unique_topic()

      :ok = PubSub.subscribe({ExAgent.PubSub.Local, []}, topic)

      e1 = event(:run_started, 1)
      e2 = event(:run_finished, 2)

      assert PubSub.broadcast({ExAgent.PubSub.Local, []}, topic, e1) == :ok
      assert PubSub.broadcast({ExAgent.PubSub.Local, []}, topic, e2) == :ok

      assert_receive {:exagent_event, ^e1}
      assert_receive {:exagent_event, ^e2}
    end

    test "broadcast to a topic with no subscribers is still :ok" do
      assert PubSub.broadcast({ExAgent.PubSub.Local, []}, unique_topic(), event()) == :ok
    end

    test "two subscribers both receive the same event" do
      topic = unique_topic()

      task =
        Task.async(fn ->
          :ok = PubSub.subscribe({ExAgent.PubSub.Local, []}, topic)
          assert_receive {:exagent_event, _}
          :ok
        end)

      :ok = PubSub.subscribe({ExAgent.PubSub.Local, []}, topic)

      e = event(:run_started, 1)

      # Give the task a moment to register before broadcasting.
      Process.sleep(10)
      assert PubSub.broadcast({ExAgent.PubSub.Local, []}, topic, e) == :ok

      assert Task.await(task) == :ok
      assert_receive {:exagent_event, ^e}
    end
  end

  describe "Phoenix" do
    test "returns a graceful error when Phoenix.PubSub is not available" do
      # Phoenix is not a dependency of exagent, so the adapter must not raise.
      result = PubSub.broadcast({ExAgent.PubSub.Phoenix, :missing}, "t", event())

      assert result in [
               :ok,
               {:error, {:phoenix_pubsub_not_available, Phoenix.PubSub}}
             ]
    end
  end

  defp event, do: event(:run_started, 0)
  defp event(type, seq), do: Event.new(type: type, seq: seq)

  defp unique_topic, do: "exagent:test:#{:erlang.unique_integer([:positive])}"
end
