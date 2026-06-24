---
name: exagent-session
description: >
  Use this skill when the user wants multi-agent coordination / shared-state turns
  with the `exagent` Hex package (Layer 3): starting an `ExAgent.Session`,
  registering `ExAgent.Session.Participant`s, taking turns over `shared_state`
  via `take_turn/3`, choosing a `TurnPolicy` (`:round_robin` / `:initiative` /
  custom), reading/proposing state from inside a tool via `SharedState`, or using
  orchestration patterns (`ExAgent.Coordination` delegation/hand-off). Triggers:
  multi-agent, agents coordinados, turno por turno, shared state, ExAgent.Session,
  Participant, take_turn, turn policy round_robin initiative, SharedState handle,
  delegation handoff, several agents sharing state, game/session coordination.
---

# exagent-session — coordinated multi-agent turns over shared state (Layer 3)

`ExAgent.Session` owns a piece of app-defined `shared_state` and a set of
**participants** (agents backed by `ExAgent.Server`, or humans via LiveView), and
decides — through a pluggable `ExAgent.Session.TurnPolicy` — whose turn it is.
The Session is the **single writer** of `shared_state`; participants propose
changes through a change function.

## Prerequisites

Host app depends on `{:exagent, "~> 1.0"`. Typically each agent participant is a
long-lived `ExAgent.Server` (see `exagent-server`); humans are driven by your
LiveView/channel.

## Workflow

### 1. Start a session with participants and a policy

```elixir
alias ExAgent.Session
alias ExAgent.Session.Participant

{:ok, game} =
  Session.start_link(
    shared_state: %{round: 1, actions: []},
    policy: :round_robin,
    participants: [
      Participant.new(id: "fighter", kind: :agent, ref: bot_a_server),
      Participant.new(id: "rogue", kind: :agent, ref: bot_b_server)
    ],
    session_id: "skirmish",
    pubsub: :local
  )

{:ok, first} = Session.start(game)        # :created → :running; first = "fighter"
```

`Participant.new/1`: `:id` required, `:kind` is `:agent` or `:human` (default
`:human`), `:ref` holds whatever you need to drive the participant (pid/name).

### 2. Take turns — the single-writer rule

A turn = apply a `change_fn` to `shared_state` **atomically**, then advance:

```elixir
{:ok, world, next} =
  Session.take_turn(game, "fighter", fn s ->
    {:ok, %{s | actions: [{:fighter, "attack"} | s.actions]}}
  end)
# next == "rogue"; it sees the fighter's change via Session.read_state/1
```

`change_fn` is `(state) -> {:ok, new_state} | {:error, reason}` (a bare value is
accepted as the new state). `take_turn/3` returns `{:ok, new_state, next_id}` or
`{:error, reason}` (`:not_your_turn`, `:paused`, `{:not_running, status}`).

### 3. Drive an agent participant's turn

