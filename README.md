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
- Sandbox execution with security-by-default (Docker, Fly.io)
- HTTP proxy for controlled network access with credential injection

## What Strider Doesn't Do

Tool calling isn't built in. You decide how to parse responses and when to stop.

## Installation

```elixir
def deps do
  [
    {:strider, github: "bradleygolden/strider"},
    {:ecto_sql, "~> 3.0"},   # optional, for Strider.Sandbox.Pool.Store.Postgres
    {:plug, "~> 1.15"},      # optional, for Strider.Proxy.Sandbox
    {:req, "~> 0.5"},        # optional, for Strider.Sandbox.Adapters.Fly
    {:req_llm, "~> 1.0"},    # optional, for Strider.Backends.ReqLLM
    {:solid, "~> 0.15"},     # optional, for Strider.Prompt.Solid
    {:telemetry, "~> 1.2"},  # optional, for Strider.Telemetry
    {:zoi, "~> 0.7"}         # optional, for Strider.Schema.Zoi
  ]
end
```

## Quick Start

The simplest way to call an LLM - just pass your prompt and model:

```elixir
{:ok, response, _ctx} = Strider.call("Hello!", model: "anthropic:claude-sonnet-4-5")

IO.puts(response.content)
# => "Hello! How can I help you today?"
```

Add a system prompt:

```elixir
{:ok, response, _ctx} = Strider.call("Translate: Hello",
  model: "anthropic:claude-sonnet-4-5",
  system_prompt: "You are a translator. Translate to Spanish."
)
# => "Hola"
```

Stream responses:

```elixir
{:ok, stream, _ctx} = Strider.stream("Tell me a story", model: "anthropic:claude-sonnet-4-5")

Enum.each(stream, fn chunk ->
  IO.write(chunk.content)
end)
```

That's it! No agent or context required for simple use cases.

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

## Multi-Modal Content

Use `Strider.Content` for images, files, audio, and other content types:

```elixir
alias Strider.Content

# Image from URL
{:ok, response, _ctx} = Strider.call([
  Content.text("What's in this image?"),
  Content.image_url("https://example.com/cat.png")
], model: "anthropic:claude-sonnet-4-5")

# Base64 image data
image_bytes = File.read!("photo.png")
{:ok, response, _ctx} = Strider.call([
  Content.text("Describe this photo"),
  Content.image(image_bytes, "image/png")
], model: "anthropic:claude-sonnet-4-5")

# PDF file
pdf_bytes = File.read!("report.pdf")
{:ok, response, _ctx} = Strider.call([
  Content.text("Summarize this document"),
  Content.file(pdf_bytes, "application/pdf", filename: "report.pdf")
], model: "anthropic:claude-sonnet-4-5")
```

Plain strings are automatically wrapped as text content.

## Multi-Turn Conversations

Pass conversation history directly as messages:

```elixir
{:ok, response, _ctx} = Strider.call([
  %{role: :user, content: "My name is Alice"},
  %{role: :assistant, content: "Nice to meet you, Alice!"},
  %{role: :user, content: "What's my name?"}
], model: "anthropic:claude-sonnet-4-5")

# => "Your name is Alice."
```

For stateful conversations across multiple calls, use the `:context` option:

```elixir
# First call - get back the context
{:ok, _response, context} = Strider.call("My name is Alice.",
  model: "anthropic:claude-sonnet-4-5"
)

# Second call - pass the context to continue the conversation
{:ok, response, _context} = Strider.call("What's my name?",
  model: "anthropic:claude-sonnet-4-5",
  context: context
)

# => "Your name is Alice."
```

You can also combine messages with an existing context - messages are appended:

```elixir
{:ok, response, context} = Strider.call([
  %{role: :user, content: "What's 2+2?"},
  %{role: :assistant, content: "4"},
  %{role: :user, content: "And what's that times 10?"}
], model: "anthropic:claude-sonnet-4-5", context: existing_context)
```

## Explicit Agents

For more control, create an agent explicitly:

```elixir
agent = Strider.Agent.new({Strider.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
  system_prompt: "You are a helpful assistant.",
  temperature: 0.7,
  max_tokens: 1000
)

context = Strider.Context.new()
{:ok, response, context} = Strider.call(agent, "Hello!", context)
```

Agents are useful when you want to:
- Reuse the same configuration across multiple calls
- Add hooks for logging, caching, or guardrails
- Use custom backends

