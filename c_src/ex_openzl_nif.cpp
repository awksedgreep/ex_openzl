#include <fine.hpp>
#include <openzl/openzl.h>
#include <openzl/codecs/zl_generic.h>

#include <cstring>
#include <memory>
#include <optional>
#include <string>
#include <variant>
#include <vector>

// ---------------------------------------------------------------------------
// Resource: Compressor (wraps ZL_Compressor*)
// Must be declared before CCtx since CCtx can hold a reference to it.
// ---------------------------------------------------------------------------

class Compressor {
public:
  ZL_Compressor *compressor;

  Compressor() : compressor(ZL_Compressor_create()) {
    if (!compressor) {
      throw std::runtime_error("failed to create OpenZL compressor");
    }
  }

  ~Compressor() {
    if (compressor) {
      ZL_Compressor_free(compressor);
    }
  }

  Compressor(const Compressor &) = delete;
  Compressor &operator=(const Compressor &) = delete;
};

FINE_RESOURCE(Compressor);

// ---------------------------------------------------------------------------
// Resource: Compression context (reusable across calls)
// ---------------------------------------------------------------------------

class CCtx {
public:
  ZL_CCtx *ctx;
  // Default generic compressor for typed compression (owned by CCtx)
  ZL_Compressor *default_compressor;
  // Hold a reference to attached compressor to prevent GC
  std::optional<fine::ResourcePtr<Compressor>> compressor_ref;

  CCtx() : ctx(ZL_CCtx_create()), default_compressor(nullptr) {
    if (!ctx) {
      throw std::runtime_error("failed to create OpenZL compression context");
    }
    (void)ZL_CCtx_setParameter(ctx, ZL_CParam_formatVersion,
                               static_cast<int>(ZL_getDefaultEncodingVersion()));
    (void)ZL_CCtx_setParameter(ctx, ZL_CParam_stickyParameters, 1);

    // Set up default generic compressor so typed compression works
    default_compressor = ZL_Compressor_create();
    if (default_compressor) {
      ZL_Report result = ZL_Compressor_selectStartingGraphID(
          default_compressor, ZL_GRAPH_COMPRESS_GENERIC);
      if (!ZL_isError(result)) {
        (void)ZL_CCtx_refCompressor(ctx, default_compressor);
      }
    }
  }

  ~CCtx() {
    if (ctx) {
      ZL_CCtx_free(ctx);
    }
    if (default_compressor) {
      ZL_Compressor_free(default_compressor);
    }
  }

  CCtx(const CCtx &) = delete;
  CCtx &operator=(const CCtx &) = delete;
};

FINE_RESOURCE(CCtx);

// ---------------------------------------------------------------------------
// Resource: Decompression context (reusable across calls)
// ---------------------------------------------------------------------------

class DCtx {
public:
  ZL_DCtx *ctx;

  DCtx() : ctx(ZL_DCtx_create()) {
    if (!ctx) {
      throw std::runtime_error(
          "failed to create OpenZL decompression context");
    }
  }

  ~DCtx() {
    if (ctx) {
      ZL_DCtx_free(ctx);
    }
  }

  DCtx(const DCtx &) = delete;
  DCtx &operator=(const DCtx &) = delete;
};

FINE_RESOURCE(DCtx);

// ---------------------------------------------------------------------------
// Helper: RAII wrapper for ZL_TypedRef*
// ---------------------------------------------------------------------------

struct TypedRefDeleter {
  void operator()(ZL_TypedRef *ref) const {
    if (ref)
      ZL_TypedRef_free(ref);
  }
};
using TypedRefPtr = std::unique_ptr<ZL_TypedRef, TypedRefDeleter>;

// ---------------------------------------------------------------------------
// Helper: RAII wrapper for ZL_TypedBuffer*
// ---------------------------------------------------------------------------

struct TypedBufferDeleter {
  void operator()(ZL_TypedBuffer *buf) const {
    if (buf)
      ZL_TypedBuffer_free(buf);
  }
};
using TypedBufferPtr = std::unique_ptr<ZL_TypedBuffer, TypedBufferDeleter>;

// ---------------------------------------------------------------------------
// Helper: RAII wrapper for ZL_FrameInfo*
// ---------------------------------------------------------------------------

struct FrameInfoDeleter {
  void operator()(ZL_FrameInfo *fi) const {
    if (fi)
      ZL_FrameInfo_free(fi);
  }
};
using FrameInfoPtr = std::unique_ptr<ZL_FrameInfo, FrameInfoDeleter>;

// ---------------------------------------------------------------------------
// Helper: convert ZL_Type enum to atom string
// ---------------------------------------------------------------------------

