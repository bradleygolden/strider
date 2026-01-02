if Code.ensure_loaded?(Ecto) do
  defmodule Strider.Sandbox.Pool.Store.Postgres.Migrations do
    @moduledoc """
    Ecto migration helpers for the Postgres pool store.

    ## Usage

        defmodule MyApp.Repo.Migrations.CreatePoolEntries do
          use Ecto.Migration
          alias Strider.Sandbox.Pool.Store.Postgres.Migrations

          def change do
            Migrations.create_pool_tables()
          end
        end
    """

    use Ecto.Migration

    def create_pool_tables do
      create table(:pool_entries, primary_key: false) do
        add :id, :string, primary_key: true
        add :partition_key, :string, null: false
        add :data, :map, default: %{}, null: false
        add :created_at, :bigint, null: false

        timestamps type: :utc_datetime, updated_at: false
      end

      create index(:pool_entries, [:partition_key, :created_at])

      create table(:pool_entries_pending, primary_key: false) do
        add :partition_key, :string, primary_key: true
        add :created_at, :bigint, null: false
      end

      create index(:pool_entries_pending, [:created_at])
    end

    def drop_pool_tables do
      drop table(:pool_entries_pending)
      drop table(:pool_entries)
    end
  end
end