The host app runs the agent and records its reply as the change (the agent itself
doesn't know about the Session unless you wire a `SharedState` handle):

```elixir
current = Session.current(game)
%{ref: server} = Enum.find(Session.participants(game), &(&1.id == current))
{:ok, %{output: action}} = ExAgent.Server.chat(server, "what do you do this turn?")

{:ok, _world, _next} =
  Session.take_turn(game, current, fn s -> {:ok, %{s | actions: [{current, action} | s.actions]}} end)
```

### 4. Let tools inside an agent run reach the shared state

Place a `SharedState` handle in `RunContext.deps` so a tool can **read** and
**propose** changes without a mutable reference (still single-writer — the Session
applies it, only if it's this participant's turn):

```elixir
# build the handle when driving this participant's turn:
handle = ExAgent.Session.SharedState.new(game, "dm")
ExAgent.Server.chat(dm_server, "narrate the scene", deps: handle)

# inside a tool:
deftool set_scene(ctx, description :: String.t()) do
  {:ok, _new_state} =
    ExAgent.Session.SharedState.propose_change(ctx.deps, fn s ->
      {:ok, %{s | scene: description}}
    end)

  {:ok, "scene updated"}
end
```

`propose_change/2` calls `Session.update_state/3` — it mutates state **without**
advancing the turn (mid-turn changes). Finish the turn with `Session.end_turn/2`.

## `start_link/1` options

| key | default | notes |
|---|---|---|
| `:shared_state` | `nil` | app-defined initial state (any term). |
| `:policy` | `:round_robin` | `:round_robin` / `:initiative` / `{:initiative, order: [...]}` / `{module, opts}` / `module`. |
| `:participants` | `[]` | initial list of `Participant.t()`. |
| `:session_id` | auto | stable id for events/store. |
| `:pubsub` | `nil` | `nil`/`:none`/`:local`/`{module, config}`. |
| `:store` | `nil` | checkpoints `shared_state`+turn position; see `exagent-store`. |
| `:name` / `:metadata` | — | GenServer name / free-form map on every event. |

## Full session API

`start/1`, `current/1`, `participants/1`, `status/1` (`:created|:running|:paused|:closed|:done`),
`read_state/1` (anyone, read-only), `take_turn/3`, `update_state/3` (no turn advance),
`end_turn/2`, `handoff/2` (bypass policy — for rehydrate), `pause/1`, `resume/1`,
`close/1`, `join/2`, `leave/2`.

## Turn policies

- `:round_robin` — insertion order, cycling forever.
- `:initiative` / `{:initiative, order: ["rogue","fighter","wizard"]}` — explicit order, cycling forever.
- `{module, opts}` / `module` — custom: implement `ExAgent.Session.TurnPolicy`
  callbacks `init/1`, `next_participant/2` (`{:ok, id, state} | {:done, state}`),
  `can_act?/3`, and optional `participant_joined/2` / `participant_left/2`.

## Orchestration (`ExAgent.Coordination`)

Delegation (agent-as-tool; both runs' tokens counted together):

```elixir
helper = ExAgent.new(model: "openai:gpt-4o-mini", instructions: "You summarize.")
parent =
  ExAgent.new(model: "openai:gpt-4o",
    tools: [ExAgent.Coordination.delegation_tool(helper, name: "summarize")])
```

Hand-off inside a session (bypasses the policy, emits `:session_turn_changed`):

```elixir
{:ok, "wizard"} = ExAgent.Coordination.handoff(game, "wizard")
```

## Events

Topic `"exagent:session:<id>"` (`ExAgent.Event.session_topic/1`). Types:
`:session_started · :participant_joined · :participant_left · :session_turn_changed ·
:shared_state_updated · :session_paused · :session_resumed · :session_closed`.
Events carry ids/status, **never the bulk `shared_state`** — read it with `read_state/1`.

## Gotchas

- The Session is the **only** writer of `shared_state`. Never mutate it from a
  participant process; always go through `take_turn/3` / `update_state/3` /
  `SharedState.propose_change/2`.
- `take_turn/3` while not `:running` returns `{:error, :paused}` /
  `{:error, {:not_running, status}}`. Call `start/1` first (`:created → :running`).
- `propose_change/2` returns `{:error, :not_your_turn}` unless it's the owning
  participant's turn — so only pass the handle for the **current** participant.
- The `change_fn` must be **pure & serializable-friendly**: state that will be
  checkpointed to a store must be JSON-portable (no pids/secrets/closures).
- A participant leaving **mid-turn** auto-forfeits the turn and advances (or ends
  the session if the roster is empty) — no deadlock.
- On rehydrate from a `store:`, only the **serializable coordination state**
  (shared_state, turn position, roster ids/kinds) is restored — the **live `ref`s
  come from `:participants`** you pass on restart. Use `handoff/2` to restore the
  exact turn owner (the policy would otherwise compute its own "first").

## Validation

- Offline two-bot round-robin: `mix run examples/multi_agent_session.exs`
  (uses the TestModel — no key). Check each bot's reply lands in `shared_state`
  and the turn alternates.
- Subscribe to the session topic and assert `:session_turn_changed` /
  `:shared_state_updated` arrive in order with increasing `seq`.
- `Session.read_state/1` after every turn reflects the accumulated changes.

## Troubleshooting

- `{:error, :not_your_turn}` from a tool's `propose_change/2` → the handle's
  `participant_id` isn't the current one; rebuild the handle for `current/1`.
- Session stuck (no one acts) → the current participant left or its policy state
  is empty; `leave/2` auto-advances, but check `status/1` isn't `:paused`.
- Lost turn owner after restart/rehydrate → call `handoff/2` with the persisted
  owner id once the session is `:running`.
