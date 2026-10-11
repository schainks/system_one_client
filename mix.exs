defmodule SystemOneClient.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/schainks/system_one_client"

  def project do
    [
      app: :system_one_client,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Client for System One decision models (TypeSafe Jev, Cloudflare Clef, OpenAI Decisions, OpenRouter, self-hosted): " <>
          "typed Choice, Noul and Score answers with full probability distributions, a behaviour and stub for tests.",
      package: package(),
      docs: docs(),
      name: "SystemOneClient",
      source_url: @source_url
    ]
  end

  def application, do: [extra_applications: [:logger]]

  def cli do
    [preferred_envs: [docs: :docs, "hex.publish": :docs]]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.3"},
      {:plug, "~> 1.16", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :docs, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "https://hexdocs.pm/system_one_client/changelog.html"
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [main: "readme", extras: ["README.md", "CHANGELOG.md"], source_ref: "v#{@version}"]
  end
end
