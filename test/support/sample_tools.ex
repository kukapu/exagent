defmodule ExAgent.Test.SampleTools do
  @moduledoc false
  use ExAgent.Tools

  @doc "Get the weather for a city."
  deftool get_weather(_ctx, city :: String.t(), days :: integer()) do
    {:ok, city <> " (" <> Integer.to_string(days) <> "d)"}
  end

  @doc "Add two numbers."
  tool_plain add(a :: integer(), b :: integer()) do
    {:ok, a + b}
  end

  @doc "No params tool."
  deftool ping(_ctx) do
    {:ok, "pong"}
  end
end
