defmodule ExAgent.Providers.OpenAIChatTest do
  use ExUnit.Case, async: false

  alias ExAgent.Message.{Part, Response}
  alias ExAgent.Message, as: Msg
  alias ExAgent.ModelRequestParameters
  alias ExAgent.Models.{OpenAI, OpenRouter}
  alias ExAgent.Providers.OpenAIChat
  alias ExAgent.Tool

  describe "encode: messages -> openai" do
    test "system + user request" do
      msgs = [
        Msg.new_request([
          %Part.System{content: "you are nice"},
          %Part.User{content: "hi"}
        ])
      ]

      assert OpenAIChat.to_openai_messages(msgs) == [
               %{"role" => "system", "content" => "you are nice"},
               %{"role" => "user", "content" => "hi"}
             ]
    end

    test "assistant response with a tool call" do
      msgs = [
        Msg.new_response([
          %Part.ToolCall{
            tool_name: "get_weather",
            args: ~s({"city":"Madrid"}),
            tool_call_id: "call_1"
          }
        ])
      ]

      assert OpenAIChat.to_openai_messages(msgs) == [
               %{
                 "role" => "assistant",
                 "tool_calls" => [
                   %{
                     "id" => "call_1",
                     "type" => "function",
                     "function" => %{
                       "name" => "get_weather",
                       "arguments" => ~s({"city":"Madrid"})
                     }
                   }
                 ]
               }
             ]
    end

    test "assistant response with text keeps content" do
      msgs = [Msg.new_response([%Part.Text{content: "hello"}])]

      assert OpenAIChat.to_openai_messages(msgs) == [
               %{"role" => "assistant", "content" => "hello"}
             ]
    end

    test "tool return -> role tool" do
      msgs = [
        Msg.new_request([
          %Part.ToolReturn{tool_name: "get_weather", content: "sunny", tool_call_id: "call_1"}
        ])
      ]

      assert OpenAIChat.to_openai_messages(msgs) == [
               %{"role" => "tool", "tool_call_id" => "call_1", "content" => "sunny"}
             ]
    end

    test "tool return with a map content is JSON-encoded" do
      msgs = [
        Msg.new_request([
          %Part.ToolReturn{
            tool_name: "search",
            content: %{temp: 22},
            tool_call_id: "call_1"
          }
        ])
      ]

      [encoded] = OpenAIChat.to_openai_messages(msgs)
      assert {:ok, %{"temp" => 22}} = Jason.decode(encoded["content"])
    end

    test "generic retry prompt -> user message" do
      msgs = [
        Msg.new_request([
          %Part.Retry{content: "please answer"}
        ])
      ]

      [encoded] = OpenAIChat.to_openai_messages(msgs)
      assert encoded["role"] == "user"
      assert encoded["content"] =~ "please answer"
    end

    test "tool retry -> role tool keyed by tool_call_id" do
      msgs = [
        Msg.new_response([
          %Part.ToolCall{tool_name: "get_weather", args: %{}, tool_call_id: "call_1"}
        ]),
        Msg.new_request([
          %Part.Retry{
            content: "city is required",
            tool_name: "get_weather",
            tool_call_id: "call_1"
          }
        ])
      ]

      [_assistant, encoded] = OpenAIChat.to_openai_messages(msgs)

      assert encoded == %{
               "role" => "tool",
               "tool_call_id" => "call_1",
               "content" => "Error calling tool get_weather: city is required"
             }
    end
  end

  describe "encode_tools/1" do
    test "builds function tool payloads" do
      tools = [
        Tool.new(
          name: "get_weather",
          description: "Get weather",
          parameters_json_schema: %{type: "object", properties: %{city: %{type: "string"}}}
        )
      ]

      assert OpenAIChat.encode_tools(tools) == [
               %{
                 "type" => "function",
                 "function" => %{
                   "name" => "get_weather",
                   "description" => "Get weather",
                   "parameters" => %{type: "object", properties: %{city: %{type: "string"}}}
                 }
               }
             ]
    end

    test "returns nil for empty list" do
      assert OpenAIChat.encode_tools([]) == nil
    end
  end

  describe "decode: response -> our structs" do
    test "text response with usage" do
      body = %{
        "model" => "gpt-4o-mini",
        "choices" => [
          %{
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => "Hello there"}
          }
        ],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 2, "total_tokens" => 7}
      }

      resp = OpenAIChat.parse_response(body, %OpenAIChat.Config{system: "openai"})

      assert %Response{parts: [%Part.Text{content: "Hello there"}]} = resp
      assert resp.finish_reason == :stop
      assert resp.model_name == "gpt-4o-mini"
      assert resp.usage.input_tokens == 5
      assert resp.usage.output_tokens == 2
      assert resp.usage.details == %{"total_tokens" => 7}
    end

    test "tool-call response keeps arguments as raw JSON string" do
      body = %{
        "model" => "gpt-4o-mini",
        "choices" => [
          %{
            "finish_reason" => "tool_calls",
            "message" => %{
              "role" => "assistant",
              "tool_calls" => [
                %{
                  "id" => "call_abc",
                  "function" => %{"name" => "get_weather", "arguments" => ~s({"city":"Madrid"})}
                }
              ]
            }
          }
        ]
      }

      resp = OpenAIChat.parse_response(body, %OpenAIChat.Config{system: "openai"})

      assert %Response{
               parts: [%Part.ToolCall{tool_name: "get_weather", tool_call_id: "call_abc"}]
             } =
               resp

      assert resp.parts |> hd() |> Part.ToolCall.args_as_map() == {:ok, %{"city" => "Madrid"}}
      assert resp.finish_reason == :tool_calls
    end

    test "error body -> {:error, %RequestError{}} (keeps the tuple contract)" do
      body = %{"error" => %{"message" => "invalid api key"}}

      assert {:error,
              %ExAgent.RequestError{provider: :openai, reason: :provider_error, body: message}} =
               OpenAIChat.parse_body(body, %OpenAIChat.Config{system: "openai"})

      assert message =~ "invalid api key"
    end

    test "OpenRouter error bodies are labeled as openrouter" do
      body = %{"error" => %{"message" => "upstream unavailable"}}

      assert {:error, %ExAgent.RequestError{provider: :openrouter, reason: :provider_error}} =
               OpenAIChat.parse_body(body, %OpenAIChat.Config{
                 provider: :openrouter,
                 system: "openrouter"
               })
    end

    test "missing credentials preserve provider identity from model config" do
      without_env(["OPENAI_API_KEY", "OPENROUTER_API_KEY"], fn ->
        params = %ModelRequestParameters{}

        assert {:error, %ExAgent.RequestError{provider: :openai, reason: :missing_credentials}} =
                 OpenAIChat.request(%OpenAI{model: "gpt-4o-mini", api_key: nil}, [], nil, params)

        assert {:error,
                %ExAgent.RequestError{provider: :openrouter, reason: :missing_credentials}} =
                 OpenAIChat.request(
                   %OpenRouter{model: "openai/gpt-4o-mini", api_key: nil},
                   [],
                   nil,
                   params
                 )
      end)
    end
  end

  describe "end-to-end translation (round trip)" do
    test "a full conversation encodes then decodes losslessly" do
      conv = [
        Msg.new_request([%Part.System{content: "be brief"}, %Part.User{content: "weather?"}]),
        Msg.new_response([
          %Part.ToolCall{
            tool_name: "get_weather",
            args: ~s({"city":"Madrid"}),
            tool_call_id: "c1"
          }
        ]),
        Msg.new_request([
          %Part.ToolReturn{tool_name: "get_weather", content: "sunny", tool_call_id: "c1"}
        ]),
        Msg.new_response([%Part.Text{content: "It's sunny in Madrid"}])
      ]

      encoded = OpenAIChat.to_openai_messages(conv)

      assert [
               %{"role" => "system"},
               %{"role" => "user"},
               %{"role" => "assistant"} = a,
               %{"role" => "tool"},
               %{"role" => "assistant" = _} | _
             ] = encoded

      assert %{"tool_calls" => [%{"id" => "c1"}]} = a
    end
  end

  defp without_env(keys, fun) do
    previous = Map.new(keys, &{&1, System.get_env(&1)})
    Enum.each(keys, &System.delete_env/1)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
