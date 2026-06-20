# Run with: mix run examples/multi_agent_session.exs
#
# Demonstrates ExAgent.Session (Roadmap Phase 3): two TestModel agents
# coordinated by a round-robin policy over a shared "world" state. The Session is
# the single writer; each agent's turn proposes a change that the next agent
# sees. Offline — no API key needed.

alias ExAgent.{Event, Models.Test, PubSub, Server, Session}
alias ExAgent.Session.Participant

# Each "bot" is a stateful ExAgent.Server. On its turn, the driver asks it to
# describe an action; the model reply becomes a state change proposed through
# the SharedState handle. (Here the scripted reply is the action text itself.)
{:ok, bot_a} =
  Server.start_link(
    agent:
      ExAgent.new(
        model: %Test{script: ~w(attack defend cast)},
        instructions: "You are a fighter."
      ),
    agent_id: "bot_a"
  )

{:ok, bot_b} =
  Server.start_link(
    agent:
      ExAgent.new(model: %Test{script: ~w(dodge counter heal)}, instructions: "You are a rogue."),
    agent_id: "bot_b"
  )

{:ok, session} =
  Session.start_link(
    shared_state: %{round: 1, actions: []},
    policy: :round_robin,
    participants: [
      Participant.new(id: "fighter", kind: :agent, ref: bot_a),
      Participant.new(id: "rogue", kind: :agent, ref: bot_b)
    ],
    session_id: "skirmish",
    pubsub: :local
  )

:ok = PubSub.subscribe({PubSub.Local, []}, Event.session_topic("skirmish"))

IO.puts("=== starting session ===")
{:ok, first} = Session.start(session)
IO.puts("first to act: #{first}")

# A tiny driver: for each participant, run its agent server once and record its
# reply as a shared-state change. Three rounds (so both agents act a few times).
Enum.each(1..4, fn _ ->
  current = Session.current(session)
  %{ref: server} = Enum.find(Session.participants(session), &(&1.id == current))

  {:ok, %{output: action}} = Server.chat(server, "what do you do this turn?")

  {:ok, world, next} =
    Session.take_turn(session, current, fn s ->
      {:ok, %{s | actions: [{current, action} | s.actions]}}
    end)

  IO.puts("[#{current}] #{action}  →  next: #{next}")
end)

IO.puts("\n=== final shared state ===")
final = Session.read_state(session)
IO.inspect(final, label: "world")

IO.puts("\n=== closing ===")
:ok = Session.close(session)
IO.puts("status: #{Session.status(session)}")
