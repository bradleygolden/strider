if Code.ensure_loaded?(:telemetry) do
  defmodule Strider.Telemetry.Hooks do
    @moduledoc """
    Strider.Hooks implementation that emits telemetry events.

    This module implements the `Strider.Hooks` behaviour and emits
    `:telemetry` events at each lifecycle point.

    ## Usage

        # Agent-level hooks
        agent = Strider.Agent.new({Strider.Backends.ReqLLM, "anthropic:claude-4-5-sonnet"},
          hooks: Strider.Telemetry.Hooks
        )

        # Per-call hooks
        Strider.call(agent, "Hello", context, hooks: Strider.Telemetry.Hooks)

        # Combined with other hooks
        Strider.call(agent, "Hello", context,
          hooks: [Strider.Telemetry.Hooks, MyApp.CustomHooks]
        )

    """

    @behaviour Strider.Hooks

    @impl true
    def on_call_start(agent, prompt, context) do
      :telemetry.execute(
        [:strider, :call, :start],
        %{system_time: System.system_time()},
        %{agent: agent, prompt: prompt, context: context}
      )

      # Store start time in process dictionary for duration calculation
      Process.put(:strider_call_start, System.monotonic_time())

      {:cont, prompt}
    end

    @impl true
    def on_call_end(agent, response, context) do
      start_time = Process.get(:strider_call_start, System.monotonic_time())
      duration = System.monotonic_time() - start_time
      Process.delete(:strider_call_start)

      :telemetry.execute(
        [:strider, :call, :stop],
        %{duration: duration},
        %{agent: agent, response: response, context: context}
      )

      {:cont, response}
    end

    @impl true
    def on_call_error(agent, error, context) do
      Process.delete(:strider_call_start)

      :telemetry.execute(
        [:strider, :call, :error],
        %{system_time: System.system_time()},
        %{agent: agent, error: error, context: context}
      )
    end

    @impl true
    def on_stream_start(agent, prompt, context) do
      :telemetry.execute(
        [:strider, :stream, :start],
        %{system_time: System.system_time()},
        %{agent: agent, prompt: prompt, context: context}
      )

      {:cont, prompt}
    end

    @impl true
    def on_stream_chunk(agent, chunk, context) do
      :telemetry.execute(
        [:strider, :stream, :chunk],
        %{},
        %{agent: agent, chunk: chunk, context: context}
      )
    end

    @impl true
    def on_stream_end(agent, context) do
      :telemetry.execute(
        [:strider, :stream, :stop],
        %{system_time: System.system_time()},
        %{agent: agent, context: context}
      )
    end

    @impl true
    def on_backend_request(config, messages) do
      :telemetry.execute(
        [:strider, :backend, :request],
        %{system_time: System.system_time()},
        %{config: config, messages: messages}
      )

      {:cont, messages}
    end

    @impl true
    def on_backend_response(config, response) do
      :telemetry.execute(
        [:strider, :backend, :response],
        %{system_time: System.system_time()},
        %{config: config, response: response}
      )

      {:cont, response}
    end
  end
end
