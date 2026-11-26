# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.V4L.MixProject do
  use Mix.Project

  @moduledoc """
  Beam Bots camera driver for Linux V4L2 devices, delivering raw frames via ffmpeg.
  """

  @version "0.3.0"

  def project do
    [
      aliases: aliases(),
      app: :bb_camera_v4l,
      consolidate_protocols: Mix.env() == :prod,
      deps: deps(),
      description: @moduledoc,
      dialyzer: dialyzer(),
      docs: docs(),
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      start_permanent: Mix.env() == :prod,
      version: @version
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix]
    ]
  end

  defp package do
    [
      files: ~w(lib .formatter.exs mix.exs README* CHANGELOG* LICENSE* usage-rules.md),
      maintainers: ["James Harton <james@harton.nz>"],
      licenses: ["Apache-2.0"],
      links: %{
        "Source" => "https://github.com/beam-bots/bb_camera_v4l",
        "Sponsor" => "https://github.com/sponsors/jimsynz"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "assets/logo.png",
      extras:
        ["README.md", "CHANGELOG.md"]
        |> Enum.concat(Path.wildcard("documentation/**/*.{md,livemd,cheatmd}")),
      groups_for_extras: [
        Tutorials: ~r/tutorials\//
      ],
      source_ref: "main",
      source_url: "https://github.com/beam-bots/bb_camera_v4l"
    ]
  end

  defp aliases, do: []

  defp bb_dep(default, package \\ :bb) do
    case System.get_env("BB_VERSION") do
      nil -> default
      "local" -> [path: "../#{package}", override: true]
      "main" -> [git: "https://github.com/beam-bots/#{package}.git", override: true]
      version -> "~> #{version}"
    end
  end

  defp deps do
    [
      {:bb, bb_dep("~> 0.33")},
      {:bb_camera, bb_dep("~> 0.2", :bb_camera)},
      {:bb_camera_ffmpeg, bb_dep("~> 0.2", :bb_camera_ffmpeg)},

      # dev/test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.9", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.6", only: [:dev, :test], runtime: false},
      {:usage_rules, "~> 1.2", only: [:dev], runtime: false}
    ]
  end

  defp elixirc_paths(env) when env in [:dev, :test], do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
