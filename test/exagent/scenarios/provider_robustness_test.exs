defmodule ExAgent.Scenarios.ProviderRobustnessTest do
  @moduledoc """
  Regression tests for malformed provider responses.

  Real providers (OpenAI, OpenRouter, Azure, DeepSeek, Anthropic, Z.AI) all
  occasionally return a 200 with a body the happy-path parser would crash on.
  These tests pin that such responses yield a usable (possibly empty) Response
  instead of a FunctionClauseError / Protocol.UndefinedError that kills the run.
  """

  use ExUnit.Case, async: true

  alias ExAgent.Message.{Part, Response}
  alias ExAgent.Providers.{Anthropic, OpenAIChat}

  defp openai_cfg, do: %OpenAIChat.Config{system: "openai"}
  defp anthropic_cfg, do: %Anthropic.Config{system: "anthropic"}

  describe "OpenAI: empty / missing choices" do
    test "choices: [] does not crash" do
      assert %Response{parts: []} = OpenAIChat.parse_response(%{"choices" => []}, openai_cfg())
    end

    test "no choices key does not crash" do
      assert %Response{parts: []} =
               OpenAIChat.parse_response(%{"model" => "gpt", "usage" => nil}, openai_cfg())
    end

    test "tool_calls: null does not crash (Azure refusal path)" do
      assert %Response{parts: [%Part.Text{content: "no"}]} =
               OpenAIChat.parse_response(
                 %{
                   "choices" => [
                     %{
                       "message" => %{"content" => "no", "tool_calls" => nil},
                       "finish_reason" => "stop"
                     }
                   ]
                 },
                 openai_cfg()
               )
    end

    test "a malformed tool_call entry is skipped, not fatal" do
      assert %Response{parts: [%Part.Text{content: "x"}]} =
               OpenAIChat.parse_response(
                 %{
                   "choices" => [
                     %{
                       "message" => %{
                         "content" => "x",
                         "tool_calls" => [%{"id" => "incomplete"}]
                       }
                     }
                   ]
                 },
                 openai_cfg()
               )
    end
  end

  describe "OpenAI: partial usage is preserved" do
    test "only prompt_tokens still yields a Usage (no silent drop)" do
      assert %Response{usage: %ExAgent.Message.Usage{input_tokens: 7, output_tokens: 0}} =
               OpenAIChat.parse_response(
                 %{
                   "choices" => [%{"message" => %{"content" => "hi"}}],
                   "usage" => %{"prompt_tokens" => 7}
                 },
                 openai_cfg()
               )
    end
  end

  describe "Anthropic: nil / missing content" do
    test "content: null does not crash" do
      assert %Response{parts: []} =
               Anthropic.parse_response(%{"content" => nil, "model" => "c"}, anthropic_cfg())
    end

    test "no content key does not crash" do
      assert %Response{parts: []} =
               Anthropic.parse_response(%{"model" => "c"}, anthropic_cfg())
    end
  end
end
