defmodule ExAgent.RunEvent do
  @moduledoc false
  # Internal, loop-level events emitted by ExAgent.run/3 through the optional
  # `:on_event` callback. They carry only loop-intrinsic data (steps, tool
  # calls, usage, output, errors); the runtime layer (ExAgent.Server) is
  # responsible for turning them into versioned ExAgent.Event envelopes —
  # assigning seq/id/occurred_at and correlation ids — and broadcasting them.
  #
  # Keeping these two concerns separate means the pure loop stays decoupled
  # from PubSub/serialization, and one-shot ExAgent.run/3 callers that pass no
  # :on_event pay nothing.

  @enforce_keys [:type]
  defstruct [:type, :run_id, :step, :data]

  @type t :: %__MODULE__{
          type: atom(),
          run_id: String.t() | nil,
          step: non_neg_integer() | nil,
          data: map()
        }

  @spec new(atom(), keyword()) :: t()
  def new(type, opts \\ []) when is_atom(type) do
    opts = Keyword.put(opts, :type, type)
    struct!(__MODULE__, opts)
  end
end
