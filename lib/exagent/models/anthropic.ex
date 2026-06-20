defmodule ExAgent.Models.Anthropic do
  @moduledoc """
  Anthropic Messages API provider, or any endpoint that speaks the same format
  (e.g. Z.AI's `/api/anthropic`, which serves GLM models natively in Anthropic
  form).

  Two auth modes (mirroring the Anthropic SDK):

    * `:api_key`    → sent as `x-api-key` (real Anthropic, `ANTHROPIC_API_KEY`).
    * `:auth_token` → sent as `Authorization: Bearer` (Z.AI coding plan,
      `ANTHROPIC_AUTH_TOKEN`).

  ## Examples

      # Real Anthropic
      ExAgent.Models.Anthropic.new(model: "claude-3-5-haiku-20241022")

      # Z.AI's Anthropic-compatible endpoint, cheap model
      ExAgent.Models.Anthropic.new(
        model: "glm-4.5-air",
        auth_token: System.fetch_env!("ZAI_API_KEY"),
        base_url: "https://api.z.ai/api/anthropic"
      )
  """
  @behaviour ExAgent.Model

  defstruct [:model, :api_key, :auth_token, :base_url, cache: false]

  @type t :: %__MODULE__{
          model: String.t(),
          api_key: String.t() | nil,
          auth_token: String.t() | nil,
          base_url: String.t() | nil,
          cache: boolean()
        }

  @doc """
  Build an Anthropic model.

  Options: `:model` (required), `:api_key`, `:auth_token`, `:base_url`,
  `:cache` (default `false`). When `:cache` is `true`, Anthropic prompt-caching
  breakpoints are added to the system prompt and the last tool definition
  (60–90% input-token savings on repeated long prefixes).
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    opts =
      opts
      |> Keyword.put_new(:api_key, System.get_env("ANTHROPIC_API_KEY"))
      |> Keyword.put_new(:auth_token, System.get_env("ANTHROPIC_AUTH_TOKEN"))

    struct!(__MODULE__, opts)
  end

  @impl true
  def request(model, messages, settings, params),
    do: ExAgent.Providers.Anthropic.request(model, messages, settings, params)

  @impl true
  def request_stream(model, messages, settings, params),
    do: ExAgent.Providers.Anthropic.request_stream(model, messages, settings, params)

  @impl true
  def model_name(%__MODULE__{model: model}), do: model
  @impl true
  def system(_), do: "anthropic"
  @impl true
  def profile(_),
    do: %ExAgent.ModelProfile{
      supports_tools: true,
      supports_json_schema_output: false,
      supports_thinking: true
    }
end
