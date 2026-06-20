defmodule ExAgent.MCP.Protocol do
  @moduledoc """
  Pure JSON-RPC 2.0 encoding/decoding for the Model Context Protocol, plus the
  mapping from an MCP tool spec to an `ExAgent.Tool`.

  Splitting the protocol out (no ports, no processes) keeps it trivially
  unit-testable. `ExAgent.MCP.Client` owns the transport and calls into here.
  """

  alias ExAgent.Tool

  @type decoded ::
          {:response, id :: term(), result :: map()}
          | {:error_response, id :: term(), error :: map()}
          | {:notification, method :: String.t(), params :: map()}
          | :ignore

  @doc "Encode a JSON-RPC request (with an `id`) as a newline-terminated binary."
  @spec encode_request(term(), String.t(), map()) :: iodata()
  def encode_request(id, method, params) when is_binary(method) do
    Jason.encode_to_iodata!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }) ++
      "\n"
  end

  @doc "Encode a JSON-RPC notification (no `id`, no reply expected)."
  @spec encode_notification(String.t(), map()) :: iodata()
  def encode_notification(method, params) when is_binary(method) do
    Jason.encode_to_iodata!(%{"jsonrpc" => "2.0", "method" => method, "params" => params}) ++ "\n"
  end

  @doc """
  Decode one complete JSON-RPC line.

    * a response with a `result` → `{:response, id, result}`
    * a response with an `error` → `{:error_response, id, error}`
    * a notification (no `id`) → `{:notification, method, params}`
    * anything unparseable / unrelated → `:ignore`
  """
  @spec decode(binary()) :: decoded()
  def decode(line) when is_binary(line) do
    line = String.trim(line)

    case Jason.decode(line) do
      {:ok, %{"id" => id, "result" => result}} when id != nil ->
        {:response, id, result}

      {:ok, %{"id" => id, "error" => error}} when id != nil ->
        {:error_response, id, error}

      {:ok, %{"method" => method, "params" => params}} ->
        {:notification, method, params || %{}}

      _ ->
        :ignore
    end
  end

  @doc """
  Map an MCP `tools/list` entry to an `ExAgent.Tool` whose `call` forwards to the
  server via `call_fun`. The tool's result text is extracted from the MCP
  `content` blocks; an MCP `isError: true` becomes `{:error, _}`.
  """
  @spec to_tool(map(), (String.t(), map() -> {:ok, String.t()} | {:error, term()})) :: Tool.t()
  def to_tool(spec, call_fun) when is_function(call_fun, 2) do
    name = spec["name"]
    schema = spec["inputSchema"] || spec["input_schema"] || %{type: "object", properties: %{}}

    Tool.new(
      name: name,
      description: spec["description"] || "MCP tool #{name}",
      parameters_json_schema: schema,
      takes_ctx: false,
      call: fn args -> call_fun.(name, args) end
    )
  end

  @doc "Extract the concatenated text from an MCP `tools/call` result."
  @spec result_to_text(map()) :: {:ok, String.t()} | {:error, term()}
  def result_to_text(%{"isError" => true} = result),
    do: {:error, extract_text(result)}

  def result_to_text(%{"content" => content}) when is_list(content),
    do: {:ok, extract_text(%{"content" => content})}

  def result_to_text(other), do: {:ok, inspect(other)}

  defp extract_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map_join(fn
      %{"type" => "text", "text" => t} -> t
      %{"text" => t} -> t
      block -> inspect(block)
    end)
  end

  defp extract_text(other), do: inspect(other)
end
