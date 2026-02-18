# ExOpenzl

Elixir NIF bindings for [OpenZL](https://github.com/facebook/openzl), Meta's format-aware compression framework.

OpenZL extends zstd with typed and columnar compression, enabling significantly better ratios on structured data like timestamps, enums, and variable-length strings. It also includes SDDL (Structured Data Description Language) for defining custom format-aware compression graphs.

## Features

- **One-shot compression** — compress/decompress binaries with a single call
- **Reusable contexts** — amortize allocation cost across many operations
- **Configurable compression levels** — levels 1-19 (same as zstd)
- **Typed compression** — numeric, struct, and string-aware encoding
  - Numeric: delta coding for monotonic sequences (timestamps, counters)
  - Struct: fixed-width record encoding
  - String: variable-length with packed length arrays
- **Multi-typed frames** — pack multiple typed columns into a single compressed frame
- **Frame introspection** — query metadata without decompressing
- **SDDL compressor** — compile and apply format-aware compression graphs

## Prerequisites

- Erlang/OTP 26+
- Elixir 1.19+
- CMake 3.14+
- C++17 compiler (clang or gcc)
- Git (for fetching the OpenZL submodule)

## Installation

Add `ex_openzl` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_openzl, "~> 0.4"}
  ]
end
```

The NIF is compiled automatically via `elixir_make`. The first build will compile the OpenZL C library from source (takes ~1 minute).

### Precompiled binaries

Precompiled NIF binaries are available for the following targets:

- `x86_64-linux-gnu`
- `aarch64-linux-gnu`
- `x86_64-apple-darwin`
- `aarch64-apple-darwin`

If a precompiled binary is available for your platform, `mix compile` will download it automatically — no C++ toolchain required.

## Usage

### Basic compression

```elixir
data = "hello world, this is a test of OpenZL compression"

{:ok, compressed} = ExOpenzl.compress(data)
{:ok, ^data} = ExOpenzl.decompress(compressed)
```

### Reusable contexts

```elixir
{:ok, cctx} = ExOpenzl.create_compression_context()
:ok = ExOpenzl.set_compression_level(cctx, 9)

{:ok, compressed} = ExOpenzl.compress(cctx, data)

{:ok, dctx} = ExOpenzl.create_decompression_context()
{:ok, ^data} = ExOpenzl.decompress(dctx, compressed)
```

### Typed columnar compression

Pack structured data into typed columns for better compression ratios:

```elixir
{:ok, cctx} = ExOpenzl.create_compression_context()

# Timestamps: packed u64 little-endian (delta coding)
timestamps = <<1000::little-64, 1001::little-64, 1002::little-64>>

# Levels: u8 enum values (entropy coding)
levels = <<0, 1, 1>>

# Messages: concatenated strings + packed u32 lengths
messages = "helloworld!!"
msg_lengths = <<5::little-32, 5::little-32, 2::little-32>>

{:ok, compressed} = ExOpenzl.compress_multi_typed(cctx, [
  {:numeric, timestamps, 8},
  {:numeric, levels, 1},
  {:string, messages, msg_lengths}
])

# Decompress
{:ok, dctx} = ExOpenzl.create_decompression_context()
{:ok, [ts_info, lv_info, msg_info]} = ExOpenzl.decompress_multi_typed(dctx, compressed)
```

### Frame introspection

```elixir
{:ok, info} = ExOpenzl.frame_info(compressed)
# => %{format_version: 1, num_outputs: 3, outputs: [...]}
```

### SDDL format-aware compression

```elixir
{:ok, compiled} = ExOpenzl.sddl_compile("u32 timestamp; u8 level;")
{:ok, compressor} = ExOpenzl.create_sddl_compressor(compiled)

{:ok, cctx} = ExOpenzl.create_compression_context()
:ok = ExOpenzl.set_compressor(cctx, compressor)

# Now compress/2 uses the format-aware graph
{:ok, compressed} = ExOpenzl.compress(cctx, data)
```

## Thread safety

Compression and decompression contexts are **not** thread-safe. Each context should be used by a single Erlang/Elixir process at a time. If you need to compress or decompress from multiple concurrent processes, create a separate context per process.

## Hardware acceleration

On x86-64, OpenZL uses BMI2 assembly for Huffman coding, SSE2/AVX2 SIMD for match finding, and BMI2 intrinsics for varint encoding. On other architectures (including Apple Silicon), it falls back to portable C.

## License

MIT - see [LICENSE](LICENSE).

OpenZL itself is licensed under the [BSD License](https://github.com/facebook/openzl/blob/main/LICENSE) by Meta Platforms, Inc.
