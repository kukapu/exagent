defmodule ExAgent.UsageLimits do
  @moduledoc """
  Run-level safety net: caps on requests and token usage, enforced before each
  model request.

  Any `nil` field is unchecked. When a limit is exceeded the run terminates with
  `{:error, {:usage_limit_exceeded, which, value}}` instead of looping or burning
  cost.

  ## Example

      alias ExAgent.UsageLimits

      agent =
        ExAgent.new(
          model: "openai:gpt-4o",
          usage_limits: %UsageLimits{request_limit: 5, total_tokens_limit: 2000}
        )
  """

  @enforce_keys []
  defstruct request_limit: nil,
            total_tokens_limit: nil,
            input_tokens_limit: nil,
            output_tokens_limit: nil

  @type t :: %__MODULE__{
          request_limit: pos_integer() | nil,
          total_tokens_limit: pos_integer() | nil,
          input_tokens_limit: pos_integer() | nil,
          output_tokens_limit: pos_integer() | nil
        }

  @doc """
  Check the limits against accumulated `usage` and the upcoming request count.

  `request_count` is the number of model requests already issued (0 before the
  first). Returns `:ok` or `{:error, {:usage_limit_exceeded, which, value}}`.
  """
  @spec check_before_request(t(), ExAgent.Message.Usage.t(), non_neg_integer()) ::
          :ok | {:error, {:usage_limit_exceeded, atom(), number()}}
  def check_before_request(%__MODULE__{} = limits, usage, request_count) do
    cond do
      exceeds?(limits.request_limit, request_count) ->
        {:error, {:usage_limit_exceeded, :request_limit, request_count}}

      exceeds?(limits.total_tokens_limit, usage.input_tokens + usage.output_tokens) ->
        {:error, {:usage_limit_exceeded, :total_tokens, usage.input_tokens + usage.output_tokens}}

      exceeds?(limits.input_tokens_limit, usage.input_tokens) ->
        {:error, {:usage_limit_exceeded, :input_tokens, usage.input_tokens}}

      exceeds?(limits.output_tokens_limit, usage.output_tokens) ->
        {:error, {:usage_limit_exceeded, :output_tokens, usage.output_tokens}}

      true ->
        :ok
    end
  end

  defp exceeds?(nil, _), do: false
  defp exceeds?(limit, value), do: value >= limit
end
