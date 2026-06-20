defmodule ExAgent.AgentSupervisor do
  @moduledoc """
  A `DynamicSupervisor` that owns `ExAgent.Server` processes.

  Each long-lived agent is a supervised GenServer started under this supervisor,
  so a crash (or an explicit stop) is isolated from the rest of the application
  and the agent can be restarted by its host app. Agents are looked up by name
  via the same `:name`/`:agent_id` passed to `ExAgent.Server.start_link/1`.

  ## Example

      {:ok, pid} = ExAgent.AgentSupervisor.start_agent(agent: my_agent, name: :dm)
      ExAgent.Server.chat(:dm, "Roll for initiative")
  """

  use DynamicSupervisor

  @doc false
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start an `ExAgent.Server` under this supervisor. `opts` are forwarded to
  `ExAgent.Server.start_link/1`. Returns `{:ok, pid}` or `{:error, _}`.
  """
  @spec start_agent(keyword()) :: DynamicSupervisor.on_start_child()
  def start_agent(opts) when is_list(opts) do
    DynamicSupervisor.start_child(__MODULE__, {ExAgent.Server, opts})
  end

  @doc "Stop a supervised agent by pid. Returns `:ok` or `{:error, _}`."
  @spec stop_agent(pid()) :: :ok | {:error, :not_found}
  def stop_agent(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end
end
