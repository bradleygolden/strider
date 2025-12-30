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
  defstruct [:id, :adapter, :config, metadata: %{}, created_at: nil]

  @doc """
  Creates a new Instance struct with the given attributes.
  """
  @spec new(map()) :: t()
  def new(attrs) do
    struct!(__MODULE__, Map.put(attrs, :created_at, System.monotonic_time(:millisecond)))
  end
end
