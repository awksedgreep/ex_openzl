defmodule ExOpenzlTest do
  use ExUnit.Case

  describe "version/0" do
    test "returns a version string" do
      version = ExOpenzl.version()
      assert is_binary(version)
      assert version =~ ~r/^\d+\.\d+\.\d+$/
    end
  end

  describe "compress/1 and decompress/1" do
    test "roundtrips binary data" do
      original = "Hello, OpenZL! This is a test of format-aware compression."
      assert {:ok, compressed} = ExOpenzl.compress(original)
      assert is_binary(compressed)
      assert {:ok, ^original} = ExOpenzl.decompress(compressed)
    end

    test "roundtrips larger data" do
      original = String.duplicate("The quick brown fox jumps over the lazy dog. ", 1000)
      assert {:ok, compressed} = ExOpenzl.compress(original)
      assert byte_size(compressed) < byte_size(original)
      assert {:ok, ^original} = ExOpenzl.decompress(compressed)
    end

    test "returns error for empty input on compress" do
      assert {:error, _reason} = ExOpenzl.compress(<<>>)
    end

    test "returns error for empty input on decompress" do
      assert {:error, _reason} = ExOpenzl.decompress(<<>>)
    end

    test "returns error for invalid compressed data" do
      assert {:error, _reason} = ExOpenzl.decompress("not valid compressed data")
    end
  end

  describe "context-based compression" do
    test "roundtrips with reusable contexts" do
      cctx = ExOpenzl.create_compression_context()
      dctx = ExOpenzl.create_decompression_context()

      assert is_reference(cctx)
      assert is_reference(dctx)

      original = "Context-based compression test data"
      assert {:ok, compressed} = ExOpenzl.compress(cctx, original)
      assert {:ok, ^original} = ExOpenzl.decompress(dctx, compressed)
    end

    test "context can be reused across multiple calls" do
      cctx = ExOpenzl.create_compression_context()
      dctx = ExOpenzl.create_decompression_context()

      for i <- 1..10 do
        original = "Message number #{i}: #{String.duplicate("x", i * 100)}"
        assert {:ok, compressed} = ExOpenzl.compress(cctx, original)
        assert {:ok, ^original} = ExOpenzl.decompress(dctx, compressed)
      end
    end
  end

  describe "compress_bound/1" do
    test "returns a value larger than input size" do
      bound = ExOpenzl.compress_bound(1000)
      assert is_integer(bound)
      assert bound >= 1000
    end

    test "returns a value for zero" do
      bound = ExOpenzl.compress_bound(0)
      assert is_integer(bound)
      assert bound >= 0
    end
  end

  # ===========================================================================
  # Phase 1: Compression Level
  # ===========================================================================

  describe "set_compression_level/2" do
    test "sets compression level and compresses successfully" do
      cctx = ExOpenzl.create_compression_context()
      dctx = ExOpenzl.create_decompression_context()

      assert :ok = ExOpenzl.set_compression_level(cctx, 9)

      original = String.duplicate("Compression level test data. ", 500)
      assert {:ok, compressed} = ExOpenzl.compress(cctx, original)
      assert {:ok, ^original} = ExOpenzl.decompress(dctx, compressed)
    end

    test "higher levels produce smaller output" do
      data = String.duplicate("Repeated data for compression level comparison. ", 1000)

      cctx_low = ExOpenzl.create_compression_context()
      assert :ok = ExOpenzl.set_compression_level(cctx_low, 1)
      assert {:ok, compressed_low} = ExOpenzl.compress(cctx_low, data)

      cctx_high = ExOpenzl.create_compression_context()
      assert :ok = ExOpenzl.set_compression_level(cctx_high, 19)
      assert {:ok, compressed_high} = ExOpenzl.compress(cctx_high, data)

      assert byte_size(compressed_high) <= byte_size(compressed_low)
    end

    test "roundtrips at different levels" do
      dctx = ExOpenzl.create_decompression_context()
      original = String.duplicate("Level test ", 200)

      for level <- [1, 3, 6, 9, 12] do
        cctx = ExOpenzl.create_compression_context()
        assert :ok = ExOpenzl.set_compression_level(cctx, level)
        assert {:ok, compressed} = ExOpenzl.compress(cctx, original)
        assert {:ok, ^original} = ExOpenzl.decompress(dctx, compressed)
      end
    end
  end

  # ===========================================================================
  # Phase 2: Typed Compression
  # ===========================================================================

  describe "compress_typed/2 - numeric" do
    test "roundtrips u64 numeric data" do
      cctx = ExOpenzl.create_compression_context()
      dctx = ExOpenzl.create_decompression_context()

      # 100 u64 timestamps (little-endian)
      timestamps =
        for i <- 1..100, into: <<>> do
          <<1_700_000_000 + i::little-unsigned-64>>
        end

      assert {:ok, compressed} = ExOpenzl.compress_typed(cctx, {:numeric, timestamps, 8})
      assert {:ok, info} = ExOpenzl.decompress_typed(dctx, compressed)
      assert info.type == :numeric
      assert info.data == timestamps
      assert info.element_width == 8
      assert info.num_elements == 100
    end

    test "roundtrips u8 numeric data" do
      cctx = ExOpenzl.create_compression_context()
      dctx = ExOpenzl.create_decompression_context()

      data = :binary.copy(<<0, 1, 2, 3, 4, 5, 6, 7>>, 50)

      assert {:ok, compressed} = ExOpenzl.compress_typed(cctx, {:numeric, data, 1})
      assert {:ok, info} = ExOpenzl.decompress_typed(dctx, compressed)
      assert info.type == :numeric
      assert info.data == data
      assert info.element_width == 1
      assert info.num_elements == 400
    end

    test "roundtrips u16 numeric data" do
      cctx = ExOpenzl.create_compression_context()
      dctx = ExOpenzl.create_decompression_context()

      data =
        for i <- 1..200, into: <<>> do
          <<i::little-unsigned-16>>
        end

      assert {:ok, compressed} = ExOpenzl.compress_typed(cctx, {:numeric, data, 2})
      assert {:ok, info} = ExOpenzl.decompress_typed(dctx, compressed)
      assert info.type == :numeric
      assert info.data == data
      assert info.element_width == 2
      assert info.num_elements == 200
    end

    test "roundtrips u32 numeric data" do
      cctx = ExOpenzl.create_compression_context()
      dctx = ExOpenzl.create_decompression_context()

      data =
        for i <- 1..150, into: <<>> do
          <<i * 1000::little-unsigned-32>>
        end

      assert {:ok, compressed} = ExOpenzl.compress_typed(cctx, {:numeric, data, 4})
      assert {:ok, info} = ExOpenzl.decompress_typed(dctx, compressed)
      assert info.type == :numeric
      assert info.data == data
      assert info.element_width == 4
      assert info.num_elements == 150
    end

    test "returns error for invalid element_width" do
      cctx = ExOpenzl.create_compression_context()
      data = :binary.copy(<<0, 1, 2>>, 10)

      assert {:error, _reason} = ExOpenzl.compress_typed(cctx, {:numeric, data, 3})
      assert {:error, _reason} = ExOpenzl.compress_typed(cctx, {:numeric, data, 5})
      assert {:error, _reason} = ExOpenzl.compress_typed(cctx, {:numeric, data, 7})
    end

    test "returns error for misaligned data" do
      cctx = ExOpenzl.create_compression_context()
      # 7 bytes is not a multiple of 4
      data = <<1, 2, 3, 4, 5, 6, 7>>
      assert {:error, _reason} = ExOpenzl.compress_typed(cctx, {:numeric, data, 4})
    end

    test "returns error for empty data" do
      cctx = ExOpenzl.create_compression_context()
      assert {:error, _reason} = ExOpenzl.compress_typed(cctx, {:numeric, <<>>, 8})
    end

    test "roundtrips large numeric dataset" do
      cctx = ExOpenzl.create_compression_context()
      dctx = ExOpenzl.create_decompression_context()

      # 10,000 u64 values - monotonically increasing (highly compressible)
      data =
        for i <- 1..10_000, into: <<>> do
          <<1_700_000_000_000 + i::little-unsigned-64>>
        end

      assert {:ok, compressed} = ExOpenzl.compress_typed(cctx, {:numeric, data, 8})
      assert byte_size(compressed) < byte_size(data)
      assert {:ok, info} = ExOpenzl.decompress_typed(dctx, compressed)
      assert info.data == data
      assert info.num_elements == 10_000
    end
  end

  describe "compress_typed/2 - struct" do
    test "roundtrips fixed-width struct data" do
      cctx = ExOpenzl.create_compression_context()
      dctx = ExOpenzl.create_decompression_context()

      # 100 records, 12 bytes each (u64 timestamp + u32 value)
      records =
        for i <- 1..100, into: <<>> do
          <<1_700_000_000 + i::little-unsigned-64, i * 10::little-unsigned-32>>
        end

      assert {:ok, compressed} = ExOpenzl.compress_typed(cctx, {:struct, records, 12})
      assert {:ok, info} = ExOpenzl.decompress_typed(dctx, compressed)
      assert info.type == :struct
      assert info.data == records
      assert info.element_width == 12
      assert info.num_elements == 100
    end

    test "returns error for misaligned struct data" do
      cctx = ExOpenzl.create_compression_context()
      # 10 bytes is not a multiple of struct_width=3
      data = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>
      assert {:error, _reason} = ExOpenzl.compress_typed(cctx, {:struct, data, 3})
    end

    test "returns error for zero struct_width" do
      cctx = ExOpenzl.create_compression_context()
      assert {:error, _reason} = ExOpenzl.compress_typed(cctx, {:struct, <<1, 2, 3>>, 0})
    end

    test "returns error for empty struct data" do
      cctx = ExOpenzl.create_compression_context()
      assert {:error, _reason} = ExOpenzl.compress_typed(cctx, {:struct, <<>>, 4})
    end
  end

  describe "compress_typed/2 - string" do
    test "roundtrips variable-length string data" do
      cctx = ExOpenzl.create_compression_context()
      dctx = ExOpenzl.create_decompression_context()

      strings = ["hello", "world", "foo", "bar baz"]
      concat = Enum.join(strings)

      lengths_bin =
        for s <- strings, into: <<>> do
          <<String.length(s)::native-unsigned-32>>
        end

      assert {:ok, compressed} = ExOpenzl.compress_typed(cctx, {:string, concat, lengths_bin})
      assert {:ok, info} = ExOpenzl.decompress_typed(dctx, compressed)
      assert info.type == :string
      assert info.data == concat
      assert info.num_elements == 4
      assert is_binary(info.string_lengths)
    end

    test "string lengths roundtrip with correct values" do
      cctx = ExOpenzl.create_compression_context()
      dctx = ExOpenzl.create_decompression_context()

      strings = ["alpha", "beta", "gamma", "delta", "epsilon"]
      concat = Enum.join(strings)
      expected_lengths = Enum.map(strings, &byte_size/1)

      lengths_bin =
        for len <- expected_lengths, into: <<>> do
          <<len::native-unsigned-32>>
        end

      assert {:ok, compressed} = ExOpenzl.compress_typed(cctx, {:string, concat, lengths_bin})
      assert {:ok, info} = ExOpenzl.decompress_typed(dctx, compressed)

      # Verify we can reconstruct the original strings from data + lengths
      decoded_lengths =
        for <<len::native-unsigned-32 <- info.string_lengths>>, do: len

      assert decoded_lengths == expected_lengths

      # Reconstruct strings from concatenated data and lengths
      {reconstructed, _} =
        Enum.map_reduce(decoded_lengths, info.data, fn len, rest ->
          <<chunk::binary-size(len), remaining::binary>> = rest
          {chunk, remaining}
        end)

      assert reconstructed == strings
    end

    test "roundtrips many short strings" do
      cctx = ExOpenzl.create_compression_context()
      dctx = ExOpenzl.create_decompression_context()

      strings = for i <- 1..500, do: "msg#{i}"
      concat = Enum.join(strings)

      lengths_bin =
        for s <- strings, into: <<>> do
          <<byte_size(s)::native-unsigned-32>>
        end

      assert {:ok, compressed} = ExOpenzl.compress_typed(cctx, {:string, concat, lengths_bin})
      assert {:ok, info} = ExOpenzl.decompress_typed(dctx, compressed)
      assert info.data == concat
      assert info.num_elements == 500
    end

    test "returns error for empty string data" do
      cctx = ExOpenzl.create_compression_context()
      assert {:error, _reason} = ExOpenzl.compress_typed(cctx, {:string, <<>>, <<4::native-unsigned-32>>})
    end

    test "returns error for misaligned lengths binary" do
      cctx = ExOpenzl.create_compression_context()
      # 3 bytes is not a multiple of 4
      assert {:error, _reason} = ExOpenzl.compress_typed(cctx, {:string, "hello", <<1, 2, 3>>})
    end
  end

  describe "compress_multi_typed/2 and decompress_multi_typed/2" do
    test "roundtrips multiple typed inputs in one frame" do
      cctx = ExOpenzl.create_compression_context()
      dctx = ExOpenzl.create_decompression_context()

      # Timestamps (u64)
      timestamps =
        for i <- 1..50, into: <<>> do
          <<1_700_000_000 + i::little-unsigned-64>>
        end

      # Log levels (u8)
      levels = :binary.copy(<<0, 1, 2, 3, 4>>, 10)

      inputs = [
        {:numeric, timestamps, 8},
        {:numeric, levels, 1}
      ]

      assert {:ok, compressed} = ExOpenzl.compress_multi_typed(cctx, inputs)
      assert {:ok, outputs} = ExOpenzl.decompress_multi_typed(dctx, compressed)
      assert length(outputs) == 2

      [ts_out, lv_out] = outputs
      assert ts_out.type == :numeric
      assert ts_out.data == timestamps
      assert ts_out.element_width == 8
      assert lv_out.type == :numeric
      assert lv_out.data == levels
      assert lv_out.element_width == 1
    end

    test "roundtrips mixed types: numeric + struct + string" do
      cctx = ExOpenzl.create_compression_context()
      dctx = ExOpenzl.create_decompression_context()

      # Timestamps (u64 numeric)
      timestamps =
        for i <- 1..50, into: <<>> do
          <<1_700_000_000 + i::little-unsigned-64>>
        end

      # Fixed-width records (struct: u32 pid + u32 tid = 8 bytes)
      structs =
        for i <- 1..50, into: <<>> do
          <<i::little-unsigned-32, i + 100::little-unsigned-32>>
        end

      # Log messages (string)
      strings = for i <- 1..50, do: "log message #{i}"
      concat = Enum.join(strings)

      lengths_bin =
        for s <- strings, into: <<>> do
          <<byte_size(s)::native-unsigned-32>>
        end

      inputs = [
        {:numeric, timestamps, 8},
        {:struct, structs, 8},
        {:string, concat, lengths_bin}
      ]

      assert {:ok, compressed} = ExOpenzl.compress_multi_typed(cctx, inputs)
      assert {:ok, outputs} = ExOpenzl.decompress_multi_typed(dctx, compressed)
      assert length(outputs) == 3

      [ts_out, st_out, str_out] = outputs
      assert ts_out.type == :numeric
      assert ts_out.data == timestamps
      assert st_out.type == :struct
      assert st_out.data == structs
      assert str_out.type == :string
      assert str_out.data == concat
      assert str_out.num_elements == 50
    end

    test "roundtrips single input through multi path" do
      cctx = ExOpenzl.create_compression_context()
      dctx = ExOpenzl.create_decompression_context()

      data =
        for i <- 1..100, into: <<>> do
          <<i::little-unsigned-32>>
        end

      assert {:ok, compressed} = ExOpenzl.compress_multi_typed(cctx, [{:numeric, data, 4}])
      assert {:ok, [output]} = ExOpenzl.decompress_multi_typed(dctx, compressed)
      assert output.type == :numeric
      assert output.data == data
      assert output.element_width == 4
      assert output.num_elements == 100
    end

    test "returns error for empty input list" do
      cctx = ExOpenzl.create_compression_context()
      assert {:error, _reason} = ExOpenzl.compress_multi_typed(cctx, [])
    end

    test "returns error for invalid tuple in list" do
      cctx = ExOpenzl.create_compression_context()
      data = <<1, 2, 3, 4, 5, 6, 7, 8>>
      # Invalid type atom
      assert {:error, _reason} = ExOpenzl.compress_multi_typed(cctx, [{:invalid_type, data, 1}])
    end
  end

  describe "typed compression with compression level" do
    test "compression level applies to typed compression" do
      data =
        for i <- 1..1_000, into: <<>> do
          <<1_700_000_000 + i::little-unsigned-64>>
        end

      cctx_low = ExOpenzl.create_compression_context()
      assert :ok = ExOpenzl.set_compression_level(cctx_low, 1)
      assert {:ok, compressed_low} = ExOpenzl.compress_typed(cctx_low, {:numeric, data, 8})

      cctx_high = ExOpenzl.create_compression_context()
      assert :ok = ExOpenzl.set_compression_level(cctx_high, 19)
      assert {:ok, compressed_high} = ExOpenzl.compress_typed(cctx_high, {:numeric, data, 8})

      assert byte_size(compressed_high) <= byte_size(compressed_low)

      # Both decompress correctly
      dctx = ExOpenzl.create_decompression_context()
      assert {:ok, info_low} = ExOpenzl.decompress_typed(dctx, compressed_low)
      assert {:ok, info_high} = ExOpenzl.decompress_typed(dctx, compressed_high)
      assert info_low.data == data
      assert info_high.data == data
    end
  end

  describe "compression level stickiness" do
    test "level persists across multiple compress calls on same context" do
      cctx = ExOpenzl.create_compression_context()
      dctx = ExOpenzl.create_decompression_context()

      assert :ok = ExOpenzl.set_compression_level(cctx, 15)

      for i <- 1..5 do
        original = String.duplicate("Sticky level test #{i}. ", 200)
        assert {:ok, compressed} = ExOpenzl.compress(cctx, original)
        assert {:ok, ^original} = ExOpenzl.decompress(dctx, compressed)
      end
    end
  end

  describe "frame_info/1" do
    test "returns metadata for a single-output frame" do
      cctx = ExOpenzl.create_compression_context()

      data =
        for i <- 1..100, into: <<>> do
          <<i::little-unsigned-64>>
        end

      assert {:ok, compressed} = ExOpenzl.compress_typed(cctx, {:numeric, data, 8})
      assert {:ok, info} = ExOpenzl.frame_info(compressed)

      assert info.num_outputs == 1
      assert is_integer(info.format_version)
      assert [output] = info.outputs
      assert output.type == :numeric
      assert output.decompressed_size == 800
      assert output.num_elements == 100 or output.num_elements == :unknown
    end

    test "returns metadata for a multi-output frame" do
      cctx = ExOpenzl.create_compression_context()

      timestamps = for i <- 1..50, into: <<>>, do: <<i::little-unsigned-64>>
      levels = :binary.copy(<<1, 2, 3>>, 10)

      assert {:ok, compressed} =
               ExOpenzl.compress_multi_typed(cctx, [
                 {:numeric, timestamps, 8},
                 {:numeric, levels, 1}
               ])

      assert {:ok, info} = ExOpenzl.frame_info(compressed)
      assert info.num_outputs == 2
    end

    test "returns error for invalid data" do
      assert {:error, _reason} = ExOpenzl.frame_info("not valid frame data")
    end

    test "returns error for empty data" do
      assert {:error, _reason} = ExOpenzl.frame_info(<<>>)
    end

    test "per-output metadata includes type and size for mixed frame" do
      cctx = ExOpenzl.create_compression_context()

      u64_data = for i <- 1..20, into: <<>>, do: <<i::little-unsigned-64>>
      u8_data = :binary.copy(<<1, 2, 3, 4, 5>>, 10)

      assert {:ok, compressed} =
               ExOpenzl.compress_multi_typed(cctx, [
                 {:numeric, u64_data, 8},
                 {:numeric, u8_data, 1}
               ])

      assert {:ok, info} = ExOpenzl.frame_info(compressed)
      assert length(info.outputs) == 2

      [out1, out2] = info.outputs
      assert out1.type == :numeric
      assert out1.decompressed_size == 160
      assert out2.type == :numeric
      assert out2.decompressed_size == 50
    end
  end

  describe "decompress_typed/2 error paths" do
    test "returns error for empty input" do
      dctx = ExOpenzl.create_decompression_context()
      assert {:error, _reason} = ExOpenzl.decompress_typed(dctx, <<>>)
    end

    test "returns error for invalid compressed data" do
      dctx = ExOpenzl.create_decompression_context()
      assert {:error, _reason} = ExOpenzl.decompress_typed(dctx, "not valid data")
    end
  end

  describe "decompress_multi_typed/2 error paths" do
    test "returns error for empty input" do
      dctx = ExOpenzl.create_decompression_context()
      assert {:error, _reason} = ExOpenzl.decompress_multi_typed(dctx, <<>>)
    end

    test "returns error for invalid compressed data" do
      dctx = ExOpenzl.create_decompression_context()
      assert {:error, _reason} = ExOpenzl.decompress_multi_typed(dctx, "not valid data")
    end
  end

  # ===========================================================================
  # Phase 3: SDDL Compressor
  # ===========================================================================

  describe "sddl_compile/1" do
    test "compiles valid SDDL source" do
      source = "Row = {\nUInt64LE\nUInt8\n}\n: Row[_rem / 9]\n"
      assert {:ok, compiled} = ExOpenzl.sddl_compile(source)
      assert is_binary(compiled)
      assert byte_size(compiled) > 0
    end

    test "returns error for invalid SDDL source" do
      assert {:error, _reason} = ExOpenzl.sddl_compile("invalid !@#$ syntax {{{")
    end

    test "returns error for empty source" do
      assert {:error, _reason} = ExOpenzl.sddl_compile("")
    end

    test "compiles single-field description" do
      source = ": UInt32LE[_rem / 4]\n"
      assert {:ok, compiled} = ExOpenzl.sddl_compile(source)
      assert is_binary(compiled)
    end

    test "compiles multi-field record description" do
      source = """
      Row = {
        UInt64LE
        UInt32LE
        UInt16LE
        UInt8
      }
      : Row[_rem / 15]
      """

      assert {:ok, compiled} = ExOpenzl.sddl_compile(source)
      assert is_binary(compiled)
    end
  end

  describe "create_sddl_compressor/1" do
    test "returns error for empty binary" do
      assert {:error, _reason} = ExOpenzl.create_sddl_compressor(<<>>)
    end

    test "compressor from invalid binary fails at compress time" do
      # The compressor creation may succeed (lazy validation), but
      # compressing with it should fail
      case ExOpenzl.create_sddl_compressor("not valid compiled sddl") do
        {:error, _reason} ->
          :ok

        {:ok, compressor} ->
          cctx = ExOpenzl.create_compression_context()
          assert :ok = ExOpenzl.set_compressor(cctx, compressor)
          assert {:error, _reason} = ExOpenzl.compress(cctx, "some data to compress")
      end
    end
  end

  describe "SDDL compressor pipeline" do
    test "compile, create compressor, attach, and compress" do
      # Define a record with UInt64LE timestamp + UInt8 level (9 bytes),
      # repeated for all remaining input bytes
      source = "Row = {\nUInt64LE\nUInt8\n}\n: Row[_rem / 9]\n"
      assert {:ok, compiled} = ExOpenzl.sddl_compile(source)

      assert {:ok, compressor} = ExOpenzl.create_sddl_compressor(compiled)
      assert is_reference(compressor)

      cctx = ExOpenzl.create_compression_context()
      dctx = ExOpenzl.create_decompression_context()

      assert :ok = ExOpenzl.set_compressor(cctx, compressor)

      # Build data matching the SDDL description: 9 bytes per record (8 + 1)
      records =
        for i <- 1..100, into: <<>> do
          <<1_700_000_000 + i::little-unsigned-64, rem(i, 5)::unsigned-8>>
        end

      assert {:ok, compressed} = ExOpenzl.compress(cctx, records)
      assert is_binary(compressed)
      assert {:ok, ^records} = ExOpenzl.decompress(dctx, compressed)
    end

    test "SDDL compression achieves better ratio than plain compress" do
      source = "Row = {\nUInt64LE\nUInt8\n}\n: Row[_rem / 9]\n"
      assert {:ok, compiled} = ExOpenzl.sddl_compile(source)
      assert {:ok, compressor} = ExOpenzl.create_sddl_compressor(compiled)

      # Highly structured data — monotonic timestamps + repeating levels
      records =
        for i <- 1..1_000, into: <<>> do
          <<1_700_000_000 + i::little-unsigned-64, rem(i, 5)::unsigned-8>>
        end

      # SDDL-aware compression
      cctx_sddl = ExOpenzl.create_compression_context()
      assert :ok = ExOpenzl.set_compressor(cctx_sddl, compressor)
      assert {:ok, compressed_sddl} = ExOpenzl.compress(cctx_sddl, records)

      # Plain compression (no format awareness)
      assert {:ok, compressed_plain} = ExOpenzl.compress(records)

      assert byte_size(compressed_sddl) < byte_size(compressed_plain),
             "SDDL compressed: #{byte_size(compressed_sddl)}, plain: #{byte_size(compressed_plain)}"

      # Both decompress correctly
      dctx = ExOpenzl.create_decompression_context()
      assert {:ok, ^records} = ExOpenzl.decompress(dctx, compressed_sddl)
    end

    test "compressor can be shared across multiple contexts" do
      source = ": UInt32LE[_rem / 4]\n"
      assert {:ok, compiled} = ExOpenzl.sddl_compile(source)
      assert {:ok, compressor} = ExOpenzl.create_sddl_compressor(compiled)

      dctx = ExOpenzl.create_decompression_context()

      for batch <- 1..3 do
        cctx = ExOpenzl.create_compression_context()
        assert :ok = ExOpenzl.set_compressor(cctx, compressor)

        data =
          for i <- 1..100, into: <<>> do
            <<(batch * 1000 + i)::little-unsigned-32>>
          end

        assert {:ok, compressed} = ExOpenzl.compress(cctx, data)
        assert {:ok, ^data} = ExOpenzl.decompress(dctx, compressed)
      end
    end

    test "SDDL with wider record (15 bytes)" do
      source = """
      Row = {
        UInt64LE
        UInt32LE
        UInt16LE
        UInt8
      }
      : Row[_rem / 15]
      """

      assert {:ok, compiled} = ExOpenzl.sddl_compile(source)
      assert {:ok, compressor} = ExOpenzl.create_sddl_compressor(compiled)

      cctx = ExOpenzl.create_compression_context()
      dctx = ExOpenzl.create_decompression_context()
      assert :ok = ExOpenzl.set_compressor(cctx, compressor)

      records =
        for i <- 1..200, into: <<>> do
          <<
            1_700_000_000 + i::little-unsigned-64,
            i * 10::little-unsigned-32,
            rem(i, 1000)::little-unsigned-16,
            rem(i, 256)::unsigned-8
          >>
        end

      assert {:ok, compressed} = ExOpenzl.compress(cctx, records)
      assert {:ok, ^records} = ExOpenzl.decompress(dctx, compressed)
    end
  end
end
