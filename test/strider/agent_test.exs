defmodule Strider.AgentTest do
  use ExUnit.Case, async: true

  alias Strider.Agent

  doctest Strider.Agent

  describe "backend_module/1" do
    test "resolves :mock to Mock backend" do
      agent = Agent.new({:mock, response: "Hello"})
      assert Agent.backend_module(agent) == Strider.Backends.Mock
    end

    test "resolves :req_llm to ReqLLM backend" do
      agent = Agent.new({:req_llm, "anthropic:claude-sonnet-4-5"})
      assert Agent.backend_module(agent) == Strider.Backends.ReqLLM
    end

    test "passes through full module name" do
      agent = Agent.new({Strider.Backends.Mock, response: "Hello"})
      assert Agent.backend_module(agent) == Strider.Backends.Mock
    end

    test "raises for unknown backend atom" do
      agent = Agent.new({:nonexistent, []})

      assert_raise ArgumentError, ~r/Unknown backend/, fn ->
        Agent.backend_module(agent)
      end
    end
  end

  describe "backend_config/1" do
    test "returns the backend configuration map" do
      agent = Agent.new({:mock, response: "Hello", delay: 100})
      assert Agent.backend_config(agent) == %{response: "Hello", delay: 100}
    end

    test "normalizes string model to map" do
      agent = Agent.new({:req_llm, "anthropic:claude-sonnet-4-5"})
      assert Agent.backend_config(agent) == %{model: "anthropic:claude-sonnet-4-5"}
    end
  end

  describe "put_config/3" do
    test "adds a config value" do
      agent = Agent.new({:mock, response: "Hello"})
      updated = Agent.put_config(agent, :temperature, 0.7)

      assert updated.config == %{temperature: 0.7}
    end

    test "overwrites existing config value" do
      agent =
        Agent.new({:mock, response: "Hello"}, temperature: 0.5)
        |> Agent.put_config(:temperature, 0.9)

      assert Agent.get_config(agent, :temperature) == 0.9
    end

    test "preserves other config values" do
      agent =
        Agent.new({:mock, response: "Hello"}, temperature: 0.5, max_tokens: 100)
        |> Agent.put_config(:temperature, 0.9)

      assert Agent.get_config(agent, :temperature) == 0.9
      assert Agent.get_config(agent, :max_tokens) == 100
    end
  end

  describe "get_config/2,3" do
    test "returns config value when present" do
      agent = Agent.new({:mock, response: "Hello"}, temperature: 0.7)
      assert Agent.get_config(agent, :temperature) == 0.7
    end

    test "returns nil for missing config" do
      agent = Agent.new({:mock, response: "Hello"})
      assert Agent.get_config(agent, :temperature) == nil
    end

    test "returns default for missing config" do
      agent = Agent.new({:mock, response: "Hello"})
      assert Agent.get_config(agent, :temperature, 1.0) == 1.0
    end

    test "returns value over default when present" do
      agent = Agent.new({:mock, response: "Hello"}, temperature: 0.7)
      assert Agent.get_config(agent, :temperature, 1.0) == 0.7
    end
  end
end