static const char *type_to_string(ZL_Type type) {
  switch (type) {
  case ZL_Type_serial:
    return "serial";
  case ZL_Type_struct:
    return "struct";
  case ZL_Type_numeric:
    return "numeric";
  case ZL_Type_string:
    return "string";
  default:
    return "unknown";
  }
}

// ===================================================================
// Phase 0: Original NIFs
// ===================================================================

// ---------------------------------------------------------------------------
// NIF: version/0 - Return OpenZL version string
// ---------------------------------------------------------------------------

static std::string nif_version(ErlNifEnv *env) {
  unsigned ver = ZL_LIBRARY_VERSION_NUMBER;
  unsigned major = ver / 10000;
  unsigned minor = (ver / 100) % 100;
  unsigned patch = ver % 100;
  return std::to_string(major) + "." + std::to_string(minor) + "." +
         std::to_string(patch);
}

FINE_NIF(nif_version, 0);

// ---------------------------------------------------------------------------
// NIF: compress/1 - One-shot compression of raw bytes
// ---------------------------------------------------------------------------

static std::variant<fine::Ok<std::string>, fine::Error<std::string>>
nif_compress(ErlNifEnv *env, std::string_view input) {
  if (input.empty()) {
    return fine::Error(std::string("input must not be empty"));
  }

  size_t bound = ZL_compressBound(input.size());
  std::string output(bound, '\0');

  ZL_CCtx *cctx = ZL_CCtx_create();
  if (!cctx) {
    return fine::Error(std::string("failed to create compression context"));
  }

  (void)ZL_CCtx_setParameter(cctx, ZL_CParam_formatVersion,
                              static_cast<int>(ZL_getDefaultEncodingVersion()));

  ZL_Report result = ZL_CCtx_compress(cctx, output.data(), bound,
                                       input.data(), input.size());

  if (ZL_isError(result)) {
    const char *err = ZL_CCtx_getErrorContextString(cctx, result);
    std::string msg = err ? std::string(err) : "compression failed";
    ZL_CCtx_free(cctx);
    return fine::Error(std::move(msg));
  }

  ZL_CCtx_free(cctx);
  output.resize(ZL_validResult(result));
  return fine::Ok(std::move(output));
}

FINE_NIF(nif_compress, ERL_NIF_DIRTY_JOB_CPU_BOUND);

// ---------------------------------------------------------------------------
// NIF: compress_with_context/2 - Compress using a reusable context
// ---------------------------------------------------------------------------

static std::variant<fine::Ok<std::string>, fine::Error<std::string>>
nif_compress_with_context(ErlNifEnv *env, fine::ResourcePtr<CCtx> cctx,
                          std::string_view input) {
  if (input.empty()) {
    return fine::Error(std::string("input must not be empty"));
  }

  size_t bound = ZL_compressBound(input.size());
  std::string output(bound, '\0');

  ZL_Report result = ZL_CCtx_compress(cctx->ctx, output.data(), bound,
                                       input.data(), input.size());

  if (ZL_isError(result)) {
    const char *err = ZL_CCtx_getErrorContextString(cctx->ctx, result);
    std::string msg = err ? std::string(err) : "compression failed";
    return fine::Error(std::move(msg));
  }

  output.resize(ZL_validResult(result));
  return fine::Ok(std::move(output));
}

FINE_NIF(nif_compress_with_context, ERL_NIF_DIRTY_JOB_CPU_BOUND);

// ---------------------------------------------------------------------------
// NIF: decompress/1 - One-shot decompression
// ---------------------------------------------------------------------------

static std::variant<fine::Ok<std::string>, fine::Error<std::string>>
nif_decompress(ErlNifEnv *env, std::string_view compressed) {
  if (compressed.empty()) {
    return fine::Error(std::string("input must not be empty"));
  }

  ZL_Report decompressed_size =
      ZL_getDecompressedSize(compressed.data(), compressed.size());

  if (ZL_isError(decompressed_size)) {
    return fine::Error(
        std::string("failed to read decompressed size from frame"));
  }

  size_t out_size = ZL_validResult(decompressed_size);
  std::string output(out_size, '\0');

  ZL_Report result = ZL_decompress(output.data(), output.size(),
                                    compressed.data(), compressed.size());

  if (ZL_isError(result)) {
    return fine::Error(std::string("decompression failed"));
  }

  output.resize(ZL_validResult(result));
  return fine::Ok(std::move(output));
}

FINE_NIF(nif_decompress, ERL_NIF_DIRTY_JOB_CPU_BOUND);

// ---------------------------------------------------------------------------
// NIF: decompress_with_context/2 - Decompress using a reusable context
// ---------------------------------------------------------------------------

