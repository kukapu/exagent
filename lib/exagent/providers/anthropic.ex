defmodule ExAgent.Providers.Anthropic do
  @moduledoc """
  Implementation for providers that speak the **Anthropic Messages API**:
  `POST {base_url}/v1/messages`.

  The Anthropic wire format differs from OpenAI Chat Completions in several
  load-bearing ways, all handled here:

    * **`system` is top-level** — `SystemPrompt` parts are lifted out of the
      message stream and sent as the `system` parameter, not as a message.
    * **Content is an array of blocks** — every message body is a list of
      `{"type": "text" | "tool_use" | "tool_result", ...}` blocks.
    * **Tool calls** — the model emits `tool_use` blocks (with an `input` object,
      not a JSON string); the agent replies with `tool_result` blocks in a
      *user* message keyed by `tool_use_id`.
    * **Auth** — `x-api-key` (real Anthropic) or `Authorization: Bearer`
      (e.g. Z.AI's `/api/anthropic`), plus the `anthropic-version` header.

  Pointing this at Z.AI's Anthropic-compatible endpoint gives access to GLM
  models (`glm-4.5-air`, `glm-4.7`, `glm-5.2`, …) using the native format.
  """

  alias ExAgent.{Message, ModelSettings, ModelRequestParameters, Tool}
  alias ExAgent.Message.{Part, Response, Usage}
  alias ExAgent.Providers.SSE

  @anthropic_version "2023-06-01"
  @default_max_tokens 4096
  @default_timeout 60_000

  defmodule Config do
    @moduledoc false
    defstruct [:model, :api_key, :auth_token, :base_url, :system, cache: false]

    @type t :: %__MODULE__{
            model: String.t(),
            api_key: String.t() | nil,
            auth_token: String.t() | nil,
            base_url: String.t(),
            system: String.t(),
            cache: boolean()
          }
  end

  @doc "Perform a (non-streaming) Messages API request."
  @spec request(struct(), [Message.t()], ModelSettings.t() | nil, ModelRequestParameters.t()) ::
          {:ok, Response.t(), struct()} | {:error, term()}
  def request(model, messages, settings, params) do
    config = config(model)

    with :ok <- ensure_credentials(config) do
      body = build_body(model, messages, settings, params)
      do_request(config, body, settings, model)
    end
  end

  @doc false
  # Builds the Messages API request body. Public so the cache breakpoint layout
  # can be unit-tested without a network.
  def build_body(model, messages, settings, params) do
    config = config(model)
    {system, convo} = encode_messages(messages)
    tools = encode_tools(params)
    {system, tools} = apply_cache(system, tools, config.cache)

    %{}
    |> Map.put("model", config.model)
    |> Map.put("max_tokens", max_tokens(settings))
    |> maybe_put("system", system)
    |> Map.put("messages", convo)
    |> put_settings(settings)
    |> maybe_put("tools", tools)
    |> maybe_put("tool_choice", tool_choice(params))
  end

  # Anthropic prompt caching: a `cache_control: ephemeral` breakpoint on the
  # last system block and the last tool definition lets the provider reuse the
  # cached prefix (60–90% input-token savings on long, repeated system prompts).
  defp apply_cache(system, tools, true) do
    {cache_last_block(system), cache_last_block(tools)}
  end

  defp apply_cache(system, tools, _), do: {system, tools}

  defp cache_last_block(nil), do: nil

  defp cache_last_block([]), do: []

  defp cache_last_block(list) when is_list(list) do
    List.update_at(list, -1, &Map.put(&1, "cache_control", %{"type" => "ephemeral"}))
  end

  defp do_request(config, body, settings, model) do
    case Req.request(
           url: String.trim_trailing(config.base_url, "/") <> "/v1/messages",
           method: :post,
           headers: build_headers(config),
           json: body,
           finch: ExAgent.Finch,
           receive_timeout: settings_timeout(settings) || @default_timeout
         ) do
      {:ok, %{status: 200, body: resp_body}} ->
        case parse_body(resp_body, config) do
          {:ok, resp} -> {:ok, resp, model}
          {:error, _} = e -> e
        end

      {:ok, %{status: status, body: body}} ->
        {:error,
         %ExAgent.RequestError{
           provider: :anthropic,
           status: status,
           reason: :http_error,
           body: body
         }}

      {:error, %{reason: :timeout} = exception} ->
        {:error,
         %ExAgent.RequestError{
           provider: :anthropic,
           reason: :timeout,
           body: inspect(exception)
         }}

      {:error, exception} ->
        {:error,
         %ExAgent.RequestError{
           provider: :anthropic,
           reason: :request_failed,
           body: inspect(exception)
         }}
    end
  end

  @doc false
  @spec parse_body(map(), struct()) ::
          {:ok, Response.t()} | {:error, ExAgent.RequestError.t()}
  def parse_body(%{"error" => error}, _config) do
    {:error,
     %ExAgent.RequestError{
       provider: :anthropic,
       reason: :provider_error,
       body: error["message"] || inspect(error)
     }}
  end

  def parse_body(body, config), do: {:ok, parse_response(body, config)}

  # ----- config extraction -------------------------------------------------
  defp config(%{__struct__: mod, model: model} = struct) do
    %Config{
      model: model,
      api_key: Map.get(struct, :api_key),
      auth_token: Map.get(struct, :auth_token),
      base_url: Map.get(struct, :base_url) || default_base_url(mod),
      system: Atom.to_string(mod) |> String.split(".") |> List.last() |> String.downcase(),
      cache: Map.get(struct, :cache) || false
    }
  end

  defp default_base_url(ExAgent.Models.Anthropic), do: "https://api.anthropic.com"
  defp default_base_url(_), do: "https://api.anthropic.com"

  defp build_headers(%Config{api_key: api_key, auth_token: auth_token}) do
    auth =
      cond do
        auth_token -> [{"authorization", "Bearer " <> auth_token}]
        api_key -> [{"x-api-key", api_key}]
      end

    [{"content-type", "application/json"}, {"anthropic-version", @anthropic_version} | auth]
  end

  defp ensure_credentials(%{api_key: nil, auth_token: nil}),
    do: {:error, %ExAgent.RequestError{provider: :anthropic, reason: :missing_credentials}}

  defp ensure_credentials(_), do: :ok

  # ----- encode: messages -> anthropic ------------------------------------
  @doc """
  Split a message history into a top-level `system` block list and the
  conversation messages (with `System` parts removed and consecutive
  same-role messages merged — Anthropic requires strict alternation).
  """
  @spec encode_messages([Message.t()]) :: {[map()], [map()]}
  def encode_messages(messages) do
    {system_parts, convo} =
      Enum.reduce(messages, {[], []}, fn
        %Message.Request{parts: parts}, {sys_acc, convo_acc} ->
          {sys, rest} = split_system(parts)

          case rest do
            [] ->
              {sys_acc ++ sys, convo_acc}

            _ ->
              {sys_acc ++ sys,
               convo_acc ++ [{:user, Enum.flat_map(rest, &encode_request_block/1)}]}
          end

        %Message.Response{parts: parts}, {sys_acc, convo_acc} ->
          blocks = Enum.flat_map(parts, &encode_response_block/1)
          {sys_acc, convo_acc ++ [{:assistant, blocks}]}
      end)

    system =
      case system_parts do
        [] -> nil
        parts -> Enum.map(parts, &%{type: "text", text: &1.content})
      end

    convo = merge_consecutive(convo)
    {system, convo}
  end

  defp split_system(parts) do
    Enum.split_with(parts, &match?(%Part.System{}, &1))
  end

  defp encode_request_block(%Part.System{}), do: []

  defp encode_request_block(%Part.User{content: content}),
    do: [%{type: "text", text: content_to_string(content)}]

  defp encode_request_block(%Part.ToolReturn{
         tool_name: name,
         content: content,
         tool_call_id: id
       }),
       do: [%{type: "tool_result", tool_use_id: id || name, content: encode_content(content)}]

  defp encode_request_block(%Part.Retry{content: content, tool_name: nil}),
    do: [%{type: "text", text: retry_text(content, nil)}]

  defp encode_request_block(%Part.Retry{content: content, tool_name: name, tool_call_id: id}),
    do: [
      %{
        type: "tool_result",
        tool_use_id: id || name,
        content: retry_text(content, name),
        is_error: true
      }
    ]

  defp encode_response_block(%Part.Text{content: content}),
    do: [%{type: "text", text: content}]

  defp encode_response_block(%Part.ToolCall{
         tool_name: name,
         args: args,
         tool_call_id: id
       }),
       do: [%{type: "tool_use", id: id || name, name: name, input: args_to_map(args)}]

  defp encode_response_block(%Part.Thinking{content: content, signature: signature}),
    do: [%{type: "thinking", thinking: content, signature: signature}]

  defp merge_consecutive(convo) do
    convo
    |> Enum.reduce([], fn {role, blocks}, acc ->
      case acc do
        [{^role, prev} | rest] -> [{role, prev ++ blocks} | rest]
        _ -> [{role, blocks} | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn {role, blocks} -> %{role: role, content: blocks} end)
  end

  # ----- tools -------------------------------------------------------------
  @doc "Encode `Tool` list into the Anthropic `tools` payload (or `nil`)."
  @spec encode_tools(ModelRequestParameters.t()) :: [map()] | nil
  def encode_tools(%ModelRequestParameters{function_tools: f, output_tools: o}) do
    case Enum.map(f ++ o, &encode_tool/1) do
      [] -> nil
      list -> list
    end
  end

  defp encode_tool(%Tool{} = t) do
    %{name: t.name, description: t.description, input_schema: t.parameters_json_schema}
  end

  defp tool_choice(%ModelRequestParameters{output_mode: :tool}), do: %{type: "any"}

  defp tool_choice(%ModelRequestParameters{function_tools: [], output_tools: []}), do: nil
  defp tool_choice(_), do: %{type: "auto"}

  # ----- streaming ---------------------------------------------------------
  @doc """
  Perform a streaming Messages API request. Returns a lazy stream of:

    * `{:text_delta, binary}`,
    * `{:response, Response.t()}` (final assembled),
    * `{:error, reason}` on failure.
  """
  @spec request_stream(
          struct(),
          [Message.t()],
          ModelSettings.t() | nil,
          ModelRequestParameters.t()
        ) ::
          Enumerable.t() | {:error, term()}
  def request_stream(model, messages, settings, params) do
    config = config(model)

    case ensure_credentials(config) do
      :ok ->
        body =
          model
          |> build_body(messages, settings, params)
          |> Map.put("stream", true)

        do_request_stream(config, body, settings)

      {:error, _} = e ->
        [e]
    end
  end

  defp do_request_stream(config, body, settings) do
    case Req.request(
           url: String.trim_trailing(config.base_url, "/") <> "/v1/messages",
           method: :post,
           headers: build_headers(config),
           json: body,
           into: :self,
           finch: ExAgent.Finch,
           receive_timeout: settings_timeout(settings) || @default_timeout
         ) do
      {:ok, %Req.Response{status: 200, body: %Req.Response.Async{}} = resp} ->
        resp |> SSE.stream() |> adapt_anthropic(config.model)

      {:ok, %{status: status, body: body}} ->
        [
          {:error,
           %ExAgent.RequestError{
             provider: :anthropic,
             status: status,
             reason: :http_error,
             body: body
           }}
        ]

      {:error, exception} ->
        [
          {:error,
           %ExAgent.RequestError{
             provider: :anthropic,
             reason: :request_failed,
             body: inspect(exception)
           }}
        ]
    end
  end

  defp adapt_anthropic(sse, model_name) do
    reducer = fn
      :done, acc ->
        if Map.get(acc, :error),
          do: {[], acc},
          else: {[{:response, build_streamed_response(acc)}], acc}

      {:error, _} = e, acc ->
        {[e], Map.put(acc, :error, true)}

      map, acc ->
        interpret_anthropic(map, acc)
    end

    Stream.transform(
      sse,
      %{text: <<>>, in_tokens: nil, out_tokens: nil, model: model_name, error: false},
      reducer
    )
  end

  defp interpret_anthropic(%{"type" => "message_start", "message" => msg}, acc) do
    in_t = get_in(msg, ["usage", "input_tokens"])
    {[], %{acc | in_tokens: in_t, model: msg["model"] || acc.model}}
  end

  defp interpret_anthropic(
         %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => t}},
         acc
       ) do
    {[{:text_delta, t}], %{acc | text: acc.text <> t}}
  end

  # Real Anthropic carries usage under delta.usage; Z.AI carries it at top-level usage.
  defp interpret_anthropic(%{"type" => "message_delta", "usage" => usage}, acc)
       when is_map(usage) do
    out = usage["output_tokens"] || acc.out_tokens
    inp = usage["input_tokens"] || acc.in_tokens
    {[], %{acc | out_tokens: out, in_tokens: inp}}
  end

  defp interpret_anthropic(%{"type" => "message_delta", "delta" => %{"usage" => usage}}, acc)
       when is_map(usage) do
    out = usage["output_tokens"] || acc.out_tokens
    inp = usage["input_tokens"] || acc.in_tokens
    {[], %{acc | out_tokens: out, in_tokens: inp}}
  end

  defp interpret_anthropic(_, acc), do: {[], acc}

  defp build_streamed_response(acc) do
    parts = if acc.text == "", do: [], else: [%Part.Text{content: acc.text}]

    usage =
      if acc.in_tokens || acc.out_tokens do
        %Usage{input_tokens: acc.in_tokens || 0, output_tokens: acc.out_tokens || 0}
      else
        nil
      end

    Message.new_response(parts, usage: usage, model_name: acc.model)
  end

  # ----- decode: response -> our structs ----------------------------------
  @spec parse_response(map(), struct()) :: Response.t()
  def parse_response(%{"content" => content} = body, %Config{system: system}) do
    parts =
      Enum.flat_map(content, fn
        %{"type" => "text", "text" => text} ->
          [%Part.Text{content: text}]

        %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
          [tool_call(name, id, input)]

        %{"type" => "thinking", "thinking" => thought, "signature" => signature} ->
          [%Part.Thinking{content: thought, signature: signature}]

        %{"type" => "redacted_thinking", "data" => data} ->
          [%Part.Thinking{content: data, signature: nil}]

        _ ->
          []
      end)

    %Response{
      parts: parts,
      usage: parse_usage(body["usage"]),
      model_name: body["model"] || system,
      finish_reason: map_stop_reason(body["stop_reason"]),
      timestamp: DateTime.utc_now()
    }
  end

  defp tool_call(name, id, input) when is_map(input),
    do: %Part.ToolCall{tool_name: name, args: input, tool_call_id: id, kind: :function}

  defp tool_call(name, id, input) when is_binary(input) do
    args = (match?({:ok, _}, Jason.decode(input)) && elem(Jason.decode(input), 1)) || %{}
    %Part.ToolCall{tool_name: name, args: args, tool_call_id: id, kind: :function}
  end

  defp tool_call(name, id, _), do: %Part.ToolCall{tool_name: name, args: %{}, tool_call_id: id}

  defp map_stop_reason("end_turn"), do: :stop
  defp map_stop_reason("tool_use"), do: :tool_calls
  defp map_stop_reason("max_tokens"), do: :length
  defp map_stop_reason("stop_sequence"), do: :stop_sequence
  defp map_stop_reason(other) when is_binary(other), do: :unknown
  defp map_stop_reason(nil), do: nil

  defp parse_usage(%{"input_tokens" => in_t, "output_tokens" => out_t}) do
    %Usage{input_tokens: in_t || 0, output_tokens: out_t || 0, details: %{}}
  end

  defp parse_usage(_), do: nil

  # ----- helpers -----------------------------------------------------------
  defp max_tokens(%ModelSettings{max_tokens: n}) when is_integer(n), do: n
  defp max_tokens(_), do: @default_max_tokens

  defp settings_timeout(%ModelSettings{timeout: t}), do: t
  defp settings_timeout(_), do: nil

  defp put_settings(body, %ModelSettings{} = s) do
    body
    |> maybe_put("temperature", s.temperature)
    |> maybe_put("top_p", s.top_p)
  end

  defp put_settings(body, nil), do: body

  defp encode_content(content) when is_binary(content), do: content
  defp encode_content(content), do: Jason.encode!(content)

  defp content_to_string(content) when is_binary(content), do: content
  defp content_to_string(content), do: Jason.encode!(content)

  defp retry_text(content, nil), do: format_retry(content)
  defp retry_text(content, name), do: "Error calling tool #{name}: " <> format_retry(content)

  defp format_retry(content) when is_binary(content), do: content
  defp format_retry(errors) when is_list(errors), do: Jason.encode!(%{"errors" => errors})

  defp args_to_map(nil), do: %{}
  defp args_to_map(args) when is_map(args), do: args

  defp args_to_map(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
