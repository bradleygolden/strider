if Code.ensure_loaded?(ReqLLM) do
  defmodule Strider.Backends.ReqLLMTest do
    use ExUnit.Case, async: true

    alias Strider.Backends.ReqLLM

    describe "Strider.Backends.ReqLLM" do
      test "implements Strider.Backend behaviour" do
        Code.ensure_loaded!(ReqLLM)

        assert function_exported?(ReqLLM, :call, 3)
        assert function_exported?(ReqLLM, :stream, 3)
        assert function_exported?(ReqLLM, :introspect, 0)
      end

      test "introspect returns backend info" do
        info = ReqLLM.introspect()

        assert info.provider == "req_llm"
        assert info.model == "dynamic"
        assert info.operation == :chat
        assert :streaming in info.capabilities
        assert :multi_provider in info.capabilities
      end
    end
  end
end
