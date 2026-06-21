defmodule ExAgent.Session do
  @moduledoc """
  A coordinated, multi-participant interaction with shared state.

  `ExAgent.Session` is the **coordination layer** (Roadmap Phase 3): it owns a
  piece of application-defined `shared_state` and a set of *participants*
  (agents backed by `ExAgent.Server`, or humans driving via LiveView), and it
  decides — through a pluggable `ExAgent.Session.TurnPolicy` — whose turn it is.

  It is deliberately agnostic: the `shared_state` can be a D&D world, a support
  ticket, a collaborative document, anything. ExAgent never assumes a shape.

  ## The single-writer rule

  The Session is the **only** process allowed to mutate `shared_state`.
  Participants never touch it directly. Instead, a participant whose turn it is
  passes a *change function* `(state) -> {:ok, new_state} | {:error, reason}`,
  and the Session applies it atomically, emits `:shared_state_updated`, and
  advances the turn. Tools running inside an agent reach the Session through an
  `ExAgent.Session.SharedState` handle placed in `RunContext.deps`.

  ## Lifecycle

      {:ok, session} =
        ExAgent.Session.start_link(
          shared_state: %{log: []},
          policy: :round_robin,
          participants: [
            ExAgent.Session.Participant.new(id: "dm", kind: :agent),
            ExAgent.Session.Participant.new(id: "player", kind: :human)
          ],
          pubsub: :local
        )

      :ok = ExAgent.Session.start(session)
      {:ok, state, next} = ExAgent.Session.take_turn(session, "dm", fn s -> {:ok, %{s | log: ["dm acted" | s.log]}} end)

  Status flows `:created → :running → (:paused ⇄ :running) → :closed`. While not
  `:running`, `take_turn/3` returns `{:error, :paused}` / `{:error, {:not_running, _}}`.

  ## Events

  Published on `ExAgent.Event.session_topic(session_id)` (`"exagent:session:<id>"`):
  `:session_started · :participant_joined · :participant_left ·
  :session_turn_changed · :shared_state_updated · :session_paused ·
  :session_resumed · :session_closed`. Events carry ids/status, never the bulk
  `shared_state` (read it with `read_state/1`).
  """

  use GenServer
  require Logger

  alias ExAgent.{Event, PubSub}
  alias ExAgent.Session.{Participant, TurnPolicy}

  defmodule State do
    @moduledoc false

    defstruct session_id: nil,
              shared_state: nil,
              participants: %{},
              policy_mod: nil,
              policy_state: nil,
              current: nil,
              status: :created,
              pubsub: {ExAgent.PubSub.None, []},
              store: nil,
              topic: nil,
              seq: 0,
              metadata: %{}

    @type status :: :created | :running | :paused | :closed | :done
    @type t :: %__MODULE__{
            session_id: String.t() | nil,
            shared_state: term(),
            participants: %{term() => Participant.t()},
            policy_mod: module(),
            policy_state: term(),
            current: term() | nil,
            status: status(),
            pubsub: {module(), term()},
            store: {module(), term()} | nil,
            topic: String.t() | nil,
            seq: non_neg_integer(),
            metadata: map()
          }
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start a supervised session.

  ## Options

    * `:shared_state` — the initial application-defined state (required-ish;
      defaults to `nil`).
    * `:policy`       — `:round_robin` / `:initiative` / `{:initiative, order: [...]}` /
      `{module, opts}` / `module` (default `:round_robin`).
    * `:participants` — initial list of `ExAgent.Session.Participant.t()`.
    * `:session_id`   — stable id for events; auto-generated if absent.
    * `:pubsub`       — `nil`/`:none`/`:local`/`{module, config}` (default `nil`).
    * `:store`        — `nil`/`:ets`/`{module, config}` (default `nil`, no
                       persistence). When set, `shared_state` + turn position
                       are checkpointed after every change and rehydrated on
                       restart. The live participant `ref`s come from
                       `:participants` on restart; only the serializable
                       coordination state is restored.
    * `:name`         — registered name for the GenServer.
    * `:metadata`     — free-form map attached to every emitted event.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Add a participant (allowed before or during a running session)."
  @spec join(GenServer.server(), Participant.t() | keyword()) :: :ok
  def join(session, %Participant{} = p), do: GenServer.call(session, {:join, p})
  def join(session, opts) when is_list(opts), do: join(session, Participant.new(opts))

  @doc "Remove a participant by id. Returns `:ok` or `{:error, :not_found}`."
  @spec leave(GenServer.server(), term()) :: :ok | {:error, :not_found}
  def leave(session, id), do: GenServer.call(session, {:leave, id})

  @doc "Begin turns. Picks the first participant via the policy. `:created → :running`."
  @spec start(GenServer.server()) :: {:ok, term()} | {:error, term()}
  def start(session), do: GenServer.call(session, :start)

  @doc "The participant id whose turn it currently is (or `nil`)."
  @spec current(GenServer.server()) :: term() | nil
  def current(session), do: GenServer.call(session, :current)

  @doc "All registered participants."
  @spec participants(GenServer.server()) :: [Participant.t()]
  def participants(session), do: GenServer.call(session, :participants)

  @doc "Current session status (`:created | :running | :paused | :closed | :done`)."
  @spec status(GenServer.server()) :: :created | :running | :paused | :closed | :done
  def status(session), do: GenServer.call(session, :status)

  @doc "Read the shared state (read-only snapshot; anyone may call this)."
  @spec read_state(GenServer.server()) :: term()
  def read_state(session), do: GenServer.call(session, :read_state)

  @doc """
  Take a turn: apply `change_fn` to the shared state atomically, then advance to
  the next participant. `change_fn` is `(state) -> {:ok, new_state} | {:error,
  reason}` (a bare value is treated as the new state).

  Returns `{:ok, new_state, next_participant_id}` or `{:error, reason}` —
  `:not_your_turn`, `:paused`, or `{:not_running, status}`.
  """
  @spec take_turn(GenServer.server(), term(), (term() ->
                                                 {:ok, term()} | {:error, term()} | term())) ::
          {:ok, term(), term()} | {:error, term()}
  def take_turn(session, participant_id, change_fn),
    do: GenServer.call(session, {:take_turn, participant_id, change_fn})

  @doc """
  Mutate the shared state **without** advancing the turn — for mid-turn changes
  (e.g. a tool inside an agent run proposes a change). Only the current
  participant may call this.
  """
  @spec update_state(GenServer.server(), term(), (term() ->
                                                    {:ok, term()} | {:error, term()} | term())) ::
          {:ok, term()} | {:error, term()}
  def update_state(session, participant_id, change_fn),
    do: GenServer.call(session, {:update_state, participant_id, change_fn})

  @doc "End the current participant's turn without changing state, advancing next."
  @spec end_turn(GenServer.server(), term()) :: {:ok, term()} | {:error, term()}
  def end_turn(session, participant_id), do: GenServer.call(session, {:end_turn, participant_id})

  @doc "Pause a running session (`take_turn/3` then returns `{:error, :paused}`)."
  @spec pause(GenServer.server()) :: :ok | {:error, term()}
  def pause(session), do: GenServer.call(session, :pause)

  @doc "Resume a paused session."
  @spec resume(GenServer.server()) :: :ok | {:error, term()}
  def resume(session), do: GenServer.call(session, :resume)

  @doc "Close the session. Further turns return `{:error, {:not_running, :closed}}`."
  @spec close(GenServer.server()) :: :ok
  def close(session), do: GenServer.call(session, :close)

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    {pmod, popts} = normalize_policy(Keyword.get(opts, :policy, :round_robin))

    participants = Keyword.get(opts, :participants, [])
    participant_map = Map.new(participants, &{&1.id, &1})

    session_id = Keyword.get(opts, :session_id) || generate_id("session_")
    store = ExAgent.Store.normalize(Keyword.get(opts, :store))

    # Rehydrate coordination state from the store (if any). The live participant
    # refs come from `opts`; only shared_state, turn position, status and the
    # roster ids/kinds are restored — never pids/secrets/closures.
    {shared_state, policy_state, current, status, seq, rehydrated_participants} =
      load_session_state(store, session_id, %{
        shared_state: Keyword.get(opts, :shared_state),
        participants: participant_map,
        policy_mod: pmod,
        policy_opts: Keyword.put(popts, :participants, participants),
        current: nil,
        status: :created,
        seq: 0
      })

    # Merge rehydrated kinds for participants the app didn't re-supply.
    participant_map = merge_participants(participant_map, rehydrated_participants)

    state = %State{
      session_id: session_id,
      shared_state: shared_state,
      participants: participant_map,
      policy_mod: pmod,
      policy_state: policy_state,
      current: current,
      status: status,
      pubsub: PubSub.normalize(Keyword.get(opts, :pubsub)),
      store: store,
      topic: Event.session_topic(session_id),
      seq: seq,
      metadata: Keyword.get(opts, :metadata, %{})
    }

    {:ok, state}
  end

  # ----- join / leave -------------------------------------------------------
  @impl true
  def handle_call({:join, %Participant{} = p}, _from, %State{} = state) do
    state = %{state | participants: Map.put(state.participants, p.id, p)}
    state = update_policy(state, &TurnPolicy.participant_joined(&1, p))

    state =
      broadcast(state, :participant_joined, payload: %{participant_id: p.id, kind: p.kind})

    {:reply, :ok, checkpoint(state)}
  end

  @impl true
  def handle_call({:leave, id}, _from, %State{} = state) do
    case Map.pop(state.participants, id) do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {_p, participants} ->
        state = %{state | participants: participants}
        state = update_policy(state, &TurnPolicy.participant_left(&1, id))
        state = broadcast(state, :participant_left, payload: %{participant_id: id})

        # The current participant leaving mid-turn would otherwise deadlock the
        # session (the policy niled its `current`; no one can satisfy can_act?).
        # Forfeit their turn and advance to the next, or end the session if the
        # roster is now empty.
        state =
          if state.current == id and state.status == :running do
            advance_after_leave(state)
          else
            state
          end

        {:reply, :ok, checkpoint(state)}
    end
  end

  # ----- start --------------------------------------------------------------
  @impl true
  def handle_call(:start, _from, %State{status: :created} = state) do
    case advance(state) do
      {:ok, first, state} ->
        state = broadcast(state, :session_started, payload: %{first: first})
        state = broadcast(state, :session_turn_changed, payload: %{participant_id: first})
        {:reply, {:ok, first}, checkpoint(%{state | status: :running})}

      {:done, state} ->
        {:reply, {:error, :no_participants}, checkpoint(%{state | status: :done})}
    end
  end

  def handle_call(:start, _from, %State{status: status} = state),
    do: {:reply, {:error, {:already_started, status}}, state}

  # ----- take_turn ----------------------------------------------------------
  @impl true
  def handle_call({:take_turn, _id, _fn}, _from, %State{status: :paused} = state),
    do: {:reply, {:error, :paused}, state}

  def handle_call({:take_turn, _id, _fn}, _from, %State{status: status} = state)
      when status in [:created, :closed, :done],
      do: {:reply, {:error, {:not_running, status}}, state}

  def handle_call({:take_turn, id, change_fn}, _from, %State{status: :running} = state) do
    with true <- TurnPolicy.can_act?(state.policy_state, id, context(state)),
         {:ok, state} <- apply_change(state, change_fn),
         {:ok, next, state} <- advance(state) do
      state = broadcast(state, :session_turn_changed, payload: %{participant_id: next})
      {:reply, {:ok, state.shared_state, next}, checkpoint(state)}
    else
      false ->
        {:reply, {:error, :not_your_turn}, state}

      {:error, _} = e ->
        {:reply, e, state}

      {:done, state} ->
        {:reply, {:ok, state.shared_state, :done}, checkpoint(%{state | status: :done})}
    end
  end

  # ----- update_state (mid-turn, no advance) --------------------------------
  @impl true
  def handle_call({:update_state, _id, _fn}, _from, %State{status: :paused} = state),
    do: {:reply, {:error, :paused}, state}

  def handle_call({:update_state, _id, _fn}, _from, %State{status: status} = state)
      when status in [:created, :closed, :done],
      do: {:reply, {:error, {:not_running, status}}, state}

  def handle_call({:update_state, id, change_fn}, _from, %State{status: :running} = state) do
    with true <- TurnPolicy.can_act?(state.policy_state, id, context(state)),
         {:ok, state} <- apply_change(state, change_fn) do
      {:reply, {:ok, state.shared_state}, state}
    else
      false -> {:reply, {:error, :not_your_turn}, state}
      {:error, _} = e -> {:reply, e, state}
    end
  end

  # ----- end_turn -----------------------------------------------------------
  @impl true
  def handle_call({:end_turn, _id}, _from, %State{status: :paused} = state),
    do: {:reply, {:error, :paused}, state}

  def handle_call({:end_turn, _id}, _from, %State{status: status} = state)
      when status in [:created, :closed, :done],
      do: {:reply, {:error, {:not_running, status}}, state}

  def handle_call({:end_turn, id}, _from, %State{status: :running} = state) do
    with true <- TurnPolicy.can_act?(state.policy_state, id, context(state)),
         {:ok, next, state} <- advance(state) do
      state = broadcast(state, :session_turn_changed, payload: %{participant_id: next})
      {:reply, {:ok, next}, checkpoint(state)}
    else
      false -> {:reply, {:error, :not_your_turn}, state}
      {:done, state} -> {:reply, {:ok, :done}, checkpoint(%{state | status: :done})}
    end
  end

  # ----- handoff (direct control transfer, bypassing the policy) -----------
  @impl true
  def handle_call({:handoff, _to_id}, _from, %State{status: status} = state)
      when status in [:created, :paused, :closed, :done],
      do: {:reply, {:error, {:not_running, status}}, state}

  def handle_call({:handoff, to_id}, _from, %State{status: :running} = state) do
    if Map.has_key?(state.participants, to_id) do
      state = update_policy(state, &set_policy_current(&1, to_id))
      state = %{state | current: to_id}

      state =
        broadcast(state, :session_turn_changed, payload: %{participant_id: to_id, via: :handoff})

      {:reply, {:ok, to_id}, checkpoint(state)}
    else
      {:reply, {:error, :not_a_participant}, state}
    end
  end

  # ----- pause / resume / close --------------------------------------------
  @impl true
  def handle_call(:pause, _from, %State{status: :running} = state) do
    state = broadcast(%{state | status: :paused}, :session_paused, payload: %{})
    {:reply, :ok, checkpoint(state)}
  end

  def handle_call(:pause, _from, state),
    do: {:reply, {:error, {:not_running, state.status}}, state}

  @impl true
  def handle_call(:resume, _from, %State{status: :paused} = state) do
    state = broadcast(%{state | status: :running}, :session_resumed, payload: %{})
    {:reply, :ok, checkpoint(state)}
  end

  def handle_call(:resume, _from, state),
    do: {:reply, {:error, {:not_paused, state.status}}, state}

  @impl true
  def handle_call(:close, _from, %State{status: status} = state) when status != :closed do
    state = broadcast(%{state | status: :closed}, :session_closed, payload: %{})
    {:reply, :ok, checkpoint(state)}
  end

  def handle_call(:close, _from, state), do: {:reply, :ok, state}

  # ----- introspection ------------------------------------------------------
  @impl true
  def handle_call(:read_state, _from, state), do: {:reply, state.shared_state, state}
  @impl true
  def handle_call(:current, _from, state), do: {:reply, state.current, state}

  @impl true
  def handle_call(:participants, _from, state),
    do: {:reply, state.participants |> Map.values(), state}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp context(%State{} = state) do
    %{shared_state: state.shared_state, participants: Map.values(state.participants)}
  end

  defp update_policy(%State{} = state, fun),
    do: %{state | policy_state: fun.(state.policy_state)}

  # A handoff sets the current actor directly. The built-in policies track a
  # `current` field; custom policies without one are left untouched (their
  # `can_act?/3` decides admission as usual).
  defp set_policy_current(policy_state, id) do
    if is_map(policy_state) and Map.has_key?(policy_state, :current) do
      Map.put(policy_state, :current, id)
    else
      policy_state
    end
  end

  defp advance(%State{} = state) do
    case TurnPolicy.next_participant(state.policy_state, context(state)) do
      {:ok, id, policy_state} ->
        {:ok, id, %{state | policy_state: policy_state, current: id}}

      {:done, policy_state} ->
        {:done, %{state | policy_state: policy_state, current: nil}}
    end
  end

  # The current participant left mid-turn: forfeit their turn and pick the next,
  # so the session does not deadlock. An empty roster ends the session.
  defp advance_after_leave(%State{} = state) do
    case advance(state) do
      {:ok, next, state} ->
        broadcast(state, :session_turn_changed, payload: %{participant_id: next, via: :leave})

      {:done, state} ->
        %{state | status: :done}
    end
  end

  # Apply a participant's change function to the shared state (single writer).
  defp apply_change(%State{} = state, change_fn) do
    case change_fn.(state.shared_state) do
      {:ok, new_state} -> commit_change(state, new_state)
      {:error, _} = e -> e
      # A bare value is treated as the new state (convenience).
      new_state -> commit_change(state, new_state)
    end
  end

  defp commit_change(%State{} = state, new_state) do
    state = %{state | shared_state: new_state}

    state =
      broadcast(state, :shared_state_updated, payload: %{participant_id: state.current})

    {:ok, checkpoint(state)}
  end

  # -------------------------------------------------------------------------
  # Persistence
  # -------------------------------------------------------------------------

  # Persist a snapshot of the coordination state, keyed by session_id. No-op
  # when no store is configured. Persistence failures are logged (not raised),
  # like Server.checkpoint does — a store problem must never break a turn.
  defp checkpoint(%State{store: nil} = state), do: state

  defp checkpoint(%State{store: {mod, config}} = state) do
    snapshot = ExAgent.Session.Snapshot.new(state)
    mod.save_session_snapshot(config, snapshot)
    state
  rescue
    e ->
      Logger.warning(
        "exagent session checkpoint failed for #{inspect(state.session_id)}: #{Exception.message(e)}"
      )

      state
  end

  # Rehydrate coordination state from the store at init. The app always supplies
  # the live participant refs via `:participants`; only the serializable parts
  # (shared_state, turn position, status, roster ids/kinds) are restored.
  defp load_session_state(nil, _id, defaults) do
    {defaults.shared_state, TurnPolicy.init(defaults.policy_mod, defaults.policy_opts),
     defaults.current, defaults.status, defaults.seq, %{}}
  end

  defp load_session_state({mod, config}, session_id, defaults) do
    case ExAgent.Store.load_session_snapshot({mod, config}, session_id) do
      {:ok, snap} ->
        # Restore turn position from the snapshot's policy_state (the policy
        # struct round-tripped with its index/current); fall back to a fresh
        # init if the module/struct changed incompatibly between runs.
        policy_state =
          case reconstruct_policy_state(snap) do
            nil -> TurnPolicy.init(defaults.policy_mod, defaults.policy_opts)
            other -> other
          end

        {snap.shared_state, policy_state, snap.current, snap.status, snap.seq,
         Map.new(snap.participants || [], &{&1.id, &1})}

      {:error, :not_found} ->
        {defaults.shared_state, TurnPolicy.init(defaults.policy_mod, defaults.policy_opts),
         defaults.current, defaults.status, defaults.seq, %{}}
    end
  rescue
    e ->
      Logger.warning(
        "exagent session rehydrate failed for #{inspect(session_id)} (starting fresh): #{Exception.message(e)}"
      )

      {defaults.shared_state, TurnPolicy.init(defaults.policy_mod, defaults.policy_opts),
       defaults.current, defaults.status, defaults.seq, %{}}
  end

  # The policy_state round-trips tagged with __struct__; reconstruct it, but only
  # if the module matches the one the app is starting with (avoids restoring an
  # incompatible policy from an older snapshot).
  defp reconstruct_policy_state(%ExAgent.Session.Snapshot{policy_state: nil}), do: nil

  defp reconstruct_policy_state(%ExAgent.Session.Snapshot{policy_mod: mod, policy_state: ps})
       when is_struct(ps) and is_atom(mod) do
    if ps.__struct__ == mod, do: ps, else: nil
  end

  defp reconstruct_policy_state(_), do: nil

  # Keep the app's live participants (with refs), filling kinds for any the app
  # didn't re-supply but were in the persisted roster.
  defp merge_participants(live, rehydrated) when rehydrated == %{}, do: live

  defp merge_participants(live, rehydrated) do
    Enum.reduce(rehydrated, live, fn {id, rehydrated_p}, acc ->
      case Map.get(acc, id) do
        nil ->
          # App didn't re-supply this one; keep the persisted id/kind without a ref.
          Map.put(acc, id, Participant.new(id: id, kind: rehydrated_p.kind))

        _live_p ->
          # App re-supplied the live ref; keep it.
          acc
      end
    end)
  end

  defp broadcast(%State{} = state, type, opts) do
    seq = state.seq + 1

    event =
      Event.new(
        type: type,
        seq: seq,
        source: :session,
        session_id: state.session_id,
        payload: Keyword.get(opts, :payload, %{}),
        metadata: Map.merge(state.metadata, Keyword.get(opts, :metadata, %{}))
      )

    case PubSub.broadcast(state.pubsub, state.topic, event) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("exagent session pubsub broadcast failed: #{inspect(reason)}")
    end

    %{state | seq: seq}
  end

  defp normalize_policy(:round_robin), do: {ExAgent.Session.TurnPolicy.RoundRobin, []}
  defp normalize_policy(:initiative), do: {ExAgent.Session.TurnPolicy.Initiative, []}

  defp normalize_policy({:initiative, opts}),
    do: {ExAgent.Session.TurnPolicy.Initiative, opts}

  defp normalize_policy(:supervisor), do: {ExAgent.Session.TurnPolicy.SupervisorPolicy, []}

  defp normalize_policy({:supervisor, opts}),
    do: {ExAgent.Session.TurnPolicy.SupervisorPolicy, opts}

  defp normalize_policy({mod, opts}) when is_atom(mod), do: {mod, opts}
  defp normalize_policy(mod) when is_atom(mod), do: {mod, []}

  defp generate_id(prefix),
    do: prefix <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
