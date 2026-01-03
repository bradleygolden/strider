if Code.ensure_loaded?(:telemetry) do
  defmodule Strider.TelemetryTest do
    use ExUnit.Case, async: false

    alias Strider.{Agent, Context}

    defmodule EventTracker do
      def start do
        if :ets.whereis(:telemetry_events) != :undefined do
          :ets.delete(:telemetry_events)
        end

        :ets.new(:telemetry_events, [:named_table, :public, :bag])
      end

      def record(event, measurements, metadata) do
        :ets.insert(:telemetry_events, {event, measurements, metadata})
      end

      def events do
        :ets.tab2list(:telemetry_events)
      end

      def has_event?(event_name) do
        events() |> Enum.any?(fn {event, _, _} -> event == event_name end)
      end
    end

    describe "Strider.Telemetry.Hooks" do
      setup do
        EventTracker.start()

        handler_id = "test-handler-#{:erlang.unique_integer()}"

        :telemetry.attach_many(
          handler_id,
          Strider.Telemetry.event_names(),
          fn event, measurements, metadata, _config ->
            EventTracker.record(event, measurements, metadata)
          end,
          nil
        )

        on_exit(fn ->
          :telemetry.detach(handler_id)
        end)

        :ok
      end

      test "emits call lifecycle events" do
        agent =
          Agent.new({Strider.Backends.Mock, response: "Hello!"}, hooks: Strider.Telemetry.Hooks)

        context = Context.new()

        {:ok, _response, _context} = Strider.call(agent, "Hi!", context)

        assert EventTracker.has_event?([:strider, :call, :start])
        assert EventTracker.has_event?([:strider, :backend, :request])
        assert EventTracker.has_event?([:strider, :backend, :response])
        assert EventTracker.has_event?([:strider, :call, :stop])
      end

      test "emits call error event on failure" do
        agent =
          Agent.new({Strider.Backends.Mock, error: :rate_limited}, hooks: Strider.Telemetry.Hooks)

        context = Context.new()

        {:error, :rate_limited} = Strider.call(agent, "Hi!", context)

        assert EventTracker.has_event?([:strider, :call, :start])
        assert EventTracker.has_event?([:strider, :call, :error])
      end

      test "emits stream lifecycle events" do
        agent =
          Agent.new({Strider.Backends.Mock, stream_chunks: ["Hello", " ", "world"]},
            hooks: Strider.Telemetry.Hooks
          )

        context = Context.new()

        {:ok, stream, _context} = Strider.stream(agent, "Hi!", context)

        assert EventTracker.has_event?([:strider, :stream, :start])
        assert EventTracker.has_event?([:strider, :backend, :request])

        _chunks = Enum.to_list(stream)

        assert EventTracker.has_event?([:strider, :stream, :chunk])
        assert EventTracker.has_event?([:strider, :stream, :stop])
      end

      test "emits stream usage event when chunk includes usage" do
        agent =
          Agent.new(
            {Strider.Backends.Mock,
             stream_chunks: ["Hello"], stream_usage: %{input_tokens: 1, output_tokens: 2}},
            hooks: Strider.Telemetry.Hooks
          )

        context = Context.new()

        {:ok, stream, _context} = Strider.stream(agent, "Hi!", context)

        _chunks = Enum.to_list(stream)

        assert EventTracker.has_event?([:strider, :stream, :usage])

        {_, measurements, metadata} =
          EventTracker.events()
          |> Enum.find(fn {event, _, _} -> event == [:strider, :stream, :usage] end)

        assert measurements == %{input_tokens: 1, output_tokens: 2}
        assert metadata.usage_stage == :final
        assert %Agent{} = metadata.agent
        assert %Context{} = metadata.context
      end
    end

    describe "Strider.Telemetry.event_names/0" do
      test "returns all event names" do
        names = Strider.Telemetry.event_names()

        assert [:strider, :call, :start] in names
        assert [:strider, :call, :stop] in names
        assert [:strider, :call, :error] in names
        assert [:strider, :stream, :start] in names
        assert [:strider, :stream, :chunk] in names
        assert [:strider, :stream, :usage] in names
        assert [:strider, :stream, :stop] in names
        assert [:strider, :backend, :request] in names
        assert [:strider, :backend, :response] in names
      end
    end

    describe "attach_default_logger/1" do
      test "attaches and detaches successfully" do
        assert :ok = Strider.Telemetry.attach_default_logger()
        assert {:error, :already_exists} = Strider.Telemetry.attach_default_logger()
        assert :ok = Strider.Telemetry.detach_default_logger()
        assert {:error, :not_found} = Strider.Telemetry.detach_default_logger()
      end
    end
  end
end
