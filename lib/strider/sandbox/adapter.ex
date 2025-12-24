defmodule Strider.Sandbox.Adapter do
  @moduledoc """
  Behaviour for sandbox adapters.

  Adapters implement the actual sandbox creation and management for different
  backends (Docker, E2B, Fly Machines, etc.).

  ## Required Callbacks

  - `create/1` - Create a new sandbox, return its ID
  - `exec/3` - Execute a command in the sandbox
  - `terminate/1` - Stop and cleanup the sandbox
  - `status/1` - Get the current sandbox status

  ## Optional Callbacks

  - `get_url/2` - Get URL for an exposed port

  ## Example

      defmodule MyAdapter do
        @behaviour Strider.Sandbox.Adapter

        @impl true
        def create(config) do
          # Create sandbox, return {:ok, sandbox_id} or {:error, reason}
        end

        @impl true
        def exec(sandbox_id, command, opts) do
          # Execute command, return {:ok, %ExecResult{}} or {:error, reason}
        end

        @impl true
        def terminate(sandbox_id) do
          # Cleanup sandbox, return :ok or {:error, reason}
        end

        @impl true
        def status(sandbox_id) do
          # Return :running | :stopped | :terminated | :unknown
        end
      end
  """

  alias Strider.Sandbox.ExecResult

  @type config :: map()
  @type sandbox_id :: String.t()
  @type command :: String.t()
  @type opts :: keyword()

  @doc """
  Creates a new sandbox with the given configuration.

  Returns `{:ok, sandbox_id}` on success or `{:error, reason}` on failure.
  """
  @callback create(config()) :: {:ok, sandbox_id()} | {:error, term()}

  @doc """
  Executes a command in the sandbox.

  Options may include:
  - `:timeout` - Command timeout in milliseconds
  - `:workdir` - Working directory for the command

  Returns `{:ok, %ExecResult{}}` on success or `{:error, reason}` on failure.
  """
  @callback exec(sandbox_id(), command(), opts()) :: {:ok, ExecResult.t()} | {:error, term()}

  @doc """
  Terminates and cleans up the sandbox.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @callback terminate(sandbox_id()) :: :ok | {:error, term()}

  @doc """
  Gets the current status of the sandbox.
  """
  @callback status(sandbox_id()) :: :running | :stopped | :terminated | :unknown

  @doc """
  Gets the URL for an exposed port on the sandbox.

  Optional callback - not all adapters support exposed ports.
  """
  @callback get_url(sandbox_id(), port :: integer()) :: {:ok, String.t()} | {:error, term()}

  @optional_callbacks [get_url: 2]
end
