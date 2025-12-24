if Code.ensure_loaded?(Zoi) do
  defmodule Strider.Schema.Zoi do
    @moduledoc """
    Schema implementation using the Zoi library.

    Zoi provides runtime schema validation with JSON Schema generation,
    making it ideal for structured LLM outputs.

    ## Example

        alias Strider.Schema.Zoi, as: Schema

        # Define a schema for extracting user info
        user_schema = Schema.object(%{
          name: Schema.string(),
          age: Schema.integer(),
          email: Schema.string() |> Schema.describe("User's email address")
        })

        # Parse LLM response
        {:ok, user} = Schema.parse(user_schema, %{
          "name" => "Alice",
          "age" => 30,
          "email" => "alice@example.com"
        })

        # Generate JSON Schema for prompt injection
        json_schema = Schema.to_json_schema(user_schema)

    ## Tool Schemas

    For tool calling, you can define both input and output schemas:

        # Tool input schema
        search_input = Schema.object(%{
          query: Schema.string() |> Schema.describe("Search query"),
          limit: Schema.integer() |> Schema.optional()
        })

        # Tool output schema
        search_output = Schema.object(%{
          results: Schema.array(Schema.object(%{
            title: Schema.string(),
            url: Schema.string(),
            snippet: Schema.string()
          }))
        })

    """

    @behaviour Strider.Schema

    # Parsing

    @impl true
    def parse(schema, data) do
      Zoi.parse(schema, data)
    end

    @impl true
    def parse!(schema, data) do
      Zoi.parse!(schema, data)
    end

    # JSON Schema generation

    @impl true
    def to_json_schema(schema) do
      Zoi.to_json_schema(schema)
    end

    # Primitive types

    @impl true
    def string(opts \\ []) do
      Zoi.string(opts)
    end

    @impl true
    def integer(opts \\ []) do
      Zoi.integer(opts)
    end

    @impl true
    def number(opts \\ []) do
      Zoi.number(opts)
    end

    @impl true
    def boolean(opts \\ []) do
      Zoi.boolean(opts)
    end

    # Complex types

    @impl true
    def array(item_schema) do
      Zoi.array(item_schema)
    end

    @impl true
    def object(properties) do
      Zoi.object(properties)
    end

    @impl true
    def enum(values) do
      Zoi.enum(values)
    end

    @impl true
    def union(schemas) do
      Zoi.union(schemas)
    end

    # Modifiers

    @impl true
    def optional(schema) do
      Zoi.optional(schema)
    end

    @impl true
    def describe(schema, description) do
      # Zoi sets description at creation time, so we update the meta directly
      %{schema | meta: %{schema.meta | description: description}}
    end

    # Additional Zoi-specific helpers (not part of behaviour)

    @doc """
    Creates a nullable schema (allows null values).
    """
    @spec nullable(Strider.Schema.t()) :: Strider.Schema.t()
    def nullable(schema) do
      Zoi.nullable(schema)
    end

    @doc """
    Creates a literal schema (exact value match).
    """
    @spec literal(term()) :: Strider.Schema.t()
    def literal(value) do
      Zoi.literal(value)
    end

    @doc """
    Adds a minimum constraint.
    """
    @spec min(Strider.Schema.t(), integer()) :: Strider.Schema.t()
    def min(schema, value) do
      Zoi.min(schema, value)
    end

    @doc """
    Adds a maximum constraint.
    """
    @spec max(Strider.Schema.t(), integer()) :: Strider.Schema.t()
    def max(schema, value) do
      Zoi.max(schema, value)
    end

    @doc """
    Adds a custom refinement function.
    """
    @spec refine(Strider.Schema.t(), (term() -> :ok | {:error, String.t()})) :: Strider.Schema.t()
    def refine(schema, fun) do
      Zoi.refine(schema, fun)
    end

    @doc """
    Adds a transformation function.
    """
    @spec transform(Strider.Schema.t(), (term() -> term())) :: Strider.Schema.t()
    def transform(schema, fun) do
      Zoi.transform(schema, fun)
    end
  end
end
