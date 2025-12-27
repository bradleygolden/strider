if Code.ensure_loaded?(Req) do
  defmodule Strider.Sandbox.Adapters.Fly.Client do
    @moduledoc """
    HTTP client for the Fly Machines API.

    Uses a token bucket rate limiter to proactively enforce rate limits
    and prevent 429 responses.

    ## Rate Limits

    Fly API has rate limits:
    - 1 req/s per action (create, start, stop, delete)
    - 3 req/s burst
    - 5 req/s for GET machine (10 burst)

    The rate limiter handles throttling. Retry logic is kept as a safety net
    for transient 429s that slip through.
    """

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
