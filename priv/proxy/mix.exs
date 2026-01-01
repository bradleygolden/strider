defmodule StriderProxy.MixProject do
  use Mix.Project

  def project do
    [
      app: :strider_proxy,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {StriderProxy.Application, []}
    ]
  end

  defp deps do
    [
      # TODO: Change back to github ref after testing
      {:strider, path: "../strider"},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.15"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"}
    ]
  end
end
