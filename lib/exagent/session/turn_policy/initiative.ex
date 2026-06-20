defmodule ExAgent.Session.TurnPolicy.Initiative do
  @moduledoc """
  Cycles participants in an **explicitly given order**, forever. Use it when
  participants act in a fixed, possibly uneven sequence — D&D initiative order,
  priority-based triage, etc.

  Pass `:order` (a list of participant ids); participants not in `:order` are
  appended after it. If `:order` is omitted, it degrades to insertion order.

      ExAgent.Session.start_link(
        shared_state: %{},
        policy: {:initiative, order: ["rogue", "fighter", "wizard"]},
        participants: [...]
      )
  """

  @behaviour ExAgent.Session.TurnPolicy

  defstruct ids: [], index: 0, current: nil

  @type t :: %__MODULE__{ids: [term()], index: non_neg_integer(), current: term() | nil}

  @impl true
  def init(opts) do
    participants = Keyword.get(opts, :participants, [])
    order = Keyword.get(opts, :order, [])

    known = MapSet.new(participants, & &1.id)
    # Keep only ids that actually correspond to a participant, then append any
    # participants the caller forgot to order (stable, deduped).
    ordered = Enum.filter(order, &MapSet.member?(known, &1))
    rest = Enum.reject(participants, &(&1.id in ordered))
    ids = ordered ++ Enum.map(rest, & &1.id)

    %__MODULE__{ids: ids}
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
    # next pick forward (skipping someone).
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
