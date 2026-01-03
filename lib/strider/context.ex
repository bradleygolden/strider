defmodule Strider.Context do
  @moduledoc """
  Manages conversation context including message history and metadata.

  The context holds the conversation state between calls to an agent,
  allowing for multi-turn conversations.

  ## Examples

      # Create a new context
      context = Strider.Context.new()

      # Add messages
      context = context
        |> Strider.Context.add_message(:user, "Hello!")
        |> Strider.Context.add_message(:assistant, "Hi there!")

      # Get messages
      messages = Strider.Context.messages(context)

  """

  alias Strider.Content.Part
  alias Strider.Message

  @type t :: %__MODULE__{
          messages: [Message.t()],
          metadata: map(),
          usage: map()
        }

  defstruct messages: [], metadata: %{}, usage: %{input_tokens: 0, output_tokens: 0}

  @doc """
  Creates a new empty context.

  ## Examples

      iex> Strider.Context.new()
      %Strider.Context{messages: [], metadata: %{}}

      iex> Strider.Context.new(metadata: %{session_id: "abc123"})
      %Strider.Context{messages: [], metadata: %{session_id: "abc123"}}

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      messages: Keyword.get(opts, :messages, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Adds a message to the context.

  Content can be a string (wrapped automatically), a single Part, or a list of Parts.

  ## Examples

      iex> context = Strider.Context.new()
      iex> context = Strider.Context.add_message(context, :user, "Hello!")
      iex> length(context.messages)
      1

  """
  @spec add_message(t(), Message.role(), String.t() | Part.t() | [Part.t()], map()) :: t()
  def add_message(%__MODULE__{} = context, role, content, metadata \\ %{}) do
    message = Message.new(role, content, metadata)
    %{context | messages: context.messages ++ [message]}
  end

  @doc """
  Returns the messages in the context.

  ## Examples

      iex> context = Strider.Context.new()
      iex> context = Strider.Context.add_message(context, :user, "Hello!")
      iex> length(Strider.Context.messages(context))
      1

  """
  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{messages: messages}), do: messages

  @doc """
  Returns the last message in the context, or nil if empty.

  ## Examples

      iex> context = Strider.Context.new()
      iex> Strider.Context.last_message(context)
      nil

  """
  @spec last_message(t()) :: Message.t() | nil
  def last_message(%__MODULE__{messages: []}), do: nil
  def last_message(%__MODULE__{messages: messages}), do: List.last(messages)

  @doc """
  Returns the number of messages in the context.

  ## Examples

      iex> context = Strider.Context.new()
      iex> Strider.Context.message_count(context)
      0

  """
  @spec message_count(t()) :: non_neg_integer()
  def message_count(%__MODULE__{messages: messages}), do: length(messages)

  @doc """
  Updates the context metadata.

  ## Examples

      iex> context = Strider.Context.new()
      iex> context = Strider.Context.put_metadata(context, :session_id, "abc123")
      iex> context.metadata
      %{session_id: "abc123"}

  """
  @spec put_metadata(t(), atom(), term()) :: t()
  def put_metadata(%__MODULE__{} = context, key, value) do
    %{context | metadata: Map.put(context.metadata, key, value)}
  end

  @doc """
  Gets a value from the context metadata.

  ## Examples

      iex> context = Strider.Context.new(metadata: %{session_id: "abc123"})
      iex> Strider.Context.get_metadata(context, :session_id)
      "abc123"

      iex> Strider.Context.get_metadata(context, :missing)
      nil

  """
  @spec get_metadata(t(), atom(), term()) :: term()
  def get_metadata(%__MODULE__{metadata: metadata}, key, default \\ nil) do
    Map.get(metadata, key, default)
  end

  @doc """
  Clears all messages from the context, preserving metadata.

  Useful for starting a fresh conversation while keeping session information.

  ## Examples

      iex> context = Strider.Context.new(metadata: %{session_id: "abc123"})
      iex> context = Strider.Context.add_message(context, :user, "Hello!")
      iex> context = Strider.Context.clear(context)
      iex> {context.messages, context.metadata}
      {[], %{session_id: "abc123"}}

  """
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = context) do
    %{context | messages: []}
  end

  @doc """
  Returns the accumulated usage for the context.

  ## Examples

      iex> context = Strider.Context.new()
      iex> Strider.Context.usage(context)
      %{input_tokens: 0, output_tokens: 0}

  """
  @spec usage(t()) :: map()
  def usage(%__MODULE__{usage: usage}), do: usage

  @doc """
  Returns the total number of tokens used in the context.

  ## Examples

      iex> context = Strider.Context.new()
      iex> Strider.Context.total_tokens(context)
      0

  """
  @spec total_tokens(t()) :: non_neg_integer()
  def total_tokens(%__MODULE__{usage: usage}) do
    Map.get(usage, :input_tokens, 0) + Map.get(usage, :output_tokens, 0)
  end
end
