if Code.ensure_loaded?(Req) do
  defmodule Strider.Sandbox.Adapters.Fly do
    @moduledoc """
    Fly Machines adapter for Strider.Sandbox.

    Provides production sandbox management using the Fly.io Machines API.
    Implements the `Strider.Sandbox.Adapter` behaviour with provider-agnostic
    configuration that maps to Fly-specific API calls.

    ## Configuration

    Generic fields (work across adapters):
    - `:image` - Container image (required, e.g., "node:22-slim")
    - `:env` - Environment variables as `[{name, value}]`
    - `:ports` - Ports to expose as list of integers
    - `:memory_mb` - Memory limit in MB (default: 256)
    - `:cpu` - CPU count (default: 1)
    - `:cpu_kind` - CPU type, "shared" or "performance" (default: "shared")

    Fly-specific fields:
    - `:app_name` - Fly app name (required)
    - `:region` - Fly region (optional, defaults to closest)
    - `:api_token` - API token (optional, defaults to FLY_API_TOKEN env var)

    ## Usage

        alias Strider.Sandbox.Adapters.Fly

        {:ok, sandbox} = Strider.Sandbox.create({Fly, %{
          image: "node:22-slim",
          env: [{"HTTP_PORT", "4001"}],
          ports: [4001],
          memory_mb: 512,
          app_name: "my-sandboxes",
          region: "ord"
        }})

        {:ok, result} = Strider.Sandbox.exec(sandbox, "node --version")
        {:ok, url} = Strider.Sandbox.get_url(sandbox, 4001)
        :ok = Strider.Sandbox.terminate(sandbox)

    ## Reconnecting to Existing Machines

        # Sandbox ID format: "app_name:machine_id"
        sandbox = Strider.Sandbox.from_id(Fly, "my-sandboxes:abc123def")
        {:ok, result} = Strider.Sandbox.exec(sandbox, "echo 'still here'")

    ## Environment Variables

    - `FLY_API_TOKEN` - Fly.io API token (required if not passed in config)
    - `FLY_APP_NAME` - Default app name (optional)
    """

    @behaviour Strider.Sandbox.Adapter

    alias Strider.Sandbox.Adapters.Fly.Client
    alias Strider.Sandbox.ExecResult

    @doc """
    Creates a new Fly Machine sandbox.

    Returns `{:ok, sandbox_id, metadata}` where sandbox_id is formatted as `"app_name:machine_id"`
    and metadata contains `private_ip` for fast health checks.
    """
    @impl true
    def create(config) do
      app_name = get_app_name!(config)
      api_token = get_api_token!(config)

      body =
        %{
          config: %{
            image: Map.fetch!(config, :image),
            env: build_env(config),
            guest: %{
              memory_mb: Map.get(config, :memory_mb, 256),
              cpus: Map.get(config, :cpu, 1),
              cpu_kind: Map.get(config, :cpu_kind, "shared")
            },
            services: build_services(Map.get(config, :ports, [])),
            auto_destroy: true,
            restart: %{policy: "no"}
          }
        }
        |> maybe_add_region(config)

      case Client.post("/apps/#{app_name}/machines", body, api_token) do
        {:ok, %{"id" => machine_id} = response} ->
          metadata = %{private_ip: Map.get(response, "private_ip")}
          {:ok, "#{app_name}:#{machine_id}", metadata}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @doc """
    Executes a command in the Fly Machine.

    Note: Fly exec has a 60 second timeout limit.
    """
    @impl true
    def exec(sandbox_id, command, opts) do
      {app_name, machine_id} = parse_sandbox_id!(sandbox_id)
      api_token = get_api_token!(opts)
      timeout_ms = min(Keyword.get(opts, :timeout, 30_000), 60_000)

      body = %{
        cmd: ["sh", "-c", command],
        timeout: div(timeout_ms, 1000)
      }

      case Client.post("/apps/#{app_name}/machines/#{machine_id}/exec", body, api_token) do
        {:ok, %{"stdout" => stdout, "stderr" => stderr, "exit_code" => exit_code}} ->
          {:ok, %ExecResult{stdout: stdout || "", stderr: stderr || "", exit_code: exit_code}}

        {:ok, %{"stdout" => stdout, "exit_code" => exit_code}} ->
          {:ok, %ExecResult{stdout: stdout || "", exit_code: exit_code}}

        {:error, :timeout} ->
          {:error, :timeout}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @doc """
    Terminates and destroys the Fly Machine.
    """
    @impl true
    def terminate(sandbox_id) do
      {app_name, machine_id} = parse_sandbox_id!(sandbox_id)
      api_token = get_api_token!([])

      case Client.delete("/apps/#{app_name}/machines/#{machine_id}?force=true", api_token) do
        {:ok, _} -> :ok
        {:error, :not_found} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    @doc """
    Gets the current status of the Fly Machine.
    """
    @impl true
    def status(sandbox_id) do
      {app_name, machine_id} = parse_sandbox_id!(sandbox_id)
      api_token = get_api_token!([])

      case Client.get("/apps/#{app_name}/machines/#{machine_id}", api_token) do
        {:ok, %{"state" => "started"}} -> :running
        {:ok, %{"state" => "stopped"}} -> :stopped
        {:ok, %{"state" => "destroyed"}} -> :terminated
        {:ok, %{"state" => "destroying"}} -> :terminated
        {:error, :not_found} -> :terminated
        _ -> :unknown
      end
    end

    @doc """
    Gets the internal URL for an exposed port on the Fly Machine.

    Returns Fly's internal DNS format: `http://{machine_id}.vm.{app_name}.internal:{port}`
    """
    @impl true
    def get_url(sandbox_id, port) do
      {app_name, machine_id} = parse_sandbox_id!(sandbox_id)
      {:ok, "http://#{machine_id}.vm.#{app_name}.internal:#{port}"}
    end

    # Additional Fly-specific functions (not part of Adapter behaviour)

    @doc """
    Reads a file from the Fly Machine using base64 encoding.
    """
    @impl true
    def read_file(sandbox_id, path, opts) do
      case exec(sandbox_id, "base64 '#{escape_path(path)}'", opts) do
        {:ok, %{exit_code: 0, stdout: encoded}} ->
          case Base.decode64(String.trim(encoded)) do
            {:ok, content} -> {:ok, content}
            :error -> {:error, :invalid_base64}
          end

        {:ok, %{exit_code: _, stderr: err}} ->
          {:error, err}

        {:ok, %{exit_code: _}} ->
          {:error, :file_not_found}

        error ->
          error
      end
    end

    @doc """
    Writes a file to the Fly Machine using base64 encoding.
    """
    @impl true
    def write_file(sandbox_id, path, content, opts) do
      encoded = Base.encode64(content)
      escaped_path = escape_path(path)

      cmd =
        "mkdir -p \"$(dirname '#{escaped_path}')\" && echo '#{encoded}' | base64 -d > '#{escaped_path}'"

      case exec(sandbox_id, cmd, opts) do
        {:ok, %{exit_code: 0}} -> :ok
        {:ok, %{exit_code: _, stderr: err}} when err != "" -> {:error, err}
        {:ok, %{exit_code: code}} -> {:error, {:exit_code, code}}
        error -> error
      end
    end

    @doc """
    Stops a Fly Machine without destroying it.

    Useful for suspend/resume patterns to save costs.
    """
    def stop(sandbox_id, opts \\ []) do
      {app_name, machine_id} = parse_sandbox_id!(sandbox_id)
      api_token = get_api_token!(opts)

      Client.post("/apps/#{app_name}/machines/#{machine_id}/stop", %{}, api_token)
    end

    @doc """
    Starts a stopped Fly Machine.
    """
    def start(sandbox_id, opts \\ []) do
      {app_name, machine_id} = parse_sandbox_id!(sandbox_id)
      api_token = get_api_token!(opts)

      Client.post("/apps/#{app_name}/machines/#{machine_id}/start", %{}, api_token)
    end

    @doc """
    Waits for a Fly Machine to reach a specific state.

    ## States
    - "started" - Machine is running
    - "stopped" - Machine is stopped
    - "destroyed" - Machine is destroyed
    """
    def wait(sandbox_id, state, opts \\ []) do
      {app_name, machine_id} = parse_sandbox_id!(sandbox_id)
      api_token = get_api_token!(opts)
      timeout = Keyword.get(opts, :timeout, 60)

      Client.get(
        "/apps/#{app_name}/machines/#{machine_id}/wait?state=#{state}&timeout=#{timeout}",
        api_token
      )
    end

    @doc """
    Waits for sandbox to become ready using Fly's native wait API + health polling.

    Phase 1: Waits for machine to reach "started" state via Fly API
    Phase 2: Polls health endpoint until it responds with 200

    Uses private_ip from metadata when available for fast health checks,
    falling back to DNS when private_ip is not available.

    ## Options
      * `:port` - health check port (default: 4001)
      * `:timeout` - max wait time in ms (default: 60_000)
      * `:interval` - poll interval in ms (default: 2_000)
      * `:api_token` - Fly API token (optional, uses FLY_API_TOKEN env var if not provided)
    """
    @impl true
    def await_ready(sandbox_id, metadata, opts \\ []) do
      timeout_ms = Keyword.get(opts, :timeout, 60_000)
      # Fly wait API has a max timeout of 60 seconds
      wait_timeout_sec = min(div(timeout_ms, 1000), 60)
      port = Keyword.get(opts, :port, 4001)
      interval = Keyword.get(opts, :interval, 2_000)

      with {:ok, _} <- wait(sandbox_id, "started", Keyword.put(opts, :timeout, wait_timeout_sec)) do
        health_url = build_health_url(sandbox_id, metadata, port)
        poll_health(health_url, timeout_ms, interval)
      end
    end

    defp build_health_url(_sandbox_id, %{private_ip: private_ip}, port)
         when is_binary(private_ip) do
      "http://[#{private_ip}]:#{port}/health"
    end

    defp build_health_url(sandbox_id, _metadata, port) do
      {:ok, url} = get_url(sandbox_id, port)
      "#{url}/health"
    end

    defp poll_health(url, timeout, interval) do
      deadline = System.monotonic_time(:millisecond) + timeout
      do_poll_health(url, deadline, interval)
    end

    defp do_poll_health(url, deadline, interval) do
      if System.monotonic_time(:millisecond) > deadline do
        {:error, :timeout}
      else
        case Req.get(url) do
          {:ok, %{status: 200, body: body}} ->
            {:ok, body}

          _ ->
            Process.sleep(interval)
            do_poll_health(url, deadline, interval)
        end
      end
    end

    # Private helpers

    defp parse_sandbox_id!(sandbox_id) do
      case String.split(sandbox_id, ":", parts: 2) do
        [app_name, machine_id] -> {app_name, machine_id}
        _ -> raise ArgumentError, "Invalid sandbox_id format. Expected 'app_name:machine_id'"
      end
    end

    defp get_app_name!(config) do
      Map.get(config, :app_name) ||
        System.get_env("FLY_APP_NAME") ||
        raise ArgumentError, "app_name is required in config or FLY_APP_NAME env var"
    end

    defp get_api_token!(config_or_opts) do
      config_or_opts =
        if is_list(config_or_opts), do: Map.new(config_or_opts), else: config_or_opts

      Map.get(config_or_opts, :api_token) ||
        System.get_env("FLY_API_TOKEN") ||
        raise ArgumentError, "api_token is required in config or FLY_API_TOKEN env var"
    end

    defp build_env(config) do
      config
      |> Map.get(:env, [])
      |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)
    end

    defp build_services([]), do: []

    defp build_services(ports) do
      Enum.map(ports, fn port ->
        %{
          ports: [%{port: port, handlers: ["http"]}],
          protocol: "tcp",
          internal_port: port
        }
      end)
    end

    defp maybe_add_region(body, config) do
      case Map.get(config, :region) do
        nil -> body
        region -> Map.put(body, :region, region)
      end
    end

    defp escape_path(path) do
      String.replace(path, "'", "'\\''")
    end
  end
end
