# Run with: mix run examples/dnd_session.exs
#
# A miniature D&D round, run entirely offline (TestModel, no API key).
#
# It shows the full coordination stack for the D&D use case:
#
#   * a DM agent (ExAgent.Server) whose tool mutates the shared world,
#   * a bot player agent that takes its turn,
#   * a human "player" turn (driven by the script — in a real app, a LiveView),
#   * an ExAgent.Session coordinating them (SupervisorPolicy: DM between every
#     actor) over a single-writer shared_state (the world), with events.
#
# Nothing here is D&D-specific to ExAgent — the Session is agnostic. The "world"
# is just a map; in a real game it'd be an Ecto schema.

alias ExAgent.{Event, Message.Part, Models.Test, PubSub, Server, Session}
alias ExAgent.Session.{Participant, SharedState}

# --- The shared world (single-writer: only the Session mutates it) ---------
# In a real app this would be an Ecto embedded_schema. Here, a plain map.
defmodule World do
  def new, do: %{round: 1, scene: "a dark tavern", goblin_hp: 7, log: []}

  def change(world, opts) do
    world
    |> maybe(:scene, opts[:scene])
    |> maybe(:goblin_hp, opts[:goblin_hp] && max(0, world.goblin_hp + opts[:goblin_hp]))
    |> Map.put(:log, [{Keyword.get(opts, :by, "?"), Keyword.get(opts, :say, "")} | world.log])
  end

  defp maybe(map, _key, nil), do: map
  defp maybe(map, key, value), do: Map.put(map, key, value)
end

# --- DM agent: narrates and sets the scene via a tool ----------------------
# The tool receives a SharedState handle in deps and proposes a change through
# the Session (single-writer). Offline-scripted narration.
narrate_tool =
  ExAgent.Tool.new(
    name: "set_scene",
    description: "Narrate and update the scene.",
    parameters_json_schema: %{
      "type" => "object",
      "properties" => %{"narration" => %{"type" => "string"}},
      "required" => ["narration"]
    },
    takes_ctx: true,
    call: fn ctx, %{"narration" => text} ->
      handle = ctx.deps

      {:ok, _world} =
        SharedState.propose_change(handle, fn w ->
          {:ok, World.change(w, scene: text, by: "dm", say: text)}
        end)

      {:ok, "scene set"}
    end
  )

{:ok, dm} =
  Server.start_link(
    agent:
      ExAgent.new(
        # Two DM turns: each is a set_scene tool call followed by narration text.
        model: %Test{
          script: [
            {:tool_calls,
             [%Part.ToolCall{tool_name: "set_scene", args: %{"narration" => "a tense tavern"}}]},
            "The goblin snarls across the room!",
            {:tool_calls,
             [%Part.ToolCall{tool_name: "set_scene", args: %{"narration" => "chaos erupts"}}]},
            "The goblin staggers, wounded!"
          ]
        },
        instructions: "You are the Dungeon Master.",
        tools: [narrate_tool]
      ),
    agent_id: "dnd_dm",
    pubsub: :local
  )

# --- Bot player: attacks on its turn ---------------------------------------
attack_tool =
  ExAgent.Tool.new(
    name: "attack",
    description: "Attack the goblin for N damage.",
    parameters_json_schema: %{
      "type" => "object",
      "properties" => %{"damage" => %{"type" => "integer"}},
      "required" => ["damage"]
    },
    takes_ctx: true,
    call: fn ctx, %{"damage" => dmg} ->
      handle = ctx.deps

      {:ok, _world} =
        SharedState.propose_change(handle, fn w ->
          {:ok, World.change(w, goblin_hp: -dmg, by: "bot", say: "bot hits for #{dmg}")}
        end)

      {:ok, "attacked"}
    end
  )

{:ok, bot} =
  Server.start_link(
    agent:
      ExAgent.new(
        # One bot turn: an attack tool call followed by a battle cry.
        model: %Test{
          script: [
            {:tool_calls, [%Part.ToolCall{tool_name: "attack", args: %{"damage" => 3}}]},
            "I swing my sword!"
          ]
        },
        instructions: "You are a brave bot adventurer.",
        tools: [attack_tool]
      ),
    agent_id: "dnd_bot",
    pubsub: :local
  )

# --- The session: DM alternates with the bot and a human -------------------
{:ok, game} =
  Session.start_link(
    shared_state: World.new(),
    # DM goes between every actor: dm, bot, dm, human, dm, bot, …
    policy: {:supervisor, supervisor: "dm", workers: ["bot", "human"]},
    participants: [
      Participant.new(id: "dm", kind: :agent, ref: dm),
      Participant.new(id: "bot", kind: :agent, ref: bot),
      Participant.new(id: "human", kind: :human)
    ],
    session_id: "dnd_game",
    pubsub: :local
  )

:ok = PubSub.subscribe({PubSub.Local, []}, Event.session_topic("dnd_game"))
{:ok, _first} = Session.start(game)

IO.puts("=== D&D round (DM, bot, human coordinated by Session) ===\n")

# Helpers as closures over the shared `game` / agent servers.
drive_agent = fn id, server, _tool, _args ->
  handle = SharedState.new(game, id)
  # One run: the model calls its tool (mutating the world via the handle), then
  # narrates. The narration is the run's final text output.
  {:ok, %{output: narration}} = Server.chat(server, "your turn", deps: handle)
  {:ok, _next} = Session.end_turn(game, id)
  IO.puts("  → #{narration}")
  :ok
end

human_turn = fn action, damage ->
  {:ok, _world, _next} =
    Session.take_turn(game, "human", fn w ->
      {:ok, World.change(w, goblin_hp: damage, by: "human", say: action)}
    end)

  IO.puts("[human] #{action}")
  :ok
end

print_world = fn ->
  w = Session.read_state(game)
  IO.puts("  world: goblin_hp=#{w.goblin_hp}, scene=#{inspect(w.scene)}")
end

# Drive a few turns. The human turn is played by the script (in a real app, a
# LiveView would call take_turn when the player submits an action).
rounds = [
  {"dm", fn -> drive_agent.("dm", dm, "set_scene", %{"narration" => "tavern, tense"}) end},
  {"bot", fn -> drive_agent.("bot", bot, "attack", %{"damage" => 3}) end},
  {"dm", fn -> drive_agent.("dm", dm, "set_scene", %{"narration" => "goblin reels"}) end},
  {"human", fn -> human_turn.("I cast firebolt for 4 damage!", -4) end}
]

for {who, turn} <- rounds do
  current = Session.current(game)
  IO.puts("[#{who}] (turn was #{current})")
  turn.()
  print_world.()
end

IO.puts("\n=== final world ===")
IO.inspect(Session.read_state(game), label: "world", pretty: true)
:ok = Session.close(game)
