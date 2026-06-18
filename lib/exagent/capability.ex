defmodule ExAgent.Capability do
  @moduledoc """
  Composable middleware that observes/transforms an agent run at well-defined
  points. This is ExAgent's "capabilities" spine, modelled the Elixir way: a
  behaviour whose callbacks default to no-ops via `use ExAgent.Capability`, so
  a capability overrides only the hooks it cares about.

  A capability is any module. It is passed as the first argument to its own
  callbacks (so it can carry config as module state or read its own attributes).

  ## Hooks (all optional)

    * `before_model_request(cap, state)` — return (possibly modified) `state`.
      Set `state.request_messages` to alter what's sent to the model without
      touching the canonical history (e.g. keep a sliding window, redact PII).
    * `after_model_request(cap, state)` — observe/modify state after the model
      responded (state already includes the new response + merged usage).
    * `before_tool_execute(cap, ctx, tool_call)` — observe/replace a tool call.
    * `after_tool_execute(cap, ctx, tool_call, result)` — observe a tool result.

  ## Example

      defmodule MyApp.RedactPII do
        use ExAgent.Capability

        @impl true
        def before_model_request(_cap, state) do
          redacted = redact(state.messages)
          %{state | request_messages: redacted}
        end
      end

      ExAgent.new(model: "openai:gpt-4o", capabilities: [MyApp.RedactPII])
  """

  @type state :: map()

  @callback before_model_request(cap :: module(), state()) :: state()
  @callback after_model_request(cap :: module(), state()) :: state()
  @callback before_tool_execute(cap :: module(), map(), struct()) :: struct()
  @callback after_tool_execute(cap :: module(), map(), struct(), term()) :: term()

  @optional_callbacks [
    before_model_request: 2,
    after_model_request: 2,
    before_tool_execute: 3,
    after_tool_execute: 4
  ]

  defmacro __using__(_opts) do
    quote do
      @behaviour ExAgent.Capability

      def before_model_request(_cap, state), do: state
      def after_model_request(_cap, state), do: state
      def before_tool_execute(_cap, ctx, tool_call), do: tool_call
      def after_tool_execute(_cap, ctx, tool_call, result), do: result

      defoverridable before_model_request: 2,
                     after_model_request: 2,
                     before_tool_execute: 3,
                     after_tool_execute: 4
    end
  end
end

defmodule ExAgent.Capabilities do
  @moduledoc false
  # Reduces a list of capability modules over the run state / call / result,
  # calling each implemented hook. Capabilities compose in list order.

  @spec before_model_request([module()], map()) :: map()
  def before_model_request(caps, state) do
    Enum.reduce(caps, state, fn cap, acc ->
      call_if(cap, :before_model_request, [cap, acc], acc)
    end)
  end

  @spec after_model_request([module()], map()) :: map()
  def after_model_request(caps, state) do
    Enum.reduce(caps, state, fn cap, acc ->
      call_if(cap, :after_model_request, [cap, acc], acc)
    end)
  end

  @spec before_tool_execute([module()], map(), struct()) :: struct()
  def before_tool_execute(caps, ctx, tool_call) do
    Enum.reduce(caps, tool_call, fn cap, acc ->
      call_if(cap, :before_tool_execute, [cap, ctx, acc], acc)
    end)
  end

  @spec after_tool_execute([module()], map(), struct(), term()) :: term()
  def after_tool_execute(caps, ctx, tool_call, result) do
    Enum.reduce(caps, result, fn cap, acc ->
      call_if(cap, :after_tool_execute, [cap, ctx, tool_call, acc], acc)
    end)
  end

  defp call_if(cap, fun, args, default) do
    mod = impl(cap)

    if function_exported?(mod, fun, length(args)) do
      apply(mod, fun, args)
    else
      default
    end
  end

  defp impl(mod) when is_atom(mod), do: mod
  defp impl(%{__struct__: mod}), do: mod
end
