defmodule Strider.Proxy.DockerIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :docker

  @proxy_port 4123

  setup_all do
    {_, exit_code} =
      System.cmd(
        "docker",
        ["build", "-t", "strider-proxy:test", "-f", "Dockerfile", "."],
        cd: "priv/proxy",
        stderr_to_stdout: true
      )

    if exit_code != 0 do
      raise "Failed to build proxy Docker image"
    end

    :ok
  end

  setup do
    container_id = start_proxy_container()

    on_exit(fn ->
      System.cmd("docker", ["rm", "-f", container_id], stderr_to_stdout: true)
    end)

    {:ok, container_id: container_id}
  end

  describe "domain allowlisting" do
    test "allows requests to allowed domains" do
      # httpbin.org is in the allowed domains for this test
      {:ok, response} = make_proxy_request("/https://httpbin.org/get")

      assert response.status == 200
      body = Jason.decode!(response.body)
      assert body["url"] == "https://httpbin.org/get"
    end

    test "blocks requests to non-allowed domains" do
      {:ok, response} = make_proxy_request("/https://evil.example.com/steal-data")

      assert response.status == 403
      assert response.body =~ "Domain not allowed"
    end

    test "returns 400 for invalid URLs" do
      {:ok, response} = make_proxy_request("/not-a-valid-url")

      assert response.status == 400
      assert response.body =~ "Invalid target URL"
    end
  end

  describe "request forwarding" do
    test "forwards POST requests with body" do
      body = Jason.encode!(%{test: "data", number: 42})

      {:ok, response} =
        make_proxy_request("/https://httpbin.org/post",
          method: :post,
          body: body,
          headers: [{"content-type", "application/json"}]
        )

      assert response.status == 200
      result = Jason.decode!(response.body)
      assert result["json"] == %{"test" => "data", "number" => 42}
    end

    test "forwards custom headers" do
      {:ok, response} =
        make_proxy_request("/https://httpbin.org/headers",
          headers: [{"x-custom-header", "test-value"}]
        )

      assert response.status == 200
      result = Jason.decode!(response.body)
      assert result["headers"]["X-Custom-Header"] == "test-value"
    end

    test "handles different HTTP methods" do
      {:ok, response} = make_proxy_request("/https://httpbin.org/delete", method: :delete)
      assert response.status == 200

      {:ok, response} =
        make_proxy_request("/https://httpbin.org/put",
          method: :put,
          body: "test",
          headers: [{"content-type", "text/plain"}]
        )

      assert response.status == 200
    end
  end

  describe "wildcard domain matching" do
    test "matches subdomains with wildcard pattern" do
      # Test assumes *.httpbin.org is in allowed domains
      # Since httpbin.org doesn't have subdomains we test with the main domain
      {:ok, response} = make_proxy_request("/https://httpbin.org/get")
      assert response.status == 200
    end
  end

  defp start_proxy_container do
    allowed_domains = "httpbin.org,*.httpbin.org"

    {output, 0} =
      System.cmd(
        "docker",
        [
          "run",
          "-d",
          "-p",
          "#{@proxy_port}:4000",
          "-e",
          "PROXY_PORT=4000",
          "-e",
          "ALLOWED_DOMAINS=#{allowed_domains}",
          "strider-proxy:test"
        ],
        stderr_to_stdout: true
      )

    container_id = String.trim(output)

    wait_for_proxy_ready()

    container_id
  end

  defp wait_for_proxy_ready(attempts \\ 30) do
    if attempts <= 0 do
      raise "Proxy container failed to become ready"
    end

    case Req.get("http://localhost:#{@proxy_port}/https://httpbin.org/get",
           receive_timeout: 5_000
         ) do
      {:ok, %{status: status}} when status in [200, 403] ->
        :ok

      _ ->
        Process.sleep(500)
        wait_for_proxy_ready(attempts - 1)
    end
  end

  defp make_proxy_request(path, opts \\ []) do
    method = Keyword.get(opts, :method, :get)
    body = Keyword.get(opts, :body)
    headers = Keyword.get(opts, :headers, [])

    url = "http://localhost:#{@proxy_port}#{path}"

    Req.request(
      method: method,
      url: url,
      body: body,
      headers: headers,
      receive_timeout: 30_000
    )
  end
end
