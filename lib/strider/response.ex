defmodule Strider.Response do
  @moduledoc """
  A consistent response struct for LLM outputs.

  Every backend returns a `Strider.Response`, ensuring your agent loop code
  works regardless of which provider you're using.

  ## Why This Matters

  Without a consistent response shape, your loop code becomes backend-specific:

      # Without Response struct - backend-specific code
      case response do
        %{"choices" => [%{"message" => msg} | _]} -> msg["content"]  # OpenAI
        %{"content" => [%{"text" => text} | _]} -> text               # Anthropic
      end

  With Response, it's always the same:

      # With Response struct - works with any backend
      response.content

  ## Structure

  - `content` - The response content (text, structured data, or multi-modal parts)
  - `tool_calls` - List of tool calls requested by the model (if any)
  - `finish_reason` - Why the model stopped (`:stop`, `:tool_use`, `:max_tokens`, etc.)
  - `usage` - Token usage information
  - `metadata` - Backend-specific data (model name, raw response, etc.)

  ## Metadata

  Backends should populate these standardized metadata keys when available:

  - `:response_id` - Provider's unique response identifier
  - `:model` - Actual model used (may differ from requested)
  - `:provider` - Provider name ("anthropic", "openai", etc.)
  - `:latency_ms` - Request latency in milliseconds

  These align with OpenTelemetry GenAI semantic conventions for observability.

  ## Tool Calls

  When the model wants to call tools, `tool_calls` will be populated:

      %Strider.Response{
        content: nil,
        finish_reason: :tool_use,
        tool_calls: [
          %{
            id: "call_abc123",
            name: "search",
            arguments: %{"query" => "elixir agents"}
          }
        ]
      }

  Your loop can pattern match on this:

      case response.finish_reason do
        :stop -> {:done, response.content}
        :tool_use -> {:tool_calls, response.tool_calls}
        :max_tokens -> {:error, :truncated}
      end

  """

  @type tool_call :: %{
          id: String.t(),
          name: String.t(),
          arguments: map()
        }

  @type usage :: %{
          optional(:input_tokens) => non_neg_integer(),
          optional(:output_tokens) => non_neg_integer(),
          optional(:total_tokens) => non_neg_integer()
        }

  @type finish_reason ::
          :stop
          | :tool_use
          | :max_tokens
          | :content_filter
          | :error
          | atom()

  @typedoc """
  Standardized metadata keys for observability.

  These align with OpenTelemetry GenAI semantic conventions.
  """
  @type metadata :: %{
          optional(:response_id) => String.t(),
          optional(:model) => String.t(),
          optional(:provider) => String.t(),
          optional(:latency_ms) => non_neg_integer(),
          optional(atom()) => term()
        }

  @type t :: %__MODULE__{
          content: term(),
          tool_calls: [tool_call()],
          finish_reason: finish_reason() | nil,
          usage: usage(),
          metadata: metadata()
        }

  defstruct content: nil,
            tool_calls: [],
            finish_reason: nil,
            usage: %{},
            metadata: %{}

  @doc """
  Creates a new response with the given attributes.

  ## Examples

      iex> Strider.Response.new(content: "Hello!")
      %Strider.Response{content: "Hello!", tool_calls: [], finish_reason: nil, usage: %{}, metadata: %{}}

      iex> Strider.Response.new(
      ...>   content: nil,
      ...>   finish_reason: :tool_use,
      ...>   tool_calls: [%{id: "1", name: "search", arguments: %{}}]
      ...> )
      %Strider.Response{content: nil, finish_reason: :tool_use, tool_calls: [%{id: "1", name: "search", arguments: %{}}], usage: %{}, metadata: %{}}

  """
  @spec new(keyword()) :: t()
  def new(attrs \\ []) do
    struct(__MODULE__, attrs)
  end

  @doc """
  Returns true if this response contains tool calls.

  ## Examples

      iex> response = Strider.Response.new(tool_calls: [%{id: "1", name: "search", arguments: %{}}])
      iex> Strider.Response.has_tool_calls?(response)
      true

      iex> response = Strider.Response.new(content: "Hello!")
      iex> Strider.Response.has_tool_calls?(response)
      false

  """
  @spec has_tool_calls?(t()) :: boolean()
  def has_tool_calls?(%__MODULE__{tool_calls: tool_calls}) do
    tool_calls != []
  end

  @doc """
  Returns true if this response is complete (stopped naturally).

  ## Examples

      iex> response = Strider.Response.new(finish_reason: :stop)
      iex> Strider.Response.complete?(response)
      true

      iex> response = Strider.Response.new(finish_reason: :tool_use)
      iex> Strider.Response.complete?(response)
      false

  """
  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{finish_reason: :stop}), do: true
  def complete?(%__MODULE__{finish_reason: :end_turn}), do: true
  def complete?(%__MODULE__{}), do: false

  @doc """
  Gets the total token count from usage, if available.

  ## Examples

      iex> response = Strider.Response.new(usage: %{input_tokens: 10, output_tokens: 20})
      iex> Strider.Response.total_tokens(response)
      30

      iex> response = Strider.Response.new(usage: %{total_tokens: 50})
      iex> Strider.Response.total_tokens(response)
      50

      iex> response = Strider.Response.new()
      iex> Strider.Response.total_tokens(response)
      nil

  """
  @spec total_tokens(t()) :: non_neg_integer() | nil
  def total_tokens(%__MODULE__{usage: %{total_tokens: total}}), do: total

  def total_tokens(%__MODULE__{usage: usage}) do
    input = Map.get(usage, :input_tokens, 0)
    output = Map.get(usage, :output_tokens, 0)

    if input == 0 and output == 0 do
      nil
    else
      input + output
    end
  end
end
