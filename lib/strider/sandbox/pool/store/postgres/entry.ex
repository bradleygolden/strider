defmodule Strider.Sandbox.Pool.Store.Postgres.Entry do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "pool_entries" do
    field :partition_key, :string
    field :data, :map, default: %{}
    field :created_at, :integer

    timestamps type: :utc_datetime, updated_at: false
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:id, :partition_key, :data, :created_at])
    |> validate_required([:id, :partition_key, :created_at])
  end
end
