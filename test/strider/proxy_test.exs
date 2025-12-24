if Code.ensure_loaded?(Plug) do
  defmodule Strider.ProxyTest do
    use ExUnit.Case, async: true

    import Plug.Test
    import Plug.Conn

    alias Strider.Proxy

    describe "init/1" do
      test "requires upstream option" do
        assert_raise KeyError, fn ->
          Proxy.init(request_headers: fn _ -> [] end)
        end
      end

      test "requires request_headers option" do
        assert_raise KeyError, fn ->
          Proxy.init(upstream: "https://example.com")
        end
      end

      test "parses options correctly" do
        config =
          Proxy.init(
            upstream: "https://api.anthropic.com",
            request_headers: fn _ -> [{"x-api-key", "test"}] end,
            timeout: 30_000
          )

        assert config.upstream == "https://api.anthropic.com"
        assert is_function(config.request_headers, 1)
        assert config.timeout == 30_000
      end

      test "uses default timeout" do
        config =
          Proxy.init(
            upstream: "https://api.anthropic.com",
            request_headers: fn _ -> [] end
          )

        assert config.timeout == 600_000
      end
    end

    describe "request_headers function" do
      test "is called with conn" do
        test_pid = self()

        config =
          Proxy.init(
            upstream: "https://api.anthropic.com",
            request_headers: fn conn ->
              send(test_pid, {:called_with, conn})
              [{"x-api-key", "test-key"}]
            end
          )

        headers = config.request_headers.(conn(:post, "/v1/messages"))
        assert headers == [{"x-api-key", "test-key"}]

        assert_received {:called_with, %Plug.Conn{}}
      end

      test "can access conn.assigns" do
        config =
          Proxy.init(
            upstream: "https://api.anthropic.com",
            request_headers: fn conn ->
              [{"x-api-key", conn.assigns[:api_key]}]
            end
          )

        conn =
          conn(:post, "/v1/messages")
          |> assign(:api_key, "from-assigns")

        headers = config.request_headers.(conn)
        assert headers == [{"x-api-key", "from-assigns"}]
      end
    end
  end
end
