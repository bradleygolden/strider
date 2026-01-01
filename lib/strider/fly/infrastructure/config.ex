if Code.ensure_loaded?(Toml) do
  defmodule Strider.Fly.Infrastructure.Config do
    @moduledoc """
    Parses and validates `strider.fly.toml` configuration files.

    ## Example Config

        [fly]
        org = "my-org"
        api_token_env = "FLY_API_TOKEN"

        [app]
        name = "strider-sandboxes"
        regions = ["sjc"]

        [network]
        enabled = true
        name = "strider-isolated"

        [volumes.workspace]
        size_gb = 10
        regions = ["sjc"]
        count_per_region = 2

        [sandbox]
        image = "ghcr.io/bradleygolden/strider-sandbox:latest"
        memory_mb = 256
        cpu = 1

        [proxy]
        enabled = true
        app_name = "strider-proxy"
        port = 4000
        allowed_domains = ["api.anthropic.com"]
    """

    @type t :: %__MODULE__{
            fly: fly_config(),
            app: app_config(),
            network: network_config(),
            volumes: %{String.t() => volume_config()},
            sandbox: sandbox_config(),
            proxy: proxy_config()
          }

    @type fly_config :: %{
            org: String.t(),
            api_token_env: String.t()
          }

    @type app_config :: %{
            name: String.t(),
            regions: [String.t()]
          }

    @type network_config :: %{
            enabled: boolean(),
            name: String.t() | nil
          }

    @type volume_config :: %{
            size_gb: pos_integer(),
            regions: [String.t()],
            count_per_region: pos_integer()
          }

    @type sandbox_config :: %{
            image: String.t(),
            memory_mb: pos_integer(),
            cpu: pos_integer(),
            cpu_kind: String.t(),
            auto_destroy: boolean(),
            env: %{String.t() => String.t()}
          }

    @type proxy_config :: %{
            enabled: boolean(),
            app_name: String.t() | nil,
            port: pos_integer(),
            allowed_domains: [String.t()]
          }

    defstruct [:fly, :app, :network, :volumes, :sandbox, :proxy]

    @default_config_path "strider.fly.toml"

    @doc """
    Loads and validates config from a TOML file.

    ## Options
      * `:path` - Path to config file (default: "strider.fly.toml")

    ## Returns
      * `{:ok, config}` - Parsed and validated config struct
      * `{:error, reason}` - Validation error with details
    """
    @spec load(keyword()) :: {:ok, t()} | {:error, term()}
    def load(opts \\ []) do
      path = Keyword.get(opts, :path, @default_config_path)

      with {:ok, content} <- read_file(path),
           {:ok, parsed} <- parse_toml(content) do
        validate(parsed)
      end
    end

    @doc """
    Returns the default config file path.
    """
    @spec default_path() :: String.t()
    def default_path, do: @default_config_path

    @doc """
    Validates a parsed TOML map and returns a Config struct.
    """
    @spec validate(map()) :: {:ok, t()} | {:error, term()}
    def validate(parsed) do
      with {:ok, fly} <- validate_fly(parsed["fly"]),
           {:ok, app} <- validate_app(parsed["app"]),
           {:ok, network} <- validate_network(parsed["network"]),
           {:ok, volumes} <- validate_volumes(parsed["volumes"]),
           {:ok, sandbox} <- validate_sandbox(parsed["sandbox"]),
           {:ok, proxy} <- validate_proxy(parsed["proxy"]) do
        {:ok,
         %__MODULE__{
           fly: fly,
           app: app,
           network: network,
           volumes: volumes,
           sandbox: sandbox,
           proxy: proxy
         }}
      end
    end

    @doc """
    Returns the API token from the configured environment variable.
    """
    @spec get_api_token(t()) :: {:ok, String.t()} | {:error, :missing_api_token}
    def get_api_token(%__MODULE__{fly: %{api_token_env: env_var}}) do
      case System.get_env(env_var) do
        nil -> {:error, :missing_api_token}
        "" -> {:error, :missing_api_token}
        token -> {:ok, token}
      end
    end

    defp read_file(path) do
      case File.read(path) do
        {:ok, content} -> {:ok, content}
        {:error, :enoent} -> {:error, {:file_not_found, path}}
        {:error, reason} -> {:error, {:file_read_error, path, reason}}
      end
    end

    defp parse_toml(content) do
      case Toml.decode(content) do
        {:ok, parsed} -> {:ok, parsed}
        {:error, reason} -> {:error, {:toml_parse_error, reason}}
      end
    end

    defp validate_fly(nil), do: {:error, {:missing_section, "fly"}}

    defp validate_fly(fly) do
      with :ok <- require_field(fly, "org", "fly") do
        org = fly["org"]
        api_token_env = Map.get(fly, "api_token_env", "FLY_API_TOKEN")
        {:ok, %{org: org, api_token_env: api_token_env}}
      end
    end

    defp validate_app(nil), do: {:error, {:missing_section, "app"}}

    defp validate_app(app) do
      with :ok <- require_field(app, "name", "app") do
        name = app["name"]
        regions = Map.get(app, "regions", ["sjc"])

        if is_list(regions) and Enum.all?(regions, &is_binary/1) do
          {:ok, %{name: name, regions: regions}}
        else
          {:error, {:invalid_field, "app.regions", "must be a list of strings"}}
        end
      end
    end

    defp validate_network(nil), do: {:ok, %{enabled: false, name: nil}}

    defp validate_network(network) do
      enabled = Map.get(network, "enabled", false)
      name = Map.get(network, "name")

      if enabled and is_nil(name) do
        {:error, {:invalid_field, "network.name", "required when network.enabled is true"}}
      else
        {:ok, %{enabled: enabled, name: name}}
      end
    end

    defp validate_volumes(nil), do: {:ok, %{}}

    defp validate_volumes(volumes) when is_map(volumes) do
      volumes
      |> Enum.reduce_while({:ok, %{}}, fn {name, vol}, {:ok, acc} ->
        case validate_volume(name, vol) do
          {:ok, validated} -> {:cont, {:ok, Map.put(acc, name, validated)}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end

    defp validate_volume(name, vol) do
      with :ok <- require_field(vol, "size_gb", "volumes.#{name}") do
        size_gb = vol["size_gb"]
        regions = Map.get(vol, "regions", ["sjc"])
        count_per_region = Map.get(vol, "count_per_region", 1)

        cond do
          not is_integer(size_gb) or size_gb < 1 ->
            {:error, {:invalid_field, "volumes.#{name}.size_gb", "must be a positive integer"}}

          not is_list(regions) or not Enum.all?(regions, &is_binary/1) ->
            {:error, {:invalid_field, "volumes.#{name}.regions", "must be a list of strings"}}

          not is_integer(count_per_region) or count_per_region < 1 ->
            {:error,
             {:invalid_field, "volumes.#{name}.count_per_region", "must be a positive integer"}}

          true ->
            {:ok, %{size_gb: size_gb, regions: regions, count_per_region: count_per_region}}
        end
      end
    end

    defp validate_sandbox(nil), do: {:error, {:missing_section, "sandbox"}}

    defp validate_sandbox(sandbox) do
      with :ok <- require_field(sandbox, "image", "sandbox") do
        image = sandbox["image"]
        memory_mb = Map.get(sandbox, "memory_mb", 256)
        cpu = Map.get(sandbox, "cpu", 1)
        cpu_kind = Map.get(sandbox, "cpu_kind", "shared")
        auto_destroy = Map.get(sandbox, "auto_destroy", true)
        env = Map.get(sandbox, "env", %{})

        cond do
          not is_integer(memory_mb) or memory_mb < 256 ->
            {:error, {:invalid_field, "sandbox.memory_mb", "must be at least 256"}}

          not is_integer(cpu) or cpu < 1 ->
            {:error, {:invalid_field, "sandbox.cpu", "must be a positive integer"}}

          cpu_kind not in ["shared", "performance"] ->
            {:error, {:invalid_field, "sandbox.cpu_kind", "must be 'shared' or 'performance'"}}

          not is_map(env) ->
            {:error, {:invalid_field, "sandbox.env", "must be a map"}}

          true ->
            {:ok,
             %{
               image: image,
               memory_mb: memory_mb,
               cpu: cpu,
               cpu_kind: cpu_kind,
               auto_destroy: auto_destroy,
               env: stringify_env(env)
             }}
        end
      end
    end

    defp validate_proxy(nil),
      do: {:ok, %{enabled: false, app_name: nil, port: 4000, allowed_domains: []}}

    defp validate_proxy(proxy) do
      enabled = Map.get(proxy, "enabled", false)
      app_name = Map.get(proxy, "app_name")
      port = Map.get(proxy, "port", 4000)
      allowed_domains = Map.get(proxy, "allowed_domains", [])

      cond do
        enabled and is_nil(app_name) ->
          {:error, {:invalid_field, "proxy.app_name", "required when proxy.enabled is true"}}

        not is_integer(port) or port < 1 or port > 65_535 ->
          {:error, {:invalid_field, "proxy.port", "must be a valid port number"}}

        not is_list(allowed_domains) or not Enum.all?(allowed_domains, &is_binary/1) ->
          {:error, {:invalid_field, "proxy.allowed_domains", "must be a list of strings"}}

        true ->
          {:ok,
           %{
             enabled: enabled,
             app_name: app_name,
             port: port,
             allowed_domains: allowed_domains
           }}
      end
    end

    defp require_field(map, field, section) do
      if Map.has_key?(map, field) do
        :ok
      else
        {:error, {:missing_field, "#{section}.#{field}"}}
      end
    end

    defp stringify_env(env) do
      Map.new(env, fn {k, v} -> {to_string(k), to_string(v)} end)
    end

    @doc """
    Generates a template config file content with comments.
    """
    @spec template() :: String.t()
    def template do
      """
      # Strider Fly.io Infrastructure Configuration
      # Deploy sandbox infrastructure to Fly.io
      #
      # Usage:
      #   mix strider.fly.deploy    # Deploy infrastructure
      #   mix strider.fly.status    # Check current status
      #   mix strider.fly.destroy   # Tear down infrastructure

      [fly]
      # Your Fly.io organization slug (required)
      org = "my-org"

      # Environment variable containing your Fly API token (default: FLY_API_TOKEN)
      # api_token_env = "FLY_API_TOKEN"

      [app]
      # Globally unique app name for sandboxes (required)
      name = "strider-sandboxes"

      # Fly.io regions to deploy to
      regions = ["sjc"]

      [network]
      # Enable 6PN private network for sandbox isolation
      enabled = true

      # Custom network name (required if enabled)
      name = "strider-isolated"

      # Volume templates for persistent storage (optional)
      # [volumes.workspace]
      # size_gb = 10
      # regions = ["sjc"]
      # count_per_region = 2

      [sandbox]
      # Container image for sandboxes (required)
      image = "ghcr.io/bradleygolden/strider-sandbox:latest"

      # Resource allocation
      memory_mb = 256
      cpu = 1
      cpu_kind = "shared"  # "shared" or "performance"

      # Keep sandboxes after termination for pool management
      auto_destroy = false

      # Environment variables for sandboxes
      # [sandbox.env]
      # NODE_ENV = "production"

      [proxy]
      # Enable proxy app for controlled network access
      enabled = false

      # Proxy app name (required if enabled)
      # app_name = "strider-proxy"

      # Proxy port
      port = 4000

      # Allowed external domains
      # allowed_domains = ["api.anthropic.com", "api.github.com"]
      """
    end

    @doc """
    Formats a validation error into a human-readable message.
    """
    @spec format_error(term()) :: String.t()
    def format_error({:file_not_found, path}) do
      "Config file not found: #{path}\nRun 'mix strider.fly.init' to create one."
    end

    def format_error({:file_read_error, path, reason}) do
      "Failed to read config file #{path}: #{inspect(reason)}"
    end

    def format_error({:toml_parse_error, reason}) do
      "Failed to parse TOML: #{inspect(reason)}"
    end

    def format_error({:missing_section, section}) do
      "Missing required section: [#{section}]"
    end

    def format_error({:missing_field, field}) do
      "Missing required field: #{field}"
    end

    def format_error({:invalid_field, field, message}) do
      "Invalid field #{field}: #{message}"
    end

    def format_error(:missing_api_token) do
      "API token not found. Set the FLY_API_TOKEN environment variable."
    end

    def format_error(reason) do
      "Configuration error: #{inspect(reason)}"
    end
  end
end
