defmodule ExAgent.MCP.ClientTest do
  use ExUnit.Case, async: true

  alias ExAgent.MCP.Client
  alias ExAgent.Tool

  # A deterministic in-process "MCP server". The client's send_fun routes bytes
  # here as {:sent, bin, from}; it replies with {ref, {:data, resp}} to `from`.
  # `respond` is (method, params) -> {:ok, result} | {:error, err} | {:chunks, fun}.
  defp start_mock(ref, respond) do
    spawn(fn -> loop(ref, respond) end)
  end

  defp loop(ref, respond) do
    receive do
      {:sent, bin, from} ->
        req = bin |> IO.iodata_to_binary() |> String.trim() |> Jason.decode!()

        unless req["id"] == nil do
          case respond.(req["method"], Map.get(req, "params", %{})) do
            {:ok, result} -> send_resp(ref, from, req["id"], result)
            {:error, err} -> send(ref, from, req["id"], "error", err)
            :noreply -> :ok
            {:chunks, fun} -> Enum.each(fun.(req["id"]), &send(from, {ref, {:data, &1}}))
          end
        end

        loop(ref, respond)
    end
  end

  defp send_resp(ref, from, id, result), do: send(ref, from, id, "result", result)

  defp send(ref, from, id, kind, body) do
    send(
      from,
      {ref, {:data, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, kind => body}) <> "\n"}}
    )
  end

  defp client_with(ref, mock, opts \\ []) do
    send_fun = fn _r, bin -> send(mock, {:sent, bin, self()}) end

    Client.start_link(
      Keyword.merge([transport: {send_fun, ref}, command: "mock", timeout: 1_000], opts)
    )
  end

  defp default_respond do
    fn
      "initialize", _ ->
        {:ok, %{"capabilities" => %{}, "serverInfo" => %{"name" => "mock"}}}

      "tools/list", _ ->
        {:ok,
         %{
           "tools" => [
             %{
               "name" => "greet",
               "description" => "Greet someone",
               "inputSchema" => %{
                 "type" => "object",
                 "properties" => %{"name" => %{"type" => "string"}},
                 "required" => ["name"]
               }
             }
           ]
         }}

      "tools/call", %{"arguments" => %{"name" => name}} ->
        {:ok, %{"content" => [%{"type" => "text", "text" => "hi " <> name}]}}
    end
  end

  describe "stdio client (mock transport)" do
    test "handshakes, lists tools, and calls a tool end-to-end" do
      ref = make_ref()
      mock = start_mock(ref, default_respond())
      {:ok, client} = client_with(ref, mock)

      assert {:ok, [%Tool{name: "greet", description: "Greet someone"} = tool]} =
               Client.tools(client)

      # The discovered tool forwards to the server.
      assert tool.call.(%{"name" => "Ada"}) == {:ok, "hi Ada"}
      assert {:ok, "hi Bo"} = Client.call_tool(client, "greet", %{"name" => "Bo"})
    end

    test "reassembles a response split across data chunks (line buffering)" do
      ref = make_ref()

      respond = fn
        "initialize", _ ->
          {:ok, %{"capabilities" => %{}}}

        "tools/list", _ ->
          {:chunks,
           fn id ->
             full =
               Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => []}}) <>
                 "\n"

             <<a::binary-size(15), b::binary>> = full
             [a, b]
           end}
      end

      mock = start_mock(ref, respond)
      {:ok, client} = client_with(ref, mock)

      assert {:ok, []} = Client.tools(client)
    end

    test "an error response surfaces as {:error, _}" do
      ref = make_ref()

      respond = fn
        "initialize", _ -> {:ok, %{"capabilities" => %{}}}
        "tools/list", _ -> {:error, %{"code" => -32601, "message" => "not supported"}}
      end

      mock = start_mock(ref, respond)
      {:ok, client} = client_with(ref, mock)

      assert {:error, %{"code" => -32601}} = Client.tools(client)
    end

    test "a tools/call with isError becomes an error" do
      ref = make_ref()

      respond = fn
        "initialize", _ ->
          {:ok, %{"capabilities" => %{}}}

        "tools/list", _ ->
          {:ok, %{"tools" => [%{"name" => "boom"}]}}

        "tools/call", _ ->
          {:ok, %{"isError" => true, "content" => [%{"type" => "text", "text" => "kaboom"}]}}
      end

      mock = start_mock(ref, respond)
      {:ok, client} = client_with(ref, mock)

      assert {:error, "kaboom"} = Client.call_tool(client, "boom", %{})
    end

    test "transport exit fails pending callers and stops the client" do
      ref = make_ref()
      parent = self()

      respond = fn
        "initialize", _ ->
          {:ok, %{"capabilities" => %{}}}

        "tools/list", _ ->
          send(parent, {:saw, :tools_list})
          :noreply
      end

      mock = start_mock(ref, respond)
      {:ok, client} = client_with(ref, mock)

      # A tools call that the mock never answers (it only notifies the test).
      task = Task.async(fn -> Client.tools(client) end)
      assert_receive {:saw, :tools_list}, 100

      send(client, {ref, {:exit_status, 1}})

      assert {:error, {:server_exited, 1}} = Task.await(task, 500)
      assert Process.alive?(client)
      Client.close(client)
    end
  end
end
