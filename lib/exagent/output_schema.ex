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

    required = required_fields(mod) |> Enum.map(&Atom.to_string/1)

    %{type: "object", properties: properties, required: required}
  end

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
  defp apply_changeset(mod, data) do
    if function_exported?(mod, :changeset, 2) do
      mod.changeset(struct(mod), data)
    else
      struct(mod)
      |> Changeset.cast(data, fields(mod))
      |> Changeset.validate_required(fields(mod))
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
