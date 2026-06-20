defmodule ExAgent.Session.TurnPolicy.RoundRobin do
  @moduledoc """
  Cycles participants in **insertion order**, forever (each full pass is a
  "round"). The simplest fair policy — good for chat, brainstorming, or any
  turn-taking where everyone gets equal time.

      ExAgent.Session.start_link(
        shared_state: %{},
        policy: :round_robin,
        participants: [Participant.new(id: "a"), Participant.new(id: "b")]
      )
  """

  @behaviour ExAgent.Session.TurnPolicy

  defstruct ids: [], index: 0, current: nil

  @type t :: %__MODULE__{ids: [term()], index: non_neg_integer(), current: term() | nil}

  @impl true
  def init(opts) do
    participants = Keyword.get(opts, :participants, [])
    %__MODULE__{ids: Enum.map(participants, & &1.id)}
  end

  @impl true
  def next_participant(%__MODULE__{ids: []} = state, _ctx),
    do: {:done, %{state | current: nil}}

  def next_participant(%__MODULE__{ids: ids, index: i} = state, _ctx) do
    current = Enum.at(ids, rem(i, length(ids)))
    {:ok, current, %{state | index: i + 1, current: current}}
  end

  @impl true
  def can_act?(%__MODULE__{current: current}, id, _ctx), do: current != nil and current == id

  @impl true
  def participant_joined(%__MODULE__{ids: ids} = state, participant) do
    %{state | ids: ids ++ [participant.id]}
  end

  @impl true
  def participant_left(%__MODULE__{ids: ids, index: i} = state, id) do
    # Realign `index` so removing a participant before it doesn't shift the
    # next pick forward (skipping someone). The Session re-advances when the
    # current participant leaves; this only keeps the index honest.
    leaver_at = Enum.find_index(ids, &(&1 == id))
    new_ids = List.delete(ids, id)

    new_index =
      cond do
        is_nil(leaver_at) -> i
        leaver_at < i -> max(i - 1, 0)
        true -> i
      end

    current = if state.current == id, do: nil, else: state.current
    %{state | ids: new_ids, index: new_index, current: current}
  end
end
