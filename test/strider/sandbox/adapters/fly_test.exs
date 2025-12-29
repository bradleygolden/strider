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

    describe "status/1" do
      @tag :integration
      test "requires FLY_API_TOKEN" do
        assert_raise ArgumentError, ~r/api_token is required/, fn ->
          Fly.status("test-app:machine123")
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

    describe "get_machine_volumes/2" do
      test "requires api_token" do
        assert_raise ArgumentError, ~r/api_token is required/, fn ->
          Fly.get_machine_volumes("test-app:machine123")
        end
      end

      test "requires valid sandbox_id format" do
        assert_raise ArgumentError, ~r/Invalid sandbox_id/, fn ->
          Fly.get_machine_volumes("invalid", api_token: "test")
        end
      end
    end

    describe "create/1 mount validation" do
      test "rejects mount with missing path" do
        config = %{
          image: "node:22-slim",
          app_name: "test-app",
          api_token: "fake-token",
          mounts: [%{volume: "vol_abc123"}]
        }

        assert {:error, {:invalid_mount, %{volume: "vol_abc123"}}} = Fly.create(config)
      end

      test "rejects mount with missing volume and missing name" do
        config = %{
          image: "node:22-slim",
          app_name: "test-app",
          api_token: "fake-token",
          mounts: [%{path: "/data"}]
        }

        assert {:error, {:invalid_mount, %{path: "/data"}}} = Fly.create(config)
      end

      test "rejects auto-create mount with invalid size_gb" do
        config = %{
          image: "node:22-slim",
          app_name: "test-app",
          api_token: "fake-token",
          mounts: [%{name: "my-vol", path: "/data", size_gb: 0}]
        }

        assert {:error, {:invalid_mount, _}} = Fly.create(config)
      end

      test "rejects auto-create mount with negative size_gb" do
        config = %{
          image: "node:22-slim",
          app_name: "test-app",
          api_token: "fake-token",
          mounts: [%{name: "my-vol", path: "/data", size_gb: -5}]
        }

        assert {:error, {:invalid_mount, _}} = Fly.create(config)
      end

      test "rejects auto-create mount with missing size_gb" do
        config = %{
          image: "node:22-slim",
          app_name: "test-app",
          api_token: "fake-token",
          mounts: [%{name: "my-vol", path: "/data"}]
        }

        assert {:error, {:invalid_mount, _}} = Fly.create(config)
      end

      test "rejects mount with non-string volume" do
        config = %{
          image: "node:22-slim",
          app_name: "test-app",
          api_token: "fake-token",
          mounts: [%{volume: 123, path: "/data"}]
        }

        assert {:error, {:invalid_mount, _}} = Fly.create(config)
      end

      test "rejects mount with non-string path" do
        config = %{
          image: "node:22-slim",
          app_name: "test-app",
          api_token: "fake-token",
          mounts: [%{volume: "vol_abc", path: 123}]
        }

        assert {:error, {:invalid_mount, _}} = Fly.create(config)
      end
    end
  end
end
