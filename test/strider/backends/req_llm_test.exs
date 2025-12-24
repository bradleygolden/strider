if Code.ensure_loaded?(ReqLLM) do
  defmodule Strider.Backends.ReqLLMTest do
    use ExUnit.Case, async: true

    alias Strider.Backends.ReqLLM

    describe "Strider.Backends.ReqLLM" do
      test "implements Strider.Backend behaviour" do
        # Ensure the module is loaded before checking function_exported?
        Code.ensure_loaded!(ReqLLM)

        # Verify the module implements the Backend behaviour
        assert function_exported?(ReqLLM, :call, 3)
        assert function_exported?(ReqLLM, :stream, 3)
        assert function_exported?(ReqLLM, :introspect, 0)
      end

      test "introspect returns backend info" do
        info = ReqLLM.introspect()

        # Standardized keys (OpenTelemetry GenAI conventions)
        assert info.provider == "req_llm"
        assert info.model == "dynamic"
        assert info.operation == :chat
        assert :streaming in info.capabilities
        assert :multi_provider in info.capabilities
      end
    end
  end
end
