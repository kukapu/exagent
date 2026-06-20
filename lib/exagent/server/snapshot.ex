defmodule ExAgent.Server.Snapshot do
  @moduledoc """
  A serializable checkpoint of an `ExAgent.Server`'s conversational state.

  A snapshot captures what is needed to *resume* a conversation after a crash or
  restart: the `agent_id`, the serialized `message_history`, accumulated token
  `usage`, free-form `metadata`, and an optional serializable `provider_state`.

  By design a snapshot **never** contains:
    * pids or other live process references,
    * API keys or other secrets,
    * tool closures / function captures,
    * the live model struct (its internal state isn't assumed serializable).

  Those live, non-serializable pieces (tools, model, instructions) are provided
  by the host app as an *agent template* on restart; the snapshot only carries
  the conversational state to rehydrate on top of that template.

  Snapshots are JSON-serializable (`Snapshot.serialize/1` / `deserialize/1`),
  so the same contract maps cleanly to a future Postgres/Redis store without
  redesign. Serialization is *strict*: a snapshot that somehow carries a
  non-encodable value (e.g. a closure snuck into `metadata`) fails to encode
  rather than being silently stored as a broken term.
  """

  alias ExAgent.Message
  alias ExAgent.Message.Usage

  @derive {Jason.Encoder,
           only: [
             :version,
             :agent_id,
             :message_history,
             :usage,
             :metadata,
             :provider_state,
             :saved_at
           ]}

  @enforce_keys [:agent_id]
  defstruct version: 1,
            agent_id: nil,
            message_history: nil,
            usage: %{},
            metadata: %{},
            provider_state: nil,
            saved_at: nil

  @type t :: %__MODULE__{
          version: pos_integer(),
          agent_id: String.t(),
          # JSON binary from `ExAgent.Message.to_json/1`.
          message_history: String.t() | nil,
          usage: map(),
          metadata: map(),
          provider_state: map() | nil,
          saved_at: DateTime.t() | nil
        }

  @doc """
  Build a snapshot from the conversational state of an `ExAgent.Server`.

  Options: `:agent_id` (required), `:history` (`[Message.t()]`),
  `:usage` (`Usage.t()`), `:metadata` (map), `:provider_state` (map | nil).
  `message_history` is serialized via `Message.to_json/1` here, so the snapshot
  is immediately serializable.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    history = Keyword.get(opts, :history, [])

    %__MODULE__{
      agent_id: agent_id,
      message_history: Message.to_json(history),
      usage: usage_to_map(Keyword.get(opts, :usage)),
      metadata: Keyword.get(opts, :metadata, %{}),
      provider_state: Keyword.get(opts, :provider_state),
      saved_at: DateTime.utc_now()
    }
  end

  @doc """
  Encode a snapshot to a JSON binary. **Strict**: raises if any field is not
  JSON-encodable (e.g. a closure or pid), which is how we refuse to persist
  non-serializable state.
  """
  @spec serialize(t()) :: String.t()
  def serialize(%__MODULE__{} = snapshot) do
    Jason.encode!(snapshot)
  end

  @doc """
  Decode a JSON binary (from `serialize/1`) back into a snapshot struct.
  Returns `{:ok, t}` or `{:error, reason}`.
  """
  @spec deserialize(String.t() | binary()) :: {:ok, t()} | {:error, term()}
  def deserialize(binary) when is_binary(binary) do
    with {:ok, map} <- Jason.decode(binary) do
      {:ok, from_map(map)}
    end
  end

  @doc """
  Parse the snapshot's message history back into `Message.t()` structs.
  Returns `{:ok, [Message.t()]}` or `{:error, reason}`. An empty/absent history
  yields `{:ok, []}`.
  """
  @spec messages(t()) :: {:ok, [Message.t()]} | {:error, term()}
  def messages(%__MODULE__{message_history: nil}), do: {:ok, []}

  def messages(%__MODULE__{message_history: binary}) when is_binary(binary) do
    Message.from_json(binary)
  end

  @doc "Rebuild the `Usage` struct from the snapshot's usage map."
  @spec usage_struct(t()) :: Usage.t()
  def usage_struct(%__MODULE__{usage: usage}) do
    %Usage{
      input_tokens: Map.get(usage, "input_tokens") || Map.get(usage, :input_tokens) || 0,
      output_tokens: Map.get(usage, "output_tokens") || Map.get(usage, :output_tokens) || 0
    }
  end

  # ---------------------------------------------------------------------------
  defp from_map(map) do
    %__MODULE__{
      version: Map.get(map, "version", 1),
      agent_id: Map.fetch!(map, "agent_id"),
      message_history: Map.get(map, "message_history"),
      usage: Map.get(map, "usage", %{}),
      metadata: Map.get(map, "metadata", %{}),
      provider_state: Map.get(map, "provider_state"),
      saved_at: parse_ts(Map.get(map, "saved_at"))
    }
  end

  defp parse_ts(nil), do: nil

  defp parse_ts(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp usage_to_map(%Usage{input_tokens: i, output_tokens: o}),
    do: %{"input_tokens" => i, "output_tokens" => o}

  defp usage_to_map(%{} = m), do: m
  defp usage_to_map(_), do: %{}
end
