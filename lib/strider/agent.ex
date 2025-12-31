defmodule Strider.Agent do
  @moduledoc """
  Configuration struct for an AI agent.

  An agent encapsulates the configuration needed to interact with an LLM backend.

  ## Backend Specification

  The backend is specified as a tuple: `{backend_type, backend_config}` where:

  - `backend_type` is a backend module (e.g., `Strider.Backends.ReqLLM`) or a shortcut (`:mock`, `:req_llm`)
  - `backend_config` is backend-specific (model string, keyword list, etc.)

  ## Creating Agents

  There are two equivalent ways to create an agent:

      # Style 1: Tuple as first argument (clean)
      Strider.Agent.new({Strider.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})

      Strider.Agent.new({Strider.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
        system_prompt: "You are helpful."
      )

      # Style 2: Pure keyword config (explicit)
      Strider.Agent.new(
        backend: {Strider.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
        system_prompt: "You are helpful."
      )

  ## Backend Examples

      # Using :req_llm shortcut (requires :req_llm dep)
      Strider.Agent.new({:req_llm, "anthropic:claude-sonnet-4-5"})
      Strider.Agent.new({:req_llm, "openai:gpt-4"})
      Strider.Agent.new({:req_llm, "openrouter:anthropic/claude-sonnet-4-5"})

      # Or use the full module name
      Strider.Agent.new({Strider.Backends.ReqLLM, "amazon_bedrock:anthropic.claude-sonnet-4-5-20241022-v2:0"})

      # With BYOK (Bring Your Own Key)
      Strider.Agent.new({:req_llm, "anthropic:claude-sonnet-4-5", api_key: user_api_key})

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
  - `:top_p` - Nucleus sampling parameter (passed to backend)

  ## Hooks

  Hooks allow observability and custom processing at each stage of execution:

      agent = Strider.Agent.new({Strider.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
        hooks: MyApp.LLMHooks
      )

      # Multiple hooks (all get called in order)
      agent = Strider.Agent.new({Strider.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
        hooks: [Strider.Telemetry.Hooks, MyApp.LoggingHooks]
      )

  See `Strider.Hooks` for the full behaviour specification.

  """

  @type backend_type :: atom() | module()
  @type backend_config :: map()
  @type backend :: {backend_type(), backend_config()}

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
      %Strider.Agent{backend: {:mock, %{response: "Hello!"}}, system_prompt: nil, config: %{}}

      # With options
      iex> Strider.Agent.new({:mock, response: "Hi"}, system_prompt: "You are helpful.")
      %Strider.Agent{backend: {:mock, %{response: "Hi"}}, system_prompt: "You are helpful.", config: %{}}

      # Pure keyword style
      iex> Strider.Agent.new(backend: {:mock, response: "Test"}, system_prompt: "You are helpful.")
      %Strider.Agent{backend: {:mock, %{response: "Test"}}, system_prompt: "You are helpful.", config: %{}}

  """
  @spec new(backend() | keyword()) :: t()
  @spec new(backend(), keyword()) :: t()
  def new(backend_or_opts, opts \\ [])

  # Style 1: Tuple as first argument
  def new({backend_type, backend_config}, opts) when is_atom(backend_type) do
    build_agent({backend_type, normalize_backend_config(backend_config)}, opts)
  end

  def new({backend_type, model, backend_opts}, opts)
      when is_atom(backend_type) and is_binary(model) and is_list(backend_opts) do
    config = backend_opts |> Map.new() |> Map.put(:model, model)
    build_agent({backend_type, config}, opts)
  end

  # Style 2: Pure keyword config
  def new(opts, []) when is_list(opts) do
    backend = Keyword.fetch!(opts, :backend)
    rest_opts = Keyword.delete(opts, :backend)
    new(backend, rest_opts)
  end

  defp normalize_backend_config(config) when is_map(config), do: config
  defp normalize_backend_config(config) when is_list(config), do: Map.new(config)
  defp normalize_backend_config(model) when is_binary(model), do: %{model: model}

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

  defp resolve_backend_module(:mock), do: Strider.Backends.Mock
  defp resolve_backend_module(:req_llm), do: Strider.Backends.ReqLLM

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
      %{response: "Hello"}

  """
  @spec backend_config(t()) :: map()
  def backend_config(%__MODULE__{backend: {_, config}}) do
    config
  end

  @doc """
  Updates the agent's configuration.

  Use this to modify agent settings dynamically, such as adjusting temperature
  based on task complexity or changing max_tokens for different response lengths.

  Configuration set here is merged with backend config when making calls.

  ## Examples

      iex> agent = Strider.Agent.new({:mock, response: "Hello"})
      iex> agent = Strider.Agent.put_config(agent, :temperature, 0.5)
      iex> agent.config
      %{temperature: 0.5}

      # Adjust settings based on task
      agent = if complex_task? do
        Agent.put_config(agent, :temperature, 0.2)
      else
        Agent.put_config(agent, :temperature, 0.8)
      end

  """
  @spec put_config(t(), atom(), term()) :: t()
  def put_config(%__MODULE__{} = agent, key, value) do
    %{agent | config: Map.put(agent.config, key, value)}
  end

  @doc """
  Gets a configuration value from the agent.

  This retrieves values from the agent's config map, which includes
  options like temperature, max_tokens, and top_p passed during creation.

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
