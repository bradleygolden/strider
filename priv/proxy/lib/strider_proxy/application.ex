defmodule StriderProxy.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    port = get_port()
    allowed_domains = get_allowed_domains()
    credentials = build_credentials()

    children = [
      {Bandit,
       plug: {Strider.Proxy.Sandbox, allowed_domains: allowed_domains, credentials: credentials},
       port: port}
    ]

    opts = [strategy: :one_for_one, name: StriderProxy.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp get_port do
    case System.get_env("PROXY_PORT") do
      nil -> 4000
      port -> String.to_integer(port)
    end
  end

  defp get_allowed_domains do
    case System.get_env("ALLOWED_DOMAINS") do
      nil -> []
      "" -> []
      domains -> String.split(domains, ",", trim: true)
    end
  end

  defp build_credentials do
    %{}
    |> maybe_add_anthropic_credentials()
    |> maybe_add_openai_credentials()
  end

  defp maybe_add_anthropic_credentials(acc) do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil ->
        acc

      key ->
        Map.put(acc, "api.anthropic.com", [
          {"x-api-key", key},
          {"anthropic-version", "2023-06-01"}
        ])
    end
  end

  defp maybe_add_openai_credentials(acc) do
    case System.get_env("OPENAI_API_KEY") do
      nil ->
        acc

      key ->
        Map.put(acc, "api.openai.com", [
          {"authorization", "Bearer #{key}"}
        ])
    end
  end
end