static std::variant<fine::Ok<std::string>, fine::Error<std::string>>
nif_decompress_with_context(ErlNifEnv *env, fine::ResourcePtr<DCtx> dctx,
                            std::string_view compressed) {
  if (compressed.empty()) {
    return fine::Error(std::string("input must not be empty"));
  }

  ZL_Report decompressed_size =
      ZL_getDecompressedSize(compressed.data(), compressed.size());

  if (ZL_isError(decompressed_size)) {
    return fine::Error(
        std::string("failed to read decompressed size from frame"));
  }

  size_t out_size = ZL_validResult(decompressed_size);
  std::string output(out_size, '\0');

  ZL_Report result =
      ZL_DCtx_decompress(dctx->ctx, output.data(), output.size(),
                          compressed.data(), compressed.size());

  if (ZL_isError(result)) {
    return fine::Error(std::string("decompression failed"));
  }

  output.resize(ZL_validResult(result));
  return fine::Ok(std::move(output));
}

FINE_NIF(nif_decompress_with_context, ERL_NIF_DIRTY_JOB_CPU_BOUND);

// ---------------------------------------------------------------------------
// NIF: create_compression_context/0
// ---------------------------------------------------------------------------

static fine::ResourcePtr<CCtx>
nif_create_compression_context(ErlNifEnv *env) {
  return fine::make_resource<CCtx>();
}

FINE_NIF(nif_create_compression_context, 0);

// ---------------------------------------------------------------------------
// NIF: create_decompression_context/0
// ---------------------------------------------------------------------------

static fine::ResourcePtr<DCtx>
nif_create_decompression_context(ErlNifEnv *env) {
  return fine::make_resource<DCtx>();
}

FINE_NIF(nif_create_decompression_context, 0);

// ---------------------------------------------------------------------------
// NIF: compress_bound/1 - Return upper bound of compressed size
// ---------------------------------------------------------------------------

static uint64_t nif_compress_bound(ErlNifEnv *env, uint64_t src_size) {
  return static_cast<uint64_t>(ZL_compressBound(static_cast<size_t>(src_size)));
}

FINE_NIF(nif_compress_bound, 0);

// ===================================================================
// Phase 1: Compression Level
// ===================================================================

// ---------------------------------------------------------------------------
// NIF: set_compression_level/2
// ---------------------------------------------------------------------------

static std::variant<fine::Ok<fine::Atom>, fine::Error<std::string>>
nif_set_compression_level(ErlNifEnv *env, fine::ResourcePtr<CCtx> cctx,
                          int64_t level) {
  ZL_Report result =
      ZL_CCtx_setParameter(cctx->ctx, ZL_CParam_compressionLevel,
                            static_cast<int>(level));
  if (ZL_isError(result)) {
    const char *err = ZL_CCtx_getErrorContextString(cctx->ctx, result);
    std::string msg = err ? std::string(err) : "failed to set compression level";
    return fine::Error(std::move(msg));
  }
  return fine::Ok(fine::Atom("ok"));
}

FINE_NIF(nif_set_compression_level, 0);

// ===================================================================
// Phase 2: Typed Compression
// ===================================================================

// ---------------------------------------------------------------------------
// NIF: compress_typed_numeric/3
// Compress numeric data: (cctx, binary, element_width)
// ---------------------------------------------------------------------------

static std::variant<fine::Ok<std::string>, fine::Error<std::string>>
nif_compress_typed_numeric(ErlNifEnv *env, fine::ResourcePtr<CCtx> cctx,
                           std::string_view data, uint64_t element_width) {
  if (data.empty()) {
    return fine::Error(std::string("input must not be empty"));
  }
  if (element_width != 1 && element_width != 2 && element_width != 4 &&
      element_width != 8) {
    return fine::Error(std::string("element_width must be 1, 2, 4, or 8"));
  }

  size_t num_elements = data.size() / element_width;
  if (data.size() % element_width != 0) {
    return fine::Error(
        std::string("data size must be a multiple of element_width"));
  }

  TypedRefPtr tref(ZL_TypedRef_createNumeric(data.data(), element_width,
                                              num_elements));
  if (!tref) {
    return fine::Error(std::string("failed to create numeric typed ref"));
  }

  size_t bound = ZL_compressBound(data.size());
  std::string output(bound, '\0');

  ZL_Report result = ZL_CCtx_compressTypedRef(cctx->ctx, output.data(), bound,
                                               tref.get());

  if (ZL_isError(result)) {
    const char *err = ZL_CCtx_getErrorContextString(cctx->ctx, result);
    std::string msg = err ? std::string(err) : "typed numeric compression failed";
    return fine::Error(std::move(msg));
  }

  output.resize(ZL_validResult(result));
  return fine::Ok(std::move(output));
}

