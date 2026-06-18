defmodule ExAgent.Tools do
  @moduledoc ~S"""
  Define tools as plain Elixir functions, with their JSON Schema derived from
  `::` type annotations and `@doc` strings — no hand-written schemas.

  Define a module of tools with derived schemas:

      defmodule MyApp.Tools do
        use ExAgent.Tools

        @doc "Get the weather for a city."
        deftool get_weather(ctx, city :: String.t()) do
          {:ok, ~s(#{city}: 22C, clear)}
        end

        @doc "Add two numbers."
        tool_plain add(a :: integer(), b :: integer()) do
          {:ok, a + b}
        end
      end

  Then wire them into an agent:

      agent = ExAgent.new(model: "test", tools: MyApp.Tools.tools())

  Rules:
    * `deftool` — the **first argument is the `RunContext`** (named `ctx` by
      convention); remaining typed args become the tool's parameters.
    * `tool_plain` — no context; every typed arg is a parameter.
    * Each parameter is described by `name :: type`; supported types live in
      `ExAgent.Schema`. Untyped params collapse to an unconstrained schema.
    * The function may return `value`, `{:ok, value}`, or `{:error, reason}`.
  """

  alias ExAgent.{Schema, Tool}

  defmacro __using__(_opts) do
    quote do
      import ExAgent.Tools, only: [deftool: 2, tool_plain: 2]
      Module.register_attribute(__MODULE__, :exagent_tools, accumulate: true)
      @before_compile ExAgent.Tools
    end
  end

  @doc "Define a tool that receives the `RunContext` as its first argument."
  defmacro deftool(head, do: body) do
    {name, arg_asts} = normalize_head(head)

    case arg_asts do
      [] ->
        raise ArgumentError, "deftool #{name}/0 must take a `ctx` argument"

      [ctx_ast | param_asts] ->
        ctx_name = arg_name(ctx_ast)
        params = Enum.map(param_asts, &extract_arg/1)
        build_tool(name, ctx_name, params, body, __CALLER__)
    end
  end

  @doc "Define a tool that takes only its parameters (no context)."
  defmacro tool_plain(head, do: body) do
    {name, arg_asts} = normalize_head(head)
    params = Enum.map(arg_asts, &extract_arg/1)
    build_tool(name, nil, params, body, __CALLER__)
  end

  @doc false
  # Compile-time assembly shared by both macros. `params` are already-extracted
  # `{name_atom, type_ast}` pairs; `ctx` is the context arg's atom name (or nil).
  defp build_tool(name, ctx, params, body, _caller) do
    schema = Schema.object_schema(params)

    param_names = Enum.map(params, &elem(&1, 0))

    # all argument names for the generated function (ctx first, if present)
    fn_args = if ctx, do: [ctx | param_names], else: param_names
    arg_vars = Enum.map(fn_args, &Macro.var(&1, nil))

    meta = %{
      name: Atom.to_string(name),
      parameters_json_schema: schema,
      takes_ctx: ctx != nil,
      function: name,
      arity: length(fn_args),
      args: param_names
    }

    quote do
      def unquote(name)(unquote_splicing(arg_vars)) do
        unquote(body)
      end

      @exagent_tools unquote(Macro.escape(meta))
    end
  end

  defp normalize_head({:when, _, [head, _guard]}), do: normalize_head(head)
  defp normalize_head({name, _meta, args}) when is_atom(name) and is_list(args), do: {name, args}
  defp normalize_head({name, _meta, nil}) when is_atom(name), do: {name, []}

  # Pull the bare atom name out of an argument AST (with or without `::`).
  defp arg_name({:"::", _, [{name, _, _}, _]}), do: name
  defp arg_name({name, _, _}) when is_atom(name), do: name

  # `param :: Type` → {param, type_ast}; bare `param` → {param, nil}
  defp extract_arg({:"::", _, [{name, _, _}, type]}) when is_atom(name), do: {name, type}
  defp extract_arg({name, _, _}) when is_atom(name), do: {name, nil}

  # ----- runtime construction of Tool structs (called from tools/0) --------
  @doc false
  @spec build(module(), map()) :: Tool.t()
  def build(mod, meta) do
    %Tool{
      name: meta.name,
      description: fetch_doc(mod, meta.function, meta.arity),
      parameters_json_schema: meta.parameters_json_schema,
      takes_ctx: meta.takes_ctx,
      call: build_call(mod, meta.function, meta.args, meta.takes_ctx),
      max_retries: 1
    }
  end

  defp fetch_doc(mod, name, arity) do
    with {:docs_v1, _, _, _, _, _, docs} <- Code.fetch_docs(mod),
         {_, _, _, doc, _} <- Enum.find(docs, &match_entry(&1, name, arity)) do
      case doc do
        %{"en" => text} -> String.trim(text)
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp match_entry({{:function, name, arity}, _, _, _, _}, name, arity), do: true
  defp match_entry(_, _, _), do: false

  defp build_call(mod, function, arg_names, true) do
    fn ctx, args ->
      apply(mod, function, [ctx | positional(args, arg_names)])
    end
  end

  defp build_call(mod, function, arg_names, false) do
    fn args ->
      apply(mod, function, positional(args, arg_names))
    end
  end

  defp positional(args, arg_names) do
    Enum.map(arg_names, fn name ->
      key = Atom.to_string(name)

      case Map.fetch(args, key) do
        {:ok, value} -> value
        :error -> Map.get(args, name)
      end
    end)
  end

  # ----- generated by @before_compile --------------------------------------
  @doc false
  defmacro __before_compile__(env) do
    metas =
      env.module
      |> Module.get_attribute(:exagent_tools)
      |> Enum.reverse()

    names = Enum.map(metas, & &1.name)

    quote do
      def __exagent_tools__,
        do: Enum.map(unquote(Macro.escape(metas)), &ExAgent.Tools.build(__MODULE__, &1))

      def tools, do: __exagent_tools__()
      def tool(name) when is_binary(name), do: Enum.find(tools(), &(&1.name == name))
      def tool(name) when is_atom(name), do: tool(Atom.to_string(name))
      def __exagent_tool_names__, do: unquote(names)
    end
  end
end
