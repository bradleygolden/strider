defmodule Strider.ResponseTest do
  use ExUnit.Case, async: true

  alias Strider.Response

  doctest Strider.Response

  describe "new/1" do
    test "creates response with defaults" do
      response = Response.new()

      assert response.content == nil
      assert response.tool_calls == []
      assert response.finish_reason == nil
      assert response.usage == %{}
      assert response.metadata == %{}
    end

    test "creates response with content" do
      response = Response.new(content: "Hello!")

      assert response.content == "Hello!"
    end

    test "creates response with all fields" do
      response =
        Response.new(
          content: "Hello!",
          tool_calls: [%{id: "1", name: "search", arguments: %{}}],
          finish_reason: :stop,
          usage: %{input_tokens: 10, output_tokens: 5},
          metadata: %{model: "claude-3"}
        )

      assert response.content == "Hello!"
      assert length(response.tool_calls) == 1
      assert response.finish_reason == :stop
      assert response.usage == %{input_tokens: 10, output_tokens: 5}
      assert response.metadata == %{model: "claude-3"}
    end
  end

  describe "has_tool_calls?/1" do
    test "returns true when tool_calls is non-empty" do
      response = Response.new(tool_calls: [%{id: "1", name: "search", arguments: %{}}])

      assert Response.has_tool_calls?(response) == true
    end

    test "returns false when tool_calls is empty" do
      response = Response.new(content: "Hello!")

      assert Response.has_tool_calls?(response) == false
    end

    test "returns false for default response" do
      response = Response.new()

      assert Response.has_tool_calls?(response) == false
    end
  end

  describe "complete?/1" do
    test "returns true for :stop finish_reason" do
      response = Response.new(finish_reason: :stop)

      assert Response.complete?(response) == true
    end

    test "returns true for :end_turn finish_reason" do
      response = Response.new(finish_reason: :end_turn)

      assert Response.complete?(response) == true
    end

    test "returns false for :tool_use finish_reason" do
      response = Response.new(finish_reason: :tool_use)

      assert Response.complete?(response) == false
    end

    test "returns false for :max_tokens finish_reason" do
      response = Response.new(finish_reason: :max_tokens)

      assert Response.complete?(response) == false
    end

    test "returns false for nil finish_reason" do
      response = Response.new()

      assert Response.complete?(response) == false
    end
  end

  describe "total_tokens/1" do
    test "returns total_tokens when present" do
      response = Response.new(usage: %{total_tokens: 50})

      assert Response.total_tokens(response) == 50
    end

    test "calculates from input + output tokens" do
      response = Response.new(usage: %{input_tokens: 10, output_tokens: 20})

      assert Response.total_tokens(response) == 30
    end

    test "prefers total_tokens over calculation" do
      response =
        Response.new(usage: %{input_tokens: 10, output_tokens: 20, total_tokens: 50})

      assert Response.total_tokens(response) == 50
    end

    test "returns nil when no usage data" do
      response = Response.new()

      assert Response.total_tokens(response) == nil
    end

    test "returns nil when only zeros" do
      response = Response.new(usage: %{input_tokens: 0, output_tokens: 0})

      assert Response.total_tokens(response) == nil
    end
  end
end
