defmodule ExOpenzl.MixProject do
  use Mix.Project

  @version "0.4.0"
  @source_url "https://github.com/awksedgreep/ex_openzl"

  def project do
    [
      app: :ex_openzl,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_env: fn -> %{"FINE_INCLUDE_DIR" => Fine.include_dir()} end,
      make_precompiler: {:nif, CCPrecompiler},
      make_precompiler_url:
        "https://github.com/awksedgreep/ex_openzl/releases/download/v#{@version}/@{artefact_filename}",
      make_precompiler_filename: "ex_openzl_nif",
      make_precompiler_priv_paths: ["ex_openzl_nif.*"],
      make_precompiler_nif_versions: [versions: ["2.16", "2.17"]],
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:elixir_make, "~> 0.9", runtime: false},
      {:cc_precompiler, "~> 0.1", runtime: false},
      {:fine, "~> 0.1.0", runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Elixir NIF bindings for OpenZL, Meta's format-aware compression framework. " <>
      "Extends zstd with typed columnar compression (delta coding, entropy coding) " <>
      "and SDDL format-aware compression graphs."
  end

  defp package do
    [
      maintainers: ["Mark Cotner"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(
        lib
        c_src/ex_openzl_nif.cpp
        Makefile
        mix.exs
        checksum.exs
        README.md
        LICENSE
        .formatter.exs
      )
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE"],
      source_ref: "v#{@version}"
    ]
  end
end
