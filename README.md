# Strider

A simple Elixir library for calling LLMs.

Strider sits on top of libraries like [ReqLLM](https://github.com/bradleygolden/req_llm) and provides an agent layer - consistent interfaces for building loops that call LLMs. It doesn't replace these libraries, it builds on them.

## Why?

Agents are just loops. A loop that calls an LLM, gets a response, and decides what to do next.

## What Strider Does

- Unified interface for LLM calls across any backend
- Works with req_llm, langchain, baml_elixir, or whatever comes next
- Conversation context management
- Streaming support
- Telemetry

## What Strider Doesn't Do

Tool calling isn't built in. Start with a simple LLM call. Add tool calling when you need it.

## Installation

```elixir
def deps do
  [
    {:strider, "~> 0.1.0"}
  ]
end
```

## Usage

```elixir
agent = Strider.Agent.new({:req_llm, "anthropic:claude-4-5-sonnet"},
  system_prompt: "You are a helpful assistant."
)

context = Strider.Context.new()
{:ok, response, context} = Strider.call(agent, "Hello!", context)

IO.puts(response.content)
```

### Multi-Turn Conversations

Context carries the conversation history:

```elixir
context = Strider.Context.new()

{:ok, _response, context} = Strider.call(agent, "My name is Alice.", context)
{:ok, response, _context} = Strider.call(agent, "What's my name?", context)
```

### Streaming

```elixir
{:ok, stream, context} = Strider.stream(agent, "Tell me a story", context)

Enum.each(stream, fn chunk ->
  IO.write(chunk.content)
end)
```

### Providers

The model uses `"provider:model"` format:

```elixir
"anthropic:claude-4-5-sonnet"
"openai:gpt-4"
"openrouter:anthropic/claude-4-5-sonnet"
"amazon_bedrock:anthropic.claude-4-5-sonnet-20241022-v2:0"
```

### BYOK (Bring Your Own Key)

Pass API keys at runtime for multi-tenant applications:

```elixir
agent = Strider.Agent.new({:req_llm, "anthropic:claude-4-5-sonnet", api_key: user_api_key})
```

## The Loop

An agent loop is a recursive function:

```elixir
defmodule MyAgent do
  def run(agent, prompt, context \\ Strider.Context.new(), max_turns \\ 10)

  def run(_agent, _prompt, context, 0), do: {:error, :max_turns_exceeded, context}

  def run(agent, prompt, context, turns_left) do
    case Strider.call(agent, prompt, context) do
      {:ok, response, context} ->
        case response.finish_reason do
          :stop ->
            {:ok, response.content, context}

          :tool_use ->
            result = execute_tools(response.tool_calls)
            run(agent, "Tool result: #{result}", context, turns_left - 1)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_tools(tool_calls) do
    # Your logic here
  end
end
```

Tool calling lives in your code. You decide how to parse responses and when to stop.

## Backends

- `:req_llm` - Uses [ReqLLM](https://github.com/bradleygolden/req_llm)
- `:mock` - For testing

Write your own by implementing `Strider.Backend`.

## Philosophy

Built from experience shipping AI code to production. Simple loops with escape hatches.

## License

MIT
