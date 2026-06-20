defmodule ExAgent.UsageLimits do
  @moduledoc """
  Run-level safety net: caps on requests, token usage, tool calls and cost,
  enforced at well-defined points in the agent loop.

  Any `nil` field is unchecked. When a limit is exceeded the run terminates with
  `{:error, {:usage_limit_exceeded, which, value}}` instead of looping or burning
  cost.

  * `request_limit` / `total_tokens_limit` / `input_tokens_limit` /
    `output_tokens_limit` — checked before each model request.
  * `tool_calls_limit` — checked before a batch of tool calls is executed
    (pydanticAI semantics: if the model returned parallel calls that would
    exceed the limit, none run).
  * `max_budget_cents` — checked before each model request against an estimated
    cost (see `ExAgent.CostGuard`). Requires an `:estimate_cost` run option.

  ## Example

      alias ExAgent.{CostGuard, UsageLimits}

      agent =
        ExAgent.new(
          model: "openai:gpt-4o",
          usage_limits: %UsageLimits{
            request_limit: 5,
            total_tokens_limit: 2000,
            tool_calls_limit: 10,
            max_budget_cents: 25
          }
        )

      pricing = CostGuard.estimator(%{input_per_1k_cents: 250, output_per_1k_cents: 1000})
      ExAgent.run(agent, "research this", estimate_cost: pricing)
  """

  @enforce_keys []
  defstruct request_limit: nil,
            total_tokens_limit: nil,
            input_tokens_limit: nil,
            output_tokens_limit: nil,
            tool_calls_limit: nil,
            max_budget_cents: nil

  @type t :: %__MODULE__{
          request_limit: pos_integer() | nil,
          total_tokens_limit: pos_integer() | nil,
          input_tokens_limit: pos_integer() | nil,
          output_tokens_limit: pos_integer() | nil,
          tool_calls_limit: pos_integer() | nil,
          max_budget_cents: number() | nil
        }

  @doc """
  Check the request/token/budget limits against accumulated `usage`, the
  upcoming request count, and the estimated `cost_cents`. Returns `:ok` or
  `{:error, {:usage_limit_exceeded, which, value}}`.

  `request_count` is the number of model requests already issued (0 before the
  first). `cost_cents` is the estimated cost so far (0 when no estimator is in
  use).
  """
  @spec check_before_request(t(), ExAgent.Message.Usage.t(), non_neg_integer(), number()) ::
          :ok | {:error, {:usage_limit_exceeded, atom(), number()}}
  def check_before_request(%__MODULE__{} = limits, usage, request_count, cost_cents \\ 0) do
    total = (usage.input_tokens || 0) + (usage.output_tokens || 0)

    cond do
      exceeds?(limits.request_limit, request_count) ->
        {:error, {:usage_limit_exceeded, :request_limit, request_count}}

      exceeds?(limits.total_tokens_limit, total) ->
        {:error, {:usage_limit_exceeded, :total_tokens, total}}

      exceeds?(limits.input_tokens_limit, usage.input_tokens || 0) ->
        {:error, {:usage_limit_exceeded, :input_tokens, usage.input_tokens || 0}}

      exceeds?(limits.output_tokens_limit, usage.output_tokens || 0) ->
        {:error, {:usage_limit_exceeded, :output_tokens, usage.output_tokens || 0}}

      exceeds?(limits.max_budget_cents, cost_cents) ->
        {:error, {:usage_limit_exceeded, :budget_cents, cost_cents}}

      true ->
        :ok
    end
  end

  @doc """
  Check the `tool_calls_limit` before executing a batch of `incoming` tool
  calls. Returns `:ok` or `{:error, {:usage_limit_exceeded, :tool_calls, n}}`.

  `executed` is the number of tool calls already run this run. Following
  pydanticAI, if `executed + incoming` would exceed the limit, none of the
  incoming calls are executed.
  """
  @spec check_tool_calls(t(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, {:usage_limit_exceeded, :tool_calls, non_neg_integer()}}
  def check_tool_calls(%__MODULE__{tool_calls_limit: nil}, _executed, _incoming), do: :ok

  def check_tool_calls(%__MODULE__{tool_calls_limit: limit}, executed, incoming) do
    total = executed + incoming

    if total > limit do
      {:error, {:usage_limit_exceeded, :tool_calls, total}}
    else
      :ok
    end
  end

  defp exceeds?(nil, _), do: false
  defp exceeds?(limit, value), do: value >= limit
end

defmodule ExAgent.CostGuard do
  @moduledoc """
  Helpers for turning token usage into an estimated cost, used together with
  the `max_budget_cents` field of `ExAgent.UsageLimits`.

  ExAgent does **not** ship a pricing table (model prices change constantly and
  vary by vendor). You bring the prices that matter to you as a map and
  `CostGuard.estimator/1` builds the `(usage -> cents)` function you pass to
  `ExAgent.run/3` via the `:estimate_cost` option.

  ## Example

      pricing = ExAgent.CostGuard.estimator(%{
        input_per_1k_cents: 250,
        output_per_1k_cents: 1000
      })

      ExAgent.run(agent, "go", estimate_cost: pricing)
  """

  alias ExAgent.Message.Usage

  @type pricing :: %{
          optional(:input_per_1k_cents) => number(),
          optional(:output_per_1k_cents) => number()
        }

  @doc """
  Build a cost estimator `(Usage.t() -> integer cents)` from a pricing map.

  Prices are per **1000 tokens**, in **cents** (so `250` = $2.50 / 1M input
  tokens, matching how vendors quote).
  """
  @spec estimator(pricing()) :: (Usage.t() -> non_neg_integer())
  def estimator(pricing) when is_map(pricing) do
    in_per_1k = Map.get(pricing, :input_per_1k_cents, 0)
    out_per_1k = Map.get(pricing, :output_per_1k_cents, 0)

    fn %Usage{} = usage ->
      input = usage.input_tokens || 0
      output = usage.output_tokens || 0
      trunc((input * in_per_1k + output * out_per_1k) / 1000)
    end
  end
end