## Hooks

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
agent = Strider.Agent.new({Strider.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
  hooks: MyApp.LoggingHooks
)
```

Hooks can:
- Transform content before LLM call (`on_call_start`)
- Transform messages at backend level (`on_backend_request`)
- Transform responses after LLM call (`on_backend_response`, `on_call_end`)
- Short-circuit with cached responses (`{:halt, response}`)
- Block requests with guardrails (`{:error, reason}`)

## BYOK (Bring Your Own Key)

Pass API keys at runtime for multi-tenant applications:

```elixir
agent = Strider.Agent.new({Strider.Backends.ReqLLM, "anthropic:claude-sonnet-4-5", api_key: user_api_key})
```

## Telemetry

```elixir
agent = Strider.Agent.new({Strider.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
  hooks: Strider.Telemetry.Hooks
)
```

## Prompt Templates

```elixir
import Strider.Prompt.Sigils

prompt = ~P"Hello {{ name }}!"
{:ok, rendered} = Strider.Prompt.Solid.render(prompt, %{"name" => "Alice"})
```

## Schema Validation

```elixir
alias Strider.Schema.Zoi, as: Schema

schema = Schema.object(%{name: Schema.string(), age: Schema.integer()})
{:ok, result} = Schema.parse(schema, %{name: "Alice", age: 30})
```

## Sandbox Execution

Sandboxes provide isolated code execution with **no network access by default**.

The default sandbox image (`ghcr.io/bradleygolden/strider-sandbox`) includes:
- **Python 3** and **Node.js** runtimes
- **Network isolation** via iptables (no outbound traffic)
- **Non-root execution** (runs as `sandbox` user)

```elixir
alias Strider.Sandbox
alias Strider.Sandbox.Adapters.Docker

# Uses default sandbox image - no network access
{:ok, sandbox} = Sandbox.create({Docker, %{}})
{:ok, result} = Sandbox.exec(sandbox, "python3 -c 'print(1+1)'")
{:ok, result} = Sandbox.exec(sandbox, "node -e 'console.log(1+1)'")

# Pin to a specific image version (recommended for production)
{:ok, sandbox} = Sandbox.create({Docker, %{
  image: "ghcr.io/bradleygolden/strider-sandbox:latest"
}})

# Use a custom image (note: no network isolation unless image supports it)
{:ok, sandbox} = Sandbox.create({Docker, %{image: "node:22-slim"}})

# File operations
:ok = Sandbox.write_file(sandbox, "/workspace/main.js", "console.log('hello')")
{:ok, content} = Sandbox.read_file(sandbox, "/workspace/main.js")

Sandbox.terminate(sandbox)
```

Enable controlled network access through a proxy (see [Sandbox Proxy](#sandbox-proxy) for setup):

```elixir
# Create sandbox with proxy access
{:ok, sandbox} = Sandbox.create({Docker, %{proxy: [ip: "172.17.0.1", port: 4000]}})
```

Fly.io adapter for production:

```elixir
alias Strider.Sandbox
alias Strider.Sandbox.Adapters.Fly

{:ok, sandbox} = Sandbox.create({Fly, %{
  app_name: "my-sandboxes",
  region: "ord",
  mounts: [%{name: "data", path: "/data", size_gb: 10}]
}})

Sandbox.await_ready(sandbox, port: 4001)
{:ok, result} = Sandbox.exec(sandbox, "node --version")
```

## Sandbox Pool

Pre-warm sandboxes for fast provisioning:

```elixir
alias Strider.Sandbox.Pool

{:ok, pool} = Pool.start_link(%{
  adapter: Fly,
  partitions: ["ord", "ewr"],
  target_per_partition: 2,
  build_config: fn partition -> %{app_name: "my-sandboxes", region: partition} end
})

case Pool.checkout(pool, "ord") do
  {:warm, sandbox_info} -> # ~10s start from pre-warmed volume
  {:cold, :pool_empty} -> # create from scratch
end
```

For distributed deployments, use the Postgres store:

```elixir
Pool.start_link(%{
  # ...
  store: Strider.Sandbox.Pool.Store.Postgres,
  store_config: %{repo: MyApp.Repo}
})
```

## Sandbox Proxy

A security-focused HTTP proxy for sandboxed environments with domain allowlisting and credential injection:

```elixir
# In your Phoenix router
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  forward "/proxy", Strider.Proxy.Sandbox,
    allowed_domains: ["api.anthropic.com", "api.github.com", "*.openai.com"],
    credentials: %{
      "api.anthropic.com" => [
        {"x-api-key", System.get_env("ANTHROPIC_API_KEY")},
        {"anthropic-version", "2023-06-01"}
      ],
      "api.github.com" => [
        {"authorization", "Bearer #{System.get_env("GITHUB_TOKEN")}"}
      ]
    }
end
```

Sandboxes send requests with the target URL in the path: `POST http://proxy:4000/proxy/https://api.anthropic.com/v1/messages`

## Backends

- `Strider.Backends.ReqLLM` - Multi-provider backend via [ReqLLM](https://github.com/bradleygolden/req_llm) (requires `{:req_llm, "~> 1.0"}`)
- `Strider.Backends.Mock` - For testing

Write your own by implementing `Strider.Backend`.

## Development

```bash
mix test                    # Excludes docker tests
mix test --include docker   # Runs docker integration tests
```

### Building the Sandbox Image

```bash
REF=$(git rev-parse --short HEAD)

# Multi-arch build (amd64 for Fly, arm64 for Mac)
docker buildx build --platform linux/amd64,linux/arm64 \
  -t ghcr.io/bradleygolden/strider-sandbox:$REF \
  -f priv/sandbox/Dockerfile priv/sandbox --push
```

## Ecosystem

| Package | Description | Status |
|---------|-------------|--------|
| `strider` | Core agent framework (Elixir) | Development |
| [`strider-sandbox`](https://github.com/bradleygolden/strider-sandbox) | Sandbox runtime for Node.js containers (TypeScript) | Development |
| `strider_studio` | Real-time observability UI | Roadmap |

Install the JS package via GitHub:

```json
"strider-sandbox": "github:bradleygolden/strider-sandbox"
```

**Status:**
- **Roadmap** - Planned, not yet started
- **Development** - API may change, not recommended for production
- **Alpha** - Feature-complete but API may change
- **Beta** - API stable, ready for production testing
- **Stable** - Production-ready

## License

Apache-2.0
