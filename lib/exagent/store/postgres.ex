defmodule ExAgent.Store.Postgres do
  @moduledoc """
  A durable `ExAgent.Store` backed by PostgreSQL, for resume across crashes and
  multiple nodes.

  Snapshots are stored as **JSON** (the same strict serialization `ExAgent.Store.ETS`
  uses), never raw Erlang terms — so nothing non-serializable (pids, secrets,
  closures) can land in the database. The store is **DB-free by default** in the
  rest of exAgent: this module needs `ecto_sql` + `postgrex`, declared as optional
  dependencies that a host app adds when it wants a durable store.

  ## Wiring

  The store takes the host app's `Ecto.Repo` as its config (the host owns the
  database connection — exAgent never does):

      # 1) add deps in your app:
      #   {:ecto_sql, "~> 3.0"}, {:postgrex, "~> 0.19"}
      # 2) create the table once (migration or at boot):
      ExAgent.Store.Postgres.migrate(MyApp.Repo)
      # 3) use it:
      ExAgent.AgentSupervisor.start_agent(
        agent: agent_template,
        agent_id: "dm",
        store: {ExAgent.Store.Postgres, MyApp.Repo}
      )

  The snapshots table is `exagent_snapshots` by default; override it with
  `{ExAgent.Store.Postgres, {MyApp.Repo, table: "my_snapshots"}}`.

  ## Why not own the database?

  A library shouldn't own your connection pool, credentials or migrations. The
  repo comes from your app; exAgent only issues parameterized SQL against one
  table.
  """

  @behaviour ExAgent.Store

  alias ExAgent.Server.Snapshot

  @default_table "exagent_snapshots"

  # config forms: repo | {repo, opts} | {repo, table: "..."}
  defp conf(repo) when is_atom(repo), do: {repo, @default_table}

  defp conf({repo, opts}) when is_atom(repo) and is_list(opts),
    do: {repo, opts[:table] || @default_table}

  # ----- agents -------------------------------------------------------------
  @impl true
  def save_agent_snapshot(config, %Snapshot{} = snap) do
    {repo, table} = conf(config)

    sql =
      "INSERT INTO #{table} (key, data) VALUES ($1, $2) " <>
        "ON CONFLICT (key) DO UPDATE SET data = EXCLUDED.data, updated_at = now()"

    with {:ok, _} <- repo.query(sql, [agent_key(snap.agent_id), Snapshot.serialize(snap)]) do
      :ok
    end
  end

  @impl true
  def load_agent_snapshot(config, agent_id) do
    {repo, table} = conf(config)

    case repo.query("SELECT data FROM #{table} WHERE key = $1", [agent_key(agent_id)]) do
      {:ok, %{rows: [[binary | _] | _]}} -> Snapshot.deserialize(binary)
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, _} = e -> e
    end
  end

  @impl true
  def list_agent_snapshots(config) do
    {repo, table} = conf(config)

    case repo.query("SELECT data FROM #{table} WHERE key LIKE 'agent:%'", []) do
      {:ok, %{rows: rows}} ->
        Enum.flat_map(rows, fn [binary | _] ->
          case Snapshot.deserialize(binary) do
            {:ok, %Snapshot{} = s} -> [s]
            {:error, _} -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  @impl true
  def delete_agent_snapshot(config, agent_id) do
    {repo, table} = conf(config)

    with {:ok, _} <- repo.query("DELETE FROM #{table} WHERE key = $1", [agent_key(agent_id)]) do
      :ok
    end
  end

  # ----- sessions (Phase 3+) ------------------------------------------------
  @impl true
  def save_session_snapshot(config, snapshot) do
    {repo, table} = conf(config)
    id = session_id_of(snapshot)

    sql =
      "INSERT INTO #{table} (key, data) VALUES ($1, $2) " <>
        "ON CONFLICT (key) DO UPDATE SET data = EXCLUDED.data, updated_at = now()"

    with {:ok, _} <- repo.query(sql, [session_key(id), Jason.encode!(snapshot)]) do
      :ok
    end
  end

  @impl true
  def load_session_snapshot(config, session_id) do
    {repo, table} = conf(config)

    case repo.query("SELECT data FROM #{table} WHERE key = $1", [session_key(session_id)]) do
      {:ok, %{rows: [[binary | _] | _]}} ->
        with {:ok, map} <- Jason.decode(binary), do: {:ok, map}

      {:ok, %{rows: []}} ->
        {:error, :not_found}
    end
  end

  @impl true
  def delete_session_snapshot(config, session_id) do
    {repo, table} = conf(config)

    with {:ok, _} <- repo.query("DELETE FROM #{table} WHERE key = $1", [session_key(session_id)]) do
      :ok
    end
  end

  # ----- schema -------------------------------------------------------------
  @doc """
  Create the snapshots table (idempotent). Run this once from a migration or at
  boot, against your app's repo. Columns: `key` (PK), `data` (the JSON text),
  `updated_at`.
  """
  @spec migrate(module(), String.t()) :: :ok | {:error, term()}
  def migrate(repo, table \\ @default_table) do
    sql =
      "CREATE TABLE IF NOT EXISTS #{table} (" <>
        "key text PRIMARY KEY, data text NOT NULL, updated_at timestamptz NOT NULL DEFAULT now())"

    with {:ok, _} <- repo.query(sql, []) do
      :ok
    end
  end

  defp agent_key(id), do: "agent:" <> to_string(id)
  defp session_key(id), do: "session:" <> to_string(id)

  defp session_id_of(%{session_id: id}), do: id
  defp session_id_of(%{"session_id" => id}), do: id

  defp session_id_of(_),
    do: raise(ArgumentError, "session snapshot has no :session_id")
end
