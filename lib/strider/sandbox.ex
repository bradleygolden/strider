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
  alias Strider.Sandbox.NDJSON

  @type backend :: {module(), map() | keyword()}
  @type text_block :: %{type: :text, text: String.t()}
  @type file_block ::
          %{type: :file, media_type: String.t(), data: String.t()}
          | %{type: :file, media_type: String.t(), text: String.t()}
  @type prompt_content :: String.t() | [text_block() | file_block()]

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

  @doc """
  Sends a prompt to the sandbox server and returns a stream of events.

  The sandbox must be running a strider-sandbox compatible server that
  accepts POST requests to `/prompt` and returns NDJSON events.

  ## Options

  - `:port` - The port the sandbox server is listening on (default: 4001)
  - `:timeout` - Request timeout in milliseconds (default: 60_000)

  ## Examples

      {:ok, stream} = Strider.Sandbox.prompt(sandbox, "Hello")
      Enum.each(stream, fn event -> IO.inspect(event) end)

      # With content blocks for images/files
      {:ok, stream} = Strider.Sandbox.prompt(sandbox, [
        %{type: "text", text: "What's in this image?"},
        %{type: "file", media_type: "image/png", data: Base.encode64(bytes)}
      ])
  """
  @spec prompt(Instance.t(), prompt_content(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def prompt(%Instance{} = sandbox, content, opts \\ []) do
    port = Keyword.get(opts, :port, 4001)
    timeout = Keyword.get(opts, :timeout, 60_000)

    with {:ok, base_url} <- get_url(sandbox, port) do
      url = "#{base_url}/prompt"
      body = Jason.encode!(%{prompt: content, options: %{}})

      stream =
        Stream.resource(
          fn -> start_prompt_request(url, body, timeout) end,
          &receive_prompt_chunks/1,
          &cleanup_prompt_request/1
        )
        |> NDJSON.stream()

      {:ok, stream}
    end
  end

  defp start_prompt_request(url, body, timeout) do
    caller = self()
    ref = make_ref()

    pid =
      spawn_link(fn ->
        try do
          Req.post!(url,
            body: body,
            headers: [{"content-type", "application/json"}],
            into: fn {:data, data}, acc ->
              send(caller, {ref, {:data, data}})
              {:cont, acc}
            end,
            receive_timeout: timeout
          )

          send(caller, {ref, :done})
        rescue
          e -> send(caller, {ref, {:error, Exception.message(e)}})
        end
      end)

    {ref, pid, timeout}
  end

  defp receive_prompt_chunks({ref, pid, timeout} = state) do
    receive do
      {^ref, {:data, data}} ->
        {[data], state}

      {^ref, :done} ->
        {:halt, state}

      {^ref, {:error, reason}} ->
        raise "Prompt request failed: #{reason}"

      {:EXIT, ^pid, reason} ->
        raise "Prompt request process died: #{inspect(reason)}"
    after
      timeout ->
        raise "Prompt request timed out"
    end
  end

  defp cleanup_prompt_request({_ref, pid, _timeout}) do
    Process.exit(pid, :kill)

    receive do
      {:EXIT, ^pid, _} -> :ok
    after
      100 -> :ok
    end
  end

  defp normalize_config(config) when is_map(config), do: config
  defp normalize_config(config) when is_list(config), do: Map.new(config)
end
