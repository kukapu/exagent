defmodule ExAgent.ModelSettings do
  @moduledoc """
  Per-request knobs sent to the model. Provider-specific options that are not
  first-class fields can be carried in the immutable `:extra` map.
  """
  @enforce_keys []
  defstruct max_tokens: nil,
            temperature: nil,
            top_p: nil,
            presence_penalty: nil,
            frequency_penalty: nil,
            timeout: nil,
            extra: %{}

  @type t :: %__MODULE__{
          max_tokens: pos_integer() | nil,
          temperature: float() | nil,
          top_p: float() | nil,
          presence_penalty: float() | nil,
          frequency_penalty: float() | nil,
          timeout: pos_integer() | nil,
          extra: map()
        }

  @doc "Merge two settings, `overrides` winning on non-nil values."
  @spec merge(t(), t() | nil) :: t()
  def merge(%__MODULE__{} = base, nil), do: base

  def merge(%__MODULE__{} = base, %__MODULE__{} = overrides) do
    fields = [:max_tokens, :temperature, :top_p, :presence_penalty, :frequency_penalty, :timeout]

    merged =
      Enum.reduce(fields, base, fn f, acc ->
        case Map.fetch(overrides, f) do
          {:ok, nil} -> acc
          {:ok, v} -> %{acc | f => v}
          :error -> acc
        end
      end)

    %{merged | extra: Map.merge(base.extra, overrides.extra)}
  end

  @doc "Build settings from a keyword/enum of options, ignoring nils."
  @spec new(keyword() | map()) :: t()
  def new(opts) when is_list(opts) do
    opts
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> then(fn kw ->
      {extra, kw} = Keyword.pop_first(kw, :extra, [])
      struct!(__MODULE__, Keyword.put(kw, :extra, Map.new(extra)))
    end)
  end

  def new(opts) when is_map(opts), do: new(Map.to_list(opts))
end
