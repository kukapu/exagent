# Run with: mix run examples/stateful_agent.exs
#
# Demonstrates ExAgent.Server (Roadmap Phase 1): a supervised, long-lived agent
# that keeps conversation history across many turns, preserves a stateful model
# between runs, and emits ExAgent.Event envelopes over the Local PubSub.
#
# Uses the in-process TestModel — no API key needed.

alias ExAgent.{Event, Models.Test, PubSub, Server}

# A scripted model whose replies advance turn by turn. Because ExAgent.Server
# threads the (updated) model struct from one run to the next, the script index
# keeps advancing — proving stateful model preservation across chats.
model = %Test{
  script: [
    "Greetings, traveller. The tavern is warm tonight.",
    "You roll a 14 — barely enough to pick the lock.",
    "The guard didn't see you. For now.",
    "Dawn breaks. Your adventure continues..."
  ]
}

# Start a supervised agent under the app's ExAgent.AgentSupervisor and enable the
# Local PubSub so we can observe events.
{:ok, pid} =
  ExAgent.AgentSupervisor.start_agent(
    agent: ExAgent.new(model: model, instructions: "You are a DM."),
    agent_id: "dm",
    pubsub: :local
  )

# Subscribe to the agent's event topic. Every run publishes versioned envelopes
# with a monotonic `seq`.
:ok = PubSub.subscribe({ExAgent.PubSub.Local, []}, Event.agent_topic("dm"))

# A small collector process that prints each event as it arrives.
collector =
  spawn(fn ->
    Enum.each(Stream.repeatedly(fn -> receive(do: ({:exagent_event, e} -> e)) end), fn e ->
      IO.puts("[event seq=#{e.seq}] #{e.type}")
    end)
  end)

# Bind the collector to the topic by also subscribing it.
PubSub.subscribe({ExAgent.PubSub.Local, []}, Event.agent_topic("dm"))

IO.puts("=== chat 1 ===")
{:ok, %{output: out1}} = Server.chat(pid, "I enter the tavern.")
IO.puts("DM: #{out1}")

IO.puts("\n=== chat 2 (history is preserved) ===")
{:ok, %{output: out2}} = Server.chat(pid, "I try to pick the lock on the back door.")
IO.puts("DM: #{out2}")

IO.puts("\n=== chat 3 ===")
{:ok, %{output: out3}} = Server.chat(pid, "Does the guard notice?")
IO.puts("DM: #{out3}")

IO.puts("\n=== accumulated usage ===")
IO.inspect(Server.usage(pid), label: "usage")

IO.puts("\n=== history length (req/resp per turn) ===")
IO.inspect(length(Server.history(pid)), label: "messages")

# Async dispatch: returns immediately, result arrives as a :run_finished event.
IO.puts("\n=== send_message (async) ===")
{:ok, request_id} = Server.send_message(pid, "anything")
IO.puts("queued request #{request_id}, waiting for the event...")

receive do
  {:exagent_event, %Event{type: :run_finished, request_id: ^request_id}} ->
    IO.puts("got :run_finished for #{request_id}")
after
  1_000 -> IO.puts("(no event received)")
end

Process.exit(collector, :shutdown)
:ok = ExAgent.AgentSupervisor.stop_agent(pid)
