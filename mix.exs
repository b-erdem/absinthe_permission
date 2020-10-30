defmodule AbsinthePermission.MixProject do
  use Mix.Project

  @source_url "https://github.com/b-erdem/absinthe_permission"
  @version "0.1.0"

  def project do
    [
      app: :absinthe_permission,
      name: "AbsinthePermission",
      package: package(),
      description: description(),
      version: @version,
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: [
        main: "AbsinthePermission",
        extras: ["README.md"],
        source_ref: "v#{@version}",
        source_url: @source_url
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description do
    "Fine-grained Permission/Policy Checker Middleware for Absinthe GraphQL"
  end

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
      links: %{GitHub: @source_url},
      files: ~w(lib LICENSE mix.exs README.md)
    ]
  end
end
