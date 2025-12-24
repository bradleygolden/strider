if Code.ensure_loaded?(Plug) do
  defmodule Strider.Proxy do
    @moduledoc """
    A minimal, transparent HTTP proxy for forwarding LLM API requests.

    Strider.Proxy is a Plug that forwards requests to an upstream server,
    injecting headers along the way. It supports both streaming (SSE) and
    non-streaming requests.

    ## Usage

        # In your router
        forward "/v1", Strider.Proxy,
          upstream: "https://api.anthropic.com",
          request_headers: fn _conn ->
            [
              {"x-api-key", System.get_env("ANTHROPIC_API_KEY")},
              {"anthropic-version", "2023-06-01"},
              {"content-type", "application/json"}
            ]
          end

    ## Options

    - `:upstream` (required) - The base URL to forward requests to
    - `:request_headers` (required) - A function that takes a `Plug.Conn` and
      returns a list of `{header_name, header_value}` tuples
    - `:timeout` - Request timeout in milliseconds (default: 600_000)

    ## Request Flow

    1. Sandbox calls `POST http://proxy:4000/v1/messages`
    2. Router forwards to Strider.Proxy
    3. Strider.Proxy builds URL: `https://api.anthropic.com/v1/messages`
    4. Injects headers from `request_headers` function
    5. Forwards request body unchanged
    6. Streams response back to client
    """

    @behaviour Plug

    import Plug.Conn

    @default_timeout 600_000

    @impl true
    def init(opts) do
      %{
        upstream: Keyword.fetch!(opts, :upstream),
        request_headers: Keyword.fetch!(opts, :request_headers),
        timeout: Keyword.get(opts, :timeout, @default_timeout)
      }
    end

    @impl true
    def call(conn, config) do
      headers = config.request_headers.(conn)
      forward_request(conn, config, headers)
    end

    defp forward_request(conn, config, headers) do
      {:ok, body, conn} = read_body(conn)
      url = build_url(config.upstream, conn)

      if streaming_request?(body) do
        stream_request(conn, url, headers, body, config.timeout)
      else
        sync_request(conn, url, headers, body, conn.method, config.timeout)
      end
    end

    defp build_url(upstream, conn) do
      path = "/" <> Enum.join(conn.path_info, "/")
      query = if conn.query_string != "", do: "?#{conn.query_string}", else: ""
      upstream <> path <> query
    end

    defp streaming_request?(body) when is_binary(body) do
      String.contains?(body, "\"stream\":true") or
        String.contains?(body, "\"stream\": true")
    end

    defp streaming_request?(_), do: false

    defp stream_request(conn, url, headers, body, timeout) do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(200)

      task =
        Task.async(fn ->
          Req.post(url,
            headers: headers,
            body: body,
            into: :self,
            receive_timeout: timeout
          )
        end)

      receive_chunks(conn, task.ref, timeout)
    end

    defp receive_chunks(conn, ref, timeout) do
      receive do
        {^ref, {:data, data}} ->
          case chunk(conn, data) do
            {:ok, new_conn} -> receive_chunks(new_conn, ref, timeout)
            {:error, _} -> conn
          end

        {^ref, %Req.Response{}} ->
          conn

        {:DOWN, ^ref, :process, _pid, _reason} ->
          conn
      after
        timeout -> conn
      end
    end

    defp sync_request(conn, url, headers, body, method, timeout) do
      req_method = method |> to_string() |> String.downcase() |> String.to_atom()

      response =
        Req.request!(
          method: req_method,
          url: url,
          headers: headers,
          body: body,
          receive_timeout: timeout
        )

      conn
      |> put_resp_content_type(get_content_type(response.headers))
      |> send_resp(response.status, response.body)
    end

    defp get_content_type(headers) do
      case List.keyfind(headers, "content-type", 0) do
        {_, value} -> value
        nil -> "application/json"
      end
    end
  end
end
