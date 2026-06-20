defmodule ExAgent.OutputSchemaTest do
  use ExUnit.Case, async: true

  alias ExAgent.OutputSchema
  alias ExAgent.Test.{Receipt, ReceiptItem, Ticket, WeatherReport}

  describe "json_schema/1" do
    test "derives properties and required from an Ecto schema" do
      schema = OutputSchema.json_schema(WeatherReport)

      assert schema.type == "object"

      # temp_c carries the validate_number constraints now (greater/less than →
      # exclusiveMinimum / exclusiveMaximum), so the model can comply.
      assert schema.properties == %{
               "city" => %{type: "string"},
               "temp_c" => %{type: "number", exclusiveMinimum: -100, exclusiveMaximum: 100},
               "condition" => %{type: "string", enum: ["sunny", "rainy", "cloudy"]}
             }

      # validate_required([:city, :temp_c]) → only those two are required
      assert schema.required == ["city", "temp_c"]
    end

    test "reflects validate_inclusion as an enum and validate_number as min/max" do
      schema = OutputSchema.json_schema(Ticket)

      assert schema.properties["category"] == %{
               type: "string",
               enum: ["billing", "bug", "feature", "other"]
             }

      assert schema.properties["priority"] == %{
               type: "integer",
               minimum: 1,
               maximum: 5
             }
    end

    test "embeds_many derives an array of nested object schemas" do
      schema = OutputSchema.json_schema(Receipt)

      assert schema.properties["items"] == %{
               type: "array",
               items: %{
                 type: "object",
                 properties: %{
                   "name" => %{type: "string"},
                   "quantity" => %{type: "number"},
                   "unit_price" => %{type: "number"}
                 },
                 required: ["name"]
               }
             }

      assert "items" in schema.required
    end
  end

  describe "validate/2" do
    test "valid data → struct with cast atoms for enum" do
      assert {:ok, %WeatherReport{} = wr} =
               OutputSchema.validate(WeatherReport, %{
                 "city" => "Madrid",
                 "temp_c" => 22.0,
                 "condition" => "sunny"
               })

      assert wr.city == "Madrid"
      assert wr.temp_c == 22.0
      assert wr.condition == :sunny
    end

    test "out-of-range number fails validation" do
      assert {:error, errors} =
               OutputSchema.validate(WeatherReport, %{"city" => "X", "temp_c" => 200})

      assert Enum.any?(errors, &(&1.field == :temp_c))
    end

    test "missing required field fails" do
      assert {:error, errors} = OutputSchema.validate(WeatherReport, %{"temp_c" => 10.0})
      assert Enum.any?(errors, &(&1.field == :city))
    end

    test "unknown enum value fails" do
      assert {:error, errors} =
               OutputSchema.validate(WeatherReport, %{
                 "city" => "X",
                 "temp_c" => 1.0,
                 "condition" => "stormy"
               })

      assert Enum.any?(errors, &(&1.field == :condition))
    end
  end
end
