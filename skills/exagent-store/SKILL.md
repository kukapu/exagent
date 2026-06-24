---
name: exagent-store
description: >
  Use this skill when the user wants durable/resumable agents or sessions with the
  `exagent` Hex package (Layer 2): enabling snapshots via `store:` on
  `ExAgent.AgentSupervisor.start_agent/1` or `ExAgent.Session`, using the default
  in-process `ExAgent.Store.ETS`, wiring durable `ExAgent.Store.Postgres`
  (`migrate/1`, `{ExAgent.Store.Postgres, MyApp.Repo}`), checkpoint/rehydrate after
  crash, or implementing a custom `ExAgent.Store` behaviour. Triggers: durable
  agent, persist agent, snapshots, resume after crash, ExAgent.Store, Store.ETS,
  Store.Postgres, exagent_snapshots, checkpoint rehydrate, serializar agente.
---

# exagent-store — snapshots & resume (Layer 2)

Point an `ExAgent.Server` (or `ExAgent.Session`) at a **store** and it
**checkpoints after every run and rehydrates on restart**, surviving crashes.
The store is a pluggable behaviour; exAgent ships `ETS` (in-process) and
`Postgres` (durable, multi-node). exAgent **never owns a database** — the host
app does.

## Prerequisites

- Host app depends on `{:exagent, "~> 1.0"}`.
- For Postgres durability, the **host app** adds (exAgent does not): `{:ecto_sql, "~> 3.0"}`,
  `{:postgrex, "~> 0.19"}`, and owns the `Ecto.Repo` + connection pool.

## Workflow

### 1. In-process snapshots (ETS, default — dev/test)

```elixir
ExAgent.AgentSupervisor.start_agent(
  agent: agent_template,
  agent_id: "dm",
  store: :ets          # → {ExAgent.Store.ETS, ExAgent.Store.ETS}
)
```

Survives the agent process crashing (rehydrates from the ETS table, which lives in
exAgent's supervision tree). Does **not** survive a full node restart.

### 2. Durable snapshots (Postgres)

```elixir
# 1) once: create the table (migration or at boot)
ExAgent.Store.Postgres.migrate(MyApp.Repo)

# 2) point the server at the store
ExAgent.AgentSupervisor.start_agent(
  agent: agent_template,
  agent_id: "dm",
  store: {ExAgent.Store.Postgres, MyApp.Repo}
)
```

Default table is `exagent_snapshots`. Override it:

```elixir
store: {ExAgent.Store.Postgres, {MyApp.Repo, table: "my_snapshots"}}
```

Now history/usage/metadata survive node restarts and are visible across nodes.

### 3. Works for sessions too

`ExAgent.Session.start_link/1` takes the same `store:` option — it checkpoints
`shared_state` + turn position and rehydrates coordination state on restart (the
live participant `ref`s come from `:participants` on restart).

## How rehydrate works

The persisted `ExAgent.Server.Snapshot` carries **only serializable state**
(history + usage + metadata). On restart:
- exAgent loads the snapshot by `agent_id`.
- The **live model + tools come from the `agent:` template** you pass to
  `start_agent/1`, never from the snapshot.

So the "template" (model config, tools, instructions) is supplied fresh by your
app on every start; the conversation memory is restored from the store.

## `store:` accepted forms

| form | resolves to |
|---|---|
| `nil` / omitted | `nil` — no persistence (one-shot friendly, the default) |
| `:ets` | `{ExAgent.Store.ETS, ExAgent.Store.ETS}` |
| `mod` (atom) | `{mod, []}` |
| `{mod, config}` | as-is (e.g. `{ExAgent.Store.Postgres, MyApp.Repo}`) |

## Implementing a custom store

Implement the `ExAgent.Store` behaviour. Reference as `{MyStore, config}`:

```elixir
defmodule MyApp.Store.Redis do
  @behaviour ExAgent.Store
  alias ExAgent.Server.Snapshot

  @impl true
  def save_agent_snapshot(conn, %Snapshot{} = snap),
    do: Redix.command(conn, ["SET", "agent:#{snap.agent_id}", Snapshot.serialize(snap)])

  @impl true
  def load_agent_snapshot(conn, agent_id) do
    case Redix.command(conn, ["GET", "agent:#{agent_id}"]) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, bin} -> Snapshot.deserialize(bin)
    end
  end

  @impl true
  def list_agent_snapshots(conn), do: []   # implement as needed
  @impl true
  def delete_agent_snapshot(conn, agent_id), do: :ok

  # session callbacks are @optional_callbacks — implement if you need sessions
end
```

Required callbacks: `save_agent_snapshot/2`, `load_agent_snapshot/2`,
`list_agent_snapshots/1`, `delete_agent_snapshot/2`. Session callbacks
(`save/load/delete_session_snapshot`) are `@optional_callbacks`.

## Gotchas — the portability rule (important)

- Snapshots round-trip through **JSON** (`Snapshot.serialize/deserialize`), **never**
  `term_to_binary`. This refuses to persist non-serializable state: **pids,
  secrets, refs, function captures/tool closures**. Don't try to stuff those into
  `metadata`; they will be rejected or dropped.
- The live **model and tools are NOT persisted** — they come from the `agent:`
  template on restart. A stateful model (e.g. `%ExAgent.Models.Test{script: ...}`)
  does not resume mid-script from a snapshot; the template's script starts fresh.
- `Store.ETS` lives **in-process** — it survives an agent GenServer crash but **not**
  a BEAM VM restart. Use `Store.Postgres` for real durability.
- exAgent issues **parameterized SQL against one table only** and never touches your
  repo's migrations — call `Store.Postgres.migrate(MyApp.Repo)` yourself (once).
- Persisting fails (e.g. DB down) is **swallowed + logged**, never crashes the run
  or the Server — best-effort by design.
- Persistence is **per-run checkpointing**, not per-tool. For exactly-once
  side effects, make tools idempotent or guard with your own DB locking
  (see `examples/durable_oban.exs`).

## Validation

- ETS round-trip: start an agent with `store: :ets`, `chat/3` once, stop it
  (`AgentSupervisor.stop_agent/1`), restart with the same `agent_id` + `store: :ets`,
  then `Server.history/1` — the prior turn should be present.
- Postgres: after a run, `SELECT data FROM exagent_snapshots WHERE key = 'agent:<id>'`.
- For tests requiring Postgres, set `EXAGENT_PG_HOST`/`EXAGENT_PG_PORT` and tag the
  test `:postgres` (auto-skipped without a DB).

## Troubleshooting

- Agent restarts with **empty history** → `store:` is `nil`, or you restarted with a
  different `agent_id`. The id is the lookup key.
- `(Postgrex.Error) relation "exagent_snapshots" does not exist` → you skipped
  `Store.Postgres.migrate(MyApp.Repo)`.
- Snapshot rejected as non-serializable → you put a pid/ref/secret/anonymous fn into
  agent `metadata` or deps; store only plain JSON-portable data.
- Custom store not called → did you pass `{MyStore, config}` (a tuple), not a bare
  atom? `Store.normalize/1` maps `:ets`/`nil` specially.
