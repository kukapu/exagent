defmodule ExAgent.Session.TurnPolicy do
  @moduledoc """
  Decides the order in which session participants take turns.

  A turn policy is a small, stateful module that sequences participants. The
  `ExAgent.Session` owns no scheduling logic of its own — it delegates "who acts
  next" and "may this participant act now" to the policy, so the same Session can
  drive a round-robin chat, an initiative-ordered combat, or a supervisor that
  delegates (Phase 4).

  ## Callbacks

    * `init/1`              — build the policy state from options. `opts` carries
                              `:participants` (the initial list) plus any
                              policy-specific keys (e.g. `:order` for initiative).
    * `next_participant/2`  — return `{:ok, id, new_state}` for the next actor,
                              or `{:done, new_state}` when the sequence is
                              exhausted. `context` carries `%{shared_state: _, participants: _}`
                              for policies that need it.
    * `can_act?/3`          — whether `participant_id` may act right now (the
                              policy tracks the current actor).
    * `participant_joined/2` / `participant_left/2` — keep the policy's roster in
                              sync as participants come and go.

  ## Built-in implementations

    * `ExAgent.Session.TurnPolicy.RoundRobin` — insertion order, cycling forever.
    * `ExAgent.Session.TurnPolicy.Initiative` — an explicit `:order`, cycling forever.
    * (Phase 4) `SupervisorDriven` — a coordinator participant directs others.
  """

  alias ExAgent.Session.Participant

  @type id :: term()
  @type state :: term()
  @type context :: %{shared_state: term(), participants: [Participant.t()]}

  @callback init(opts :: keyword()) :: state()

  @callback next_participant(state(), context()) ::
              {:ok, id(), state()} | {:done, state()}

  @callback can_act?(state(), participant_id :: id(), context()) :: boolean()

  @callback participant_joined(state(), Participant.t()) :: state()

  @callback participant_left(state(), id()) :: state()

  @optional_callbacks [participant_joined: 2, participant_left: 2]

  # ---------------------------------------------------------------------------
  # Dispatch (struct-based, like ExAgent.Model). Lets callers hold an opaque
  # policy state and call through this module without knowing the impl.
  # ---------------------------------------------------------------------------

  @spec init(module(), keyword()) :: state()
  def init(mod, opts) when is_atom(mod), do: mod.init(opts)

  @spec next_participant(state(), context()) ::
          {:ok, id(), state()} | {:done, state()}
  def next_participant(%mod{} = state, ctx), do: mod.next_participant(state, ctx)

  @spec can_act?(state(), id(), context()) :: boolean()
  def can_act?(%mod{} = state, id, ctx), do: mod.can_act?(state, id, ctx)

  @spec participant_joined(state(), Participant.t()) :: state()
  def participant_joined(%mod{} = state, participant) do
    if function_exported?(mod, :participant_joined, 2) do
      mod.participant_joined(state, participant)
    else
      state
    end
  end

  @spec participant_left(state(), id()) :: state()
  def participant_left(%mod{} = state, id) do
    if function_exported?(mod, :participant_left, 2) do
      mod.participant_left(state, id)
    else
      state
    end
  end
end
