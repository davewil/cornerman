defmodule Cornerman.MixProject do
  use Mix.Project

  def project do
    [
      app: :cornerman,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Cornerman.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # OS process control: process groups, kill_timeout, streamed stdout (ENG-474).
      {:erlexec, "~> 2.5"}
    ]
  end
end
