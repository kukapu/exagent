defmodule ExAgent.Session.SharedState do
  @moduledoc """
  A handle placed in `RunContext.deps` so tools running inside an agent run can
  read the session's shared state and **propose** changes — without ever holding
  a mutable reference to it.

  This enforces the Session's single-writer rule: a tool never mutates the world
  directly. It reads through `SharedState.read/1` and proposes a change through
  `SharedState.propose_change/2`, which the Session validates (it must be the
  owning participant's turn) and applies atomically.

  ## Wiring

  Build the handle when you start the agent's run for a participant, and pass it
  as `deps`:

      handle = ExAgent.Session.SharedState.new(session, "dm")
      ExAgent.Server.chat(dm_server, "narrate the scene", deps: handle)

  Inside a tool:

      deftool set_scene(ctx, description :: String.t()) do
        {:ok, _new_state} =
          ExAgent.Session.SharedState.propose_change(ctx.deps, fn s ->
            {:ok, %{s | scene: description}}
          end)

        {:ok, "scene updated"}
      end
  """

  alias ExAgent.Session

  defstruct [:session, :participant_id]

  @type t :: %__MODULE__{
          session: GenServer.server(),
          participant_id: term()
        }

  @doc "Build a handle for `participant_id` operating on `session`."
  @spec new(GenServer.server(), term()) :: t()
  def new(session, participant_id),
    do: %__MODULE__{session: session, participant_id: participant_id}

  @doc "Read the current shared state (read-only; anyone may read)."
  @spec read(t()) :: term()
  def read(%__MODULE__{session: session}), do: Session.read_state(session)

  @doc """
  Propose a change to the shared state. The Session applies `change_fn`
  atomically **only if it's this participant's turn**; otherwise it returns
  `{:error, :not_your_turn}`. Does not advance the turn (use `Session.end_turn/2`
  when the participant is done).
  """
  @spec propose_change(t(), (term() -> {:ok, term()} | {:error, term()} | term())) ::
          {:ok, term()} | {:error, term()}
  def propose_change(%__MODULE__{session: session, participant_id: id}, change_fn),
    do: Session.update_state(session, id, change_fn)
end
