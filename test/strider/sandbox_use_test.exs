defmodule Strider.SandboxUseTest do
  use ExUnit.Case, async: false

  alias Strider.Sandbox
  alias Strider.Sandbox.Adapters.Test, as: TestAdapter
  alias Strider.Sandbox.Runner

  setup do
    adapter_name = :"test_adapter_#{System.unique_integer([:positive])}"
    start_supervised!({TestAdapter, name: adapter_name})
    {:ok, adapter_name: adapter_name}
  end

  defmodule TestSandbox do
    use Strider.Sandbox,
      adapter: Strider.Sandbox.Adapters.Test,
      pool_size: 2
  end

  describe "use Strider.Sandbox" do
    test "defines child_spec/1" do
      assert function_exported?(TestSandbox, :child_spec, 1)
      spec = TestSandbox.child_spec([])
      assert spec.id == TestSandbox
      assert spec.type == :worker
    end

    test "defines start_link/1" do
      assert function_exported?(TestSandbox, :start_link, 1)
    end

    test "defines run/2" do
      assert function_exported?(TestSandbox, :run, 2)
    end

    test "defines run!/2" do
      assert function_exported?(TestSandbox, :run!, 2)
    end

    test "defines transaction/2" do
      assert function_exported?(TestSandbox, :transaction, 2)
    end

    test "defines transaction!/2" do
      assert function_exported?(TestSandbox, :transaction!, 2)
    end

    test "defines end_session/2" do
      assert function_exported?(TestSandbox, :end_session, 2)
    end
  end

  describe "dynamic sandbox module" do
    test "can start and run commands", %{adapter_name: adapter_name} do
      sandbox_name = :"sandbox_#{System.unique_integer([:positive])}"

      defmodule :"Elixir.DynamicSandbox#{System.unique_integer([:positive])}" do
        use Strider.Sandbox,
          adapter: Strider.Sandbox.Adapters.Test,
          pool_size: 0
      end
      |> then(fn _mod ->
        start_supervised!(
          {Runner,
           {sandbox_name,
            [
              adapter: TestAdapter,
              adapter_opts: [agent_name: adapter_name],
              pool_size: 0
            ]}}
        )

        {:ok, result} = Runner.run(sandbox_name, "echo hello")
        assert result.exit_code == 0
      end)
    end
  end

  describe "integration with supervision tree" do
    test "can be started via start_supervised", %{adapter_name: adapter_name} do
      sandbox_name = :"sandbox_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Runner,
         {sandbox_name,
          [
            adapter: TestAdapter,
            adapter_opts: [agent_name: adapter_name],
            pool_size: 0
          ]}}
      )

      {:ok, result} = Runner.run(sandbox_name, "echo test")
      assert result.exit_code == 0
    end

    test "run with session creates persistent sandbox", %{adapter_name: adapter_name} do
      sandbox_name = :"sandbox_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Runner,
         {sandbox_name,
          [
            adapter: TestAdapter,
            adapter_opts: [agent_name: adapter_name],
            pool_size: 0,
            session_volume: %{name: "data", path: "/data", size_gb: 1}
          ]}}
      )

      {:ok, _} =
        Runner.transaction(
          sandbox_name,
          fn sb ->
            Sandbox.write_file(sb, "/data/state.json", ~s({"count": 1}))
          end,
          session: "user-1"
        )

      {:ok, result} =
        Runner.transaction(
          sandbox_name,
          fn sb ->
            Sandbox.read_file(sb, "/data/state.json")
          end,
          session: "user-1"
        )

      assert result == {:ok, ~s({"count": 1})}
    end
  end
end
