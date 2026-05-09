defmodule AbsinthePermission.MixProject do
  use Mix.Project

  @source_url "https://github.com/b-erdem/absinthe_permission"
  @version "1.0.0"

  def project do
    [
      app: :absinthe_permission,
      name: "AbsinthePermission",
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      deps: deps(),
      docs: docs(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      preferred_cli_env: [
        check: :test,
        "test.coverage": :test
      ],
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        flags: [:error_handling, :unknown, :unmatched_returns]
      ],
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp description do
    "Declarative, schema-first authorization middleware for Absinthe GraphQL. " <>
      "Auth rules live next to the field they protect."
  end

  defp deps do
    [
      {:absinthe, "~> 1.7"},
      {:telemetry, "~> 1.0"},
      {:dataloader, "~> 2.0", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Baris Erdem"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: ~w(lib LICENSE mix.exs README.md CHANGELOG.md AGENTS.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "AGENTS.md"],
      source_ref: "v#{@version}",
      source_url: @source_url,
      groups_for_modules: [
        "Core API": [
          AbsinthePermission,
          AbsinthePermission.Middleware
        ],
        "DSL Helpers": [
          AbsinthePermission.DSL,
          AbsinthePermission.Conditions
        ],
        "Data Structures": [
          AbsinthePermission.Rule,
          AbsinthePermission.Decision,
          AbsinthePermission.Condition
        ],
        Internals: [
          AbsinthePermission.Compiler,
          AbsinthePermission.Evaluator,
          AbsinthePermission.Registry
        ]
      ]
    ]
  end

  defp aliases do
    [
      check: [
        "format --check-formatted",
        "credo --strict",
        "sobelow --config",
        "dialyzer",
        "test"
      ],
      "test.coverage": ["coveralls.html"]
    ]
  end
end
