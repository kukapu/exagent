defmodule ExAgent.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # A dedicated, supervised Finch pool shared by every provider, so the host
    # app's own Finch isn't contended by agent traffic and pool size is tunable
    # via config.
    children = [
      {Finch,
       name: ExAgent.Finch,
       pools:
         Application.get_env(:exagent, :finch_pools, %{
           :default => [size: 32, pool_max_idle_time: 15_000]
         })}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ExAgent.Supervisor)
  end
end
