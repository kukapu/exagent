---
name: exagent-server
description: >
  Use this skill when the user wants a long-lived, stateful, conversation-aware
  agent with the `exagent` Hex package (Layer 1): starting a supervised
  `ExAgent.Server` via `AgentSupervisor.start_agent/1`, preserving history and
  usage across turns with `chat/3`/`send_message/3`/`stream/3`/`steer/2`/`abort/1`,
  subscribing to `ExAgent.Event` envelopes over `ExAgent.PubSub`, or handling
  backpressure (`:busy` / `:queue_full`). Triggers: agente stateful, agente con
  memoria, supervised agent, ExAgent.Server, chat send_message, events pubsub,
  agent_topic, LiveView agent, steer/abort agent, durable agent in memory.
---

# exagent-server — a supervised, stateful, event-emitting agent (Layer 1)

`ExAgent.Server` keeps an agent **alive across runs**: it preserves conversation
history, accumulates token usage, threads **stateful models** from one run to the
next, and emits `ExAgent.Event`s over `ExAgent.PubSub` so LiveView/CLI can observe
every run in real time. It does **not** coordinate multiple participants (that's
`ExAgent.Session`).

## Prerequisites

Host app depends on `{:exagent, "~> 1.0"}`. The `ExAgent.AgentSupervisor`
(DynamicSupervisor) and `ExAgent.PubSub.Local` registry are already started by
exAgent's application tree.

## Workflow

### 1. Start a supervised agent

```elixir
{:ok, dm} =
  ExAgent.AgentSupervisor.start_agent(
    agent: ExAgent.new(model: "openai:gpt-4o", instructions: "You are a DM."),
    agent_id: "dm",
    pubsub: :local
  )
```

`agent_id` is the stable correlation key for events/store. `pubsub: :local`
enables the in-process Registry pubsub (needed to observe events). You can also
start standalone with `ExAgent.Server.start_link/1` (same opts).

### 2. Talk to it — sync and async

```elixir
# synchronous: blocks until the run finishes (timeout :infinity by default)
{:ok, %{output: _}} = ExAgent.Server.chat(dm, "I enter the tavern.")
{:ok, %{output: _}} = ExAgent.Server.chat(dm, "I pick the lock.")   # sees prior turn

# asynchronous: returns immediately; result arrives as a :run_finished event
{:ok, request_id} = ExAgent.Server.send_message(dm, "describe the room")

# stream text deltas (arrive as :text_delta events)
{:ok, _request_id} = ExAgent.Server.stream(dm, "count to five")

ExAgent.Server.abort(dm)       # cancel the in-flight run (keeps the server responsive)
ExAgent.Server.health(dm)      # %{status: :idle | :running, pending: n}
ExAgent.Server.usage(dm)       # accumulated %Usage{}
ExAgent.Server.history(dm)     # [ExAgent.Message.t()]
```

### 3. Subscribe to events

```elixir
:ok = ExAgent.PubSub.subscribe({ExAgent.PubSub.Local, []}, ExAgent.Event.agent_topic("dm"))

receive do
  {:exagent_event, %ExAgent.Event{type: :run_finished, payload: p, seq: n}} ->
    IO.puts("done (seq=#{n}): #{inspect(p)}")
end
```

Topic is `"exagent:agent:<agent_id>"` (`ExAgent.Event.agent_topic/1`). The `seq`
field is monotonic per agent. Key event types: `:run_started`, `:run_finished`,
`:run_failed`, `:server_request_cancelled`, `:text_delta`.

## `start_agent/1` / `start_link/1` options

| key | default | notes |
|---|---|---|
| `:agent` | — | **required**. An `ExAgent.t()` from `ExAgent.new/1`. |
| `:agent_id` | auto | stable id for events/store correlation. |
| `:name` | — | registered GenServer name (lookup by name then). |
| `:pubsub` | `nil` | `nil`/`:none`/`:local`/`{module, config}`. `:local` to observe events. |
| `:store` | `nil` | `:ets`/`{module, config}` → checkpoint after every run (see `exagent-store`). |
| `:max_pending` | `8` | max queued async requests before `:queue_full`. |
| `:metadata` | `%{}` | free-form map attached to every emitted event. |

