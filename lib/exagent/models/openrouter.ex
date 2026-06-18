defmodule ExAgent.Models.OpenRouter do
  @moduledoc """
  [OpenRouter](https://openrouter.ai) provider.

  OpenRouter speaks the OpenAI Chat Completions wire format, so it reuses
  `ExAgent.Providers.OpenAIChat`. The only differences are the base URL
  (`https://openrouter.ai/api/v1`), the env key (`OPENROUTER_API_KEY`) and the
  optional attribution headers (`HTTP-Referer` / `X-Title`), pulled from
  `OPENROUTER_APP_URL` / `OPENROUTER_APP_TITLE`.

      model = ExAgent.Models.OpenRouter.new(model: "anthropic/claude-3.5-sonnet")
  """
  @behaviour ExAgent.Model

  defstruct [:model, :api_key, :base_url, extra_headers: []]

  @type t :: %__MODULE__{
          model: String.t(),
          api_key: String.t() | nil,
          base_url: String.t() | nil,
          extra_headers: [{String.t(), String.t()}]
        }

  @doc """
  Build an OpenRouter model.

  Options:
    * `:model`        — the OpenRouter model slug, e.g. `"openai/gpt-4o-mini"`.
    * `:api_key`      — falls back to `OPENROUTER_API_KEY`.
    * `:base_url`     — defaults to `https://openrouter.ai/api/v1`.
    * `:app_url`/`:app_title` — for attribution; default to env vars.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    opts =
      opts
      |> Keyword.put_new(:api_key, System.get_env("OPENROUTER_API_KEY"))
      |> Keyword.put_new(:base_url, "https://openrouter.ai/api/v1")

    extra =
      [
        {"HTTP-Referer", opts[:app_url] || System.get_env("OPENROUTER_APP_URL")},
        {"X-Title", opts[:app_title] || System.get_env("OPENROUTER_APP_TITLE")}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    opts = Keyword.drop(opts, [:app_url, :app_title])
    struct!(__MODULE__, Keyword.merge(opts, extra_headers: extra))
  end

  @impl true
  def request(model, messages, settings, params),
    do: ExAgent.Providers.OpenAIChat.request(model, messages, settings, params)

  @impl true
  def request_stream(model, messages, settings, params),
    do: ExAgent.Providers.OpenAIChat.request_stream(model, messages, settings, params)

  @impl true
  def model_name(%__MODULE__{model: model}), do: model
  @impl true
  def system(_), do: "openrouter"
  @impl true
  def profile(_),
    do: %ExAgent.ModelProfile{
      supports_tools: true,
      supports_json_schema_output: true,
      supports_thinking: false
    }
end
