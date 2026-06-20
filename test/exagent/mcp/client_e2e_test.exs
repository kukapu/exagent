defmodule ExAgent.MCP.ClientE2ETest do
  use ExUnit.Case, async: false

  alias ExAgent.MCP.Client
  alias ExAgent.Tool

  # A real end-to-end test of the stdio transport: spawns a tiny MCP server
  # (python) over a Port and exercises the full handshake → tools/list →
  # tools/call path. Skipped per-test when python3 isn't on PATH.
  @moduletag :mcp_e2e

  setup do
    if System.find_executable("python3") == nil do
      {:skip, "python3 not available"}
    else
      :ok
    end
  end

  test "spawns a server over stdio, lists tools, calls a tool" do
    python = System.find_executable("python3")
    script = python_mock_server()

    path =
      Path.join(System.tmp_dir!(), "exagent_mcp_mock_#{:erlang.unique_integer([:positive])}.py")

    File.write!(path, script)
    on_exit(fn -> File.rm(path) end)

    {:ok, client} =
      Client.start_link(command: python, args: [path], timeout: 5_000)

    assert {:ok, [%Tool{name: "greet"} = tool]} = Client.tools(client)
    assert tool.description == "Greet someone"

    assert {:ok, "hi Ada"} = Client.call_tool(client, "greet", %{"name" => "Ada"})
    assert :ok = Client.close(client)
  end

  # A minimal MCP server: reads newline-delimited JSON-RPC on stdin, replies on
  # stdout. Handles initialize / tools/list / tools/call.
  defp python_mock_server do
    """
    import sys, json
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception:
            continue
        rid = req.get("id")
        if rid is None:
            continue  # notification, no reply
        m = req.get("method")
        if m == "initialize":
            r = {"capabilities": {}}
        elif m == "tools/list":
            r = {"tools": [{"name": "greet", "description": "Greet someone",
                            "inputSchema": {"type": "object",
                                            "properties": {"name": {"type": "string"}}}}]}
        elif m == "tools/call":
            name = (req.get("params", {}).get("arguments") or {}).get("name", "")
            r = {"content": [{"type": "text", "text": "hi " + name}]}
        else:
            r = {}
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": rid, "result": r}) + "\\n")
        sys.stdout.flush()
    """
  end
end