`chat/3`, `send_message/3`, `stream/3`, `steer/2` forward run options
(`:deps`, `:model_settings`, …) to `ExAgent.run/3`.

## Concurrency model & backpressure

Runs execute in a **supervised task** (`ExAgent.TaskSupervisor`), so the GenServer
stays responsive during long runs.

- `chat/3` — synchronous; **refuses to start if busy** → `{:error, :busy}`.
- `send_message/3` / `steer/2` — **enqueue** up to `max_pending`, then `{:error, :queue_full}`.
- `stream/3` — async text streaming; `{:error, :busy}` if a run is in flight.
- `steer/2` — places a high-priority follow-up at the **front** of the queue; it
  does **not** mutate an HTTP request already in flight.
- `abort/1` — cancels the in-flight run and emits `:server_request_cancelled`.

## Wiring into LiveView

`pubsub: :local` is in-process. For a Phoenix app use the `Phoenix` pubsub
adapter (delegates to `Phoenix.PubSub`, no hard dep) so LiveView processes can
subscribe:

```elixir
# start with a Phoenix pubsub instead of :local
ExAgent.AgentSupervisor.start_agent(
  agent: agent, agent_id: "dm",
  pubsub: {ExAgent.PubSub.Phoenix, [pubsub: MyApp.PubSub]}
)

# in a LiveView:
@impl true
def mount(_p, _s, socket) do
  ExAgent.PubSub.subscribe({ExAgent.PubSub.Phoenix, [pubsub: MyApp.PubSub]},
    ExAgent.Event.agent_topic("dm"))
  {:ok, socket}
end

@impl true
def handle_info({:exagent_event, %ExAgent.Event{type: :text_delta, payload: %{text: t}}}, socket) do
  {:noreply, update(socket, :buffer, &(&1 <> t))}
end
```

## Gotchas

- **Without `pubsub: :local` (or a Phoenix adapter) you get no events** — the
  default `PubSub.None` is a no-op. Async `send_message/3`/`stream/3` still *work*
  but you'll never observe the result event.
- `chat/3` blocks the caller with **`:infinity` timeout** by default — fine for a
  GenServer-to-GenServer call, risky from a request handler; pass `timeout: ms` or
  use `send_message/3` + events.
- History/usage/stateful-model are kept **in memory** in the Server process. To
  survive crashes/restarts, add `store:` (see `exagent-store`).
- A crashed agent is isolated: the `AgentSupervisor` (`max_restarts: 100/5s`) won't
  take down siblings, and a `:transient` restart means it won't respawn unless your
  host app restarts it. Restart manually via `start_agent/1` (rehydrates from store).
- The Server **threads the updated model struct** between runs — so a scripted
  `%ExAgent.Models.Test{script: [...]}` advances through the script across chats.
- `stream/3` surfaces text deltas but does **not** run a full agentic tool loop;
  for tool loops use `chat/3`/`send_message/3`.

## Validation

- Offline smoke (no key): start with `ExAgent.new(model: "test", ...)` and call
  `chat/3` twice — second reply should reflect the scripted script index advancing.
- Subscribe to the agent topic and assert a `:run_finished` arrives after a `chat`.
- `ExAgent.Server.health(pid)` should report `status: :idle, pending: 0` between runs.

## Troubleshooting

- `{:error, :busy}` from `chat/3` → a run is in flight. Use `send_message/3`
  (queues) or `abort/1` first.
- `{:error, :queue_full}` → too many pending async messages; raise `:max_pending`
  or drain the queue / apply your own backpressure.
- No events arriving → `pubsub` is `nil`/`:none`; set `:local` (or the Phoenix
  adapter) and re-subscribe to `ExAgent.Event.agent_topic(agent_id)`.
- Server not restarting with its history → `store:` is unset; add `store: :ets`
  (or Postgres) for checkpoint+rehydrate.