FINE_NIF(nif_compress_typed_numeric, ERL_NIF_DIRTY_JOB_CPU_BOUND);

// ---------------------------------------------------------------------------
// NIF: compress_typed_struct/3
// Compress struct data: (cctx, binary, struct_width)
// ---------------------------------------------------------------------------

static std::variant<fine::Ok<std::string>, fine::Error<std::string>>
nif_compress_typed_struct(ErlNifEnv *env, fine::ResourcePtr<CCtx> cctx,
                          std::string_view data, uint64_t struct_width) {
  if (data.empty()) {
    return fine::Error(std::string("input must not be empty"));
  }
  if (struct_width == 0) {
    return fine::Error(std::string("struct_width must be > 0"));
  }

  size_t struct_count = data.size() / struct_width;
  if (data.size() % struct_width != 0) {
    return fine::Error(
        std::string("data size must be a multiple of struct_width"));
  }

  TypedRefPtr tref(
      ZL_TypedRef_createStruct(data.data(), struct_width, struct_count));
  if (!tref) {
    return fine::Error(std::string("failed to create struct typed ref"));
  }

  size_t bound = ZL_compressBound(data.size());
  std::string output(bound, '\0');

  ZL_Report result = ZL_CCtx_compressTypedRef(cctx->ctx, output.data(), bound,
                                               tref.get());

  if (ZL_isError(result)) {
    const char *err = ZL_CCtx_getErrorContextString(cctx->ctx, result);
    std::string msg = err ? std::string(err) : "typed struct compression failed";
    return fine::Error(std::move(msg));
  }

  output.resize(ZL_validResult(result));
  return fine::Ok(std::move(output));
}

FINE_NIF(nif_compress_typed_struct, ERL_NIF_DIRTY_JOB_CPU_BOUND);

// ---------------------------------------------------------------------------
// NIF: compress_typed_string/3
// Compress string data: (cctx, binary, lengths_list_as_binary)
// lengths is a binary of packed uint32_t little-endian values
// ---------------------------------------------------------------------------

static std::variant<fine::Ok<std::string>, fine::Error<std::string>>
nif_compress_typed_string(ErlNifEnv *env, fine::ResourcePtr<CCtx> cctx,
                          std::string_view data,
                          std::string_view lengths_bin) {
  if (data.empty()) {
    return fine::Error(std::string("input must not be empty"));
  }
  if (lengths_bin.size() % sizeof(uint32_t) != 0) {
    return fine::Error(
        std::string("lengths binary size must be a multiple of 4"));
  }

  size_t nb_strings = lengths_bin.size() / sizeof(uint32_t);
  const uint32_t *lengths =
      reinterpret_cast<const uint32_t *>(lengths_bin.data());

  TypedRefPtr tref(
      ZL_TypedRef_createString(data.data(), data.size(), lengths, nb_strings));
  if (!tref) {
    return fine::Error(std::string("failed to create string typed ref"));
  }

  size_t bound = ZL_compressBound(data.size());
  std::string output(bound, '\0');

  ZL_Report result = ZL_CCtx_compressTypedRef(cctx->ctx, output.data(), bound,
                                               tref.get());

  if (ZL_isError(result)) {
    const char *err = ZL_CCtx_getErrorContextString(cctx->ctx, result);
    std::string msg = err ? std::string(err) : "typed string compression failed";
    return fine::Error(std::move(msg));
  }

  output.resize(ZL_validResult(result));
  return fine::Ok(std::move(output));
}

FINE_NIF(nif_compress_typed_string, ERL_NIF_DIRTY_JOB_CPU_BOUND);

// ---------------------------------------------------------------------------
// NIF: compress_multi_typed/2
// Compress multiple typed inputs into one frame.
// Input: (cctx, list_of_tagged_tuples)
// Each tuple is one of:
//   {:numeric, binary, width}
//   {:struct, binary, struct_width}
//   {:string, binary, lengths_binary}
// We accept fine::Term and manually decode.
// ---------------------------------------------------------------------------

