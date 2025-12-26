defmodule Strider.Sandbox.Adapters.Fly.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Strider.Sandbox.Adapters.Fly.RateLimiter

  setup do
    RateLimiter.stop()
    on_exit(fn -> RateLimiter.stop() end)
    :ok
  end

  describe "acquire/1" do
    test "returns immediately when tokens are available" do
      assert :ok = RateLimiter.acquire(:mutation)
      assert :ok = RateLimiter.acquire(:mutation)
      assert :ok = RateLimiter.acquire(:mutation)
    end

    test "mutation and read have independent token pools" do
      # Exhaust mutation tokens (burst of 3)
      assert :ok = RateLimiter.acquire(:mutation)
      assert :ok = RateLimiter.acquire(:mutation)
      assert :ok = RateLimiter.acquire(:mutation)

      # Read tokens should still be available
      assert :ok = RateLimiter.acquire(:read)
      assert :ok = RateLimiter.acquire(:read)
    end

    test "blocks when tokens are exhausted and unblocks after refill" do
      # Exhaust the burst capacity (3 tokens)
      assert :ok = RateLimiter.acquire(:mutation)
      assert :ok = RateLimiter.acquire(:mutation)
      assert :ok = RateLimiter.acquire(:mutation)

      # This should block until refill
      parent = self()

      task =
        Task.async(fn ->
          start_time = System.monotonic_time(:millisecond)
          :ok = RateLimiter.acquire(:mutation)
          elapsed = System.monotonic_time(:millisecond) - start_time
          send(parent, {:elapsed, elapsed})
        end)

      Task.await(task, 5000)

      assert_receive {:elapsed, elapsed}
      # Should have waited approximately 1000ms (mutation rate)
      assert elapsed >= 900, "Expected to wait ~1000ms, but only waited #{elapsed}ms"
    end

    test "read tokens refill faster than mutation tokens" do
      # Exhaust read tokens (burst of 10)
      for _ <- 1..10, do: RateLimiter.acquire(:read)

      # This should block until refill (200ms for read vs 1000ms for mutation)
      start_time = System.monotonic_time(:millisecond)
      :ok = RateLimiter.acquire(:read)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should have waited approximately 200ms (read rate)
      assert elapsed >= 150, "Expected to wait ~200ms, but only waited #{elapsed}ms"
      assert elapsed < 500, "Expected to wait ~200ms, but waited #{elapsed}ms"
    end

    test "multiple waiters are all eventually served" do
      # Exhaust tokens
      for _ <- 1..3, do: RateLimiter.acquire(:mutation)

      parent = self()

      # Start multiple waiting tasks
      tasks =
        for i <- 1..3 do
          Task.async(fn ->
            :ok = RateLimiter.acquire(:mutation)
            send(parent, {:completed, i})
          end)
        end

      # Wait for all to complete
      for task <- tasks, do: Task.await(task, 10_000)

      # Collect all completions (order is non-deterministic due to concurrent task scheduling)
      completed =
        for _ <- 1..3 do
          receive do
            {:completed, i} -> i
          end
        end

      # All three should complete
      assert Enum.sort(completed) == [1, 2, 3]
    end
  end

  describe "ensure_started/1" do
    test "is idempotent" do
      assert :ok = RateLimiter.ensure_started()
      assert :ok = RateLimiter.ensure_started()
      assert :ok = RateLimiter.ensure_started()
    end

    test "is called automatically by acquire/1" do
      # Don't call ensure_started explicitly
      assert :ok = RateLimiter.acquire(:read)
    end
  end

  describe "stop/0" do
    test "stops the rate limiter" do
      RateLimiter.ensure_started()
      assert is_pid(GenServer.whereis(RateLimiter))

      :ok = RateLimiter.stop()
      assert GenServer.whereis(RateLimiter) == nil
    end

    test "is idempotent" do
      assert :ok = RateLimiter.stop()
      assert :ok = RateLimiter.stop()
    end
  end
end
