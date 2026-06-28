defmodule ExOpenzl.MixProject do
  use Mix.Project

  @version "0.4.15"
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
      make_precompiler_nif_versions: [versions: ["2.16", "2.17", "2.18"]],
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
        c_src/openzl/CMakeLists.txt
        c_src/openzl/build-scripts/cmake
        c_src/openzl/include
        c_src/openzl/src
        c_src/openzl/cpp/CMakeLists.txt
        c_src/openzl/cpp/include
        c_src/openzl/cpp/src
        c_src/openzl/cpp/tests/CMakeLists.txt
        c_src/openzl/tools/CMakeLists.txt
        c_src/openzl/tools/arg/CMakeLists.txt
        c_src/openzl/tools/fileio/CMakeLists.txt
        c_src/openzl/tools/io/CMakeLists.txt
        c_src/openzl/tools/logger/CMakeLists.txt
        c_src/openzl/tools/ml_selector/CMakeLists.txt
        c_src/openzl/tools/parquet/CMakeLists.txt
        c_src/openzl/tools/protobuf/CMakeLists.txt
        c_src/openzl/tools/sddl/CMakeLists.txt
        c_src/openzl/tools/sddl/compiler
        c_src/openzl/tools/sddl2/CMakeLists.txt
        c_src/openzl/tools/streamdump/CMakeLists.txt
        c_src/openzl/tools/time/CMakeLists.txt
        c_src/openzl/tools/training/CMakeLists.txt
        c_src/openzl/custom_parsers/sddl
        c_src/openzl/custom_parsers/shared_components
        c_src/openzl/deps/zstd/build/cmake
        c_src/openzl/deps/zstd/lib
        c_src/openzl/deps/lz4/build/cmake
        c_src/openzl/deps/lz4/lib
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
