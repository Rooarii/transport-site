defmodule Transport.Mixfile do
  use Mix.Project

  def project do
    [
      app: :transport,
      version: "0.0.1",
      elixir: "~> 1.10",
      elixirc_paths: elixirc_paths(Mix.env()),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      gettext: [{:write_reference_comments, false}],
      preferred_cli_env: [
        vcr: :test,
        "vcr.delete": :test,
        "vcr.check": :test,
        "vcr.show": :test,
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def application do
    [
      mod: {Transport.Application, []},
      extra_applications: [
        :logger,
        :unidecode,
        :phoenix_ecto,
        # for memsup memory tracking
        :sasl,
        :os_mon
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # see https://github.com/etalab/transport-site/issues/2520
  defp apple_silicon? do
    :system_architecture
    |> :erlang.system_info()
    |> List.to_string()
    |> String.starts_with?("aarch64-apple-darwin")
  end

  defp deps do
    [
      {:csv, "~> 3.0"},
      {:earmark, "~> 1.4"},
      {:gettext, "~> 0.11"},
      {:httpoison, "~> 2.1"},
      {:phoenix, "~> 1.6.2"},
      {:phoenix_html, "~> 3.1"},
      {:phoenix_markdown, "~> 1.0"},
      {:phoenix_live_view, "~> 0.18.0"},
      {:html_sanitize_ex, "~> 1.4"},
      {:floki, ">= 0.0.0", only: :test},
      {:plug_cowboy, "~> 2.3"},
      {:recon, "~> 2.4"},
      {:quantum, "~> 3.4"},
      {:timex, "~> 3.7"},
      {:sentry, "~> 8.0"},
      {:scrivener, "~> 2.5"},
      {:scrivener_html, git: "https://github.com/mgwidmann/scrivener_html.git", ref: "9224d1"},
      {:scrivener_list, "~>2.0"},
      {:jason, "~> 1.1"},
      {:open_api_spex, "~> 3.8"},
      {:gbfs, in_umbrella: true},
      {:datagouvfr, in_umbrella: true},
      {:shared, in_umbrella: true},
      {:unlock, in_umbrella: true},
      {:castore, "~> 1.0"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:cors_plug, "~> 3.0"},
      {:exvcr, "~> 0.13", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_aws, "~> 2.1"},
      {:ex_aws_s3, "~> 2.0"},
      {:unidecode, "~> 1.0.0"},
      {:phoenix_ecto, "~> 4.0"},
      {:sizeable, "~> 1.0"},
      {:plug_canonical_host, "~> 2.0"},
      {:mox, "~> 1.0.0", only: :test},
      # temporary fix until https://github.com/jayjun/rambo/pull/13 is merged
      # see https://github.com/etalab/transport-site/issues/2520.
      # Not perfect since this will impact `mix.lock`
      if apple_silicon?() do
        # branch is "aarch64-apple" but we're hardcoding the ref for security, especially since `mix.lock`
        # must not be committed in that case.
        # NOTE: this is not enough, and a manual `mix compile.rambo` must be issued manually in order
        # for this to work (https://github.com/jayjun/rambo/pull/13#issuecomment-1189194040).
        {:rambo, "~> 0.3.4",
         github: "myobie/rambo", ref: "e321db8e4f035f2a295ee2a5310dcb75034677ce"}
      else
        {:rambo, "~> 0.3.4"}
      end,
      {:etag_plug, "~> 1.0"},
      {:oban, "~> 2.13"},
      {:unzip, "~> 0.8"},
      {:protobuf, "~> 0.11.0"},
      {:nimble_csv, "~> 1.2.0"},
      {:kino, "~> 0.6", only: :dev},
      # db
      {:ecto, "~> 3.7"},
      {:ecto_sql, "~> 3.7"},
      {:postgrex, ">= 0.0.0"},
      {:geo_postgis, "~> 3.4"},
      {:ecto_interval, "~> 0.2.5"},
      {:scrivener_ecto, "~> 2.7.0"},
      {:typed_ecto_schema, ">= 0.1.1"},
      {:ymlr, "~> 3.0"},
      {:ex_machina, "~> 2.4", only: :test},
      {:cloak_ecto, "~> 1.2.0"},
      {:phoenix_live_dashboard, "~> 0.7"},
      {:ecto_psql_extras, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},
      {:telemetry_metrics, "~> 0.4"},
      {:luhn, "~> 0.3.0"},
      {:ex_phone_number, "~> 0.3"},
      {:appsignal, "~> 2.0"},
      {:appsignal_phoenix, "~> 2.0"},
      {:vega_lite, "~> 0.1.7"}
    ]
  end
end