static std::variant<fine::Ok<std::string>, fine::Error<std::string>>
nif_compress_multi_typed(ErlNifEnv *env, fine::ResourcePtr<CCtx> cctx,
                         fine::Term list_term) {
  // Iterate the list and build TypedRefs
  std::vector<TypedRefPtr> refs;
  std::vector<const ZL_TypedRef *> ref_ptrs;
  size_t total_size = 0;

  ERL_NIF_TERM head, tail;
  ERL_NIF_TERM current = list_term;

  while (enif_get_list_cell(env, current, &head, &tail)) {
    int arity;
    const ERL_NIF_TERM *tuple_terms;
    if (!enif_get_tuple(env, head, &arity, &tuple_terms) || arity != 3) {
      return fine::Error(
          std::string("each input must be a 3-tuple {type, data, param}"));
    }

    // Get the type atom
    char type_atom[16];
    if (!enif_get_atom(env, tuple_terms[0], type_atom, sizeof(type_atom),
                       ERL_NIF_LATIN1)) {
      return fine::Error(std::string("first element must be an atom"));
    }

    // Get the binary data
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, tuple_terms[1], &bin)) {
      return fine::Error(std::string("second element must be a binary"));
    }

    if (std::strcmp(type_atom, "numeric") == 0) {
      ErlNifUInt64 width;
      if (!enif_get_uint64(env, tuple_terms[2], &width)) {
        return fine::Error(
            std::string("numeric width must be a positive integer"));
      }
      if (width != 1 && width != 2 && width != 4 && width != 8) {
        return fine::Error(
            std::string("numeric element_width must be 1, 2, 4, or 8"));
      }
      if (bin.size % width != 0) {
        return fine::Error(
            std::string("numeric data size must be a multiple of width"));
      }
      size_t count = bin.size / width;
      TypedRefPtr ref(
          ZL_TypedRef_createNumeric(bin.data, width, count));
      if (!ref) {
        return fine::Error(
            std::string("failed to create numeric typed ref"));
      }
      total_size += bin.size;
      ref_ptrs.push_back(ref.get());
      refs.push_back(std::move(ref));

    } else if (std::strcmp(type_atom, "struct") == 0) {
      ErlNifUInt64 swidth;
      if (!enif_get_uint64(env, tuple_terms[2], &swidth)) {
        return fine::Error(
            std::string("struct width must be a positive integer"));
      }
      if (swidth == 0) {
        return fine::Error(std::string("struct_width must be > 0"));
      }
      if (bin.size % swidth != 0) {
        return fine::Error(
            std::string("struct data size must be a multiple of width"));
      }
      size_t count = bin.size / swidth;
      TypedRefPtr ref(
          ZL_TypedRef_createStruct(bin.data, swidth, count));
      if (!ref) {
        return fine::Error(
            std::string("failed to create struct typed ref"));
      }
      total_size += bin.size;
      ref_ptrs.push_back(ref.get());
      refs.push_back(std::move(ref));

    } else if (std::strcmp(type_atom, "string") == 0) {
      ErlNifBinary lens_bin;
      if (!enif_inspect_binary(env, tuple_terms[2], &lens_bin)) {
        return fine::Error(
            std::string("string lengths must be a binary of uint32_t values"));
      }
      if (lens_bin.size % sizeof(uint32_t) != 0) {
        return fine::Error(std::string(
            "string lengths binary size must be a multiple of 4"));
      }
      size_t nb_strings = lens_bin.size / sizeof(uint32_t);
      const uint32_t *lengths =
          reinterpret_cast<const uint32_t *>(lens_bin.data);
      TypedRefPtr ref(ZL_TypedRef_createString(bin.data, bin.size,
                                                lengths, nb_strings));
      if (!ref) {
        return fine::Error(
            std::string("failed to create string typed ref"));
      }
      total_size += bin.size;
      ref_ptrs.push_back(ref.get());
      refs.push_back(std::move(ref));

    } else {
      return fine::Error(
          std::string("unknown type atom: ") + type_atom);
    }

    current = tail;
  }

  if (refs.empty()) {
    return fine::Error(std::string("input list must not be empty"));
  }

  size_t bound = ZL_compressBound(total_size);
  std::string output(bound, '\0');

  ZL_Report result = ZL_CCtx_compressMultiTypedRef(
      cctx->ctx, output.data(), bound, ref_ptrs.data(), ref_ptrs.size());

  if (ZL_isError(result)) {
    const char *err = ZL_CCtx_getErrorContextString(cctx->ctx, result);
    std::string msg =
        err ? std::string(err) : "multi-typed compression failed";
    return fine::Error(std::move(msg));
  }

  output.resize(ZL_validResult(result));
  return fine::Ok(std::move(output));
}

FINE_NIF(nif_compress_multi_typed, ERL_NIF_DIRTY_JOB_CPU_BOUND);

// ---------------------------------------------------------------------------
// NIF: decompress_typed/2
// Decompress a single typed output using TypedBuffer (auto-allocates).
// Returns {:ok, map} with type info + data, or {:error, reason}.
// ---------------------------------------------------------------------------

