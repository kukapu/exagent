defmodule ExAgent.Message do
  @moduledoc """
  Message and part types exchanged between the agent and a model.

  It leans into Elixir's native discriminated unions: every part/message is a
  struct, and the `__struct__` field is the discriminator you pattern-match on
  (`case part do %Part.ToolCall{} -> ...`).

  Two top-level messages:

    * `Request`  — sent *to* the model (system/user prompts, tool returns,
      retry prompts).
    * `Response` — returned *by* the model (text, tool calls, thinking).

  All structs `@derive Jason.Encoder` so a whole history can be serialised to
  JSON for persistence or for talking to providers.
  """

  defmodule Usage do
    @moduledoc "Token accounting for a single model response."
    @derive [Jason.Encoder]
    @enforce_keys [:input_tokens, :output_tokens]
    defstruct [:input_tokens, :output_tokens, details: %{}]

    @type t :: %__MODULE__{
            input_tokens: non_neg_integer(),
            output_tokens: non_neg_integer(),
            details: map()
          }
  end

  # ---------------------------------------------------------------------------
  # Request parts
  # ---------------------------------------------------------------------------
  defmodule Part do
    @moduledoc "Request & response part structs."

    defmodule System do
      @moduledoc "A system / instruction prompt part."
      @derive [Jason.Encoder]
      @enforce_keys [:content]
      defstruct [:content, :dynamic_ref]

      @type t :: %__MODULE__{
              content: String.t() | [map()],
              dynamic_ref: String.t() | nil
            }
    end

    defmodule User do
      @moduledoc "A user prompt part (text or multimodal content list)."
      @derive [Jason.Encoder]
      @enforce_keys [:content]
      defstruct [:content, :timestamp]

      @type t :: %__MODULE__{
              content: String.t() | [map()],
              timestamp: DateTime.t() | nil
            }
    end

    defmodule ToolReturn do
      @moduledoc """
      The return value of a tool call, fed back to the model.

      `usage` is an optional contributed token usage (e.g. from a delegated
      sub-agent run) that the agent loop merges into the run's accumulated
      usage. It is `nil` for ordinary tools and is not part of the serialized
      message history (usage is accounted for at runtime).
      """
      @derive [Jason.Encoder]
      @enforce_keys [:tool_name, :content, :tool_call_id]
      defstruct [:tool_name, :content, :tool_call_id, :usage]

      @type t :: %__MODULE__{
              tool_name: String.t(),
              content: term(),
              tool_call_id: String.t(),
              usage: Usage.t() | nil
            }
    end

    defmodule Retry do
      @moduledoc """
      A retry prompt: validation errors (list of maps) or a plain message,
      sent back to the model so it can correct itself.
      """
      @derive [Jason.Encoder]
      @enforce_keys [:content]
      defstruct [:content, :tool_name, :tool_call_id]

      @type t :: %__MODULE__{
              content: [map()] | String.t(),
              tool_name: String.t() | nil,
              tool_call_id: String.t() | nil
            }
    end

    # -------------------------------------------------------------------------
    # Response parts
    # -------------------------------------------------------------------------
    defmodule Text do
      @moduledoc "A plain text chunk returned by the model."
      @derive [Jason.Encoder]
      @enforce_keys [:content]
      defstruct [:content, :id]

      @type t :: %__MODULE__{content: String.t(), id: String.t() | nil}
    end

    defmodule Thinking do
      @moduledoc "A reasoning / chain-of-thought part (provider-dependent)."
      @derive [Jason.Encoder]
      @enforce_keys [:content]
      defstruct [:content, :signature, :id]

      @type t :: %__MODULE__{
              content: String.t(),
              signature: String.t() | nil,
              id: String.t() | nil
            }
    end

    defmodule ToolCall do
      @moduledoc """
      The model asking the agent to run a tool.

      `args` may be `nil`, a decoded `map()`, or raw JSON `binary()` (the latter
      when the provider streams partial JSON). Use `args_as_map/1` to normalise.
      """
      @derive [Jason.Encoder]
      @enforce_keys [:tool_name]
      defstruct [:tool_name, :args, :tool_call_id, kind: :function]

      @type arg :: nil | map() | binary()
      @type kind :: :function | :output | :external | :unapproved
      @type t :: %__MODULE__{
              tool_name: String.t(),
              args: arg(),
              tool_call_id: String.t() | nil,
              kind: kind()
            }

      @doc """
      Decode `args` to a map. Accepts a map (passthrough), a JSON string, or
      `nil`. On unparseable JSON, returns `:error` (the agent turns that into a
      retry prompt so the model can fix its arguments).
      """
      @spec args_as_map(t()) :: {:ok, map()} | {:error, term()} | :empty
      def args_as_map(%__MODULE__{args: nil}), do: :empty
      def args_as_map(%__MODULE__{args: args}) when is_map(args), do: {:ok, args}

      def args_as_map(%__MODULE__{args: args}) when is_binary(args) do
        case Jason.decode(args) do
          {:ok, map} when is_map(map) -> {:ok, map}
          {:ok, other} -> {:error, {:not_an_object, other}}
          {:error, _} = e -> e
        end
      end

      # A non-conforming args value (e.g. an integer a model/proxy emitted) used
      # to raise FunctionClauseError and crash the tool task. Surface it as a
      # clean error so the run returns {:error, _} and the model can retry.
      def args_as_map(%__MODULE__{args: other}), do: {:error, {:unsupported_args_type, other}}
    end
  end

  # ---------------------------------------------------------------------------
  # Top-level messages
  # ---------------------------------------------------------------------------
  defmodule Request do
    @moduledoc "A message sent *to* the model."
    @derive [Jason.Encoder]
    @enforce_keys [:parts]
    defstruct [:parts, :instructions, :run_id, :conversation_id, :timestamp]

    @type part :: Part.System.t() | Part.User.t() | Part.ToolReturn.t() | Part.Retry.t()
    @type t :: %__MODULE__{
            parts: [part()],
            instructions: String.t() | nil,
            run_id: String.t() | nil,
            conversation_id: String.t() | nil,
            timestamp: DateTime.t() | nil
          }
  end

  defmodule Response do
    @moduledoc "A message returned *by* the model."
    @derive [Jason.Encoder]
    @enforce_keys [:parts]
    defstruct [:parts, :usage, :model_name, :finish_reason, :timestamp]

    @type part :: Part.Text.t() | Part.ToolCall.t() | Part.Thinking.t()
    @type t :: %__MODULE__{
            parts: [part()],
            usage: Usage.t() | nil,
            model_name: String.t() | nil,
            finish_reason: atom() | nil,
            timestamp: DateTime.t() | nil
          }

    @doc "Concatenate all `TextPart` contents of the response."
    @spec text(t()) :: String.t()
    def text(%__MODULE__{parts: parts}) do
      parts
      |> Enum.filter(&match?(%Part.Text{}, &1))
      |> Enum.map_join(& &1.content)
    end

    @doc "All `ToolCall` parts in order."
    @spec tool_calls(t()) :: [Part.ToolCall.t()]
    def tool_calls(%__MODULE__{parts: parts}) do
      Enum.filter(parts, &match?(%Part.ToolCall{}, &1))
    end

    @doc "True if the response contains no tool calls and no text."
    @spec empty?(t()) :: boolean()
    def empty?(%__MODULE__{} = resp) do
      tool_calls(resp) == [] and text(resp) == ""
    end
  end

  @type t :: Request.t() | Response.t()

  @doc "Build a request from a list of parts."
  @spec new_request([Request.part()], keyword()) :: Request.t()
  def new_request(parts, opts \\ []) do
    %Request{
      parts: parts,
      instructions: Keyword.get(opts, :instructions),
      run_id: Keyword.get(opts, :run_id),
      conversation_id: Keyword.get(opts, :conversation_id),
      timestamp: Keyword.get(opts, :timestamp) || DateTime.utc_now()
    }
  end

  @doc "Build a response from a list of parts."
  @spec new_response([Response.part()], keyword()) :: Response.t()
  def new_response(parts, opts \\ []) do
    %Response{
      parts: parts,
      usage: Keyword.get(opts, :usage),
      model_name: Keyword.get(opts, :model_name),
      finish_reason: Keyword.get(opts, :finish_reason),
      timestamp: Keyword.get(opts, :timestamp) || DateTime.utc_now()
    }
  end

  @doc "Flatten a message history into its constituent parts (mostly for tests)."
  @spec parts([t()]) :: [struct()]
  def parts(messages) do
    Enum.flat_map(messages, fn
      %Request{parts: ps} -> ps
      %Response{parts: ps} -> ps
    end)
  end

  # -------------------------------------------------------------------------
  # Serialization (round-trip for persistence: PG/Redis/ETS/file)
  # -------------------------------------------------------------------------
  # The per-struct `@derive Jason.Encoder` drops `__struct__`, so the plain JSON
  # isn't self-describing. These helpers add a `__type__` discriminator and a
  # DateTime round-trip, so a message history can be stored and reconstructed
  # with best-effort fidelity (maps/strings/numbers survive; opaque terms become
  # their inspected string).

  @doc "Serialize a message history to a JSON binary for persistence."
  @spec to_json([t()]) :: String.t()
  def to_json(messages) when is_list(messages) do
    Jason.encode!(Enum.map(messages, &to_encodable/1))
  end

  @doc "Parse a JSON binary back into a message history."
  @spec from_json(String.t() | binary()) :: {:ok, [t()]} | {:error, term()}
  def from_json(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, list} when is_list(list) -> {:ok, Enum.map(list, &from_encodable/1)}
      {:ok, other} -> {:error, {:not_a_list, other}}
      {:error, _} = e -> e
    end
  end

  defp to_encodable(%Request{parts: parts} = r) do
    request = %{
      "__type__" => "request",
      "parts" => Enum.map(parts, &to_encodable/1),
      "instructions" => r.instructions
    }

    request
    |> Map.put("run_id", r.run_id)
    |> Map.put("conversation_id", r.conversation_id)
    |> maybe_put_ts(r.timestamp)
  end

  defp to_encodable(%Response{parts: parts} = r) do
    %{
      "__type__" => "response",
      "parts" => Enum.map(parts, &to_encodable/1),
      "usage" => to_encodable(r.usage),
      "model_name" => r.model_name,
      "finish_reason" => Atom.to_string(r.finish_reason)
    }
    |> maybe_put_ts(r.timestamp)
  end

  defp to_encodable(nil), do: nil

  defp to_encodable(%Usage{input_tokens: i, output_tokens: o, details: d}),
    do: %{"input_tokens" => i, "output_tokens" => o, "details" => d}

  defp to_encodable(%Part.System{content: c, dynamic_ref: d}),
    do: %{"__type__" => "system", "content" => c, "dynamic_ref" => d}

  defp to_encodable(%Part.User{content: c, timestamp: ts}),
    do: %{"__type__" => "user", "content" => c} |> maybe_put_ts(ts)

  defp to_encodable(%Part.ToolReturn{tool_name: n, content: c, tool_call_id: id}),
    do: %{
      "__type__" => "tool_return",
      "tool_name" => n,
      "content" => encode_content(c),
      "tool_call_id" => id
    }

  defp to_encodable(%Part.Retry{content: c, tool_name: n, tool_call_id: id}),
    do: %{
      "__type__" => "retry",
      "content" => encode_content(c),
      "tool_name" => n,
      "tool_call_id" => id
    }

  defp to_encodable(%Part.Text{content: c}),
    do: %{"__type__" => "text", "content" => c}

  defp to_encodable(%Part.Thinking{content: c, signature: s}),
    do: %{"__type__" => "thinking", "content" => c, "signature" => s}

  defp to_encodable(%Part.ToolCall{tool_name: n, args: a, tool_call_id: id, kind: k}),
    do: %{
      "__type__" => "tool_call",
      "tool_name" => n,
      "args" => a,
      "tool_call_id" => id,
      "kind" => k
    }

  defp from_encodable(%{"__type__" => "request"} = r) do
    %Request{
      parts: Enum.map(r["parts"], &from_encodable/1),
      instructions: r["instructions"],
      run_id: r["run_id"],
      conversation_id: r["conversation_id"],
      timestamp: parse_ts(r["timestamp"])
    }
  end

  defp from_encodable(%{"__type__" => "response"} = r) do
    %Response{
      parts: Enum.map(r["parts"], &from_encodable/1),
      usage: from_encodable(r["usage"]),
      model_name: r["model_name"],
      finish_reason: parse_atom(r["finish_reason"]),
      timestamp: parse_ts(r["timestamp"])
    }
  end

  defp from_encodable(nil), do: nil

  defp from_encodable(%{"input_tokens" => i, "output_tokens" => o} = u),
    do: %Usage{input_tokens: i, output_tokens: o, details: Map.get(u, "details", %{})}

  defp from_encodable(%{"__type__" => "system"} = p),
    do: %Part.System{content: p["content"], dynamic_ref: p["dynamic_ref"]}

  defp from_encodable(%{"__type__" => "user"} = p),
    do: %Part.User{content: p["content"], timestamp: parse_ts(p["timestamp"])}

  defp from_encodable(%{"__type__" => "tool_return"} = p),
    do: %Part.ToolReturn{
      tool_name: p["tool_name"],
      content: p["content"],
      tool_call_id: p["tool_call_id"]
    }

  defp from_encodable(%{"__type__" => "retry"} = p),
    do: %Part.Retry{
      content: p["content"],
      tool_name: p["tool_name"],
      tool_call_id: p["tool_call_id"]
    }

  defp from_encodable(%{"__type__" => "text"} = p),
    do: %Part.Text{content: p["content"]}

  defp from_encodable(%{"__type__" => "thinking"} = p),
    do: %Part.Thinking{content: p["content"], signature: p["signature"]}

  defp from_encodable(%{"__type__" => "tool_call"} = p),
    do: %Part.ToolCall{
      tool_name: p["tool_name"],
      args: p["args"],
      tool_call_id: p["tool_call_id"],
      kind: parse_atom(p["kind"])
    }

  defp maybe_put_ts(map, %DateTime{} = ts), do: Map.put(map, "timestamp", DateTime.to_iso8601(ts))
  defp maybe_put_ts(map, _), do: map

  defp parse_ts(nil), do: nil

  defp parse_ts(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_atom(nil), do: nil

  defp parse_atom(str) when is_binary(str) do
    # finish_reason / kind come from a known set; avoid atom-table growth on
    # untrusted input by preferring existing atoms, falling back to nil.
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end

  defp encode_content(content)
       when is_binary(content) or is_number(content) or is_boolean(content),
       do: content

  defp encode_content(content) when is_map(content) or is_list(content), do: content

  defp encode_content(content), do: inspect(content)
end
