#!/usr/bin/env elixir
# Quick benchmark for ExOpenzl compression operations

defmodule Bench do
  def run(label, fun, iterations \\ 1000) do
    # Warmup
    for _ <- 1..min(iterations, 100), do: fun.()

    times =
      for _ <- 1..iterations do
        {us, _result} = :timer.tc(fun)
        us
      end

    avg = Enum.sum(times) / length(times)
    sorted = Enum.sort(times)
    p50 = Enum.at(sorted, div(length(sorted), 2))
    p99 = Enum.at(sorted, trunc(length(sorted) * 0.99))
    min_t = List.first(sorted)
    max_t = List.last(sorted)

    IO.puts(
      "#{String.pad_trailing(label, 45)} " <>
        "avg=#{pad(avg)}us  p50=#{pad(p50)}us  p99=#{pad(p99)}us  " <>
        "min=#{pad(min_t)}us  max=#{pad(max_t)}us"
    )
  end

  defp pad(val) when is_float(val), do: :erlang.float_to_binary(val, decimals: 1) |> String.pad_leading(10)
  defp pad(val), do: Integer.to_string(val) |> String.pad_leading(10)
end

IO.puts("ExOpenzl Benchmark")
IO.puts("==================")
IO.puts("OpenZL version: #{ExOpenzl.version()}")
IO.puts("")

# ── Data generation ──

small_text = "Hello, OpenZL! This is a test of format-aware compression."
medium_text = String.duplicate("The quick brown fox jumps over the lazy dog. ", 100)
large_text = String.duplicate("The quick brown fox jumps over the lazy dog. ", 10_000)

timestamps_1k =
  for i <- 1..1_000, into: <<>> do
    <<1_700_000_000 + i::little-unsigned-64>>
  end

timestamps_10k =
  for i <- 1..10_000, into: <<>> do
    <<1_700_000_000 + i::little-unsigned-64>>
  end

u32_data =
  for i <- 1..5_000, into: <<>> do
    <<i * 100::little-unsigned-32>>
  end

struct_data =
  for i <- 1..1_000, into: <<>> do
    <<1_700_000_000 + i::little-unsigned-64, i * 10::little-unsigned-32>>
  end

strings = for i <- 1..200, do: "log message number #{i} with some payload data"
string_concat = Enum.join(strings)
string_lengths = for s <- strings, into: <<>>, do: <<byte_size(s)::native-unsigned-32>>

sddl_source = "Row = {\nUInt64LE\nUInt8\n}\n: Row[_rem / 9]\n"
sddl_records =
  for i <- 1..1_000, into: <<>> do
    <<1_700_000_000 + i::little-unsigned-64, rem(i, 5)::unsigned-8>>
  end

# ── Pre-compress for decompress benchmarks ──

{:ok, small_compressed} = ExOpenzl.compress(small_text)
{:ok, medium_compressed} = ExOpenzl.compress(medium_text)
{:ok, large_compressed} = ExOpenzl.compress(large_text)

{:ok, cctx_pre} = ExOpenzl.create_compression_context()
{:ok, ts1k_compressed} = ExOpenzl.compress_typed(cctx_pre, {:numeric, timestamps_1k, 8})
{:ok, ts10k_compressed} = ExOpenzl.compress_typed(cctx_pre, {:numeric, timestamps_10k, 8})

{:ok, compiled_sddl} = ExOpenzl.sddl_compile(sddl_source)
{:ok, compressor} = ExOpenzl.create_sddl_compressor(compiled_sddl)
{:ok, sddl_cctx} = ExOpenzl.create_compression_context()
:ok = ExOpenzl.set_compressor(sddl_cctx, compressor)
{:ok, sddl_compressed} = ExOpenzl.compress(sddl_cctx, sddl_records)

# ── Benchmarks ──

IO.puts("── Plain Compression ──")
Bench.run("compress small (#{byte_size(small_text)} B)", fn -> ExOpenzl.compress(small_text) end)
Bench.run("compress medium (#{byte_size(medium_text)} B)", fn -> ExOpenzl.compress(medium_text) end)
Bench.run("compress large (#{byte_size(large_text)} B)", fn -> ExOpenzl.compress(large_text) end)

IO.puts("")
IO.puts("── Plain Decompression ──")
Bench.run("decompress small (#{byte_size(small_compressed)} B)", fn -> ExOpenzl.decompress(small_compressed) end)
Bench.run("decompress medium (#{byte_size(medium_compressed)} B)", fn -> ExOpenzl.decompress(medium_compressed) end)
Bench.run("decompress large (#{byte_size(large_compressed)} B)", fn -> ExOpenzl.decompress(large_compressed) end)

IO.puts("")
IO.puts("── Context-based Compression ──")
{:ok, cctx} = ExOpenzl.create_compression_context()
{:ok, dctx} = ExOpenzl.create_decompression_context()
Bench.run("ctx compress medium", fn -> ExOpenzl.compress(cctx, medium_text) end)
Bench.run("ctx decompress medium", fn -> ExOpenzl.decompress(dctx, medium_compressed) end)

