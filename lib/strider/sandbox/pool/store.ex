defmodule Strider.Sandbox.Pool.Store do
  @moduledoc """
  Behaviour for generic pool storage backends.

  The store is agnostic to what it stores. Entries have:
  - `id`: Unique identifier (string)
  - `partition_key`: Grouping key for partitioned pools (string)
  - `data`: Arbitrary data (map)
  - `created_at`: Monotonic timestamp for staleness checks (integer)

  The Pool GenServer interprets these as sandboxes, regions, etc.

  Implementations must handle concurrent access safely.
  """

  @type entry :: %{
          id: String.t(),
          partition_key: String.t(),
          data: map(),
          created_at: integer()
        }

  @type config :: map()
  @type store_ref :: term()

  @doc "Initialize the store with configuration"
  @callback init(config()) :: {:ok, store_ref()} | {:error, term()}

  @doc "Atomically pop a non-stale entry for the partition"
  @callback pop(store_ref(), partition_key :: String.t(), max_age_ms :: pos_integer()) ::
              {:ok, entry()} | {:empty, :pool_empty} | {:error, term()}

  @doc "Add an entry to the pool"
  @callback push(store_ref(), entry()) :: :ok | {:error, term()}

  @doc "Remove an entry by ID"
  @callback remove(store_ref(), id :: String.t()) :: :ok

  @doc "Count entries for a partition"
  @callback count(store_ref(), partition_key :: String.t()) :: non_neg_integer()

  @doc "Check if partition has pending flag set"
  @callback pending?(store_ref(), partition_key :: String.t()) :: boolean()

  @doc "Set pending flag for partition"
  @callback set_pending(store_ref(), partition_key :: String.t(), boolean()) :: :ok

  @doc "Get counts for all partitions"
  @callback counts_by_partition(store_ref()) :: %{String.t() => non_neg_integer()}

  @doc "Count partitions with pending flag"
  @callback pending_count(store_ref()) :: non_neg_integer()

  @doc "Stop the store and release resources"
  @callback stop(store_ref()) :: :ok

  @optional_callbacks [stop: 1]
end
