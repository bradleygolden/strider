if Code.ensure_loaded?(BamlElixir.Client) do
  defmodule Strider.Backends.Baml do
    @moduledoc """
    Backend implementation using BAML (Boundary AI Markup Language).

    BAML provides type-safe, structured LLM function calls defined in `.baml` files.
    Unlike traditional chat backends, BAML functions have explicit input/output schemas.

    ## How BAML Works

    BAML defines functions in `.baml` files that specify:
    - Input parameters with types
    - Output types (structured data)
    - Prompt templates
    - LLM client configuration

    The `baml_elixir` library parses these files and generates type-safe Elixir modules.

    ## Configuration

    The backend config requires:
    - `:function` - The BAML function name to call (string)
    - `:path` - Path to BAML source files (default: "baml_src")

    Optional:
    - `:llm_client` - Override the LLM client configured in BAML
    - `:collectors` - List of collectors for observability
    - `:parse` - Whether to parse results into structs (default: true)
    - `:prefix` - Module prefix for parsed structs (e.g., `MyApp.Baml`)
    - `:args_format` - How to build function arguments (see Structured Inputs)
    - `:args` - Custom arguments map or builder function

    ## Usage

    There are two approaches to using BAML with Strider:

    ### Approach 1: Direct BAML Function Calls

    Call specific BAML functions where the user message becomes function arguments:

        # For a BAML function like:
        # function ExtractPerson(text: string) -> Person
        agent = Strider.Agent.new({:baml,
          function: "ExtractPerson",
          path: "priv/baml_src"
        })

        # The message content is used as input to the function
        {:ok, response, _ctx} = Strider.call(agent, "John is 30 years old")
        # response.content => %{name: "John", age: 30}

    ### Approach 2: Chat-like BAML Functions

    For BAML functions designed for chat:

        # function Chat(messages: Message[]) -> string
        agent = Strider.Agent.new({:baml,
          function: "Chat",
          path: "priv/baml_src"
        })

        {:ok, response, ctx} = Strider.call(agent, "Hello!")

    ## Structured Output

    BAML functions return structured data by design. The output type is defined
    in the `.baml` file and automatically parsed:

        # BAML: function Analyze(text: string) -> Analysis
        # where Analysis has fields: sentiment, topics, summary

        {:ok, response, _} = Strider.call(agent, "Great product!")
        response.content
        # => %{sentiment: "positive", topics: ["product"], summary: "..."}

    ## With Collectors

    Collectors provide observability into LLM calls:

        collector = BamlElixir.Collector.new("my-collector")

        agent = Strider.Agent.new({:baml,
          function: "ExtractPerson",
          path: "priv/baml_src",
          collectors: [collector]
        })

        {:ok, response, _} = Strider.call(agent, "...")
        usage = BamlElixir.Collector.usage(collector)

    ## Structured Inputs

    BAML supports rich input types beyond simple strings. You can define classes,
    arrays, maps, unions, and optional types as function parameters:

        # In your .baml file:
        class Car {
          make string
          model string
          year int
        }

        function EvaluateCar(car: Car) -> string {
          client Ollama
          prompt #"Evaluate this car: {{ car }}"#
        }

    ### Args Format Options

    The `:args_format` option controls how Strider builds arguments for the BAML function:

    - `:auto` (default) - Uses last user message as `text`, merges with `:args` if provided
    - `:text` - Passes `%{text: <last_user_message>}`
    - `:messages` - Passes `%{messages: [...]}` with all messages formatted
    - `:raw` - Uses `:args` directly without modification

    ### Passing Structured Data

    For functions with structured inputs, use `:args_format` with `:raw` or provide
    an `:args` map:

        # Static structured input
        agent = Strider.Agent.new({:baml,
          function: "EvaluateCar",
          path: "priv/baml_src",
          args_format: :raw,
          args: %{car: %{make: "Toyota", model: "Camry", year: 2024}}
        })

        {:ok, response, _} = Strider.call(agent, "")

    ### Dynamic Arguments with Builder Function

    For dynamic argument building, pass a function to `:args`:

        agent = Strider.Agent.new({:baml,
          function: "EvaluateCar",
          path: "priv/baml_src",
          args: fn messages ->
            # Build args from message content
            text = extract_text(messages)
            car = parse_car_from_text(text)
            %{car: car}
          end
        })

    ### Supported BAML Input Types

    BAML supports these input types in function parameters:

    - Classes: `function Foo(input: MyClass) -> string`
    - Arrays: `function Foo(items: string[]) -> string`
    - Maps: `function Foo(data: map<string, int>) -> string`
    - Unions: `function Foo(value: int | string) -> string`
    - Optional: `function Foo(maybe: string?) -> string`

    """

    @behaviour Strider.Backend

    alias Strider.{Message, Response}

    @impl true
    def call(config, messages, _opts) do
      function_name = Map.fetch!(config, :function)
      args = build_args(messages, config)
      baml_opts = build_baml_opts(config)

      case BamlElixir.Client.call(function_name, args, baml_opts) do
        {:ok, result} ->
          {:ok, build_response(result, config)}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def stream(config, messages, _opts) do
      function_name = Map.fetch!(config, :function)
      args = build_args(messages, config)
      baml_opts = build_baml_opts(config)
      caller = self()
      ref = make_ref()

      stream =
        Stream.resource(
          fn -> start_stream(caller, ref, function_name, args, baml_opts) end,
          fn state -> receive_chunks(state, ref) end,
          fn _state -> :ok end
        )

      {:ok, stream}
    end

    @impl true
    def introspect(config) do
      %{
        provider: "baml",
        model: Map.get(config, :llm_client, "default"),
        operation: :chat,
        function: Map.get(config, :function, "unknown"),
        capabilities: [:streaming, :structured_output]
      }
    end

    # Build arguments for the BAML function from Strider messages.
    # BAML functions can accept various argument shapes depending on their definition.
    defp build_args(messages, config) do
      case Map.get(config, :args_format, :auto) do
        :auto ->
          auto_build_args(messages, config)

        :messages ->
          %{messages: format_messages(messages)}

        :text ->
          %{text: extract_last_user_text(messages)}

        :raw ->
          Map.get(config, :args, %{})
      end
    end

    defp auto_build_args(messages, config) do
      case Map.get(config, :args) do
        nil ->
          # Default: use last user message as main input
          text = extract_last_user_text(messages)
          %{text: text}

        args when is_map(args) ->
          # Merge provided args with message content
          text = extract_last_user_text(messages)
          Map.put_new(args, :text, text)

        args when is_function(args, 1) ->
          # Custom arg builder function
          args.(messages)
      end
    end

    defp extract_last_user_text(messages) do
      messages
      |> Enum.filter(&(&1.role == :user))
      |> List.last()
      |> case do
        nil -> ""
        %Message{content: content} -> extract_text_from_content(content)
      end
    end

    defp extract_text_from_content(parts) when is_list(parts) do
      parts
      |> Enum.filter(&(&1.type == :text))
      |> Enum.map_join("\n", & &1.text)
    end

    defp format_messages(messages) do
      Enum.map(messages, fn %Message{role: role, content: content} ->
        %{
          role: to_string(role),
          content: extract_text_from_content(content)
        }
      end)
    end

    defp build_baml_opts(config) do
      %{}
      |> maybe_put(:path, Map.get(config, :path))
      |> maybe_put(:collectors, Map.get(config, :collectors))
      |> maybe_put(:llm_client, Map.get(config, :llm_client))
      |> maybe_put(:parse, Map.get(config, :parse, true))
      |> maybe_put(:prefix, Map.get(config, :prefix))
    end

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)

    defp build_response(result, config) do
      Response.new(
        content: result,
        finish_reason: :stop,
        usage: %{},
        metadata: %{
          provider: "baml",
          function: Map.get(config, :function),
          backend: :baml
        }
      )
    end

    defp start_stream(caller, ref, function_name, args, opts) do
      spawn_link(fn ->
        BamlElixir.Client.stream(
          function_name,
          args,
          fn
            {:partial, result} ->
              send(caller, {ref, {:chunk, result}})

            {:done, result} ->
              send(caller, {ref, {:done, result}})

            {:error, reason} ->
              send(caller, {ref, {:error, reason}})
          end,
          opts
        )
      end)

      :streaming
    end

    defp receive_chunks(:done, _ref) do
      {:halt, :done}
    end

    defp receive_chunks(:streaming, ref) do
      receive do
        {^ref, {:chunk, result}} ->
          chunk = %{content: result, metadata: %{partial: true}}
          {[chunk], :streaming}

        {^ref, {:done, result}} ->
          chunk = %{content: result, metadata: %{partial: false}}
          {[chunk], :done}

        {^ref, {:error, reason}} ->
          raise "BAML stream error: #{inspect(reason)}"
      after
        30_000 ->
          raise "BAML stream timeout"
      end
    end
  end
end
