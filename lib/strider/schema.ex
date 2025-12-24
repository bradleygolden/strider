defmodule Strider.Schema do
  @moduledoc """
  Behaviour for schema validation providers.

  Strider uses schemas for two purposes:

  1. **Input validation** - Validate structured input before sending to the LLM
  2. **Output validation** - Parse and validate LLM responses into typed structures

  This abstraction allows different schema libraries to be used. The default
  implementation uses Zoi (`Strider.Schema.Zoi`).

  ## Why Schemas Matter for Agent Loops

  Agent loops need structured output to work. When an LLM returns a response,
  you need to know: Is this a tool call? Is this a final answer? What are
  the arguments?

  Without consistent schemas, your loop code becomes backend-specific.
  With schemas, you can swap backends and keep the same loop logic.

  ## Inspiration

  This design is inspired by [BAML](https://boundaryml.com), which treats
  prompts as functions with typed inputs and outputs. The key insight:
  every LLM call is really `function(input) -> output` where both sides
  have schemas.

  ## Example

  Using the default Zoi implementation (requires `{:zoi, "~> 0.7"}`):

      alias Strider.Schema.Zoi, as: Schema

      output_schema = Schema.object(%{
        name: Schema.string(),
        age: Schema.integer(),
        email: Schema.string()
      })

      # Parse LLM response against the schema
      {:ok, user} = Schema.parse(output_schema, llm_response_json)
      # => %{name: "Alice", age: 30, email: "alice@example.com"}

  ## Implementing a Custom Schema Provider

  To use a different schema library, implement this behaviour:

      defmodule MyApp.Schemas.Ecto do
        @behaviour Strider.Schema

        @impl true
        def parse(schema, data) do
          # Your parsing logic
        end

        @impl true
        def to_json_schema(schema) do
          # Convert to JSON Schema for LLM context
        end

        # ... implement other callbacks
      end

  """

  @typedoc "A schema definition (implementation-specific)"
  @type t :: term()

  @typedoc "Validation errors"
  @type errors :: [map()]

  @doc """
  Parses and validates data against a schema.

  Returns `{:ok, validated_data}` on success, `{:error, errors}` on failure.

  ## Examples

      schema = MySchema.object(%{name: MySchema.string()})
      {:ok, %{name: "Alice"}} = MySchema.parse(schema, %{"name" => "Alice"})
      {:error, errors} = MySchema.parse(schema, %{"name" => 123})

  """
  @callback parse(schema :: t(), data :: term()) :: {:ok, term()} | {:error, errors()}

  @doc """
  Parses data, raising on validation failure.

  ## Examples

      schema = MySchema.string()
      "hello" = MySchema.parse!(schema, "hello")
      # Raises on invalid input

  """
  @callback parse!(schema :: t(), data :: term()) :: term()

  @doc """
  Converts a schema to JSON Schema format.

  This is used to inject output format instructions into prompts,
  similar to BAML's `{{ ctx.output_format }}` pattern.

  ## Examples

      schema = MySchema.object(%{name: MySchema.string()})
      json_schema = MySchema.to_json_schema(schema)
      # => %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}, ...}

  """
  @callback to_json_schema(schema :: t()) :: map()

  @doc """
  Creates a string schema.
  """
  @callback string(opts :: keyword()) :: t()

  @doc """
  Creates an integer schema.
  """
  @callback integer(opts :: keyword()) :: t()

  @doc """
  Creates a number (float) schema.
  """
  @callback number(opts :: keyword()) :: t()

  @doc """
  Creates a boolean schema.
  """
  @callback boolean(opts :: keyword()) :: t()

  @doc """
  Creates an array schema with items of the given type.
  """
  @callback array(item_schema :: t()) :: t()

  @doc """
  Creates an object schema with the given properties.

  ## Examples

      schema = MySchema.object(%{
        name: MySchema.string(),
        age: MySchema.integer()
      })

  """
  @callback object(properties :: map()) :: t()

  @doc """
  Creates an enum schema with allowed values.

  ## Examples

      schema = MySchema.enum(["pending", "approved", "rejected"])

  """
  @callback enum(values :: [term()]) :: t()

  @doc """
  Creates a union schema (one of multiple types).

  ## Examples

      schema = MySchema.union([
        MySchema.string(),
        MySchema.integer()
      ])

  """
  @callback union(schemas :: [t()]) :: t()

  @doc """
  Makes a schema optional (nullable).
  """
  @callback optional(schema :: t()) :: t()

  @doc """
  Adds a description to the schema (used in JSON Schema output).
  """
  @callback describe(schema :: t(), description :: String.t()) :: t()

  # Optional callbacks with defaults
  @optional_callbacks [string: 1, integer: 1, number: 1, boolean: 1]
end
