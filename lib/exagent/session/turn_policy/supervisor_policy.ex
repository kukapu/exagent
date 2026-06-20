defmodule ExAgent.Session.TurnPolicy.SupervisorPolicy do
  @moduledoc """
  A coordinator-driven turn order: a **supervisor** participant alternates with
  each worker in turn, forever.

  The sequence is `supervisor, worker[0], supervisor, worker[1], …,
  supervisor, worker[0], …`. This models a "DM" or triage coordinator that
  stays in the loop between every worker action — useful when the supervisor
  must react (narrate, validate, re-route) each time a worker acts. The
  supervisor may also hand off mid-turn via `ExAgent.Coordination.handoff/2`, or
  delegate sub-tasks via `ExAgent.Coordination.delegation_tool/2`.

      ExAgent.Session.start_link(
        shared_state: %{},
        policy: {:supervisor, supervisor: "dm", workers: ["rogue", "wizard"]},
        participants: [...]
      )

  `:supervisor` defaults to the first participant; `:workers` defaults to every
  other participant.
  """

  @behaviour ExAgent.Session.TurnPolicy

  defstruct supervisor: nil,
            workers: [],
            worker_index: 0,
            emit_supervisor_next: true,
            current: nil

  @type t :: %__MODULE__{
          supervisor: term() | nil,
          workers: [term()],
          worker_index: non_neg_integer(),
          emit_supervisor_next: boolean(),
          current: term() | nil
        }

  @impl true
  def init(opts) do
    participants = Keyword.get(opts, :participants, [])
    ids = Enum.map(participants, & &1.id)

    supervisor =
      Keyword.get(opts, :supervisor) ||
        case ids do
          [first | _] -> first
          [] -> nil
        end

    workers =
      Keyword.get(opts, :workers) ||
        Enum.reject(ids, &(&1 == supervisor))

    %__MODULE__{supervisor: supervisor, workers: workers}
  end

  @impl true
  def next_participant(%__MODULE__{} = state, _ctx) do
    cond do
      state.emit_supervisor_next and state.supervisor != nil ->
        {:ok, state.supervisor, %{state | current: state.supervisor, emit_supervisor_next: false}}

      state.workers != [] ->
        idx = rem(state.worker_index, length(state.workers))
        worker = Enum.at(state.workers, idx)

        {:ok, worker,
         %{
           state
           | current: worker,
             worker_index: state.worker_index + 1,
             emit_supervisor_next: true
         }}

      state.supervisor != nil ->
        {:ok, state.supervisor, %{state | current: state.supervisor}}

      true ->
        {:done, %{state | current: nil}}
    end
  end

  @impl true
  def can_act?(%__MODULE__{current: current}, id, _ctx),
    do: current != nil and current == id

  @impl true
  def participant_joined(%__MODULE__{workers: workers} = state, %{id: id} = participant) do
    if participant.id == state.supervisor do
      state
    else
      %{state | workers: workers ++ [id]}
    end
  end

  @impl true
  def participant_left(%__MODULE__{workers: workers} = state, id) do
    current = if state.current == id, do: nil, else: state.current
    %{state | workers: List.delete(workers, id), current: current}
  end
end
