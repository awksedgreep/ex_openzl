defmodule ExOpenzl do
  @moduledoc """
  Elixir bindings for OpenZL, Meta's format-aware compression framework.

  Provides one-shot compression and decompression of binary data, with
  optional reusable contexts for amortizing setup cost across many operations.
  Supports typed/columnar compression and SDDL format-aware compression.
  """

  alias ExOpenzl.NIF

  @doc """
  Returns the OpenZL library version string.
  """
  @spec version() :: String.t()
  def version, do: NIF.nif_version()

  @doc """
  Compresses the given binary using OpenZL.

  Returns `{:ok, compressed}` on success or `{:error, reason}` on failure.
  """
  @spec compress(binary()) :: {:ok, binary()} | {:error, String.t()}
  def compress(data) when is_binary(data), do: NIF.nif_compress(data)

  @doc """
  Compresses the given binary using a reusable compression context.

  Creating a context with `create_compression_context/0` and reusing it
  across multiple calls avoids repeated allocation of internal state.
  """
  @spec compress(reference(), binary()) :: {:ok, binary()} | {:error, String.t()}
  def compress(ctx, data) when is_reference(ctx) and is_binary(data) do
    NIF.nif_compress_with_context(ctx, data)
  end

  @doc """
  Decompresses an OpenZL-compressed binary.

  Returns `{:ok, decompressed}` on success or `{:error, reason}` on failure.
  """
  @spec decompress(binary()) :: {:ok, binary()} | {:error, String.t()}
  def decompress(data) when is_binary(data), do: NIF.nif_decompress(data)

  @doc """
  Decompresses using a reusable decompression context.
  """
  @spec decompress(reference(), binary()) :: {:ok, binary()} | {:error, String.t()}
  def decompress(ctx, data) when is_reference(ctx) and is_binary(data) do
    NIF.nif_decompress_with_context(ctx, data)
  end

  @doc """
  Creates a reusable compression context.

  The context is garbage-collected when no longer referenced.
  """
  @spec create_compression_context() :: reference()
  def create_compression_context, do: NIF.nif_create_compression_context()

  @doc """
  Creates a reusable decompression context.

  The context is garbage-collected when no longer referenced.
  """
  @spec create_decompression_context() :: reference()
  def create_decompression_context, do: NIF.nif_create_decompression_context()

  @doc """
  Returns the upper bound on compressed output size for a given input size.

  Useful for pre-allocating buffers.
  """
  @spec compress_bound(non_neg_integer()) :: non_neg_integer()
  def compress_bound(src_size) when is_integer(src_size) and src_size >= 0 do
    NIF.nif_compress_bound(src_size)
  end

  # ===========================================================================
  # Phase 1: Compression Level
  # ===========================================================================

  @doc """
  Sets the compression level on a reusable compression context.

  Higher levels produce smaller output but take longer. The level persists
  across subsequent compress calls on the same context (sticky parameters).
  """
  @spec set_compression_level(reference(), integer()) :: :ok | {:error, String.t()}
  def set_compression_level(ctx, level) when is_reference(ctx) and is_integer(level) do
    case NIF.nif_set_compression_level(ctx, level) do
      {:ok, :ok} -> :ok
      {:error, _} = err -> err
    end
  end

  # ===========================================================================
  # Phase 2: Typed Compression
  # ===========================================================================

  @doc """
  Compresses typed data (numeric, struct, or string) with type information.

  Accepts tagged tuples:
  - `{:numeric, data, element_width}` — width must be 1, 2, 4, or 8
  - `{:struct, data, struct_width}` — fixed-width records
  - `{:string, data, lengths_bin}` — variable-length strings with packed uint32 lengths
  """
  @spec compress_typed(reference(), tuple()) :: {:ok, binary()} | {:error, String.t()}
  def compress_typed(ctx, {:numeric, data, element_width})
      when is_reference(ctx) and is_binary(data) and is_integer(element_width) do
    NIF.nif_compress_typed_numeric(ctx, data, element_width)
  end

  def compress_typed(ctx, {:struct, data, struct_width})
      when is_reference(ctx) and is_binary(data) and is_integer(struct_width) do
    NIF.nif_compress_typed_struct(ctx, data, struct_width)
  end

  def compress_typed(ctx, {:string, data, lengths_bin})
      when is_reference(ctx) and is_binary(data) and is_binary(lengths_bin) do
    NIF.nif_compress_typed_string(ctx, data, lengths_bin)
  end

  @doc """
  Compresses multiple typed inputs into a single frame.

  Each input is a tagged tuple: `{:numeric, data, width}`,
  `{:struct, data, struct_width}`, or `{:string, data, lengths_bin}`.
  """
  @spec compress_multi_typed(reference(), [tuple()]) ::
          {:ok, binary()} | {:error, String.t()}
  def compress_multi_typed(ctx, inputs) when is_reference(ctx) and is_list(inputs) do
    NIF.nif_compress_multi_typed(ctx, inputs)
  end

  @doc """
  Decompresses a single typed output from a compressed frame.

  Returns `{:ok, info_map}` where `info_map` contains `:type`, `:data`,
  `:element_width`, `:num_elements`, and optionally `:string_lengths`.
  """
  @spec decompress_typed(reference(), binary()) :: {:ok, map()} | {:error, String.t()}
  def decompress_typed(ctx, compressed) when is_reference(ctx) and is_binary(compressed) do
    NIF.nif_decompress_typed(ctx, compressed)
  end

  @doc """
  Decompresses a multi-output frame into a list of typed result maps.
  """
  @spec decompress_multi_typed(reference(), binary()) ::
          {:ok, [map()]} | {:error, String.t()}
  def decompress_multi_typed(ctx, compressed)
      when is_reference(ctx) and is_binary(compressed) do
    NIF.nif_decompress_multi_typed(ctx, compressed)
  end

  @doc """
  Queries frame metadata without decompression.

  Returns `{:ok, info_map}` with `:format_version`, `:num_outputs`, and
  `:outputs` (a list of per-output metadata maps).
  """
  @spec frame_info(binary()) :: {:ok, map()} | {:error, String.t()}
  def frame_info(compressed) when is_binary(compressed) do
    NIF.nif_frame_info(compressed)
  end

  # ===========================================================================
  # Phase 3: SDDL Compressor
  # ===========================================================================

  @doc """
  Compiles SDDL source text to a binary description.
  """
  @spec sddl_compile(String.t()) :: {:ok, binary()} | {:error, String.t()}
  def sddl_compile(source) when is_binary(source) do
    NIF.nif_sddl_compile(source)
  end

  @doc """
  Creates a compressor from compiled SDDL binary.
  """
  @spec create_sddl_compressor(binary()) :: {:ok, reference()} | {:error, String.t()}
  def create_sddl_compressor(compiled) when is_binary(compiled) do
    NIF.nif_create_sddl_compressor(compiled)
  end

  @doc """
  Attaches a compressor to a compression context.

  After this call, `compress/2` on this context will use the compressor's
  format-aware compression graph.
  """
  @spec set_compressor(reference(), reference()) :: :ok | {:error, String.t()}
  def set_compressor(ctx, compressor) when is_reference(ctx) and is_reference(compressor) do
    case NIF.nif_set_compressor(ctx, compressor) do
      {:ok, :ok} -> :ok
      {:error, _} = err -> err
    end
  end
end
