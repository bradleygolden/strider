defmodule Strider.Sandbox.ExecResult do
  @moduledoc """
  Struct representing the result of executing a command in a sandbox.
  """

  @type t :: %__MODULE__{
          stdout: String.t(),
          stderr: String.t(),
          exit_code: non_neg_integer()
        }

  defstruct stdout: "", stderr: "", exit_code: 0
end
