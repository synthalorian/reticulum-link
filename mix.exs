defmodule ReticulumLink.MixProject do
  use Mix.Project

  @version "0.7.0"

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
      extra_applications: [:logger, :runtime_tools, :crypto, :os_mon] ++ extra_applications(Mix.target())
    ]
  end

  defp extra_applications(:host), do: []
  defp extra_applications(_target), do: [:nerves_runtime, :nerves_pack]

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

      # Nerves (embedded)
      {:nerves, "~> 1.10", runtime: false},
      {:shoehorn, "~> 0.9"},
      {:ring_logger, "~> 0.11"},
      {:nerves_runtime, "~> 0.13"},
      {:nerves_pack, "~> 0.7"},

      # Target-specific systems (optional, fetched on demand)
      {:nerves_system_rpi4, "~> 1.29", runtime: false, targets: :rpi4},
      {:nerves_system_rpi3, "~> 1.29", runtime: false, targets: :rpi3},
      {:nerves_system_rpi0, "~> 1.29", runtime: false, targets: :rpi0},

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
        applications: [runtime_tools: :permanent]
      ]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "compile"],
      firmware: ["deps.get", "compile", "firmware"],
      "firmware.burn": ["firmware.burn"]
    ]
  end
end
