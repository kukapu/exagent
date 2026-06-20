defmodule ExAgent.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # The supervisor tree owns the long-lived infrastructure every layer of
    # ExAgent relies on:
    #
    #   * `ExAgent.Finch`           — shared HTTP pool for providers (existing).
    #   * `ExAgent.PubSub.Registry` — duplicate-key Registry backing
    #                                 `ExAgent.PubSub.Local` (cheap; always on).
    #   * `ExAgent.TaskSupervisor`  — runs agent runs so a Server keeps answering
    #                                 `abort/1`, `health/1` and backpressure
    #                                 during long runs.
    #   * `ExAgent.AgentSupervisor` — DynamicSupervisor for `ExAgent.Server`
    #                                 processes (one per live agent).
    #   * `ExAgent.Store.ETS`       — owner of the default snapshots table
    #                                 (dev/test persistence; survives agent
    #                                 crashes).
    children = [
      {Finch,
       name: ExAgent.Finch,
       pools:
         Application.get_env(:exagent, :finch_pools, %{
           :default => [size: 32, pool_max_idle_time: 15_000]
         })},
      {Registry, keys: :duplicate, name: ExAgent.PubSub.Registry},
      {Task.Supervisor, name: ExAgent.TaskSupervisor},
      {ExAgent.Store.ETS, []},
      {ExAgent.AgentSupervisor, []}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ExAgent.Supervisor)
  end
end
