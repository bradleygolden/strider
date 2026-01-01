if Code.ensure_loaded?(BamlElixir.Client) do
  defmodule Strider.Backends.Baml do
    @moduledoc false

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
          text = extract_last_user_text(messages)
          %{text: text}

        args when is_map(args) ->
          text = extract_last_user_text(messages)
          Map.put_new(args, :text, text)

        args when is_function(args, 1) ->
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
