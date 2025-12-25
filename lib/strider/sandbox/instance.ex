defmodule Strider.Sandbox.Instance do
  @moduledoc """
  Struct representing a sandbox instance.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          adapter: module(),
          config: map(),
          metadata: map(),
          status: :running | :stopped | :terminated,
          created_at: integer()
        }

  @enforce_keys [:id, :adapter]
  defstruct [:id, :adapter, :config, metadata: %{}, status: :running, created_at: nil]

  @doc """
  Creates a new Instance struct with the given attributes.
  """
  @spec new(map()) :: t()
  def new(attrs) do
    struct!(__MODULE__, Map.put(attrs, :created_at, System.monotonic_time(:millisecond)))
  end
end
