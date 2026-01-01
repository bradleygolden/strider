if Code.ensure_loaded?(Toml) do
  defmodule Mix.Tasks.Strider.Fly.Init do
    @shortdoc "Generate a strider.fly.toml configuration file"
    @moduledoc """
    Generates a template `strider.fly.toml` configuration file.

    ## Usage

        $ mix strider.fly.init
        $ mix strider.fly.init --force  # Overwrite existing file

    ## Options

      * `--force` - Overwrite existing config file
      * `--path` - Custom path for config file (default: strider.fly.toml)

    After generating the config file, edit it with your Fly.io organization
    and app settings, then run `mix strider.fly.deploy` to create the infrastructure.
    """

    use Mix.Task

    alias Strider.Fly.Infrastructure.Config

    @impl Mix.Task
    def run(args) do
      {opts, _, _} = OptionParser.parse(args, strict: [force: :boolean, path: :string])

      path = Keyword.get(opts, :path, Config.default_path())
      force = Keyword.get(opts, :force, false)

      if File.exists?(path) and not force do
        Mix.shell().error("Config file already exists: #{path}")
        Mix.shell().error("Use --force to overwrite.")
        exit({:shutdown, 1})
      end

      content = Config.template()
      File.write!(path, content)

      Mix.shell().info("Created #{path}")
      Mix.shell().info("")
      Mix.shell().info("Next steps:")
      Mix.shell().info("  1. Edit #{path} with your Fly.io settings")
      Mix.shell().info("  2. Set FLY_API_TOKEN environment variable")
      Mix.shell().info("  3. Run: mix strider.fly.plan  # Preview changes")
      Mix.shell().info("  4. Run: mix strider.fly.deploy  # Create infrastructure")
    end
  end
end