static std::variant<fine::Ok<fine::Term>, fine::Error<std::string>>
nif_decompress_typed(ErlNifEnv *env, fine::ResourcePtr<DCtx> dctx,
                     std::string_view compressed) {
  if (compressed.empty()) {
    return fine::Error(std::string("input must not be empty"));
  }

  TypedBufferPtr tbuf(ZL_TypedBuffer_create());
  if (!tbuf) {
    return fine::Error(std::string("failed to create typed buffer"));
  }

  ZL_Report result = ZL_DCtx_decompressTBuffer(
      dctx->ctx, tbuf.get(), compressed.data(), compressed.size());

  if (ZL_isError(result)) {
    const char *err = ZL_DCtx_getErrorContextString(dctx->ctx, result);
    std::string msg = err ? std::string(err) : "typed decompression failed";
    return fine::Error(std::move(msg));
  }

  ZL_Type type = ZL_TypedBuffer_type(tbuf.get());
  size_t byte_size = ZL_TypedBuffer_byteSize(tbuf.get());
  size_t num_elts = ZL_TypedBuffer_numElts(tbuf.get());
  size_t elt_width = ZL_TypedBuffer_eltWidth(tbuf.get());
  const void *data_ptr = ZL_TypedBuffer_rPtr(tbuf.get());

  // Build the data binary
  ERL_NIF_TERM data_bin;
  unsigned char *bin_ptr = enif_make_new_binary(env, byte_size, &data_bin);
  std::memcpy(bin_ptr, data_ptr, byte_size);

  // Build the result map
  ERL_NIF_TERM map = enif_make_new_map(env);
  ERL_NIF_TERM keys[5], vals[5];

  keys[0] = fine::__private__::make_atom(env, "type");
  vals[0] = fine::__private__::make_atom(env, type_to_string(type));
  keys[1] = fine::__private__::make_atom(env, "data");
  vals[1] = data_bin;
  keys[2] = fine::__private__::make_atom(env, "element_width");
  vals[2] = enif_make_uint64(env, elt_width);
  keys[3] = fine::__private__::make_atom(env, "num_elements");
  vals[3] = enif_make_uint64(env, num_elts);

  int map_size = 4;

  // For string type, also include the lengths
  if (type == ZL_Type_string) {
    const uint32_t *str_lens = ZL_TypedBuffer_rStringLens(tbuf.get());
    if (str_lens) {
      ERL_NIF_TERM lens_bin;
      size_t lens_byte_size = num_elts * sizeof(uint32_t);
      unsigned char *lens_ptr =
          enif_make_new_binary(env, lens_byte_size, &lens_bin);
      std::memcpy(lens_ptr, str_lens, lens_byte_size);
      keys[4] = fine::__private__::make_atom(env, "string_lengths");
      vals[4] = lens_bin;
      map_size = 5;
    }
  }

  enif_make_map_from_arrays(env, keys, vals, map_size, &map);

  return fine::Ok(fine::Term(map));
}

FINE_NIF(nif_decompress_typed, ERL_NIF_DIRTY_JOB_CPU_BOUND);

// ---------------------------------------------------------------------------
// NIF: decompress_multi_typed/2
// Decompress a multi-output frame into a list of typed result maps.
// ---------------------------------------------------------------------------

