defmodule Strider.ContentTest do
  use ExUnit.Case, async: true

  alias Strider.Content
  alias Strider.Content.Part

  defmodule TestStruct do
    @derive Jason.Encoder
    defstruct [:name, :value]
  end

  describe "wrap/1" do
    test "handles maps from structured output" do
      result = Content.wrap(%{"name" => "Test", "value" => 123})
      assert [%Part{type: :text, text: json}] = result
      assert Jason.decode!(json) == %{"name" => "Test", "value" => 123}
    end

    test "handles structs from structured output (via Zoi.struct)" do
      result = Content.wrap(%TestStruct{name: "Test", value: 123})
      assert [%Part{type: :text, text: json}] = result
      assert Jason.decode!(json) == %{"name" => "Test", "value" => 123}
    end

    test "Part structs are not JSON encoded" do
      part = Content.text("Hello!")
      result = Content.wrap(part)
      assert [^part] = result
    end
  end
end
