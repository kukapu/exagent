defmodule ExAgent.Test.ReceiptItem do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  embedded_schema do
    field(:name, :string)
    field(:quantity, :float)
    field(:unit_price, :float)
  end

  def changeset(schema, attrs) do
    schema
    |> Ecto.Changeset.cast(attrs, [:name, :quantity, :unit_price])
    |> Ecto.Changeset.validate_required([:name])
  end
end

defmodule ExAgent.Test.Receipt do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  embedded_schema do
    field(:merchant, :string)
    field(:total, :float)
    embeds_many(:items, ExAgent.Test.ReceiptItem)
  end

  def changeset(schema, attrs) do
    schema
    |> Ecto.Changeset.cast(attrs, [:merchant, :total])
    |> Ecto.Changeset.cast_embed(:items, required: true)
  end
end
