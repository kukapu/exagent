defmodule ExAgent.ServerTest do
  # The server spawns tasks and relies on the app-wide ExAgent.TaskSupervisor /
  # ExAgent.PubSub.Registry, so we can't be fully async against other suites that
  # touch those, but each test owns its own server.
  use ExUnit.Case, async: true

  alias ExAgent.{Event, Models.Test, PubSub, Server}

  describe "chat/3 — stateful conversation" do
    test "threads history across chats and preserves the stateful model" do
      # If the model were NOT preserved between chats, the script index would
      # reset and both chats would return "hello".
      model = %Test{script: ["hello", "world"]}
      {:ok, server} = start_server(model: model)

      assert {:ok, %{output: "hello"}} = Server.chat(server, "msg one")
      assert {:ok, %{output: "world"}} = Server.chat(server, "msg two")

      history = Server.history(server)
      # req(instructions+user) · resp · req(user) · resp
      assert length(history) == 4

      usage = Server.usage(server)
      assert usage.input_tokens > 0 and usage.output_tokens > 0
    end

    test "does not duplicate system instructions on subsequent chats" do
      model = %Test{label: "ok"}
      {:ok, server} = start_server(model: model, instructions: "you are a DM")

      Server.chat(server, "first")
      Server.chat(server, "second")

      [%ExAgent.Message.Request{} = first_req | rest] = Server.history(server)

      # First request carries the system instruction.
      assert Enum.any?(first_req.parts, &match?(%ExAgent.Message.Part.System{}, &1))

      # The second request (third message) carries only the new user prompt.
      second_req = Enum.at(rest, 1)

      assert %ExAgent.Message.Request{parts: [%ExAgent.Message.Part.User{content: "second"}]} =
               second_req
    end

    test "returns :busy when a run is already in flight" do
      model = %Test{
        script: [
          fn ->
            Process.sleep(150)
            "done"
          end
        ]
      }

      {:ok, server} = start_server(model: model)

      runner =
        Task.async(fn -> Server.chat(server, "blocking") end)

      wait_for_status(server, :running)

      assert {:error, :busy} = Server.chat(server, "meanwhile")

      Task.await(runner)
    end
  end

  describe "send_message/3 — async via events" do
    test "delivers the result as a :run_finished event on the agent topic" do
      {:ok, server} = start_server(pubsub: :local, agent_id: "async-agent")

      :ok = PubSub.subscribe({ExAgent.PubSub.Local, []}, Event.agent_topic("async-agent"))

      {:ok, request_id} = Server.send_message(server, "hi")

      assert_receive {:exagent_event, %Event{type: :run_started, request_id: ^request_id}}
      assert_receive {:exagent_event, %Event{type: :run_finished, request_id: ^request_id}}
    end
  end

  describe "events" do
    test "published with monotonic seq and carry agent_id + request_id" do
      {:ok, server} = start_server(pubsub: :local, agent_id: "evt-agent")

      :ok = PubSub.subscribe({ExAgent.PubSub.Local, []}, Event.agent_topic("evt-agent"))

      assert {:ok, _} = Server.chat(server, "hello")

      events = collect_events(200)

      types = Enum.map(events, & &1.type)
      assert :run_started in types
      assert :run_finished in types

      seqs = Enum.map(events, & &1.seq)
      assert seqs == Enum.sort(seqs) and length(seqs) > 1
      assert Enum.all?(events, &(&1.agent_id == "evt-agent"))
      assert Enum.all?(events, &(&1.version == 1))
    end
  end

  describe "abort/1" do
    test "cancels the in-flight run and emits :server_request_cancelled" do
      model = %Test{
        script: [
          fn ->
            Process.sleep(2_000)
            "never"
          end
        ]
      }

      {:ok, server} = start_server(model: model, pubsub: :local, agent_id: "abort-agent")

      :ok = PubSub.subscribe({ExAgent.PubSub.Local, []}, Event.agent_topic("abort-agent"))

      {:ok, request_id} = Server.send_message(server, "block")
      wait_for_status(server, :running)

      assert :ok = Server.abort(server)

      assert_receive {:exagent_event,
                      %Event{type: :server_request_cancelled, request_id: ^request_id}},
                     500

      # The server must be idle again immediately.
      assert %{status: :idle} = Server.health(server)
    end
  end

  describe "backpressure" do
    test "send_message returns :queue_full past max_pending while busy" do
      model = %Test{
        script: [
          fn ->
            Process.sleep(500)
            "done"
          end
        ]
      }

      {:ok, server} = start_server(model: model, max_pending: 2)

      # First starts immediately (idle → running); the rest queue up.
      assert {:ok, _} = Server.send_message(server, "running")
      wait_for_status(server, :running)

      assert {:ok, _} = Server.send_message(server, "q1")
      assert {:ok, _} = Server.send_message(server, "q2")
      assert {:error, :queue_full} = Server.send_message(server, "overflow")

      Server.abort(server)
    end

    test "steer/2 enqueues at the front" do
      model = %Test{
        script: [
          fn ->
            Process.sleep(500)
            "done"
          end
        ]
      }

      {:ok, server} = start_server(model: model, max_pending: 4)

      assert {:ok, _} = Server.send_message(server, "rear-1")
      wait_for_status(server, :running)

      assert {:ok, _} = Server.send_message(server, "rear-2")
      assert {:ok, front_id} = Server.steer(server, "front")

      health = Server.health(server)
      assert health.pending == 2
      # The queue depth counts both; order is validated by drain in integration.
      assert is_binary(front_id)

      Server.abort(server)
    end
  end

  describe "stream/3 — text deltas via events" do
    test "publishes :text_delta chunks then :run_finished" do
      {:ok, server} =
        start_server(pubsub: :local, agent_id: "stream-agent", model: %Test{label: "hello world"})

      :ok = PubSub.subscribe({ExAgent.PubSub.Local, []}, Event.agent_topic("stream-agent"))

      assert {:ok, request_id} = Server.stream(server, "hi")

      events = collect_events(150)
      deltas = for %Event{type: :text_delta, payload: %{text: t}} <- events, do: t

      assert deltas != []
      assert Enum.join(deltas) == "hello world"

      assert %Event{type: :run_finished, request_id: ^request_id} =
               Enum.find(events, &(&1.type == :run_finished))
    end

    test "returns :busy if a run is in flight" do
      model = %Test{
        script: [
          fn ->
            Process.sleep(200)
            "done"
          end
        ]
      }

      {:ok, server} = start_server(model: model)

      runner = Task.async(fn -> Server.chat(server, "blocking") end)
      wait_for_status(server, :running)

      assert {:error, :busy} = Server.stream(server, "meanwhile")
      Task.await(runner)
    end
  end

  describe "control / introspection" do
    test "set_model/2 replaces the model when idle" do
      {:ok, server} = start_server(model: %Test{label: "old"})
      assert :ok = Server.set_model(server, %Test{label: "new"})
      assert {:ok, %{output: "new"}} = Server.chat(server, "x")
    end

    test "set_model/2 with a string spec resolves it" do
      {:ok, server} = start_server(model: %Test{label: "x"})
      assert :ok = Server.set_model(server, "test:resolved")
      assert {:ok, %{output: "resolved"}} = Server.chat(server, "x")
    end

    test "health/1 reports status and pending depth" do
      {:ok, server} = start_server(model: %Test{label: "x"})
      assert %{status: :idle, pending: 0} = Server.health(server)
    end

    test "reset/1 clears history and usage when idle" do
      {:ok, server} = start_server(model: %Test{label: "ok"})
      assert {:ok, _} = Server.chat(server, "first")
      assert {:ok, _} = Server.chat(server, "second")
      assert length(Server.history(server)) == 4
      assert Server.usage(server).input_tokens > 0

      assert :ok = Server.reset(server)

      assert Server.history(server) == []
      assert Server.usage(server).input_tokens == 0

      # The server keeps working after a reset.
      assert {:ok, %{output: "ok"}} = Server.chat(server, "fresh start")
      assert length(Server.history(server)) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_server(opts) do
    model = Keyword.get(opts, :model, %Test{label: "hi"})
    instructions = Keyword.get(opts, :instructions)
    agent = ExAgent.new(model: model, instructions: instructions)

    start_opts =
      [agent: agent]
      |> maybe_put(:pubsub, Keyword.get(opts, :pubsub))
      |> maybe_put(:agent_id, Keyword.get(opts, :agent_id))
      |> maybe_put(:max_pending, Keyword.get(opts, :max_pending))

    Server.start_link(start_opts)
  end

  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, key, value), do: Keyword.put(list, key, value)

  defp wait_for_status(server, status, tries \\ 100) do
    cond do
      tries <= 0 ->
        flunk("server never reached status #{inspect(status)}")

      Server.health(server).status == status ->
        :ok

      true ->
        Process.sleep(5)
        wait_for_status(server, status, tries - 1)
    end
  end

  defp collect_events(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect_events([], deadline)
  end

  defp do_collect_events(acc, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:exagent_event, %Event{} = e} -> do_collect_events([e | acc], deadline)
    after
      remaining -> Enum.reverse(acc)
    end
  end
end
