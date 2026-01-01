defprotocol Strider.Content.Wrappable do
  @moduledoc """
  Protocol for converting content to a list of `Strider.Content.Part` structs.

  This protocol defines the boundary between arbitrary content (strings, maps,
  structs, etc.) and the Part-based representation used for LLM messages.

  ## Why a Protocol?

  Different content types need different handling when stored in context
  or sent to LLMs:

  - Strings become text parts
  - Maps/structs are JSON-encoded for LLM consumption
  - Parts pass through unchanged

  Using a protocol allows:
  1. Clear boundary definition
  2. Extensibility for custom types
  3. Idiomatic Elixir polymorphism

  ## Implementing for Custom Types

  If you have custom structs that should be stored differently:

      defimpl Strider.Content.Wrappable, for: MyApp.CustomResponse do
        def wrap(response) do
          [Strider.Content.text(MyApp.CustomResponse.to_string(response))]
        end
      end

  """

  @fallback_to_any true

  @doc """
  Converts content to a list of Content.Part structs.

  ## Examples

      iex> Strider.Content.Wrappable.wrap("Hello")
      [%Strider.Content.Part{type: :text, text: "Hello"}]

      iex> Strider.Content.Wrappable.wrap(%{result: 42})
      [%Strider.Content.Part{type: :text, text: ~s({"result":42})}]

  """
  @spec wrap(t) :: [Strider.Content.Part.t()]
  def wrap(content)
end

defimpl Strider.Content.Wrappable, for: BitString do
  def wrap(text) do
    [Strider.Content.text(text)]
  end
end

defimpl Strider.Content.Wrappable, for: Strider.Content.Part do
  def wrap(part) do
    [part]
  end
end

defimpl Strider.Content.Wrappable, for: List do
  def wrap([]), do: []

  def wrap([%Strider.Content.Part{} | _] = parts) do
    parts
  end

  def wrap(list) do
    [Strider.Content.text(Jason.encode!(list))]
  end
end

defimpl Strider.Content.Wrappable, for: Map do
  def wrap(map) do
    [Strider.Content.text(Jason.encode!(map))]
  end
end

defimpl Strider.Content.Wrappable, for: Any do
  def wrap(struct) when is_struct(struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__baml_class__])
    |> Jason.encode!()
    |> Strider.Content.text()
    |> List.wrap()
  end

  def wrap(other) do
    [Strider.Content.text(inspect(other))]
  end
end
