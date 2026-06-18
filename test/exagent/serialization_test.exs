defmodule ExAgent.SerializationTest do
  use ExUnit.Case, async: true

  alias ExAgent.Message, as: M
  alias ExAgent.Message.Part

  describe "Message.to_json / from_json round-trip" do
    test "a full conversation survives encode → decode losslessly" do
      conv = [
        M.new_request(
          [
            %Part.System{content: "be brief"},
            %Part.User{content: "hi"}
          ],
          timestamp: nil
        ),
        M.new_response(
          [
            %Part.Thinking{content: "reasoning", signature: "sig1"},
            %Part.ToolCall{
              tool_name: "get_weather",
              args: %{"city" => "Madrid"},
              tool_call_id: "c1",
              kind: :function
            }
          ],
          usage: %M.Usage{input_tokens: 5, output_tokens: 3, details: %{"total" => 8}},
          model_name: "gpt",
          finish_reason: :tool_calls,
          timestamp: nil
        ),
        M.new_request(
          [
            %Part.ToolReturn{tool_name: "get_weather", content: "sunny", tool_call_id: "c1"},
            %Part.Retry{content: "try again", tool_name: "x", tool_call_id: "c2"}
          ],
          timestamp: nil
        ),
        M.new_response([%Part.Text{content: "It's sunny in Madrid"}],
          model_name: "gpt",
          timestamp: nil
        )
      ]

      json = M.to_json(conv)
      assert {:ok, decoded} = M.from_json(json)

      assert decoded == conv
    end

    test "tool-call args round-trip whether map or JSON string" do
      call = %Part.ToolCall{tool_name: "f", args: ~s({"x":1}), tool_call_id: "i", kind: :function}
      resp = M.new_response([call], model_name: "m", timestamp: nil)

      assert {:ok, [decoded]} = M.from_json(M.to_json([resp]))
      # args stored as-is (a JSON string), then still decodable via args_as_map
      assert Part.ToolCall.args_as_map(hd(decoded.parts)) == {:ok, %{"x" => 1}}
    end

    test "DateTime timestamps round-trip through ISO8601" do
      ts = ~U[2026-01-15 12:30:00Z]
      msg = M.new_request([%Part.User{content: "x"}], timestamp: ts)
      assert {:ok, [decoded]} = M.from_json(M.to_json([msg]))
      assert decoded.timestamp == ts
    end

    test "opaque tool-return content degrades to an inspected string (no crash)" do
      msg =
        M.new_request(
          [%Part.ToolReturn{tool_name: "f", content: {:weird, :tuple}, tool_call_id: "i"}],
          timestamp: nil
        )

      assert {:ok, [decoded]} = M.from_json(M.to_json([msg]))
      assert hd(decoded.parts).content == "{:weird, :tuple}"
    end

    test "bad input -> error" do
      assert {:error, _} = M.from_json("not json")
      assert {:error, _} = M.from_json(Jason.encode!(%{"not" => "a list"}))
    end
  end
end
