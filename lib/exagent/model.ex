defmodule ExAgent.ModelRequestParameters do
  @moduledoc """
  The per-request contract handed to a model. It bundles the tools the agent
  has prepared (function tools + output tools), the negotiated output mode, and
  the structured-output schema (if any).

  The struct is deliberately minimal for now and grows as we add tool/output
  features.
  """
  alias ExAgent.{Tool, Message}

  @type output_mode :: :text | :tool | :native | :prompted | :auto
  @type output_object :: %{json_schema: map(), module: module() | nil}

  defstruct function_tools: [],
            output_tools: [],
            output_mode: :text,
            allow_text_output: true,
            output_object: nil,
            instructions: []

  @type t :: %__MODULE__{
          function_tools: [Tool.t()],
          output_tools: [Tool.t()],
          output_mode: output_mode(),
          allow_text_output: boolean(),
          output_object: output_object() | nil,
          instructions: [Message.Part.System.t()]
        }
end

defmodule ExAgent.Model do
  @moduledoc """
  Behaviour that every provider model implements.

  A "model" is any struct whose module `@behaviour`s `ExAgent.Model`. The
  struct carries the model's own state (base URL, API key, configured
  options…). Callers never invoke a provider module directly — they go through
  the dispatch functions in this module (`request/4`, `request_stream/4`, …),
  which resolve the implementer from the struct's `__struct__`.

  This uses Elixir behaviours plus struct dispatch so providers can stay small
  and explicit.
  """

  alias ExAgent.{Message, ModelSettings, ModelRequestParameters}

  @type model :: struct()
  @type messages :: [Message.t()]

  @doc """
  Make a non-streaming request and return a full `Message.Response`.

  Implementations return the (possibly updated) model struct alongside the
  response. Real providers return the model unchanged; stateful models (e.g.
  the script-driven `Test`) thread their internal state through the run this
  way, avoiding globals.
  """
  @callback request(
              model :: model(),
              messages,
              ModelSettings.t() | nil,
              ModelRequestParameters.t()
            ) :: {:ok, Message.Response.t(), model()} | {:error, term()}

  @doc """
  Make a streaming request. Returns an enumerable of events. Implementations
  may instead return `{:error, _}` if streaming is unsupported.
  """
  @callback request_stream(
              model :: model(),
              messages,
              ModelSettings.t() | nil,
              ModelRequestParameters.t()
            ) :: Enumerable.t() | {:error, term()}

  @callback model_name(model()) :: String.t()
  @callback system(model()) :: String.t()

  @doc "Declares this model's capabilities (optional; defaults are permissive)."
  @callback profile(model()) :: ExAgent.ModelProfile.t()

  @optional_callbacks [request_stream: 4, profile: 1]

  # --- dispatch ------------------------------------------------------------
  @spec request(model(), messages, ModelSettings.t() | nil, ModelRequestParameters.t()) ::
          {:ok, Message.Response.t(), model()} | {:error, term()}
  def request(%mod{} = model, messages, settings, params) do
    mod.request(model, messages, settings, params)
  end

  @spec request_stream(model(), messages, ModelSettings.t() | nil, ModelRequestParameters.t()) ::
          Enumerable.t()
  def request_stream(%mod{} = model, messages, settings, params) do
    if function_exported?(mod, :request_stream, 4) do
      case mod.request_stream(model, messages, settings, params) do
        {:error, _} = e -> Stream.concat([[], [e]])
        stream -> stream
      end
    else
      Stream.concat([[], [{:error, {:unsupported, :streaming}}]])
    end
  end

  @spec model_name(model()) :: String.t()
  def model_name(%mod{} = model), do: mod.model_name(model)

  @spec system(model()) :: String.t()
  def system(%mod{} = model), do: mod.system(model)

  @spec profile(model()) :: ExAgent.ModelProfile.t()
  def profile(%mod{} = model) do
    if function_exported?(mod, :profile, 1) do
      mod.profile(model)
    else
      %ExAgent.ModelProfile{}
    end
  end

  @doc """
  Resolve a model from a spec. A struct is returned as-is; a string like
  `"openai:gpt-4o"` is resolved via the provider registry (only a few providers
  are wired up for now).
  """
  @spec resolve(model() | String.t()) :: {:ok, model()} | {:error, term()}
  def resolve(%_{} = model), do: {:ok, model}

  def resolve("test:" <> rest), do: {:ok, %ExAgent.Models.Test{label: rest}}
  def resolve("test"), do: {:ok, %ExAgent.Models.Test{}}

  def resolve("openai:" <> name),
    do: {:ok, ExAgent.Models.OpenAI.new(model: name)}

  def resolve("openrouter:" <> name),
    do: {:ok, ExAgent.Models.OpenRouter.new(model: name)}

  def resolve("anthropic:" <> name),
    do: {:ok, ExAgent.Models.Anthropic.new(model: name)}

  # Z.AI (Zhipu) GLM models via their Anthropic-compatible endpoint.
  # Cheap pick: "glm-4.5-air". Needs ZAI_API_KEY (or ANTHROPIC_AUTH_TOKEN).
  def resolve("zai:" <> name) do
    token = System.get_env("ZAI_API_KEY") || System.get_env("ANTHROPIC_AUTH_TOKEN")

    {:ok,
     ExAgent.Models.Anthropic.new(
       model: name,
       auth_token: token,
       base_url: "https://api.z.ai/api/anthropic"
     )}
  end

  def resolve(other) do
    {:error, {:unknown_model, other}}
  end
end
