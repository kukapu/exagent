defmodule ExAgent.MCP.Client do
  @moduledoc """
  A client for [Model Context Protocol](https://modelcontextprotocol.io) servers
  over the **stdio** transport, exposing a server's tools as `ExAgent.Tool`s.

  An MCP server is an external process that speaks JSON-RPC 2.0 over stdin/stdout
  (e.g. `npx -y @modelcontextprotocol/server-filesystem ./`). This client spawns
  it, performs the `initialize` handshake, lists its tools, and turns each into an
  `ExAgent.Tool` whose execution forwards a `tools/call` back to the server.

  ## Example

      # 1) start the server + handshake
      {:ok, client} =
        ExAgent.MCP.Client.start_link(
          command: "npx",
          args: ["-y", "@modelcontextprotocol/server-filesystem", "./data"]
        )

      # 2) discover its tools as ExAgent tools
      tools = ExAgent.MCP.Client.tools(client)

      # 3) use them like any ExAgent tool
      agent = ExAgent.new(model: "anthropic:claude-3-5-haiku", tools: tools)
      ExAgent.run(agent, "list the files")

  ## Why a single client per server

  MCP servers are stateful and not generally concurrency-safe; this client
  serializes `tools/call` requests through one GenServer, which is the safe
  default. Tool execution in ExAgent already runs tools concurrently — if a
  particular MCP server is safe to call in parallel, give each agent its own
  client (and thus its own server process).

  ## Testing seam

  The transport is pluggable: pass `transport: {send_fun, ref}` (mostly for
  tests) to inject a fake transport instead of spawning a real process. The
  client receives data as messages shaped `{ref, {:data, binary}}`.
  """

  use GenServer

  alias ExAgent.MCP.Protocol

  @default_timeout 5_000

  defstruct transport_ref: nil,
            send_fun: nil,
            id: 0,
            # id => {from, method}
            pending: %{},
            buffer: "",
            ready: false,
            timeout: @default_timeout

  @type t :: GenServer.server()

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start the client, spawn the MCP server (stdio), and perform the `initialize`
  handshake.

  ## Options

    * `:command` — executable to spawn (required for stdio).
    * `:args` — list of args passed to the command (default `[]`).
    * `:env` — list of `{bin, bin}` env vars (default `[]`).
    * `:timeout` — handshake / per-request timeout in ms (default `5000`).
    * `:cd` — working directory for the spawned server.
    * `:transport` — `{send_fun, ref}` test seam (see moduledoc). When set, no
      process is spawned; `send_fun.(ref, iodata)` must deliver bytes to the
      server and responses must arrive as `{ref, {:data, binary}}` messages.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  List the server's tools as `ExAgent.Tool`s. Each tool's `call` forwards a
  `tools/call` to the server and returns its text result.
  """
  @spec tools(GenServer.server()) :: {:ok, [ExAgent.Tool.t()]} | {:error, term()}
  def tools(client) do
    GenServer.call(client, :tools, timeout(client))
  end

  @doc """
  Call a tool on the server by name. Returns `{:ok, text}` (the concatenated
  content text) or `{:error, reason}`. Used by the generated `ExAgent.Tool`s.
  """
  @spec call_tool(GenServer.server(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def call_tool(client, name, arguments) do
    GenServer.call(client, {:call_tool, name, arguments}, timeout(client))
  end

  @doc "Shut the client and its server process down."
  @spec close(GenServer.server()) :: :ok
  def close(client) do
    GenServer.stop(client, :normal)
  end

  defp timeout(client) do
    try do
      :sys.get_state(client).timeout || @default_timeout
    rescue
      _ -> @default_timeout
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    {ref, send_fun} =
      case Keyword.get(opts, :transport) do
        {fun, transport_ref} when is_function(fun, 2) ->
          {transport_ref, fun}

        nil ->
          port = open_port(opts)
          {port, fn p, data -> true = Port.command(p, data) end}
      end

    state = %__MODULE__{transport_ref: ref, send_fun: send_fun, timeout: timeout}

    # initialize handshake (synchronous: we wait for the response here so that
    # start_link only returns once the server is actually ready).
    case request_sync(state, "initialize", handshake_params(opts), timeout) do
      {:ok, _result, state} ->
        # acknowledge, then mark ready. No reply expected for notifications.
        send_data(state, Protocol.encode_notification("notifications/initialized", %{}))
        {:ok, %{state | ready: true}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp handshake_params(opts) do
    %{
      "protocolVersion" => Keyword.get(opts, :protocol_version, "2024-11-05"),
      "capabilities" => %{},
      "clientInfo" => %{"name" => "exagent", "version" => "1.1.0"}
    }
  end

  defp open_port(opts) do
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, [])

    port_args =
      [
        :binary,
        :use_stdio,
        :stream,
        :exit_status,
        {:args, args},
        {:env, env}
      ] ++ if opts[:cd], do: [{:cd, opts[:cd]}], else: []

    Port.open({:spawn_executable, command}, port_args)
  end

  @impl true
  def handle_call(:tools, from, %__MODULE__{ready: true} = state) do
    {:noreply, async_request(state, "tools/list", %{}, from)}
  end

  def handle_call({:call_tool, name, arguments}, from, %__MODULE__{ready: true} = state) do
    params = %{"name" => name, "arguments" => arguments || %{}}
    {:noreply, async_request(state, "tools/call", params, from)}
  end

  def handle_call(_call, _from, %__MODULE__{ready: false} = state),
    do: {:reply, {:error, :not_ready}, state}

  # Incoming data from the transport (Port or injected ref). Buffer + split lines.
  @impl true
  def handle_info({ref, {:data, chunk}}, %__MODULE__{transport_ref: ref} = state) do
    {lines, buffer} = split_lines(state.buffer <> chunk)
    state = Enum.reduce(lines, %{state | buffer: buffer}, &handle_line(&2, &1))
    {:noreply, state}
  end

  # Transport exited — fail any pending callers and mark not-ready. The client
  # process is left alive (ready: false) so the host can observe the failure and
  # shut it down cleanly, rather than racing a reply against an EXIT.
  def handle_info({ref, {:exit_status, status}}, %__MODULE__{transport_ref: ref} = state) do
    fail_all(state, {:server_exited, status})
    {:noreply, %{state | ready: false}}
  end

  def handle_info({ref, {:eof, _}}, %__MODULE__{transport_ref: ref} = state) do
    fail_all(state, :eof)
    {:noreply, %{state | ready: false}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_port(state.transport_ref) do
      Port.close(state.transport_ref)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Request machinery
  # ---------------------------------------------------------------------------

  # A synchronous request used during init (before the GenServer loop is serving
  # calls): we send and then receive the matching response inline.
  defp request_sync(state, method, params, timeout) do
    {id, iod} = outbound(state, method, params)
    send_data(state, iod)
    deadline = System.monotonic_time(:millisecond) + timeout

    case await_response(id, deadline, "") do
      {:ok, result} -> {:ok, result, %{state | id: id + 1}}
      {:error, _} = e -> e
    end
  end

  # An async request from a GenServer.call: store `from`, send, reply later when
  # the response arrives (in handle_info/handle_line). Returns the new state.
  defp async_request(state, method, params, from) do
    {id, iod} = outbound(state, method, params)
    send_data(state, iod)
    %{state | id: id + 1, pending: Map.put(state.pending, id, {from, method})}
  end

  defp outbound(state, method, params) do
    id = state.id
    {id, Protocol.encode_request(id, method, params)}
  end

  defp send_data(state, iod), do: state.send_fun.(state.transport_ref, iod)

  # During init we own the mailbox; collect {ref, {:data, _}} chunks until the
  # matching response id arrives (or timeout). Non-matching messages are flushed.
  # A JSON-RPC frame may be split across data chunks (the port doesn't preserve
  # message boundaries), so we buffer the way handle_info does — a partial frame
  # with no trailing newline is kept for the next chunk rather than crashing.
  defp await_response(id, deadline, buffer) do
    remaining = deadline - System.monotonic_time(:millisecond)

    receive do
      {ref, {:data, chunk}} when ref != nil ->
        {lines, buffer} = split_lines(buffer <> IO.iodata_to_binary(chunk))

        case find_response(lines, id) do
          {:ok, result} -> {:ok, result}
          {:error, _} = e -> e
          :none -> await_response(id, deadline, buffer)
        end
    after
      max(0, remaining) -> {:error, :timeout}
    end
  end

  defp find_response([], _id), do: :none

  defp find_response([line | rest], id) do
    case Protocol.decode(line) do
      {:response, ^id, result} -> {:ok, result}
      {:error_response, ^id, error} -> {:error, error}
      _ -> find_response(rest, id)
    end
  end

  defp handle_line(state, line) do
    case Protocol.decode(line) do
      {:response, id, result} ->
        reply_pending(state, id, {:ok, result})

      {:error_response, id, error} ->
        reply_pending(state, id, {:error, error})

      {:notification, _method, _params} ->
        # Server-initiated notifications are accepted but not acted on (e.g.
        # tools/list_changed could trigger a refresh; out of scope for now).
        state

      :ignore ->
        state
    end
  end

  defp reply_pending(%{pending: pending} = state, id, reply) do
    case Map.pop(pending, id) do
      {nil, _} ->
        state

      {{from, "tools/list"}, pending} ->
        GenServer.reply(from, map_tools_reply(reply))
        %{state | pending: pending}

      {{from, "tools/call"}, pending} ->
        GenServer.reply(from, tools_call_reply(reply))
        %{state | pending: pending}

      {{from, _method}, pending} ->
        GenServer.reply(from, reply)
        %{state | pending: pending}
    end
  end

  defp map_tools_reply({:ok, %{"tools" => _} = result}), do: {:ok, map_tools(result, nil)}
  defp map_tools_reply({:ok, _}), do: {:ok, []}
  defp map_tools_reply({:error, _} = e), do: e

  defp tools_call_reply({:ok, result}), do: Protocol.result_to_text(result)
  defp tools_call_reply({:error, _} = e), do: e

  defp map_tools(%{"tools" => tools}, _state) when is_list(tools) do
    client = self()

    Enum.map(tools, fn spec ->
      Protocol.to_tool(spec, fn name, args ->
        __MODULE__.call_tool(client, name, args)
      end)
    end)
  end

  defp map_tools(_, _state), do: []

  defp fail_all(%{pending: pending}, reason) do
    for {_id, {from, _method}} <- pending, do: GenServer.reply(from, {:error, reason})
    :ok
  end

  defp split_lines(buffer) do
    case :binary.split(buffer, "\n") do
      [line, rest] ->
        {next_lines, final} = split_lines(rest)
        {[String.trim(line) | next_lines], final}

      [rest] ->
        {[], rest}
    end
  end
end
