defmodule ExAgent.Models.OpenAI do
  @moduledoc """
  OpenAI Chat Completions provider. Talks the real API over Req.

      model = %__MODULE__{model: "gpt-4o-mini"}
      {:ok, %{output: text}} = ExAgent.run(agent_with(model), "hi")

  The actual wire translation lives in `ExAgent.Providers.OpenAIChat`; this
  module just holds config and delegates.
  """
  @behaviour ExAgent.Model

  defstruct [:model, :api_key, :base_url, extra_headers: []]

  @type t :: %__MODULE__{
          model: String.t(),
          api_key: String.t() | nil,
          base_url: String.t() | nil,
          extra_headers: [{String.t(), String.t()}]
        }

  @doc "Build an OpenAI model. `:api_key` falls back to `OPENAI_API_KEY`."
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    opts = Keyword.put_new(opts, :api_key, System.get_env("OPENAI_API_KEY"))
    struct!(__MODULE__, opts)
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
  def system(_), do: "openai"
  @impl true
  def profile(_),
    do: %ExAgent.ModelProfile{
      supports_tools: true,
      supports_json_schema_output: true,
      supports_thinking: false
    }
end
