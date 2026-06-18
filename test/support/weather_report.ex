defmodule ExAgent.Test.WeatherReport do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  embedded_schema do
    field(:city, :string)
    field(:temp_c, :float)
    field(:condition, Ecto.Enum, values: [:sunny, :rainy, :cloudy])
  end

  def changeset(schema, attrs) do
    schema
    |> Ecto.Changeset.cast(attrs, [:city, :temp_c, :condition])
    |> Ecto.Changeset.validate_required([:city, :temp_c])
    |> Ecto.Changeset.validate_number(:temp_c, greater_than: -100, less_than: 100)
  end
end
