if Code.ensure_loaded?(Toml) do
  defmodule Strider.Fly.Infrastructure.Plan do
    @moduledoc """
    Generates a plan of changes needed to reach the desired infrastructure state.

    Compares the current Fly.io state against the desired configuration
    and produces a list of actions (create, update, delete).
    """

    alias Strider.Fly.Infrastructure.Config
    alias Strider.Fly.Infrastructure.State

    @type action :: :create | :update | :delete | :no_change

    @type change :: %{
            action: action(),
            resource_type: :app | :network | :volume | :proxy,
            resource_id: String.t(),
            description: String.t(),
            details: map()
          }

    @type t :: %__MODULE__{
            changes: [change()],
            has_changes: boolean()
          }

    defstruct changes: [], has_changes: false

    @doc """
    Generates a plan by comparing desired config against current state.

    ## Parameters
      * `config` - The desired configuration
      * `state` - The current infrastructure state

    ## Returns
      * A Plan struct containing the list of changes
    """
    @spec generate(Config.t(), State.t()) :: t()
    def generate(%Config{} = config, %State{} = state) do
      changes =
        []
        |> add_app_changes(config, state)
        |> add_volume_changes(config, state)
        |> add_proxy_changes(config, state)

      %__MODULE__{
        changes: changes,
        has_changes: changes != []
      }
    end

    @doc """
    Generates a destruction plan for tearing down all infrastructure.
    """
    @spec generate_destroy(Config.t(), State.t()) :: t()
    def generate_destroy(%Config{} = config, %State{} = state) do
      changes =
        []
        |> add_destroy_machines(config, state)
        |> add_destroy_volumes(config, state)
        |> add_destroy_proxy(config, state)
        |> add_destroy_app(config, state)

      %__MODULE__{
        changes: changes,
        has_changes: changes != []
      }
    end

    @doc """
    Formats a plan for display.
    """
    @spec format(t()) :: String.t()
    def format(%__MODULE__{has_changes: false}) do
      "No changes required. Infrastructure is up to date."
    end

    def format(%__MODULE__{changes: changes}) do
      Enum.map_join(changes, "\n", &format_change/1)
    end

    defp format_change(%{action: :create, resource_type: type, description: desc}) do
      "  + [#{type}] #{desc}"
    end

    defp format_change(%{action: :update, resource_type: type, description: desc}) do
      "  ~ [#{type}] #{desc}"
    end

    defp format_change(%{action: :delete, resource_type: type, description: desc}) do
      "  - [#{type}] #{desc}"
    end

    defp add_app_changes(changes, config, state) do
      if state.sandbox_app.exists do
        changes
      else
        network_desc =
          if config.network.enabled,
            do: " with network '#{config.network.name}'",
            else: ""

        change = %{
          action: :create,
          resource_type: :app,
          resource_id: config.app.name,
          description: "Create app '#{config.app.name}'#{network_desc}",
          details: %{
            name: config.app.name,
            org: config.fly.org,
            network: if(config.network.enabled, do: config.network.name, else: nil)
          }
        }

        changes ++ [change]
      end
    end

    defp add_volume_changes(changes, config, state) do
      if state.sandbox_app.exists do
        add_volume_creates_for_existing_app(changes, config, state)
      else
        add_volume_creates_for_new_app(changes, config)
      end
    end

    defp add_volume_creates_for_new_app(changes, config) do
      Enum.reduce(config.volumes, changes, fn {name, vol_config}, acc ->
        new_changes =
          for region <- vol_config.regions,
              i <- 1..vol_config.count_per_region do
            %{
              action: :create,
              resource_type: :volume,
              resource_id: "#{name}-#{region}-#{i}",
              description: "Create volume '#{name}' in #{region} (#{vol_config.size_gb}GB)",
              details: %{
                name: name,
                region: region,
                size_gb: vol_config.size_gb,
                app_name: config.app.name
              }
            }
          end

        acc ++ new_changes
      end)
    end

    defp add_volume_creates_for_existing_app(changes, config, state) do
      Enum.reduce(config.volumes, changes, fn {name, vol_config}, acc ->
        existing = Map.get(state.volumes, name, [])

        new_changes =
          for region <- vol_config.regions do
            existing_in_region = Enum.filter(existing, &(&1.region == region))
            needed = vol_config.count_per_region - length(existing_in_region)

            if needed > 0 do
              for i <- 1..needed do
                %{
                  action: :create,
                  resource_type: :volume,
                  resource_id: "#{name}-#{region}-new-#{i}",
                  description: "Create volume '#{name}' in #{region} (#{vol_config.size_gb}GB)",
                  details: %{
                    name: name,
                    region: region,
                    size_gb: vol_config.size_gb,
                    app_name: config.app.name
                  }
                }
              end
            else
              []
            end
          end

        acc ++ List.flatten(new_changes)
      end)
    end

    defp add_proxy_changes(changes, config, state) do
      if config.proxy.enabled and not state.proxy_app.exists do
        change = %{
          action: :create,
          resource_type: :proxy,
          resource_id: config.proxy.app_name,
          description: "Create proxy app '#{config.proxy.app_name}'",
          details: %{
            name: config.proxy.app_name,
            org: config.fly.org,
            port: config.proxy.port,
            allowed_domains: config.proxy.allowed_domains
          }
        }

        changes ++ [change]
      else
        changes
      end
    end

    defp add_destroy_machines(_changes, _config, %State{machines: []}) do
      []
    end

    defp add_destroy_machines(changes, config, state) do
      machine_changes =
        Enum.map(state.machines, fn machine ->
          %{
            action: :delete,
            resource_type: :machine,
            resource_id: machine.id,
            description: "Delete machine '#{machine.id}' (#{machine.state})",
            details: %{
              machine_id: machine.id,
              app_name: config.app.name
            }
          }
        end)

      changes ++ machine_changes
    end

    defp add_destroy_volumes(changes, config, state) do
      volume_changes =
        state.volumes
        |> Map.values()
        |> List.flatten()
        |> Enum.map(fn vol ->
          %{
            action: :delete,
            resource_type: :volume,
            resource_id: vol.id,
            description: "Delete volume '#{vol.name}' (#{vol.id})",
            details: %{
              volume_id: vol.id,
              app_name: config.app.name
            }
          }
        end)

      changes ++ volume_changes
    end

    defp add_destroy_proxy(changes, config, state) do
      if state.proxy_app.exists do
        change = %{
          action: :delete,
          resource_type: :proxy,
          resource_id: config.proxy.app_name,
          description: "Delete proxy app '#{config.proxy.app_name}'",
          details: %{
            app_name: config.proxy.app_name
          }
        }

        changes ++ [change]
      else
        changes
      end
    end

    defp add_destroy_app(changes, _config, %State{sandbox_app: %{exists: false}}) do
      changes
    end

    defp add_destroy_app(changes, config, state) do
      change = %{
        action: :delete,
        resource_type: :app,
        resource_id: config.app.name,
        description: "Delete app '#{state.sandbox_app.name}' and all resources",
        details: %{
          app_name: config.app.name
        }
      }

      changes ++ [change]
    end
  end
end
