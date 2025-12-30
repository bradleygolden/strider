defmodule Strider.Sandbox.Adapters.Docker do
  @moduledoc """
  Docker adapter for Strider.Sandbox.

  Creates and manages Docker containers as sandboxes for isolated code execution.

  ## Configuration

  - `:image` - Docker image to use (default: strider sandbox image)
  - `:workdir` - Working directory in container (default: "/workspace")
  - `:command` - Container command:
    - `nil` (default) - Runs `tail -f /dev/null` to keep container alive
    - `:default` - Uses image's default ENTRYPOINT/CMD
    - `["cmd", "arg1", ...]` - Custom command list
  - `:memory_mb` - Memory limit in MB
  - `:cpu_cores` - CPU limit
  - `:pids_limit` - Max number of processes
  - `:mounts` - List of volume mounts: `[{src, dest}]` or `[{src, dest, readonly: true}]`
  - `:ports` - List of port mappings: `[{host_port, container_port}]`
  - `:env` - List of environment variables: `[{name, value}]`
  - `:proxy` - Enable proxy mode for controlled network access:
    - `[ip: "172.17.0.1", port: 4000]` - Proxy IP and port (port defaults to 4000)

  ## Network Isolation

  By default, sandboxes have **no network access** (maximum isolation). To enable
  controlled network access through a proxy, pass the `:proxy` option.

  ## Security

  By default, containers are created with:
  - `--cap-drop ALL` - Drop all capabilities
  - `--cap-add NET_ADMIN` - Required for network isolation via iptables
  - `--cap-add SETUID/SETGID` - Required for privilege dropping in entrypoint
  - `--security-opt no-new-privileges` - Prevent privilege escalation
  """

  @behaviour Strider.Sandbox.Adapter

  alias Strider.Sandbox.ExecResult

  @default_image "ghcr.io/bradleygolden/strider-sandbox"
  @default_workdir "/workspace"
  @default_timeout 30_000

  @impl true
  def create(config) do
    image = Map.get(config, :image, @default_image)
    workdir = Map.get(config, :workdir, @default_workdir)
    container_name = generate_name()

    args = build_docker_args(container_name, config, image, workdir)

    port_map =
      config
      |> Map.get(:ports, [])
      |> Map.new(fn {host_port, container_port} -> {container_port, host_port} end)

    case System.cmd("docker", ["run" | args], stderr_to_stdout: true) do
      {_, 0} -> {:ok, container_name, %{port_map: port_map}}
      {error, _} -> {:error, error}
    end
  end

  @impl true
  def exec(container_id, command, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    workdir = Keyword.get(opts, :workdir)
    user = Keyword.get(opts, :user, "sandbox")

    args = ["exec", "-u", user]
    args = if workdir, do: args ++ ["-w", workdir], else: args
    args = args ++ [container_id, "sh", "-c", command]

    task = Task.async(fn -> System.cmd("docker", args, stderr_to_stdout: true) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {output, exit_code}} ->
        {:ok, %ExecResult{stdout: output, exit_code: exit_code}}

      nil ->
        {:error, :timeout}
    end
  end

  @impl true
  def terminate(container_id) do
    System.cmd("docker", ["rm", "-f", container_id], stderr_to_stdout: true)
    :ok
  end

  @impl true
  def status(container_id) do
    case System.cmd("docker", ["inspect", "-f", "{{.State.Status}}", container_id],
           stderr_to_stdout: true
         ) do
      {"running\n", 0} -> :running
      {"exited\n", 0} -> :stopped
      _ -> :unknown
    end
  end

  @impl true
  def get_url(_container_id, port) do
    {:ok, "http://localhost:#{port}"}
  end

  @impl true
  def read_file(container_id, path, opts) do
    case exec(container_id, "base64 -w 0 '#{escape_path(path)}'", opts) do
      {:ok, %{exit_code: 0, stdout: encoded}} ->
        case Base.decode64(String.trim(encoded)) do
          {:ok, content} -> {:ok, content}
          :error -> {:error, :invalid_base64}
        end

      {:ok, %{exit_code: _}} ->
        {:error, :file_not_found}

      error ->
        error
    end
  end

  @impl true
  def write_file(container_id, path, content, opts) do
    encoded = Base.encode64(content)
    escaped_path = escape_path(path)

    cmd =
      "mkdir -p \"$(dirname '#{escaped_path}')\" && echo '#{encoded}' | base64 -d > '#{escaped_path}'"

    case exec(container_id, cmd, opts) do
      {:ok, %{exit_code: 0}} -> :ok
      {:ok, %{exit_code: code}} -> {:error, {:exit_code, code}}
      error -> error
    end
  end

  # Private helpers

  defp generate_name do
    "strider-sandbox-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
  end

  defp build_docker_args(name, config, image, workdir) do
    ["-d", "--name", name, "-w", workdir]
    |> add_resource_limits(config)
    |> add_security_opts()
    |> add_mounts(config)
    |> add_ports(config)
    |> add_env_vars(config)
    |> add_network_env(config)
    |> add_image_and_command(config, image)
  end

  defp add_resource_limits(args, config) do
    args
    |> maybe_add("--memory", Map.get(config, :memory_mb), &"#{&1}m")
    |> maybe_add("--cpus", Map.get(config, :cpu_cores), &to_string/1)
    |> maybe_add("--pids-limit", Map.get(config, :pids_limit), &to_string/1)
  end

  defp add_security_opts(args) do
    args ++
      [
        "--cap-drop",
        "ALL",
        "--cap-add",
        "NET_ADMIN",
        "--cap-add",
        "SETUID",
        "--cap-add",
        "SETGID",
        "--security-opt",
        "no-new-privileges"
      ]
  end

  defp add_mounts(args, config) do
    Enum.reduce(Map.get(config, :mounts, []), args, fn
      {src, dest}, acc -> acc ++ ["-v", "#{Path.expand(src)}:#{dest}"]
      {src, dest, readonly: true}, acc -> acc ++ ["-v", "#{Path.expand(src)}:#{dest}:ro"]
    end)
  end

  defp add_ports(args, config) do
    Enum.reduce(Map.get(config, :ports, []), args, fn {host, container}, acc ->
      acc ++ ["-p", "#{host}:#{container}"]
    end)
  end

  defp add_env_vars(args, config) do
    Enum.reduce(Map.get(config, :env, []), args, fn {k, v}, acc ->
      acc ++ ["-e", "#{k}=#{v}"]
    end)
  end

  defp add_network_env(args, config) do
    case Map.get(config, :proxy) do
      nil ->
        args ++ ["-e", "STRIDER_NETWORK_MODE=none"]

      proxy_opts when is_list(proxy_opts) ->
        ip = Keyword.fetch!(proxy_opts, :ip)
        port = Keyword.get(proxy_opts, :port, 4000)

        args ++
          [
            "-e",
            "STRIDER_NETWORK_MODE=proxy_only",
            "-e",
            "STRIDER_PROXY_IP=#{ip}",
            "-e",
            "STRIDER_PROXY_PORT=#{port}"
          ]
    end
  end

  defp add_image_and_command(args, config, image) do
    case Map.get(config, :command) do
      nil -> args ++ [image, "tail", "-f", "/dev/null"]
      :default -> args ++ [image]
      cmd when is_list(cmd) -> args ++ [image | cmd]
    end
  end

  defp maybe_add(args, _flag, nil, _transform), do: args
  defp maybe_add(args, flag, value, transform), do: args ++ [flag, transform.(value)]

  defp escape_path(path) do
    String.replace(path, "'", "'\\''")
  end
end
