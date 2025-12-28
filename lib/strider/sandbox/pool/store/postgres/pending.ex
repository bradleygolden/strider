defmodule Strider.Sandbox.Pool.Store.Postgres.Pending do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:partition_key, :string, autogenerate: false}
  schema "pool_entries_pending" do
    field :created_at, :integer
  end
end
