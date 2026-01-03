if Code.ensure_loaded?(:telemetry) do
  defmodule Strider.Telemetry do
    @moduledoc """
    Telemetry integration for Strider agents.

    This module provides observability for Strider through the `:telemetry` library.
    It implements `Strider.Hooks` to emit telemetry events at key lifecycle points.

    ## Usage

    Use the hooks with your agent:

        agent = Strider.Agent.new({Strider.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"},
          hooks: Strider.Telemetry.Hooks
        )

    Or attach to specific calls:

        Strider.call(agent, "Hello", context, hooks: Strider.Telemetry.Hooks)

    ## Events

    The following telemetry events are emitted:

    ### Call Events

    - `[:strider, :call, :start]` - When a call begins
      - Measurements: `%{system_time: integer}`
      - Metadata: `%{agent: Agent.t(), prompt: String.t(), context: Context.t()}`

    - `[:strider, :call, :stop]` - When a call completes successfully
      - Measurements: `%{system_time: integer}`
      - Metadata: `%{agent: Agent.t(), response: Response.t(), context: Context.t()}`

    - `[:strider, :call, :error]` - When a call fails
      - Measurements: `%{system_time: integer}`
      - Metadata: `%{agent: Agent.t(), error: term(), context: Context.t()}`

    ### Stream Events

    - `[:strider, :stream, :start]` - When streaming begins
      - Measurements: `%{system_time: integer}`
      - Metadata: `%{agent: Agent.t(), prompt: String.t(), context: Context.t()}`

    - `[:strider, :stream, :chunk]` - For each chunk received
      - Measurements: `%{}`
      - Metadata: `%{agent: Agent.t(), chunk: map(), context: Context.t()}`

    - `[:strider, :stream, :usage]` - When a stream chunk includes usage
      - Measurements: `%{input_tokens: integer, output_tokens: integer}`
      - Metadata: `%{agent: Agent.t(), context: Context.t(), usage_stage: :partial | :final}`

    - `[:strider, :stream, :stop]` - When streaming completes
      - Measurements: `%{system_time: integer}`
      - Metadata: `%{agent: Agent.t(), context: Context.t()}`

    ### Backend Events

    - `[:strider, :backend, :request]` - Before backend request
      - Measurements: `%{system_time: integer}`
      - Metadata: `%{config: map(), messages: list()}`

    - `[:strider, :backend, :response]` - After backend responds
      - Measurements: `%{system_time: integer}`
      - Metadata: `%{config: map(), response: Response.t()}`

    ## Attaching Handlers

        :telemetry.attach_many(
          "my-strider-handler",
          Strider.Telemetry.event_names(),
          &MyHandler.handle_event/4,
          nil
        )

    Or use the convenience function:

        Strider.Telemetry.attach_default_logger()

    """

    @doc """
    Returns all telemetry event names that can be emitted.

    Useful for attaching handlers to all events.

    ## Example

        :telemetry.attach_many("my-handler", Strider.Telemetry.event_names(), &handler/4, nil)

    """
    @spec event_names() :: [[atom()]]
    def event_names do
      [
        [:strider, :call, :start],
        [:strider, :call, :stop],
        [:strider, :call, :error],
        [:strider, :stream, :start],
        [:strider, :stream, :chunk],
        [:strider, :stream, :usage],
        [:strider, :stream, :stop],
        [:strider, :backend, :request],
        [:strider, :backend, :response]
      ]
    end

    @doc """
    Attaches a default logging handler to all Strider telemetry events.

    This is a convenience function for quick debugging. For production use,
    you should implement your own handler with appropriate log levels and formatting.

    ## Options

    - `:level` - Log level to use (default: `:debug`)

    ## Example

        Strider.Telemetry.attach_default_logger()
        Strider.Telemetry.attach_default_logger(level: :info)

    """
    @spec attach_default_logger(keyword()) :: :ok | {:error, :already_exists}
    def attach_default_logger(opts \\ []) do
      level = Keyword.get(opts, :level, :debug)

      :telemetry.attach_many(
        "strider-telemetry-default-logger",
        event_names(),
        &__MODULE__.log_event/4,
        %{level: level}
      )
    end

    @doc """
    Detaches the default logging handler.
    """
    @spec detach_default_logger() :: :ok | {:error, :not_found}
    def detach_default_logger do
      :telemetry.detach("strider-telemetry-default-logger")
    end

    @doc false
    def log_event(event, measurements, metadata, config) do
      require Logger

      level = Map.get(config, :level, :debug)
      event_name = Enum.join(event, ".")

      Logger.log(level, fn ->
        "[#{event_name}] #{inspect(measurements)} #{inspect(metadata, limit: 3)}"
      end)
    end
  end
end
