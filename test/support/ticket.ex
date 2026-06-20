defmodule ExAgent.Test.Ticket do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  embedded_schema do
    field(:category, :string)
    field(:priority, :integer)
    field(:summary, :string)
  end

  def changeset(schema, attrs) do
    schema
    |> Ecto.Changeset.cast(attrs, [:category, :priority, :summary])
    |> Ecto.Changeset.validate_required([:category, :priority, :summary])
    |> Ecto.Changeset.validate_inclusion(:category, ["billing", "bug", "feature", "other"])
    |> Ecto.Changeset.validate_number(:priority,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 5
    )
  end
end
