defmodule ExAgent.Store do
  @moduledoc """
  Behaviour for persisting `ExAgent.Server.Snapshot`s (and, in Phase 3, session
  snapshots).

  ExAgent never owns a database: the store is a pluggable behaviour. The default
  `ExAgent.Store.ETS` keeps snapshots in an in-process ETS table (dev/test); a
  future `ExAgent.Store.Postgres` will implement the same contract for durable,
  multi-node persistence.

  ## The contract (what a store must do)

    * `save_agent_snapshot/2`   — persist a snapshot, keyed by its `agent_id`.
    * `load_agent_snapshot/2`   — fetch a snapshot by `agent_id`.
    * `list_agent_snapshots/1`  — list all persisted agent snapshots.
    * `delete_agent_snapshot/2` — remove a snapshot by `agent_id`.
    * `save_session_snapshot/2` / `load_session_snapshot/2` — the session
      counterparts (used by `ExAgent.Session` from Phase 3).

  ## Portability rule

  Implementations MUST round-trip snapshots through a portable encoding (JSON
  for the ETS impl), never `term_to_binary` of arbitrary terms. This guarantees
  the same data can land in Postgres later without redesign, and refuses to
  persist non-serializable state (pids, secrets, closures).

  A store is referenced as `{module, config}` where `config` is opaque to
  ExAgent (e.g. an ETS table name). `normalize/1` turns friendly forms into that
  tuple; `nil` means "no store" (the default — one-shot friendly).
  """

  alias ExAgent.Server.Snapshot
  alias ExAgent.Session.Snapshot, as: SessionSnapshot

  @type agent_snapshot :: Snapshot.t()
  @type session_snapshot :: SessionSnapshot.t()

  @doc "Persist an agent snapshot, keyed by its `agent_id`."
  @callback save_agent_snapshot(config :: term(), snapshot :: agent_snapshot()) ::
              :ok | {:error, term()}

  @doc "Load an agent snapshot by `agent_id`, or `{:error, :not_found}`."
  @callback load_agent_snapshot(config :: term(), agent_id :: String.t()) ::
              {:ok, agent_snapshot()} | {:error, :not_found | term()}

  @doc "List every persisted agent snapshot."
  @callback list_agent_snapshots(config :: term()) :: [agent_snapshot()]

  @doc "Delete an agent snapshot by `agent_id`."
  @callback delete_agent_snapshot(config :: term(), agent_id :: String.t()) :: :ok

  @doc "Persist a session snapshot, keyed by `session_id` (Phase 3)."
  @callback save_session_snapshot(config :: term(), snapshot :: session_snapshot()) ::
              :ok | {:error, term()}

  @doc "Load a session snapshot by `session_id` (Phase 3)."
  @callback load_session_snapshot(config :: term(), session_id :: String.t()) ::
              {:ok, session_snapshot()} | {:error, :not_found | term()}

  @doc "Delete a session snapshot by `session_id` (Phase 3)."
  @callback delete_session_snapshot(config :: term(), session_id :: String.t()) :: :ok

  @optional_callbacks [
    save_session_snapshot: 2,
    load_session_snapshot: 2,
    delete_session_snapshot: 2
  ]

  @doc """
  Resolve a store option into a `{module, config}` tuple, or `nil` for "no store".

    * `nil`        → `nil` (no persistence — default).
    * `:ets`       → `{ExAgent.Store.ETS, ExAgent.Store.ETS}` (default table).
    * `{mod, cfg}` → as-is.
    * `mod`        → `{mod, []}`.
  """
  @spec normalize(term()) :: {module(), term()} | nil
  def normalize(nil), do: nil
  def normalize(:ets), do: {ExAgent.Store.ETS, ExAgent.Store.ETS}
  def normalize({mod, config}) when is_atom(mod), do: {mod, config}
  def normalize(mod) when is_atom(mod), do: {mod, []}

  @doc "Persist an agent snapshot via the resolved `{module, config}` tuple."
  @spec save_agent_snapshot({module(), term()}, Snapshot.t()) :: :ok | {:error, term()}
  def save_agent_snapshot({mod, config}, %Snapshot{} = snapshot) do
    mod.save_agent_snapshot(config, snapshot)
  end

  @doc "Load an agent snapshot via the resolved tuple."
  @spec load_agent_snapshot({module(), term()}, String.t()) ::
          {:ok, Snapshot.t()} | {:error, term()}
  def load_agent_snapshot({mod, config}, agent_id) do
    mod.load_agent_snapshot(config, agent_id)
  end

  @doc "List agent snapshots via the resolved tuple."
  @spec list_agent_snapshots({module(), term()}) :: [Snapshot.t()]
  def list_agent_snapshots({mod, config}) do
    mod.list_agent_snapshots(config)
  end

  @doc "Delete an agent snapshot via the resolved tuple."
  @spec delete_agent_snapshot({module(), term()}, String.t()) :: :ok
  def delete_agent_snapshot({mod, config}, agent_id) do
    mod.delete_agent_snapshot(config, agent_id)
  end

  @doc "Persist a session snapshot via the resolved tuple."
  @spec save_session_snapshot({module(), term()}, SessionSnapshot.t()) :: :ok | {:error, term()}
  def save_session_snapshot({mod, config}, %SessionSnapshot{} = snapshot) do
    mod.save_session_snapshot(config, snapshot)
  end

  @doc "Load a session snapshot via the resolved tuple."
  @spec load_session_snapshot({module(), term()}, String.t()) ::
          {:ok, SessionSnapshot.t()} | {:error, term()}
  def load_session_snapshot({mod, config}, session_id) do
    mod.load_session_snapshot(config, session_id)
  end

  @doc "Delete a session snapshot via the resolved tuple."
  @spec delete_session_snapshot({module(), term()}, String.t()) :: :ok
  def delete_session_snapshot({mod, config}, session_id) do
    mod.delete_session_snapshot(config, session_id)
  end
end
