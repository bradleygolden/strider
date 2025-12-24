defmodule StriderTest do
  use ExUnit.Case, async: true

  alias Strider.{Agent, Context}

  describe "call/4 with mock backend" do
    test "returns a response and updated context" do
      agent = Agent.new({:mock, response: "Hello from mock!"})
      context = Context.new()

      assert {:ok, response, updated_context} = Strider.call(agent, "Hi!", context)

      assert response.content == "Hello from mock!"
      assert Context.message_count(updated_context) == 2

      messages = Context.to_messages(updated_context)
      assert Enum.at(messages, 0) == %{role: "user", content: "Hi!"}
      assert Enum.at(messages, 1) == %{role: "assistant", content: "Hello from mock!"}
    end

    test "includes system prompt in messages" do
      agent =
        Agent.new({:mock, response: "I'm here to help!"},
          system_prompt: "You are a helpful assistant."
        )

      context = Context.new()

      assert {:ok, _response, _context} = Strider.call(agent, "Hello!", context)
    end

    test "preserves conversation history" do
      agent = Agent.new({:mock, responses: ["First reply", "Second reply"]})
      context = Context.new()

      {:ok, _response1, context} = Strider.call(agent, "First message", context)
      {:ok, _response2, context} = Strider.call(agent, "Second message", context)

      assert Context.message_count(context) == 4
    end

    test "returns error from backend" do
      agent = Agent.new({:mock, error: :rate_limited})
      context = Context.new()

      assert {:error, :rate_limited} = Strider.call(agent, "Hello!", context)
    end

    test "accepts multi-modal content" do
      agent = Agent.new({:mock, response: "I see an image of a cat."})
      context = Context.new()

      multi_modal_content = [
        %{type: :text, text: "What's in this image?"},
        %{type: :image_url, url: "https://example.com/cat.png"}
      ]

      assert {:ok, response, updated_context} =
               Strider.call(agent, multi_modal_content, context)

      assert response.content == "I see an image of a cat."

      messages = Context.to_messages(updated_context)
      assert Enum.at(messages, 0) == %{role: "user", content: multi_modal_content}
    end

    test "accepts structured content as map" do
      agent = Agent.new({:mock, response: "Audio processed."})
      context = Context.new()

      structured_content = %{audio: "base64data", format: "wav"}

      assert {:ok, response, updated_context} =
               Strider.call(agent, structured_content, context)

      assert response.content == "Audio processed."

      messages = Context.to_messages(updated_context)
      assert Enum.at(messages, 0) == %{role: "user", content: structured_content}
    end
  end

  describe "stream/4 with mock backend" do
    test "returns a stream of chunks" do
      agent = Agent.new({:mock, stream_chunks: ["Hello", " ", "world", "!"]})
      context = Context.new()

      assert {:ok, stream, updated_context} = Strider.stream(agent, "Hi!", context)

      chunks = Enum.to_list(stream)
      assert length(chunks) == 4
      assert Enum.map(chunks, & &1.content) == ["Hello", " ", "world", "!"]

      assert Context.message_count(updated_context) == 1
    end

    test "returns error from backend" do
      agent = Agent.new({:mock, error: :connection_failed})
      context = Context.new()

      assert {:error, :connection_failed} = Strider.stream(agent, "Hello!", context)
    end
  end

  describe "Agent.new/1 API styles" do
    test "tuple as first argument" do
      agent = Agent.new({:req_llm, "anthropic:claude-4-5-sonnet"})

      assert agent.backend == {:req_llm, "anthropic:claude-4-5-sonnet"}
      assert agent.system_prompt == nil
    end

    test "tuple with options" do
      agent =
        Agent.new({:req_llm, "openai:gpt-4"},
          system_prompt: "You are helpful.",
          temperature: 0.7
        )

      assert agent.backend == {:req_llm, "openai:gpt-4"}
      assert agent.system_prompt == "You are helpful."
      assert agent.config == %{temperature: 0.7}
    end

    test "pure keyword style" do
      agent =
        Agent.new(
          backend: {:req_llm, "openai:gpt-4"},
          system_prompt: "You are helpful."
        )

      assert agent.backend == {:req_llm, "openai:gpt-4"}
      assert agent.system_prompt == "You are helpful."
    end

    test "three-element tuple with backend options (BYOK)" do
      agent = Agent.new({:req_llm, "anthropic:claude-4-5-sonnet", api_key: "sk-test"})

      assert agent.backend == {:req_llm, "anthropic:claude-4-5-sonnet", [api_key: "sk-test"]}
    end

    test "mock backend with keyword config" do
      agent = Agent.new({:mock, response: "Hello!", delay: 100})

      assert agent.backend == {:mock, [response: "Hello!", delay: 100]}
    end
  end
end