static std::variant<fine::Ok<fine::Term>, fine::Error<std::string>>
nif_decompress_multi_typed(ErlNifEnv *env, fine::ResourcePtr<DCtx> dctx,
                           std::string_view compressed) {
  if (compressed.empty()) {
    return fine::Error(std::string("input must not be empty"));
  }

  // Get number of outputs from frame
  ZL_Report num_report =
      ZL_getNumOutputs(compressed.data(), compressed.size());
  if (ZL_isError(num_report)) {
    return fine::Error(
        std::string("failed to get number of outputs from frame"));
  }
  size_t nb_outputs = ZL_validResult(num_report);

  // Create typed buffers
  std::vector<TypedBufferPtr> bufs;
  std::vector<ZL_TypedBuffer *> buf_ptrs;
  for (size_t i = 0; i < nb_outputs; i++) {
    TypedBufferPtr buf(ZL_TypedBuffer_create());
    if (!buf) {
      return fine::Error(std::string("failed to create typed buffer"));
    }
    buf_ptrs.push_back(buf.get());
    bufs.push_back(std::move(buf));
  }

  ZL_Report result = ZL_DCtx_decompressMultiTBuffer(
      dctx->ctx, buf_ptrs.data(), nb_outputs, compressed.data(),
      compressed.size());

  if (ZL_isError(result)) {
    const char *err = ZL_DCtx_getErrorContextString(dctx->ctx, result);
    std::string msg =
        err ? std::string(err) : "multi-typed decompression failed";
    return fine::Error(std::move(msg));
  }

  // Build list of result maps
  std::vector<ERL_NIF_TERM> list_items;
  for (size_t i = 0; i < nb_outputs; i++) {
    ZL_TypedBuffer *tbuf = buf_ptrs[i];
    ZL_Type type = ZL_TypedBuffer_type(tbuf);
    size_t byte_size = ZL_TypedBuffer_byteSize(tbuf);
    size_t num_elts = ZL_TypedBuffer_numElts(tbuf);
    size_t elt_width = ZL_TypedBuffer_eltWidth(tbuf);
    const void *data_ptr = ZL_TypedBuffer_rPtr(tbuf);

    ERL_NIF_TERM data_bin;
    unsigned char *bin_ptr = enif_make_new_binary(env, byte_size, &data_bin);
    std::memcpy(bin_ptr, data_ptr, byte_size);

    ERL_NIF_TERM keys[5], vals[5];
    keys[0] = fine::__private__::make_atom(env, "type");
    vals[0] = fine::__private__::make_atom(env, type_to_string(type));
    keys[1] = fine::__private__::make_atom(env, "data");
    vals[1] = data_bin;
    keys[2] = fine::__private__::make_atom(env, "element_width");
    vals[2] = enif_make_uint64(env, elt_width);
    keys[3] = fine::__private__::make_atom(env, "num_elements");
    vals[3] = enif_make_uint64(env, num_elts);

    int map_size = 4;

    if (type == ZL_Type_string) {
      const uint32_t *str_lens = ZL_TypedBuffer_rStringLens(tbuf);
      if (str_lens) {
        ERL_NIF_TERM lens_bin;
        size_t lens_byte_size = num_elts * sizeof(uint32_t);
        unsigned char *lens_ptr =
            enif_make_new_binary(env, lens_byte_size, &lens_bin);
        std::memcpy(lens_ptr, str_lens, lens_byte_size);
        keys[4] = fine::__private__::make_atom(env, "string_lengths");
        vals[4] = lens_bin;
        map_size = 5;
      }
    }

    ERL_NIF_TERM map;
    enif_make_map_from_arrays(env, keys, vals, map_size, &map);
    list_items.push_back(map);
  }

  ERL_NIF_TERM result_list =
      enif_make_list_from_array(env, list_items.data(), list_items.size());
  return fine::Ok(fine::Term(result_list));
}

FINE_NIF(nif_decompress_multi_typed, ERL_NIF_DIRTY_JOB_CPU_BOUND);

// ---------------------------------------------------------------------------
// NIF: frame_info/1
// Query frame metadata without decompression.
// ---------------------------------------------------------------------------

static std::variant<fine::Ok<fine::Term>, fine::Error<std::string>>
nif_frame_info(ErlNifEnv *env, std::string_view compressed) {
  if (compressed.empty()) {
    return fine::Error(std::string("input must not be empty"));
  }

  FrameInfoPtr fi(
      ZL_FrameInfo_create(compressed.data(), compressed.size()));
  if (!fi) {
    return fine::Error(std::string("failed to create frame info"));
  }

  ZL_Report ver_report = ZL_FrameInfo_getFormatVersion(fi.get());
  if (ZL_isError(ver_report)) {
    return fine::Error(std::string("failed to get format version"));
  }

  ZL_Report num_report = ZL_FrameInfo_getNumOutputs(fi.get());
  if (ZL_isError(num_report)) {
    return fine::Error(std::string("failed to get number of outputs"));
  }
  size_t num_outputs = ZL_validResult(num_report);

  // Build per-output info list
  std::vector<ERL_NIF_TERM> output_items;
  for (size_t i = 0; i < num_outputs; i++) {
    ZL_Report type_report = ZL_FrameInfo_getOutputType(fi.get(), (int)i);
    ZL_Report size_report = ZL_FrameInfo_getDecompressedSize(fi.get(), (int)i);
    ZL_Report elts_report = ZL_FrameInfo_getNumElts(fi.get(), (int)i);

    ERL_NIF_TERM keys[3], vals[3];
    keys[0] = fine::__private__::make_atom(env, "type");
    if (!ZL_isError(type_report)) {
      vals[0] = fine::__private__::make_atom(env,
                                type_to_string((ZL_Type)ZL_validResult(type_report)));
    } else {
      vals[0] = fine::__private__::make_atom(env, "unknown");
    }

    keys[1] = fine::__private__::make_atom(env, "decompressed_size");
    vals[1] = !ZL_isError(size_report)
                  ? enif_make_uint64(env, ZL_validResult(size_report))
                  : fine::__private__::make_atom(env, "unknown");

    keys[2] = fine::__private__::make_atom(env, "num_elements");
    vals[2] = !ZL_isError(elts_report)
                  ? enif_make_uint64(env, ZL_validResult(elts_report))
                  : fine::__private__::make_atom(env, "unknown");

    ERL_NIF_TERM map;
    enif_make_map_from_arrays(env, keys, vals, 3, &map);
    output_items.push_back(map);
  }

  // Build top-level map
  ERL_NIF_TERM top_keys[3], top_vals[3];
  top_keys[0] = fine::__private__::make_atom(env, "format_version");
  top_vals[0] = enif_make_uint64(env, ZL_validResult(ver_report));
  top_keys[1] = fine::__private__::make_atom(env, "num_outputs");
  top_vals[1] = enif_make_uint64(env, num_outputs);
  top_keys[2] = fine::__private__::make_atom(env, "outputs");
  top_vals[2] =
      enif_make_list_from_array(env, output_items.data(), output_items.size());

  ERL_NIF_TERM result_map;
  enif_make_map_from_arrays(env, top_keys, top_vals, 3, &result_map);
  return fine::Ok(fine::Term(result_map));
}