IO.puts("")
IO.puts("── Compression Levels ──")
for level <- [1, 6, 12, 19] do
  {:ok, c} = ExOpenzl.create_compression_context()
  :ok = ExOpenzl.set_compression_level(c, level)
  Bench.run("compress level #{level} (#{byte_size(large_text)} B)", fn ->
    ExOpenzl.compress(c, large_text)
  end, 200)
end

IO.puts("")
IO.puts("── Typed Compression (Numeric) ──")
{:ok, tc} = ExOpenzl.create_compression_context()
{:ok, td} = ExOpenzl.create_decompression_context()
Bench.run("typed numeric u64 1K elements (#{byte_size(timestamps_1k)} B)", fn ->
  ExOpenzl.compress_typed(tc, {:numeric, timestamps_1k, 8})
end)
Bench.run("typed numeric u64 10K elements (#{byte_size(timestamps_10k)} B)", fn ->
  ExOpenzl.compress_typed(tc, {:numeric, timestamps_10k, 8})
end)
Bench.run("typed numeric u32 5K elements (#{byte_size(u32_data)} B)", fn ->
  ExOpenzl.compress_typed(tc, {:numeric, u32_data, 4})
end)
Bench.run("typed decompress u64 1K", fn ->
  ExOpenzl.decompress_typed(td, ts1k_compressed)
end)
Bench.run("typed decompress u64 10K", fn ->
  ExOpenzl.decompress_typed(td, ts10k_compressed)
end)

IO.puts("")
IO.puts("── Typed Compression (Struct) ──")
Bench.run("typed struct 12B x 1K (#{byte_size(struct_data)} B)", fn ->
  ExOpenzl.compress_typed(tc, {:struct, struct_data, 12})
end)

IO.puts("")
IO.puts("── Typed Compression (String) ──")
Bench.run("typed string 200 msgs (#{byte_size(string_concat)} B)", fn ->
  ExOpenzl.compress_typed(tc, {:string, string_concat, string_lengths})
end)

IO.puts("")
IO.puts("── Multi-Typed Compression ──")
inputs = [
  {:numeric, timestamps_1k, 8},
  {:struct, struct_data, 12},
  {:string, string_concat, string_lengths}
]
Bench.run("multi-typed 3 inputs", fn ->
  ExOpenzl.compress_multi_typed(tc, inputs)
end)

IO.puts("")
IO.puts("── SDDL Pipeline ──")
Bench.run("sddl compile", fn -> ExOpenzl.sddl_compile(sddl_source) end, 500)
Bench.run("sddl compress 1K records (#{byte_size(sddl_records)} B)", fn ->
  {:ok, c} = ExOpenzl.create_compression_context()
  :ok = ExOpenzl.set_compressor(c, compressor)
  ExOpenzl.compress(c, sddl_records)
end, 500)
Bench.run("sddl decompress 1K records", fn ->
  {:ok, d} = ExOpenzl.create_decompression_context()
  ExOpenzl.decompress(d, sddl_compressed)
end, 500)

IO.puts("")
IO.puts("── Compression Ratios ──")
for {label, original, compressed} <- [
  {"small text", small_text, small_compressed},
  {"medium text", medium_text, medium_compressed},
  {"large text", large_text, large_compressed}
] do
  ratio = byte_size(compressed) / byte_size(original) * 100
  IO.puts("  #{String.pad_trailing(label, 20)} #{byte_size(original)} -> #{byte_size(compressed)} bytes (#{:erlang.float_to_binary(ratio, decimals: 1)}%)")
end

{:ok, ts1k_c} = ExOpenzl.compress_typed(cctx_pre, {:numeric, timestamps_1k, 8})
{:ok, ts10k_c} = ExOpenzl.compress_typed(cctx_pre, {:numeric, timestamps_10k, 8})
{:ok, plain_ts10k} = ExOpenzl.compress(timestamps_10k)

for {label, original_size, compressed} <- [
  {"typed u64 1K", byte_size(timestamps_1k), ts1k_c},
  {"typed u64 10K", byte_size(timestamps_10k), ts10k_c},
  {"plain u64 10K (compare)", byte_size(timestamps_10k), plain_ts10k},
  {"SDDL 1K records", byte_size(sddl_records), sddl_compressed}
] do
  ratio = byte_size(compressed) / original_size * 100
  IO.puts("  #{String.pad_trailing(label, 20)} #{original_size} -> #{byte_size(compressed)} bytes (#{:erlang.float_to_binary(ratio, decimals: 1)}%)")
end

{:ok, plain_sddl} = ExOpenzl.compress(sddl_records)
ratio_sddl = byte_size(sddl_compressed) / byte_size(sddl_records) * 100
ratio_plain = byte_size(plain_sddl) / byte_size(sddl_records) * 100
IO.puts("  SDDL vs plain:       SDDL=#{:erlang.float_to_binary(ratio_sddl, decimals: 1)}%  plain=#{:erlang.float_to_binary(ratio_plain, decimals: 1)}%")
