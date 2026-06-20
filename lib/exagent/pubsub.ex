defmodule ExAgent.PubSub do
  @moduledoc """
  Behaviour for broadcasting `ExAgent.Event`s.

  ExAgent never depends on a concrete PubSub implementation. The default is
  `ExAgent.PubSub.None` (no side-effects, for one-shot use and tests that don't
  observe events). `ExAgent.PubSub.Local` ships an in-process `Registry`-backed
  implementation that works out of the box. `ExAgent.PubSub.Phoenix` delegates
  to `Phoenix.PubSub` dynamically, with no hard dependency on Phoenix. A custom
  implementation just implements this behaviour.

  A PubSub is referenced as `{module, config}` where `config` is opaque to
  ExAgent (e.g. a PubSub server name for Phoenix, or `[]` for Local/None). The
  helper `normalize/1` turns the friendly option forms into that tuple.
  """

  alias ExAgent.Event

  @doc "Broadcast `event` to all subscribers of `topic`."
  @callback broadcast(config :: term(), topic :: String.t(), event :: Event.t()) ::
              :ok | {:error, term()}

  @doc """
  Subscribe the calling process to `topic`. Implementations that can't
  subscribe (e.g. `None`) should return `{:error, {:subscribe_unsupported, mod}}`.
  """
  @callback subscribe(config :: term(), topic :: String.t()) :: :ok | {:error, term()}

  @doc """
  Resolve a PubSub option into a `{module, config}` tuple.

  Accepts:

    * `nil` / `:none`  → `{ExAgent.PubSub.None, []}`
    * `:local`         → `{ExAgent.PubSub.Local, []}`
    * `module`         → `{module, []}`
    * `{module, conf}` → as-is

  The resolved module must implement this behaviour.
  """
  @spec normalize(term()) :: {module(), term()}
  def normalize(nil), do: {ExAgent.PubSub.None, []}
  def normalize(:none), do: {ExAgent.PubSub.None, []}
  def normalize(:local), do: {ExAgent.PubSub.Local, []}
  def normalize({mod, config}) when is_atom(mod), do: {mod, config}
  def normalize(mod) when is_atom(mod), do: {mod, []}

  @doc "Broadcast via the resolved `{module, config}` tuple."
  @spec broadcast({module(), term()}, String.t(), Event.t()) :: :ok | {:error, term()}
  def broadcast({mod, config}, topic, %Event{} = event) do
    mod.broadcast(config, topic, event)
  end

  @doc "Subscribe via the resolved tuple."
  @spec subscribe({module(), term()}, String.t()) :: :ok | {:error, term()}
  def subscribe({mod, config}, topic) do
    mod.subscribe(config, topic)
  end
end

defmodule ExAgent.PubSub.None do
  @moduledoc """
  No-op PubSub (default). Broadcasts are discarded; `subscribe/2` is
  unsupported. Use when you don't need to observe events (e.g. pure one-shot
  `ExAgent.run/3`).
  """
  @behaviour ExAgent.PubSub

  @impl true
  def broadcast(_config, _topic, _event), do: :ok

  @impl true
  def subscribe(_config, _topic), do: {:error, {:subscribe_unsupported, __MODULE__}}
end

defmodule ExAgent.PubSub.Local do
  @moduledoc """
  In-process PubSub backed by a duplicate-key `Registry`
  (`ExAgent.PubSub.Registry`, started by the application supervisor).

  Subscribers receive `{:exagent_event, %ExAgent.Event{}}`. Works without any
  external dependency — ideal for tests, CLIs and single-node apps.
  """
  @behaviour ExAgent.PubSub

  @registry ExAgent.PubSub.Registry

  @impl true
  def broadcast(_config, topic, %ExAgent.Event{} = event) do
    Registry.dispatch(@registry, topic, fn entries ->
      for {pid, _value} <- entries do
        send(pid, {:exagent_event, event})
      end
    end)

    :ok
  end

  @impl true
  def subscribe(_config, topic) do
    case Registry.register(@registry, topic, []) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  end
end

defmodule ExAgent.PubSub.Phoenix do
  @moduledoc """
  Delegates to `Phoenix.PubSub` when available, with **no hard dependency**.

  If `Phoenix.PubSub` is not loaded, both `broadcast/3` and `subscribe/2`
  return `{:error, {:phoenix_pubsub_not_available, Phoenix.PubSub}}` rather than
  raising.

  Configure as `{ExAgent.PubSub.Phoenix, MyApp.PubSub}`, where the second
  element is the PubSub server name registered in the host app.
  """
  @behaviour ExAgent.PubSub

  # Phoenix is an optional host dependency. Silence the compile-time
  # "undefined module" warnings when it isn't present; we guard the calls at
  # runtime with Code.ensure_loaded?/1.
  @compile {:no_warn_undefined, [Phoenix.PubSub]}

  @impl true
  def broadcast(pubsub, topic, %ExAgent.Event{} = event) do
    with true <- Code.ensure_loaded?(Phoenix.PubSub) do
      Phoenix.PubSub.broadcast(pubsub, topic, {:exagent_event, event})
      :ok
    else
      _ -> {:error, {:phoenix_pubsub_not_available, Phoenix.PubSub}}
    end
  end

  @impl true
  def subscribe(pubsub, topic) do
    with true <- Code.ensure_loaded?(Phoenix.PubSub) do
      Phoenix.PubSub.subscribe(pubsub, topic)
      :ok
    else
      _ -> {:error, {:phoenix_pubsub_not_available, Phoenix.PubSub}}
    end
  end
end
