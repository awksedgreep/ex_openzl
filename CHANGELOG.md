# Changelog

## 0.5.0

- Upgrade the bundled OpenZL library from 0.2.0 to [0.3.0](https://github.com/facebook/openzl/releases/tag/v0.3.0). The upstream release improves its native LZ decompressor and adds the Compression Transformer for numeric graphs.
- Add `create_lz_compressor/0` so callers can select the native LZ graph with `set_compressor/2`. The default serial path continues to use the zstd graph.
- Add `set_format_version/2`. OpenZL 0.3.0 writes format version 27 by default; set version 24 on a reusable context when OpenZL 0.2.0 must decode new frames.
- Include new upstream CMake inputs in the Hex source package and update the native LZ benchmark.
