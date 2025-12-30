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
    alias Strider.Sandbox.ExecResult
    alias Strider.Sandbox.HealthPoller

    @default_image "ghcr.io/bradleygolden/strider-sandbox"

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
           {:ok, validated_mounts} <- validate_mounts(Map.get(config, :mounts)),
           {:ok, resolved_mounts, created_volume_ids} <-
             resolve_mounts(validated_mounts, app_name, region, api_token) do
        body =
          %{
            skip_launch: Map.get(config, :skip_launch, false),
            config: %{
              image: Map.get(config, :image, @default_image),
              env: build_env(config),
              guest: %{
                memory_mb: Map.get(config, :memory_mb, 256),
                cpus: Map.get(config, :cpu, 1),
                cpu_kind: Map.get(config, :cpu_kind, "shared")
              },
              services: Map.get(config, :services) || build_services(Map.get(config, :ports, [])),
              auto_destroy: Map.get(config, :auto_destroy, true),
              restart: %{policy: "no"}
            }
          }
          |> maybe_add_region(config)
          |> maybe_add_mounts(resolved_mounts)

        case create_machine_if_none_exist(app_name, body, api_token) do
          {:ok, %{"id" => machine_id} = response} ->
            metadata = %{
              private_ip: Map.get(response, "private_ip"),
              created_volumes: created_volume_ids
            }

            {:ok, "#{app_name}:#{machine_id}", metadata}

          {:error, reason} ->
            cleanup_volumes(created_volume_ids, app_name, api_token)
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
      timeout_ms = min(Keyword.get(opts, :timeout, 30_000), 60_000)

      body = %{
        command: ["sh", "-c", command],
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

      with :ok <- terminate(sandbox_id) do
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
    def status(sandbox_id) do
      {app_name, machine_id} = parse_sandbox_id!(sandbox_id)
      api_token = get_api_token!([])

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

    # Additional Fly-specific functions (not part of Adapter behaviour)

    @doc """
    Reads a file from the Fly Machine using base64 encoding.
    """
    @impl true
    def read_file(sandbox_id, path, opts) do
      case exec(sandbox_id, "base64 -w0 '#{escape_path(path)}'", opts) do
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

      machine_config = build_machine_config(config)

      machine_config =
        if Map.has_key?(config, :mounts) do
          maybe_add_mounts_to_config(machine_config, Map.get(config, :mounts))
        else
          case Client.get("/apps/#{app_name}/machines/#{machine_id}", api_token) do
            {:ok, %{"config" => %{"mounts" => existing_mounts}}} when is_list(existing_mounts) ->
              Map.put(machine_config, :mounts, existing_mounts)

            _ ->
              machine_config
          end
        end

      body = %{config: machine_config}
      Client.post("/apps/#{app_name}/machines/#{machine_id}", body, api_token)
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

      case Client.get_machine(app_name, machine_id, api_token) do
        {:ok, %{"config" => %{"mounts" => mounts}}} when is_list(mounts) ->
          volumes =
            Enum.map(mounts, fn mount ->
              %{volume: mount["volume"], path: mount["path"]}
            end)

          {:ok, volumes}

        {:ok, _} ->
          {:ok, []}

        {:error, _} = error ->
          error
      end
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

      case Client.list_volumes(app_name, api_token) do
        {:ok, volumes} ->
          {:ok, Enum.map(volumes, &transform_volume/1)}

        {:error, _} = error ->
          error
      end
    end

    defp transform_volume(vol) do
      %{
        id: vol["id"],
        name: vol["name"],
        state: vol["state"],
        attached_machine_id: vol["attached_machine_id"],
        region: vol["region"],
        size_gb: vol["size_gb"],
        created_at: vol["created_at"]
      }
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
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      # Fly wait API has a max timeout of 60 seconds
      wait_timeout_sec = min(div(timeout_ms, 1000), 60)
      port = Keyword.get(opts, :port, 4001)
      interval = Keyword.get(opts, :interval, 2_000)

      # Wait for machine to start, but proceed to health polling even on timeout (408)
      # since the machine may still become ready within our overall deadline
      case wait(sandbox_id, "started", Keyword.put(opts, :timeout, wait_timeout_sec)) do
        {:ok, _} ->
          :ok

        {:error, {:api_error, 408, _}} ->
          # Wait timed out but machine may still start - continue to health polling
          :ok

        {:error, reason} ->
          {:error, reason}
      end
      |> case do
        :ok ->
          remaining_ms = max(0, deadline - System.monotonic_time(:millisecond))
          health_url = build_health_url(sandbox_id, metadata, port)
          HealthPoller.poll(health_url, timeout: remaining_ms, interval: interval)

        error ->
          error
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
      base = %{
        image: Map.fetch!(config, :image),
        guest: %{
          memory_mb: Map.get(config, :memory_mb, 256),
          cpus: Map.get(config, :cpu, 1),
          cpu_kind: Map.get(config, :cpu_kind, "shared")
        }
      }

      base
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
      config_or_opts =
        if is_list(config_or_opts), do: Map.new(config_or_opts), else: config_or_opts

      Map.get(config_or_opts, :api_token) ||
        System.get_env("FLY_API_TOKEN") ||
        raise ArgumentError, "api_token is required in config or FLY_API_TOKEN env var"
    end

    defp build_env(config) do
      base_env =
        config
        |> Map.get(:env, [])
        |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)

      base_env
      |> add_network_env(config)
    end

    defp add_network_env(env, config) do
      case Map.get(config, :proxy) do
        nil ->
          Map.put(env, "STRIDER_NETWORK_MODE", "none")

        proxy_opts when is_list(proxy_opts) ->
          ip = Keyword.fetch!(proxy_opts, :ip)
          port = Keyword.get(proxy_opts, :port, 4000)

          env
          |> Map.put("STRIDER_NETWORK_MODE", "proxy_only")
          |> Map.put("STRIDER_PROXY_IP", to_string(ip))
          |> Map.put("STRIDER_PROXY_PORT", to_string(port))
      end
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

    defp validate_mounts(nil), do: {:ok, []}
    defp validate_mounts([]), do: {:ok, []}

    defp validate_mounts(mounts) when is_list(mounts) do
      Enum.reduce_while(mounts, {:ok, []}, fn mount, {:ok, acc} ->
        case validate_mount(mount) do
          {:ok, validated} -> {:cont, {:ok, [validated | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)
      |> case do
        {:ok, validated} -> {:ok, Enum.reverse(validated)}
        error -> error
      end
    end

    defp validate_mount(%{volume: vol_id, path: path})
         when is_binary(vol_id) and is_binary(path) do
      {:ok, {:existing, vol_id, path}}
    end

    defp validate_mount(%{name: name, path: path, size_gb: size})
         when is_binary(name) and is_binary(path) and is_integer(size) and size > 0 do
      {:ok, {:create, name, path, size}}
    end

    defp validate_mount(mount) do
      {:error, {:invalid_mount, mount}}
    end

    defp resolve_mounts(validated_mounts, app_name, region, api_token) do
      resolve_mounts(validated_mounts, app_name, region, api_token, [], [])
    end

    defp resolve_mounts([], _app, _region, _token, resolved, created) do
      {:ok, Enum.reverse(resolved), Enum.reverse(created)}
    end

    defp resolve_mounts([{:existing, vol_id, path} | rest], app, region, token, resolved, created) do
      mount = %{volume: vol_id, path: path}
      resolve_mounts(rest, app, region, token, [mount | resolved], created)
    end

    defp resolve_mounts(
           [{:create, name, path, size} | rest],
           app,
           region,
           token,
           resolved,
           created
         ) do
      case Client.create_volume(app, name, size, region, token) do
        {:ok, %{"id" => vol_id}} ->
          mount = %{volume: vol_id, path: path}
          resolve_mounts(rest, app, region, token, [mount | resolved], [vol_id | created])

        {:error, reason} ->
          cleanup_volumes(created, app, token)
          {:error, {:volume_creation_failed, name, reason}}
      end
    end

    defp cleanup_volumes([], _app, _token), do: :ok

    defp cleanup_volumes(volume_ids, app_name, api_token) do
      Enum.each(volume_ids, fn vol_id ->
        Client.delete_volume(app_name, vol_id, api_token)
      end)
    end

    defp maybe_add_mounts(body, []), do: body

    defp maybe_add_mounts(body, mounts) when is_list(mounts) do
      put_in(body, [:config, :mounts], mounts)
    end

    defp escape_path(path) do
      String.replace(path, "'", "'\\''")
    end

    defp create_machine_if_none_exist(app_name, body, api_token) do
      case Client.get("/apps/#{app_name}/machines", api_token) do
        {:ok, [%{"id" => existing_id} | _]} ->
          case Client.get("/apps/#{app_name}/machines/#{existing_id}", api_token) do
            {:ok, response} -> {:ok, response}
            error -> error
          end

        {:ok, []} ->
          Client.post("/apps/#{app_name}/machines", body, api_token)

        {:error, _} ->
          Client.post("/apps/#{app_name}/machines", body, api_token)
      end
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
