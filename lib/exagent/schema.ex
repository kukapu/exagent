defmodule ExAgent.Schema do
  @moduledoc """
  Convert Elixir type expressions (as written in `::` annotations / typespecs)
  into JSON Schema fragments — the foundation for `deftool` and structured
  output.

  This is deliberately a *subset*: it covers the common scalar/collection types
  a tool signature or output schema uses. Anything it can't resolve collapses to
  an unconstrained `%{}` ("any"), which is safe for the model and easy to spot.
  """

  @doc "Convert a single type AST node to a JSON Schema fragment."
  @spec from_type(Macro.t() | nil) :: map()
  # annotated form: `name :: type`
  def from_type({:"::", _, [_, type]}), do: from_type(type)

  # scalar zero-arity type calls: integer(), float(), ...
  def from_type({:integer, _, _}), do: %{type: "integer"}
  def from_type({:non_neg_integer, _, _}), do: %{type: "integer", minimum: 0}
  def from_type({:pos_integer, _, _}), do: %{type: "integer", minimum: 1}
  def from_type({:float, _, _}), do: %{type: "number"}
  def from_type({:number, _, _}), do: %{type: "number"}
  def from_type({:boolean, _, _}), do: %{type: "boolean"}
  def from_type({:atom, _, _}), do: %{type: "string"}
  def from_type({:binary, _, _}), do: %{type: "string"}
  def from_type({:string, _, _}), do: %{type: "string"}
  def from_type({:any, _, _}), do: %{}

  # String.t() / Binary.t() → dot-call form on an alias
  def from_type({{:., _, [{:__aliases__, _, [:String]}, :t]}, _, _}), do: %{type: "string"}
  def from_type({{:., _, [{:__aliases__, _, [:Binary]}, :t]}, _, _}), do: %{type: "string"}

  # bare aliases used as type names: String, boolean, integer ...
  def from_type({:__aliases__, _, [:String]}), do: %{type: "string"}
  def from_type({:__aliases__, _, [:boolean]}), do: %{type: "boolean"}
  def from_type({:__aliases__, _, [:integer]}), do: %{type: "integer"}
  def from_type({:__aliases__, _, [:float]}), do: %{type: "number"}

  # list of one inner type → JSON array
  def from_type([inner]), do: %{type: "array", items: from_type(inner)}
  def from_type([]), do: %{type: "array"}

  # literal unions (e.g. :a | :b) → string enum
  def from_type({:|, _, [left, right]}) do
    Enum.reduce(union_parts({:|, [], [left, right]}), [], &(&2 ++ [to_enum_value(&1)]))
    |> case do
      [] -> %{}
      values -> %{type: "string", enum: values}
    end
  end

  # atom literal used as a type → its string form (loosely typed)
  def from_type(atom) when is_atom(atom) and not is_nil(atom), do: %{}

  def from_type(nil), do: %{}

  # anything else → unconstrained
  def from_type(_), do: %{}

  @doc """
  Build a JSON Schema `object` for a list of `{name, type_ast}` params.

  All params are marked `required` by default (tool signatures have no defaults
  in this iteration); the model is expected to supply every one.
  """
  @spec object_schema([{atom(), Macro.t() | nil}]) :: map()
  def object_schema(params) do
    properties =
      Map.new(params, fn {name, type} -> {Atom.to_string(name), from_type(type)} end)

    required = Enum.map(params, &Atom.to_string(elem(&1, 0)))
    %{type: "object", properties: properties, required: required}
  end

  defp union_parts({:|, _, [left, right]}), do: union_parts(left) ++ union_parts(right)
  defp union_parts(other), do: [other]

  defp to_enum_value(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp to_enum_value(other), do: other
end
