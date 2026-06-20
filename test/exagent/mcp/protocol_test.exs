defmodule ExAgent.MCP.ProtocolTest do
  use ExUnit.Case, async: true

  alias ExAgent.MCP.Protocol

  describe "encode" do
    test "encode_request produces a JSON-RPC request with an id + newline" do
      bin = IO.iodata_to_binary(Protocol.encode_request(7, "tools/list", %{"a" => 1}))
      assert String.ends_with?(bin, "\n")

      assert %{"jsonrpc" => "2.0", "id" => 7, "method" => "tools/list", "params" => %{"a" => 1}} =
               Jason.decode!(bin)
    end

    test "encode_notification has no id" do
      bin = IO.iodata_to_binary(Protocol.encode_notification("notifications/initialized", %{}))
      decoded = Jason.decode!(bin)
      assert decoded["method"] == "notifications/initialized"
      refute Map.has_key?(decoded, "id")
    end
  end

  describe "decode" do
    test "a result response" do
      line = ~s({"jsonrpc":"2.0","id":3,"result":{"tools":[]}})
      assert Protocol.decode(line) == {:response, 3, %{"tools" => []}}
    end

    test "an error response" do
      line = ~s({"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"no such method"}})

      assert Protocol.decode(line) ==
               {:error_response, 3, %{"code" => -32601, "message" => "no such method"}}
    end

    test "a notification (no id)" do
      line = ~s({"jsonrpc":"2.0","method":"notifications/cancelled","params":{"x":1}})
      assert Protocol.decode(line) == {:notification, "notifications/cancelled", %{"x" => 1}}
    end

    test "garbage is ignored" do
      assert Protocol.decode("not json") == :ignore
      assert Protocol.decode("") == :ignore
    end
  end

  describe "to_tool" do
    test "maps an MCP tool spec to an ExAgent.Tool that forwards via call_fun" do
      spec = %{
        "name" => "greet",
        "description" => "Greet someone",
        "inputSchema" => %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}
      }

      {:ok, _} = Agent.start_link(fn -> [] end)

      call_fun = fn "greet", %{"name" => name} -> {:ok, "hi #{name}"} end
      tool = Protocol.to_tool(spec, call_fun)

      assert tool.name == "greet"
      assert tool.description == "Greet someone"
      assert tool.parameters_json_schema == spec["inputSchema"]
      assert tool.takes_ctx == false
      assert tool.call.(%{"name" => "Ada"}) == {:ok, "hi Ada"}
    end
  end

  describe "result_to_text" do
    test "concatenates text content blocks" do
      result = %{
        "content" => [
          %{"type" => "text", "text" => "hello "},
          %{"type" => "text", "text" => "world"}
        ]
      }

      assert Protocol.result_to_text(result) == {:ok, "hello world"}
    end

    test "an isError result becomes an error" do
      result = %{"isError" => true, "content" => [%{"type" => "text", "text" => "boom"}]}
      assert {:error, "boom"} = Protocol.result_to_text(result)
    end
  end
end
