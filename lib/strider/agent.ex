defmodule Strider.Agent do
  @moduledoc """
  Configuration struct for an AI agent.

  An agent encapsulates the configuration needed to interact with an LLM backend.

  ## Backend Specification

  The backend is specified as a tuple: `{backend_type, backend_config}` where:

  - `backend_type` is an atom (`:mock`) or a backend module (e.g., `StriderReqLLM`)
  - `backend_config` is backend-specific (model string, keyword list, etc.)

  ## Creating Agents

  There are two equivalent ways to create an agent:

      # Style 1: Tuple as first argument (clean)
      Strider.Agent.new({StriderReqLLM, "anthropic:claude-4-5-sonnet"})

      Strider.Agent.new({StriderReqLLM, "anthropic:claude-4-5-sonnet"},
        system_prompt: "You are helpful."
      )

      # Style 2: Pure keyword config (explicit)
      Strider.Agent.new(
        backend: {StriderReqLLM, "anthropic:claude-4-5-sonnet"},
        system_prompt: "You are helpful."
      )

  ## Backend Examples

      # StriderReqLLM with different providers (requires :strider_req_llm dep)
      Strider.Agent.new({StriderReqLLM, "anthropic:claude-4-5-sonnet"})
      Strider.Agent.new({StriderReqLLM, "openai:gpt-4"})
      Strider.Agent.new({StriderReqLLM, "openrouter:anthropic/claude-4-5-sonnet"})
      Strider.Agent.new({StriderReqLLM, "amazon_bedrock:anthropic.claude-4-5-sonnet-20241022-v2:0"})

      # With BYOK (Bring Your Own Key)
      Strider.Agent.new({StriderReqLLM, "anthropic:claude-4-5-sonnet", api_key: user_api_key})

      # Mock backend for testing
      Strider.Agent.new({:mock, response: "Hello!"})

      # Custom backend module
      Strider.Agent.new({MyApp.CustomBackend, endpoint: "http://localhost:8000"})

  ## Configuration Options

  Options can be passed as the second argument or in keyword style:

  - `:system_prompt` - The system prompt for conversations
  - `:hooks` - Hook module(s) for lifecycle events (see `Strider.Hooks`)
  - `:temperature` - Sampling temperature (passed to backend)
  - `:max_tokens` - Maximum tokens in response (passed to backend)

  ## Hooks

  Hooks allow observability and custom processing at each stage of execution:

      agent = Strider.Agent.new({StriderReqLLM, "anthropic:claude-4-5-sonnet"},
        hooks: MyApp.LLMHooks
      )

      # Multiple hooks (all get called in order)
      agent = Strider.Agent.new({StriderReqLLM, "anthropic:claude-4-5-sonnet"},
        hooks: [StriderTelemetry.Hooks, MyApp.LoggingHooks]
      )

  See `Strider.Hooks` for the full behaviour specification.

  """

  @type backend_type :: atom() | module()
  @type backend_config :: term()
  @type backend ::
          {backend_type(), backend_config()} | {backend_type(), backend_config(), keyword()}

  @type hooks :: module() | [module()] | nil

  @type t :: %__MODULE__{
          backend: backend(),
          system_prompt: String.t() | nil,
          hooks: hooks(),
          config: map()
        }

  @enforce_keys [:backend]
  defstruct [:backend, :system_prompt, :hooks, config: %{}]

  @doc """
  Creates a new agent.

  Accepts either a backend tuple as the first argument with optional keyword options,
  or a pure keyword list with a `:backend` key.

  ## Examples

      # Mock backend (built-in)
      iex> Strider.Agent.new({:mock, response: "Hello!"})
      %Strider.Agent{backend: {:mock, [response: "Hello!"]}, system_prompt: nil, config: %{}}

      # With options
      iex> Strider.Agent.new({:mock, response: "Hi"}, system_prompt: "You are helpful.")
      %Strider.Agent{backend: {:mock, [response: "Hi"]}, system_prompt: "You are helpful.", config: %{}}

      # Pure keyword style
      iex> Strider.Agent.new(backend: {:mock, response: "Test"}, system_prompt: "You are helpful.")
      %Strider.Agent{backend: {:mock, [response: "Test"]}, system_prompt: "You are helpful.", config: %{}}

  """
  @spec new(backend() | keyword()) :: t()
  @spec new(backend(), keyword()) :: t()
  def new(backend_or_opts, opts \\ [])

  # Style 1: Tuple as first argument
  def new({backend_type, backend_config}, opts) when is_atom(backend_type) do
    build_agent({backend_type, backend_config}, opts)
  end

  def new({backend_type, backend_config, backend_opts}, opts)
      when is_atom(backend_type) and is_list(backend_opts) do
    build_agent({backend_type, backend_config, backend_opts}, opts)
  end

  # Style 2: Pure keyword config
  def new(opts, []) when is_list(opts) do
    backend = Keyword.fetch!(opts, :backend)
    rest_opts = Keyword.delete(opts, :backend)
    build_agent(backend, rest_opts)
  end

  defp build_agent(backend, opts) do
    {config_opts, agent_opts} = split_config_opts(opts)

    %__MODULE__{
      backend: backend,
      system_prompt: Keyword.get(agent_opts, :system_prompt),
      hooks: Keyword.get(agent_opts, :hooks),
      config: Map.new(config_opts)
    }
  end

  # Split options into config (temperature, max_tokens, etc.) and agent-level (system_prompt, hooks)
  @agent_keys [:system_prompt, :hooks]

  defp split_config_opts(opts) do
    Enum.split_with(opts, fn {key, _} -> key not in @agent_keys end)
  end

  @doc """
  Returns the backend module for this agent.

  Maps backend atoms to their implementing modules. If the backend type
  is already a module, returns it directly.

  ## Examples

      iex> agent = Strider.Agent.new({:mock, response: "Hello"})
      iex> Strider.Agent.backend_module(agent)
      Strider.Backends.Mock

  """
  @spec backend_module(t()) :: module()
  def backend_module(%__MODULE__{backend: {backend_type, _}}) do
    resolve_backend_module(backend_type)
  end

  def backend_module(%__MODULE__{backend: {backend_type, _, _}}) do
    resolve_backend_module(backend_type)
  end

  defp resolve_backend_module(:mock), do: Strider.Backends.Mock

  defp resolve_backend_module(module) when is_atom(module) do
    # Check if it's a module (has module info) or unknown atom
    if Code.ensure_loaded?(module) and function_exported?(module, :call, 3) do
      module
    else
      raise ArgumentError, "Unknown backend: #{inspect(module)}"
    end
  end

  @doc """
  Returns the backend config for this agent.

  ## Examples

      iex> agent = Strider.Agent.new({:mock, response: "Hello"})
      iex> Strider.Agent.backend_config(agent)
      [response: "Hello"]

  """
  @spec backend_config(t()) :: term()
  def backend_config(%__MODULE__{backend: {_, config}}) do
    config
  end

  def backend_config(%__MODULE__{backend: {_, config, opts}}) do
    {config, opts}
  end

  @doc """
  Updates the agent's configuration.

  ## Examples

      iex> agent = Strider.Agent.new({:mock, response: "Hello"})
      iex> agent = Strider.Agent.put_config(agent, :temperature, 0.5)
      iex> agent.config
      %{temperature: 0.5}

  """
  @spec put_config(t(), atom(), term()) :: t()
  def put_config(%__MODULE__{} = agent, key, value) do
    %{agent | config: Map.put(agent.config, key, value)}
  end

  @doc """
  Gets a configuration value from the agent.

  ## Examples

      iex> agent = Strider.Agent.new({:mock, response: "Hello"}, temperature: 0.7)
      iex> Strider.Agent.get_config(agent, :temperature)
      0.7

      iex> Strider.Agent.get_config(agent, :missing, 1.0)
      1.0

  """
  @spec get_config(t(), atom(), term()) :: term()
  def get_config(%__MODULE__{config: config}, key, default \\ nil) do
    Map.get(config, key, default)
  end
end
