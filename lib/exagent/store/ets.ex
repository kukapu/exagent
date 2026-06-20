defmodule ExAgent.Store.ETS do
  @moduledoc """
  In-process, ETS-backed `ExAgent.Store` implementation (dev/test default).

  A supervised `ExAgent.Store.ETS` GenServer owns a public, named ETS table
  (default name `ExAgent.Store.ETS`, started by the application supervisor), so
  the table outlives any single `ExAgent.Server` crash and snapshots survive a
  restart. The behaviour callbacks operate directly on the table for speed.

  ## Portability (the important bit)

  Even though ETS can hold arbitrary Erlang terms, this implementation
  **round-trips snapshots through JSON** (`Snapshot.serialize/1`), never
  `term_to_binary`. That enforces two things a future Postgres store will rely
  on:

    1. the stored shape is portable (JSON, not opaque binaries), and
    2. non-serializable values (pids, secrets, function captures) are refused
       at write time — `Jason.encode!` raises rather than persisting junk.

  Use it as `store: :ets` on `ExAgent.Server` / `ExAgent.AgentSupervisor`.
  """

  use GenServer

  @behaviour ExAgent.Store

  alias ExAgent.Server.Snapshot

  @default_table __MODULE__

  # ---------------------------------------------------------------------------
  # GenServer (owns the table)
  # ---------------------------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    table = Keyword.get(opts, :table, @default_table)
    GenServer.start_link(__MODULE__, table, name: via(table))
  end

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  @impl true
  def init(table) do
    # Create the table if it doesn't already exist (e.g. across app restarts).
    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:set, :public, :named_table])
    end

    {:ok, table}
  end

  defp via(table), do: {:via, :global, {:exagent_store_ets, table}}

  # ---------------------------------------------------------------------------
  # ExAgent.Store — agents
  # ---------------------------------------------------------------------------

  @impl true
  def save_agent_snapshot(table, %Snapshot{} = snap) do
    # Strict JSON: raises (and so the save fails) if anything isn't encodable.
    binary = Snapshot.serialize(snap)
    true = :ets.insert(table, {{:agent, snap.agent_id}, binary})
    :ok
  end

  @impl true
  def load_agent_snapshot(table, agent_id) do
    case :ets.lookup(table, {:agent, agent_id}) do
      [{_, binary}] ->
        case Snapshot.deserialize(binary) do
          {:ok, %Snapshot{} = snap} -> {:ok, snap}
          {:error, _} = e -> e
        end

      [] ->
        {:error, :not_found}
    end
  end

  @impl true
  def list_agent_snapshots(table) do
    :ets.match(table, {{:agent, :_}, :"$1"})
    |> List.flatten()
    |> Enum.flat_map(fn binary ->
      case Snapshot.deserialize(binary) do
        {:ok, %Snapshot{} = snap} -> [snap]
        {:error, _} -> []
      end
    end)
  end

  @impl true
  def delete_agent_snapshot(table, agent_id) do
    :ets.delete(table, {:agent, agent_id})
    :ok
  end

  # ---------------------------------------------------------------------------
  # ExAgent.Store — sessions (Phase 3). Stored as JSON keyed by session_id,
  # forward-compatible with a future ExAgent.Session.Snapshot struct.
  # ---------------------------------------------------------------------------

  @impl true
  def save_session_snapshot(table, snapshot) do
    session_id = session_id_of(snapshot)
    binary = Jason.encode!(snapshot)
    true = :ets.insert(table, {{:session, session_id}, binary})
    :ok
  end

  @impl true
  def load_session_snapshot(table, session_id) do
    case :ets.lookup(table, {:session, session_id}) do
      [{_, binary}] ->
        case Jason.decode(binary) do
          {:ok, map} -> {:ok, map}
          {:error, _} = e -> e
        end

      [] ->
        {:error, :not_found}
    end
  end

  @impl true
  def delete_session_snapshot(table, session_id) do
    :ets.delete(table, {:session, session_id})
    :ok
  end

  defp session_id_of(%{session_id: id}), do: id
  defp session_id_of(%{"session_id" => id}), do: id
  defp session_id_of(_), do: raise(ArgumentError, "session snapshot has no :session_id")
end
