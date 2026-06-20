defmodule ExAgent do
  @moduledoc """
  An agent: model + instructions + tools + output spec, runnable as a loop that
  alternates between **calling the model** and **executing tools** until a final
  result is produced.

  This is the heart of the framework. It follows a small loop:

      UserPromptNode → ModelRequestNode ⇄ CallToolsNode → End

  It is implemented as idiomatic Elixir recursion. Each recursive step issues a
  model request or handles returned tool calls; termination happens when the
  model returns a valid final response (no tool calls) or an empty response with
  `allow_text_output`.

  ## Quick start

      alias ExAgent

      agent =
        ExAgent.new(
          model: "test",
          instructions: "Be concise."
        )

      {:ok, %{output: text}} = ExAgent.run(agent, "Hello!")
  """

  alias ExAgent.{Model, ModelSettings, ModelRequestParameters, RunContext, Tool, UsageLimits}
  alias ExAgent.Message.{Part, Request, Response, Usage}

  defstruct model: nil,
            instructions: [],
            output_type: :text,
            tools: [],
            settings: %ModelSettings{},
            output_retries: 1,
            tool_timeout: 30_000,
            usage_limits: nil,
            capabilities: [],
            name: nil

  @type output_type :: :text | module()
  @type t :: %__MODULE__{
          model: Model.model(),
          instructions: [Part.System.t()],
          output_type: output_type(),
          tools: [Tool.t()],
          settings: ModelSettings.t(),
          output_retries: non_neg_integer(),
          tool_timeout: pos_integer(),
          usage_limits: ExAgent.UsageLimits.t() | nil,
          capabilities: [module() | struct()],
          name: String.t() | nil
        }

  @type result :: %{
          output: term(),
          messages: [ExAgent.Message.t()],
          new_messages: [ExAgent.Message.t()],
          usage: Usage.t(),
          run_step: non_neg_integer(),
          model: Model.model()
        }

  @output_tool_name "final_result"

  # -------------------------------------------------------------------------
  # Construction
  # -------------------------------------------------------------------------
  @doc "Build an agent from options. Use `:output` for the output spec."
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    model =
      case Keyword.fetch!(opts, :model) do
        %_{} = m -> m
        spec -> resolve_model!(spec)
      end

    %__MODULE__{
      model: model,
      instructions: to_instructions(Keyword.get(opts, :instructions)),
      output_type: Keyword.get(opts, :output, Keyword.get(opts, :output_type, :text)),
      tools: Keyword.get(opts, :tools, []),
      settings: ModelSettings.new(Keyword.get(opts, :model_settings, [])),
      output_retries: Keyword.get(opts, :output_retries, 1),
      tool_timeout: Keyword.get(opts, :tool_timeout, 30_000),
      usage_limits: Keyword.get(opts, :usage_limits),
      capabilities: Keyword.get(opts, :capabilities, []),
      name: Keyword.get(opts, :name)
    }
  end

  defp resolve_model!(spec) do
    case Model.resolve(spec) do
      {:ok, model} -> model
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  defp to_instructions(nil), do: []

  defp to_instructions(instructions) when is_binary(instructions),
    do: [%Part.System{content: instructions}]

  defp to_instructions(list) when is_list(list),
    do: Enum.map(list, &%Part.System{content: &1})

  # When output is an Ecto schema module, the model is forced to call an output
  # tool whose args are the schema; we validate those args (retry on failure).
  # For `:text` there's no output tool and free-text responses are allowed.
  defp output_config(%__MODULE__{output_type: :text}), do: {:text, [], true}

  defp output_config(%__MODULE__{output_type: mod}) when is_atom(mod) do
    tool = %Tool{
      name: @output_tool_name,
      description: "Return the final answer as structured data.",
      parameters_json_schema: ExAgent.OutputSchema.json_schema(mod),
      kind: :output,
      takes_ctx: false,
      call: nil
    }

    {:tool, [tool], false}
  end

  # -------------------------------------------------------------------------
  # Running
  # -------------------------------------------------------------------------
  @doc """
  Run the agent against `prompt`, returning `{:ok, result}` or `{:error, _}`.

  Options:
    * `:deps`              — dependency value threaded into `RunContext`.
    * `:message_history`   — prior `Message.t()` list to continue from.
    * `:model_settings`    — per-run settings overrides.
  """
  @spec run(t(), String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(agent, prompt, opts \\ []) do
    start = System.monotonic_time()

    ExAgent.Telemetry.execute([:run, :start], %{system_time: start}, %{
      agent: agent.name,
      prompt: prompt
    })

    state = init_state(agent, prompt, opts)

    emit(state, :run_started, %{prompt: prompt})
    result = drive(state)
    duration = System.monotonic_time() - start

    case result do
      {:ok, %{usage: usage, run_step: steps} = res} ->
        emit(state, :run_finished, %{
          output: res.output,
          usage: usage,
          steps: steps
        })

        ExAgent.Telemetry.execute([:run, :stop], %{duration: duration}, %{
          agent: agent.name,
          usage: usage,
          steps: steps
        })

      {:error, reason} ->
        emit(state, :run_failed, %{reason: reason})

        ExAgent.Telemetry.execute([:run, :exception], %{duration: duration}, %{
          agent: agent.name,
          reason: reason
        })
    end

    result
  end

  @doc "Run synchronously and return the output value directly, raising on error."
  @spec run!(t(), String.t(), keyword()) :: term()
  def run!(agent, prompt, opts \\ []) do
    case run(agent, prompt, opts) do
      {:ok, %{output: out}} -> out
      {:error, reason} -> raise ExAgent.UnexpectedModelBehavior, inspect(reason)
    end
  end

  @doc ~S"""
  Run the agent, returning a **lazy stream** of events as the model generates.

  This is the streaming variant. It yields:

    * `{:delta, binary}` — incremental output text (one per model text chunk),
    * `{:result, map}` — the final result once the stream completes.

  It is text-focused: best suited to chat / response-streaming UIs. Tool calls
  emitted mid-stream are not re-executed in this path (use `run/3` for full
  agentic tool loops). The same per-run options as `run/3` apply.
  """
  @spec run_stream(t(), String.t(), keyword()) :: Enumerable.t()
  def run_stream(agent, prompt, opts \\ []) do
    state = init_state(agent, prompt, opts)
    stream = Model.request_stream(state.model, state.messages, state.settings, state.params)

    Stream.transform(stream, %{run: state, text: <<>>}, fn
      {:text_delta, chunk}, acc ->
        {[{:delta, chunk}], %{acc | text: acc.text <> chunk}}

      {:response, %Response{} = resp}, acc ->
        {[stream_result(acc, resp)], acc}

      {:error, reason}, acc ->
        {[{:error, reason}, {:result, %{error: reason}}], acc}
    end)
  end

  defp stream_result(acc, %Response{} = resp) do
    text = acc.text
    output = if text == "", do: Response.text(resp), else: text
    messages = acc.run.messages ++ [resp]
    usage = merge_usage(acc.run.usage, resp.usage)

    {:result, %{output: output, messages: messages, usage: usage}}
  end

  # ----- per-run state -----------------------------------------------------
  defmodule Run do
    @moduledoc false
    defstruct agent: nil,
              model: nil,
              messages: [],
              # index into `messages` where this run's new messages begin
              first_new_message_index: 0,
              usage: %ExAgent.Message.Usage{input_tokens: 0, output_tokens: 0},
              deps: nil,
              settings: nil,
              params: nil,
              prompt: nil,
              output_retries_used: 0,
              # per-tool-name failure counters (drives the per-tool retry budget)
              tool_retries: %{},
              tool_timeout: 30_000,
              usage_limits: nil,
              capabilities: [],
              # transient override of messages sent to the model (set by capabilities)
              request_messages: nil,
              run_step: 0,
              max_steps: 50,
              # optional event sink: (ExAgent.RunEvent.t() -> any()). No-op by
              # default so one-shot callers that don't pass :on_event pay nothing.
              on_event: nil,
              run_id: nil
  end

  defp init_state(agent, prompt, opts) do
    history = Keyword.get(opts, :message_history, [])

    settings =
      ModelSettings.merge(
        agent.settings,
        ModelSettings.new(Keyword.get(opts, :model_settings, []))
      )

    {output_mode, output_tools, allow_text} = output_config(agent)

    params = %ModelRequestParameters{
      function_tools: agent.tools,
      output_tools: output_tools,
      output_mode: output_mode,
      allow_text_output: allow_text,
      instructions: agent.instructions
    }

    # On the first turn of a conversation we prepend the agent's system
    # instructions into the canonical history (so they survive serialization and
    # are seen by every subsequent run). When *continuing* an existing
    # conversation (non-empty history that already carries the instructions),
    # we only append the new user prompt — no duplicated system messages.
    prepend_instructions? = history == [] and Keyword.get(opts, :prepend_instructions, true)

    user = %Part.User{content: prompt, timestamp: DateTime.utc_now()}

    first_parts = if prepend_instructions?, do: agent.instructions ++ [user], else: [user]

    first_request = %Request{
      parts: first_parts,
      timestamp: DateTime.utc_now()
    }

    %Run{
      agent: agent,
      model: agent.model,
      messages: history ++ [first_request],
      first_new_message_index: length(history),
      deps: Keyword.get(opts, :deps),
      settings: settings,
      params: params,
      prompt: prompt,
      tool_timeout: agent.tool_timeout,
      usage_limits: agent.usage_limits,
      capabilities: agent.capabilities,
      on_event: Keyword.get(opts, :on_event),
      run_id: Keyword.get(opts, :run_id)
    }
  end

  # ----- the loop ----------------------------------------------------------
  # Emit a loop event to the optional :on_event sink. No-op when unset, so the
  # pure one-shot path is unaffected. `state` is read for run_id/step context.
  defp emit(%Run{on_event: nil}, _type, _data), do: :ok

  defp emit(%Run{on_event: fun} = state, type, data) when is_function(fun, 1) do
    event = ExAgent.RunEvent.new(type, run_id: state.run_id, step: state.run_step, data: data)
    fun.(event)
  rescue
    # A misbehaving event sink must never break a run.
    _ -> :ok
  end

  defp drive(%Run{run_step: step, max_steps: max} = _state) when step >= max,
    do: {:error, {:max_steps_exceeded, max}}

  defp drive(%Run{} = state) do
    %Run{model: model, settings: settings, params: params, capabilities: caps} = state

    case check_usage_limits(state) do
      :ok ->
        state = %{state | run_step: state.run_step + 1}
        emit(state, :run_step_started, %{step: state.run_step})
        # capabilities may set a transient request_messages override
        state = ExAgent.Capabilities.before_model_request(caps, state)
        request_messages = state.request_messages || state.messages

        case Model.request(model, request_messages, settings, params) do
          {:ok, %Response{} = response, model} ->
            state = %{state | model: model, request_messages: nil}
            state = %{state | messages: append(state.messages, response)}
            state = %{state | usage: merge_usage(state.usage, response.usage)}
            state = ExAgent.Capabilities.after_model_request(caps, state)
            handle_response(response, state)

          {:error, reason} ->
            {:error, {:model_request_failed, reason}}
        end

      {:error, _} = e ->
        e
    end
  end

  defp check_usage_limits(%Run{usage_limits: nil}), do: :ok

  defp check_usage_limits(%Run{usage_limits: limits, usage: usage, run_step: step}),
    do: UsageLimits.check_before_request(limits, usage, step)

  # call_tools_node: decide what to do with the model's response.
  defp handle_response(%Response{} = response, %Run{} = state) do
    tool_calls = Response.tool_calls(response)
    text = Response.text(response)

    cond do
      tool_calls != [] ->
        handle_tool_calls(tool_calls, state)

      response.finish_reason == :length ->
        {:error, {:max_tokens_exceeded, response.model_name}}

      response.finish_reason == :content_filter ->
        {:error, {:content_filter, response.model_name}}

      state.params.allow_text_output and text != "" ->
        finalize_text(text, state)

      true ->
        retry_or_fail(state, actionable_hint(state))
    end
  end

  defp actionable_hint(%Run{params: %{output_tools: [_ | _]}}),
    do: "Please call the #{@output_tool_name} tool to return your answer."

  defp actionable_hint(%Run{}), do: "Please respond."

  # ----- tools -------------------------------------------------------------
  defp handle_tool_calls(tool_calls, %Run{} = state) do
    output_names = MapSet.new(state.params.output_tools, & &1.name)

    case Enum.split_with(tool_calls, &MapSet.member?(output_names, &1.tool_name)) do
      {[output_call | _], siblings} ->
        handle_output_call(output_call, siblings, state)

      {[], fn_calls} ->
        case execute_function_tools(fn_calls, state) do
          {:ok, parts, new_retries} ->
            state = %{
              state
              | tool_retries: new_retries,
                messages:
                  append(state.messages, %Request{parts: parts, timestamp: DateTime.utc_now()})
            }

            drive(state)

          {:error, _} = e ->
            e
        end
    end
  end

  # The model returned the structured output: validate it, then finalize. A
  # `ToolReturn` is appended for the output call (plus stubs for any sibling
  # function calls) so the message history stays replayable on the next turn.
  defp handle_output_call(
         %Part.ToolCall{tool_call_id: id} = call,
         siblings,
         %Run{agent: %{output_type: mod}} = state
       )
       when is_atom(mod) and mod != :text do
    with {:ok, args} <- decode_args(call),
         {:ok, data} <- ExAgent.OutputSchema.validate(mod, args) do
      parts = [
        %Part.ToolReturn{tool_name: @output_tool_name, content: "ok", tool_call_id: id}
        | Enum.map(siblings, &stub_return/1)
      ]

      state = %{
        state
        | messages: append(state.messages, %Request{parts: parts, timestamp: DateTime.utc_now()})
      }

      {:ok, result(data, state)}
    else
      {:error, errors} -> retry_or_fail(state, errors, call, Enum.map(siblings, &stub_return/1))
    end
  end

  defp stub_return(%Part.ToolCall{tool_name: name, tool_call_id: id}),
    do: %Part.ToolReturn{
      tool_name: name,
      content: "Tool not executed - a final result was already processed.",
      tool_call_id: id || name
    }

  # Execute a batch of function tools **in parallel** via Task.async_stream
  # (ordered, with per-tool timeout + kill). The actual tool bodies run
  # concurrently (big latency win for I/O tools); the per-tool retry budget is
  # applied sequentially afterwards (pure, cheap). Returns
  # {:ok, parts, retries} or {:error, reason} (terminates the run when a tool
  # blows its budget).
  defp execute_function_tools(calls, %Run{} = state) do
    base_ctx = build_context(state)
    base_retries = state.tool_retries

    results =
      Task.async_stream(
        calls,
        fn call -> run_tool_raw(call, base_ctx, state) end,
        ordered: true,
        timeout: state.tool_timeout,
        on_timeout: :kill_task
      )
      |> Enum.zip(calls)

    Enum.reduce_while(results, {:ok, [], base_retries}, fn
      # Success: a tool that succeeds resets its consecutive-failure counter.
      {{:ok, {:ok, part}}, _call}, {:ok, parts, retries} ->
        {:cont, {:ok, parts ++ [part], Map.delete(retries, part.tool_name)}}

      {{:ok, {:error, reason}}, call}, {:ok, parts, retries} ->
        apply_failure(call, reason, retries, parts, state)

      # Any task death (timeout OR a raise/exit inside the task) is a failure.
      {{:exit, reason}, call}, {:ok, parts, retries} ->
        apply_failure(call, {:exit, reason}, retries, parts, state)
    end)
  end

  defp apply_failure(call, reason, retries, parts, state) do
    case decide_retry(call, reason, retries, state) do
      {:ok, part, new_retries} -> {:cont, {:ok, parts ++ [part], new_retries}}
      {:error, _} = e -> {:halt, e}
    end
  end

  # Run a single tool's body to completion (or raise). Used inside a Task.
  defp run_tool_raw(%Part.ToolCall{tool_name: name} = call, ctx, state) do
    start = System.monotonic_time()
    caps = state.capabilities
    call = ExAgent.Capabilities.before_tool_execute(caps, ctx, call)
    tool = find_tool(state, name)

    # Enrich ctx once so it carries tool_name/retry/max_retries into both the
    # tool body AND after_tool_execute (which otherwise gets the base ctx).
    ctx =
      put_tool_info(
        ctx,
        name,
        call.tool_call_id,
        Map.get(state.tool_retries, name, 0),
        max_retries(tool)
      )

    emit(state, :tool_call_started, %{
      tool_name: name,
      tool_call_id: call.tool_call_id,
      args: call.args
    })

    res =
      case tool do
        nil ->
          {:error, "Unknown tool #{inspect(name)}"}

        tool ->
          with {:ok, args} <- decode_args(call),
               {:ok, value} <- invoke(tool, ctx, args) do
            {:ok,
             %Part.ToolReturn{
               tool_name: tool.name,
               content: value,
               tool_call_id: call.tool_call_id
             }}
          end
      end

    res = ExAgent.Capabilities.after_tool_execute(caps, ctx, call, res)

    duration_ms = System.monotonic_time() - start

    emit(state, :tool_call_finished, %{
      tool_name: name,
      tool_call_id: call.tool_call_id,
      success: match?({:ok, _}, res),
      duration_ms: duration_ms
    })

    ExAgent.Telemetry.execute(
      [:tool, :stop],
      %{duration: duration_ms},
      %{tool_name: name, agent: state.agent.name, success: match?({:ok, _}, res)}
    )

    res
  end

  # Apply the per-tool retry budget to a failure (raw reason or :timeout).
  defp decide_retry(%Part.ToolCall{tool_name: name, tool_call_id: id}, reason, retries, state) do
    tool = find_tool(state, name)
    max = if tool, do: tool.max_retries, else: 0
    used_after = Map.get(retries, name, 0) + 1

    if used_after > max do
      {:error, {:unexpected_model_behavior, {:tool_retries_exhausted, name, reason}}}
    else
      {:ok, retry_part(name, id, reason), Map.put(retries, name, used_after)}
    end
  end

  defp find_tool(%Run{agent: agent}, name), do: Enum.find(agent.tools, &(&1.name == name))

  defp max_retries(nil), do: 0
  defp max_retries(%Tool{max_retries: m}), do: m

  defp decode_args(%Part.ToolCall{} = call) do
    case Part.ToolCall.args_as_map(call) do
      :empty -> {:ok, %{}}
      {:ok, map} when is_map(map) -> {:ok, map}
      {:error, _} = e -> e
    end
  end

  defp invoke(tool, ctx, args) do
    res =
      try do
        if tool.takes_ctx, do: tool.call.(ctx, args), else: tool.call.(args)
      rescue
        e in ExAgent.ModelRetry -> {:error, e.message}
        e -> {:error, Exception.message(e)}
      end

    case res do
      {:ok, _} = ok -> ok
      {:error, _} = e -> e
      value -> {:ok, value}
    end
  end

  defp retry_part(tool_name, tool_call_id, reason) do
    %Part.Retry{content: reason_msg(reason), tool_name: tool_name, tool_call_id: tool_call_id}
  end

  defp reason_msg(reason) when is_binary(reason), do: reason
  defp reason_msg(reasons) when is_list(reasons), do: Jason.encode!(%{"errors" => reasons})
  defp reason_msg(reason), do: inspect(reason)

  # ----- finalising --------------------------------------------------------
  defp finalize_text(text, %Run{} = state) do
    {:ok, result(text, state)}
  end

  defp retry_or_fail(%Run{} = state, error) do
    retry_or_fail(state, error, %Part.Retry{content: reason_msg(error)}, [])
  end

  defp retry_or_fail(
         %Run{} = state,
         error,
         %Part.ToolCall{tool_name: tool_name, tool_call_id: tool_call_id},
         extra_parts
       ) do
    retry = %Part.Retry{
      content: reason_msg(error),
      tool_name: tool_name,
      tool_call_id: tool_call_id
    }

    retry_or_fail(state, error, retry, extra_parts)
  end

  defp retry_or_fail(
         %Run{output_retries_used: used, agent: %{output_retries: max}},
         error,
         _retry,
         _extra_parts
       )
       when used >= max do
    {:error, {:unexpected_model_behavior, {:output_retries_exhausted, error}}}
  end

  defp retry_or_fail(%Run{} = state, _error, %Part.Retry{} = retry, extra_parts) do
    state = %{state | output_retries_used: state.output_retries_used + 1}

    state = %{
      state
      | messages:
          append(state.messages, %Request{
            parts: [retry | extra_parts],
            timestamp: DateTime.utc_now()
          })
    }

    drive(state)
  end

  # ----- helpers -----------------------------------------------------------
  defp build_context(%Run{
         deps: deps,
         model: model,
         messages: messages,
         usage: usage,
         prompt: prompt
       }) do
    %RunContext{
      deps: deps,
      model: model,
      prompt: prompt,
      messages: messages,
      usage: usage
    }
  end

  defp put_tool_info(%RunContext{} = ctx, tool_name, tool_call_id, retry, max_retries) do
    %{
      ctx
      | tool_name: tool_name,
        tool_call_id: tool_call_id,
        retry: retry,
        max_retries: max_retries
    }
  end

  defp merge_usage(%Usage{} = acc, nil), do: acc

  defp merge_usage(%Usage{} = acc, %Usage{} = resp) do
    %Usage{
      input_tokens: acc.input_tokens + (resp.input_tokens || 0),
      output_tokens: acc.output_tokens + (resp.output_tokens || 0),
      details: sum_details(acc.details, resp.details)
    }
  end

  defp sum_details(a, b) do
    Map.merge(a, b, fn _k, x, y -> (x || 0) + (y || 0) end)
  end

  defp append(messages, message), do: messages ++ [message]

  defp result(output, %Run{} = state) do
    new = Enum.drop(state.messages, state.first_new_message_index)

    %{
      output: output,
      messages: state.messages,
      new_messages: new,
      usage: state.usage,
      run_step: state.run_step,
      # The (possibly updated) model struct, so stateful models (e.g. the
      # script-driven Test) can be threaded across runs by the runtime layer.
      model: state.model
    }
  end
end
