defmodule ExAgent.Providers.OpenAIChat do
  @moduledoc """
  Shared implementation for any provider that speaks the OpenAI **Chat
  Completions** wire format (`/v1/chat/completions`). This covers OpenAI itself
  and OpenRouter (and DeepSeek, Groq, Together, etc.).

  The two directions every provider needs:

    * **encode** — our `Message` history → the `messages` array the API expects
      (roles `system` / `user` / `assistant` / `tool`), and our `Tool` list →
      the `tools` array.
    * **decode** — the API JSON response back into our `Message.Response` with
      `TextPart` / `ToolCallPart` parts and `Usage`.

  Providers are thin structs carrying `{:model, :api_key, :base_url,
  :extra_headers}`; `request/4` reads those fields generically, so the same code
  drives `%OpenAI{}` and `%OpenRouter{}`.
  """

  alias ExAgent.{Message, ModelSettings, ModelRequestParameters, Tool}
  alias ExAgent.Message.{Part, Response, Usage}
  alias ExAgent.Providers.SSE

  @default_timeout 60_000

  @doc "Perform a (non-streaming) chat-completions request."
  @spec request(struct(), [Message.t()], ModelSettings.t() | nil, ModelRequestParameters.t()) ::
          {:ok, Response.t(), struct()} | {:error, term()}
  def request(model, messages, settings, params) do
    config = config(model)

    with :ok <- ensure_credentials(config) do
      body = build_body(config, messages, settings, params)
      headers = build_headers(config)

      http_opts = [
        url: String.trim_trailing(config.base_url, "/") <> "/chat/completions",
        method: :post,
        headers: headers,
        json: body,
        finch: ExAgent.Finch,
        receive_timeout: settings_timeout(settings) || @default_timeout
      ]

      case Req.request(http_opts) do
        {:ok, %{status: 200, body: resp_body}} ->
          case parse_body(resp_body, config) do
            {:ok, resp} -> {:ok, resp, model}
            {:error, _} = e -> e
          end

        {:ok, %{status: status, body: body}} ->
          {:error,
           %ExAgent.RequestError{
             provider: config.provider,
             status: status,
             reason: :http_error,
             body: body
           }}

        {:error, %{reason: :timeout} = exception} ->
          {:error,
           %ExAgent.RequestError{
             provider: config.provider,
             reason: :timeout,
             body: inspect(exception)
           }}

        {:error, exception} ->
          {:error,
           %ExAgent.RequestError{
             provider: config.provider,
             reason: :request_failed,
             body: inspect(exception)
           }}
      end
    end
  end

  defp ensure_credentials(%{api_key: nil, provider: provider}),
    do: {:error, %ExAgent.RequestError{provider: provider, reason: :missing_credentials}}

  defp ensure_credentials(_), do: :ok

  defp settings_timeout(%ModelSettings{timeout: t}), do: t
  defp settings_timeout(_), do: nil

  @doc false
  # Pure body classification used by `request/4` — kept public so it can be
  # unit-tested without a network (provider error bodies vs. normal responses).
  @spec parse_body(map(), struct()) ::
          {:ok, Response.t()} | {:error, ExAgent.RequestError.t()}
  def parse_body(%{"error" => error}, config) do
    {:error,
     %ExAgent.RequestError{
       provider: config.provider,
       reason: :provider_error,
       body: error["message"] || inspect(error)
     }}
  end

  def parse_body(body, config), do: {:ok, parse_response(body, config)}

  @doc """
  Perform a streaming chat-completions request. Returns a lazy stream of:

    * `{:text_delta, binary}` — incremental text,
    * `{:response, Response.t()}` — the final assembled response,
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
          build_body(config, messages, settings, params)
          |> Map.put("stream", true)
          |> Map.put("stream_options", %{"include_usage" => true})

        headers = build_headers(config)

        http_opts = [
          url: String.trim_trailing(config.base_url, "/") <> "/chat/completions",
          method: :post,
          headers: headers,
          json: body,
          into: :self,
          finch: ExAgent.Finch,
          receive_timeout: settings_timeout(settings) || @default_timeout
        ]

        do_request_stream(http_opts, config)

      {:error, _} = e ->
        [e]
    end
  end

  defp do_request_stream(http_opts, config) do
    case Req.request(http_opts) do
      {:ok, %Req.Response{status: 200, body: %Req.Response.Async{}} = resp} ->
        resp |> SSE.stream() |> adapt_openai(config.model)

      {:ok, %{status: status, body: body}} ->
        [
          {:error,
           %ExAgent.RequestError{
             provider: config.provider,
             status: status,
             reason: :http_error,
             body: body
           }}
        ]

      {:error, exception} ->
        [
          {:error,
           %ExAgent.RequestError{
             provider: config.provider,
             reason: :request_failed,
             body: inspect(exception)
           }}
        ]
    end
  end

  # Interpret OpenAI SSE chunks: choices[0].delta.content -> text deltas.
  defp adapt_openai(sse, model_name) do
    reducer = fn
      :done, acc ->
        {[{:response, build_streamed_response(acc)}], acc}

      {:error, _} = e, acc ->
        {[e], Map.put(acc, :error, true)}

      map, acc ->
        text = get_in(map, ["choices", Access.at(0), "delta", "content"]) || ""
        usage = map["usage"]

        acc = %{acc | text: acc.text <> text, usage: usage || acc.usage}
        events = if text == "", do: [], else: [{:text_delta, text}]
        {events, acc}
    end

    Stream.transform(sse, %{text: <<>>, usage: nil, model: model_name, error: false}, reducer)
  end

  defp build_streamed_response(acc) do
    parts = if acc.text == "", do: [], else: [%Part.Text{content: acc.text}]
    Message.new_response(parts, usage: acc.usage && parse_usage(acc.usage), model_name: acc.model)
  end

  defmodule Config do
    @moduledoc false
    defstruct [:model, :api_key, :base_url, :system, provider: :openai, extra_headers: []]

    @type t :: %__MODULE__{
            model: String.t(),
            api_key: String.t() | nil,
            base_url: String.t(),
            system: String.t(),
            provider: atom(),
            extra_headers: [{String.t(), String.t()}]
          }
  end

  # Extract a Config from a provider struct (OpenAI/OpenRouter share the fields).
  defp config(%{
         __struct__: mod,
         model: model,
         api_key: key,
         base_url: base,
         extra_headers: extra
       }) do
    %Config{
      model: model,
      api_key: key || env_key(mod),
      base_url: base || default_base_url(mod),
      system: Atom.to_string(mod) |> String.split(".") |> List.last() |> String.downcase(),
      provider: provider(mod),
      extra_headers: extra || []
    }
  end

  defp provider(ExAgent.Models.OpenAI), do: :openai
  defp provider(ExAgent.Models.OpenRouter), do: :openrouter
  defp provider(_), do: :openai

  defp env_key(ExAgent.Models.OpenAI), do: System.get_env("OPENAI_API_KEY")
  defp env_key(ExAgent.Models.OpenRouter), do: System.get_env("OPENROUTER_API_KEY")
  defp env_key(_), do: nil

  defp default_base_url(ExAgent.Models.OpenAI), do: "https://api.openai.com/v1"
  defp default_base_url(ExAgent.Models.OpenRouter), do: "https://openrouter.ai/api/v1"
  defp default_base_url(_), do: "https://api.openai.com/v1"

  # ----- request body ------------------------------------------------------
  defp build_body(%Config{model: model}, messages, settings, params) do
    tools = build_tools(params)

    %{}
    |> Map.put("model", model)
    |> Map.put("messages", to_openai_messages(messages))
    |> maybe_put("stream", false)
    |> put_settings(settings)
    |> maybe_put("tools", tools)
    |> maybe_put("tool_choice", tool_choice(params, tools))
  end

  defp build_headers(%Config{api_key: key, extra_headers: extra}) do
    auth = [{"authorization", "Bearer " <> key}]

    [{"content-type", "application/json"} | auth ++ extra]
  end

  defp put_settings(body, %ModelSettings{} = s) do
    body
    |> maybe_put("max_tokens", s.max_tokens)
    |> maybe_put("temperature", s.temperature)
    |> maybe_put("top_p", s.top_p)
    |> maybe_put("presence_penalty", s.presence_penalty)
    |> maybe_put("frequency_penalty", s.frequency_penalty)
  end

  defp put_settings(body, nil), do: body

  defp tool_choice(%ModelRequestParameters{output_mode: :tool}, _), do: "required"
  defp tool_choice(_, nil), do: nil
  defp tool_choice(_, _), do: "auto"

  # ----- tools -------------------------------------------------------------
  @doc "Encode a list of `Tool` into the OpenAI `tools` payload (or `nil`)."
  @spec encode_tools([Tool.t()]) :: [map()] | nil
  def encode_tools(tools) when is_list(tools) do
    case Enum.map(tools, &encode_tool/1) do
      [] -> nil
      list -> list
    end
  end

  defp encode_tool(%Tool{} = t) do
    %{
      "type" => "function",
      "function" => %{
        "name" => t.name,
        "description" => t.description,
        "parameters" => t.parameters_json_schema
      }
    }
  end

  defp build_tools(%ModelRequestParameters{function_tools: f, output_tools: o}) do
    encode_tools(f ++ o)
  end

  # ----- encode: messages → openai ----------------------------------------
  @spec to_openai_messages([Message.t()]) :: [map()]
  def to_openai_messages(messages) do
    Enum.flat_map(messages, &encode_message/1)
  end

  defp encode_message(%Message.Request{parts: parts}) do
    Enum.flat_map(parts, &encode_request_part/1)
  end

  defp encode_message(%Message.Response{parts: parts}) do
    [encode_assistant(parts)]
  end

  defp encode_request_part(%Part.System{content: content}),
    do: [%{"role" => "system", "content" => content_to_string(content)}]

  defp encode_request_part(%Part.User{content: content}),
    do: [%{"role" => "user", "content" => content_to_string(content)}]

  defp encode_request_part(%Part.ToolReturn{
         tool_name: name,
         content: content,
         tool_call_id: id
       }),
       do: [
         %{"role" => "tool", "tool_call_id" => id || name, "content" => encode_content(content)}
       ]

  defp encode_request_part(%Part.Retry{content: content, tool_name: nil}),
    do: [%{"role" => "user", "content" => retry_text(content, nil)}]

  defp encode_request_part(%Part.Retry{content: content, tool_name: name, tool_call_id: id}),
    do: [
      %{
        "role" => "tool",
        "tool_call_id" => id || name,
        "content" => retry_text(content, name)
      }
    ]

  defp encode_assistant(parts) do
    text =
      parts
      |> Enum.filter(&match?(%Part.Text{}, &1))
      |> Enum.map_join(& &1.content)

    tool_calls =
      parts
      |> Enum.filter(&match?(%Part.ToolCall{}, &1))
      |> Enum.map(&encode_tool_call/1)

    assistant = %{"role" => "assistant"}
    assistant = if text == "", do: assistant, else: Map.put(assistant, "content", text)
    if tool_calls == [], do: assistant, else: Map.put(assistant, "tool_calls", tool_calls)
  end

  defp encode_tool_call(%Part.ToolCall{tool_name: name, args: args, tool_call_id: id}) do
    %{
      "id" => id || name,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => args_json(args)}
    }
  end

  defp args_json(nil), do: "{}"
  defp args_json(args) when is_binary(args), do: args
  defp args_json(args) when is_map(args), do: Jason.encode!(args)

  defp encode_content(content) when is_binary(content), do: content
  defp encode_content(content), do: Jason.encode!(content)

  defp content_to_string(content) when is_binary(content), do: content
  defp content_to_string(content), do: Jason.encode!(content)

  defp retry_text(content, nil), do: format_retry(content)

  defp retry_text(content, name),
    do: "Error calling tool #{name}: " <> format_retry(content)

  defp format_retry(content) when is_binary(content), do: content
  defp format_retry(errors) when is_list(errors), do: Jason.encode!(%{"errors" => errors})

  # ----- decode: response → our structs -----------------------------------
  @spec parse_response(map(), struct()) :: Response.t()
  def parse_response(%{"choices" => [choice | _]} = body, %Config{system: system}) do
    message = Map.get(choice, "message", %{})
    finish_reason = parse_finish_reason(Map.get(choice, "finish_reason"))

    text_parts =
      case Map.get(message, "content") do
        nil -> []
        "" -> []
        content -> [%Part.Text{content: content}]
      end

    tool_parts =
      message
      |> Map.get("tool_calls", [])
      |> Enum.map(&parse_tool_call/1)

    %Response{
      parts: text_parts ++ tool_parts,
      usage: parse_usage(body["usage"]),
      model_name: body["model"] || system,
      finish_reason: finish_reason,
      timestamp: DateTime.utc_now()
    }
  end

  # Map known finish reasons to atoms; never mint atoms from arbitrary provider
  # input (avoids atom-table growth via a hostile/buggy proxy).
  @finish_reasons %{
    "stop" => :stop,
    "length" => :length,
    "tool_calls" => :tool_calls,
    "content_filter" => :content_filter,
    "function_call" => :function_call
  }
  defp parse_finish_reason(nil), do: nil
  defp parse_finish_reason(reason), do: Map.get(@finish_reasons, reason, :unknown)

  defp parse_tool_call(%{
         "id" => id,
         "function" => %{"name" => name, "arguments" => args}
       }) do
    %Part.ToolCall{tool_name: name, args: args, tool_call_id: id, kind: :function}
  end

  defp parse_usage(nil), do: nil

  defp parse_usage(%{"prompt_tokens" => in_t, "completion_tokens" => out_t} = u) do
    %Usage{
      input_tokens: in_t || 0,
      output_tokens: out_t || 0,
      details: Map.take(u, ["total_tokens"])
    }
  end

  defp parse_usage(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
