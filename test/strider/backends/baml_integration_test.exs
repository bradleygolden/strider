if Code.ensure_loaded?(BamlElixir.Client) do
  defmodule Strider.Backends.BamlIntegrationTest do
    @moduledoc false

    use ExUnit.Case, async: false

    @moduletag :integration
    @moduletag :baml

    defmodule TestBaml do
      use BamlElixir.Client, path: "test/support/baml_src"
    end

    setup do
      case check_ollama_available() do
        :ok ->
          :ok

        {:error, reason} ->
          flunk("Ollama is not available: #{reason}. Start Ollama with: ollama serve")
      end
    end

    describe "direct BAML function calls" do
      test "ExtractPerson extracts structured data" do
        {:ok, result} = TestBaml.ExtractPerson.call(%{text: "John Smith is 30 years old"})

        assert is_struct(result, TestBaml.Person) or is_map(result)
        assert result.name =~ ~r/john/i or result.name =~ ~r/smith/i
      end

      test "Summarize returns a string summary" do
        text = """
        Elixir is a dynamic, functional language for building scalable and maintainable
        applications. Elixir runs on the Erlang VM, known for creating low-latency,
        distributed, and fault-tolerant systems.
        """

        {:ok, result} = TestBaml.Summarize.call(%{text: text})

        assert is_binary(result)
        assert String.length(result) > 0
      end

      test "Classify returns sentiment classification" do
        {:ok, result} = TestBaml.Classify.call(%{text: "I love this product, it's amazing!"})

        assert is_binary(result)
        assert String.downcase(result) =~ ~r/positive/
      end
    end

    describe "Strider BAML backend integration" do
      test "call/2 with :baml backend executes BAML function" do
        agent =
          Strider.Agent.new(
            {Strider.Backends.Baml, function: "Summarize", path: "test/support/baml_src"}
          )

        {:ok, response, _ctx} =
          Strider.call(agent, "The quick brown fox jumps over the lazy dog.")

        assert response.content != nil
        assert is_binary(response.content)
        assert response.metadata.provider == "baml"
        assert response.metadata.function == "Summarize"
      end

      test "call/2 with structured output function returns struct when prefix provided" do
        agent =
          Strider.Agent.new(
            {Strider.Backends.Baml,
             function: "ExtractPerson", path: "test/support/baml_src", prefix: TestBaml}
          )

        {:ok, response, _ctx} = Strider.call(agent, "Alice is 25 years old")

        assert response.content != nil
        assert is_struct(response.content, TestBaml.Person)
        assert response.content.name =~ ~r/alice/i
        assert response.finish_reason == :stop
      end

      test "introspect returns backend metadata" do
        agent =
          Strider.Agent.new(
            {Strider.Backends.Baml, function: "ExtractPerson", path: "test/support/baml_src"}
          )

        info = Strider.Agent.backend_module(agent).introspect(elem(agent.backend, 1))

        assert info.provider == "baml"
        assert info.function == "ExtractPerson"
        assert :structured_output in info.capabilities
      end
    end

    describe "output_schema parsing" do
      defmodule PersonStruct do
        defstruct [:name, :age]
      end

      defmodule PersonWithAge do
        defstruct [:name, :age]
      end

      defmodule PersonNameOnly do
        defstruct [:name]
      end

      test "call/2 with output_schema parses response through Zoi" do
        schema =
          Zoi.struct(PersonStruct, %{
            name: Zoi.string(),
            age: Zoi.integer() |> Zoi.optional()
          })
          |> Zoi.coerce()

        agent =
          Strider.Agent.new(
            {Strider.Backends.Baml, function: "ExtractPerson", path: "test/support/baml_src"}
          )

        {:ok, response, _ctx} =
          Strider.call(agent, "Alice is 25 years old", Strider.Context.new(),
            output_schema: schema
          )

        assert is_struct(response.content, PersonStruct)
        assert response.content.name =~ ~r/alice/i
      end

      test "call/2 with union output_schema parses to matching variant" do
        schema =
          Zoi.union([
            Zoi.object(%{name: Zoi.string(), age: Zoi.integer()})
            |> Zoi.transform(fn data -> struct!(PersonWithAge, data) end),
            Zoi.object(%{name: Zoi.string()})
            |> Zoi.transform(fn data -> struct!(PersonNameOnly, data) end)
          ])

        agent =
          Strider.Agent.new(
            {Strider.Backends.Baml, function: "ExtractPerson", path: "test/support/baml_src"}
          )

        {:ok, response, _ctx} =
          Strider.call(agent, "Bob is 30", Strider.Context.new(), output_schema: schema)

        assert is_struct(response.content, PersonWithAge) or
                 is_struct(response.content, PersonNameOnly)
      end

      test "call/2 without output_schema returns BamlElixir default" do
        agent =
          Strider.Agent.new(
            {Strider.Backends.Baml,
             function: "ExtractPerson", path: "test/support/baml_src", prefix: TestBaml}
          )

        {:ok, response, _ctx} = Strider.call(agent, "Charlie is 40 years old")

        assert is_struct(response.content, TestBaml.Person)
      end
    end

    describe "streaming" do
      test "stream/2 returns enumerable stream" do
        agent =
          Strider.Agent.new(
            {Strider.Backends.Baml, function: "Summarize", path: "test/support/baml_src"}
          )

        {:ok, stream, _ctx} =
          Strider.stream(agent, "Elixir is a functional programming language.")

        chunks = Enum.to_list(stream)

        assert not Enum.empty?(chunks)
        last_chunk = List.last(chunks)
        assert last_chunk.metadata.partial == false
      end
    end

    defp check_ollama_available do
      url = "http://localhost:11434/api/tags"

      case :httpc.request(:get, {~c"#{url}", []}, [timeout: 5000], []) do
        {:ok, {{_, 200, _}, _, _}} ->
          :ok

        {:ok, {{_, status, _}, _, _}} ->
          {:error, "Ollama returned status #{status}"}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end
end
