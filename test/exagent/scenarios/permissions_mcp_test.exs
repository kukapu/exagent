defmodule ExAgent.Scenarios.PermissionsMcpTest do
  @moduledoc """
  Scenario 5 — external tools (MCP) + admission control, composed into the loop.

  `mcp/client_test.exs` covers the MCP client mechanics in isolation. This
  scenario proves the **integration**: tools discovered from an MCP server
  actually execute inside `ExAgent.run/3`, and `ExAgent.Permissions` gates them
  (allow / ask / deny) just like local tools.

  Uses a deterministic in-process mock MCP server (the same transport-seam
  pattern as the client tests) so it runs fully offline. The real stdio e2e
  (python) lives in `mcp/client_e2e_test.exs` under the `:mcp_e2e` tag.
  """

  use ExUnit.Case, async: true

  alias ExAgent.Message.Part
  alias ExAgent.MCP.Client
  alias ExAgent.Models.Test
  alias ExAgent.Permissions

  # A mock MCP server over the in-process transport seam. `tools` is a list of
  # {name, description, schema} and `call` is (name, args) -> text.
  defp start_mock_server(ref, tools, call_fn) do
    spawn(fn -> loop(ref, tools, call_fn) end)
  end

  defp loop(ref, tools, call_fn) do
    receive do
      {:sent, bin, from} ->
        req = bin |> IO.iodata_to_binary() |> String.trim() |> Jason.decode!()

        unless req["id"] == nil do
          case req["method"] do
            "initialize" ->
              reply(ref, from, req["id"], %{"capabilities" => %{}})

            "tools/list" ->
              reply(ref, from, req["id"], %{"tools" => Enum.map(tools, &tool_spec/1)})

            "tools/call" ->
              %{"name" => name, "arguments" => args} =
                Map.merge(%{"arguments" => %{}}, req["params"])

              case call_fn.(name, args) do
                {:error, text} ->
                  reply(
                    ref,
                    from,
                    req["id"],
                    %{"isError" => true, "content" => [%{"type" => "text", "text" => text}]}
                  )

                text ->
                  reply(
                    ref,
                    from,
                    req["id"],
                    %{"content" => [%{"type" => "text", "text" => text}]}
                  )
              end
          end
        end

        loop(ref, tools, call_fn)
    end
  end

  defp tool_spec({name, desc, schema}),
    do: %{"name" => name, "description" => desc, "inputSchema" => schema}

  defp reply(ref, from, id, result),
    do:
      send(
        from,
        {ref,
         {:data, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}) <> "\n"}}
      )

  defp start_client(ref, mock, opts \\ []) do
    send_fun = fn _r, bin -> send(mock, {:sent, bin, self()}) end

    Client.start_link(
      Keyword.merge([transport: {send_fun, ref}, command: "mock", timeout: 1_000], opts)
    )
  end

  defp mock_tools,
    do: [
      {"search", "Search the web", search_schema()},
      {"delete_file", "Delete a file", %{type: "object", properties: %{}}}
    ]

  defp search_schema,
    do: %{
      "type" => "object",
      "properties" => %{"q" => %{"type" => "string"}},
      "required" => ["q"]
    }

  defp mock_call do
    fn
      "search", %{"q" => q} -> "results for: #{q}"
      "delete_file", _ -> "deleted!"
    end
  end

  describe "an MCP-discovered tool executes inside the agent loop" do
    test "the model calls search; the loop forwards to the MCP server" do
      ref = make_ref()
      mock = start_mock_server(ref, mock_tools(), mock_call())
      {:ok, client} = start_client(ref, mock)
      {:ok, [search, _delete]} = Client.tools(client)

      model = %Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "search", args: %{"q" => "elixir"}}]},
          "I found it"
        ]
      }

      agent = ExAgent.new(model: model, tools: [search])

      assert {:ok, %{output: "I found it", messages: messages}} =
               ExAgent.run(agent, "search elixir")

      # The MCP tool genuinely ran: its return text is in the history.
      assert find_return(messages, "search") =~ "results for: elixir"

      Client.close(client)
    end
  end

  describe "permissions gate MCP tools exactly like local tools" do
    test ":allow — the MCP tool runs" do
      ref = make_ref()
      mock = start_mock_server(ref, mock_tools(), mock_call())
      {:ok, client} = start_client(ref, mock)
      {:ok, [search, _]} = Client.tools(client)

      model = %Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "search", args: %{"q" => "x"}}]},
          "ok"
        ]
      }

      perms = Permissions.new!(rules: [{"search", :allow}])
      agent = ExAgent.new(model: model, tools: [search])

      assert {:ok, %{messages: messages}} = ExAgent.run(agent, "go", permissions: perms)
      assert find_return(messages, "search") =~ "results for"

      Client.close(client)
    end

    test ":deny — the MCP tool is refused; the model is told it's not permitted" do
      ref = make_ref()
      mock = start_mock_server(ref, mock_tools(), mock_call())
      {:ok, client} = start_client(ref, mock)
      {:ok, [_, delete]} = Client.tools(client)

      model = %Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "delete_file", args: %{}}]},
          "could not delete"
        ]
      }

      perms = Permissions.new!(rules: [{"*", :allow}, {"delete_*", :deny}])
      agent = ExAgent.new(model: model, tools: [delete])

      assert {:ok, %{messages: messages}} = ExAgent.run(agent, "go", permissions: perms)
      assert find_return(messages, "delete_file") =~ "not permitted"

      Client.close(client)
    end

    test ":ask without an approve callback fails closed" do
      ref = make_ref()
      mock = start_mock_server(ref, mock_tools(), mock_call())
      {:ok, client} = start_client(ref, mock)
      {:ok, [search, _]} = Client.tools(client)

      model = %Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "search", args: %{"q" => "x"}}]},
          "ok"
        ]
      }

      perms = Permissions.new!(rules: [{"search", :ask}])
      agent = ExAgent.new(model: model, tools: [search])

      # No :approve callback → :ask fails closed → tool refused.
      assert {:ok, %{messages: messages}} = ExAgent.run(agent, "go", permissions: perms)
      assert find_return(messages, "search") =~ "not permitted"

      Client.close(client)
    end

    test ":ask with an approving callback runs the tool" do
      ref = make_ref()
      mock = start_mock_server(ref, mock_tools(), mock_call())
      {:ok, client} = start_client(ref, mock)
      {:ok, [search, _]} = Client.tools(client)

      model = %Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "search", args: %{"q" => "x"}}]},
          "ok"
        ]
      }

      perms = Permissions.new!(rules: [{"search", :ask}])
      agent = ExAgent.new(model: model, tools: [search])

      assert {:ok, %{messages: messages}} =
               ExAgent.run(agent, "go", permissions: perms, approve: fn _call -> :approve end)

      assert find_return(messages, "search") =~ "results for"

      Client.close(client)
    end
  end

  describe "an MCP tool error surfaces to the model (retry budget)" do
    test "a tool that returns {:error, _} is retried then fails the run" do
      ref = make_ref()
      # A server whose tool always errors.
      mock =
        start_mock_server(ref, [{"flaky", "flaky", %{type: "object", properties: %{}}}], fn _,
                                                                                            _ ->
          {:error, "boom"}
        end)

      send_fun = fn _r, bin -> send(mock, {:sent, bin, self()}) end

      {:ok, client} =
        Client.start_link(transport: {send_fun, ref}, command: "mock", timeout: 1_000)

      {:ok, [flaky]} = Client.tools(client)

      model = %Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "flaky", args: %{}}]},
          {:tool_calls, [%Part.ToolCall{tool_name: "flaky", args: %{}}]},
          {:tool_calls, [%Part.ToolCall{tool_name: "flaky", args: %{}}]}
        ]
      }

      agent = ExAgent.new(model: model, tools: [flaky])

      # The tool never succeeds → retries exhausted → run fails.
      assert {:error, {:unexpected_model_behavior, {:tool_retries_exhausted, "flaky", _}}} =
               ExAgent.run(agent, "go")

      Client.close(client)
    end
  end

  # ---------------------------------------------------------------------------
  defp find_return(messages, name) do
    Enum.find_value(messages, fn
      %ExAgent.Message.Request{parts: parts} ->
        Enum.find_value(parts, fn
          %Part.ToolReturn{tool_name: ^name, content: c} -> c
          _ -> nil
        end)

      _ ->
        nil
    end)
  end
end
