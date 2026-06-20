defmodule ExAgent.Event do
  @moduledoc """
  Versioned, serializable event envelope — ExAgent's UI/runtime contract.

  `ExAgent.Event` is what LiveView, CLI frontends, channels, product logs and
  flow tests subscribe to. It is deliberately distinct from `:telemetry`, which
  stays the channel for technical observability (metrics, OTel, dashboards) and
  may be emitted in parallel.

  Events flow through `ExAgent.PubSub`. A subscriber receives messages shaped as
  `{:exagent_event, %ExAgent.Event{}}` on topics such as
  `"exagent:agent:<agent_id>"` (see `agent_topic/1`) and
  `"exagent:session:<session_id>"` (see `session_topic/1`).

  ## Fields

    * `version`     — envelope schema version (currently `1`).
    * `id`          — unique event id (`"evt_..."`).
    * `seq`         — monotonic sequence within the emitting source (per agent).
    * `type`        — one of the event types listed below.
    * `source`      — `:run`, `:server`, `:session`, `:coordination`, …
    * `occurred_at` — `DateTime.utc_now/0` at emission.
    * correlation   — `run_id`, `request_id`, `agent_id`, `session_id`,
                      `participant_id` (any may be `nil`).
    * `payload`     — JSON-encodable map with event-specific data.
    * `metadata`    — free-form, JSON-encodable map.

  ## Event types

  Loop / run:

      :run_started · :run_finished · :run_failed
      :run_step_started · :run_step_finished
      :text_delta · :thinking_delta
      :tool_call_started · :tool_call_finished
      :usage_updated

  Server runtime:

      :server_request_queued · :server_request_cancelled
      :approval_requested

  Session / coordination (Phase 3+):

      :session_started · :participant_joined · :participant_left
      :session_turn_changed · :shared_state_updated · :session_closed

  Compaction (Phase 5):

      :compaction_started · :compaction_finished
  """

  @derive {Jason.Encoder,
           only: [
             :version,
             :id,
             :seq,
             :type,
             :source,
             :occurred_at,
             :run_id,
             :request_id,
             :agent_id,
             :session_id,
             :participant_id,
             :payload,
             :metadata
           ]}

  @enforce_keys [:id, :seq, :type, :occurred_at]
  defstruct version: 1,
            id: nil,
            seq: nil,
            type: nil,
            source: nil,
            occurred_at: nil,
            run_id: nil,
            request_id: nil,
            agent_id: nil,
            session_id: nil,
            participant_id: nil,
            payload: %{},
            metadata: %{}

  @type source :: :run | :server | :session | :coordination | atom()
  @type t :: %__MODULE__{
          version: pos_integer(),
          id: String.t(),
          seq: non_neg_integer(),
          type: atom(),
          source: source() | nil,
          occurred_at: DateTime.t(),
          run_id: String.t() | nil,
          request_id: String.t() | nil,
          agent_id: String.t() | nil,
          session_id: String.t() | nil,
          participant_id: String.t() | nil,
          payload: map(),
          metadata: map()
        }

  @doc """
  Build a new event, filling `id`/`occurred_at`/`version` defaults.

  `:type` and `:seq` are required (enforced); everything else is optional with
  sensible defaults. `payload`/`metadata` default to empty maps.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    opts =
      opts
      |> Keyword.put_new_lazy(:id, &generate_id/0)
      |> Keyword.put_new_lazy(:occurred_at, &DateTime.utc_now/0)
      |> Keyword.put_new(:version, 1)
      |> Keyword.put_new(:payload, %{})
      |> Keyword.put_new(:metadata, %{})

    struct!(__MODULE__, opts)
  end

  @doc "Recommended PubSub topic for an agent (`\"exagent:agent:<id>\"`)."
  @spec agent_topic(String.t() | nil) :: String.t()
  def agent_topic(nil), do: "exagent:agent"
  def agent_topic(agent_id), do: "exagent:agent:#{agent_id}"

  @doc "Recommended PubSub topic for a session (`\"exagent:session:<id>\"`)."
  @spec session_topic(String.t() | nil) :: String.t()
  def session_topic(nil), do: "exagent:session"
  def session_topic(session_id), do: "exagent:session:#{session_id}"

  @doc false
  def generate_id do
    "evt_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
