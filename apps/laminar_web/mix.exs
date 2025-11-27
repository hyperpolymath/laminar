# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule LaminarWeb.MixProject do
  use Mix.Project

  @version "1.0.0"
  @source_url "https://github.com/hyperpolymath/laminar"

  def project do
    [
      app: :laminar_web,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      description: "High-velocity cloud streaming relay with GraphQL control plane",
      package: package(),
      docs: docs(),
      escript: escript(),
      releases: releases()
    ]
  end

  defp escript do
    [
      main_module: Laminar.CLI,
      name: "laminar",
      comment: "Cloud-to-cloud streaming relay"
    ]
  end

  defp releases do
    [
      laminar_web: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent],
        steps: [:assemble, :tar]
      ],
      laminar_cli: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent],
        cookie: "laminar_secret"
      ]
    ]
  end

  def application do
    [
      mod: {LaminarWeb.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Web Framework
      {:phoenix, "~> 1.7.10"},
      {:bandit, "~> 1.2"},
      {:jason, "~> 1.4"},
      {:cors_plug, "~> 3.0"},

      # GraphQL
      {:absinthe, "~> 1.7"},
      {:absinthe_plug, "~> 1.5"},
      {:absinthe_phoenix, "~> 2.0"},

      # HTTP Client (for Rclone RC API)
      {:finch, "~> 0.18"},
      {:mint, "~> 1.5"},

      # Concurrent Processing Pipeline
      {:broadway, "~> 1.0"},
      {:gen_stage, "~> 1.2"},

      # Compression
      {:zstd, "~> 0.3", optional: true},

      # Utilities
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 0.6"},

      # Development & Testing
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Laminar Contributors"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: ["../../README.adoc", "../../cookbook.adoc"]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      test: ["test"]
    ]
  end
end
