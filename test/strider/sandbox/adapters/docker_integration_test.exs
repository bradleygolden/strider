defmodule Strider.Sandbox.Adapters.DockerIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :docker

  alias Strider.Sandbox
  alias Strider.Sandbox.Adapters.Docker

  setup_all do
    {_, 0} =
      System.cmd(
        "docker",
        ["build", "-t", "strider-sandbox:test", "-f", "priv/sandbox/Dockerfile", "priv/sandbox"],
        stderr_to_stdout: true
      )

    :ok
  end

  setup do
    on_exit(fn ->
      {output, _} =
        System.cmd(
          "docker",
          ["ps", "-aq", "--filter", "name=strider-sandbox-"],
          stderr_to_stdout: true
        )

      for id <- String.split(output, "\n", trim: true) do
        System.cmd("docker", ["rm", "-f", id], stderr_to_stdout: true)
      end
    end)

    :ok
  end

  describe "network mode: none (default)" do
    test "can execute basic commands" do
      {:ok, sandbox} = Sandbox.create({Docker, %{image: "strider-sandbox:test"}})

      {:ok, result} = Sandbox.exec(sandbox, "echo 'hello world'")
      assert result.exit_code == 0
      assert String.contains?(result.stdout, "hello world")

      Sandbox.terminate(sandbox)
    end

    test "blocks outbound network traffic" do
      {:ok, sandbox} = Sandbox.create({Docker, %{image: "strider-sandbox:test"}})

      {:ok, result} =
        Sandbox.exec(
          sandbox,
          "curl -s --connect-timeout 2 https://example.com || echo 'blocked'",
          timeout: 10_000
        )

      assert String.contains?(result.stdout, "blocked") or result.exit_code != 0

      Sandbox.terminate(sandbox)
    end

    test "allows loopback traffic" do
      {:ok, sandbox} = Sandbox.create({Docker, %{image: "strider-sandbox:test"}})

      {:ok, result} = Sandbox.exec(sandbox, "ping -c 1 127.0.0.1")
      assert result.exit_code == 0

      Sandbox.terminate(sandbox)
    end
  end

  describe "network mode: proxy_only" do
    test "sets proxy environment variables" do
      {:ok, sandbox} =
        Sandbox.create(
          {Docker,
           %{
             image: "strider-sandbox:test",
             proxy: [ip: "172.17.0.1", port: 4000]
           }}
        )

      {:ok, result} = Sandbox.exec(sandbox, "echo $STRIDER_NETWORK_MODE")
      assert String.contains?(result.stdout, "proxy_only")

      {:ok, result} = Sandbox.exec(sandbox, "echo $STRIDER_PROXY_IP:$STRIDER_PROXY_PORT")
      assert String.contains?(result.stdout, "172.17.0.1:4000")

      Sandbox.terminate(sandbox)
    end

    test "blocks non-proxy traffic" do
      {:ok, sandbox} =
        Sandbox.create(
          {Docker,
           %{
             image: "strider-sandbox:test",
             proxy: [ip: "172.17.0.1", port: 4000]
           }}
        )

      {:ok, result} =
        Sandbox.exec(
          sandbox,
          "curl -s --connect-timeout 2 https://example.com || echo 'blocked'",
          timeout: 10_000
        )

      assert String.contains?(result.stdout, "blocked") or result.exit_code != 0

      Sandbox.terminate(sandbox)
    end
  end

  describe "file operations" do
    test "can write and read files" do
      {:ok, sandbox} = Sandbox.create({Docker, %{image: "strider-sandbox:test"}})

      content = "test content: #{:rand.uniform(1000)}"
      :ok = Sandbox.write_file(sandbox, "/workspace/test.txt", content)
      {:ok, read_content} = Sandbox.read_file(sandbox, "/workspace/test.txt")

      assert read_content == content

      Sandbox.terminate(sandbox)
    end
  end

  describe "polyglot execution" do
    test "can run Python" do
      {:ok, sandbox} = Sandbox.create({Docker, %{image: "strider-sandbox:test"}})

      {:ok, result} = Sandbox.exec(sandbox, "python3 -c 'print(1 + 1)'")
      assert result.exit_code == 0
      assert String.contains?(result.stdout, "2")

      Sandbox.terminate(sandbox)
    end

    test "can run Node.js" do
      {:ok, sandbox} = Sandbox.create({Docker, %{image: "strider-sandbox:test"}})

      {:ok, result} = Sandbox.exec(sandbox, "node -e 'console.log(1 + 1)'")
      assert result.exit_code == 0
      assert String.contains?(result.stdout, "2")

      Sandbox.terminate(sandbox)
    end
  end
end
