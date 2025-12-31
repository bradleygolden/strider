defmodule Strider.Sandbox.ExecResult do
  @moduledoc """
  Struct representing the result of executing a command in a sandbox.

  ## Fields

  - `stdout` - Standard output from the command
  - `stderr` - Standard error from the command
  - `exit_code` - Exit code of the command (0 typically means success)

  ## Examples

      %Strider.Sandbox.ExecResult{
        stdout: "hello world",
        stderr: "",
        exit_code: 0
      }

  """

  @type t :: %__MODULE__{
          stdout: String.t(),
          stderr: String.t(),
          exit_code: non_neg_integer()
        }

  defstruct stdout: "", stderr: "", exit_code: 0

  @doc """
  Creates a new ExecResult with the given attributes.

  ## Examples

      iex> Strider.Sandbox.ExecResult.new(stdout: "hello", exit_code: 0)
      %Strider.Sandbox.ExecResult{stdout: "hello", stderr: "", exit_code: 0}

  """
  @spec new(keyword()) :: t()
  def new(attrs \\ []) do
    struct(__MODULE__, attrs)
  end
end
