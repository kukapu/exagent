defmodule ExAgent.Providers.AnthropicTest do
  use ExUnit.Case, async: true

  alias ExAgent.Message.{Part, Response}
  alias ExAgent.Message, as: Msg
  alias ExAgent.Providers.Anthropic
  alias ExAgent.Providers.Anthropic.Config
  alias ExAgent.{ModelRequestParameters, Tool}

  describe "encode: messages -> anthropic" do
    test "system parts are lifted to the top-level system parameter" do
      msgs = [Msg.new_request([%Part.System{content: "be brief"}, %Part.User{content: "hi"}])]

      {system, convo} = Anthropic.encode_messages(msgs)

      assert system == [%{type: "text", text: "be brief"}]
      assert convo == [%{role: :user, content: [%{type: "text", text: "hi"}]}]
    end

    test "multiple system parts become several top-level text blocks" do
      msgs = [
        Msg.new_request([%Part.System{content: "rule 1"}]),
        Msg.new_request([%Part.System{content: "rule 2"}, %Part.User{content: "go"}])
      ]

      {system, convo} = Anthropic.encode_messages(msgs)

      assert Enum.map(system, & &1.text) == ["rule 1", "rule 2"]
      # the empty-after-system first request is dropped; only one user turn remains
      assert length(convo) == 1
    end

    test "assistant tool call -> tool_use block with input as a map" do
      msgs = [
        Msg.new_response([
          %Part.ToolCall{
            tool_name: "get_weather",
            args: %{"city" => "Madrid"},
            tool_call_id: "t1"
          }
        ])
      ]

      {_, convo} = Anthropic.encode_messages(msgs)

      assert convo == [
               %{
                 role: :assistant,
                 content: [
                   %{
                     type: "tool_use",
                     id: "t1",
                     name: "get_weather",
                     input: %{"city" => "Madrid"}
                   }
                 ]
               }
             ]
    end

    test "tool return -> tool_result block inside a user message" do
      msgs = [
        Msg.new_request([
          %Part.ToolReturn{tool_name: "get_weather", content: "sunny", tool_call_id: "t1"}
        ])
      ]

      {_, convo} = Anthropic.encode_messages(msgs)

      assert convo == [
               %{
                 role: :user,
                 content: [%{type: "tool_result", tool_use_id: "t1", content: "sunny"}]
               }
             ]
    end

    test "tool retry -> error tool_result block keyed by tool_use_id" do
      msgs = [
        Msg.new_response([
          %Part.ToolCall{tool_name: "get_weather", args: %{}, tool_call_id: "t1"}
        ]),
        Msg.new_request([
          %Part.Retry{
            content: "city is required",
            tool_name: "get_weather",
            tool_call_id: "t1"
          }
        ])
      ]

      {_, convo} = Anthropic.encode_messages(msgs)

      assert [_, %{role: :user, content: [retry]}] = convo

      assert retry == %{
               type: "tool_result",
               tool_use_id: "t1",
               content: "Error calling tool get_weather: city is required",
               is_error: true
             }
    end

    test "consecutive same-role messages are merged (alternation requirement)" do
      msgs = [
        Msg.new_request([%Part.User{content: "a"}]),
        Msg.new_request([%Part.Retry{content: "please retry"}])
      ]

      {_, convo} = Anthropic.encode_messages(msgs)

      # Both are user turns -> merged into a single user message with two blocks.
      assert [%{role: :user, content: blocks}] = convo
      assert length(blocks) == 2
    end
  end

  describe "encode_tools/1" do
    test "builds tool defs with input_schema" do
      params = %ModelRequestParameters{
        function_tools: [
          Tool.new(name: "g", description: "d", parameters_json_schema: %{type: "object"})
        ]
      }

      assert Anthropic.encode_tools(params) == [
               %{name: "g", description: "d", input_schema: %{type: "object"}}
             ]
    end

    test "returns nil when there are no tools" do
      assert Anthropic.encode_tools(%ModelRequestParameters{}) == nil
    end
  end

  describe "decode: response -> our structs" do
    test "text response with usage and stop_reason" do
      body = %{
        "model" => "glm-4.5-air",
        "content" => [%{"type" => "text", "text" => "hi"}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 3, "output_tokens" => 1}
      }

      resp = Anthropic.parse_response(body, %Config{system: "anthropic"})

      assert %Response{parts: [%Part.Text{content: "hi"}], finish_reason: :stop} = resp
      assert resp.model_name == "glm-4.5-air"
      assert resp.usage.input_tokens == 3
      assert resp.usage.output_tokens == 1
    end

    test "tool_use block -> ToolCallPart with map args" do
      body = %{
        "content" => [
          %{"type" => "tool_use", "id" => "t1", "name" => "g", "input" => %{"x" => 1}}
        ],
        "stop_reason" => "tool_use",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      }

      resp = Anthropic.parse_response(body, %Config{system: "anthropic"})

      assert %Response{
               parts: [%Part.ToolCall{tool_name: "g", tool_call_id: "t1", args: %{"x" => 1}}],
               finish_reason: :tool_calls
             } = resp
    end

    test "thinking block -> ThinkingPart (BUG 4: round-trip for GLM extended thinking)" do
      body = %{
        "content" => [
          %{"type" => "thinking", "thinking" => "let me reason", "signature" => "sig123"},
          %{"type" => "text", "text" => "answer"}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      }

      resp = Anthropic.parse_response(body, %Config{system: "anthropic"})

      assert %Response{
               parts: [
                 %Part.Thinking{content: "let me reason", signature: "sig123"},
                 %Part.Text{content: "answer"}
               ]
             } =
               resp
    end

    test "stop_reason mapping" do
      for {src, expected} <- [
            {"end_turn", :stop},
            {"tool_use", :tool_calls},
            {"max_tokens", :length}
          ] do
        resp =
          Anthropic.parse_response(
            %{
              "content" => [],
              "stop_reason" => src,
              "usage" => %{"input_tokens" => 0, "output_tokens" => 0}
            },
            %Config{system: "anthropic"}
          )

        assert resp.finish_reason == expected
      end
    end

    test "error body -> {:error, %RequestError{}} (keeps the tuple contract)" do
      body = %{"error" => %{"message" => "invalid token"}}

      assert {:error,
              %ExAgent.RequestError{
                provider: :anthropic,
                reason: :provider_error,
                body: message
              }} =
               Anthropic.parse_body(body, %Anthropic.Config{system: "anthropic"})

      assert message =~ "invalid token"
    end
  end
end
