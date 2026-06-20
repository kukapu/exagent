defmodule ExAgent.Session.Participant do
  @moduledoc """
  A member of an `ExAgent.Session`: either an `:agent` (typically backed by an
  `ExAgent.Server`) or a `:human` (a real person driving via LiveView/a channel).

  Participants are identified by their `id` (any term, usually a stable string).
  For agents, `ref` may hold a pid / registered name / app-defined handle so the
  host app can drive the agent when its turn comes. ExAgent itself never assumes
  a particular `ref` shape — the Session is agnostic.
  """

  @type kind :: :agent | :human

  defstruct [:id, :kind, :ref, metadata: %{}]

  @type t :: %__MODULE__{
          id: term(),
          kind: kind(),
          ref: term(),
          metadata: map()
        }

  @doc "Build a participant from opts (`:id` required, `:kind` defaults to `:human`)."
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    id = Keyword.fetch!(opts, :id)

    %__MODULE__{
      id: id,
      kind: Keyword.get(opts, :kind, :human),
      ref: Keyword.get(opts, :ref),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
