defmodule Strider.Message do
  @moduledoc """
  Represents a single message in a conversation.

  ## Fields

  - `:role` - The role of the message sender (`:system`, `:user`, `:assistant`)
  - `:content` - The message content (text, multi-modal parts, or any backend-specific format)
  - `:metadata` - Optional metadata map (e.g., token counts, timestamps)

  ## Content Types

  Strider is content-agnostic. The `:content` field accepts any term, allowing backends
  to interpret content as needed. Common patterns include:

  - **Text** (most common): `"Hello!"` - simple string content
  - **Multi-modal list**: `[%{type: :text, text: "What's this?"}, %{type: :image_url, url: "..."}]`
  - **Structured data**: Backend-specific maps or structs

  ## Examples

      # Simple text message
      message = Strider.Message.new(:user, "Hello!")

      # Multi-modal message with image
      message = Strider.Message.new(:user, [
        %{type: :text, text: "What's in this image?"},
        %{type: :image_url, url: "https://example.com/image.png"}
      ])

      # Message with metadata
      message = Strider.Message.new(:assistant, "Hi there!", %{tokens: 5})

  """

  @type role :: :system | :user | :assistant
  @type t :: %__MODULE__{
          role: role(),
          content: term(),
          metadata: map()
        }

  @enforce_keys [:role, :content]
  defstruct [:role, :content, metadata: %{}]

  @doc """
  Creates a new message.

  ## Parameters

  - `role` - One of `:system`, `:user`, or `:assistant`
  - `content` - The message content (string, list of parts, or any term)
  - `metadata` - Optional metadata map (default: `%{}`)

  ## Examples

      iex> Strider.Message.new(:user, "Hello!")
      %Strider.Message{role: :user, content: "Hello!", metadata: %{}}

      iex> Strider.Message.new(:assistant, "Hi!", %{model: "gpt-4"})
      %Strider.Message{role: :assistant, content: "Hi!", metadata: %{model: "gpt-4"}}

  """
  @spec new(role(), term(), map()) :: t()
  def new(role, content, metadata \\ %{})
      when role in [:system, :user, :assistant] do
    %__MODULE__{
      role: role,
      content: content,
      metadata: metadata
    }
  end

  @doc """
  Converts a message to the format expected by LLM providers.

  ## Examples

      iex> message = Strider.Message.new(:user, "Hello!")
      iex> Strider.Message.to_provider_format(message)
      %{role: "user", content: "Hello!"}

  """
  @spec to_provider_format(t()) :: map()
  def to_provider_format(%__MODULE__{role: role, content: content}) do
    %{role: to_string(role), content: content}
  end
end
