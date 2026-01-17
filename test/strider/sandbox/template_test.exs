defmodule Strider.Sandbox.TemplateTest do
  use ExUnit.Case, async: false

  alias Strider.Sandbox
  alias Strider.Sandbox.Adapters.Test, as: TestAdapter
  alias Strider.Sandbox.Instance
  alias Strider.Sandbox.Template

  setup do
    name = :"test_adapter_#{System.unique_integer([:positive])}"
    start_supervised!({TestAdapter, name: name})
    {:ok, agent_name: name}
  end

  describe "new/1" do
    test "creates template with keyword syntax", %{agent_name: agent_name} do
      template =
        Template.new(
          adapter: TestAdapter,
          config: %{agent_name: agent_name, image: "alpine", memory_mb: 256}
        )

      assert template.adapter == TestAdapter
      assert template.config == %{agent_name: agent_name, image: "alpine", memory_mb: 256}
    end

    test "creates template with tuple syntax (map config)", %{agent_name: agent_name} do
      template =
        Template.new({TestAdapter, %{agent_name: agent_name, image: "alpine", memory_mb: 256}})

      assert template.adapter == TestAdapter
      assert template.config == %{agent_name: agent_name, image: "alpine", memory_mb: 256}
    end

    test "creates template with tuple syntax (keyword config)", %{agent_name: agent_name} do
      template =
        Template.new({TestAdapter, agent_name: agent_name, image: "alpine", memory_mb: 256})

      assert template.adapter == TestAdapter
      assert template.config == %{agent_name: agent_name, image: "alpine", memory_mb: 256}
    end

    test "normalizes keyword list config to map", %{agent_name: agent_name} do
      template =
        Template.new(
          adapter: TestAdapter,
          config: [agent_name: agent_name, image: "alpine", memory_mb: 256]
        )

      assert template.config == %{agent_name: agent_name, image: "alpine", memory_mb: 256}
    end

    test "defaults config to empty map" do
      template = Template.new(adapter: TestAdapter)

      assert template.config == %{}
    end
  end

  describe "merge/2" do
    test "merges overrides into template config" do
      template = Template.new({TestAdapter, %{image: "python", memory_mb: 256}})

      merged = Template.merge(template, %{memory_mb: 512, cpu: 2})

      assert merged == %{image: "python", memory_mb: 512, cpu: 2}
    end

    test "accepts keyword list overrides" do
      template = Template.new({TestAdapter, %{image: "python", memory_mb: 256}})

      merged = Template.merge(template, memory_mb: 512, cpu: 2)

      assert merged == %{image: "python", memory_mb: 512, cpu: 2}
    end

    test "deep merges nested maps" do
      template =
        Template.new(
          {TestAdapter,
           %{
             image: "python",
             nested: %{a: 1, b: 2}
           }}
        )

      merged = Template.merge(template, %{nested: %{b: 20, c: 3}})

      assert merged.nested == %{a: 1, b: 20, c: 3}
    end

    test "override wins for non-map values" do
      template = Template.new({TestAdapter, %{image: "python", ports: [4000]}})

      merged = Template.merge(template, %{ports: [8080, 9000]})

      assert merged.ports == [8080, 9000]
    end
  end

  describe "to_backend/2" do
    test "returns tuple for Sandbox.create/1" do
      template = Template.new({TestAdapter, %{image: "alpine"}})

      assert {TestAdapter, %{image: "alpine"}} = Template.to_backend(template)
    end

    test "applies overrides to backend tuple" do
      template = Template.new({TestAdapter, %{image: "alpine", memory_mb: 256}})

      {adapter, config} = Template.to_backend(template, %{memory_mb: 512})

      assert adapter == TestAdapter
      assert config == %{image: "alpine", memory_mb: 512}
    end
  end

  describe "Sandbox.create/2 with Template" do
    test "creates sandbox from template", %{agent_name: agent_name} do
      template = Template.new({TestAdapter, %{agent_name: agent_name, image: "test:latest"}})

      {:ok, sandbox} = Sandbox.create(template)

      assert %Instance{} = sandbox
      assert sandbox.adapter == TestAdapter
      assert sandbox.config == %{agent_name: agent_name, image: "test:latest"}
      assert Sandbox.status(sandbox) == :running
    end

    test "creates sandbox from template with overrides", %{agent_name: agent_name} do
      template =
        Template.new(
          {TestAdapter, %{agent_name: agent_name, image: "test:latest", memory_mb: 256}}
        )

      {:ok, sandbox} = Sandbox.create(template, memory_mb: 512, cpu: 2)

      assert sandbox.config == %{
               agent_name: agent_name,
               image: "test:latest",
               memory_mb: 512,
               cpu: 2
             }
    end

    test "works with keyword list overrides", %{agent_name: agent_name} do
      template = Template.new({TestAdapter, %{agent_name: agent_name, image: "test:latest"}})

      {:ok, sandbox} = Sandbox.create(template, env: [{"FOO", "bar"}])

      assert sandbox.config == %{
               agent_name: agent_name,
               image: "test:latest",
               env: [{"FOO", "bar"}]
             }
    end

    test "template without overrides works", %{agent_name: agent_name} do
      template = Template.new({TestAdapter, %{agent_name: agent_name, image: "test:latest"}})

      {:ok, sandbox} = Sandbox.create(template)

      assert sandbox.config == %{agent_name: agent_name, image: "test:latest"}
    end
  end
end
