if Code.ensure_loaded?(Solid) do
  defmodule Strider.Prompt.SolidTest do
    use ExUnit.Case, async: true

    alias Strider.Prompt.Solid, as: PromptSolid

    describe "parse/1" do
      test "parses valid template" do
        assert {:ok, template} = PromptSolid.parse("Hello {{ name }}!")
        assert is_struct(template, Solid.Template)
      end

      test "returns error for invalid template" do
        assert {:error, _reason} = PromptSolid.parse("Hello {{ unclosed")
      end
    end

    describe "parse!/1" do
      test "parses valid template" do
        template = PromptSolid.parse!("Hello {{ name }}!")
        assert is_struct(template, Solid.Template)
      end

      test "raises for invalid template" do
        assert_raise ArgumentError, ~r/Failed to parse template/, fn ->
          PromptSolid.parse!("Hello {{ unclosed")
        end
      end
    end

    describe "render/2" do
      test "renders template with atom keys" do
        {:ok, template} = PromptSolid.parse("Hello {{ name }}!")
        assert {:ok, "Hello World!"} = PromptSolid.render(template, %{name: "World"})
      end

      test "renders template with string keys" do
        {:ok, template} = PromptSolid.parse("Hello {{ name }}!")
        assert {:ok, "Hello World!"} = PromptSolid.render(template, %{"name" => "World"})
      end

      test "renders template with nested values" do
        {:ok, template} = PromptSolid.parse("Hello {{ user.name }}!")

        assert {:ok, "Hello Alice!"} =
                 PromptSolid.render(template, %{"user" => %{"name" => "Alice"}})
      end

      test "renders empty string for missing variable" do
        {:ok, template} = PromptSolid.parse("Hello {{ name }}!")
        assert {:ok, "Hello !"} = PromptSolid.render(template, %{})
      end

      test "renders template with conditionals" do
        {:ok, template} = PromptSolid.parse("{% if show %}visible{% endif %}")
        assert {:ok, "visible"} = PromptSolid.render(template, %{show: true})
        assert {:ok, ""} = PromptSolid.render(template, %{show: false})
      end

      test "renders template with loops" do
        {:ok, template} = PromptSolid.parse("{% for i in items %}{{ i }},{% endfor %}")
        assert {:ok, "a,b,c,"} = PromptSolid.render(template, %{items: ["a", "b", "c"]})
      end
    end

    describe "render!/2" do
      test "renders template successfully" do
        {:ok, template} = PromptSolid.parse("Hello {{ name }}!")
        assert "Hello World!" = PromptSolid.render!(template, %{name: "World"})
      end
    end

    describe "eval/2" do
      test "parses and renders in one step" do
        assert {:ok, "Hello World!"} = PromptSolid.eval("Hello {{ name }}!", %{name: "World"})
      end

      test "returns error for invalid template" do
        assert {:error, _reason} = PromptSolid.eval("Hello {{ unclosed", %{})
      end

      test "renders with mixed key types" do
        context = %{x: "a"} |> Map.put("y", "b")

        assert {:ok, "a and b"} = PromptSolid.eval("{{ x }} and {{ y }}", context)
      end
    end

    describe "multiline templates" do
      test "handles multiline templates" do
        template = """
        Hello {{ name }}!
        Welcome to {{ place }}.
        """

        assert {:ok, result} = PromptSolid.eval(template, %{name: "Alice", place: "Wonderland"})
        assert result =~ "Hello Alice!"
        assert result =~ "Welcome to Wonderland."
      end
    end
  end
end
