defmodule Strider.Sandbox.Adapters.Test do
  @moduledoc """
  Test adapter for Strider.Sandbox.

  An in-memory adapter for testing that uses an Agent to store state.
  Allows mocking exec responses and tracking command history.

  ## Usage

      # In your test setup
      setup do
        start_supervised!(Strider.Sandbox.Adapters.Test)
        :ok
      end

      test "executes commands" do
        alias Strider.Sandbox.Adapters.Test, as: TestAdapter

        {:ok, sandbox} = Strider.Sandbox.create({TestAdapter, %{}})

        # Set up mock response
        TestAdapter.set_exec_response(sandbox.id, "echo hello",
          {:ok, %Strider.Sandbox.ExecResult{stdout: "hello", exit_code: 0}})

        {:ok, result} = Strider.Sandbox.exec(sandbox, "echo hello")
        assert result.stdout == "hello"

        # Check command history
        history = TestAdapter.get_exec_history(sandbox.id)
        assert "echo hello" in history
      end
  """

  @behaviour Strider.Sandbox.Adapter

  use Agent

  alias Strider.Sandbox.ExecResult

  @doc """
  Starts the test adapter agent.
  """
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{sandboxes: %{}, responses: %{}} end, name: __MODULE__)
  end

  @doc """
  Sets a mock response for a specific command in a sandbox.
  """
  @spec set_exec_response(String.t(), String.t(), {:ok, ExecResult.t()} | {:error, term()}) :: :ok
  def set_exec_response(sandbox_id, command, response) do
    Agent.update(__MODULE__, fn state ->
      put_in(state, [:responses, {sandbox_id, command}], response)
    end)
  end

  @doc """
  Gets the command execution history for a sandbox.
  """
  @spec get_exec_history(String.t()) :: [String.t()]
  def get_exec_history(sandbox_id) do
    Agent.get(__MODULE__, fn state ->
      get_in(state, [:sandboxes, sandbox_id, :history]) || []
    end)
  end

  @doc """
  Resets all adapter state.
  """
  @spec reset() :: :ok
  def reset do
    Agent.update(__MODULE__, fn _ -> %{sandboxes: %{}, responses: %{}} end)
  end

  # Adapter callbacks

  @impl true
  def create(config) do
    id = "test-sandbox-#{System.unique_integer([:positive])}"

    Agent.update(__MODULE__, fn state ->
      put_in(state, [:sandboxes, id], %{config: config, status: :running, history: []})
    end)

    {:ok, id}
  end

  @impl true
  def exec(sandbox_id, command, _opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = update_in(state, [:sandboxes, sandbox_id, :history], &[command | &1 || []])

      response =
        get_in(state, [:responses, {sandbox_id, command}]) ||
          {:ok, %ExecResult{stdout: "mock: #{command}", exit_code: 0}}

      {response, state}
    end)
  end

  @impl true
  def terminate(sandbox_id) do
    Agent.update(__MODULE__, fn state ->
      put_in(state, [:sandboxes, sandbox_id, :status], :terminated)
    end)

    :ok
  end

  @impl true
  def status(sandbox_id) do
    Agent.get(__MODULE__, fn state ->
      get_in(state, [:sandboxes, sandbox_id, :status]) || :unknown
    end)
  end

  @impl true
  def get_url(sandbox_id, port) do
    {:ok, "http://#{sandbox_id}:#{port}"}
  end
end
