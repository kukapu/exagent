defmodule ExAgent.OutputSchema do
  @moduledoc """
  Structured output via Ecto schemas and changesets.

  Given any module defining an `embedded_schema` (plus a `changeset/2`), this
  module:

    * **`json_schema/1`** derives the JSON Schema the model is told to produce,
      by walking the schema's fields and types (scalars, enums, arrays, embedded
      schemas, datetimes).
    * **`validate/2`** builds a changeset from the model's data, applies the
      schema's validations, and returns either `{:ok, struct}` or
      `{:error, errors}` — feeding the errors back to the model for a retry.

  The convention is the standard Ecto one: a `changeset(struct, attrs)` callback.
  If the module doesn't define one, a default "cast all fields" changeset is
  used.

  ## Example

      defmodule WeatherReport do
        use Ecto.Schema

        embedded_schema do
          field :city, :string
          field :temp_c, :float
          field :condition, Ecto.Enum, values: [:sunny, :rainy, :cloudy]
        end

        def changeset(schema, attrs) do
          schema
          |> Ecto.Changeset.cast(attrs, [:city, :temp_c, :condition])
          |> Ecto.Changeset.validate_required([:city, :temp_c])
          |> Ecto.Changeset.validate_number(:temp_c, greater_than: -100, less_than: 100)
        end
      end

      ExAgent.OutputSchema.json_schema(WeatherReport)
      # => %{type: "object", properties: %{city: %{type: "string"}, ...}, required: [...]}

      ExAgent.OutputSchema.validate(WeatherReport, %{"city" => "Madrid", "temp_c" => 22.0})
      # => {:ok, %WeatherReport{city: "Madrid", temp_c: 22.0, ...}}
  """

  alias Ecto.Changeset

  @doc "Derive a JSON Schema from an Ecto schema module."
  @spec json_schema(module()) :: map()
  def json_schema(mod) do
    properties =
      mod
      |> fields()
      |> Map.new(fn field -> {Atom.to_string(field), type_to_schema(mod, field)} end)

    # Reflect changeset-level constraints (inclusion → enum, number → min/max,
    # length → minLength/maxLength) so the model can actually comply with them.
    # Without this, a `validate_inclusion(:category, [...])` is invisible to the
    # model and every structured-output call needs wasteful retries.
    properties = merge_changeset_validations(mod, properties)

    required = required_fields(mod) |> Enum.map(&Atom.to_string/1)

    %{type: "object", properties: properties, required: required}
  end

  # Fold the changeset's declared validations into the per-field schemas. We run
  # the schema's changeset once (on empty data) purely to read `.validations`,
  # the metadata Ecto attaches for each validate_* call.
  defp merge_changeset_validations(mod, properties) do
    changeset = apply_changeset(mod, %{})

    Enum.reduce(changeset.validations, properties, fn {field, {kind, meta}}, props ->
      case Map.get(props, Atom.to_string(field)) do
        nil -> props
        schema -> Map.put(props, Atom.to_string(field), apply_validation(kind, meta, schema))
      end
    end)
  end

  defp apply_validation(:inclusion, values, schema) when is_list(values),
    do: Map.put(schema, :enum, Enum.map(values, &to_string/1))

  defp apply_validation(:exclusion, values, schema) when is_list(values),
    do: Map.put(schema, :not, %{enum: Enum.map(values, &to_string/1)})

  defp apply_validation(:number, opts, schema) do
    Enum.reduce(opts, schema, fn
      {:greater_than_or_equal_to, n}, s -> Map.put(s, :minimum, n)
      {:less_than_or_equal_to, n}, s -> Map.put(s, :maximum, n)
      {:greater_than, n}, s -> Map.put(s, :exclusiveMinimum, n)
      {:less_than, n}, s -> Map.put(s, :exclusiveMaximum, n)
      {:equal_to, n}, s -> s |> Map.put(:minimum, n) |> Map.put(:maximum, n)
      _, s -> s
    end)
  end

  defp apply_validation(:length, opts, schema) do
    Enum.reduce(opts, schema, fn
      {:min, n}, s -> Map.put(s, :minLength, n)
      {:max, n}, s -> Map.put(s, :maxLength, n)
      _, s -> s
    end)
  end

  # format / acceptance / others have no clean JSON Schema equivalent; skip.
  defp apply_validation(_kind, _meta, schema), do: schema

  @doc """
  Validate `data` (a map, typically decoded from the model's JSON) against an
  Ecto schema, returning `{:ok, struct}` or `{:error, [error_map]}`.
  """
  @spec validate(module(), map()) :: {:ok, struct()} | {:error, [map()]}
  def validate(mod, data) when is_atom(mod) and is_map(data) do
    changeset = apply_changeset(mod, data)

    if changeset.valid? do
      {:ok, Changeset.apply_changes(changeset)}
    else
      {:error, format_errors(changeset)}
    end
  end

  # ----- changeset application --------------------------------------------
  # A user changeset that raises on missing/unexpected input (a common
  # "assume-then-cast" style) would otherwise crash the whole run. Convert any
  # exception into a retryable validation error so the model gets a chance to
  # fix its arguments.
  defp apply_changeset(mod, data) do
    try do
      if function_exported?(mod, :changeset, 2) do
        mod.changeset(struct(mod), data)
      else
        struct(mod)
        |> Changeset.cast(data, fields(mod))
        |> Changeset.validate_required(fields(mod))
      end
    rescue
      e ->
        # A user changeset that raises (common "assume-then-cast" style) would
        # otherwise crash the run; surface it as a retryable validation error.
        struct(mod)
        |> Changeset.cast(data, fields(mod))
        |> Changeset.add_error(:__changeset__, "schema changeset raised: #{Exception.message(e)}")
    end
  end

  defp fields(mod), do: mod.__schema__(:fields)

  defp required_fields(mod) do
    # The schema's own changeset is the source of truth for required-ness.
    # We run it once with empty data to collect validate_required targets.
    case apply_changeset(mod, %{}).required do
      [] -> fields(mod)
      required -> required
    end
  end

  # ----- Ecto type -> JSON Schema -----------------------------------------
  defp type_to_schema(mod, field) do
    case mod.__schema__(:type, field) do
      :string ->
        %{type: "string"}

      :integer ->
        %{type: "integer"}

      :id ->
        %{type: "integer"}

      :float ->
        %{type: "number"}

      :decimal ->
        %{type: "number"}

      :boolean ->
        %{type: "boolean"}

      :binary ->
        %{type: "string"}

      :binary_id ->
        %{type: "string"}

      :uuid ->
        %{type: "string", format: "uuid"}

      :map ->
        %{type: "object"}

      {:array, inner} ->
        %{type: "array", items: ecto_type_schema(inner)}

      {:parameterized, {Ecto.Enum, %{mappings: mappings}}} ->
        enum_schema(mappings)

      {:parameterized, Ecto.Enum, %{mappings: mappings}} ->
        enum_schema(mappings)

      # embeds_many / embeds_one are parameterized types in modern Ecto
      # (reported as {:parameterized, {Ecto.Embedded, %Ecto.Embedded{...}}}).
      # Without these clauses the field falls through to the catch-all and
      # derives to %{}, hiding the embedded object's structure from the model.
      {:parameterized, {Ecto.Embedded, %{cardinality: :many, related: related}}} ->
        %{type: "array", items: json_schema(related)}

      {:parameterized, {Ecto.Embedded, %{related: related}}} ->
        json_schema(related)

      {:parameterized, _, _} ->
        %{type: "string"}

      {:embed, %Ecto.Embedded{related: related}} ->
        json_schema(related)

      type
      when type in [
             :utc_datetime,
             :naive_datetime,
             :utc_datetime_usec,
             :naive_datetime_usec,
             :date,
             :time
           ] ->
        %{type: "string", format: inspect(type)}

      _ ->
        %{}
    end
  end

  defp ecto_type_schema(:string), do: %{type: "string"}
  defp ecto_type_schema(:integer), do: %{type: "integer"}
  defp ecto_type_schema(:float), do: %{type: "number"}
  defp ecto_type_schema(:decimal), do: %{type: "number"}
  defp ecto_type_schema(:boolean), do: %{type: "boolean"}
  defp ecto_type_schema(_), do: %{}

  defp enum_schema(mappings),
    do: %{type: "string", enum: Enum.map(mappings, fn {_k, v} -> to_string(v) end)}

  # ----- error formatting --------------------------------------------------
  defp format_errors(%Changeset{errors: errors}) do
    Enum.map(errors, fn {field, {message, opts}} ->
      %{
        field: field,
        message: interpolate(message, opts),
        type: Keyword.get(opts, :validation)
      }
    end)
  end

  defp interpolate(message, opts) do
    Enum.reduce(opts, message, fn
      {key, value}, acc when is_binary(value) ->
        String.replace(acc, "%{#{key}}", value)

      {key, value}, acc when is_atom(value) or is_number(value) ->
        String.replace(acc, "%{#{key}}", to_string(value))

      _, acc ->
        acc
    end)
  end
end
