defmodule Strider.Backends.ReqLLMTest.TestPerson do
  @derive Jason.Encoder
  defstruct [:name, :age]
end

if Code.ensure_loaded?(ReqLLM) do
  defmodule Strider.Backends.ReqLLMTest do
    use ExUnit.Case, async: true

    alias Strider.Backends.ReqLLM
    alias Strider.Backends.ReqLLMTest.TestPerson
    alias Strider.{Content, Message}

    describe "Strider.Backends.ReqLLM" do
      test "implements Strider.Backend behaviour" do
        Code.ensure_loaded!(ReqLLM)

        assert function_exported?(ReqLLM, :call, 3)
        assert function_exported?(ReqLLM, :stream, 3)
        assert function_exported?(ReqLLM, :introspect, 0)
      end

      test "introspect returns backend info" do
        info = ReqLLM.introspect()

        assert info.provider == "req_llm"
        assert info.model == "dynamic"
        assert info.operation == :chat
        assert :streaming in info.capabilities
        assert :multi_provider in info.capabilities
      end
    end

    describe "call/3 with output_schema" do
      setup do
        Req.Test.stub(__MODULE__, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          request = Jason.decode!(body)

          if request["tool_choice"] do
            Req.Test.json(conn, %{
              "id" => "msg_123",
              "type" => "message",
              "role" => "assistant",
              "model" => "claude-sonnet-4-20250514",
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "toolu_123",
                  "name" => "structured_output",
                  "input" => %{"name" => "Alice", "age" => 30}
                }
              ],
              "stop_reason" => "tool_use",
              "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
            })
          else
            Req.Test.json(conn, %{
              "id" => "msg_456",
              "type" => "message",
              "role" => "assistant",
              "model" => "claude-sonnet-4-20250514",
              "content" => [%{"type" => "text", "text" => "Hello!"}],
              "stop_reason" => "end_turn",
              "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
            })
          end
        end)

        :ok
      end

      test "returns structured content when output_schema is provided" do
        config = %{
          model: "anthropic:claude-sonnet-4-20250514",
          req_http_options: [plug: {Req.Test, __MODULE__}]
        }

        messages = [Message.new(:user, "Generate a person")]
        output_schema = Zoi.object(%{name: Zoi.string(), age: Zoi.integer()})

        assert {:ok, response} = ReqLLM.call(config, messages, output_schema: output_schema)
        assert response.content == %{"name" => "Alice", "age" => 30}
        assert response.finish_reason in [:tool_use, :tool_calls]
        assert response.usage.input_tokens == 10
        assert response.usage.output_tokens == 20
      end

      test "returns struct when output_schema is Zoi.struct with coerce: true" do
        config = %{
          model: "anthropic:claude-sonnet-4-20250514",
          req_http_options: [plug: {Req.Test, __MODULE__}]
        }

        messages = [Message.new(:user, "Generate a person")]

        output_schema =
          Zoi.struct(TestPerson, %{name: Zoi.string(), age: Zoi.integer()}, coerce: true)

        assert {:ok, response} = ReqLLM.call(config, messages, output_schema: output_schema)
        assert %TestPerson{name: "Alice", age: 30} = response.content
      end

      test "returns text content when output_schema is not provided" do
        config = %{
          model: "anthropic:claude-sonnet-4-20250514",
          req_http_options: [plug: {Req.Test, __MODULE__}]
        }

        messages = [Message.new(:user, "Say hello")]

        assert {:ok, response} = ReqLLM.call(config, messages, [])
        assert [%{text: "Hello!"}] = response.content
        assert response.finish_reason == :stop
      end

      test "converts multi-modal content to ReqLLM format" do
        config = %{
          model: "anthropic:claude-sonnet-4-20250514",
          req_http_options: [plug: {Req.Test, __MODULE__}]
        }

        messages = [
          Message.new(:user, [
            Content.text("What's in this image?"),
            Content.image_url("https://example.com/cat.png")
          ])
        ]

        assert {:ok, response} = ReqLLM.call(config, messages, [])
        assert [%{text: "Hello!"}] = response.content
      end
    end
  end
end
