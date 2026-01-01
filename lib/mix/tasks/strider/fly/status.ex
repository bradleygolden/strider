if Code.ensure_loaded?(Toml) and Code.ensure_loaded?(Req) do
  defmodule Mix.Tasks.Strider.Fly.Status do
    @shortdoc "Show current Fly.io infrastructure status"
    @moduledoc """
    Displays the current status of deployed Fly.io infrastructure.

    ## Usage

        $ mix strider.fly.status
        $ mix strider.fly.status --path custom.toml

    ## Options

      * `--path` - Path to config file (default: strider.fly.toml)

    ## Example Output

        Infrastructure Status
        =====================
        Sandbox App: strider-sandboxes (network: strider-isolated)
        Proxy App: not deployed
        Volumes: 4
        Machines: 2 (1 running)
    """

    use Mix.Task

    alias Strider.Fly.Infrastructure.Config
    alias Strider.Fly.Infrastructure.State

    @impl Mix.Task
    def run(args) do
      Application.ensure_all_started(:req)

      {opts, _, _} = OptionParser.parse(args, strict: [path: :string])
      path = Keyword.get(opts, :path, Config.default_path())

      with {:ok, config} <- load_config(path),
           {:ok, api_token} <- get_api_token(config),
           {:ok, state} <- fetch_state(config, api_token) do
        display_status(state)
      else
        {:error, reason} ->
          Mix.shell().error(Config.format_error(reason))
          exit({:shutdown, 1})
      end
    end

    defp load_config(path) do
      Config.load(path: path)
    end

    defp get_api_token(config) do
      case Config.get_api_token(config) do
        {:ok, token} -> {:ok, token}
        {:error, :missing_api_token} -> {:error, :missing_api_token}
      end
    end

    defp fetch_state(config, api_token) do
      Mix.shell().info("Fetching infrastructure status...")
      State.fetch(config, api_token)
    end

    defp display_status(state) do
      Mix.shell().info("")
      Mix.shell().info("Infrastructure Status")
      Mix.shell().info("=====================")
      Mix.shell().info(State.summary(state))
      Mix.shell().info("")

      display_volume_details(state.volumes)
      display_machine_details(state.machines)
    end

    defp display_volume_details(volumes) when map_size(volumes) == 0 do
      :ok
    end

    defp display_volume_details(volumes) do
      Mix.shell().info("Volume Details:")
      Enum.each(volumes, &display_volume_group/1)
      Mix.shell().info("")
    end

    defp display_volume_group({name, vols}) do
      Mix.shell().info("  #{name}:")
      Enum.each(vols, &display_volume/1)
    end

    defp display_volume(vol) do
      attached =
        if vol.attached_machine_id,
          do: " (attached to #{vol.attached_machine_id})",
          else: " (unattached)"

      Mix.shell().info("    - #{vol.id} in #{vol.region}, #{vol.size_gb}GB#{attached}")
    end

    defp display_machine_details([]) do
      :ok
    end

    defp display_machine_details(machines) do
      Mix.shell().info("Machine Details:")

      Enum.each(machines, fn m ->
        Mix.shell().info("  - #{m.id}: #{m.state} in #{m.region}")
      end)

      Mix.shell().info("")
    end
  end
end
