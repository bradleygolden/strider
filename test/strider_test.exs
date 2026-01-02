defmodule StriderTest do
  use ExUnit.Case, async: true

  alias Strider.{Agent, Content, Context, Message}

  describe "call/4 with mock backend" do
    test "returns a response and updated context" do
      agent = Agent.new({Strider.Backends.Mock, response: "Hello from mock!"})
      context = Context.new()

      assert {:ok, response, updated_context} = Strider.call(agent, "Hi!", context)

      assert response.content == "Hello from mock!"
      assert Context.message_count(updated_context) == 2

      messages = Context.messages(updated_context)
      assert Enum.at(messages, 0).role == :user
      assert Enum.at(messages, 0).content == [Content.text("Hi!")]
      assert Enum.at(messages, 1).role == :assistant
      assert Enum.at(messages, 1).content == [Content.text("Hello from mock!")]
    end

    test "includes system prompt in messages" do
      agent =
        Agent.new({Strider.Backends.Mock, response: "I'm here to help!"},
          system_prompt: "You are a helpful assistant."
        )

      context = Context.new()

      assert {:ok, _response, _context} = Strider.call(agent, "Hello!", context)
    end

    test "preserves conversation history" do
      agent = Agent.new({Strider.Backends.Mock, response: "Reply"})
      context = Context.new()

      {:ok, _response1, context} = Strider.call(agent, "First message", context)
      {:ok, _response2, context} = Strider.call(agent, "Second message", context)

      assert Context.message_count(context) == 4
    end

    test "returns error from backend" do
      agent = Agent.new({Strider.Backends.Mock, error: :rate_limited})
      context = Context.new()

      assert {:error, :rate_limited} = Strider.call(agent, "Hello!", context)
    end

    test "accepts multi-modal content" do
      agent = Agent.new({Strider.Backends.Mock, response: "I see an image of a cat."})
      context = Context.new()

      multi_modal_content = [
        Content.text("What's in this image?"),
        Content.image_url("https://example.com/cat.png")
      ]

      assert {:ok, response, updated_context} =
               Strider.call(agent, multi_modal_content, context)

      assert response.content == "I see an image of a cat."

      messages = Context.messages(updated_context)
      assert Enum.at(messages, 0).content == multi_modal_content
    end

    test "accepts binary image content" do
      agent = Agent.new({Strider.Backends.Mock, response: "Audio processed."})
      context = Context.new()

      content = [
        Content.text("Transcribe this audio"),
        Content.audio(<<1, 2, 3>>, "audio/wav")
      ]

      assert {:ok, response, _updated_context} =
               Strider.call(agent, content, context)

      assert response.content == "Audio processed."
    end
  end

  describe "stream/4 with mock backend" do
    test "returns a stream of chunks" do
      agent = Agent.new({Strider.Backends.Mock, stream_chunks: ["Hello", " ", "world", "!"]})
      context = Context.new()

      assert {:ok, stream, updated_context} = Strider.stream(agent, "Hi!", context)

      chunks = Enum.to_list(stream)
      assert length(chunks) == 4
      assert Enum.map(chunks, & &1.content) == ["Hello", " ", "world", "!"]

      assert Context.message_count(updated_context) == 1
    end

    test "returns error from backend" do
      agent = Agent.new({Strider.Backends.Mock, error: :connection_failed})
      context = Context.new()

      assert {:error, :connection_failed} = Strider.stream(agent, "Hello!", context)
    end
  end

  describe "call/2 with agent (no context)" do
    test "creates fresh context implicitly" do
      agent = Agent.new({Strider.Backends.Mock, response: "Hello!"})

      assert {:ok, response, context} = Strider.call(agent, "Hi!")

      assert response.content == "Hello!"
      assert Context.message_count(context) == 2
    end

    test "works with multi-modal content" do
      agent = Agent.new({Strider.Backends.Mock, response: "I see a cat."})

      multi_modal = [
        Content.text("What's this?"),
        Content.image_url("https://example.com/cat.png")
      ]

      assert {:ok, response, _ctx} = Strider.call(agent, multi_modal)
      assert response.content == "I see a cat."
    end

    test "works with messages content (conversation history)" do
      agent = Agent.new({Strider.Backends.Mock, response: "Your name is Alice."})

      messages = [
        %{role: :user, content: "My name is Alice"},
        %{role: :assistant, content: "Nice to meet you, Alice!"},
        %{role: :user, content: "What's my name?"}
      ]

      assert {:ok, response, context} = Strider.call(agent, messages)
      assert response.content == "Your name is Alice."
      # Context should have the history + response
      assert Context.message_count(context) == 4
    end

    test "works with few-shot examples" do
      agent = Agent.new({Strider.Backends.Mock, response: "Adiós"})

      few_shot = [
        %{role: :user, content: "Translate: Hello"},
        %{role: :assistant, content: "Hola"},
        %{role: :user, content: "Translate: Goodbye"}
      ]

      assert {:ok, response, _ctx} = Strider.call(agent, few_shot)
      assert response.content == "Adiós"
    end

    test "works with multi-modal content in messages" do
      agent = Agent.new({Strider.Backends.Mock, response: "I see a cat in the image."})

      messages = [
        %{
          role: :user,
          content: [
            Content.text("What's in this image?"),
            Content.image_url("https://example.com/cat.png")
          ]
        },
        %{role: :assistant, content: "I see a cat."},
        %{role: :user, content: "What color is it?"}
      ]

      assert {:ok, response, context} = Strider.call(agent, messages)
      assert response.content == "I see a cat in the image."
      assert Context.message_count(context) == 4
    end

    test "works with Strider.Message structs" do
      agent = Agent.new({Strider.Backends.Mock, response: "Hello Alice!"})

      messages = [
        Message.new(:user, "My name is Alice"),
        Message.new(:assistant, "Nice to meet you!"),
        Message.new(:user, "Say hello to me")
      ]

      assert {:ok, response, _ctx} = Strider.call(agent, messages)
      assert response.content == "Hello Alice!"
    end

    test "works with Content structs" do
      agent = Agent.new({Strider.Backends.Mock, response: "I see a cat."})

      content = [
        Content.text("What's in this image?"),
        Content.image_url("https://example.com/cat.png")
      ]

      assert {:ok, response, _ctx} = Strider.call(agent, content)
      assert response.content == "I see a cat."
    end

    test "works with Content structs in messages" do
      agent = Agent.new({Strider.Backends.Mock, response: "It's orange."})

      messages = [
        Message.new(:user, [
          Content.text("What's this?"),
          Content.image_url("https://example.com/cat.png")
        ]),
        Message.new(:assistant, "I see a cat."),
        Message.new(:user, Content.text("What color is it?"))
      ]

      assert {:ok, response, _ctx} = Strider.call(agent, messages)
      assert response.content == "It's orange."
    end
  end

  describe "stream/2 with agent (no context)" do
    test "creates fresh context implicitly" do
      agent = Agent.new({Strider.Backends.Mock, stream_chunks: ["Hello", " ", "world"]})

      assert {:ok, stream, context} = Strider.stream(agent, "Hi!")

      chunks = Enum.to_list(stream)
      assert Enum.map(chunks, & &1.content) == ["Hello", " ", "world"]
      assert Context.message_count(context) == 1
    end

    test "works with messages content" do
      agent =
        Agent.new(
          {Strider.Backends.Mock, stream_chunks: ["Your", " ", "name", " ", "is", " ", "Alice"]}
        )

      messages = [
        %{role: :user, content: "My name is Alice"},
        %{role: :assistant, content: "Nice to meet you!"},
        %{role: :user, content: "What's my name?"}
      ]

      assert {:ok, stream, context} = Strider.stream(agent, messages)

      chunks = Enum.to_list(stream)
      assert length(chunks) == 7
      # Context should have history (2 messages) + user message (1)
      assert Context.message_count(context) == 3
    end
  end

  describe "call/2 with :context option" do
    test "appends messages to existing context" do
      existing_context =
        Context.new()
        |> Context.add_message(:user, "My name is Alice")
        |> Context.add_message(:assistant, "Nice to meet you, Alice!")

      {:ok, response, updated_context} =
        Strider.call("What's my name?",
          backend: Strider.Backends.Mock,
          model: "mock",
          response: "Your name is Alice.",
          context: existing_context
        )

      assert response.content == "Your name is Alice."
      # Should have: 2 existing + 1 new user + 1 new assistant = 4
      assert Context.message_count(updated_context) == 4
    end

    test "appends conversation history to existing context" do
      existing_context =
        Context.new()
        |> Context.add_message(:user, "Remember: the secret word is banana")
        |> Context.add_message(:assistant, "Got it, I'll remember that.")

      {:ok, response, updated_context} =
        Strider.call(
          [
            %{role: :user, content: "What's 2+2?"},
            %{role: :assistant, content: "4"},
            %{role: :user, content: "What's the secret word?"}
          ],
          backend: Strider.Backends.Mock,
          model: "mock",
          response: "The secret word is banana.",
          context: existing_context
        )

      assert response.content == "The secret word is banana."
      # 2 existing + 2 from messages history + 1 user + 1 assistant = 6
      assert Context.message_count(updated_context) == 6
    end
  end

  describe "stream/2 with :context option" do
    test "appends to existing context" do
      existing_context =
        Context.new()
        |> Context.add_message(:user, "My name is Bob")
        |> Context.add_message(:assistant, "Hi Bob!")

      {:ok, stream, updated_context} =
        Strider.stream("Tell me a joke",
          backend: Strider.Backends.Mock,
          model: "mock",
          stream_chunks: ["Why", " did", " the", " chicken"],
          context: existing_context
        )

      chunks = Enum.to_list(stream)
      assert length(chunks) == 4
      # 2 existing + 1 new user = 3 (stream doesn't add assistant response)
      assert Context.message_count(updated_context) == 3
    end
  end

  describe "Agent.new/1 API styles" do
    test "tuple as first argument" do
      agent = Agent.new({Strider.Backends.ReqLLM, "anthropic:claude-sonnet-4-5"})

      assert agent.backend == {Strider.Backends.ReqLLM, %{model: "anthropic:claude-sonnet-4-5"}}
      assert agent.system_prompt == nil
    end

    test "tuple with options" do
      agent =
        Agent.new({Strider.Backends.ReqLLM, model: "openai:gpt-4", temperature: 0.7},
          system_prompt: "You are helpful."
        )

      assert agent.backend ==
               {Strider.Backends.ReqLLM, %{model: "openai:gpt-4", temperature: 0.7}}

      assert agent.system_prompt == "You are helpful."
    end

    test "pure keyword style" do
      agent =
        Agent.new(
          backend: {Strider.Backends.ReqLLM, "openai:gpt-4"},
          system_prompt: "You are helpful."
        )

      assert agent.backend == {Strider.Backends.ReqLLM, %{model: "openai:gpt-4"}}
      assert agent.system_prompt == "You are helpful."
    end

    test "three-element tuple with backend options (BYOK)" do
      agent =
        Agent.new({Strider.Backends.ReqLLM, "anthropic:claude-sonnet-4-5", api_key: "sk-test"})

      assert agent.backend ==
               {Strider.Backends.ReqLLM,
                %{model: "anthropic:claude-sonnet-4-5", api_key: "sk-test"}}
    end

    test "mock backend with keyword config" do
      agent = Agent.new({Strider.Backends.Mock, response: "Hello!", delay: 100})

      assert agent.backend == {Strider.Backends.Mock, %{response: "Hello!", delay: 100}}
    end
  end
end
