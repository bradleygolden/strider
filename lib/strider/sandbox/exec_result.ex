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

  @doc """
  Returns true if the command executed successfully (exit code 0).

  ## Examples

      iex> result = Strider.Sandbox.ExecResult.new(exit_code: 0)
      iex> Strider.Sandbox.ExecResult.success?(result)
      true

      iex> result = Strider.Sandbox.ExecResult.new(exit_code: 1)
      iex> Strider.Sandbox.ExecResult.success?(result)
      false

  """
  @spec success?(t()) :: boolean()
  def success?(%__MODULE__{exit_code: 0}), do: true
  def success?(%__MODULE__{}), do: false

  @doc """
  Returns the output (stdout if present, otherwise stderr).

  Useful when you just want the command output regardless of stream.

  ## Examples

      iex> result = Strider.Sandbox.ExecResult.new(stdout: "hello", exit_code: 0)
      iex> Strider.Sandbox.ExecResult.output(result)
      "hello"

      iex> result = Strider.Sandbox.ExecResult.new(stderr: "error message", exit_code: 1)
      iex> Strider.Sandbox.ExecResult.output(result)
      "error message"

  """
  @spec output(t()) :: String.t()
  def output(%__MODULE__{stdout: stdout}) when stdout != "", do: stdout
  def output(%__MODULE__{stderr: stderr}), do: stderr
end
