defmodule Pkglog.MixProject do
  use Mix.Project

  def project do
    [
      app: :pkglog,
      version: "2.0.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: [main_module: Pkglog.CLI, name: "pkglog"]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    []
  end
end
