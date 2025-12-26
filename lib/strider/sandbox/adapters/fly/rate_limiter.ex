defmodule Strider.Sandbox.Adapters.Fly.RateLimiter do
  @moduledoc """
  Token bucket rate limiter for the Fly Machines API.

  Proactively enforces rate limits to prevent hitting 429 responses.
  Uses `Process.send_after/3` for idiomatic token refill scheduling.

  ## Rate Limits (from Fly API docs)

    * Mutations (create, start, stop, delete): 1 req/s, 3 burst
    * Reads (GET): 5 req/s, 10 burst

  ## Usage

      :ok = RateLimiter.acquire(:mutation)
      # Make your API call...

  The rate limiter starts on-demand when first called.
  """

  use GenServer

  @limits %{
    mutation: %{rate_ms: 1000, burst: 3},
    read: %{rate_ms: 200, burst: 10}
  }

  # Public API

  @doc """
  Acquires a token for the given action type.

  Blocks until a token is available. Returns `:ok` when the caller
  may proceed with the API request.

  ## Action Types

    * `:mutation` - For create, start, stop, delete operations
    * `:read` - For GET operations
  """
  @spec acquire(atom()) :: :ok
  def acquire(action_type) when action_type in [:mutation, :read] do
    ensure_started()
    GenServer.call(__MODULE__, {:acquire, action_type}, :infinity)
  end

  @doc """
  Ensures the rate limiter is started.

  Called automatically by `acquire/1`. Safe to call multiple times.
  """
  @spec ensure_started() :: :ok
  def ensure_started do
    case GenServer.start(__MODULE__, [], name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc """
  Stops the rate limiter.

  Primarily useful for testing.
  """
  @spec stop() :: :ok
  def stop do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  # GenServer Callbacks

  @impl true
  def init([]) do
    state = %{
      tokens: %{
        mutation: @limits.mutation.burst,
        read: @limits.read.burst
      },
      waiting: %{
        mutation: :queue.new(),
        read: :queue.new()
      },
      refill_scheduled: %{
        mutation: false,
        read: false
      }
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, type}, from, state) do
    tokens = state.tokens[type]

    if tokens > 0 do
      state = put_in(state.tokens[type], tokens - 1)
      state = maybe_schedule_refill(state, type)
      {:reply, :ok, state}
    else
      state = update_in(state.waiting[type], &:queue.in(from, &1))
      state = maybe_schedule_refill(state, type)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:refill, type}, state) do
    state = put_in(state.refill_scheduled[type], false)
    limit = @limits[type]
    current_tokens = state.tokens[type]

    {state, tokens_to_add} =
      case :queue.out(state.waiting[type]) do
        {{:value, from}, new_queue} ->
          GenServer.reply(from, :ok)
          {put_in(state.waiting[type], new_queue), 0}

        {:empty, _queue} ->
          tokens_to_add = min(current_tokens + 1, limit.burst) - current_tokens
          {state, tokens_to_add}
      end

    state = update_in(state.tokens[type], &(&1 + tokens_to_add))
    state = maybe_schedule_refill(state, type)

    {:noreply, state}
  end

  # Private helpers

  defp maybe_schedule_refill(state, type) do
    needs_refill =
      state.tokens[type] < @limits[type].burst or not :queue.is_empty(state.waiting[type])

    already_scheduled = state.refill_scheduled[type]

    if needs_refill and not already_scheduled do
      Process.send_after(self(), {:refill, type}, @limits[type].rate_ms)
      put_in(state.refill_scheduled[type], true)
    else
      state
    end
  end
end
