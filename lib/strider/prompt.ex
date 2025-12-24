defmodule Strider.Prompt do
  @moduledoc """
  Behaviour for prompt template engines.

  This abstracts template parsing and rendering so different engines can be
  used interchangeably.

  ## Why Pluggable Templates?

  Different template engines have different strengths:

  - **Solid (Liquid)** - Familiar `{{ variable }}` syntax, safe sandboxed execution
  - **EEx** - Elixir's built-in, full language power
  - **HEEx** - HTML-aware, great for structured content

  This behaviour lets you swap engines without changing agent code.

  ## Example

  Using the default Solid implementation (requires `{:solid, "~> 0.15"}`):

      alias Strider.Prompt.Solid

      # Parse a template
      {:ok, template} = Solid.parse("Hello {{ name }}!")

      # Render with context
      {:ok, result} = Solid.render(template, %{name: "World"})
      # => "Hello World!"

      # Or parse and render in one step
      {:ok, result} = Solid.eval("Hello {{ name }}!", %{name: "World"})

  ## Implementing a Custom Engine

  To use a different template engine, implement this behaviour:

      defmodule MyApp.EExPrompt do
        @behaviour Strider.Prompt

        @impl true
        def parse(template), do: {:ok, template}

        @impl true
        def parse!(template), do: template

        @impl true
        def render(template, context) do
          result = EEx.eval_string(template, assigns: Map.to_list(context))
          {:ok, result}
        rescue
          e -> {:error, e}
        end

        @impl true
        def render!(template, context) do
          EEx.eval_string(template, assigns: Map.to_list(context))
        end

        @impl true
        def eval(template, context), do: render(template, context)
      end

  """

  @typedoc "A parsed template (implementation-specific)"
  @type t :: term()

  @typedoc "Context variables for template rendering"
  @type context :: %{optional(atom() | String.t()) => term()}

  @typedoc "Parse or render errors"
  @type error :: term()

  @doc """
  Parses a template string into an implementation-specific format.

  Returns `{:ok, parsed_template}` on success, `{:error, reason}` on failure.

  ## Examples

      {:ok, template} = MyEngine.parse("Hello {{ name }}!")
      {:error, reason} = MyEngine.parse("Hello {{ unclosed")

  """
  @callback parse(template :: String.t()) :: {:ok, t()} | {:error, error()}

  @doc """
  Parses a template string, raising on error.

  ## Examples

      template = MyEngine.parse!("Hello {{ name }}!")
      # Raises on invalid template

  """
  @callback parse!(template :: String.t()) :: t()

  @doc """
  Renders a parsed template with context variables.

  Returns `{:ok, rendered_string}` on success, `{:error, reason}` on failure.

  ## Examples

      {:ok, template} = MyEngine.parse("Hello {{ name }}!")
      {:ok, "Hello World!"} = MyEngine.render(template, %{name: "World"})

  """
  @callback render(template :: t(), context :: context()) ::
              {:ok, String.t()} | {:error, error()}

  @doc """
  Renders a parsed template, raising on error.

  ## Examples

      {:ok, template} = MyEngine.parse("Hello {{ name }}!")
      "Hello World!" = MyEngine.render!(template, %{name: "World"})

  """
  @callback render!(template :: t(), context :: context()) :: String.t()

  @doc """
  Parses and renders a template in one step.

  Convenience function that combines `parse/1` and `render/2`.

  ## Examples

      {:ok, "Hello World!"} = MyEngine.eval("Hello {{ name }}!", %{name: "World"})

  """
  @callback eval(template :: String.t(), context :: context()) ::
              {:ok, String.t()} | {:error, error()}
end
