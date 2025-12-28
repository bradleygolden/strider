defmodule Strider.Sandbox.Pool.Store.Memory do
  @moduledoc """
  In-memory store implementation using an Agent.

  Suitable for single-node deployments. For distributed systems,
  use a Postgres-backed store.
  """

  @behaviour Strider.Sandbox.Pool.Store

  @impl true
  def init(config) do
    partitions = Map.get(config, :partitions, [])
    initial_entries = Map.new(partitions, fn p -> {p, []} end)
    initial_state = %{entries: initial_entries, pending: MapSet.new()}

    Agent.start_link(fn -> initial_state end)
  end

  @impl true
  def pop(store_ref, partition_key, max_age_ms) do
    Agent.get_and_update(store_ref, fn state ->
      do_pop(state, partition_key, max_age_ms)
    end)
  end

  defp do_pop(state, partition_key, max_age_ms) do
    case Map.get(state.entries, partition_key, []) do
      [] ->
        {{:empty, :pool_empty}, state}

      [entry | rest] ->
        if stale?(entry, max_age_ms) do
          new_entries = Map.put(state.entries, partition_key, rest)
          do_pop(%{state | entries: new_entries}, partition_key, max_age_ms)
        else
          new_entries = Map.put(state.entries, partition_key, rest)
          {{:ok, entry}, %{state | entries: new_entries}}
        end
    end
  end

  @impl true
  def push(store_ref, entry) do
    Agent.update(store_ref, fn state ->
      partition = entry.partition_key
      current = Map.get(state.entries, partition, [])
      %{state | entries: Map.put(state.entries, partition, [entry | current])}
    end)
  end

  @impl true
  def remove(store_ref, id) do
    Agent.update(store_ref, fn state ->
      new_entries =
        Map.new(state.entries, fn {partition, entries} ->
          {partition, Enum.reject(entries, &(&1.id == id))}
        end)

      %{state | entries: new_entries}
    end)
  end

  @impl true
  def count(store_ref, partition_key) do
    Agent.get(store_ref, fn state ->
      length(Map.get(state.entries, partition_key, []))
    end)
  end

  @impl true
  def pending?(store_ref, partition_key) do
    Agent.get(store_ref, &MapSet.member?(&1.pending, partition_key))
  end

  @impl true
  def set_pending(store_ref, partition_key, pending) do
    Agent.update(store_ref, fn state ->
      new_pending =
        if pending do
          MapSet.put(state.pending, partition_key)
        else
          MapSet.delete(state.pending, partition_key)
        end

      %{state | pending: new_pending}
    end)
  end

  @impl true
  def counts_by_partition(store_ref) do
    Agent.get(store_ref, fn state ->
      Map.new(state.entries, fn {k, v} -> {k, length(v)} end)
    end)
  end

  @impl true
  def pending_count(store_ref) do
    Agent.get(store_ref, fn state -> MapSet.size(state.pending) end)
  end

  @impl true
  def stop(store_ref), do: Agent.stop(store_ref)

  defp stale?(entry, max_age_ms) do
    System.monotonic_time(:millisecond) - entry.created_at > max_age_ms
  end
end
