if Code.ensure_loaded?(ReqLLM) do
  defmodule Strider.Backends.ReqLLM do
    @moduledoc """
    Backend implementation using the ReqLLM library.

    ReqLLM provides a unified interface to multiple LLM providers including
    OpenAI, Anthropic, Google, Amazon Bedrock, OpenRouter, and more.

    ## Model Specification

    The model must include the provider in `"provider:model"` format:

        # Direct API access
        model: "anthropic:claude-4-5-sonnet"
        model: "openai:gpt-4"
        model: "google:gemini-1.5-pro"

        # Via OpenRouter (access many models through one API)
        model: "openrouter:anthropic/claude-4-5-sonnet"
        model: "openrouter:openai/gpt-4"

        # Via Amazon Bedrock
        model: "amazon_bedrock:anthropic.claude-4-5-sonnet-20241022-v2:0"

        # Via Google Vertex AI
        model: "google_vertex:claude-4-5-sonnet@20240620"

    ## Configuration

    Additional options can be passed via the `:config` map:

    - `:temperature` - Sampling temperature (0.0 to 2.0)
    - `:max_tokens` - Maximum tokens in response
    - `:top_p` - Nucleus sampling parameter
    - `:stop` - Stop sequences

    ## Examples

        # Using Anthropic directly
        agent = Strider.Agent.new(
          {Strider.Backends.ReqLLM, "anthropic:claude-4-5-sonnet"},
          config: %{temperature: 0.7, max_tokens: 1000}
        )

        # Using OpenRouter
        agent = Strider.Agent.new(
          {Strider.Backends.ReqLLM, "openrouter:anthropic/claude-4-5-sonnet"}
        )

        # Using Amazon Bedrock
        agent = Strider.Agent.new(
          {Strider.Backends.ReqLLM, "amazon_bedrock:anthropic.claude-4-5-sonnet-20241022-v2:0"}
        )

    ## Supported Providers

    See ReqLLM documentation for the full list. Common providers:

    - `:anthropic` - Anthropic API (Claude models)
    - `:openai` - OpenAI API (GPT models)
    - `:google` - Google AI (Gemini models)
    - `:openrouter` - OpenRouter (multi-provider gateway)
    - `:amazon_bedrock` - AWS Bedrock
    - `:google_vertex` - Google Vertex AI
    - `:groq` - Groq (fast inference)
    - `:cerebras` - Cerebras

    """

    @behaviour Strider.Backend

    alias Strider.Response

    @impl true
    def call(config, messages, _opts) do
      model = Map.fetch!(config, :model)
      options = build_options(config)

      case ReqLLM.generate_text(model, messages, options) do
        {:ok, response} ->
          {:ok, normalize_response(response, model)}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def stream(config, messages, _opts) do
      model = Map.fetch!(config, :model)
      options = build_options(config)

      case ReqLLM.stream_text(model, messages, options) do
        {:ok, response} ->
          # ReqLLM returns a Response with stream field
          text_stream =
            response
            |> ReqLLM.Response.text_stream()
            |> Stream.map(fn text ->
              %{content: text, metadata: %{backend: :req_llm}}
            end)

          {:ok, text_stream}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def introspect do
      # Note: This returns static info. For dynamic provider/model,
      # use the metadata in Response which has the actual values used.
      %{
        provider: "req_llm",
        model: "dynamic",
        operation: :chat,
        capabilities: [:streaming, :multi_provider]
      }
    end

    # Private helpers

    defp build_options(config) do
      config
      |> Map.take([:temperature, :max_tokens, :top_p, :stop])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.into([])
    end

    defp normalize_response(response, model) do
      content = extract_content(response)
      usage = ReqLLM.Response.usage(response) || %{}
      finish_reason = ReqLLM.Response.finish_reason(response)

      Response.new(
        content: content,
        finish_reason: normalize_finish_reason(finish_reason),
        usage: normalize_usage(usage),
        metadata: build_metadata(response, model, finish_reason)
      )
    end

    defp build_metadata(response, model, raw_finish_reason) do
      {provider, model_name} = parse_model_string(model)

      %{
        # Standardized keys (OpenTelemetry GenAI conventions)
        provider: provider,
        model: extract_response_model(response) || model_name,
        response_id: extract_response_id(response),
        # Legacy/additional keys
        raw_finish_reason: raw_finish_reason
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
    end

    defp parse_model_string(model) when is_binary(model) do
      case String.split(model, ":", parts: 2) do
        [provider, model_name] -> {provider, model_name}
        [model_name] -> {"unknown", model_name}
      end
    end

    defp parse_model_string(_model), do: {"unknown", "unknown"}

    defp extract_response_id(%{id: id}) when is_binary(id), do: id
    defp extract_response_id(_), do: nil

    defp extract_response_model(%{model: model}) when is_binary(model), do: model
    defp extract_response_model(_), do: nil

    # Extract content from ReqLLM response, preserving structure
    defp extract_content(%{message: nil}), do: nil
    defp extract_content(%{message: %{content: content}}), do: content
    defp extract_content(_response), do: nil

    defp normalize_finish_reason("stop"), do: :stop
    defp normalize_finish_reason("end_turn"), do: :stop
    defp normalize_finish_reason("tool_use"), do: :tool_use
    defp normalize_finish_reason("tool_calls"), do: :tool_use
    defp normalize_finish_reason("max_tokens"), do: :max_tokens
    defp normalize_finish_reason("length"), do: :max_tokens
    defp normalize_finish_reason("content_filter"), do: :content_filter
    defp normalize_finish_reason(nil), do: nil
    defp normalize_finish_reason(other) when is_atom(other), do: other
    defp normalize_finish_reason(other) when is_binary(other), do: String.to_atom(other)

    defp normalize_usage(usage) when is_map(usage) do
      %{
        input_tokens: Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens") || 0,
        output_tokens: Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens") || 0
      }
    end

    defp normalize_usage(_), do: %{}
  end
end
