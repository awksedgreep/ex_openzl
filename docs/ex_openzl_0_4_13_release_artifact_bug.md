# ex_openzl 0.4.13 Release Artifact Regression

## Summary

`ex_openzl` `0.4.13` fails to install in downstream Docker builds on
`linux/amd64` with NIF version `2.17`.

The precompiled artifact downloads, but `cc_precompiler` cannot decompress it
because the archive checksum is invalid. The fallback source build then fails
because the Hex package does not include the vendored OpenZL source tree that
the Makefile requires.

This broke the `timeless_stack` container release after dependency resolution
selected `ex_openzl 0.4.13`.

## Environment

- Downstream app: `timeless_stack`
- Downstream image: `hexpm/elixir:1.18.3-erlang-27.3.4-debian-bookworm-20250428`
- Build command: `mix deps.compile`
- Mix environment: `MIX_ENV=prod`
- Platform: `linux/amd64`
- NIF version: `2.17`
- `ex_openzl`: `0.4.13`

## Reproduction

In `timeless_stack`, with `ex_openzl` resolving to `0.4.13`, run:

```sh
docker build -f timeless_stack/Dockerfile -t timeless-stack:ci-check .
```

The same failure was observed in GitHub Actions while building tag `v0.6.3`.

## Actual Failure

The precompiled artifact is found but cannot be unpacked:

```text
Downloading precompiled NIF to /root/.cache/elixir_make/ex_openzl-nif-2.17-x86_64-linux-gnu-0.4.13.tar.gz
Error happened while installing ex_openzl from precompiled binary:
"cannot decompress precompiled \"/root/.cache/elixir_make/ex_openzl-nif-2.17-x86_64-linux-gnu-0.4.13.tar.gz\": :invalid_tar_checksum".
```

`cc_precompiler` then falls back to building from source. That also fails:

```text
Attempting to compile ex_openzl from source...
cmake ... -S c_src/openzl -B c_src/openzl/build
CMake Error: The source directory "/build/timeless_stack/deps/ex_openzl/c_src/openzl" does not exist.
make: *** [Makefile:113: c_src/openzl/build/libopenzl.a] Error 1
could not compile dependency :ex_openzl, "mix compile" failed.
```

## Suspected Causes

There appear to be two separate release issues:

1. The `0.4.13` GitHub release artifact
   `ex_openzl-nif-2.17-x86_64-linux-gnu-0.4.13.tar.gz` is not a valid tarball,
   or its published checksum does not match the uploaded artifact.
2. The Hex package cannot build from source because `mix.exs` only packages
   `c_src/ex_openzl_nif.cpp`, while `Makefile` requires the full
   `c_src/openzl` tree:

```elixir
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
```

```make
OPENZL_DIR = c_src/openzl
```

## Expected Behavior

Downstream projects should be able to install `ex_openzl 0.4.13` by either:

1. downloading and decompressing the matching precompiled NIF artifact, or
2. compiling from source from the Hex package when the precompiled artifact is
   unavailable or invalid.

## Suggested Fix

Publish a new patch release that:

1. regenerates and uploads valid precompiled artifacts for all configured NIF
   versions and targets,
2. updates `checksum.exs` from the final uploaded artifacts, and
3. either includes `c_src/openzl` in the Hex package or disables source fallback
   with a clear error if the package intentionally requires precompiled NIFs.

`0.4.11` avoids the invalid `0.4.13` archive, but it still fails in the same
Docker build because its precompiled artifact is unavailable for the tested
target and the Hex source fallback is missing `c_src/openzl`. Downstream
`timeless_stack` needs a fixed `ex_openzl` release before its container CI can
pass from Hex dependencies alone.

`0.4.14` generated GitHub release artifacts, but Hex publishing failed because
the package included the entire upstream OpenZL checkout and exceeded Hex
tarball metadata limits. The follow-up package should include only the source
paths needed by the NIF fallback build.
