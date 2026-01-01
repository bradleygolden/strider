if Code.ensure_loaded?(Req) do
  defmodule Strider.Sandbox.Adapters.Fly.Client do
    @moduledoc false

    alias Strider.Sandbox.Adapters.Fly.RateLimiter

    @base_url "https://api.machines.dev/v1"
    @max_retries 3

    @doc """
    Makes a GET request to the Fly Machines API.
    """
    def get(path, api_token) do
      :ok = RateLimiter.acquire(:read)
      request(:get, path, nil, api_token)
    end

    @doc """
    Makes a POST request to the Fly Machines API.
    """
    def post(path, body, api_token) do
      :ok = RateLimiter.acquire(:mutation)
      request(:post, path, body, api_token)
    end

    @doc """
    Makes a DELETE request to the Fly Machines API.
    """
    def delete(path, api_token) do
      :ok = RateLimiter.acquire(:mutation)
      request(:delete, path, nil, api_token)
    end

    @doc """
    Creates a new Fly volume.

    ## Parameters
    - `app_name` - The Fly app name
    - `name` - Volume name (must be unique within app)
    - `size_gb` - Volume size in GB
    - `region` - Region for the volume (nil uses Fly's default)
    - `api_token` - Fly API token

    ## Returns
    - `{:ok, %{"id" => volume_id, ...}}` on success
    - `{:error, reason}` on failure
    """
    def create_volume(app_name, name, size_gb, region, api_token) do
      body = %{name: name, size_gb: size_gb}
      body = if region, do: Map.put(body, :region, region), else: body
      post("/apps/#{app_name}/volumes", body, api_token)
    end

    @doc """
    Deletes a Fly volume.

    ## Parameters
    - `app_name` - The Fly app name
    - `volume_id` - The volume ID to delete
    - `api_token` - Fly API token

    ## Returns
    - `:ok` on success (including 404 - already deleted)
    - `{:error, reason}` on failure
    """
    def delete_volume(app_name, volume_id, api_token) do
      case delete("/apps/#{app_name}/volumes/#{volume_id}", api_token) do
        {:ok, _} -> :ok
        {:error, :not_found} -> :ok
        error -> error
      end
    end

    @doc """
    Lists all volumes for a Fly app.

    ## Parameters
    - `app_name` - The Fly app name
    - `api_token` - Fly API token

    ## Returns
    - `{:ok, [%{"id" => volume_id, "name" => name, "region" => region, "attached_machine_id" => machine_id | nil, ...}]}` on success
    - `{:error, reason}` on failure
    """
    def list_volumes(app_name, api_token) do
      get("/apps/#{app_name}/volumes", api_token)
    end

    @doc """
    Gets details for a specific volume.

    ## Parameters
    - `app_name` - The Fly app name
    - `volume_id` - The volume ID
    - `api_token` - Fly API token

    ## Returns
    - `{:ok, %{"id" => volume_id, "name" => name, "attached_machine_id" => machine_id | nil, ...}}` on success
    - `{:error, :not_found}` if volume doesn't exist
    - `{:error, reason}` on failure
    """
    def get_volume(app_name, volume_id, api_token) do
      get("/apps/#{app_name}/volumes/#{volume_id}", api_token)
    end

    @doc """
    Gets details for a specific machine.

    ## Parameters
    - `app_name` - The Fly app name
    - `machine_id` - The machine ID
    - `api_token` - Fly API token

    ## Returns
    - `{:ok, %{"id" => machine_id, "state" => state, "config" => %{"mounts" => [...], ...}, ...}}` on success
    - `{:error, :not_found}` if machine doesn't exist
    - `{:error, reason}` on failure
    """
    def get_machine(app_name, machine_id, api_token) do
      get("/apps/#{app_name}/machines/#{machine_id}", api_token)
    end

    @doc """
    Lists all machines for a Fly app.

    ## Parameters
    - `app_name` - The Fly app name
    - `api_token` - Fly API token

    ## Returns
    - `{:ok, [%{"id" => machine_id, "state" => state, "region" => region, ...}]}` on success
    - `{:error, reason}` on failure
    """
    def list_machines(app_name, api_token) do
      get("/apps/#{app_name}/machines", api_token)
    end

    @doc """
    Creates a new Fly app.

    ## Parameters
    - `app_name` - The app name (must be globally unique on Fly)
    - `org_slug` - The Fly organization slug
    - `network` - Optional custom network name for isolation (nil uses default shared network)
    - `api_token` - Fly API token

    ## Returns
    - `{:ok, %{"name" => app_name, ...}}` on success
    - `{:error, {:api_error, 422, "..."}}` if app already exists
    - `{:error, reason}` on failure
    """
    def create_app(app_name, org_slug, network, api_token) do
      body = %{app_name: app_name, org_slug: org_slug}
      body = if network, do: Map.put(body, :network, network), else: body
      post("/apps", body, api_token)
    end

    @doc """
    Gets details for a Fly app.

    ## Parameters
    - `app_name` - The Fly app name
    - `api_token` - Fly API token

    ## Returns
    - `{:ok, %{"name" => app_name, "organization" => %{...}, ...}}` on success
    - `{:error, :not_found}` if app doesn't exist
    - `{:error, reason}` on failure
    """
    def get_app(app_name, api_token) do
      get("/apps/#{app_name}", api_token)
    end

    @doc """
    Deletes a Fly app and all its resources (machines, volumes, etc).

    WARNING: This is destructive and cannot be undone.

    ## Parameters
    - `app_name` - The Fly app name
    - `api_token` - Fly API token

    ## Returns
    - `:ok` on success (including 404 - already deleted)
    - `{:error, reason}` on failure
    """
    def delete_app(app_name, api_token) do
      case delete("/apps/#{app_name}", api_token) do
        {:ok, _} -> :ok
        {:error, :not_found} -> :ok
        error -> error
      end
    end

    defp request(method, path, body, api_token, retry_count \\ 0) do
      url = @base_url <> path

      req =
        Req.new(
          method: method,
          url: url,
          headers: [
            {"authorization", "Bearer #{api_token}"},
            {"content-type", "application/json"}
          ],
          receive_timeout: 120_000
        )

      req = if body, do: Req.merge(req, json: body), else: req

      case Req.request(req) do
        {:ok, %{status: status, body: response_body}} when status in 200..299 ->
          {:ok, response_body}

        {:ok, %{status: 404}} ->
          {:error, :not_found}

        {:ok, %{status: 429}} when retry_count < @max_retries ->
          # Rate limiter will naturally throttle the retry
          request(method, path, body, api_token, retry_count + 1)

        {:ok, %{status: 429}} ->
          {:error, :rate_limited}

        {:ok, %{status: status, body: response_body}} when status >= 400 ->
          error_message = extract_error(response_body)
          {:error, {:api_error, status, error_message}}

        {:error, %{reason: :timeout}} ->
          {:error, :timeout}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp extract_error(%{"error" => error}) when is_binary(error), do: error
    defp extract_error(%{"error" => %{"message" => message}}), do: message
    defp extract_error(%{"message" => message}), do: message
    defp extract_error(body) when is_binary(body), do: body
    defp extract_error(body), do: inspect(body)
  end
end
