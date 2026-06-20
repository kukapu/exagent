defmodule ExAgent.Server do
  @moduledoc """
  A supervised, stateful wrapper around `ExAgent.run/3`.

  `ExAgent.Server` keeps an agent alive across many runs: it preserves the
  conversation history, accumulates token usage, threads stateful models (like
  `ExAgent.Models.Test`) from one run to the next, and emits `ExAgent.Event`s
  over `ExAgent.PubSub` so UIs (LiveView, CLI, channels) can observe every run
  in real time.

  It does **not** coordinate multiple participants or own shared state — that is
  `ExAgent.Session`'s job (Roadmap Phase 3). It is purely a *conversation with
  state*: model + history + usage + events.

  ## Starting

      agent = ExAgent.new(model: "openai:gpt-4o", instructions: "Be a DM.")
      {:ok, pid} = ExAgent.AgentSupervisor.start_agent(agent: agent, name: :dm)

  or standalone:

      {:ok, pid} = ExAgent.Server.start_link(agent: agent, name: :dm)

  Options: `:agent` (required), `:agent_id`, `:name`, `:pubsub`
  (`nil`/`:none`/`:local`/`{module, config}`), `:max_pending` (default `8`),
  `:metadata`.

  ## Concurrency model

  Runs execute in a supervised task (`ExAgent.TaskSupervisor`), so the GenServer
  keeps answering `abort/1`, `health/1` and backpressure during long runs.

    * `chat/3`        — synchronous: blocks the caller until the run finishes.
    * `send_message/3` — asynchronous: returns `{:ok, request_id}` immediately;
      the result arrives as a `:run_finished`/`:run_failed` event.
    * `stream/3`      — asynchronous text streaming: deltas arrive as
      `:text_delta` events on the agent topic.
    * `steer/2`       — enqueue a high-priority follow-up for the *next* run.
      It does **not** mutate an HTTP request already in flight.
    * `abort/1`       — cancel the in-flight run and emit `:server_request_cancelled`.

  Backpressure: while a run is in flight, `chat/3` returns `{:error, :busy}`;
  `send_message/3`/`steer/2` enqueue up to `max_pending` requests and otherwise
  return `{:error, :queue_full}`.

  ## Events

  Published on `ExAgent.Event.agent_topic(agent_id)`
  (`"exagent:agent:<agent_id>"`). Subscribers receive
  `{:exagent_event, %ExAgent.Event{}}`. The `seq` field is monotonic per agent.
  """

  use GenServer

  alias ExAgent.{Event, PubSub, RunEvent}
  alias ExAgent.Message.Usage

  @default_max_pending 8

  defmodule State do
    @moduledoc false

    defstruct agent: nil,
              model: nil,
              history: [],
              usage: %Usage{input_tokens: 0, output_tokens: 0},
              status: :idle,
              current: nil,
              pending: :queue.new(),
              max_pending: 8,
              pubsub: {ExAgent.PubSub.None, []},
              store: nil,
              topic: nil,
              agent_id: nil,
              seq: 0,
              metadata: %{}

    @type status :: :idle | :running
    @type reply_to :: {:call, GenServer.from()} | {:event, String.t()} | nil
    @type current :: %{
            ref: reference(),
            pid: pid(),
            reply_to: reply_to(),
            request_id: String.t(),
            run_id: String.t(),
            prompt: String.t(),
            streaming?: boolean(),
            aborting: boolean()
          }
    @type pending_entry :: {String.t(), keyword(), reply_to(), String.t()}

    @type t :: %__MODULE__{
            agent: ExAgent.t(),
            model: ExAgent.Model.model(),
            history: [ExAgent.Message.t()],
            usage: Usage.t(),
            status: status(),
            current: current() | nil,
            pending: :queue.queue(),
            max_pending: pos_integer(),
            pubsub: {module(), term()},
            store: {module(), term()} | nil,
            topic: String.t() | nil,
            agent_id: String.t() | nil,
            seq: non_neg_integer(),
            metadata: map()
          }
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start a supervised, stateful agent.

  ## Options

    * `:agent`       — (required) an `ExAgent.t()` built with `ExAgent.new/1`.
    * `:agent_id`    — stable id for correlation/events; auto-generated if absent.
    * `:name`        — registered name for the GenServer.
    * `:pubsub`      — `nil`/`:none`/`:local`/`{module, config}` (default `nil`).
    * `:store`       — `nil`/`:ets`/`{module, config}` (default `nil`, no
                      persistence). When set, history/usage are checkpointed
                      after every run and rehydrated on restart.
    * `:max_pending` — max queued async requests before `:queue_full` (default 8).
    * `:metadata`    — free-form map attached to every emitted event.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  def child_spec(opts) do
    agent_id = Keyword.get(opts, :agent_id)
    name = Keyword.get(opts, :name)

    %{
      id: {:exagent_server, agent_id || name || make_ref()},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @doc """
  Run one prompt synchronously and return `{:ok, result}` (the `ExAgent.run/3`
  result map) or `{:error, reason}`. Refuses to start if a run is already in
  flight, returning `{:error, :busy}`.

  The GenServer call uses `:infinity` timeout by default (LLM runs can be long);
  pass `timeout: ms` in `opts` to override. Run options (`:deps`,
  `:model_settings`, …) are forwarded to `ExAgent.run/3`.
  """
  @spec chat(GenServer.server(), String.t(), keyword()) ::
          {:ok, ExAgent.result()} | {:error, term()}
  def chat(server, prompt, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    GenServer.call(server, {:chat, prompt, opts}, timeout)
  end

  @doc """
  Run one prompt asynchronously. Returns `{:ok, request_id}` immediately; the
  result is delivered as a `:run_finished`/`:run_failed` event on the agent
  topic. Returns `{:error, :queue_full}` if the pending queue is full.

  Run options are forwarded to `ExAgent.run/3`.
  """
  @spec send_message(GenServer.server(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :queue_full}
  def send_message(server, prompt, opts \\ []) do
    GenServer.call(server, {:send_message, prompt, opts})
  end

  @doc """
  Stream a prompt's text deltas. Returns `{:ok, request_id}` immediately; deltas
  arrive as `:text_delta` events and the final result as a `:run_finished` event
  on the agent topic. Returns `{:error, :busy}` if a run is in flight.

  Phase 1 scope: this surfaces text deltas via the existing streaming core. It
  does not run a full agentic tool loop (use `chat/3`/`send_message/3` for that).
  """
  @spec stream(GenServer.server(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :busy}
  def stream(server, prompt, opts \\ []) do
    GenServer.call(server, {:stream, prompt, opts})
  end

  @doc """
  Enqueue a high-priority follow-up for the *next* run. It is placed at the front
  of the pending queue (or started immediately if idle). It does **not** modify
  an HTTP request already in flight. Returns `{:ok, request_id}`.
  """
  @spec steer(GenServer.server(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :queue_full}
  def steer(server, prompt, opts \\ []) do
    GenServer.call(server, {:steer, prompt, opts})
  end

  @doc "Cancel the in-flight run, if any. Returns `:ok`. Idempotent."
  @spec abort(GenServer.server()) :: :ok
  def abort(server) do
    GenServer.call(server, :abort)
  end

  @doc "Replace the model of an idle agent. Returns `:ok` or `{:error, :busy | reason}`."
  @spec set_model(GenServer.server(), ExAgent.Model.model() | String.t()) ::
          :ok | {:error, :busy | term()}
  def set_model(server, model_spec) do
    GenServer.call(server, {:set_model, model_spec})
  end

  @doc "The current conversation history (messages threaded across runs)."
  @spec history(GenServer.server()) :: [ExAgent.Message.t()]
  def history(server) do
    GenServer.call(server, :history)
  end

  @doc """
  Clear the conversation history and accumulated usage — start a fresh
  conversation on the same supervised agent. Only allowed when idle; returns
  `{:error, :busy}` if a run is in flight. When a store is configured, the
  cleared (empty) state is checkpointed.
  """
  @spec reset(GenServer.server()) :: :ok | {:error, :busy}
  def reset(server) do
    GenServer.call(server, :reset)
  end

  @doc "Accumulated token usage across all runs so far."
  @spec usage(GenServer.server()) :: Usage.t()
  def usage(server) do
    GenServer.call(server, :usage)
  end

  @doc "Runtime health: `status` and pending queue depth."
  @spec health(GenServer.server()) :: %{status: atom(), pending: non_neg_integer()}
  def health(server) do
    GenServer.call(server, :health)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks — init & calls
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    agent = Keyword.fetch!(opts, :agent)

    agent_id = Keyword.get(opts, :agent_id) || generate_id("agent_")
    store = ExAgent.Store.normalize(Keyword.get(opts, :store))

    # Rehydrate conversational state from the store (if any). The live agent
    # template (model, tools, instructions) comes from `opts`; only history and
    # usage are restored — never pids, secrets or closures.
    {history, usage} = load_state(store, agent_id)

    state = %State{
      agent: agent,
      model: agent.model,
      history: history,
      usage: usage,
      agent_id: agent_id,
      topic: Event.agent_topic(agent_id),
      pubsub: PubSub.normalize(Keyword.get(opts, :pubsub)),
      store: store,
      max_pending: Keyword.get(opts, :max_pending, @default_max_pending),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    {:ok, state}
  end

  # ----- chat (synchronous) -------------------------------------------------
  @impl true
  def handle_call({:chat, _prompt, _opts}, _from, %State{status: :running} = state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:chat, prompt, opts}, from, %State{status: :idle} = state) do
    {state, _request_id} = start_run(state, prompt, opts, {:call, from})
    {:noreply, state}
  end

  # ----- send_message (asynchronous) ----------------------------------------
  @impl true
  def handle_call({:send_message, prompt, opts}, _from, %State{status: :idle} = state) do
    request_id = request_id(opts)

    {state, ^request_id} =
      start_run(state, prompt, put_request_id(opts, request_id), {:event, request_id})

    {:reply, {:ok, request_id}, state}
  end

  def handle_call({:send_message, prompt, opts}, _from, %State{status: :running} = state) do
    enqueue_or_full(state, prompt, opts, :rear)
  end

  # ----- steer (high-priority follow-up) ------------------------------------
  @impl true
  def handle_call({:steer, prompt, opts}, _from, %State{status: :idle} = state) do
    request_id = request_id(opts)

    {state, ^request_id} =
      start_run(state, prompt, put_request_id(opts, request_id), {:event, request_id})

    {:reply, {:ok, request_id}, state}
  end

  def handle_call({:steer, prompt, opts}, _from, %State{status: :running} = state) do
    enqueue_or_full(state, prompt, opts, :front)
  end

  # ----- stream (asynchronous text deltas) ----------------------------------
  @impl true
  def handle_call({:stream, _prompt, _opts}, _from, %State{status: :running} = state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:stream, prompt, opts}, _from, %State{status: :idle} = state) do
    request_id = request_id(opts)
    run_id = generate_id("run_")

    parent = self()
    agent = %{state.agent | model: state.model}
    run_opts = build_run_opts(state, run_id)

    task =
      Task.Supervisor.async_nolink(ExAgent.TaskSupervisor, fn ->
        ExAgent.run_stream(agent, prompt, run_opts)
        |> Stream.each(fn
          {:delta, text} ->
            send(parent, {:stream_delta, run_id, request_id, text})

          {:result, %{output: output, usage: usage, messages: messages}} ->
            send(
              parent,
              {:stream_done, run_id, request_id,
               %{output: output, usage: usage, messages: messages}}
            )

          {:error, reason} ->
            send(parent, {:stream_failed, run_id, request_id, reason})
        end)
        |> Stream.run()
      end)

    state = set_current(state, task, request_id, run_id, prompt, {:event, request_id}, true)
    {:reply, {:ok, request_id}, state}
  end

  # ----- control / introspection --------------------------------------------
  @impl true
  def handle_call(:abort, _from, %State{current: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:abort, _from, %State{current: cur} = state) do
    :ok = Task.Supervisor.terminate_child(ExAgent.TaskSupervisor, cur.pid)
    {:reply, :ok, %{state | current: %{cur | aborting: true}}}
  end

  @impl true
  def handle_call({:set_model, _}, _from, %State{status: :running} = state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:set_model, spec}, _from, %State{status: :idle} = state) do
    case resolve_model(spec) do
      {:ok, model} ->
        {:reply, :ok, %{state | model: model, agent: %{state.agent | model: model}}}

      {:error, _} = e ->
        {:reply, e, state}
    end
  end

  @impl true
  def handle_call(:history, _from, state), do: {:reply, state.history, state}

  @impl true
  def handle_call(:reset, _from, %State{status: :running} = state),
    do: {:reply, {:error, :busy}, state}

  def handle_call(:reset, _from, %State{} = state) do
    state = %{state | history: [], usage: %Usage{input_tokens: 0, output_tokens: 0}}
    {:reply, :ok, checkpoint(state)}
  end

  @impl true
  def handle_call(:usage, _from, state), do: {:reply, state.usage, state}

  @impl true
  def handle_call(:health, _from, state) do
    {:reply, %{status: state.status, pending: :queue.len(state.pending)}, state}
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks — info (task lifecycle & events)
  # ---------------------------------------------------------------------------

  # Non-streaming run completed normally.
  @impl true
  def handle_info({ref, result}, %State{current: %{ref: ref, streaming?: false} = cur} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | current: nil}

    state =
      case result do
        {:ok, res} ->
          reply(cur.reply_to, {:ok, res})
          state |> integrate_result(res) |> checkpoint()

        {:error, reason} ->
          reply(cur.reply_to, {:error, reason})
          state
      end

    {:noreply, drain(state)}
  end

  # Streaming task finished consuming its stream (returns :ok).
  @impl true
  def handle_info({ref, :ok}, %State{current: %{ref: ref, streaming?: true}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, drain(%{state | current: nil})}
  end

  # Streaming text deltas.
  @impl true
  def handle_info({:stream_delta, run_id, request_id, text}, %State{} = state) do
    state =
      broadcast(state, :text_delta,
        source: :run,
        run_id: run_id,
        request_id: request_id,
        payload: %{text: text}
      )

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:stream_done, run_id, request_id, %{output: output, usage: usage, messages: messages}},
        %State{} = state
      ) do
    state = state |> integrate(messages, usage) |> checkpoint()

    state =
      emit_terminal(state, :run_finished, run_id, request_id, %{
        output_text: text_preview(output),
        usage: usage_map(usage)
      })

    {:noreply, state}
  end

  @impl true
  def handle_info({:stream_failed, run_id, request_id, reason}, %State{} = state) do
    state = emit_terminal(state, :run_failed, run_id, request_id, %{reason: inspect(reason)})
    {:noreply, state}
  end

  # Task died (crash or aborted) — no {ref, result} will arrive.
  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %State{current: %{ref: ref} = cur} = state
      ) do
    Process.demonitor(ref, [:flush])
    state = %{state | current: nil}

    state =
      cond do
        cur.aborting ->
          state =
            broadcast(state, :server_request_cancelled,
              source: :server,
              run_id: cur.run_id,
              request_id: cur.request_id,
              payload: %{}
            )

          reply(cur.reply_to, {:error, :aborted})
          state

        reason == :normal ->
          # Already handled via {ref, result}.
          state

        true ->
          state =
            emit_terminal(state, :run_failed, cur.run_id, cur.request_id, %{
              reason: inspect({:crashed, reason})
            })

          reply(cur.reply_to, {:error, {:crashed, reason}})
          state
      end

    {:noreply, drain(state)}
  end

  # Loop events → envelope → pubsub.
  @impl true
  def handle_info({:run_event, %RunEvent{} = re}, %State{current: cur} = state)
      when is_map(cur) do
    # Drop events from a run that is no longer current (e.g. after an abort) to
    # avoid post-cancellation noise.
    if re.run_id && cur.run_id && re.run_id != cur.run_id do
      {:noreply, state}
    else
      state =
        broadcast(state, re.type,
          source: :run,
          run_id: cur.run_id,
          request_id: cur.request_id,
          payload: build_payload(re)
        )

      {:noreply, state}
    end
  end

  def handle_info({:run_event, _}, state), do: {:noreply, state}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Internal: starting / draining runs
  # ---------------------------------------------------------------------------

  defp start_run(state, prompt, opts, reply_to) do
    request_id = request_id(opts)
    run_id = generate_id("run_")

    agent = %{state.agent | model: state.model}

    run_opts =
      build_run_opts(state, run_id)
      |> Keyword.merge(Keyword.take(opts, [:deps, :model_settings]))

    task =
      Task.Supervisor.async_nolink(ExAgent.TaskSupervisor, fn ->
        ExAgent.run(agent, prompt, run_opts)
      end)

    {set_current(state, task, request_id, run_id, prompt, reply_to, false), request_id}
  end

  defp set_current(
         state,
         %Task{ref: ref, pid: pid},
         request_id,
         run_id,
         prompt,
         reply_to,
         streaming?
       ) do
    current = %{
      ref: ref,
      pid: pid,
      reply_to: reply_to,
      request_id: request_id,
      run_id: run_id,
      prompt: prompt,
      streaming?: streaming?,
      aborting: false
    }

    %{state | status: :running, current: current}
  end

  # Build the keyword options handed to ExAgent.run/3 / run_stream from state.
  defp build_run_opts(state, run_id) do
    parent = self()

    [
      message_history: state.history,
      prepend_instructions: state.history == [],
      run_id: run_id,
      on_event: fn re -> send(parent, {:run_event, re}) end
    ]
  end

  # Pull the next pending request off the queue (if any) and start it.
  defp drain(%State{pending: pending} = state) do
    case :queue.out(pending) do
      {:empty, _} ->
        %{state | status: :idle, current: nil}

      {{:value, {prompt, opts, reply_to, _req_id}}, rest} ->
        {state, _} = start_run(%{state | pending: rest}, prompt, opts, reply_to)
        state
    end
  end

  defp enqueue_or_full(state, prompt, opts, position) do
    request_id = request_id(opts)

    if :queue.len(state.pending) >= state.max_pending do
      {:reply, {:error, :queue_full}, state}
    else
      entry = {prompt, put_request_id(opts, request_id), {:event, request_id}, request_id}

      pending =
        case position do
          :front -> :queue.in_r(entry, state.pending)
          :rear -> :queue.in(entry, state.pending)
        end

      {:reply, {:ok, request_id}, %{state | pending: pending}}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal: events
  # ---------------------------------------------------------------------------

  # Map a loop RunEvent to a JSON-safe envelope payload.
  defp build_payload(%RunEvent{type: :run_started, data: d}),
    do: %{prompt: Map.get(d, :prompt)}

  defp build_payload(%RunEvent{type: :run_finished, data: d}) do
    %{
      output_kind: Map.get(d, :output_kind, :text),
      output_text: text_preview(Map.get(d, :output)),
      usage: usage_map(Map.get(d, :usage)),
      steps: Map.get(d, :steps)
    }
  end

  defp build_payload(%RunEvent{type: :run_failed, data: d}),
    do: %{reason: inspect(Map.get(d, :reason))}

  defp build_payload(%RunEvent{type: :run_step_started, step: s}),
    do: %{step: s}

  defp build_payload(%RunEvent{type: :tool_call_started, step: s, data: d}) do
    %{step: s, tool_name: d.tool_name, tool_call_id: d.tool_call_id, args: jsonable(d.args)}
  end

  defp build_payload(%RunEvent{type: :tool_call_finished, step: s, data: d}) do
    %{
      step: s,
      tool_name: d.tool_name,
      tool_call_id: d.tool_call_id,
      success: Map.get(d, :success, true),
      duration_ms: Map.get(d, :duration_ms)
    }
  end

  defp build_payload(_), do: %{}

  defp emit_terminal(state, type, run_id, request_id, payload) do
    broadcast(state, type, source: :run, run_id: run_id, request_id: request_id, payload: payload)
  end

  defp broadcast(%State{} = state, type, opts) do
    seq = state.seq + 1

    event =
      Event.new(
        type: type,
        seq: seq,
        source: Keyword.get(opts, :source),
        agent_id: state.agent_id,
        run_id: Keyword.get(opts, :run_id),
        request_id: Keyword.get(opts, :request_id),
        payload: Keyword.get(opts, :payload, %{}),
        metadata: Map.merge(state.metadata, Keyword.get(opts, :metadata, %{}))
      )

    :ok = PubSub.broadcast(state.pubsub, state.topic, event)
    %{state | seq: seq}
  end

  # ---------------------------------------------------------------------------
  # Internal: state integration & helpers
  # ---------------------------------------------------------------------------

  defp integrate_result(%State{} = state, %{messages: messages, usage: usage, model: model}) do
    %{integrate(state, messages, usage) | model: model}
  end

  defp integrate(%State{} = state, messages, usage) do
    %{state | history: messages, usage: merge_usage(state.usage, usage)}
  end

  # Persist a snapshot of the current conversational state (history + usage),
  # keyed by agent_id. No-op when no store is configured. Persistence failures
  # are swallowed: a store problem must never break a run.
  defp checkpoint(%State{store: nil} = state), do: state

  defp checkpoint(%State{store: {mod, config}, agent_id: agent_id} = state) do
    snapshot =
      ExAgent.Server.Snapshot.new(
        agent_id: agent_id,
        history: state.history,
        usage: state.usage,
        metadata: state.metadata
      )

    mod.save_agent_snapshot(config, snapshot)
    state
  rescue
    _ -> state
  end

  # Rehydrate history + usage from the store at init. The live agent template
  # (model/tools/instructions) always comes from `opts`; only conversational
  # state is restored.
  defp load_state(nil, _agent_id) do
    {[], %Usage{input_tokens: 0, output_tokens: 0}}
  end

  defp load_state({mod, config}, agent_id) do
    case ExAgent.Store.load_agent_snapshot({mod, config}, agent_id) do
      {:ok, snap} ->
        history =
          case ExAgent.Server.Snapshot.messages(snap) do
            {:ok, messages} when is_list(messages) -> messages
            _ -> []
          end

        {history, ExAgent.Server.Snapshot.usage_struct(snap)}

      {:error, :not_found} ->
        {[], %Usage{input_tokens: 0, output_tokens: 0}}
    end
  rescue
    _ -> {[], %Usage{input_tokens: 0, output_tokens: 0}}
  end

  defp merge_usage(%Usage{} = acc, nil), do: acc

  defp merge_usage(%Usage{} = acc, %Usage{} = run) do
    %Usage{
      input_tokens: acc.input_tokens + (run.input_tokens || 0),
      output_tokens: acc.output_tokens + (run.output_tokens || 0)
    }
  end

  defp reply({:call, from}, result), do: GenServer.reply(from, result)
  defp reply({:event, _request_id}, _result), do: :ok
  defp reply(nil, _result), do: :ok

  defp text_preview(output) when is_binary(output), do: output
  defp text_preview(_), do: nil

  defp usage_map(%Usage{input_tokens: i, output_tokens: o}),
    do: %{input_tokens: i, output_tokens: o}

  defp usage_map(_), do: nil

  defp jsonable(args) when is_map(args) or is_binary(args), do: args
  defp jsonable(nil), do: nil
  defp jsonable(other), do: inspect(other)

  defp request_id(opts), do: Keyword.get(opts, :request_id) || generate_id("req_")
  defp put_request_id(opts, id), do: Keyword.put(opts, :request_id, id)

  defp resolve_model(%_{} = m), do: {:ok, m}
  defp resolve_model(spec), do: ExAgent.Model.resolve(spec)

  defp generate_id(prefix) do
    prefix <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
