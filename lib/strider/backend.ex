defmodule Strider.Backend do
  @moduledoc """
  Behaviour for LLM backend implementations.

  Backends are responsible for communicating with LLM APIs and returning
  responses as `Strider.Response` structs. This normalization ensures your
  agent loop code works regardless of which provider you're using.

  ## Implementing a Backend

      defmodule MyBackend do
        @behaviour Strider.Backend

        @impl true
        def call(config, messages, opts) do
          # Make API call and return Response
          {:ok, Strider.Response.new(content: "Hello!", finish_reason: :stop)}
        end

        @impl true
        def stream(config, messages, opts) do
          stream = Stream.map(["Hello", " ", "world!"], fn chunk ->
            %{content: chunk}
          end)
          {:ok, stream}
        end
      end

  ## Structured Output

  Backends can support structured output via the `:output_schema` option.
  When provided, the backend should:

  1. Include the JSON schema in the prompt/request
  2. Parse the response according to the schema
  3. Return structured data in `response.content`

  Example with structured output (requires `:strider_schema` dep):

      alias StriderSchema.Zoi, as: Schema

      output_schema = Schema.object(%{
        name: Schema.string(),
        age: Schema.integer()
      })

      {:ok, response, context} = Strider.call(agent, prompt, context,
        output_schema: output_schema
      )

      response.content
      # => %{name: "Alice", age: 30}

  ## Required Callbacks

  - `call/3` - Synchronous call to the LLM
  - `stream/3` - Streaming call that returns an enumerable

  ## Optional Callbacks

  - `introspect/0` - Returns metadata about the backend

  """

  alias Strider.Response

  @type config :: map()
  @type messages :: [map()]
  @type opts :: keyword()
  @type chunk :: %{content: term(), metadata: map()}
  @type error :: {:error, term()}

  @doc """
  Makes a synchronous call to the LLM.

  ## Parameters

  - `config` - Backend configuration (model, API keys, etc.)
  - `messages` - List of messages in provider format
  - `opts` - Additional options:
    - `:output_schema` - Schema for structured output validation

  ## Returns

  - `{:ok, response}` with a `Strider.Response` struct
  - `{:error, reason}` on failure

  """
  @callback call(config(), messages(), opts()) :: {:ok, Response.t()} | error()

  @doc """
  Makes a streaming call to the LLM.

  ## Parameters

  - `config` - Backend configuration
  - `messages` - List of messages in provider format
  - `opts` - Additional options

  ## Returns

  - `{:ok, stream}` where stream is an enumerable of chunks
  - `{:error, reason}` on failure

  Note: Streaming typically returns text chunks. For structured output
  with streaming, the full response must be accumulated and parsed.

  """
  @callback stream(config(), messages(), opts()) :: {:ok, Enumerable.t()} | error()

  @typedoc """
  Metadata returned by introspect/0 for observability.

  These align with OpenTelemetry GenAI semantic conventions.
  """
  @type operation :: :chat | :embeddings | :completion | atom()

  @type introspection :: %{
          :provider => String.t(),
          :model => String.t(),
          :operation => operation(),
          optional(atom()) => term()
        }

  @doc """
  Returns metadata about the backend configuration.

  Used by telemetry/tracing to identify provider and model without
  parsing backend config. Aligns with OpenTelemetry GenAI conventions.

  ## Expected Keys

  - `:provider` - Provider name ("anthropic", "openai", "google", etc.)
  - `:model` - Configured model identifier
  - `:operation` - Operation type ("chat", "embeddings", etc.)

  ## Example

      @impl true
      def introspect do
        %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514",
          operation: :chat
        }
      end

  """
  @callback introspect() :: introspection()

  @optional_callbacks [introspect: 0]
end
