defmodule ExAgent.Models.Test do
  @moduledoc """
  A deterministic, in-process model for development and tests.

  Drop-in replacement for a real provider: it never hits the network and returns
  scripted (or default) `Message.Response`s. This is the workhorse that lets the
  agent loop be developed and unit-tested offline.

  Configuration:

    * `%Test{}` — always replies with a generic text response.
    * `%Test{label: "x"}` — replies with the fixed string `"x"` as text.
    * `%Test{script: [...]}` — returns each item in order; an item may be a
      `Message.Response`, a string (wrapped as a text part), a `{:tool_calls,
      [ToolCall]}` tuple, or a function `fn messages, params -> item`.

  When the script is exhausted, it falls back to the default response.
  """
  @behaviour ExAgent.Model

  alias ExAgent.Message, as: Msg
  alias ExAgent.Message.{Part, Response, Usage}

  defstruct label: nil,
            script: [],
            # mutated as we consume the script
            index: 0,
            # accumulator for tool-call bookkeeping (set by callers in tests)
            received: []

  @type script_item ::
          Response.t()
          | String.t()
          | {:tool_calls, [Part.ToolCall.t()]}
          | (ExAgent.Message.t(), ExAgent.ModelRequestParameters.t() ->
               script_item())

  @type t :: %__MODULE__{
          label: String.t() | nil,
          script: [script_item()],
          index: non_neg_integer(),
          received: [term()]
        }

  @impl true
  def request(model, messages, _settings, params) do
    {response, model2} = pick(model, messages, params)
    {:ok, response, model2}
  rescue
    e -> {:error, e}
  end

  @impl true
  def request_stream(%__MODULE__{} = model, messages, _settings, params) do
    # Reuse the same script-picker the synchronous path uses so an agentic loop
    # driven by `stream_text: true` still respects the script — including
    # `{:tool_calls, [...]}` items, which have no text to stream but DO need to
    # reach the loop as the final Response. Tool-call responses emit no deltas
    # and resolve immediately; text responses chunk into word-sized deltas so
    # streaming consumers see tokens arrive.
    {response, _next} = pick(model, messages, params)
    text = Response.text(response)

    chunks = word_chunks(text)

    Stream.concat([
      Stream.map(chunks, fn c -> {:text_delta, c} end),
      [{:response, response}]
    ])
  end

  defp word_chunks(text) do
    String.split(text, ~r/(?<=\s)/, include_captures: true)
  end

  @impl true
  def model_name(_), do: "test"
  @impl true
  def system(_), do: "test"
  @impl true
  def profile(_), do: %ExAgent.ModelProfile{}

  # ---------------------------------------------------------------------------
  defp pick(%__MODULE__{script: [], label: nil} = m, _messages, _params) do
    default = default_response()
    {default, m}
  end

  defp pick(%__MODULE__{script: [], label: label} = m, _messages, _params)
       when is_binary(label) do
    {text_response(label), m}
  end

  defp pick(%__MODULE__{script: script, index: idx} = m, messages, params) do
    item = Enum.at(script, idx)
    item = resolve_item(item, messages, params)
    next = %__MODULE__{m | received: [item | m.received], index: idx + 1}

    response =
      case item do
        %Response{} = r -> r
        text when is_binary(text) -> text_response(text)
        {:tool_calls, calls} -> tool_call_response(calls)
      end

    {response, next}
  end

  defp resolve_item(item, messages, params) when is_function(item, 2),
    do: item.(messages, params)

  defp resolve_item(item, _messages, params) when is_function(item, 1),
    do: item.(params)

  defp resolve_item(item, _messages, _params) when is_function(item, 0),
    do: item.()

  defp resolve_item(item, _messages, _params), do: item

  defp default_response, do: text_response("a test response")

  defp text_response(text) do
    Msg.new_response([%Part.Text{content: text}],
      usage: %Usage{input_tokens: 1, output_tokens: 1},
      model_name: "test"
    )
  end

  defp tool_call_response(calls) do
    Msg.new_response(calls,
      usage: %Usage{input_tokens: 1, output_tokens: length(calls)},
      model_name: "test"
    )
  end
end
