if Code.ensure_loaded?(Req) do
  defmodule Strider.Sandbox.Adapters.Fly.Client do
    @moduledoc """
    HTTP client for the Fly Machines API.

    Handles authentication, request formatting, and retry logic with backoff
    for rate limits.

    ## Rate Limits

    Fly API has rate limits:
    - 1 req/s per action (create, start, stop, delete)
    - 3 req/s burst
    - 5 req/s for GET machine (10 burst)

    This client implements retry with exponential backoff for 429 responses.
    """

    @base_url "https://api.machines.dev/v1"
    @max_retries 3
    @base_delay_ms 1000

    @doc """
    Makes a GET request to the Fly Machines API.
    """
    def get(path, api_token) do
      request(:get, path, nil, api_token)
    end

    @doc """
    Makes a POST request to the Fly Machines API.
    """
    def post(path, body, api_token) do
      request(:post, path, body, api_token)
    end

    @doc """
    Makes a DELETE request to the Fly Machines API.
    """
    def delete(path, api_token) do
      request(:delete, path, nil, api_token)
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
          delay = (@base_delay_ms * :math.pow(2, retry_count)) |> round()
          Process.sleep(delay)
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
