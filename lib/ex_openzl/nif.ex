defmodule ExOpenzl.NIF do
  @moduledoc false
  @on_load :load_nif

  defp load_nif do
    path = :filename.join(:code.priv_dir(:ex_openzl), ~c"ex_openzl_nif")
    :erlang.load_nif(path, 0)
  end

  # Phase 0: Original NIFs
  def nif_version, do: :erlang.nif_error(:not_loaded)
  def nif_compress(_data), do: :erlang.nif_error(:not_loaded)
  def nif_compress_with_context(_ctx, _data), do: :erlang.nif_error(:not_loaded)
  def nif_decompress(_data), do: :erlang.nif_error(:not_loaded)
  def nif_decompress_with_context(_ctx, _data), do: :erlang.nif_error(:not_loaded)
  def nif_create_compression_context, do: :erlang.nif_error(:not_loaded)
  def nif_create_decompression_context, do: :erlang.nif_error(:not_loaded)
  def nif_compress_bound(_src_size), do: :erlang.nif_error(:not_loaded)

  # Phase 1: Compression Level
  def nif_set_compression_level(_ctx, _level), do: :erlang.nif_error(:not_loaded)

  # Phase 2: Typed Compression
  def nif_compress_typed_numeric(_ctx, _data, _element_width), do: :erlang.nif_error(:not_loaded)
  def nif_compress_typed_struct(_ctx, _data, _struct_width), do: :erlang.nif_error(:not_loaded)
  def nif_compress_typed_string(_ctx, _data, _lengths_bin), do: :erlang.nif_error(:not_loaded)
  def nif_compress_multi_typed(_ctx, _inputs), do: :erlang.nif_error(:not_loaded)
  def nif_decompress_typed(_ctx, _compressed), do: :erlang.nif_error(:not_loaded)
  def nif_decompress_multi_typed(_ctx, _compressed), do: :erlang.nif_error(:not_loaded)
  def nif_frame_info(_compressed), do: :erlang.nif_error(:not_loaded)

  # Phase 3: SDDL Compressor
  def nif_sddl_compile(_source), do: :erlang.nif_error(:not_loaded)
  def nif_create_sddl_compressor(_compiled), do: :erlang.nif_error(:not_loaded)
  def nif_set_compressor(_ctx, _compressor), do: :erlang.nif_error(:not_loaded)
end
