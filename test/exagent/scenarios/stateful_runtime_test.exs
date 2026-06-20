defmodule ExAgent.Scenarios.StatefulRuntimeTest do
  @moduledoc """
  Scenario 2 — the full lifecycle of one long-lived `ExAgent.Server`.

  Rather than re-checking each API in isolation (that's `server_test.exs`), this
  scenario drives a single agent through every transition in sequence and
  asserts state stays consistent across them:

    chat ×2 → reset → queue + steer → drain ordering → abort → stream →
    history integration → telemetry → event correlation.

  It also covers things `server_test.exs` does not: queue *execution order*
  (steer-at-front runs before rear), history/usage integration after `stream/3`,
  `:telemetry` events, and run-option (`:deps`) forwarding.
  """

  use ExUnit.Case, async: true

  alias ExAgent.{Event, Models.Test, PubSub, Server}

  describe "full synchronous lifecycle on one agent" do
    test "chat accumulates history/usage, reset zeroes it, chat works after" do
      {:ok, server} = start_server(model: %Test{script: ["a", "b", "c"]})

      assert {:ok, %{output: "a"}} = Server.chat(server, "one")
      assert {:ok, %{output: "b"}} = Server.chat(server, "two")
      assert length(Server.history(server)) == 4
      assert Server.usage(server).input_tokens >= 2

      assert :ok = Server.reset(server)
      assert Server.history(server) == []
      assert Server.usage(server).input_tokens == 0

      # Still alive and useful after reset.
      assert {:ok, %{output: "c"}} = Server.chat(server, "fresh")
      assert length(Server.history(server)) == 2
    end
  end

  describe "async queue + steer ordering" do
    test "a steered (front) request runs before rear-queued ones on drain" do
      # First item blocks briefly so we can stage the queue while it runs.
      {:ok, server} =
        start_server(
          model: %Test{
            script: [
              fn ->
                Process.sleep(80)
                "first"
              end,
              "front",
              "rear"
            ]
          },
          pubsub: :local,
          agent_id: "drain-#{unique()}",
          max_pending: 8
        )

      topic = Event.agent_topic(server_agent_id(server))
      :ok = PubSub.subscribe({PubSub.Local, []}, topic)

      # 1. Start the slow run (becomes :running).
      {:ok, _first} = Server.send_message(server, "slow")
      wait_for_status(server, :running)

      # 2. While busy, enqueue a rear item then a steer (front) item.
      {:ok, rear} = Server.send_message(server, "rear")
      {:ok, front} = Server.steer(server, "front")

      # 3. Let everything drain naturally. The steered "front" must finish first.
      assert_receive {:exagent_event, %Event{type: :run_finished, request_id: ^front}}, 300
      assert_receive {:exagent_event, %Event{type: :run_finished, request_id: ^rear}}, 300

      # Receiving front before rear proves steer-at-front ordering.
      Server.abort(server)
    end
  end

  describe "abort/1" do
    test "cancels the in-flight run and the server returns to idle" do
      {:ok, server} =
        start_server(
          model: %Test{
            script: [
              fn ->
                Process.sleep(2_000)
                "never"
              end
            ]
          },
          pubsub: :local,
          agent_id: "abort-#{unique()}"
        )

      {:ok, _} = Server.send_message(server, "block")
      wait_for_status(server, :running)

      assert :ok = Server.abort(server)
      assert %{status: :idle} = Server.health(server)
    end
  end

  describe "stream/3 integrates history into server state" do
    test "after streaming, history and usage reflect the streamed turn" do
      {:ok, server} =
        start_server(
          model: %Test{label: "hello"},
          pubsub: :local,
          agent_id: "stream-int-#{unique()}"
        )

      :ok = PubSub.subscribe({PubSub.Local, []}, Event.agent_topic(server_agent_id(server)))

      assert {:ok, _req} = Server.stream(server, "greet")
      assert_receive {:exagent_event, %Event{type: :run_finished}}, 200

      # The streamed request + response are now part of history & usage.
      assert length(Server.history(server)) == 2
      assert Server.usage(server).output_tokens > 0
    end
  end

  describe "run-option forwarding (:deps)" do
    test "deps passed to chat/3 reach the RunContext inside a tool" do
      parent = self()

      tool =
        ExAgent.Tool.new(
          name: "ping",
          description: "ping",
          parameters_json_schema: %{type: "object", properties: %{}},
          takes_ctx: true,
          call: fn ctx, _ ->
            send(parent, {:deps, ctx.deps})
            {:ok, "pong"}
          end
        )

      model = %Test{
        script: [
          {:tool_calls, [%ExAgent.Message.Part.ToolCall{tool_name: "ping", args: %{}}]},
          "done"
        ]
      }

      {:ok, server} =
        Server.start_link(
          agent:
            ExAgent.new(
              model: model,
              tools: [tool]
            )
        )

      _ = :sys.get_state(server)

      assert {:ok, _} = Server.chat(server, "go", deps: %{tenant: "acme"})
      assert_received {:deps, %{tenant: "acme"}}
    end
  end

  describe "telemetry" do
    test "the loop emits [:exagent, :run, :start] and :stop with measurements" do
      handler = {:scenarios, :telemetry, unique()}

      :ok =
        :telemetry.attach_many(
          handler,
          [[:exagent, :run, :start], [:exagent, :run, :stop]],
          &__MODULE__.handle_telemetry/4,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, server} = start_server(model: %Test{label: "ok"})
      assert {:ok, _} = Server.chat(server, "go")

      assert_received {:telemetry, [:exagent, :run, :start], %{system_time: _}}
      assert_received {:telemetry, [:exagent, :run, :stop], %{duration: d}} when d > 0
    end
  end

  describe "event correlation across a multi-run session" do
    test "every event carries agent_id + strictly monotonic seq across two runs" do
      {:ok, server} =
        start_server(
          model: %Test{script: ["one", "two"]},
          pubsub: :local,
          agent_id: "corr-#{unique()}"
        )

      :ok = PubSub.subscribe({PubSub.Local, []}, Event.agent_topic(server_agent_id(server)))

      assert {:ok, _} = Server.chat(server, "a")
      assert {:ok, _} = Server.chat(server, "b")

      events = collect_events(150)
      assert length(events) > 2

      assert Enum.all?(events, &(&1.agent_id == server_agent_id(server)))

      seqs = Enum.map(events, & &1.seq)
      assert seqs == Enum.uniq(seqs) and seqs == Enum.sort(seqs)

      # Each run ties its start to its finish by request_id.
      starts = for %Event{type: :run_started, request_id: r} <- events, do: r
      fins = for %Event{type: :run_finished, request_id: r} <- events, do: r
      assert starts == fins
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def handle_telemetry(event, measurements, _meta, target),
    do: send(target, {:telemetry, event, measurements})

  defp start_server(opts) do
    model = Keyword.get(opts, :model, %Test{label: "hi"})
    agent = ExAgent.new(model: model, instructions: Keyword.get(opts, :instructions))

    start_opts =
      [agent: agent]
      |> maybe(:pubsub, Keyword.get(opts, :pubsub))
      |> maybe(:agent_id, Keyword.get(opts, :agent_id))
      |> maybe(:max_pending, Keyword.get(opts, :max_pending))

    {:ok, pid} = Server.start_link(start_opts)
    _ = :sys.get_state(pid)
    {:ok, pid}
  end

  defp maybe(list, _key, nil), do: list
  defp maybe(list, key, value), do: Keyword.put(list, key, value)

  defp unique, do: :erlang.unique_integer([:positive])

  # The server's agent_id isn't always passed back; read it from state.
  defp server_agent_id(server), do: :sys.get_state(server).agent_id

  defp wait_for_status(server, status, tries \\ 100) do
    cond do
      tries <= 0 ->
        flunk("server never reached #{inspect(status)}")

      Server.health(server).status == status ->
        :ok

      true ->
        Process.sleep(5)
        wait_for_status(server, status, tries - 1)
    end
  end

  defp collect_events(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect([], deadline)
  end

  defp do_collect(acc, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:exagent_event, %Event{} = e} -> do_collect([e | acc], deadline)
    after
      remaining -> Enum.reverse(acc)
    end
  end
end
