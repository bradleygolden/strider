defmodule Strider do
  @moduledoc """
  Strider - An ultra-lean Elixir framework for building AI agents.

  ## Quick Start

      # Create an agent with StriderReqLLM (requires :strider_req_llm dep)
      agent = Strider.Agent.new({StriderReqLLM, "anthropic:claude-4-5-sonnet"},
        system_prompt: "You are a helpful assistant."
      )

      # Call the agent
      context = Strider.Context.new()
      {:ok, response, context} = Strider.call(agent, "Hello!", context)

      # Stream responses
      {:ok, stream, context} = Strider.stream(agent, "Tell me a story", context)
      Enum.each(stream, fn chunk -> IO.write(chunk.content) end)

  ## Core Concepts

  - `Strider.Agent` - Configuration struct for an agent (backend, system prompt, hooks)
  - `Strider.Context` - Conversation history and metadata
  - `Strider.Backend` - Behaviour for LLM backend implementations
  - `Strider.Hooks` - Behaviour for lifecycle event hooks
  - `Strider.Response` - Normalized response struct with content, tool_calls, finish_reason
  - `Strider.Message` - Individual message in a conversation

  ## Optional Packages

  - `:strider_req_llm` - Multi-provider LLM backend via ReqLLM
  - `:strider_telemetry` - Telemetry hooks for observability
  - `:strider_schema` - Schema validation for structured outputs

  """

  alias Strider.{Agent, Context, Response, Runtime}

  @doc """
  Calls an agent with content and returns the response.

  ## Parameters

  - `agent` - A `Strider.Agent` struct
  - `content` - The user's message (string, multi-modal list, or any term)
  - `context` - A `Strider.Context` struct with conversation history
  - `opts` - Optional keyword list of options

  ## Returns

  - `{:ok, response, updated_context}` on success
  - `{:error, reason}` on failure

  ## Examples

      agent = Strider.Agent.new({:mock, response: "Hello!"})
      context = Strider.Context.new()

      {:ok, response, context} = Strider.call(agent, "Hello!", context)
      IO.puts(response.content)

      # Multi-modal content
      {:ok, response, context} = Strider.call(agent, [
        %{type: :text, text: "What's in this image?"},
        %{type: :image_url, url: "https://example.com/image.png"}
      ], context)

  """
  @spec call(Agent.t(), term(), Context.t(), keyword()) ::
          {:ok, Response.t(), Context.t()} | {:error, term()}
  def call(%Agent{} = agent, content, %Context{} = context, opts \\ []) do
    Runtime.call(agent, content, context, opts)
  end

  @doc """
  Streams an agent response for a given content.

  ## Parameters

  - `agent` - A `Strider.Agent` struct
  - `content` - The user's message (string, multi-modal list, or any term)
  - `context` - A `Strider.Context` struct with conversation history
  - `opts` - Optional keyword list of options

  ## Returns

  - `{:ok, stream, updated_context}` where stream is an `Enumerable` of chunks
  - `{:error, reason}` on failure

  ## Examples

      agent = Strider.Agent.new({:mock, stream_chunks: ["Hello", " ", "world"]})
      context = Strider.Context.new()

      {:ok, stream, _context} = Strider.stream(agent, "Tell me a story", context)
      Enum.each(stream, fn chunk ->
        IO.write(chunk.content)
      end)

  """
  @spec stream(Agent.t(), term(), Context.t(), keyword()) ::
          {:ok, Enumerable.t(), Context.t()} | {:error, term()}
  def stream(%Agent{} = agent, content, %Context{} = context, opts \\ []) do
    Runtime.stream(agent, content, context, opts)
  end
end
