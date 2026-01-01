if Code.ensure_loaded?(Req) do
  defmodule Strider.Fly.Infrastructure.Executor do
    @moduledoc """
    Executes infrastructure changes against the Fly.io API.

    Takes a plan and applies each change in the correct order,
    respecting dependencies between resources.
    """

    alias Strider.Fly.Infrastructure.Plan
    alias Strider.Sandbox.Adapters.Fly.Client

    @type result :: %{
            success: [Plan.change()],
            failed: [{Plan.change(), term()}]
          }

    @doc """
    Applies all changes in the plan.

    Changes are executed in dependency order:
    1. Apps (must exist before volumes/machines)
    2. Volumes
    3. Proxy

    ## Parameters
      * `plan` - The plan to execute
      * `api_token` - Fly API token
      * `opts` - Options
        * `:on_progress` - Callback function called with each change result

    ## Returns
      * `{:ok, result}` - All changes succeeded
      * `{:partial, result}` - Some changes failed
    """
    @spec apply(Plan.t(), String.t(), keyword()) :: {:ok, result()} | {:partial, result()}
    def apply(%Plan{changes: changes}, api_token, opts \\ []) do
      on_progress = Keyword.get(opts, :on_progress, fn _, _ -> :ok end)

      ordered = order_changes(changes)

      result =
        Enum.reduce(ordered, %{success: [], failed: []}, fn change, acc ->
          case execute_change(change, api_token) do
            :ok ->
              on_progress.(change, :ok)
              %{acc | success: acc.success ++ [change]}

            {:error, reason} ->
              on_progress.(change, {:error, reason})
              %{acc | failed: acc.failed ++ [{change, reason}]}
          end
        end)

      if result.failed == [] do
        {:ok, result}
      else
        {:partial, result}
      end
    end

    defp order_changes(changes) do
      priority = %{
        app: 1,
        network: 2,
        volume: 3,
        proxy: 4,
        proxy_machine: 5,
        machine: 6
      }

      Enum.sort_by(changes, fn change ->
        base_priority = Map.get(priority, change.resource_type, 99)

        case change.action do
          :create -> base_priority
          :update -> base_priority + 10
          :delete -> 100 - base_priority
        end
      end)
    end

    defp execute_change(%{action: :create, resource_type: :app, details: details}, api_token) do
      case Client.create_app(details.name, details.org, details.network, api_token) do
        {:ok, _} -> :ok
        {:error, {:api_error, 422, _}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp execute_change(%{action: :create, resource_type: :volume, details: details}, api_token) do
      case Client.create_volume(
             details.app_name,
             details.name,
             details.size_gb,
             details.region,
             api_token
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp execute_change(%{action: :create, resource_type: :proxy, details: details}, api_token) do
      case Client.create_app(details.name, details.org, details.network, api_token) do
        {:ok, _} -> :ok
        {:error, {:api_error, 422, _}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp execute_change(
           %{action: :create, resource_type: :proxy_machine, details: details},
           api_token
         ) do
      config = build_proxy_machine_config(details)

      with {:ok, machine} <-
             Client.create_machine(details.app_name, config, details.region, api_token) do
        Client.wait_for_machine(details.app_name, machine["id"], "started", api_token)
      end
    end

    defp execute_change(%{action: :delete, resource_type: :app, details: details}, api_token) do
      case Client.delete_app(details.app_name, api_token) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp execute_change(%{action: :delete, resource_type: :volume, details: details}, api_token) do
      case Client.delete_volume(details.app_name, details.volume_id, api_token) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp execute_change(%{action: :delete, resource_type: :proxy, details: details}, api_token) do
      case Client.delete_app(details.app_name, api_token) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp execute_change(%{action: :delete, resource_type: :machine, details: details}, api_token) do
      case delete_machine(details.app_name, details.machine_id, api_token) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp execute_change(_change, _api_token) do
      :ok
    end

    defp delete_machine(app_name, machine_id, api_token) do
      case Client.delete("/apps/#{app_name}/machines/#{machine_id}?force=true", api_token) do
        {:ok, _} -> :ok
        {:error, :not_found} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp build_proxy_machine_config(details) do
      %{
        image: details.image,
        env: %{
          "PROXY_PORT" => to_string(details.port),
          "ALLOWED_DOMAINS" => Enum.join(details.allowed_domains, ",")
        },
        guest: %{
          memory_mb: details.memory_mb,
          cpus: details.cpu,
          cpu_kind: details.cpu_kind
        },
        services: [
          %{
            ports: [%{port: details.port, handlers: ["http"]}],
            protocol: "tcp",
            internal_port: details.port
          }
        ],
        auto_destroy: false,
        restart: %{policy: "always"}
      }
    end
  end
end
