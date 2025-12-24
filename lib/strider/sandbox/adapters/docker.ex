defmodule Strider.Sandbox.Adapters.Docker do
  @moduledoc """
  Docker adapter for Strider.Sandbox.

  Creates and manages Docker containers as sandboxes for isolated code execution.

  ## Configuration

  - `:image` - Docker image to use (default: "ubuntu:22.04")
  - `:workdir` - Working directory in container (default: "/workspace")
  - `:memory_mb` - Memory limit in MB
  - `:cpu_cores` - CPU limit
  - `:pids_limit` - Max number of processes
  - `:mounts` - List of volume mounts: `[{src, dest}]` or `[{src, dest, readonly: true}]`
  - `:ports` - List of port mappings: `[{host_port, container_port}]`
  - `:env` - List of environment variables: `[{name, value}]`

  ## Security

  By default, containers are created with:
  - `--cap-drop ALL` - Drop all capabilities
  - `--security-opt no-new-privileges` - Prevent privilege escalation
  """

  @behaviour Strider.Sandbox.Adapter

  alias Strider.Sandbox.ExecResult

  @default_image "ubuntu:22.04"
  @default_workdir "/workspace"
  @default_timeout 30_000

  @impl true
  def create(config) do
    image = Map.get(config, :image, @default_image)
    workdir = Map.get(config, :workdir, @default_workdir)
    container_name = generate_name()

    args = build_docker_args(container_name, config, image, workdir)

    case System.cmd("docker", ["run" | args], stderr_to_stdout: true) do
      {_, 0} -> {:ok, container_name}
      {error, _} -> {:error, error}
    end
  end

  @impl true
  def exec(container_id, command, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    workdir = Keyword.get(opts, :workdir)

    args = ["exec"]
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
  def get_url(container_id, port) do
    {:ok, "http://#{container_id}:#{port}"}
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
    |> Kernel.++([image, "tail", "-f", "/dev/null"])
  end

  defp add_resource_limits(args, config) do
    args
    |> maybe_add("--memory", Map.get(config, :memory_mb), &"#{&1}m")
    |> maybe_add("--cpus", Map.get(config, :cpu_cores), &to_string/1)
    |> maybe_add("--pids-limit", Map.get(config, :pids_limit), &to_string/1)
  end

  defp add_security_opts(args) do
    args ++ ["--cap-drop", "ALL", "--security-opt", "no-new-privileges"]
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

  defp maybe_add(args, _flag, nil, _transform), do: args
  defp maybe_add(args, flag, value, transform), do: args ++ [flag, transform.(value)]
end
