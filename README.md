# Strider

An agent framework for Elixir.

## Why?

Agents are loops. A loop that calls an LLM, gets a response, and decides what to do next. Strider provides the primitives for building these loops.

## What Strider Does

- Unified interface for LLM calls across any backend
- Conversation context management
- Streaming support
- Extensible hooks for middleware-like transformations (caching, guardrails, logging)
- Telemetry integration for observability
- Prompt templates with Liquid syntax
- Schema validation for structured outputs
- Sandbox execution (Docker, Fly.io)
- HTTP proxy for forwarding LLM API requests

## What Strider Doesn't Do

Tool calling isn't built in. You decide how to parse responses and when to stop.

## Installation

```elixir
def deps do
  [
    {:strider, git: "https://github.com/bradleygolden/strider.git", ref: "4c61b4e"},
    {:plug, "~> 1.15"},      # optional, for Strider.Proxy
    {:req, "~> 0.5"},        # optional, for Strider.Sandbox.Adapters.Fly
    {:req_llm, "~> 1.0"},    # optional, for Strider.Backends.ReqLLM
    {:solid, "~> 0.15"},     # optional, for Strider.Prompt.Solid
    {:telemetry, "~> 1.2"},  # optional, for Strider.Telemetry
    {:zoi, "~> 0.7"}         # optional, for Strider.Schema.Zoi
  ]
end
```

## Usage

```elixir
agent = Strider.Agent.new({Strider.Backends.ReqLLM, "anthropic:claude-4-5-sonnet"},
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

### Hooks

Hooks enable middleware-like transformations at each stage of agent execution:

```elixir
defmodule MyApp.LoggingHooks do
  @behaviour Strider.Hooks

  @impl true
  def on_call_start(_agent, content, _context) do
    Logger.info("LLM call started")
    {:cont, content}  # pass through
  end

  @impl true
  def on_call_end(_agent, response, _context) do
    Logger.info("LLM call completed")
    {:cont, response}  # pass through
  end
end

# Use hooks
agent = Strider.Agent.new({Strider.Backends.ReqLLM, "anthropic:claude-4-5-sonnet"},
  hooks: MyApp.LoggingHooks
)
```

Hooks can:
- Transform content before LLM call (`on_call_start`)
- Transform messages at backend level (`on_backend_request`)
- Transform responses after LLM call (`on_backend_response`, `on_call_end`)
- Short-circuit with cached responses (`{:halt, response}`)
- Block requests with guardrails (`{:error, reason}`)

### BYOK (Bring Your Own Key)

Pass API keys at runtime for multi-tenant applications:

```elixir
agent = Strider.Agent.new({Strider.Backends.ReqLLM, "anthropic:claude-4-5-sonnet", api_key: user_api_key})
```

### Telemetry

```elixir
agent = Strider.Agent.new({Strider.Backends.ReqLLM, "anthropic:claude-4-5-sonnet"},
  hooks: Strider.Telemetry.Hooks
)
```

### Prompt Templates

```elixir
import Strider.Prompt.Sigils

prompt = ~P"Hello {{ name }}!"
{:ok, rendered} = Strider.Prompt.Solid.render(prompt, %{"name" => "Alice"})
```

### Schema Validation

```elixir
alias Strider.Schema.Zoi, as: Schema

schema = Schema.object(%{name: Schema.string(), age: Schema.integer()})
{:ok, result} = Schema.parse(schema, %{name: "Alice", age: 30})
```

### Sandbox Execution

```elixir
alias Strider.Sandbox.Adapters.Docker

{:ok, sandbox} = Strider.Sandbox.create({Docker, image: "node:22-slim"})
{:ok, result} = Strider.Sandbox.exec(sandbox, "node --version")

# File operations
:ok = Strider.Sandbox.write_file(sandbox, "/app/main.js", "console.log('hello')")
{:ok, content} = Strider.Sandbox.read_file(sandbox, "/app/main.js")

Strider.Sandbox.terminate(sandbox)
```

### HTTP Proxy

```elixir
# In your router
forward "/api/anthropic", Strider.Proxy,
  target: "https://api.anthropic.com",
  request_headers: [{"x-api-key", System.get_env("ANTHROPIC_API_KEY")}]
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

## Backends

- `Strider.Backends.ReqLLM` - Multi-provider backend via [ReqLLM](https://github.com/bradleygolden/req_llm) (requires `{:req_llm, "~> 1.0"}`)
- `Strider.Backends.Mock` - For testing

Write your own by implementing `Strider.Backend`.

## Ecosystem

| Package | Description | Status |
|---------|-------------|--------|
| `strider` | Core agent framework (Elixir) | Development |
| `strider-sandbox` | Sandbox runtime for Node.js containers (TypeScript) | Development |
| `strider_studio` | Real-time observability UI | Development |

Install the JS package via GitHub:

```json
"strider-sandbox": "github:bradleygolden/strider-sandbox#e841831"
```

**Status:**
- **Development** - API may change, not recommended for production
- **Alpha** - Feature-complete but API may change
- **Beta** - API stable, ready for production testing
- **Stable** - Production-ready

## License

Apache-2.0
