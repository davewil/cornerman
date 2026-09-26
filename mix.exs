defmodule Cornerman.MixProject do
  use Mix.Project

  def project do
    [
      app: :cornerman,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
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
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # OS process control: process groups, kill_timeout, streamed stdout (ENG-474).
      {:erlexec, "~> 2.5"},
      # config.toml, the model-identity registry, DIVERGENCES.toml. Chosen over `toml` 0.7
      # (2022), whose decoder trips Elixir 1.20's type checker; both parsed the real files
      # identically (2026-09-26).
      {:toml_elixir, "~> 3.1"},
      # Run events (ENG-479): each task transition is published once and the state mirror,
      # the eval log and, from phase 3, LiveView subscribe. Phoenix.PubSub rather than a
      # hand-rolled Registry dispatch because phase 3 needs exactly this dependency.
      {:phoenix_pubsub, "~> 2.3"}
    ]
  end
end
