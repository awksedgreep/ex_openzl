# OpenZL 0.2.0 Cannot Decode Frames Written by ex_openzl 0.4.6

## Summary

Frames written by `ex_openzl` `0.4.6` cannot be decompressed by `0.4.7` or
later. `0.4.7` bumped the vendored OpenZL submodule from OpenZL 0.1.x to
v0.2.0, and the 0.2.0 decoder rejects 0.1.x frames with graph/transform
validation errors.

This is a **read compatibility break in stored data**, not a corruption of the
stored bytes. The frames are structurally intact and still introspectable.

Discovered in production on `timelessmetrics.com` (2026-08-09), where it
blocked the `timeless_traces` legacy-to-libSQL migration.

## Environment

- Writer: `ex_openzl 0.4.6` (in `timeless_traces 1.3.9`), in production since March 2026
- Reader: `ex_openzl 0.4.16` (in `timeless_traces 1.6.0`)
- Stored data: `timeless_traces` block store, `*.ozl` files

## The Change

`20a6c98 chore: release v0.4.7 with OpenZL 0.2.0` moved the submodule:

```
 c_src/openzl
-Subproject commit ef847248ba9ce8cfe0c30e0b1d16cdf20aa95479
+Subproject commit 3dceb64867840201fb8f57a29d179995f700c9b8
```

No format-version gate, compatibility shim, or migration note accompanied the
bump, and nothing in the library surfaces "this frame predates the current
decoder" as a distinct condition.

## Observed Failures

Two distinct decoder errors, both from real production blocks:

```text
Code: node is requested to regenerate an incorrect number of streams
Message: Check `!(DT_isNbRegensCompatible(dt, nodeInfo->nbRegens))' failed
  Transform 'zl.convert_num_to_serial_le'(10) is assigned 2 streams to
  regenerate, but its signature specifies 1 streams
```

```text
Code: Corruption detected
Message: Check `dataInfo[outputStreamIdx].producerNodeIdx != ((ZL_IDType)(-1))'
  failed where: lhs = 0, rhs = 4294967295
  Graph inconsistency: regenerated stream is already assigned.
```

Note that OpenZL reports the second as `Corruption detected`. That wording is
misleading here — the bytes are not damaged. Any downstream classification that
keys on the word "corruption" will misdiagnose a version mismatch as data rot.
This cost real debugging time in the incident that surfaced this.

## Key Finding: The Error Class Distinguishes These, `format_version` Does Not

Measured against `ex_openzl 0.4.16`, on real production blocks and on
deliberately damaged frames written by 0.4.16 itself:

| Input | `frame_info/1` | decoder error class |
|---|---|---|
| Frame written by 0.4.16 | `{:ok, %{format_version: 24, num_outputs: 11}}` | decodes cleanly |
| Legacy 0.1.x block (8,343 B) | `{:ok, %{format_version: 24, ...}}` | `node is requested to regenerate an incorrect number of streams` |
| Legacy 0.1.x block (65,362 B) | `{:ok, %{format_version: 24, ...}}` | `Corruption detected` / `Graph inconsistency` |
| 0.4.16 frame, 64 payload bytes overwritten | `{:ok, %{format_version: 24, ...}}` | `Compressed checksum mismatch` |
| 0.4.16 frame truncated to one third | `{:ok, %{format_version: 24, ...}}` | `Source size too small` |
| `"not valid openzl data"` | `{:error, "failed to create frame info"}` | `failed to get number of outputs from frame` |

Two results here are load-bearing, and both contradict the obvious approach:

1. **`format_version` is 24 for both old and new frames.** The field does not
   move across this break, so it cannot be used to detect it.
2. **`frame_info` succeeding does not mean the payload is intact.** Corrupted
   and truncated frames still introspect fine, because the header survives.
   Treating "introspects but will not decode" as a version mismatch
   misclassifies genuinely damaged data as recoverable — a worse failure than
   the original bug, since it tells an operator their lost data is fine.

What does separate the cases is the **error class**. OpenZL checksums the
compressed payload, so real damage reports a checksum mismatch or a short
source, while an unreadable format reports a graph/transform topology error:
the container parsed, but the compression graph inside it could not be
interpreted.

The safe rule is therefore an allowlist, not a denylist:

- topology error (`DT_isNbRegensCompatible`, `streams to regenerate`,
  `Graph inconsistency`) **and** `frame_info` succeeds → format incompatibility
- anything else → treat as corruption

Defaulting unknown failures to corruption is deliberate. A new decoder error
that nobody has classified yet should not be reported as "your data is fine".

## Impact

Any consumer that wrote frames with `<= 0.4.6` and upgraded to `>= 0.4.7`
cannot read its own stored data. For `timeless_traces` this is fatal rather than
degraded: its libSQL migration validates every legacy page and aborts on the
first undecodable block, so the whole migration is blocked.

## Suggested Fix

Ordered by cost:

1. **Surface the condition.** Return a distinguishable error (for example
   `{:error, {:incompatible_format, version}}`) when a frame introspects
   cleanly but fails to decode, instead of an opaque decoder string. This alone
   makes every downstream diagnosis honest and is independent of the rest.
2. **Document the break.** `0.4.7` is a data-format boundary; that belongs in
   the README and CHANGELOG next to the existing 0.4.8/0.4.10 notes.
3. **Provide a read path for 0.1.x frames.** Either link a 0.1.x decoder
   alongside 0.2.0 and dispatch on the frame's `format_version`, or ship a
   one-shot transcode tool built against 0.4.6 that rewrites old frames.

Option 3 is the only route that actually recovers the data. Skipping
undecodable frames was considered and rejected — silently dropping blocks
destroys the record of which data is still in a deprecated format, which is
exactly the signal needed to retire that format safely.

## Related

- `docs/ex_openzl_0_4_13_release_artifact_bug.md` — a separate packaging and
  checksum defect in `0.4.13`, unrelated to this format break.
- `f800335 Fix small multi-typed frame compression` — investigated and ruled
  out. It returns a compress-time error on a too-small destination bound and
  never produces malformed frames.
