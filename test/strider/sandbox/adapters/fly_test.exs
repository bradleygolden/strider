if Code.ensure_loaded?(Req) do
  defmodule Strider.Sandbox.Adapters.FlyTest do
    use ExUnit.Case, async: true

    alias Strider.Sandbox.Adapters.Fly

    describe "get_url/2" do
      test "returns internal Fly DNS URL" do
        assert {:ok, "http://machine123.vm.my-app.internal:4001"} ==
                 Fly.get_url("my-app:machine123", 4001)
      end

      test "handles different ports" do
        assert {:ok, "http://abc.vm.test-app.internal:8080"} ==
                 Fly.get_url("test-app:abc", 8080)
      end
    end

    describe "sandbox_id format" do
      test "get_url raises on invalid sandbox_id format" do
        assert_raise ArgumentError, ~r/Invalid sandbox_id format/, fn ->
          Fly.get_url("invalid-no-colon", 4001)
        end
      end

      test "sandbox_id with colons in machine_id works" do
        assert {:ok, "http://abc:123:def.vm.my-app.internal:4001"} ==
                 Fly.get_url("my-app:abc:123:def", 4001)
      end
    end

    describe "stop/2" do
      @tag :integration
      test "requires FLY_API_TOKEN" do
        assert_raise ArgumentError, ~r/api_token is required/, fn ->
          Fly.stop("test-app:machine123")
        end
      end
    end

    describe "start/2" do
      @tag :integration
      test "requires FLY_API_TOKEN" do
        assert_raise ArgumentError, ~r/api_token is required/, fn ->
          Fly.start("test-app:machine123")
        end
      end
    end

    describe "wait/3" do
      @tag :integration
      test "requires FLY_API_TOKEN" do
        assert_raise ArgumentError, ~r/api_token is required/, fn ->
          Fly.wait("test-app:machine123", "stopped")
        end
      end

      @tag :integration
      test "accepts instance_id option" do
        assert_raise ArgumentError, ~r/api_token is required/, fn ->
          Fly.wait("test-app:machine123", "stopped", instance_id: "abc123")
        end
      end
    end
  end
end
