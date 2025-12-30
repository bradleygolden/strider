defmodule Strider.Sandbox.Pool do
  @moduledoc """
  A GenServer that maintains a pool of pre-warmed sandboxes for fast provisioning.

  Warm sandboxes are created, initialized (await_ready), then stopped.
  The volume retains state, enabling ~10-15s starts vs ~60s cold starts.

  ## Configuration

      config = %{
        adapter: Strider.Sandbox.Adapters.Fly,
        partitions: ["ord", "ewr"],  # or ["tenant-123:ord", "tenant-456:ewr"] for multi-tenant
        target_per_partition: 1,
        max_age_ms: :timer.hours(4),
        replenish_interval_ms: :timer.minutes(1),
        build_config: fn partition -> %{image: ..., app_name: ..., region: partition} end,
        health_port: 4001,
        health_timeout_ms: 120_000,
        store: Strider.Sandbox.Pool.Store.Memory,  # optional, defaults to Memory
        store_config: %{}  # optional, passed to store.init/1
      }

      {:ok, pid} = Strider.Sandbox.Pool.start_link(config, name: MyPool)

  ## Checkout

      case Strider.Sandbox.Pool.checkout(MyPool, "ord") do
        {:warm, sandbox_info} ->
          # sandbox_info contains: %{sandbox_id: "...", private_ip: "...", partition: "...", metadata: %{}}
          sandbox = Strider.Sandbox.from_id(Fly, sandbox_info.sandbox_id, config, sandbox_info.metadata)
          Strider.Sandbox.start(sandbox)

        {:cold, :pool_empty} ->
          # No warm sandbox available, create from scratch
          Strider.Sandbox.create({Fly, config})
      end
  """

  use GenServer
  require Logger

  alias Strider.Sandbox
  alias Strider.Sandbox.Pool.Store

  @type config :: %{
          adapter: module(),
          partitions: [String.t()],
          target_per_partition: pos_integer(),
          max_age_ms: pos_integer(),
          replenish_interval_ms: pos_integer(),
          build_config: (String.t() -> map()),
          health_port: pos_integer(),
          health_timeout_ms: pos_integer(),
          store: module(),
          store_config: map()
        }

  @type sandbox_info :: %{
          sandbox_id: String.t(),
          private_ip: String.t() | nil,
          partition: String.t(),
          metadata: map(),
          created_at: integer()
        }

  @type checkout_result :: {:warm, sandbox_info()} | {:cold, :pool_empty}

  @type pool_status :: %{
          pool: %{String.t() => non_neg_integer()},
          pending: non_neg_integer()
        }

  # Public API

  @doc """
  Starts the pool GenServer.

  ## Options
    * `:name` - GenServer name registration (optional)
  """
  @spec start_link(config(), keyword()) :: GenServer.on_start()
  def start_link(config, opts \\ []) do
    GenServer.start_link(__MODULE__, config, opts)
  end

  @doc """
  Checks out a warm sandbox from the pool for the given partition.

  Returns `{:warm, sandbox_info}` if available, `{:cold, :pool_empty}` otherwise.
  """
  @spec checkout(GenServer.server(), String.t()) :: checkout_result()
  def checkout(pool, partition) do
    GenServer.call(pool, {:checkout, partition}, 10_000)
  end

  @doc """
  Claims a warm sandbox from the pool, updates its config, and returns it ready to start.

  This is a convenience function that combines checkout + update. The update replaces
  the pool marker env vars with your real configuration.

  Returns `{:warm, sandbox}` with a Sandbox.Instance ready to start,
  `{:cold, :pool_empty}` if no warm sandbox available,
  or `{:error, reason}` if the update fails.

  ## Example

      case Pool.claim(MyPool, "tenant-123:ord", %{env: %{"API_KEY" => "real-key"}}) do
        {:warm, sandbox} ->
          Sandbox.start(sandbox)
          # sandbox is now running with real config

        {:cold, :pool_empty} ->
          # Create from scratch
          Sandbox.create({Fly, config})

        {:error, reason} ->
          # Update failed
      end
  """
  @spec claim(GenServer.server(), String.t(), map(), keyword()) ::
          {:warm, Sandbox.Instance.t()} | {:cold, :pool_empty} | {:error, term()}
  def claim(pool, partition, update_config, opts \\ []) do
    GenServer.call(pool, {:claim, partition, update_config, opts}, 15_000)
  end

  @doc """
  Returns the current pool status for monitoring.
  """
  @spec status(GenServer.server()) :: pool_status()
  def status(pool) do
    GenServer.call(pool, :status)
  end

  @doc """
  Registers a new partition to be managed by the pool.

  The pool will begin warming sandboxes for this partition on the next replenish cycle.
  Useful for dynamic multi-tenant scenarios where partitions are added at runtime.

  ## Example

      Pool.register_partition(MyPool, "tenant-123:ord")
  """
  @spec register_partition(GenServer.server(), String.t()) :: :ok
  def register_partition(pool, partition) do
    GenServer.call(pool, {:register_partition, partition})
  end

  @doc """
  Unregisters a partition from the pool.

  ## Options
  - `:cleanup` - If true, terminates all warm sandboxes for this partition (default: false)

  ## Example

      Pool.unregister_partition(MyPool, "tenant-123:ord", cleanup: true)
  """
  @spec unregister_partition(GenServer.server(), String.t(), keyword()) :: :ok
  def unregister_partition(pool, partition, opts \\ []) do
    GenServer.call(pool, {:unregister_partition, partition, opts})
  end

  @doc """
  Returns child_spec for supervision tree integration.
  """
  def child_spec(opts) do
    {config, opts} = Keyword.pop!(opts, :config)

    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [config, opts]},
      type: :worker,
      restart: :permanent
    }
  end

  # GenServer Callbacks

  @impl true
  def init(config) do
    validated_config = validate_config!(config)
    store = validated_config.store

    store_config =
      validated_config.store_config
      |> Map.put(:partitions, validated_config.partitions)

    case store.init(store_config) do
      {:ok, store_ref} ->
        Logger.info(
          "[Pool] Starting sandbox pool for partitions: #{inspect(validated_config.partitions)}"
        )

        send(self(), :replenish)
        schedule_replenish(validated_config.replenish_interval_ms)

        {:ok,
         %{
           config: validated_config,
           store: store,
           store_ref: store_ref
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:checkout, partition}, _from, state) do
    start_time = System.monotonic_time()

    emit_telemetry([:checkout, :start], %{system_time: System.system_time()}, %{
      partition: partition
    })

    {result, state} = pop_warm_sandbox(state, partition)
    result_type = elem(result, 0)

    if result_type == :warm, do: send(self(), :replenish)

    duration = System.monotonic_time() - start_time

    emit_telemetry([:checkout, :stop], %{duration: duration}, %{
      partition: partition,
      result: result_type
    })

    {:reply, result, state}
  end

  def handle_call({:claim, partition, update_config, opts}, _from, state) do
    start_time = System.monotonic_time()

    emit_telemetry([:checkout, :start], %{system_time: System.system_time()}, %{
      partition: partition
    })

    {result, state} = pop_warm_sandbox(state, partition)

    case result do
      {:warm, sandbox_info} ->
        sandbox =
          Sandbox.from_id(
            state.config.adapter,
            sandbox_info.sandbox_id,
            %{},
            sandbox_info.metadata
          )

        case Sandbox.update(sandbox, update_config, opts) do
          {:ok, _} ->
            send(self(), :replenish)
            duration = System.monotonic_time() - start_time

            emit_telemetry([:checkout, :stop], %{duration: duration}, %{
              partition: partition,
              result: :warm
            })

            {:reply, {:warm, sandbox}, state}

          {:error, reason} ->
            duration = System.monotonic_time() - start_time

            emit_telemetry([:checkout, :stop], %{duration: duration}, %{
              partition: partition,
              result: :error
            })

            {:reply, {:error, reason}, state}
        end

      {:cold, :pool_empty} ->
        duration = System.monotonic_time() - start_time

        emit_telemetry([:checkout, :stop], %{duration: duration}, %{
          partition: partition,
          result: :cold
        })

        {:reply, {:cold, :pool_empty}, state}
    end
  end

  def handle_call(:status, _from, state) do
    pool_counts = state.store.counts_by_partition(state.store_ref)
    pending_count = state.store.pending_count(state.store_ref)
    status = %{pool: pool_counts, pending: pending_count}
    {:reply, status, state}
  end

  def handle_call({:register_partition, partition}, _from, state) do
    Logger.info("[Pool] Registering partition: #{partition}")

    current_partitions = state.config.partitions

    if partition in current_partitions do
      {:reply, :ok, state}
    else
      new_partitions = [partition | current_partitions]
      new_config = %{state.config | partitions: new_partitions}
      send(self(), :replenish)
      {:reply, :ok, %{state | config: new_config}}
    end
  end

  def handle_call({:unregister_partition, partition, opts}, _from, state) do
    Logger.info("[Pool] Unregistering partition: #{partition}")

    new_partitions = Enum.reject(state.config.partitions, &(&1 == partition))
    new_config = %{state.config | partitions: new_partitions}
    new_state = %{state | config: new_config}

    if Keyword.get(opts, :cleanup, false) do
      spawn(fn -> cleanup_partition(state, partition) end)
    end

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:replenish, state) do
    state = ensure_pool_filled(state)
    schedule_replenish(state.config.replenish_interval_ms)
    {:noreply, state}
  end

  def handle_info({:sandbox_created, partition, sandbox_info}, state) do
    Logger.info("[Pool] Warm sandbox created for #{partition}: #{sandbox_info.sandbox_id}")

    entry = to_entry(sandbox_info)
    :ok = state.store.push(state.store_ref, entry)
    :ok = state.store.set_pending(state.store_ref, partition, false)

    {:noreply, state}
  end

  def handle_info({:sandbox_failed, partition, reason}, state) do
    Logger.warning("[Pool] Failed to create warm sandbox for #{partition}: #{inspect(reason)}")
    :ok = state.store.set_pending(state.store_ref, partition, false)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    Logger.info("[Pool] Terminating pool, leaving sandboxes running for reconciliation")
    :ok
  end

  # Private Functions

  defp validate_config!(config) do
    required_keys = [:adapter, :partitions, :build_config]

    for key <- required_keys do
      unless Map.has_key?(config, key) do
        raise ArgumentError, "Missing required config key: #{key}"
      end
    end

    %{
      adapter: Map.fetch!(config, :adapter),
      partitions: Map.fetch!(config, :partitions),
      target_per_partition: Map.get(config, :target_per_partition, 1),
      max_age_ms: Map.get(config, :max_age_ms, :timer.hours(4)),
      replenish_interval_ms: Map.get(config, :replenish_interval_ms, :timer.minutes(1)),
      build_config: Map.fetch!(config, :build_config),
      health_port: Map.get(config, :health_port, 4001),
      health_timeout_ms: Map.get(config, :health_timeout_ms, 120_000),
      store: Map.get(config, :store, Store.Memory),
      store_config: Map.get(config, :store_config, %{})
    }
  end

  defp pop_warm_sandbox(state, partition) do
    case state.store.pop(state.store_ref, partition, state.config.max_age_ms) do
      {:ok, entry} ->
        sandbox_info = from_entry(entry)

        Logger.info(
          "[Pool] Checked out warm sandbox #{sandbox_info.sandbox_id} for partition #{partition}"
        )

        {{:warm, sandbox_info}, state}

      {:empty, :pool_empty} ->
        Logger.debug("[Pool] No warm sandbox available for partition #{partition}")
        {{:cold, :pool_empty}, state}
    end
  end

  defp ensure_pool_filled(state) do
    Enum.each(state.config.partitions, fn partition ->
      current_count = state.store.count(state.store_ref, partition)
      pending? = state.store.pending?(state.store_ref, partition)

      if current_count < state.config.target_per_partition and not pending? do
        spawn_warm_sandbox(state, partition)
      end
    end)

    state
  end

  defp spawn_warm_sandbox(state, partition) do
    parent = self()
    config = state.config

    :ok = state.store.set_pending(state.store_ref, partition, true)

    Task.start(fn ->
      case create_warm_sandbox(config, partition) do
        {:ok, sandbox_info} ->
          send(parent, {:sandbox_created, partition, sandbox_info})

        {:error, reason} ->
          send(parent, {:sandbox_failed, partition, reason})
      end
    end)
  end

  defp create_warm_sandbox(config, partition) do
    sandbox_config = config.build_config.(partition)
    sandbox_config = inject_pool_markers(sandbox_config, partition)

    emit_telemetry([:create, :start], %{system_time: System.system_time()}, %{
      partition: partition
    })

    start_time = System.monotonic_time()

    with {:ok, sandbox} <- Sandbox.create({config.adapter, sandbox_config}),
         {:ok, _metadata} <-
           Sandbox.await_ready(sandbox,
             port: config.health_port,
             timeout: config.health_timeout_ms
           ),
         {:ok, _} <- Sandbox.stop(sandbox) do
      sandbox_info = %{
        sandbox_id: sandbox.id,
        private_ip: Map.get(sandbox.metadata, :private_ip),
        partition: partition,
        metadata: sandbox.metadata,
        created_at: System.monotonic_time(:millisecond)
      }

      duration = System.monotonic_time() - start_time

      emit_telemetry([:create, :stop], %{duration: duration}, %{
        partition: partition,
        sandbox_id: sandbox.id
      })

      {:ok, sandbox_info}
    else
      {:error, reason} = error ->
        emit_telemetry([:create, :error], %{system_time: System.system_time()}, %{
          partition: partition,
          reason: reason
        })

        error
    end
  end

  defp schedule_replenish(interval_ms) do
    Process.send_after(self(), :replenish, interval_ms)
  end

  defp cleanup_partition(state, partition) do
    case state.store.pop(state.store_ref, partition, :infinity) do
      {:ok, entry} ->
        sandbox = Sandbox.from_id(state.config.adapter, entry.id, %{}, entry.data.metadata || %{})

        case Sandbox.terminate(sandbox) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("[Pool] Failed to terminate sandbox: #{inspect(reason)}")
        end

        cleanup_partition(state, partition)

      {:empty, :pool_empty} ->
        :ok
    end
  end

  defp emit_telemetry(event, measurements, metadata) do
    :telemetry.execute([:strider, :pool] ++ event, measurements, metadata)
  end

  defp inject_pool_markers(sandbox_config, partition) do
    pool_env = %{
      "STRIDER_POOL" => "true",
      "STRIDER_POOL_PARTITION" => partition
    }

    existing_env = Map.get(sandbox_config, :env, %{})
    Map.put(sandbox_config, :env, Map.merge(pool_env, existing_env))
  end

  defp to_entry(sandbox_info) do
    %{
      id: sandbox_info.sandbox_id,
      partition_key: sandbox_info.partition,
      data: %{
        private_ip: sandbox_info.private_ip,
        metadata: sandbox_info.metadata
      },
      created_at: sandbox_info.created_at
    }
  end

  defp from_entry(entry) do
    %{
      sandbox_id: entry.id,
      partition: entry.partition_key,
      private_ip: entry.data.private_ip,
      metadata: entry.data.metadata,
      created_at: entry.created_at
    }
  end
end
