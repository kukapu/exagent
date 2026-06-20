defmodule ExAgent.Permissions do
  @moduledoc """
  Per-tool admission control: `:allow`, `:ask` or `:deny`, matched against tool
  names with glob patterns — the same model opencode uses for tool safety.

  Rules are evaluated in order and the **last matching rule wins** (so put a
  catch-all `*` first, then more specific rules after it). Anything that matches
  no rule falls back to `:default` (`:allow` by default).

  * `:allow` — run the tool.
  * `:deny` — never run it; the model receives a "permission denied" tool return
    so it can adapt.
  * `:ask` — require human approval. In a one-shot `ExAgent.run/3` you pass an
    `:approve` callback `(tool_call -> :approve | :deny)`; the run calls it (it
    may block on a PubSub round-trip in a LiveView). With no callback, `:ask`
    is treated as `:deny` (fail closed).

  ## Example

      perms =
        ExAgent.Permissions.new!(
          rules: [{"*", :deny}, {"read", :allow}, {"search_*", :allow}, {"bash", :ask}],
          default: :deny
        )

      ExAgent.Permissions.decide(perms, "bash")        #=> :ask
      ExAgent.Permissions.decide(perms, "search_web")  #=> :allow
      ExAgent.Permissions.decide(perms, "write")       #=> :deny
  """

  @type action :: :allow | :ask | :deny

  defstruct rules: [], default: :allow

  @type t :: %__MODULE__{
          # compiled {Regex.t(), action()} pairs, in evaluation order
          rules: [{Regex.t(), action()}],
          default: action()
        }

  @doc """
  Build a permissions set from `rules` (`[{glob_string, action}]`) and a
  `:default` action. Globs support `*` (any run of chars) and `?` (single char).
  """
  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    rules =
      opts
      |> Keyword.get(:rules, [])
      |> Enum.map(fn {glob, action} -> {compile_glob(glob), action} end)

    %__MODULE__{rules: rules, default: Keyword.get(opts, :default, :allow)}
  end

  @doc "Decide the action for a tool name (last matching rule wins, else default)."
  @spec decide(t(), String.t()) :: action()
  def decide(%__MODULE__{rules: rules, default: default}, tool_name) when is_binary(tool_name) do
    Enum.reduce(rules, default, fn {regex, action}, acc ->
      if Regex.match?(regex, tool_name), do: action, else: acc
    end)
  end

  @doc """
  Resolve an `:ask` decision through an optional `approve` callback.

  * `:allow` → `:allow`.
  * `:deny` → `:deny`.
  * `:ask` with a callback → calls it with `tool_call` and maps `:approve` to
    `:allow`, anything else to `:deny`.
  * `:ask` without a callback → `:deny` (fail closed).
  """
  @spec resolve(action(), term(), (term() -> :approve | term()) | nil) :: action()
  def resolve(:ask, tool_call, approve) when is_function(approve, 1) do
    case approve.(tool_call) do
      :approve -> :allow
      _ -> :deny
    end
  end

  def resolve(:ask, _tool_call, nil), do: :deny
  def resolve(action, _tool_call, _approve), do: action

  defp compile_glob(glob) when is_binary(glob) do
    pattern =
      glob
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")
      |> then(&"^#{&1}$")

    Regex.compile!(pattern)
  end
end
