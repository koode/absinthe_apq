defmodule AbsintheAPQ.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/koode/absinthe_apq"

  def project do
    [
      app: :absinthe_apq,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Apollo Automatic Persisted Queries (APQ) for Absinthe and Absinthe.Plug.",
      package: package(),
      source_url: @source_url,
      docs: docs(),
      dialyzer: dialyzer()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:absinthe, "~> 1.12"},
      {:absinthe_plug, "~> 1.5"},
      {:plug, "~> 1.14"},
      {:telemetry, "~> 1.2"},
      {:jason, "~> 1.2", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "APQ protocol" => "https://www.apollographql.com/docs/apollo-server/performance/apq"
      },
      files: ~w(lib docs/PROTOCOL.md mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  # PLTs live in priv/plts so CI can cache them (see .github/workflows/ci.yml).
  defp dialyzer do
    [
      plt_core_path: "priv/plts",
      plt_local_path: "priv/plts",
      flags: [:error_handling, :extra_return, :missing_return, :unmatched_returns]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "docs/PROTOCOL.md", "CHANGELOG.md", "CONTRIBUTING.md", "LICENSE"]
    ]
  end
end
