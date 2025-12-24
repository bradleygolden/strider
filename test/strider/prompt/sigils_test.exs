if Code.ensure_loaded?(Solid) do
  defmodule Strider.Prompt.SigilsTest do
    use ExUnit.Case, async: true

    import Strider.Prompt.Sigils
    alias Strider.Prompt.Solid, as: PromptSolid

    describe "~P sigil" do
      test "creates a parsed template" do
        template = ~P"Hello {{ name }}!"
        assert is_struct(template, Solid.Template)
      end

      test "template can be rendered" do
        template = ~P"Hello {{ name }}!"
        assert {:ok, "Hello World!"} = PromptSolid.render(template, %{name: "World"})
      end

      test "works with multiline heredoc" do
        template = ~P"""
        Hello {{ name }}!
        Welcome to {{ place }}.
        """

        assert {:ok, result} = PromptSolid.render(template, %{name: "Alice", place: "Wonderland"})
        assert result =~ "Hello Alice!"
        assert result =~ "Welcome to Wonderland."
      end

      test "works with complex template" do
        template = ~P"""
        {% if user %}
        Hello {{ user.name }}!
        {% else %}
        Hello stranger!
        {% endif %}
        """

        # Solid requires string keys for nested access
        assert {:ok, with_user} =
                 PromptSolid.render(template, %{"user" => %{"name" => "Alice"}})

        assert with_user =~ "Hello Alice!"

        assert {:ok, without_user} = PromptSolid.render(template, %{user: nil})
        assert without_user =~ "Hello stranger!"
      end
    end

    describe "compile-time validation" do
      test "invalid template raises at compile time" do
        assert_raise CompileError, ~r/Invalid template/, fn ->
          Code.compile_string("""
          import Strider.Prompt.Sigils
          ~P"Hello {{ unclosed"
          """)
        end
      end
    end
  end
end
