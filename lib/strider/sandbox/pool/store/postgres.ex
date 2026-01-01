if Code.ensure_loaded?(Ecto) do
  defmodule Strider.Sandbox.Pool.Store.Postgres do
    @moduledoc """
    Postgres-backed store for distributed pool management.

    Requires user to provide an Ecto Repo at runtime.

    ## Configuration

        config = %{
          repo: MyApp.Repo,
          partitions: ["ord", "ewr"]
        }

    ## Setup

    Run the migration in your app:

        defmodule MyApp.Repo.Migrations.CreatePoolEntries do
          use Ecto.Migration
          alias Strider.Sandbox.Pool.Store.Postgres.Migrations

          def change do
            Migrations.create_pool_tables()
          end
        end
    """

    @behaviour Strider.Sandbox.Pool.Store

    import Ecto.Query

    alias Strider.Sandbox.Pool.Store.Postgres.{Entry, Pending}

    @pending_stale_ms :timer.minutes(5)

    @impl true
    def init(config) do
      repo = Map.fetch!(config, :repo)
      {:ok, %{repo: repo}}
    end

    @impl true
    def pop(%{repo: repo}, partition_key, max_age_ms) do
      min_created_at = System.system_time(:millisecond) - max_age_ms

      target_id_query =
        from e in Entry,
          where: e.partition_key == ^partition_key and e.created_at > ^min_created_at,
          order_by: [asc: e.created_at],
          limit: 1,
          lock: "FOR UPDATE SKIP LOCKED",
          select: e.id

      query =
        from e in Entry,
          where: e.id in subquery(target_id_query),
          select: e

      case repo.delete_all(query) do
        {0, _} ->
          {:empty, :pool_empty}

        {1, [entry]} ->
          {:ok, entry_to_map(entry)}
      end
    end

    @impl true
    def push(%{repo: repo}, entry) do
      %Entry{}
      |> Entry.changeset(entry)
      |> repo.insert!()

      :ok
    end

    @impl true
    def remove(%{repo: repo}, id) do
      repo.delete_all(from e in Entry, where: e.id == ^id)
      :ok
    end

    @impl true
    def count(%{repo: repo}, partition_key) do
      repo.aggregate(
        from(e in Entry, where: e.partition_key == ^partition_key),
        :count
      )
    end

    @impl true
    def pending?(%{repo: repo}, partition_key) do
      stale_threshold = System.system_time(:millisecond) - @pending_stale_ms

      repo.delete_all(from p in Pending, where: p.created_at < ^stale_threshold)

      repo.exists?(from p in Pending, where: p.partition_key == ^partition_key)
    end

    @impl true
    def set_pending(%{repo: repo}, partition_key, true) do
      now = System.system_time(:millisecond)

      repo.insert(
        %Pending{partition_key: partition_key, created_at: now},
        on_conflict: :nothing
      )

      :ok
    end

    @impl true
    def set_pending(%{repo: repo}, partition_key, false) do
      repo.delete_all(from p in Pending, where: p.partition_key == ^partition_key)
      :ok
    end

    @impl true
    def counts_by_partition(%{repo: repo}) do
      query =
        from e in Entry,
          group_by: e.partition_key,
          select: {e.partition_key, count(e.id)}

      repo.all(query) |> Map.new()
    end

    @impl true
    def pending_count(%{repo: repo}) do
      repo.aggregate(Pending, :count)
    end

    @impl true
    def stop(_store_ref), do: :ok

    defp entry_to_map(%Entry{} = entry) do
      %{
        id: entry.id,
        partition_key: entry.partition_key,
        data: entry.data,
        created_at: entry.created_at
      }
    end
  end
end
