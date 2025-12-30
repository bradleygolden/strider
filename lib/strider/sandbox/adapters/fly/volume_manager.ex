if Code.ensure_loaded?(Req) do
  defmodule Strider.Sandbox.Adapters.Fly.VolumeManager do
    @moduledoc """
    Manages Fly volume lifecycle for sandbox mounts.

    Handles validation, resolution (creating volumes for auto-create mounts),
    and cleanup of volumes.

    ## Mount Types

    Two mount types are supported:

    1. **Existing volume** - Attach an existing Fly volume by ID:
       `%{volume: "vol_abc123", path: "/data"}`

    2. **Auto-create volume** - Create a new volume on-demand:
       `%{name: "workspace", path: "/workspace", size_gb: 10}`

    Volumes created via auto-create are tracked and can be cleaned up on failure.
    """

    alias Strider.Sandbox.Adapters.Fly.Client

    @type existing_mount :: {:existing, volume_id :: String.t(), path :: String.t()}
    @type create_mount ::
            {:create, name :: String.t(), path :: String.t(), size_gb :: pos_integer()}
    @type validated_mount :: existing_mount() | create_mount()
    @type resolved_mount :: %{volume: String.t(), path: String.t()}

    @doc """
    Validates mount configurations from user input.

    Returns validated mounts as tagged tuples for processing by `resolve/4`.

    ## Returns
    - `{:ok, [validated_mount]}` on success
    - `{:error, {:invalid_mount, mount}}` if any mount is invalid
    """
    @spec validate(list() | nil) ::
            {:ok, [validated_mount()]} | {:error, {:invalid_mount, term()}}
    def validate(nil), do: {:ok, []}
    def validate([]), do: {:ok, []}

    def validate(mounts) when is_list(mounts) do
      Enum.reduce_while(mounts, {:ok, []}, fn mount, {:ok, acc} ->
        case validate_mount(mount) do
          {:ok, validated} -> {:cont, {:ok, [validated | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)
      |> case do
        {:ok, validated} -> {:ok, Enum.reverse(validated)}
        error -> error
      end
    end

    @doc """
    Resolves validated mounts by creating any auto-create volumes.

    Returns resolved mounts ready for the Fly API and a list of created volume IDs
    (for cleanup on failure).

    ## Returns
    - `{:ok, [resolved_mount], [created_volume_id]}` on success
    - `{:error, {:volume_creation_failed, name, reason}}` on failure
    """
    @spec resolve([validated_mount()], String.t(), String.t() | nil, String.t()) ::
            {:ok, [resolved_mount()], [String.t()]} | {:error, term()}
    def resolve(validated_mounts, app_name, region, api_token) do
      do_resolve(validated_mounts, app_name, region, api_token, [], [])
    end

    @doc """
    Cleans up a list of created volumes (best effort).

    Used to rollback volume creation when machine creation fails.
    """
    @spec cleanup([String.t()], String.t(), String.t()) :: :ok
    def cleanup([], _app_name, _api_token), do: :ok

    def cleanup(volume_ids, app_name, api_token) do
      Enum.each(volume_ids, fn vol_id ->
        Client.delete_volume(app_name, vol_id, api_token)
      end)
    end

    @doc """
    Lists all volumes for a Fly app with normalized structure.

    ## Returns
    - `{:ok, [volume]}` where each volume has:
      - `id` - Volume ID
      - `name` - Volume name
      - `state` - Volume state
      - `attached_machine_id` - Machine ID if attached, nil otherwise
      - `region` - Region code
      - `size_gb` - Size in GB
      - `created_at` - ISO8601 timestamp
    - `{:error, reason}` on failure
    """
    @spec list(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
    def list(app_name, api_token) do
      case Client.list_volumes(app_name, api_token) do
        {:ok, volumes} ->
          {:ok, Enum.map(volumes, &transform_volume/1)}

        {:error, _} = error ->
          error
      end
    end

    @doc """
    Gets volumes attached to a machine by reading its mount configuration.

    ## Returns
    - `{:ok, [%{volume: vol_id, path: path}]}` on success
    - `{:error, :not_found}` if machine doesn't exist
    - `{:error, reason}` on failure
    """
    @spec get_machine_volumes(String.t(), String.t(), String.t()) ::
            {:ok, [map()]} | {:error, term()}
    def get_machine_volumes(app_name, machine_id, api_token) do
      case Client.get_machine(app_name, machine_id, api_token) do
        {:ok, %{"config" => %{"mounts" => mounts}}} when is_list(mounts) ->
          volumes =
            Enum.map(mounts, fn mount ->
              %{volume: mount["volume"], path: mount["path"]}
            end)

          {:ok, volumes}

        {:ok, _} ->
          {:ok, []}

        {:error, _} = error ->
          error
      end
    end

    # Private functions

    defp validate_mount(%{volume: vol_id, path: path})
         when is_binary(vol_id) and is_binary(path) do
      {:ok, {:existing, vol_id, path}}
    end

    defp validate_mount(%{name: name, path: path, size_gb: size})
         when is_binary(name) and is_binary(path) and is_integer(size) and size > 0 do
      {:ok, {:create, name, path, size}}
    end

    defp validate_mount(mount) do
      {:error, {:invalid_mount, mount}}
    end

    defp do_resolve([], _app, _region, _token, resolved, created) do
      {:ok, Enum.reverse(resolved), Enum.reverse(created)}
    end

    defp do_resolve([{:existing, vol_id, path} | rest], app, region, token, resolved, created) do
      mount = %{volume: vol_id, path: path}
      do_resolve(rest, app, region, token, [mount | resolved], created)
    end

    defp do_resolve([{:create, name, path, size} | rest], app, region, token, resolved, created) do
      case Client.create_volume(app, name, size, region, token) do
        {:ok, %{"id" => vol_id}} ->
          mount = %{volume: vol_id, path: path}
          do_resolve(rest, app, region, token, [mount | resolved], [vol_id | created])

        {:error, reason} ->
          cleanup(created, app, token)
          {:error, {:volume_creation_failed, name, reason}}
      end
    end

    defp transform_volume(vol) do
      %{
        id: vol["id"],
        name: vol["name"],
        state: vol["state"],
        attached_machine_id: vol["attached_machine_id"],
        region: vol["region"],
        size_gb: vol["size_gb"],
        created_at: vol["created_at"]
      }
    end
  end
end
