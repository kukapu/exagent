defmodule ExAgent.RequestError do
  @moduledoc """
  Structured error returned by providers for transport/API failures.

  Every provider wraps failures in this struct so callers can pattern-match on a
  single shape instead of opaque tuples. `ExAgent.run/3` surfaces it (wrapped in
  `{:error, {:model_request_failed, %RequestError{}}}`) rather than raising.
  """
  @enforce_keys [:provider, :reason]
  defstruct [:provider, :status, :reason, :body]

  @type t :: %__MODULE__{
          provider: atom(),
          status: pos_integer() | nil,
          reason:
            :http_error | :provider_error | :request_failed | :timeout | :missing_credentials,
          body: term() | nil
        }
end

defmodule ExAgent.UnexpectedModelBehavior do
  @moduledoc """
  Raised/returned when the model behaves in a way the loop cannot recover from
  (retries exhausted, no progress, usage limits hit).
  """
  defexception [:message]

  @impl true
  def exception(message) when is_binary(message), do: %__MODULE__{message: message}

  def exception(reason), do: %__MODULE__{message: inspect(reason)}
end

defmodule ExAgent.ModelRetry do
  @moduledoc """
  A tool or output validator can return/raise this to ask the model to try
  again. In Elixir we mostly use `{:error, reason}` tuples, but this exception
  exists for the rescue-based escape hatch.
  """
  defexception [:message]

  @impl true
  def exception(message) when is_binary(message), do: %__MODULE__{message: message}
end
