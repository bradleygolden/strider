defmodule Strider.MessageTest do
  use ExUnit.Case, async: true

  alias Strider.Message

  describe "new/3" do
    test "creates a message with required fields" do
      message = Message.new(:user, "Hello!")

      assert message.role == :user
      assert message.content == "Hello!"
      assert message.metadata == %{}
    end

    test "creates a message with metadata" do
      message = Message.new(:assistant, "Hi!", %{tokens: 5})

      assert message.role == :assistant
      assert message.content == "Hi!"
      assert message.metadata == %{tokens: 5}
    end

    test "accepts all valid roles" do
      assert %Message{role: :system} = Message.new(:system, "System prompt")
      assert %Message{role: :user} = Message.new(:user, "User message")
      assert %Message{role: :assistant} = Message.new(:assistant, "Assistant reply")
    end

    test "accepts multi-modal content as list" do
      content = [
        %{type: :text, text: "What's in this image?"},
        %{type: :image_url, url: "https://example.com/image.png"}
      ]

      message = Message.new(:user, content)

      assert message.role == :user
      assert message.content == content
    end

    test "accepts structured content as map" do
      content = %{audio: <<1, 2, 3>>, format: "wav"}

      message = Message.new(:user, content)

      assert message.role == :user
      assert message.content == content
    end
  end

  describe "to_provider_format/1" do
    test "converts message to provider format" do
      message = Message.new(:user, "Hello!")

      assert Message.to_provider_format(message) == %{
               role: "user",
               content: "Hello!"
             }
    end

    test "converts all roles correctly" do
      assert %{role: "system"} = Message.to_provider_format(Message.new(:system, "test"))
      assert %{role: "user"} = Message.to_provider_format(Message.new(:user, "test"))
      assert %{role: "assistant"} = Message.to_provider_format(Message.new(:assistant, "test"))
    end

    test "preserves multi-modal content in provider format" do
      content = [
        %{type: :text, text: "Describe this"},
        %{type: :image_url, url: "https://example.com/img.png"}
      ]

      message = Message.new(:user, content)

      assert Message.to_provider_format(message) == %{
               role: "user",
               content: content
             }
    end
  end
end
