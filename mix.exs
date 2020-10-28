defmodule AbsinthePermission.MixProject do
  use Mix.Project

  def project do
    [
      app: :absinthe_permission,
      name: "AbsinthePermission",
      package: package(),
      description: description(),
      version: "0.1.0",
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: [
        main: "AbsinthePermission",
        extras: ["README.md"]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description do
    "Fine-grained Permission/Policy Checker Middleware for Absinthe GraphQL"
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:absinthe, "~> 1.4"},
      {:ex_doc, "~> 0.22", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Baris Erdem"],
      licenses: ["MIT"],
      links: %{github: "https://github.com/b-erdem/absinthe_permission"},
      files: ~w(lib LICENSE mix.exs README.md)
    ]
  end
end
