defmodule ExAgent.Scenarios.ServerConcurrencyTest do
  @moduledoc """
  Regression tests for ExAgent.Server concurrency edges:

    * a stale :stream_done from an aborted stream must NOT integrate into the
      next run's history (the streaming handlers used to be unguarded),
    * abort racing with natural completion must not crash the server
      (terminate_child returns {:error, :not_found} when the task is already gone),
    * a pubsub backend returning {:error, _} must not crash the server.
  """

  use ExUnit.Case, async: true

  alias ExAgent.{Event, Models.Test, PubSub, Server}

  # Defined at top level so the `{ErrorPubSub, []}` tuple stores the full module
  # atom (a nested module would store only the short name and fail to resolve).
  #
  # A PubSub backend that always fails — proves the server is resilient.
  defmodule ErrorPubSub do
    @behaviour ExAgent.PubSub
    @impl true
    def broadcast(_config, _topic, _event), do: {:error, :boom}
    @impl true
    def subscribe(_config, _topic), do: {:error, :boom}
  end

  describe "stale stream messages do not corrupt a later run" do
    test "a :stream_done injected when no run is current is dropped" do
      {:ok, server} =
        Server.start_link(
          agent: ExAgent.new(model: %Test{label: "ok"}),
          pubsub: :local,
          agent_id: "stale-#{unique()}"
        )

      _ = :sys.get_state(server)

      # Inject a bogus stream_done for a run that was never started / already
      # ended. Before the guard this integrated 2 messages + emitted
      # :run_finished; now it must be a no-op.
      send(
        server,
        {:stream_done, "run_bogus", "req_bogus",
         %{output: "x", usage: nil, messages: bogus_messages()}}
      )

      # Let the GenServer process the message.
      _ = :sys.get_state(server)

      assert Server.history(server) == []
      assert Server.usage(server).input_tokens == 0
    end
  end

  describe "abort racing with completion does not crash the server" do
    test "abort after a run already finished returns :ok and keeps the server alive" do
      {:ok, server} =
        start_server(model: %Test{label: "done"}, agent_id: "abort-race-#{unique()}")

      # Run to completion, then abort (task is gone by now).
      assert {:ok, _} = Server.chat(server, "go")
      assert :ok = Server.abort(server)
      assert %{status: :idle} = Server.health(server)
    end
  end

  describe "a pubsub backend returning {:error, _} does not crash the server" do
    test "the run still returns its result" do
      {:ok, server} =
        Server.start_link(
          agent: ExAgent.new(model: %Test{label: "ok"}),
          pubsub: {ErrorPubSub, []},
          agent_id: "pubsub-err-#{unique()}"
        )

      # The backend always errors; the run must still complete normally.
      assert {:ok, %{output: "ok"}} = Server.chat(server, "go")
      assert %{status: :idle} = Server.health(server)
    end
  end

  # ---------------------------------------------------------------------------
  defp unique, do: :erlang.unique_integer([:positive])

  defp start_server(opts) do
    model = Keyword.get(opts, :model, %Test{label: "hi"})
    agent = ExAgent.new(model: model)

    {:ok, pid} =
      Server.start_link(
        agent: agent,
        agent_id: Keyword.fetch!(opts, :agent_id),
        pubsub: Keyword.get(opts, :pubsub, :local)
      )

    _ = :sys.get_state(pid)
    {:ok, pid}
  end

  defp bogus_messages do
    alias ExAgent.Message
    alias ExAgent.Message.Part

    [
      Message.new_request([%Part.User{content: "bogus"}]),
      Message.new_response([%Part.Text{content: "bogus"}], model_name: "test")
    ]
  end
end
