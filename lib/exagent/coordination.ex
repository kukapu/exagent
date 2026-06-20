defmodule ExAgent.Coordination do
  @moduledoc """
  Orchestration patterns on top of `ExAgent.Session` and the core loop.

  These cover pydanticAI's complexity levels 2 and 3:

    * **Delegation** (level 2) — an agent calls another agent *as a tool*. The
      delegate runs its own model⇄tools loop and its output is returned to the
      parent; the delegate's token usage is merged into the parent run's usage.
    * **Hand-off** (level 3) — application code (or a supervisor agent)
      transfers control between participants in a Session.

  These complement — but don't replace — the BEAM-native coordination model: in
  ExAgent, multiple agents are usually separate supervised processes that
  message each other, rather than one agent calling another as a tool. Delegation
  is provided for parity with the pydanticAI pattern and for cases where nesting
  a sub-agent inside a tool is genuinely the simplest design.
  """

  alias ExAgent.Message.Usage
  alias ExAgent.Tool

  @doc """
  Build an `ExAgent.Tool` that delegates a sub-task to another agent.

  When the parent agent's model calls this tool, `delegate` is run with the
  tool's `prompt` argument (a one-shot `ExAgent.run/3`) and its output is
  returned to the parent. The delegate's token `usage` is merged into the
  parent run's accumulated usage — so limits and cost accounting cover the whole
  delegation tree, not just the parent.

  ## Arguments

    * `delegate` — an `ExAgent.t()`, or a builder `(ctx, args -> ExAgent.t())`
      so the delegate can be constructed lazily with the parent's context (e.g.
      to forward `deps` or pick a model per call).
    * `opts` — `:name` (default `"delegate"`), `:description`,
      `:max_retries` (default `1`), `:prompt_arg` (default `"prompt"`).

  ## Example

      delegate = ExAgent.new(model: "openai:gpt-4o-mini", instructions: "You summarize.")
      parent =
        ExAgent.new(
          model: "openai:gpt-4o",
          tools: [ExAgent.Coordination.delegation_tool(delegate, name: "summarize")]
        )

  The parent model can then call `summarize(prompt: "...")` to hand a sub-task
  to the cheaper model and get its result back, with both runs' tokens counted
  together.
  """
  @spec delegation_tool(ExAgent.t() | (map(), map() -> ExAgent.t()), keyword()) :: Tool.t()
  def delegation_tool(delegate, opts \\ []) do
    name = opts[:name] || "delegate"
    prompt_arg = opts[:prompt_arg] || "prompt"

    Tool.new(
      name: name,
      description: opts[:description] || default_description(delegate),
      parameters_json_schema: %{
        "type" => "object",
        "properties" => %{
          prompt_arg => %{
            "type" => "string",
            "description" => "The sub-task to hand to the delegate agent."
          }
        },
        "required" => [prompt_arg]
      },
      takes_ctx: true,
      max_retries: opts[:max_retries] || 1,
      call: fn ctx, args ->
        prompt = prompt_string(args[prompt_arg] || args[to_string(prompt_arg)])
        agent = resolve_delegate(delegate, ctx, args)

        case ExAgent.run(agent, prompt, deps: ctx.deps) do
          {:ok, %{output: output, usage: usage}} ->
            {:ok, output, usage || %Usage{input_tokens: 0, output_tokens: 0}}

          {:error, _} = e ->
            e
        end
      end
    )
  end

  @doc """
  Hand off control within a `ExAgent.Session` from the current participant to
  `to_id`, bypassing the normal turn policy. Emits `:session_turn_changed`.

  This is the BEAM-native equivalent of a programmatic hand-off: control moves
  directly between participants by message. After `to_id` takes its turn, the
  policy resumes its normal ordering from there.

  Returns `{:ok, to_id}` or `{:error, reason}` (`:not_running`, `:not_a_participant`).
  """
  @spec handoff(GenServer.server(), term()) :: {:ok, term()} | {:error, term()}
  def handoff(session, to_id) do
    GenServer.call(session, {:handoff, to_id})
  end

  # ---------------------------------------------------------------------------
  defp resolve_delegate(%ExAgent{} = agent, _ctx, _args), do: agent

  defp resolve_delegate(builder, ctx, args) when is_function(builder, 2),
    do: builder.(ctx, args)

  defp default_description(%ExAgent{name: name}) when is_binary(name) and name != "",
    do: "Delegate a sub-task to agent #{inspect(name)}."

  defp default_description(_), do: "Delegate a sub-task to another agent."

  defp prompt_string(prompt) when is_binary(prompt), do: prompt
  defp prompt_string(prompt) when is_list(prompt), do: Enum.join(prompt, " ")
  defp prompt_string(_), do: ""
end