FINE_NIF(nif_frame_info, 0);

// ===================================================================
// Phase 3: SDDL Compressor Support
// ===================================================================

// ---------------------------------------------------------------------------
// NIF: sddl_compile/1
// Compile SDDL source text to binary description.
// ---------------------------------------------------------------------------

#include "tools/sddl/compiler/Compiler.h"

static std::variant<fine::Ok<std::string>, fine::Error<std::string>>
nif_sddl_compile(ErlNifEnv *env, std::string_view source) {
  if (source.empty()) {
    return fine::Error(std::string("SDDL source must not be empty"));
  }

  try {
    openzl::sddl::Compiler compiler{
        openzl::sddl::Compiler::Options{}.with_verbosity(-1)};
    std::string compiled = compiler.compile(source, "[input]");
    return fine::Ok(std::move(compiled));
  } catch (const std::exception &e) {
    return fine::Error(std::string("SDDL compilation failed: ") + e.what());
  }
}

FINE_NIF(nif_sddl_compile, 0);

// ---------------------------------------------------------------------------
// NIF: create_sddl_compressor/1
// Create a Compressor from compiled SDDL binary.
// Uses ZL_SDDL_setupProfile which builds the SDDL graph with generic
// clustering as successor, then validates and selects the starting graph.
// ---------------------------------------------------------------------------

#include "custom_parsers/sddl/sddl_profile.h"

static std::variant<fine::Ok<fine::ResourcePtr<Compressor>>,
                    fine::Error<std::string>>
nif_create_sddl_compressor(ErlNifEnv *env, std::string_view compiled) {
  if (compiled.empty()) {
    return fine::Error(std::string("compiled SDDL must not be empty"));
  }

  auto comp = fine::make_resource<Compressor>();

  // Build the SDDL graph with generic clustering as successor
  auto graph_result = ZL_SDDL_setupProfile(
      comp->compressor, compiled.data(), compiled.size());

  if (ZL_RES_isError(graph_result)) {
    const char *err = ZL_Compressor_getErrorContextString_fromError(
        comp->compressor, graph_result._error);
    std::string msg =
        err ? std::string(err) : "failed to build SDDL graph";
    return fine::Error(std::move(msg));
  }

  ZL_GraphID graph_id = ZL_RES_value(graph_result);

  ZL_Report select_result =
      ZL_Compressor_selectStartingGraphID(comp->compressor, graph_id);

  if (ZL_isError(select_result)) {
    const char *err = ZL_Compressor_getErrorContextString(
        comp->compressor, select_result);
    std::string msg =
        err ? std::string(err) : "failed to select starting graph";
    return fine::Error(std::move(msg));
  }

  return fine::Ok(std::move(comp));
}

FINE_NIF(nif_create_sddl_compressor, 0);

// ---------------------------------------------------------------------------
// NIF: set_compressor/2
// Attach a Compressor to a CCtx.
// ---------------------------------------------------------------------------

static std::variant<fine::Ok<fine::Atom>, fine::Error<std::string>>
nif_set_compressor(ErlNifEnv *env, fine::ResourcePtr<CCtx> cctx,
                   fine::ResourcePtr<Compressor> comp) {
  ZL_Report result =
      ZL_CCtx_refCompressor(cctx->ctx, comp->compressor);

  if (ZL_isError(result)) {
    const char *err = ZL_CCtx_getErrorContextString(cctx->ctx, result);
    std::string msg = err ? std::string(err) : "failed to set compressor";
    return fine::Error(std::move(msg));
  }

  // Store reference to prevent GC
  cctx->compressor_ref = comp;

  return fine::Ok(fine::Atom("ok"));
}

FINE_NIF(nif_set_compressor, 0);

// ---------------------------------------------------------------------------
// Module init
// ---------------------------------------------------------------------------

FINE_INIT("Elixir.ExOpenzl.NIF");
