defmodule ExAgent.Telemetry do
  @moduledoc """
  Telemetry event helpers.

  The framework emits the standard Elixir `:telemetry` events so any host app
  can observe agent runs through the usual OTel / `Telemetry.Metrics` /
  LiveDashboard pipeline.

  ## Events

    * `[:exagent, :run, :start]` — measurements: `%{system_time}`, metadata: `%{agent, prompt}`
    * `[:exagent, :run, :stop]` — measurements: `%{duration}`, metadata: `%{agent, usage, steps}`
    * `[:exagent, :run, :exception]` — measurements: `%{duration}`, metadata: `%{agent, reason}`
    * `[:exagent, :tool, :stop]` — measurements: `%{duration}`, metadata: `%{tool_name, success}`
  """
  @spec execute([atom()], map(), map()) :: :ok
  def execute(event, measurements, metadata \\ %{}) when is_list(event) do
    :telemetry.execute([:exagent | event], measurements, metadata)
  end
end
