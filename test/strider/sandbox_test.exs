defmodule Strider.SandboxTest do
  use ExUnit.Case, async: true

  alias Strider.Sandbox
  alias Strider.Sandbox.Adapters.Test, as: TestAdapter
  alias Strider.Sandbox.ExecResult
  alias Strider.Sandbox.Instance

  setup do
    start_supervised!(TestAdapter)
    :ok
  end

  describe "create/1" do
    test "creates a sandbox with the test adapter" do
      {:ok, sandbox} = Sandbox.create({TestAdapter, %{image: "test:latest"}})

      assert %Instance{} = sandbox
      assert sandbox.adapter == TestAdapter
      assert sandbox.config == %{image: "test:latest"}
      assert sandbox.status == :running
      assert is_integer(sandbox.created_at)
    end

    test "accepts keyword list config" do
      {:ok, sandbox} = Sandbox.create({TestAdapter, image: "test:latest"})

      assert sandbox.config == %{image: "test:latest"}
    end
  end

  describe "from_id/3" do
    test "reconstructs a sandbox from an ID" do
      sandbox = Sandbox.from_id(TestAdapter, "existing-sandbox-123")

      assert %Instance{} = sandbox
      assert sandbox.id == "existing-sandbox-123"
      assert sandbox.adapter == TestAdapter
      assert sandbox.config == %{}
    end

    test "accepts optional config" do
      sandbox = Sandbox.from_id(TestAdapter, "existing-sandbox-123", %{foo: "bar"})

      assert sandbox.config == %{foo: "bar"}
    end
  end

  describe "exec/3" do
    test "executes a command and returns result" do
      {:ok, sandbox} = Sandbox.create({TestAdapter, %{}})
      {:ok, result} = Sandbox.exec(sandbox, "echo hello")

      assert %ExecResult{} = result
      assert result.stdout == "mock: echo hello"
      assert result.exit_code == 0
    end

    test "uses mock response when set" do
      {:ok, sandbox} = Sandbox.create({TestAdapter, %{}})

      TestAdapter.set_exec_response(
        sandbox.id,
        "node --version",
        {:ok, %ExecResult{stdout: "v22.0.0\n", exit_code: 0}}
      )

      {:ok, result} = Sandbox.exec(sandbox, "node --version")

      assert result.stdout == "v22.0.0\n"
    end

    test "records command in history" do
      {:ok, sandbox} = Sandbox.create({TestAdapter, %{}})

      Sandbox.exec(sandbox, "first command")
      Sandbox.exec(sandbox, "second command")

      history = TestAdapter.get_exec_history(sandbox.id)

      assert "first command" in history
      assert "second command" in history
    end
  end

  describe "terminate/1" do
    test "terminates the sandbox" do
      {:ok, sandbox} = Sandbox.create({TestAdapter, %{}})

      assert :ok = Sandbox.terminate(sandbox)
      assert Sandbox.status(sandbox) == :terminated
    end
  end

  describe "status/1" do
    test "returns running for new sandbox" do
      {:ok, sandbox} = Sandbox.create({TestAdapter, %{}})

      assert Sandbox.status(sandbox) == :running
    end

    test "returns terminated after termination" do
      {:ok, sandbox} = Sandbox.create({TestAdapter, %{}})
      Sandbox.terminate(sandbox)

      assert Sandbox.status(sandbox) == :terminated
    end
  end

  describe "get_url/2" do
    test "returns URL for exposed port" do
      {:ok, sandbox} = Sandbox.create({TestAdapter, %{}})

      {:ok, url} = Sandbox.get_url(sandbox, 4000)

      assert url == "http://#{sandbox.id}:4000"
    end

    test "resolves container port to host port when port_map exists" do
      sandbox =
        Sandbox.from_id(TestAdapter, "test-sandbox", %{}, %{port_map: %{4001 => 8080}})

      {:ok, url} = Sandbox.get_url(sandbox, 4001)

      assert url == "http://test-sandbox:8080"
    end

    test "uses original port when no mapping exists for the port" do
      sandbox =
        Sandbox.from_id(TestAdapter, "test-sandbox", %{}, %{port_map: %{4001 => 8080}})

      {:ok, url} = Sandbox.get_url(sandbox, 3000)

      assert url == "http://test-sandbox:3000"
    end

    test "uses original port when port_map is empty" do
      sandbox = Sandbox.from_id(TestAdapter, "test-sandbox", %{}, %{port_map: %{}})

      {:ok, url} = Sandbox.get_url(sandbox, 4001)

      assert url == "http://test-sandbox:4001"
    end
  end
end
