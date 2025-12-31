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
  - `Strider.Sandbox.Adapters.Fly` - Fly.io Machines (production)
  - `Strider.Sandbox.Adapters.Test` - In-memory testing adapter

  Custom adapters can be created by implementing the `Strider.Sandbox.Adapter` behaviour.
  """

  alias Strider.Sandbox.HealthPoller
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

    with {:ok, sandbox_id, metadata} <- adapter_module.create(config_map) do
      sandbox =
        Instance.new(
          id: sandbox_id,
          adapter: adapter_module,
          config: config_map,
          metadata: metadata
        )

      {:ok, sandbox}
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
  @spec from_id(module(), String.t(), map(), map()) :: Instance.t()
  def from_id(adapter_module, sandbox_id, config \\ %{}, metadata \\ %{}) do
    Instance.new(
      id: sandbox_id,
      adapter: adapter_module,
      config: config,
      metadata: metadata
    )
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
    sandbox.adapter.exec(sandbox.id, command, merge_opts(sandbox.config, opts))
  end

  @doc """
  Terminates and cleans up the sandbox.

  ## Examples

      :ok = Strider.Sandbox.terminate(sandbox)
  """
  @spec terminate(Instance.t()) :: :ok | {:error, term()}
  def terminate(%Instance{} = sandbox) do
    sandbox.adapter.terminate(sandbox.id, merge_opts(sandbox.config, []))
  end

  @doc """
  Gets the current status of the sandbox.

  ## Examples

      :running = Strider.Sandbox.status(sandbox)
  """
  @spec status(Instance.t()) :: :running | :stopped | :terminated | :unknown
  def status(%Instance{} = sandbox) do
    sandbox.adapter.status(sandbox.id, merge_opts(sandbox.config, []))
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
  def get_url(%Instance{metadata: metadata, adapter: adapter, id: id}, port) do
    resolved_port = get_in(metadata, [:port_map, port]) || port
    call_optional(adapter, :get_url, [id, resolved_port])
  end

  @doc """
  Reads a file from the sandbox.

  ## Examples

      {:ok, content} = Strider.Sandbox.read_file(sandbox, "/app/code.py")
  """
  @spec read_file(Instance.t(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def read_file(%Instance{adapter: adapter, id: id, config: config}, path, opts \\ []) do
    call_optional(adapter, :read_file, [id, path, merge_opts(config, opts)])
  end

  @doc """
  Writes a file to the sandbox.

  ## Examples

      :ok = Strider.Sandbox.write_file(sandbox, "/app/code.py", "print('hello')")
  """
  @spec write_file(Instance.t(), String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def write_file(%Instance{adapter: adapter, id: id, config: config}, path, content, opts \\ []) do
    call_optional(adapter, :write_file, [id, path, content, merge_opts(config, opts)])
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
  def write_files(
        %Instance{adapter: adapter, id: id, config: config} = sandbox,
        files,
        opts \\ []
      ) do
    merged_opts = merge_opts(config, opts)

    call_optional(adapter, :write_files, [id, files, merged_opts], fn ->
      write_files_sequentially(sandbox, files, merged_opts)
    end)
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
  Waits for sandbox to become ready.

  Delegates to the adapter's `await_ready/3` if implemented.
  Falls back to polling the health endpoint if not.

  ## Options

  - `:port` - health check port (default: 4001)
  - `:timeout` - max wait time in ms (default: 60_000)
  - `:interval` - poll interval in ms (default: 2_000)

  ## Examples

      {:ok, metadata} = Strider.Sandbox.await_ready(sandbox)
      {:ok, metadata} = Strider.Sandbox.await_ready(sandbox, timeout: 30_000)
  """
  @spec await_ready(Instance.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def await_ready(
        %Instance{adapter: adapter, id: id, config: config, metadata: metadata} = sandbox,
        opts \\ []
      ) do
    merged_opts = merge_opts(config, opts)

    call_optional(adapter, :await_ready, [id, metadata, merged_opts], fn ->
      poll_health_endpoint(sandbox, merged_opts)
    end)
  end

  @doc """
  Stops a sandbox without destroying it.

  Useful for suspend/resume patterns. The sandbox can be restarted with `start/1`.
  Returns `{:error, :not_implemented}` if the adapter doesn't support it.

  ## Examples

      {:ok, _} = Strider.Sandbox.stop(sandbox)
  """
  @spec stop(Instance.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def stop(%Instance{adapter: adapter, id: id, config: config}, opts \\ []) do
    call_optional(adapter, :stop, [id, merge_opts(config, opts)])
  end

  @doc """
  Starts a stopped sandbox.

  Returns `{:error, :not_implemented}` if the adapter doesn't support it.

  ## Examples

      {:ok, _} = Strider.Sandbox.start(sandbox)
  """
  @spec start(Instance.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start(%Instance{adapter: adapter, id: id, config: config}, opts \\ []) do
    call_optional(adapter, :start, [id, merge_opts(config, opts)])
  end

  @doc """
  Updates a sandbox's configuration without destroying it.

  This preserves state like volume attachments. Returns `{:error, :not_implemented}`
  if the adapter doesn't support it.

  ## Examples

      {:ok, _} = Strider.Sandbox.update(sandbox, %{image: "node:23-slim"})
  """
  @spec update(Instance.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update(%Instance{adapter: adapter, id: id, config: sandbox_config}, config, opts \\ []) do
    call_optional(adapter, :update, [id, config, merge_opts(sandbox_config, opts)])
  end

  defp poll_health_endpoint(sandbox, opts) do
    port = Keyword.get(opts, :port, 4001)

    case get_url(sandbox, port) do
      {:ok, url} -> HealthPoller.poll("#{url}/health", opts)
      {:error, _} = error -> error
    end
  end

  @doc """
  Sends a prompt to the sandbox server and returns a stream of events.

  The sandbox must be running a strider-sandbox compatible server that
  accepts POST requests to `/prompt` and returns NDJSON events.

  ## Options

  - `:port` - The port the sandbox server is listening on (default: 4001)
  - `:timeout` - Request timeout in milliseconds (default: 60_000)
  - `:options` - Custom options passed to the sandbox server (default: %{})

  ## Event Format

  The stream yields maps with a `"type"` key indicating the event type:

      %{"type" => "text", "text" => "Hello!"}
      %{"type" => "tool_call", "name" => "run_code", "arguments" => %{...}}
      %{"type" => "tool_result", "content" => "..."}
      %{"type" => "error", "message" => "..."}

  ## Examples

      {:ok, stream} = Strider.Sandbox.prompt(sandbox, "Hello")
      Enum.each(stream, fn event ->
        case event do
          %{"type" => "text", "text" => text} -> IO.write(text)
          %{"type" => "error", "message" => msg} -> IO.puts("Error: \#{msg}")
          _ -> :ok
        end
      end)

      # With content blocks for images/files
      {:ok, stream} = Strider.Sandbox.prompt(sandbox, [
        %{type: "text", text: "What's in this image?"},
        %{type: "file", media_type: "image/png", data: Base.encode64(bytes)}
      ])

      # Accumulate full response
      {:ok, stream} = Strider.Sandbox.prompt(sandbox, "Write a poem")
      text = stream
        |> Enum.filter(&match?(%{"type" => "text"}, &1))
        |> Enum.map_join(&Map.get(&1, "text"))
  """
  @spec prompt(Instance.t(), prompt_content(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def prompt(%Instance{} = sandbox, content, opts \\ []) do
    port = Keyword.get(opts, :port, 4001)
    timeout = Keyword.get(opts, :timeout, 60_000)

    with {:ok, base_url} <- get_base_url(sandbox, port) do
      url = "#{base_url}/prompt"
      custom_opts = Keyword.get(opts, :options, %{})
      body = Jason.encode!(%{prompt: content, options: custom_opts})

      case Req.post(url,
             body: body,
             headers: [{"content-type", "application/json"}],
             into: :self,
             receive_timeout: timeout
           ) do
        {:ok, %{status: status, body: async_body}} when status in 200..299 ->
          stream = async_body |> NDJSON.stream()
          {:ok, stream}

        {:ok, %{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp get_base_url(%Instance{metadata: %{private_ip: private_ip}}, port)
       when is_binary(private_ip) do
    {:ok, "http://[#{private_ip}]:#{port}"}
  end

  defp get_base_url(sandbox, port), do: get_url(sandbox, port)

  defp normalize_config(config) when is_map(config), do: config
  defp normalize_config(config) when is_list(config), do: Map.new(config)

  defp config_to_opts(config) when is_map(config), do: Keyword.new(config)
  defp config_to_opts(config) when is_list(config), do: config

  defp merge_opts(config, opts) do
    Keyword.merge(config_to_opts(config), opts)
  end

  defp call_optional(adapter, callback, args, fallback \\ fn -> {:error, :not_implemented} end) do
    if function_exported?(adapter, callback, length(args)) do
      apply(adapter, callback, args)
    else
      fallback.()
    end
  end
end
