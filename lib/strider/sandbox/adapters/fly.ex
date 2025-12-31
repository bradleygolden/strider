if Code.ensure_loaded?(Req) do
  defmodule Strider.Sandbox.Adapters.Fly do
    @moduledoc """
    Fly Machines adapter for Strider.Sandbox.

    Provides production sandbox management using the Fly.io Machines API.
    Implements the `Strider.Sandbox.Adapter` behaviour with provider-agnostic
    configuration that maps to Fly-specific API calls.

    ## Configuration

    Generic fields (work across adapters):
    - `:image` - Container image (default: strider sandbox image)
    - `:env` - Environment variables as `[{name, value}]`
    - `:ports` - Ports to expose as list of integers
    - `:memory_mb` - Memory limit in MB (default: 256)
    - `:cpu` - CPU count (default: 1)
    - `:cpu_kind` - CPU type, "shared" or "performance" (default: "shared")
    - `:auto_destroy` - Auto-destroy machine on exit (default: true). Set to false for
      persistent machines that should survive restarts.
    - `:proxy` - Enable proxy mode for controlled network access:
      - `[ip: "fdaa:...", port: 4000]` - Proxy IP and port (port defaults to 4000)

    Fly-specific fields:
    - `:app_name` - Fly app name (required)
    - `:region` - Fly region (optional, defaults to closest)
    - `:api_token` - API token (optional, defaults to FLY_API_TOKEN env var)
    - `:skip_launch` - Skip starting the machine (default: false). When true, machine
      is created but not started, enabling "warm pool" patterns for fast on-demand starts.

    Network isolation (for multi-tenant security):
    - `:create_app` - If true, creates a dedicated Fly app for this sandbox if it
      doesn't exist (default: false)
    - `:org` - Fly organization slug (required when `:create_app` is true)
    - `:network` - Custom 6PN network name for isolation. Apps on different networks
      cannot communicate with each other.

    ## Network Isolation

    By default, sandboxes have **no network access** (maximum isolation). To enable
    controlled network access through a proxy, pass the `:proxy` option.

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
    alias Strider.Sandbox.Adapters.Fly.VolumeManager
    alias Strider.Sandbox.ExecResult
    alias Strider.Sandbox.FileOps
    alias Strider.Sandbox.HealthPoller
    alias Strider.Sandbox.NetworkEnv

    @default_image "ghcr.io/bradleygolden/strider-sandbox"
    @default_memory_mb 256
    @default_cpus 1
    @default_cpu_kind "shared"
    @default_health_port 4001
    @default_health_interval 2_000
    @default_timeout_ms 60_000
    @default_exec_timeout_ms 30_000
    @fly_max_exec_timeout_ms 60_000
    @fly_max_wait_timeout_sec 60

    @doc """
    Creates a new Fly Machine sandbox.

    Returns `{:ok, sandbox_id, metadata}` where sandbox_id is formatted as `"app_name:machine_id"`
    and metadata contains `private_ip` for fast health checks and `created_volumes` for any
    auto-created volumes.

    ## Volume Mounts

    Attach persistent Fly volumes to your sandbox:

        # Existing volume (must be in same region as machine)
        {:ok, sandbox} = Strider.Sandbox.create({Fly, %{
          image: "node:22-slim",
          app_name: "my-sandboxes",
          mounts: [
            %{volume: "vol_abc123", path: "/data"}
          ]
        }})

        # Auto-create volume
        {:ok, sandbox} = Strider.Sandbox.create({Fly, %{
          image: "node:22-slim",
          app_name: "my-sandboxes",
          mounts: [
            %{name: "workspace", path: "/workspace", size_gb: 10}
          ]
        }})

    Volumes persist after `terminate/1`. Use Fly dashboard or `flyctl volumes delete` to remove.
    """
    @impl true
    def create(config) do
      app_name = get_app_name!(config)
      api_token = get_api_token!(config)
      region = Map.get(config, :region)

      with :ok <- maybe_create_app(config, app_name, api_token),
           {:ok, validated_mounts} <- VolumeManager.validate(Map.get(config, :mounts)),
           {:ok, resolved_mounts, created_volume_ids} <-
             VolumeManager.resolve(validated_mounts, app_name, region, api_token) do
        body =
          %{
            skip_launch: Map.get(config, :skip_launch, false),
            config: %{
              image: Map.get(config, :image, @default_image),
              env: build_env(config),
              guest: %{
                memory_mb: Map.get(config, :memory_mb, @default_memory_mb),
                cpus: Map.get(config, :cpu, @default_cpus),
                cpu_kind: Map.get(config, :cpu_kind, @default_cpu_kind)
              },
              services: Map.get(config, :services) || build_services(Map.get(config, :ports, [])),
              auto_destroy: Map.get(config, :auto_destroy, true),
              restart: %{policy: "no"}
            }
          }
          |> maybe_add_region(config)
          |> maybe_add_mounts(resolved_mounts)

        case Client.post("/apps/#{app_name}/machines", body, api_token) do
          {:ok, %{"id" => machine_id} = response} ->
            metadata = %{
              private_ip: Map.get(response, "private_ip"),
              created_volumes: created_volume_ids
            }

            {:ok, "#{app_name}:#{machine_id}", metadata}

          {:error, reason} ->
            VolumeManager.cleanup(created_volume_ids, app_name, api_token)
            {:error, reason}
        end
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

      timeout_ms =
        min(Keyword.get(opts, :timeout, @default_exec_timeout_ms), @fly_max_exec_timeout_ms)

      body = %{
        command: ["sh", "-c", command],
        timeout: div(timeout_ms, 1000)
      }

      case Client.post("/apps/#{app_name}/machines/#{machine_id}/exec", body, api_token) do
        {:ok, %{"exit_code" => exit_code} = result} ->
          {:ok,
           %ExecResult{
             stdout: result["stdout"] || "",
             stderr: result["stderr"] || "",
             exit_code: exit_code
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @doc """
    Terminates and destroys the Fly Machine.
    """
    @impl true
    def terminate(sandbox_id, opts \\ []) do
      {app_name, machine_id} = parse_sandbox_id!(sandbox_id)
      api_token = get_api_token!(opts)

      case Client.delete("/apps/#{app_name}/machines/#{machine_id}?force=true", api_token) do
        {:ok, _} -> :ok
        {:error, :not_found} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    @doc """
    Terminates the machine and optionally deletes the Fly app.

    This is a Fly-specific extension for cleaning up isolated per-tenant apps.

    ## Options
    - `:destroy_app` - If true, deletes the Fly app after destroying the machine (default: false)
    - `:api_token` - Fly API token (optional, uses FLY_API_TOKEN env var if not provided)

    ## Example

        # Terminate machine only
        Fly.terminate_with_app(sandbox_id)

        # Terminate machine and delete the app
        Fly.terminate_with_app(sandbox_id, destroy_app: true)
    """
    def terminate_with_app(sandbox_id, opts \\ []) do
      {app_name, _machine_id} = parse_sandbox_id!(sandbox_id)

      with :ok <- terminate(sandbox_id, opts) do
        if Keyword.get(opts, :destroy_app, false) do
          api_token = get_api_token!(opts)
          Client.delete_app(app_name, api_token)
        else
          :ok
        end
      end
    end

    @doc """
    Gets the current status of the Fly Machine.
    """
    @impl true
    def status(sandbox_id, opts \\ []) do
      {app_name, machine_id} = parse_sandbox_id!(sandbox_id)
      api_token = get_api_token!(opts)

      case Client.get("/apps/#{app_name}/machines/#{machine_id}", api_token) do
        {:ok, %{"state" => "started"}} -> :running
        {:ok, %{"state" => "stopped"}} -> :stopped
        {:ok, %{"state" => "suspended"}} -> :stopped
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

    @impl true
    def read_file(sandbox_id, path, opts) do
      FileOps.read_file(&exec(sandbox_id, &1, &2), path, opts)
    end

    @impl true
    def write_file(sandbox_id, path, content, opts) do
      FileOps.write_file(&exec(sandbox_id, &1, &2), path, content, opts)
    end

    @impl true
    def write_files(sandbox_id, files, opts) do
      FileOps.write_files(&exec(sandbox_id, &1, &2), files, opts)
    end

    @doc """
    Stops a Fly Machine without destroying it.

    Useful for suspend/resume patterns to save costs.
    """
    @impl true
    def stop(sandbox_id, opts \\ []) do
      {app_name, machine_id} = parse_sandbox_id!(sandbox_id)
      api_token = get_api_token!(opts)

      Client.post("/apps/#{app_name}/machines/#{machine_id}/stop", %{}, api_token)
    end

    @doc """
    Starts a stopped Fly Machine.
    """
    @impl true
    def start(sandbox_id, opts \\ []) do
      {app_name, machine_id} = parse_sandbox_id!(sandbox_id)
      api_token = get_api_token!(opts)

      Client.post("/apps/#{app_name}/machines/#{machine_id}/start", %{}, api_token)
    end

    @doc """
    Updates a machine's configuration without destroying it.

    This preserves volume attachments, unlike terminate + create.

    ## Supported Options

      * `:image` - Container image (required)
      * `:memory_mb` - Memory limit in MB (default: 256)
      * `:cpu` - CPU count (default: 1)
      * `:cpu_kind` - "shared" or "performance" (default: "shared")
      * `:env` - Environment variables as `[{name, value}]`
      * `:ports` - Ports to expose

    ## Example

        Fly.update(sandbox_id, %{image: "node:23-slim"}, api_token: token)
        Fly.update(sandbox_id, %{image: "node:23-slim", memory_mb: 1024}, api_token: token)
    """
    @impl true
    def update(sandbox_id, config, opts \\ []) do
      {app_name, machine_id} = parse_sandbox_id!(sandbox_id)
      api_token = get_api_token!(opts)

      machine_config =
        config
        |> build_machine_config()
        |> add_mounts_for_update(config, app_name, machine_id, api_token)

      body = %{config: machine_config}
      Client.post("/apps/#{app_name}/machines/#{machine_id}", body, api_token)
    end

    defp add_mounts_for_update(machine_config, config, app_name, machine_id, api_token) do
      case Map.fetch(config, :mounts) do
        {:ok, mounts} ->
          maybe_add_mounts_to_config(machine_config, mounts)

        :error ->
          case Client.get("/apps/#{app_name}/machines/#{machine_id}", api_token) do
            {:ok, %{"config" => %{"mounts" => existing}}} when is_list(existing) ->
              Map.put(machine_config, :mounts, existing)

            _ ->
              machine_config
          end
      end
    end

    @doc """
    Waits for a Fly Machine to reach a specific state.

    ## States
    - "started" - Machine is running
    - "stopped" - Machine is stopped
    - "destroyed" - Machine is destroyed

    ## Options
    - `:timeout` - Wait timeout in seconds (default: 60)
    - `:instance_id` - Required when waiting for "stopped" state. The instance_id
      is returned from `update/3` and identifies the specific machine version.

    ## Example

        {:ok, %{"instance_id" => instance_id}} = Fly.update(sandbox_id, config, opts)
        Fly.wait(sandbox_id, "stopped", instance_id: instance_id, timeout: 60)
    """
    def wait(sandbox_id, state, opts \\ []) do
      {app_name, machine_id} = parse_sandbox_id!(sandbox_id)
      api_token = get_api_token!(opts)
      timeout = Keyword.get(opts, :timeout, 60)
      instance_id = Keyword.get(opts, :instance_id)

      query = "state=#{state}&timeout=#{timeout}"
      query = if instance_id, do: "#{query}&instance_id=#{instance_id}", else: query

      Client.get(
        "/apps/#{app_name}/machines/#{machine_id}/wait?#{query}",
        api_token
      )
    end

    @doc """
    Gets volumes attached to a Fly machine.

    Extracts volume information from the machine's mount configuration.

    ## Parameters
    - `sandbox_id` - The sandbox ID in "app_name:machine_id" format
    - `opts` - Options including `:api_token`

    ## Returns
    - `{:ok, [%{volume: vol_id, path: path}]}` on success
    - `{:error, :not_found}` if machine doesn't exist
    - `{:error, reason}` on failure

    ## Example

        {:ok, volumes} = Fly.get_machine_volumes("my-app:machine123", api_token: token)
        # => {:ok, [%{volume: "vol_abc123", path: "/data"}]}
    """
    def get_machine_volumes(sandbox_id, opts \\ []) do
      {app_name, machine_id} = parse_sandbox_id!(sandbox_id)
      api_token = get_api_token!(opts)
      VolumeManager.get_machine_volumes(app_name, machine_id, api_token)
    end

    @doc """
    Lists all volumes for a Fly app.

    Returns volume details including attachment status, useful for finding
    unattached volumes to recover terminated machines.

    ## Parameters
    - `app_name` - The Fly app name
    - `opts` - Options including `:api_token`

    ## Returns
    - `{:ok, [volume]}` on success where each volume is:
      - `id` - Volume ID (e.g., "vol_xxx")
      - `name` - Volume name
      - `state` - Volume state ("created", "attached", etc.)
      - `attached_machine_id` - Machine ID if attached, nil otherwise
      - `region` - Region code
      - `size_gb` - Size in GB
      - `created_at` - ISO8601 timestamp
    - `{:error, reason}` on failure

    ## Example

        {:ok, volumes} = Fly.list_volumes("my-app", api_token: token)
        unattached = Enum.find(volumes, & is_nil(&1.attached_machine_id))
    """
    def list_volumes(app_name, opts \\ []) do
      api_token = get_api_token!(opts)
      VolumeManager.list(app_name, api_token)
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
      timeout_ms = Keyword.get(opts, :timeout, @default_timeout_ms)
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      wait_timeout_sec = min(div(timeout_ms, 1000), @fly_max_wait_timeout_sec)
      port = Keyword.get(opts, :port, @default_health_port)
      interval = Keyword.get(opts, :interval, @default_health_interval)

      with :ok <- wait_for_started(sandbox_id, opts, wait_timeout_sec) do
        remaining_ms = max(0, deadline - System.monotonic_time(:millisecond))
        health_url = build_health_url(sandbox_id, metadata, port)
        HealthPoller.poll(health_url, timeout: remaining_ms, interval: interval)
      end
    end

    defp wait_for_started(sandbox_id, opts, timeout_sec) do
      case wait(sandbox_id, "started", Keyword.put(opts, :timeout, timeout_sec)) do
        {:ok, _} -> :ok
        {:error, {:api_error, 408, _}} -> :ok
        {:error, reason} -> {:error, reason}
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

    # Private helpers

    defp build_machine_config(config) do
      %{
        image: Map.fetch!(config, :image),
        guest: %{
          memory_mb: Map.get(config, :memory_mb, @default_memory_mb),
          cpus: Map.get(config, :cpu, @default_cpus),
          cpu_kind: Map.get(config, :cpu_kind, @default_cpu_kind)
        }
      }
      |> maybe_add_env(config)
      |> maybe_add_services(config)
    end

    defp maybe_add_env(machine_config, config) do
      case Map.get(config, :env) do
        nil -> machine_config
        [] -> machine_config
        env -> Map.put(machine_config, :env, build_env(%{env: env}))
      end
    end

    defp maybe_add_services(machine_config, config) do
      case Map.get(config, :ports) do
        nil -> machine_config
        [] -> machine_config
        ports -> Map.put(machine_config, :services, build_services(ports))
      end
    end

    defp maybe_add_mounts_to_config(machine_config, nil), do: machine_config
    defp maybe_add_mounts_to_config(machine_config, []), do: machine_config

    defp maybe_add_mounts_to_config(machine_config, mounts) when is_list(mounts) do
      Map.put(machine_config, :mounts, mounts)
    end

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
      config_or_opts
      |> ensure_map()
      |> Map.get(:api_token, System.get_env("FLY_API_TOKEN"))
      |> case do
        nil -> raise ArgumentError, "api_token is required in config or FLY_API_TOKEN env var"
        token -> token
      end
    end

    defp ensure_map(map) when is_map(map), do: map
    defp ensure_map(keyword) when is_list(keyword), do: Map.new(keyword)

    defp build_env(config) do
      config
      |> Map.get(:env, [])
      |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)
      |> add_network_env(config)
    end

    defp add_network_env(env, config) do
      config
      |> Map.get(:proxy)
      |> NetworkEnv.build()
      |> Map.merge(env)
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

    defp maybe_add_mounts(body, []), do: body

    defp maybe_add_mounts(body, mounts) when is_list(mounts) do
      put_in(body, [:config, :mounts], mounts)
    end

    defp maybe_create_app(%{create_app: true} = config, app_name, api_token) do
      org =
        Map.get(config, :org) || raise ArgumentError, "org is required when create_app is true"

      network = Map.get(config, :network)

      case Client.get_app(app_name, api_token) do
        {:ok, _} -> :ok
        {:error, :not_found} -> do_create_app(app_name, org, network, api_token)
        {:error, reason} -> {:error, {:app_check_failed, reason}}
      end
    end

    defp maybe_create_app(_config, _app_name, _api_token), do: :ok

    defp do_create_app(app_name, org, network, api_token) do
      case Client.create_app(app_name, org, network, api_token) do
        {:ok, _} ->
          :ok

        {:error, {:api_error, 422, msg}} ->
          if String.contains?(msg, "already exists"),
            do: :ok,
            else: {:error, {:app_creation_failed, msg}}

        {:error, reason} ->
          {:error, {:app_creation_failed, reason}}
      end
    end
  end
end
