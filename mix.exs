defmodule ReticulumLink.MixProject do
  use Mix.Project

  @version "0.6.0"

  def project do
    [
      app: :reticulum_link,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      name: "Reticulum Link",
      description: "High-performance Reticulum transport node and LXMF relay",
      source_url: "https://github.com/synthalorian/reticulum-link",
      docs: [
        main: "ReticulumLink",
        extras: ["README.md", "PLAN.md"]
      ]
    ]
  end

  def application do
    [
      mod: {ReticulumLink.Application, []},
      extra_applications: [:logger, :runtime_tools, :crypto, :os_mon]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Web framework
      {:phoenix, "~> 1.7"},
      {:phoenix_pubsub, "~> 2.1"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},

      # Telemetry & monitoring
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},
      {:prom_ex, "~> 1.9"},

      # Serial / hardware
      {:circuits_uart, "~> 1.5", optional: true},
      {:circuits_gpio, "~> 1.1", optional: true},

      # Ed25519 for Reticulum identity
      {:ed25519, "~> 1.0"},

      # Testing
      {:stream_data, "~> 1.1", only: [:test, :dev]},

      # Code quality
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp releases do
    [
      reticulum_link: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :include]
      ]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "compile"]
    ]
  end
end
