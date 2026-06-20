defmodule ExAgent.Scenarios.RealProvidersTest do
  @moduledoc """
  Scenario 7 — real wire-format validation across many providers via OpenRouter.

  Opt-in: excluded by default (`:integration` tag). Run with:

      MIX_ENV=test mix test --include integration

  and `OPENROUTER_API_KEY` in the environment. Per-test skip when the key is
  absent.

  All models route through OpenRouter (OpenAI Chat Completions wire format),
  so this exercises `ExAgent.Providers.OpenAIChat` against each backend's
  response quirks: usage shape, finish_reason, content extraction and tool-call
  round-tripping. It catches parsing/integration bugs that the offline
  `ExAgent.Models.Test` cannot.
  """

  use ExUnit.Case, async: true

  alias ExAgent.{Tool, Models}
  alias ExAgent.Message.Part

  @moduletag :integration

  # The nine model slugs (via OpenRouter) covering the major providers.
  @models [
    "deepseek/deepseek-v4-flash",
    "minimax/minimax-m3",
    "xiaomi/mimo-v2.5",
    "anthropic/claude-haiku-4.5",
    "google/gemini-3.1-flash-lite",
    "openai/gpt-5.4-nano",
    "z-ai/glm-4.7-flash",
    "moonshotai/kimi-k2.7-code",
    "qwen/qwen3.7-plus"
  ]

  setup do
    if System.get_env("OPENROUTER_API_KEY") in ["", nil] do
      {:skip, "OPENROUTER_API_KEY not set"}
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Basic run + usage accounting — one test per model.
  # ---------------------------------------------------------------------------
  for slug <- @models do
    @tag :integration
    test "basic run + usage: #{slug}" do
      assert {:ok, %{output: text, usage: usage}} =
               run(unquote(slug), "Reply with exactly: pong")

      assert is_binary(text) and text != ""
      # Real providers report non-zero token usage.
      assert (usage.input_tokens || 0) > 0
      assert (usage.output_tokens || 0) > 0
    end
  end

  # ---------------------------------------------------------------------------
  # Tool-call round-trip — one test per model.
  # ---------------------------------------------------------------------------
  for slug <- @models do
    @tag :integration
    test "tool-call round-trip: #{slug}" do
      weather =
        Tool.new(
          name: "get_weather",
          description: "Get the current weather for a city.",
          parameters_json_schema: %{
            type: "object",
            properties: %{city: %{type: "string", description: "City name"}},
            required: ["city"]
          },
          takes_ctx: false,
          call: fn %{"city" => city} -> {:ok, "#{city}: 22C, clear"} end
        )

      assert {:ok, %{messages: messages}} =
               run(
                 unquote(slug),
                 "What's the weather in Madrid? You MUST call the get_weather tool.",
                 tools: [weather]
               )

      # The model should have called the tool, and exAgent should have executed
      # it (its ToolReturn is in the history).
      assert find_return(messages, "get_weather") =~ "22C"
    end
  end

  # ---------------------------------------------------------------------------
  # Streaming — deltas arrive and reassemble (representative subset).
  # ---------------------------------------------------------------------------
  for slug <- ["openai/gpt-5.4-nano", "anthropic/claude-haiku-4.5", "z-ai/glm-4.7-flash"] do
    @tag :integration
    test "streaming deltas: #{slug}" do
      agent = agent(unquote(slug))

      deltas =
        ExAgent.run_stream(agent, "Count from one to five in words.")
        |> Enum.filter(&match?({:delta, _}, &1))
        |> Enum.map(fn {:delta, d} -> d end)
        |> Enum.join()

      assert deltas != ""
    end
  end

  # ---------------------------------------------------------------------------
  # Structured output via Ecto schema (representative).
  # ---------------------------------------------------------------------------
  @tag :integration
  test "structured output (Ecto schema): anthropic/claude-haiku-4.5" do
    agent =
      agent("anthropic/claude-haiku-4.5",
        output: ExAgent.Test.Ticket,
        model_settings: [max_tokens: 1024, temperature: 0]
      )

    assert {:ok, %{output: ticket}} =
             ExAgent.run(
               agent,
               "Classify this support ticket: 'I was charged twice and want a refund.'"
             )

    assert %ExAgent.Test.Ticket{category: cat, priority: _p, summary: _s} = ticket
    assert cat in ["billing", "bug", "feature", "other"]
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp run(slug, prompt, opts \\ []) do
    slug
    |> agent(opts)
    |> ExAgent.run(prompt)
  end

  defp agent(slug, opts \\ []) do
    model =
      Models.OpenRouter.new(
        model: slug,
        app_title: "exagent integration test"
      )

    ExAgent.new(
      model: model,
      instructions: "Be concise and direct.",
      tools: Keyword.get(opts, :tools, []),
      output: Keyword.get(opts, :output, :text),
      # Reasoning models (glm-4.7-flash, etc.) consume tokens on internal
      # thinking, so a tight cap aborts mid-thought and yields finish_reason
      # :length. 1024 leaves comfortable room for both thinking and output.
      model_settings: Keyword.get(opts, :model_settings, max_tokens: 1024, temperature: 0)
    )
  end

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
