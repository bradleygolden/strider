defmodule Strider.Sandbox.Runner do
  @moduledoc """
  GenServer that manages sandbox pools and sessions for `use Strider.Sandbox`.

  Handles two modes:
  - **Stateless**: Ephemeral sandboxes from a warm pool, no persistence
  - **Session-based**: Dedicated sandbox + volume per session, data persists

  ## Architecture

  ```
  ┌─────────────────────────────────────────┐
  │  Stateless Pool                         │
  │  - No volumes                           │
  │  - Returned to pool after use           │
  │  - Cold start if pool empty             │
  └─────────────────────────────────────────┘

  ┌─────────────────────────────────────────┐
  │  Sessions                               │
  │  - Each session = 1 sandbox + 1 volume  │
  │  - Sandbox stopped (not terminated)     │
  │  - Volume persists data across calls    │
  └─────────────────────────────────────────┘
  ```
  """

  use GenServer

  alias Strider.Sandbox
  alias Strider.Sandbox.Instance

  @type opts :: [
          adapter: module(),
          adapter_opts: keyword(),
          pool_size: pos_integer(),
          default_region: String.t(),
          session_volume: map() | nil
        ]

  @default_pool_size 5
  @default_region "sjc"

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            name: atom(),
            adapter: module(),
            adapter_opts: keyword(),
            default_region: String.t(),
            session_volume: map() | nil,
            pool: [Instance.t()],
            pool_size: pos_integer(),
            in_use: %{reference() => Instance.t()},
            sessions: %{String.t() => Instance.t()}
          }

    defstruct [
      :name,
      :adapter,
      :adapter_opts,
      :default_region,
      :session_volume,
      pool: [],
      pool_size: 5,
      in_use: %{},
      sessions: %{}
    ]
  end

  @doc """
  Returns a child specification for the Runner.
  """
  def child_spec({name, opts}) do
    %{
      id: name,
      start: {__MODULE__, :start_link, [name, opts]},
      type: :worker
    }
  end

  @doc """
  Starts the Runner GenServer.

  Called by modules that `use Strider.Sandbox`.
  """
  @spec start_link(atom(), opts()) :: GenServer.on_start()
  def start_link(name, opts) do
    GenServer.start_link(__MODULE__, {name, opts}, name: name)
  end

  @doc """
  Executes a single command in a sandbox.

  ## Options

  - `:session` - Session ID for persistent sandbox (default: nil, uses pool)
  - `:region` - Region for session sandbox (default: configured default)
  - `:timeout` - Command timeout in ms (default: 30_000)
  """
  @spec run(atom(), String.t(), keyword()) ::
          {:ok, Sandbox.ExecResult.t()} | {:error, term()}
  def run(name, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000) + 5_000
    GenServer.call(name, {:run, command, opts}, timeout)
  end

  @doc """
  Executes multiple operations in a sandbox.

  The function receives the sandbox instance and can perform multiple
  operations. All operations use the same sandbox.

  ## Options

  Same as `run/3`.
  """
  @spec transaction(atom(), (Instance.t() -> term()), keyword()) ::
          {:ok, term()} | {:error, term()}
  def transaction(name, fun, opts \\ []) when is_function(fun, 1) do
    timeout = Keyword.get(opts, :timeout, 60_000) + 5_000
    GenServer.call(name, {:transaction, fun, opts}, timeout)
  end

  @doc """
  Ends a session, terminating its sandbox.

  ## Options

  - `:delete_volume` - Also delete the volume (default: false)
  """
  @spec end_session(atom(), String.t(), keyword()) :: :ok | {:error, term()}
  def end_session(name, session_id, opts \\ []) do
    GenServer.call(name, {:end_session, session_id, opts})
  end

  @impl GenServer
  def init({name, opts}) do
    state = %State{
      name: name,
      adapter: Keyword.fetch!(opts, :adapter),
      adapter_opts: Keyword.get(opts, :adapter_opts, []),
      default_region: Keyword.get(opts, :default_region, @default_region),
      session_volume: Keyword.get(opts, :session_volume),
      pool_size: Keyword.get(opts, :pool_size, @default_pool_size)
    }

    send(self(), :warm_pool)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:run, command, opts}, from, state) do
    metadata = %{
      command: command,
      session: Keyword.get(opts, :session),
      module: state.name
    }

    :telemetry.span([:strider, :sandbox, :run], metadata, fn ->
      result =
        handle_operation(state, opts, from, fn sandbox ->
          Sandbox.exec(sandbox, command, opts)
        end)

      {result, metadata}
    end)
  end

  def handle_call({:transaction, fun, opts}, from, state) do
    metadata = %{
      session: Keyword.get(opts, :session),
      module: state.name
    }

    :telemetry.span([:strider, :sandbox, :transaction], metadata, fn ->
      result =
        handle_operation(state, opts, from, fn sandbox ->
          {:ok, fun.(sandbox)}
        end)

      {result, metadata}
    end)
  end

  def handle_call({:end_session, session_id, opts}, _from, state) do
    region = Keyword.get(opts, :region, state.default_region)
    session_key = session_key(session_id, region)

    case Map.pop(state.sessions, session_key) do
      {nil, _} ->
        {:reply, {:error, :session_not_found}, state}

      {sandbox, sessions} ->
        result = Sandbox.terminate(sandbox)

        if Keyword.get(opts, :delete_volume, false) do
          Sandbox.delete_volumes(sandbox)
        end

        {:reply, result, %{state | sessions: sessions}}
    end
  end

  @impl GenServer
  def handle_info(:warm_pool, state) do
    state = warm_pool(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.in_use, ref) do
      {nil, _} ->
        {:noreply, state}

      {sandbox, in_use} ->
        pool = [sandbox | state.pool]
        {:noreply, %{state | in_use: in_use, pool: pool}}
    end
  end

  def handle_info({:sandbox_ready, sandbox}, state) do
    pool = [sandbox | state.pool]
    {:noreply, %{state | pool: pool}}
  end

  def handle_info({:sandbox_failed, _reason}, state) do
    {:noreply, state}
  end

  defp handle_operation(state, opts, {from_pid, _} = _from, operation) do
    session_id = Keyword.get(opts, :session)

    case get_sandbox(state, session_id, opts) do
      {:ok, sandbox, new_state, mode} ->
        case operation.(sandbox) do
          {:ok, result} ->
            final_state = return_sandbox(new_state, sandbox, mode, from_pid)
            {:reply, {:ok, result}, final_state}

          {:error, _} = error ->
            final_state = return_sandbox(new_state, sandbox, mode, from_pid)
            {:reply, error, final_state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp get_sandbox(state, nil, _opts) do
    get_from_pool(state)
  end

  defp get_sandbox(state, session_id, opts) do
    region = Keyword.get(opts, :region, state.default_region)
    get_or_create_session(state, session_id, region)
  end

  defp get_from_pool(state) do
    case state.pool do
      [sandbox | rest] ->
        {:ok, sandbox, %{state | pool: rest}, :pool}

      [] ->
        case cold_start(state) do
          {:ok, sandbox} ->
            {:ok, sandbox, state, :cold}

          {:error, _} = error ->
            error
        end
    end
  end

  defp get_or_create_session(state, session_id, region) do
    session_key = session_key(session_id, region)

    case Map.get(state.sessions, session_key) do
      nil ->
        case create_session_sandbox(state, region) do
          {:ok, sandbox} ->
            sessions = Map.put(state.sessions, session_key, sandbox)
            {:ok, sandbox, %{state | sessions: sessions}, :session}

          {:error, _} = error ->
            error
        end

      sandbox ->
        case ensure_running(sandbox) do
          {:ok, running} ->
            sessions = Map.put(state.sessions, session_key, running)
            {:ok, running, %{state | sessions: sessions}, :session}

          {:error, _} = error ->
            error
        end
    end
  end

  defp ensure_running(sandbox) do
    case Sandbox.status(sandbox) do
      :running ->
        {:ok, sandbox}

      :stopped ->
        case Sandbox.start(sandbox) do
          {:ok, _} -> {:ok, sandbox}
          {:error, _} = error -> error
        end

      status ->
        {:error, {:unexpected_status, status}}
    end
  end

  defp return_sandbox(state, sandbox, :pool, from_pid) do
    ref = Process.monitor(from_pid)
    in_use = Map.put(state.in_use, ref, sandbox)
    schedule_return(ref)
    %{state | in_use: in_use}
  end

  defp return_sandbox(state, sandbox, :session, _from_pid) do
    Sandbox.stop(sandbox)
    state
  end

  defp return_sandbox(state, _sandbox, :cold, _from_pid) do
    send(self(), :warm_pool)
    state
  end

  defp schedule_return(ref) do
    spawn(fn ->
      receive do
      after
        100 -> :ok
      end

      send(self(), {:return_to_pool, ref})
    end)
  end

  defp cold_start(state) do
    config = build_pool_config(state)

    with {:ok, sandbox} <- Sandbox.create({state.adapter, config}),
         {:ok, _} <- Sandbox.await_ready(sandbox) do
      {:ok, sandbox}
    end
  end

  defp create_session_sandbox(state, region) do
    config = build_session_config(state, region)

    with {:ok, sandbox} <- Sandbox.create({state.adapter, config}),
         {:ok, _} <- Sandbox.await_ready(sandbox) do
      {:ok, sandbox}
    end
  end

  defp warm_pool(state) do
    needed = state.pool_size - length(state.pool)

    if needed > 0 do
      Enum.each(1..needed, fn _ -> spawn_warmer(state) end)
    end

    state
  end

  defp spawn_warmer(state) do
    parent = self()

    spawn(fn ->
      case cold_start(state) do
        {:ok, sandbox} -> send(parent, {:sandbox_ready, sandbox})
        {:error, reason} -> send(parent, {:sandbox_failed, reason})
      end
    end)
  end

  defp build_pool_config(state) do
    state.adapter_opts
    |> Keyword.put(:region, state.default_region)
    |> Map.new()
  end

  defp build_session_config(state, region) do
    config =
      state.adapter_opts
      |> Keyword.put(:region, region)
      |> Map.new()

    if state.session_volume do
      Map.put(config, :mounts, [state.session_volume])
    else
      config
    end
  end

  defp session_key(session_id, region), do: "#{session_id}:#{region}"
end
