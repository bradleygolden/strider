if Code.ensure_loaded?(Zoi) do
  defmodule Strider.Schema.ZoiTest do
    use ExUnit.Case, async: true

    alias Strider.Schema.Zoi, as: Schema

    describe "Strider.Schema.Zoi" do
      test "parses valid object" do
        schema =
          Schema.object(%{
            name: Schema.string(),
            age: Schema.integer()
          })

        {:ok, result} = Schema.parse(schema, %{name: "Alice", age: 30})

        assert result.name == "Alice"
        assert result.age == 30
      end

      test "returns error for invalid data" do
        schema = Schema.string()

        {:error, errors} = Schema.parse(schema, 123)

        assert is_list(errors)
        refute Enum.empty?(errors)
      end

      test "parse! raises on invalid data" do
        schema = Schema.string()

        assert_raise Zoi.ParseError, fn ->
          Schema.parse!(schema, 123)
        end
      end

      test "to_json_schema generates valid JSON schema" do
        schema =
          Schema.object(%{
            name: Schema.string(),
            active: Schema.boolean()
          })

        json_schema = Schema.to_json_schema(schema)

        assert json_schema[:type] == :object
        assert json_schema[:properties][:name][:type] == :string
        assert json_schema[:properties][:active][:type] == :boolean
      end

      test "supports nested objects" do
        schema =
          Schema.object(%{
            user:
              Schema.object(%{
                name: Schema.string(),
                email: Schema.string()
              })
          })

        {:ok, result} =
          Schema.parse(schema, %{
            user: %{
              name: "Bob",
              email: "bob@example.com"
            }
          })

        assert result.user.name == "Bob"
        assert result.user.email == "bob@example.com"
      end

      test "supports arrays" do
        schema = Schema.array(Schema.string())

        {:ok, result} = Schema.parse(schema, ["one", "two", "three"])

        assert result == ["one", "two", "three"]
      end

      test "supports optional fields" do
        schema =
          Schema.object(%{
            required: Schema.string(),
            optional: Schema.optional(Schema.string())
          })

        {:ok, result} = Schema.parse(schema, %{required: "value"})

        assert result.required == "value"
        refute Map.has_key?(result, :optional)
      end

      test "supports enum values" do
        schema = Schema.enum(["pending", "approved", "rejected"])

        {:ok, result} = Schema.parse(schema, "approved")
        assert result == "approved"

        {:error, _} = Schema.parse(schema, "invalid")
      end

      test "supports union types" do
        schema = Schema.union([Schema.string(), Schema.integer()])

        {:ok, "hello"} = Schema.parse(schema, "hello")
        {:ok, 42} = Schema.parse(schema, 42)
      end

      test "describe adds description to schema" do
        schema = Schema.string() |> Schema.describe("User's full name")

        json_schema = Schema.to_json_schema(schema)
        assert json_schema[:description] == "User's full name"
      end

      test "nullable allows nil values" do
        schema = Schema.nullable(Schema.string())

        {:ok, nil} = Schema.parse(schema, nil)
        {:ok, "value"} = Schema.parse(schema, "value")
      end

      test "literal matches exact values" do
        schema = Schema.literal("exact")

        {:ok, "exact"} = Schema.parse(schema, "exact")
        {:error, _} = Schema.parse(schema, "different")
      end

      test "min/max constraints" do
        schema = Schema.integer() |> Schema.min(0) |> Schema.max(100)

        {:ok, 50} = Schema.parse(schema, 50)
        {:error, _} = Schema.parse(schema, -1)
        {:error, _} = Schema.parse(schema, 101)
      end
    end
  end
end
