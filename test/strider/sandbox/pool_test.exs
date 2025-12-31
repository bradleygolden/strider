defmodule Strider.Sandbox.PoolTest do
  use ExUnit.Case, async: false

  alias Strider.Sandbox.Adapters.Test, as: TestAdapter
  alias Strider.Sandbox.Pool

  setup do
    start_supervised!(TestAdapter)

    table = :ets.new(:pool_telemetry_events, [:public, :bag])
    handler_id = "pool-test-handler-#{:erlang.unique_integer()}"

    :telemetry.attach_many(
      handler_id,
      [
        [:strider, :pool, :checkout, :start],
        [:strider, :pool, :checkout, :stop],
        [:strider, :pool, :create, :start],
        [:strider, :pool, :create, :stop],
        [:strider, :pool, :create, :error]
      ],
      fn event, measurements, metadata, _config ->
        try do
          :ets.insert(table, {event, measurements, metadata})
        rescue
          ArgumentError -> :ok
        end
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)

      try do
        :ets.delete(table)
      rescue
        ArgumentError -> :ok
      end
    end)

    {:ok, events_table: table}
  end

  defp has_event?(table, event_name) do
    :ets.tab2list(table) |> Enum.any?(fn {event, _, _} -> event == event_name end)
  end

  describe "start_link/2" do
    test "starts with valid config" do
      config = build_config()
      assert {:ok, pid} = Pool.start_link(config)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "accepts :name option" do
      config = build_config()
      assert {:ok, _pid} = Pool.start_link(config, name: :test_pool)
      assert Process.whereis(:test_pool) != nil
      GenServer.stop(:test_pool)
    end

    test "fails on missing required config keys" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _}} =
               Pool.start_link(%{adapter: TestAdapter})

      assert message =~ "Missing required config key"
    end
  end

  describe "checkout/2" do
    test "returns {:cold, :pool_empty} when pool is empty" do
      config = build_config(target_per_partition: 0)
      {:ok, pid} = Pool.start_link(config)

      assert {:cold, :pool_empty} = Pool.checkout(pid, "ord")

      GenServer.stop(pid)
    end

    test "returns {:warm, sandbox_info} when sandbox is available" do
      config = build_config()
      {:ok, pid} = Pool.start_link(config)

      wait_for_pool_size(pid, "ord", 1)

      assert {:warm, sandbox_info} = Pool.checkout(pid, "ord")
      assert is_binary(sandbox_info.sandbox_id)
      assert sandbox_info.partition == "ord"

      GenServer.stop(pid)
    end

    test "triggers replenish after checkout" do
      config = build_config()
      {:ok, pid} = Pool.start_link(config)

      wait_for_pool_size(pid, "ord", 1)

      {:warm, _} = Pool.checkout(pid, "ord")

      wait_for_pool_size(pid, "ord", 1)

      assert %{pool: %{"ord" => 1}} = Pool.status(pid)

      GenServer.stop(pid)
    end

    test "discards stale sandboxes" do
      config = build_config(max_age_ms: 1)
      {:ok, pid} = Pool.start_link(config)

      wait_for_pool_size(pid, "ord", 1)

      receive after: (10 -> :ok)

      assert {:cold, :pool_empty} = Pool.checkout(pid, "ord")

      GenServer.stop(pid)
    end

    test "emits checkout telemetry events", %{events_table: table} do
      config = build_config()
      {:ok, pid} = Pool.start_link(config)

      wait_for_pool_size(pid, "ord", 1)
      Pool.checkout(pid, "ord")

      assert has_event?(table, [:strider, :pool, :checkout, :start])
      assert has_event?(table, [:strider, :pool, :checkout, :stop])

      GenServer.stop(pid)
    end
  end

  describe "status/1" do
    test "returns pool counts per partition" do
      config = build_config(partitions: ["ord", "ewr"])
      {:ok, pid} = Pool.start_link(config)

      wait_for_pool_size(pid, "ord", 1)
      wait_for_pool_size(pid, "ewr", 1)

      assert %{pool: %{"ord" => 1, "ewr" => 1}, pending: 0} = Pool.status(pid)

      GenServer.stop(pid)
    end
  end

  describe "replenish" do
    test "fills pool to target_per_partition" do
      config = build_config(target_per_partition: 2)
      {:ok, pid} = Pool.start_link(config)

      wait_for_pool_size(pid, "ord", 2)

      assert %{pool: %{"ord" => 2}} = Pool.status(pid)

      GenServer.stop(pid)
    end

    test "handles creation failures gracefully" do
      config = build_config()
      {:ok, pid} = Pool.start_link(config)

      ref = Process.monitor(pid)
      send(pid, {:sandbox_failed, "ord", :test_error})

      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 100
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "emits create telemetry events on success", %{events_table: table} do
      config = build_config()
      {:ok, pid} = Pool.start_link(config)

      wait_for_pool_size(pid, "ord", 1)

      assert has_event?(table, [:strider, :pool, :create, :start])
      assert has_event?(table, [:strider, :pool, :create, :stop])

      GenServer.stop(pid)
    end

    test "injects pool markers into sandbox env" do
      config = build_config()
      {:ok, pid} = Pool.start_link(config)

      wait_for_pool_size(pid, "ord", 1)

      {:warm, sandbox_info} = Pool.checkout(pid, "ord")
      sandbox_config = TestAdapter.get_config(sandbox_info.sandbox_id)

      assert sandbox_config.env["STRIDER_POOL"] == "true"
      assert sandbox_config.env["STRIDER_POOL_PARTITION"] == "ord"

      GenServer.stop(pid)
    end
  end

  describe "child_spec/1" do
    test "returns valid child spec" do
      spec = Pool.child_spec(config: build_config(), name: :my_pool)

      assert spec.id == :my_pool
      assert spec.start == {Pool, :start_link, [build_config(), [name: :my_pool]]}
      assert spec.type == :worker
      assert spec.restart == :permanent
    end
  end

  describe "claim/4" do
    test "returns {:warm, sandbox} with updated config when sandbox available" do
      config = build_config()
      {:ok, pid} = Pool.start_link(config)

      wait_for_pool_size(pid, "ord", 1)

      new_env = %{"API_KEY" => "real-key", "SITE_ID" => "site-123"}
      assert {:warm, sandbox} = Pool.claim(pid, "ord", %{env: new_env})

      assert %Strider.Sandbox.Instance{} = sandbox
      assert sandbox.adapter == TestAdapter

      # Verify config was updated (pool markers replaced)
      sandbox_config = TestAdapter.get_config(sandbox.id)
      assert sandbox_config.env["API_KEY"] == "real-key"
      assert sandbox_config.env["SITE_ID"] == "site-123"
      refute sandbox_config.env["STRIDER_POOL"]

      GenServer.stop(pid)
    end

    test "returns {:cold, :pool_empty} when pool is empty" do
      config = build_config(target_per_partition: 0)
      {:ok, pid} = Pool.start_link(config)

      assert {:cold, :pool_empty} = Pool.claim(pid, "ord", %{env: %{}})

      GenServer.stop(pid)
    end

    test "triggers replenish after successful claim" do
      config = build_config()
      {:ok, pid} = Pool.start_link(config)

      wait_for_pool_size(pid, "ord", 1)

      {:warm, _sandbox} = Pool.claim(pid, "ord", %{env: %{}})

      wait_for_pool_size(pid, "ord", 1)

      assert %{pool: %{"ord" => 1}} = Pool.status(pid)

      GenServer.stop(pid)
    end
  end

  # Helper functions

  defp build_config(overrides \\ []) do
    defaults = %{
      adapter: TestAdapter,
      partitions: ["ord"],
      target_per_partition: 1,
      max_age_ms: :timer.hours(4),
      replenish_interval_ms: 100,
      build_config: fn partition -> %{image: "test:latest", partition: partition} end,
      health_port: 4001,
      health_timeout_ms: 1000
    }

    Map.merge(defaults, Map.new(overrides))
  end

  defp wait_for_pool_size(pid, partition, target_size, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_pool_size(pid, partition, target_size, deadline)
  end

  defp do_wait_for_pool_size(pid, partition, target_size, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk("Timeout waiting for pool size #{target_size} in partition #{partition}")
    end

    status = Pool.status(pid)
    current_size = get_in(status, [:pool, partition]) || 0

    if current_size >= target_size do
      :ok
    else
      receive after: (50 -> do_wait_for_pool_size(pid, partition, target_size, deadline))
    end
  end
end
