defmodule Strider do
  @moduledoc """
  Strider - An AI agent framework for Elixir.

  ## Quick Start

      # Simple call (requires :req_llm dep)
      {:ok, response, _ctx} = Strider.call("Hello!", model: "anthropic:claude-sonnet-4-5")

      # Or create an agent explicitly
      agent = Strider.Agent.new({Strider.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
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
  - `Strider.Content` - Multi-modal content (text, images, files, audio, video)
  - `Strider.Message` - Individual message in a conversation
  - `Strider.Backend` - Behaviour for LLM backend implementations
  - `Strider.Hooks` - Behaviour for lifecycle event hooks
  - `Strider.Response` - Normalized response struct with content, tool_calls, finish_reason

  ## Optional Packages

  - `:req_llm` - Multi-provider LLM backend (enables `Strider.Backends.ReqLLM`)
  - `:solid` - Prompt templates with Liquid syntax (enables `Strider.Prompt.Solid`)
  - `:telemetry` - Telemetry integration for observability
  - `:zoi` - Schema validation for structured outputs

  """

  alias Strider.{Agent, Context, Response, Runtime}

  @agent_opts [:system_prompt, :hooks, :temperature, :max_tokens, :top_p]

  @doc """
  Calls an LLM and returns the response.

  ## Variants

  - `call(content, opts)` - Simple call with just content and options (requires `:model`)
  - `call(agent, content)` - Call with agent, creates fresh context
  - `call(agent, content, context)` - Full call with agent and context
  - `call(agent, content, context, opts)` - Full call with options

  ## Returns

  - `{:ok, response, updated_context}` on success
  - `{:error, reason}` on failure

  ## Examples

      # Simple call (no agent needed)
      {:ok, response, _ctx} = Strider.call("Hello!", model: "anthropic:claude-sonnet-4-5")

      # With system prompt
      {:ok, response, _ctx} = Strider.call("Translate to Spanish",
        model: "anthropic:claude-sonnet-4-5",
        system_prompt: "You are a translator."
      )

      # Multi-modal content (use Strider.Content)
      alias Strider.Content
      {:ok, response, _ctx} = Strider.call([
        Content.text("What's in this image?"),
        Content.image_url("https://example.com/cat.png")
      ], model: "anthropic:claude-sonnet-4-5")

      # Messages/conversation history (few-shot, context)
      {:ok, response, _ctx} = Strider.call([
        %{role: :user, content: "Translate: Hello"},
        %{role: :assistant, content: "Hola"},
        %{role: :user, content: "Translate: Goodbye"}
      ], model: "anthropic:claude-sonnet-4-5")

      # Multi-modal content in messages (role + images)
      alias Strider.Content
      {:ok, response, _ctx} = Strider.call([
        %{role: :user, content: [Content.text("What's this?"), Content.image_url("https://example.com/cat.png")]},
        %{role: :assistant, content: "I see a cat."},
        %{role: :user, content: "What color is it?"}
      ], model: "anthropic:claude-sonnet-4-5")

      # With explicit agent (no context)
      agent = Strider.Agent.new({:mock, response: "Hello!"})
      {:ok, response, _ctx} = Strider.call(agent, "Hello!")

      # Full explicit call
      context = Strider.Context.new()
      {:ok, response, context} = Strider.call(agent, "Hello!", context)

  """
  @spec call(Agent.t(), term()) :: {:ok, Response.t(), Context.t()} | {:error, term()}
  def call(%Agent{} = agent, content) do
    {context, final_content} = build_context_from_content(content)
    Runtime.call(agent, final_content, context, [])
  end

  @spec call(term(), keyword()) :: {:ok, Response.t(), Context.t()} | {:error, term()}
  def call(content, opts) when is_list(opts) do
    model = Keyword.fetch!(opts, :model)
    {agent_opts, call_opts} = Keyword.split(opts, @agent_opts)
    {base_context, call_opts} = Keyword.pop(call_opts, :context, Context.new())
    {backend, call_opts} = Keyword.pop(call_opts, :backend, default_backend())

    agent = Agent.new({backend, model}, agent_opts)
    {context, final_content} = build_context_from_content(content, base_context)

    Runtime.call(agent, final_content, context, call_opts)
  end

  @spec call(Agent.t(), term(), Context.t(), keyword()) ::
          {:ok, Response.t(), Context.t()} | {:error, term()}
  def call(%Agent{} = agent, content, %Context{} = context, opts \\ []) do
    Runtime.call(agent, content, context, opts)
  end

  @doc """
  Streams an LLM response.

  ## Variants

  - `stream(content, opts)` - Simple stream with just content and options (requires `:model`)
  - `stream(agent, content)` - Stream with agent, creates fresh context
  - `stream(agent, content, context)` - Full stream with agent and context
  - `stream(agent, content, context, opts)` - Full stream with options

  ## Returns

  - `{:ok, stream, updated_context}` where stream is an `Enumerable` of chunks
  - `{:error, reason}` on failure

  ## Examples

      # Simple stream (no agent needed)
      {:ok, stream, _ctx} = Strider.stream("Tell me a story", model: "anthropic:claude-sonnet-4-5")
      Enum.each(stream, fn chunk -> IO.write(chunk.content) end)

      # With explicit agent (no context)
      agent = Strider.Agent.new({:mock, stream_chunks: ["Hello", " ", "world"]})
      {:ok, stream, _ctx} = Strider.stream(agent, "Tell me a story")

      # Full explicit call
      context = Strider.Context.new()
      {:ok, stream, _context} = Strider.stream(agent, "Tell me a story", context)

  """
  @spec stream(Agent.t(), term()) :: {:ok, Enumerable.t(), Context.t()} | {:error, term()}
  def stream(%Agent{} = agent, content) do
    {context, final_content} = build_context_from_content(content)
    Runtime.stream(agent, final_content, context, [])
  end

  @spec stream(term(), keyword()) :: {:ok, Enumerable.t(), Context.t()} | {:error, term()}
  def stream(content, opts) when is_list(opts) do
    model = Keyword.fetch!(opts, :model)
    {agent_opts, call_opts} = Keyword.split(opts, @agent_opts)
    {base_context, call_opts} = Keyword.pop(call_opts, :context, Context.new())
    {backend, call_opts} = Keyword.pop(call_opts, :backend, default_backend())

    agent = Agent.new({backend, model}, agent_opts)
    {context, final_content} = build_context_from_content(content, base_context)

    Runtime.stream(agent, final_content, context, call_opts)
  end

  @spec stream(Agent.t(), term(), Context.t(), keyword()) ::
          {:ok, Enumerable.t(), Context.t()} | {:error, term()}
  def stream(%Agent{} = agent, content, %Context{} = context, opts \\ []) do
    Runtime.stream(agent, content, context, opts)
  end

  # Detect messages format (has :role key) and build context from conversation history
  defp build_context_from_content(content, base_context \\ Context.new())

  defp build_context_from_content([%{role: _} | _] = messages, base_context) do
    {history, [last]} = Enum.split(messages, -1)

    context =
      Enum.reduce(history, base_context, fn msg, ctx ->
        Context.add_message(ctx, msg.role, msg.content)
      end)

    {context, last.content}
  end

  defp build_context_from_content(content, base_context) do
    {base_context, content}
  end

  defp default_backend do
    case Application.get_env(:strider, :default_backend) do
      nil ->
        if Code.ensure_loaded?(Strider.Backends.ReqLLM) do
          Strider.Backends.ReqLLM
        else
          raise ArgumentError,
                "No backend available. Add {:req_llm, \"~> 1.0\"} to deps or configure :default_backend."
        end

      backend ->
        backend
    end
  end
end
