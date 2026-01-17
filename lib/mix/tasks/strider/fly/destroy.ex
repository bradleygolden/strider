if Code.ensure_loaded?(Toml) and Code.ensure_loaded?(Req) do
  defmodule Mix.Tasks.Strider.Fly.Destroy do
    @shortdoc "Tear down Fly.io infrastructure"
    @moduledoc """
    Destroys all Fly.io infrastructure defined in the configuration file.

    WARNING: This is destructive and cannot be undone. All machines, volumes,
    and apps will be permanently deleted.

    ## Usage

        $ mix strider.fly.destroy
        $ mix strider.fly.destroy --force
        $ mix strider.fly.destroy --path custom.toml

    ## Options

      * `--force` - Skip confirmation prompt
      * `--path` - Path to config file (default: strider.fly.toml)

    ## What Gets Destroyed

      * All running machines in the sandbox app
      * All volumes attached to the sandbox app
      * The sandbox Fly app itself
      * The proxy Fly app (if deployed)
    """

    use Mix.Task

    alias Strider.Fly.Infrastructure.Config
    alias Strider.Fly.Infrastructure.Executor
    alias Strider.Fly.Infrastructure.Plan
    alias Strider.Fly.Infrastructure.State

    @impl Mix.Task
    def run(args) do
      Application.ensure_all_started(:req)

      {opts, _, _} = OptionParser.parse(args, strict: [force: :boolean, path: :string])
      path = Keyword.get(opts, :path, Config.default_path())
      force = Keyword.get(opts, :force, false)

      with {:ok, config} <- load_config(path),
           {:ok, api_token} <- get_api_token(config),
           {:ok, state} <- fetch_state(config, api_token),
           plan <- Plan.generate_destroy(config, state),
           :ok <- confirm_destroy(plan, config, force),
           {:ok, _result} <- execute_plan(plan, api_token) do
        Mix.shell().info("")
        Mix.shell().info("Infrastructure destroyed successfully!")
      else
        :cancelled ->
          Mix.shell().info("Destruction cancelled.")

        :nothing_to_destroy ->
          Mix.shell().info("No infrastructure found to destroy.")

        {:partial, result} ->
          display_partial_failure(result)
          exit({:shutdown, 1})

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
      Mix.shell().info("Fetching current infrastructure state...")
      State.fetch(config, api_token)
    end

    defp confirm_destroy(%Plan{has_changes: false}, _config, _force) do
      :nothing_to_destroy
    end

    defp confirm_destroy(plan, config, force) do
      Mix.shell().info("")
      Mix.shell().info("The following resources will be PERMANENTLY DELETED:")
      Mix.shell().info("")
      Mix.shell().info(Plan.format(plan))
      Mix.shell().info("")

      counts = count_changes(plan.changes)
      Mix.shell().info("Summary: #{counts.delete} resources to destroy.")
      Mix.shell().info("")

      if force do
        :ok
      else
        Mix.shell().error("WARNING: This action cannot be undone!")

        if Mix.shell().yes?("Type 'yes' to confirm destruction of '#{config.app.name}'") do
          :ok
        else
          :cancelled
        end
      end
    end

    defp execute_plan(plan, api_token) do
      Mix.shell().info("")
      Mix.shell().info("Destroying infrastructure...")

      on_progress = fn change, result ->
        case result do
          :ok ->
            Mix.shell().info("  - #{change.description}")

          {:error, reason} ->
            Mix.shell().error("  - #{change.description} - FAILED")
            Mix.shell().error("    Error: #{inspect(reason)}")
        end
      end

      Executor.apply(plan, api_token, on_progress: on_progress)
    end

    defp display_partial_failure(result) do
      Mix.shell().info("")
      Mix.shell().error("Destruction partially failed!")
      Mix.shell().error("  Successful: #{length(result.success)}")
      Mix.shell().error("  Failed: #{length(result.failed)}")
      Mix.shell().info("")
      Mix.shell().info("Run `mix strider.fly.status` to see remaining resources.")
    end

    defp count_changes(changes) do
      Enum.reduce(changes, %{create: 0, update: 0, delete: 0}, fn change, acc ->
        Map.update!(acc, change.action, &(&1 + 1))
      end)
    end
  end
end
