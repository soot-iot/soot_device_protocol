defmodule SootDeviceProtocol.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/lawik/soot_device_protocol"

  def project do
    [
      app: :soot_device_protocol,
      version: @version,
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs(),
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :plug, :public_key, :crypto, :ssl, :inets],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts",
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters?: true
      ]
    ]
  end

  defp aliases do
    [
      format: "format --migrate",
      credo: "credo --strict"
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssl, :inets]
    ]
  end

  defp elixirc_paths(_), do: ["lib"]

  defp description do
    "Imperative device-side runtime for the Soot framework: enrollment, contract refresh, MQTT, shadow, commands, and telemetry."
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG*),
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md"]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:x509, "~> 0.8"},
      {:telemetry, "~> 1.0"},
      # Optional MQTT 5 client; the runtime only loads it via the
      # :emqtt transport, so a device that only uses the test transport
      # (or another implementation) need not pull it in.
      {:emqtt, "~> 1.14", optional: true},
      # Required by the SootDeviceProtocol.Test.Ingest fixture, which
      # ships in lib/ so downstream tests (soot_device, end-user
      # device tests) can use it through the path/hex dep.
      {:plug, "~> 1.19"},
      # Optional installer tooling — only loaded when the consumer is
      # running `mix igniter.install soot_device_protocol`. The runtime
      # never references Igniter.
      {:igniter, "~> 0.6", optional: true},
      # Dev / test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: [:dev], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}
    ] ++ duxedo_dep()
  end

  # Optional Duxedo backend for Telemetry.Buffer. Pulled in only when
  # the sibling repo is checked out alongside (developers typically
  # have it; CI on its own does not). When absent, `Buffer.Duxedo`
  # remains uncompiled — the default `Buffer.Memory` is what tests
  # exercise, and Duxedo coverage lives in the duxedo repo's own
  # suite plus the soot_device_protocol-with-duxedo path that
  # operators run locally.
  defp duxedo_dep do
    if File.dir?("../duxedo") do
      [{:duxedo, path: "../duxedo", optional: true}]
    else
      []
    end
  end
end
