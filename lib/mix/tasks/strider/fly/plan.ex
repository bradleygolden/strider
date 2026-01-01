if Code.ensure_loaded?(Toml) and Code.ensure_loaded?(Req) do
  defmodule Mix.Tasks.Strider.Fly.Plan do
    @shortdoc "Preview infrastructure changes without applying"
    @moduledoc """
    Generates and displays a plan of changes that would be made to Fly.io infrastructure.

    This command does not make any changes - it only shows what would happen
    if you ran `mix strider.fly.deploy`.

    ## Usage

        $ mix strider.fly.plan
        $ mix strider.fly.plan --path custom.toml

    ## Options

      * `--path` - Path to config file (default: strider.fly.toml)

    ## Example Output

        Planning infrastructure changes...

          + [app] Create app 'strider-sandboxes' with network 'strider-isolated'
          + [volume] Create volume 'workspace' in ord (10GB)
          + [volume] Create volume 'workspace' in ord (10GB)

        Plan: 3 to add, 0 to change, 0 to destroy.
    """

    use Mix.Task

    alias Strider.Fly.Infrastructure.Config
    alias Strider.Fly.Infrastructure.Plan
    alias Strider.Fly.Infrastructure.State

    @impl Mix.Task
    def run(args) do
      Application.ensure_all_started(:req)

      {opts, _, _} = OptionParser.parse(args, strict: [path: :string])
      path = Keyword.get(opts, :path, Config.default_path())

      with {:ok, config} <- load_config(path),
           {:ok, api_token} <- get_api_token(config),
           {:ok, state} <- fetch_state(config, api_token) do
        plan = Plan.generate(config, state)
        display_plan(plan)
      else
        {:error, reason} ->
          Mix.shell().error(Config.format_error(reason))
          exit({:shutdown, 1})
      end
    end

    defp load_config(path) do
      Mix.shell().info("Loading config from #{path}...")
      Config.load(path: path)
    end

    defp get_api_token(config) do
      case Config.get_api_token(config) do
        {:ok, token} -> {:ok, token}
        {:error, :missing_api_token} -> {:error, :missing_api_token}
      end
    end

    defp fetch_state(config, api_token) do
      Mix.shell().info("Fetching current infrastructure state...")
      State.fetch(config, api_token)
    end

    defp display_plan(plan) do
      Mix.shell().info("")
      Mix.shell().info("Plan:")
      Mix.shell().info(Plan.format(plan))
      Mix.shell().info("")

      if plan.has_changes do
        counts = count_changes(plan.changes)

        Mix.shell().info(
          "Summary: #{counts.create} to add, #{counts.update} to change, #{counts.delete} to destroy."
        )
      end
    end

    defp count_changes(changes) do
      Enum.reduce(changes, %{create: 0, update: 0, delete: 0}, fn change, acc ->
        Map.update!(acc, change.action, &(&1 + 1))
      end)
    end
  end
end
