if Code.ensure_loaded?(Toml) and Code.ensure_loaded?(Req) do
  defmodule Mix.Tasks.Strider.Fly.Deploy do
    @shortdoc "Deploy Fly.io infrastructure for Strider sandboxes"
    @moduledoc """
    Creates or updates Fly.io infrastructure based on the configuration file.

    This command will:
    1. Load and validate the configuration
    2. Fetch current infrastructure state from Fly.io
    3. Generate a plan of changes
    4. Prompt for confirmation (unless --auto-approve)
    5. Apply the changes

    ## Usage

        $ mix strider.fly.deploy
        $ mix strider.fly.deploy --auto-approve
        $ mix strider.fly.deploy --path custom.toml

    ## Options

      * `--auto-approve` - Skip confirmation prompt (for CI/CD)
      * `--path` - Path to config file (default: strider.fly.toml)

    ## Prerequisites

      * A `strider.fly.toml` config file (run `mix strider.fly.init` to create one)
      * The `FLY_API_TOKEN` environment variable set with your Fly.io API token
    """

    use Mix.Task

    alias Strider.Fly.Infrastructure.Config
    alias Strider.Fly.Infrastructure.Executor
    alias Strider.Fly.Infrastructure.Plan
    alias Strider.Fly.Infrastructure.State

    @impl Mix.Task
    def run(args) do
      Application.ensure_all_started(:req)

      {opts, _, _} = OptionParser.parse(args, strict: [auto_approve: :boolean, path: :string])
      path = Keyword.get(opts, :path, Config.default_path())
      auto_approve = Keyword.get(opts, :auto_approve, false)

      with {:ok, config} <- load_config(path),
           {:ok, api_token} <- get_api_token(config),
           {:ok, state} <- fetch_state(config, api_token),
           plan <- Plan.generate(config, state),
           :ok <- confirm_plan(plan, auto_approve),
           {:ok, _result} <- execute_plan(plan, api_token) do
        Mix.shell().info("")
        Mix.shell().info("Infrastructure deployed successfully!")
      else
        :cancelled ->
          Mix.shell().info("Deployment cancelled.")

        {:partial, result} ->
          display_partial_failure(result)
          exit({:shutdown, 1})

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

    defp confirm_plan(%Plan{has_changes: false}, _auto_approve) do
      Mix.shell().info("")
      Mix.shell().info("No changes required. Infrastructure is up to date.")
      :cancelled
    end

    defp confirm_plan(plan, auto_approve) do
      Mix.shell().info("")
      Mix.shell().info("Plan:")
      Mix.shell().info(Plan.format(plan))
      Mix.shell().info("")

      counts = count_changes(plan.changes)

      Mix.shell().info(
        "Summary: #{counts.create} to add, #{counts.update} to change, #{counts.delete} to destroy."
      )

      Mix.shell().info("")

      if auto_approve do
        :ok
      else
        if Mix.shell().yes?("Do you want to apply these changes?") do
          :ok
        else
          :cancelled
        end
      end
    end

    defp execute_plan(plan, api_token) do
      Mix.shell().info("")
      Mix.shell().info("Applying changes...")

      on_progress = fn change, result ->
        case result do
          :ok ->
            Mix.shell().info("  #{action_symbol(change.action)} #{change.description}")

          {:error, reason} ->
            Mix.shell().error("  #{action_symbol(change.action)} #{change.description} - FAILED")
            Mix.shell().error("    Error: #{inspect(reason)}")
        end
      end

      Executor.apply(plan, api_token, on_progress: on_progress)
    end

    defp display_partial_failure(result) do
      Mix.shell().info("")
      Mix.shell().error("Deployment partially failed!")
      Mix.shell().error("  Successful: #{length(result.success)}")
      Mix.shell().error("  Failed: #{length(result.failed)}")
      Mix.shell().info("")
      Mix.shell().info("Run `mix strider.fly.status` to see current state.")
    end

    defp count_changes(changes) do
      Enum.reduce(changes, %{create: 0, update: 0, delete: 0}, fn change, acc ->
        Map.update!(acc, change.action, &(&1 + 1))
      end)
    end

    defp action_symbol(:create), do: "+"
    defp action_symbol(:update), do: "~"
    defp action_symbol(:delete), do: "-"
  end
end
