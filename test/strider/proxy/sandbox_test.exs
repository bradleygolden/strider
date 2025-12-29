if Code.ensure_loaded?(Plug) do
  defmodule Strider.Proxy.SandboxTest do
    use ExUnit.Case, async: true

    import Plug.Test

    alias Strider.Proxy.Sandbox

    describe "init/1" do
      test "requires allowed_domains option" do
        assert_raise KeyError, fn ->
          Sandbox.init(credentials: %{})
        end
      end

      test "parses options correctly" do
        config =
          Sandbox.init(
            allowed_domains: ["api.anthropic.com", "api.github.com"],
            credentials: %{
              "api.anthropic.com" => [{"x-api-key", "test-key"}]
            },
            timeout: 30_000
          )

        assert config.allowed_domains == ["api.anthropic.com", "api.github.com"]
        assert config.credentials == %{"api.anthropic.com" => [{"x-api-key", "test-key"}]}
        assert config.timeout == 30_000
      end

      test "uses default values" do
        config = Sandbox.init(allowed_domains: ["example.com"])

        assert config.allowed_domains == ["example.com"]
        assert config.credentials == %{}
        assert config.timeout == 600_000
      end
    end

    describe "domain allowlist" do
      test "rejects requests to non-allowed domains" do
        config = Sandbox.init(allowed_domains: ["api.anthropic.com"])

        # Request format: POST /https://evil.com/data
        conn =
          conn(:post, "/https://evil.com/data")
          |> Sandbox.call(config)

        assert conn.status == 403
        assert conn.resp_body =~ "Domain not allowed"
      end

      test "rejects invalid target URLs" do
        config = Sandbox.init(allowed_domains: ["api.anthropic.com"])

        conn =
          conn(:post, "/not-a-valid-url")
          |> Sandbox.call(config)

        assert conn.status == 400
        assert conn.resp_body =~ "Invalid target URL"
      end

      test "supports wildcard domain patterns" do
        config = Sandbox.init(allowed_domains: ["*.anthropic.com"])

        # Test allowed subdomain
        assert domain_allowed?("api.anthropic.com", config.allowed_domains)
        assert domain_allowed?("sub.api.anthropic.com", config.allowed_domains)

        # Test non-matching domain
        refute domain_allowed?("anthropic.org", config.allowed_domains)
      end

      test "exact domain matching" do
        config = Sandbox.init(allowed_domains: ["api.anthropic.com"])

        assert domain_allowed?("api.anthropic.com", config.allowed_domains)
        refute domain_allowed?("other.anthropic.com", config.allowed_domains)
        refute domain_allowed?("api.anthropic.com.evil.com", config.allowed_domains)
      end
    end

    describe "credential injection" do
      test "credentials are configured per domain" do
        config =
          Sandbox.init(
            allowed_domains: ["api.anthropic.com", "api.github.com"],
            credentials: %{
              "api.anthropic.com" => [
                {"x-api-key", "anthropic-key"},
                {"anthropic-version", "2023-06-01"}
              ],
              "api.github.com" => [
                {"authorization", "Bearer github-token"}
              ]
            }
          )

        assert config.credentials["api.anthropic.com"] == [
                 {"x-api-key", "anthropic-key"},
                 {"anthropic-version", "2023-06-01"}
               ]

        assert config.credentials["api.github.com"] == [
                 {"authorization", "Bearer github-token"}
               ]
      end

      test "domains without credentials use empty list" do
        config =
          Sandbox.init(
            allowed_domains: ["example.com"],
            credentials: %{}
          )

        assert Map.get(config.credentials, "example.com", []) == []
      end
    end

    # Helper function to test domain matching logic
    defp domain_allowed?(host, allowed_domains) do
      Enum.any?(allowed_domains, fn pattern ->
        if String.starts_with?(pattern, "*.") do
          suffix = String.slice(pattern, 1..-1//1)
          String.ends_with?(host, suffix) or host == String.slice(pattern, 2..-1//1)
        else
          host == pattern
        end
      end)
    end
  end
end
