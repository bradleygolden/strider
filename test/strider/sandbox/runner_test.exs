defmodule Strider.Sandbox.RunnerTest do
  use ExUnit.Case, async: false

  alias Strider.Sandbox
  alias Strider.Sandbox.Adapters.Test, as: TestAdapter
  alias Strider.Sandbox.Runner

  setup do
    adapter_name = :"test_adapter_#{System.unique_integer([:positive])}"
    start_supervised!({TestAdapter, name: adapter_name})
    {:ok, adapter_name: adapter_name}
  end

  describe "start_link/2" do
    test "starts the runner GenServer", %{adapter_name: adapter_name} do
      runner_name = :"runner_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Runner.start_link(runner_name,
          adapter: TestAdapter,
          adapter_opts: [agent_name: adapter_name],
          pool_size: 2
        )

      assert Process.alive?(pid)
    end
  end

  describe "run/3" do
    test "executes a command in a sandbox", %{adapter_name: adapter_name} do
      runner_name = :"runner_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Runner,
         {runner_name,
          [
            adapter: TestAdapter,
            adapter_opts: [agent_name: adapter_name],
            pool_size: 1
          ]}}
      )

      {:ok, result} = Runner.run(runner_name, "echo hello")

      assert result.exit_code == 0
      assert result.stdout =~ "echo hello"
    end

    test "returns error for failed command", %{adapter_name: adapter_name} do
      runner_name = :"runner_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Runner,
         {runner_name,
          [
            adapter: TestAdapter,
            adapter_opts: [agent_name: adapter_name],
            pool_size: 1
          ]}}
      )

      {:ok, sandbox} = Sandbox.create({TestAdapter, %{agent_name: adapter_name}})

      TestAdapter.set_exec_response(
        sandbox.id,
        "fail",
        {:error, :command_failed},
        adapter_name
      )

      {:ok, result} = Runner.run(runner_name, "echo test")
      assert result.exit_code == 0
    end
  end

  describe "run/3 with session" do
    test "reuses the same sandbox for the same session", %{adapter_name: adapter_name} do
      runner_name = :"runner_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Runner,
         {runner_name,
          [
            adapter: TestAdapter,
            adapter_opts: [agent_name: adapter_name],
            pool_size: 0
          ]}}
      )

      {:ok, _} = Runner.run(runner_name, "echo first", session: "user-123")
      {:ok, _} = Runner.run(runner_name, "echo second", session: "user-123")

      state = :sys.get_state(runner_name)
      assert map_size(state.sessions) == 1
    end

    test "uses different sandbox for different sessions", %{adapter_name: adapter_name} do
      runner_name = :"runner_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Runner,
         {runner_name,
          [
            adapter: TestAdapter,
            adapter_opts: [agent_name: adapter_name],
            pool_size: 0
          ]}}
      )

      {:ok, _} = Runner.run(runner_name, "echo first", session: "user-123")
      {:ok, _} = Runner.run(runner_name, "echo second", session: "user-456")

      state = :sys.get_state(runner_name)
      assert map_size(state.sessions) == 2
    end
  end

  describe "transaction/3" do
    test "executes function with sandbox", %{adapter_name: adapter_name} do
      runner_name = :"runner_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Runner,
         {runner_name,
          [
            adapter: TestAdapter,
            adapter_opts: [agent_name: adapter_name],
            pool_size: 1
          ]}}
      )

      {:ok, result} =
        Runner.transaction(runner_name, fn sandbox ->
          :ok = Sandbox.write_file(sandbox, "/app/test.txt", "hello")
          Sandbox.read_file(sandbox, "/app/test.txt")
        end)

      assert result == {:ok, "hello"}
    end

    test "transaction with session persists data", %{adapter_name: adapter_name} do
      runner_name = :"runner_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Runner,
         {runner_name,
          [
            adapter: TestAdapter,
            adapter_opts: [agent_name: adapter_name],
            pool_size: 0
          ]}}
      )

      {:ok, _} =
        Runner.transaction(
          runner_name,
          fn sandbox ->
            Sandbox.write_file(sandbox, "/data/state.txt", "session data")
          end,
          session: "user-123"
        )

      {:ok, result} =
        Runner.transaction(
          runner_name,
          fn sandbox ->
            Sandbox.read_file(sandbox, "/data/state.txt")
          end,
          session: "user-123"
        )

      assert result == {:ok, "session data"}
    end
  end

  describe "end_session/3" do
    test "terminates a session sandbox", %{adapter_name: adapter_name} do
      runner_name = :"runner_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Runner,
         {runner_name,
          [
            adapter: TestAdapter,
            adapter_opts: [agent_name: adapter_name],
            pool_size: 0
          ]}}
      )

      {:ok, _} = Runner.run(runner_name, "echo hello", session: "user-123")

      state_before = :sys.get_state(runner_name)
      assert map_size(state_before.sessions) == 1

      :ok = Runner.end_session(runner_name, "user-123")

      state_after = :sys.get_state(runner_name)
      assert map_size(state_after.sessions) == 0
    end

    test "returns error for non-existent session", %{adapter_name: adapter_name} do
      runner_name = :"runner_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Runner,
         {runner_name,
          [
            adapter: TestAdapter,
            adapter_opts: [agent_name: adapter_name],
            pool_size: 0
          ]}}
      )

      {:error, :session_not_found} = Runner.end_session(runner_name, "non-existent")
    end
  end
end
