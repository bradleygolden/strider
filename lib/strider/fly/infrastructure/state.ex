if Code.ensure_loaded?(Req) and Code.ensure_loaded?(Toml) do
  defmodule Strider.Fly.Infrastructure.State do
    @moduledoc """
    Queries Fly.io API to get current infrastructure state.

    This module provides a normalized view of deployed infrastructure
    that can be compared against desired configuration.
    """

    alias Strider.Sandbox.Adapters.Fly.Client

    @type t :: %__MODULE__{
            sandbox_app: app_state(),
            proxy_app: proxy_app_state(),
            volumes: %{String.t() => [volume_state()]},
            machines: [machine_state()]
          }

    @type app_state :: %{
            exists: boolean(),
            name: String.t() | nil,
            organization: String.t() | nil,
            network: String.t() | nil
          }

    @type proxy_app_state :: %{
            exists: boolean(),
            name: String.t() | nil,
            organization: String.t() | nil,
            network: String.t() | nil,
            machine_id: String.t() | nil,
            machine_state: String.t() | nil,
            secrets: [String.t()]
          }

    @type volume_state :: %{
            id: String.t(),
            name: String.t(),
            region: String.t(),
            size_gb: pos_integer(),
            attached_machine_id: String.t() | nil
          }

    @type machine_state :: %{
            id: String.t(),
            state: String.t(),
            region: String.t(),
            image: String.t() | nil
          }

    defstruct sandbox_app: %{exists: false, name: nil, organization: nil, network: nil},
              proxy_app: %{
                exists: false,
                name: nil,
                organization: nil,
                network: nil,
                machine_id: nil,
                machine_state: nil,
                secrets: []
              },
              volumes: %{},
              machines: []

    @doc """
    Fetches the current state of infrastructure from Fly.io.

    ## Parameters
      * `config` - The parsed Config struct
      * `api_token` - Fly API token

    ## Returns
      * `{:ok, state}` - Current infrastructure state
      * `{:error, reason}` - API error
    """
    @spec fetch(Strider.Fly.Infrastructure.Config.t(), String.t()) ::
            {:ok, t()} | {:error, term()}
    def fetch(config, api_token) do
      with {:ok, sandbox_app} <- fetch_app_state(config.app.name, api_token),
           {:ok, proxy_app} <- fetch_proxy_state(config, api_token),
           {:ok, volumes} <- fetch_volumes_state(config, sandbox_app, api_token),
           {:ok, machines} <- fetch_machines_state(config, sandbox_app, api_token) do
        {:ok,
         %__MODULE__{
           sandbox_app: sandbox_app,
           proxy_app: proxy_app,
           volumes: volumes,
           machines: machines
         }}
      end
    end

    @doc """
    Returns a summary of the current state for display.
    """
    @spec summary(t()) :: String.t()
    def summary(%__MODULE__{} = state) do
      lines = []

      lines =
        if state.sandbox_app.exists do
          network_info =
            if state.sandbox_app.network,
              do: " (network: #{state.sandbox_app.network})",
              else: ""

          lines ++ ["Sandbox App: #{state.sandbox_app.name}#{network_info}"]
        else
          lines ++ ["Sandbox App: not deployed"]
        end

      lines =
        if state.proxy_app.exists do
          machine_info =
            if state.proxy_app.machine_id do
              " (machine: #{state.proxy_app.machine_state})"
            else
              " (no machine)"
            end

          lines ++ ["Proxy App: #{state.proxy_app.name}#{machine_info}"]
        else
          lines ++ ["Proxy App: not deployed"]
        end

      volume_count = state.volumes |> Map.values() |> List.flatten() |> length()
      lines = lines ++ ["Volumes: #{volume_count}"]

      machine_count = length(state.machines)
      running = Enum.count(state.machines, &(&1.state == "started"))
      lines = lines ++ ["Machines: #{machine_count} (#{running} running)"]

      Enum.join(lines, "\n")
    end

    defp fetch_app_state(app_name, api_token) do
      case Client.get_app(app_name, api_token) do
        {:ok, app} ->
          {:ok,
           %{
             exists: true,
             name: app["name"],
             organization: get_in(app, ["organization", "slug"]),
             network: app["network"]
           }}

        {:error, :not_found} ->
          {:ok, %{exists: false, name: nil, organization: nil, network: nil}}

        {:error, reason} ->
          {:error, {:api_error, :sandbox_app, reason}}
      end
    end

    defp fetch_proxy_state(config, api_token) do
      default_state = %{
        exists: false,
        name: nil,
        organization: nil,
        network: nil,
        machine_id: nil,
        machine_state: nil,
        secrets: []
      }

      if config.proxy.enabled and config.proxy.app_name do
        case Client.get_app(config.proxy.app_name, api_token) do
          {:ok, app} ->
            with {:ok, machine_info} <-
                   fetch_proxy_machine(config.proxy.app_name, api_token),
                 {:ok, secrets} <- fetch_proxy_secrets(config.proxy.app_name, api_token) do
              {:ok,
               %{
                 exists: true,
                 name: app["name"],
                 organization: get_in(app, ["organization", "slug"]),
                 network: app["network"],
                 machine_id: machine_info.id,
                 machine_state: machine_info.state,
                 secrets: secrets
               }}
            end

          {:error, :not_found} ->
            {:ok, default_state}

          {:error, reason} ->
            {:error, {:api_error, :proxy_app, reason}}
        end
      else
        {:ok, default_state}
      end
    end

    defp fetch_proxy_machine(app_name, api_token) do
      case Client.list_machines(app_name, api_token) do
        {:ok, []} ->
          {:ok, %{id: nil, state: nil}}

        {:ok, [machine | _]} ->
          {:ok, %{id: machine["id"], state: machine["state"]}}

        {:error, reason} ->
          {:error, {:api_error, :proxy_machine, reason}}
      end
    end

    defp fetch_proxy_secrets(app_name, api_token) do
      case Client.list_secrets(app_name, api_token) do
        {:ok, secrets} ->
          {:ok, secrets}

        {:error, :not_found} ->
          {:ok, []}

        {:error, reason} ->
          {:error, {:api_error, :proxy_secrets, reason}}
      end
    end

    defp fetch_volumes_state(_config, %{exists: false}, _api_token) do
      {:ok, %{}}
    end

    defp fetch_volumes_state(config, %{exists: true}, api_token) do
      case Client.list_volumes(config.app.name, api_token) do
        {:ok, volumes} ->
          grouped =
            volumes
            |> Enum.map(fn vol ->
              %{
                id: vol["id"],
                name: vol["name"],
                region: vol["region"],
                size_gb: vol["size_gb"],
                attached_machine_id: vol["attached_machine_id"]
              }
            end)
            |> Enum.group_by(& &1.name)

          {:ok, grouped}

        {:error, reason} ->
          {:error, {:api_error, :volumes, reason}}
      end
    end

    defp fetch_machines_state(_config, %{exists: false}, _api_token) do
      {:ok, []}
    end

    defp fetch_machines_state(config, %{exists: true}, api_token) do
      case Client.list_machines(config.app.name, api_token) do
        {:ok, machines} ->
          normalized =
            Enum.map(machines, fn m ->
              %{
                id: m["id"],
                state: m["state"],
                region: m["region"],
                image: get_in(m, ["config", "image"])
              }
            end)

          {:ok, normalized}

        {:error, reason} ->
          {:error, {:api_error, :machines, reason}}
      end
    end
  end
end
