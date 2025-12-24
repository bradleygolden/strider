defmodule Strider.Sandbox do
  @moduledoc """
  Minimal sandbox management library for isolated code execution.

  Strider.Sandbox provides a simple, struct-based API for creating and managing
  sandboxed execution environments. Inspired by E2B's simplicity and Modal's
  `from_id` pattern.

  ## Usage

      alias Strider.Sandbox.Adapters.Docker

      # Create a sandbox
      {:ok, sandbox} = Strider.Sandbox.create({Docker, image: "node:22-slim"})

      # Execute commands
      {:ok, result} = Strider.Sandbox.exec(sandbox, "node --version")
      IO.puts(result.stdout)

      # Cleanup
      :ok = Strider.Sandbox.terminate(sandbox)

  ## Adapters

  Strider.Sandbox uses an adapter pattern for different backends:

  - `Strider.Sandbox.Adapters.Docker` - Docker containers (local development)
  - `Strider.Sandbox.Adapters.Test` - In-memory testing adapter

  Custom adapters can be created by implementing the `Strider.Sandbox.Adapter` behaviour.
  """

  alias Strider.Sandbox.Instance

  @type backend :: {module(), map() | keyword()}

  @doc """
  Creates a new sandbox using the specified adapter and configuration.

  ## Examples

      {:ok, sandbox} = Strider.Sandbox.create({Docker, image: "node:22-slim"})

      {:ok, sandbox} = Strider.Sandbox.create({Docker, %{
        image: "node:22-slim",
        workdir: "/workspace",
        memory_mb: 2048
      }})
  """
  @spec create(backend()) :: {:ok, Instance.t()} | {:error, term()}
  def create({adapter_module, config}) when is_atom(adapter_module) do
    config_map = normalize_config(config)

    case adapter_module.create(config_map) do
      {:ok, sandbox_id} ->
        sandbox =
          Instance.new(%{
            id: sandbox_id,
            adapter: adapter_module,
            config: config_map
          })

        {:ok, sandbox}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Reconstructs a sandbox struct from an existing sandbox ID.

  Useful for resuming work with a container that was created elsewhere
  or persisted across sessions. Inspired by Modal's `Sandbox.from_id()`.

  ## Examples

      sandbox = Strider.Sandbox.from_id(Docker, "strider-sandbox-abc123")
      {:ok, result} = Strider.Sandbox.exec(sandbox, "echo 'still here'")
  """
  @spec from_id(module(), String.t(), map()) :: Instance.t()
  def from_id(adapter_module, sandbox_id, config \\ %{}) do
    Instance.new(%{
      id: sandbox_id,
      adapter: adapter_module,
      config: config
    })
  end

  @doc """
  Executes a command in the sandbox.

  ## Options

  - `:timeout` - Command timeout in milliseconds (default: 30_000)
  - `:workdir` - Working directory for the command

  ## Examples

      {:ok, result} = Strider.Sandbox.exec(sandbox, "node --version")
      IO.puts(result.stdout)

      # With timeout
      {:ok, result} = Strider.Sandbox.exec(sandbox, "npm install", timeout: 120_000)

      # File operations via exec
      {:ok, _} = Strider.Sandbox.exec(sandbox, "echo 'hello' > file.txt")
      {:ok, result} = Strider.Sandbox.exec(sandbox, "cat file.txt")
  """
  @spec exec(Instance.t(), String.t(), keyword()) ::
          {:ok, Strider.Sandbox.ExecResult.t()} | {:error, term()}
  def exec(%Instance{} = sandbox, command, opts \\ []) do
    sandbox.adapter.exec(sandbox.id, command, opts)
  end

  @doc """
  Terminates and cleans up the sandbox.

  ## Examples

      :ok = Strider.Sandbox.terminate(sandbox)
  """
  @spec terminate(Instance.t()) :: :ok | {:error, term()}
  def terminate(%Instance{} = sandbox) do
    sandbox.adapter.terminate(sandbox.id)
  end

  @doc """
  Gets the current status of the sandbox.

  ## Examples

      :running = Strider.Sandbox.status(sandbox)
  """
  @spec status(Instance.t()) :: :running | :stopped | :terminated | :unknown
  def status(%Instance{} = sandbox) do
    sandbox.adapter.status(sandbox.id)
  end

  @doc """
  Gets the URL for an exposed port on the sandbox.

  Useful for sandboxes running servers. This is an optional adapter callback -
  returns `{:error, :not_implemented}` if the adapter doesn't support it.

  ## Examples

      {:ok, url} = Strider.Sandbox.get_url(sandbox, 4000)
      # => "http://strider-sandbox-abc123:4000"
  """
  @spec get_url(Instance.t(), integer()) :: {:ok, String.t()} | {:error, term()}
  def get_url(%Instance{} = sandbox, port) do
    if function_exported?(sandbox.adapter, :get_url, 2) do
      sandbox.adapter.get_url(sandbox.id, port)
    else
      {:error, :not_implemented}
    end
  end

  @doc """
  Reads a file from the sandbox.

  ## Examples

      {:ok, content} = Strider.Sandbox.read_file(sandbox, "/app/code.py")
  """
  @spec read_file(Instance.t(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def read_file(%Instance{} = sandbox, path, opts \\ []) do
    if function_exported?(sandbox.adapter, :read_file, 3) do
      sandbox.adapter.read_file(sandbox.id, path, opts)
    else
      {:error, :not_implemented}
    end
  end

  @doc """
  Writes a file to the sandbox.

  ## Examples

      :ok = Strider.Sandbox.write_file(sandbox, "/app/code.py", "print('hello')")
  """
  @spec write_file(Instance.t(), String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def write_file(%Instance{} = sandbox, path, content, opts \\ []) do
    if function_exported?(sandbox.adapter, :write_file, 4) do
      sandbox.adapter.write_file(sandbox.id, path, content, opts)
    else
      {:error, :not_implemented}
    end
  end

  @doc """
  Writes multiple files to the sandbox.

  ## Examples

      :ok = Strider.Sandbox.write_files(sandbox, [
        {"/app/main.py", "import lib"},
        {"/app/lib.py", "def foo(): pass"}
      ])
  """
  @spec write_files(Instance.t(), [{String.t(), binary()}], keyword()) :: :ok | {:error, term()}
  def write_files(%Instance{} = sandbox, files, opts \\ []) do
    if function_exported?(sandbox.adapter, :write_files, 3) do
      sandbox.adapter.write_files(sandbox.id, files, opts)
    else
      write_files_sequentially(sandbox, files, opts)
    end
  end

  defp write_files_sequentially(sandbox, files, opts) do
    Enum.reduce_while(files, :ok, fn {path, content}, :ok ->
      case write_file(sandbox, path, content, opts) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp normalize_config(config) when is_map(config), do: config
  defp normalize_config(config) when is_list(config), do: Map.new(config)
end
