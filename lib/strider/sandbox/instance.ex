defmodule Strider.Sandbox.Instance do
  @moduledoc """
  Struct representing a sandbox instance.

  This is a lightweight handle to an existing sandbox. The actual sandbox
  state lives in the infrastructure (Docker container, Fly machine, etc.)
  and should be queried via `Strider.Sandbox.status/1`.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          adapter: module(),
          config: map(),
          metadata: map(),
          created_at: integer()
        }

  @enforce_keys [:id, :adapter]
  defstruct [:id, :adapter, config: %{}, metadata: %{}, created_at: nil]

  @doc """
  Creates a new Instance struct with the given attributes.

  ## Examples

      iex> Strider.Sandbox.Instance.new(id: "abc123", adapter: Docker)
      %Strider.Sandbox.Instance{id: "abc123", adapter: Docker, config: %{}, metadata: %{}, created_at: _}

  """
  @spec new(keyword()) :: t()
  def new(attrs \\ []) do
    attrs
    |> Keyword.put_new_lazy(:created_at, fn -> System.monotonic_time(:millisecond) end)
    |> then(&struct!(__MODULE__, &1))
  end
end
