defmodule Strider.AgentTest do
  use ExUnit.Case, async: true

  alias Strider.Agent

  doctest Strider.Agent

  describe "backend_module/1" do
    test "returns Mock backend module" do
      agent = Agent.new({Strider.Backends.Mock, response: "Hello"})
      assert Agent.backend_module(agent) == Strider.Backends.Mock
    end

    test "returns ReqLLM backend module" do
      agent = Agent.new({Strider.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})
      assert Agent.backend_module(agent) == Strider.Backends.ReqLLM
    end

    if Code.ensure_loaded?(BamlElixir.Client) do
      test "returns Baml backend module" do
        agent =
          Agent.new({Strider.Backends.Baml, function: "ExtractPerson", path: "priv/baml_src"})

        assert Agent.backend_module(agent) == Strider.Backends.Baml
      end
    end
  end

  describe "backend_config/1" do
    test "returns the backend configuration map" do
      agent = Agent.new({Strider.Backends.Mock, response: "Hello", delay: 100})
      assert Agent.backend_config(agent) == %{response: "Hello", delay: 100}
    end

    test "normalizes string model to map" do
      agent = Agent.new({Strider.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})
      assert Agent.backend_config(agent) == %{model: "anthropic:claude-sonnet-4-5"}
    end
  end
end
