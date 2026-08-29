# Unsafe-code audit, August 2026

An audit of every codec plus the compression layer, prompted by the question
of whether the performance work — in particular the move to raw pointers in
the hot paths — had increased the risk of memory-unsafe behaviour on hostile
input. All decoders were treated as processing attacker-controlled data.

Everything recorded here has been fixed. The regression tests live in
`Tests/OmniPixelTests/HostileInputTests.swift`.

## Summary

**The unsafe code was not where the risk was.** Every raw-pointer region was
verified in bounds, and verified empirically rather than only by reading: the
audit built AddressSanitizer harnesses, confirmed they caught deliberately
injected off-by-one bugs, and then found nothing. What the audit did find were
ten reachable crashes and a dozen amplification problems, all in ordinary
bounds-checked Swift — where the consequence is a trap or an out-of-memory
abort rather than corruption.

That distinction rests on the package building without `-Ounchecked` and
without `unsafeFlags`. Array subscripts therefore still trap, and that is what
contained the damage from every finding below. Enabling `-Ounchecked` would
silently convert this whole class of bug into memory corruption.

| Category | Found | Status |
| --- | --- | --- |
| Memory-unsafe behaviour in raw-pointer code | 0 | — |
| Reachable traps / stack exhaustion (denial of service) | 10 | fixed |
| Memory or CPU amplification | 12 | fixed |
| Latent unsafe-code fragility | 3 | hardened |
| Correctness (wrong pixels, not a safety issue) | 1 | fixed |

## What was verified safe

The raw-pointer work is concentrated in five places, audited individually:

- **`Inflate.swift`** — the hand-managed `UnsafeMutablePointer` output window,
  including the back-reference copy and the overlap-doubling optimization.
  ~250k inflate cases under ASan, zero reports. The reallocation ordering is
  correct: `storage` is re-read from `self` after every `reserve`, so no stale
  pointer survives a growth, which is the classic mistake in this shape of
  code. The back-reference guard correctly validates `distance` against
  `output.count` — bytes actually written — rather than against capacity.
- **`Deflate.swift`** — the `loadUnaligned` 4- and 8-byte loads in the match
  finder. The 8-byte loads are bounded by `maxLength`, not by the 4-byte
  `position + 4 <= count` guard, which would have been insufficient. Hash and
  chain indices are provably in range; `candidate < position` holds because
  insertions are strictly increasing.
- **`PNGCodec.swift`** — the unfilter loop's `rawBase`/`pixelBase`/`zeroBase`
  pointers and the row-expansion writes. The Adam7 geometry was brute-forced
  over bits-per-pixel 1…64 × width, height 1…299: `zeroRow` is sized for the
  widest pass, and every `y * width + x` destination is in range. 360k fuzz
  iterations with 223k successful decodes, zero ASan reports.
- **`JPEGEncoder.swift`** — the temporary DCT allocation, the growable output
  buffer, and the `nonisolated(unsafe)` pointers shared across
  `concurrentPerform`. Each concurrent unit writes a disjoint range, the last
  chunk is short rather than long, and nothing escapes its
  `withUnsafeMutableBufferPointer` closure because `concurrentPerform` is
  synchronous. TSan clean.
- **`AV1LoopFilters.swift` / `AV1Reconstruction.swift`** — the deblocking taps,
  the CDEF fast path, loop restoration, and the tuple-backed scratch buffers.
  The `isTxEdge` argument holds: `txWidth >= filterSize` with both powers of
  two means a transform edge is always at least `filterSize` from the plane
  boundary, so the ±7 tap span stays inside the superblock-aligned allocation.
  ~56k mutated AVIF decodes under ASan, 240 concurrent grid decodes under
  TSan, zero reports.

The 30-plus `@exclusivity(unchecked)` properties in the AV1 decoder were also
checked, since that attribute turns an overlapping-access diagnostic into
undefined behaviour. No aliasing `f(&x, &x)` pattern exists, there is no
nested pointer scope on the same array, and the scratch buffers are per
instance rather than static. Concurrency is safe because `concurrentPerform`
decodes one independent *frame* per grid tile; tiles within a frame decode
serially.

## Reachable crashes

Ten inputs caused a trap or stack exhaustion. Five were reproduced with actual
crashing files during the audit.

### SVG

| Site | Defect | Fix |
| --- | --- | --- |
| `SVGRasterizer.swift` bounding box | `Int(minY.rounded(.down))` ran before the clamp, and `Int(_:)` traps on non-finite input, on anything outside `Int`'s range, and on the untouched sentinels left when every edge had a NaN coordinate | Reject bounding boxes that miss the canvas, then convert through `pixelIndex`, which clamps in floating point |
| `SVGRasterizer.accumulateSpan` | The epsilon that keeps a span off the next pixel selected the pixel *before* the start for a span narrower than the epsilon, indexing `coverage[-1]` | `endPixel` is floored at `startPixel` |
| `SVGCodec.pixelSize` | `Int(deviceWidth.rounded())` was unchecked, and aspect-preserving shrink bounds only the *product*, so one side could still exceed `Int.max` | Clamp each side in floating point before converting |
| `SVGXML.parseElement` / `SVGScene.render` | Unbounded element nesting overflowed the stack — a signal, not a catchable error, so no amount of `throws` discipline elsewhere helps | Depth limit of 64 in both the parser and the renderer |

The recursion limit is 64 rather than something larger because the library may
be called from a Swift concurrency task, whose stack is a fraction of the main
thread's. A limit of 256 parsed fine on the main thread and still overflowed
inside the test runner. Real artwork rarely passes a dozen levels.

### HEVC

- **`HEVCReconstruction.swift`, negative quantization parameter.**
  `cu_qp_delta_abs` was unbounded, so its Exp-Golomb escape could reach about
  ±8000. Because Swift's `%` takes the sign of the dividend,
  `(predictedQGQP + delta + 52) % 52` then went negative and
  `[40, 45, 51, 57, 64, 72][qp % 6]` indexed with it. Fixed by enforcing the
  spec's −26…25 range on the delta, which makes the modulo provably 0…51. The
  slice QP was already validated; only the delta was missing.
- **`HEVCReconstruction.swift`, picture dimensions.** The SPS never checked
  that the dimensions are integer multiples of `MinCbSizeY` as 7.4.3.2
  requires. The coding quadtree only tests whether a child's *origin* is
  inside the picture, so a 12×12 picture with `MinCbSizeY = 8` produced 8×8
  coding units that overhang it, and reconstruction wrote past the end of the
  plane — silently corrupting earlier rows before trapping. The same input
  class also drove an out-of-range `modeGrid` read in the slice decoder and
  the out-of-range chroma clamp in `HEICCodec.convertToRGB`. One check in the
  SPS fixes all three, and it also guarantees even dimensions, which the
  chroma planes' truncating division had been assuming.
- **`HEVCLoopFilters.swift`, edge coordinate packing.** Deblocking edges were
  packed as `(x << 16) | y`, which aliases `y` into `x`'s field once the
  picture is 65536 samples tall. An 8×131072 picture is about a megapixel and
  entirely legal, and it produced a negative `qpGrid` index. Fixed by storing
  coordinate pairs instead of packing.

### Containers and JPEG

- **`HEIFContainer.itemData`.** `baseOffset + extent.offset` and
  `start + length` are sums of 64-bit file fields, so they overflowed and
  trapped before the range check could look at them. Now uses
  `addingReportingOverflow` and compares as `length <= source.count - start`.
- **`JPEGCodec.swift`.** Coefficients were never bounded, so magnitude
  category 15 combined with a progressive scan's point transform (Al up to 13)
  produced values around 2^28. With a 16-bit quantization table,
  `coefficient × quantizer × idctTable` accumulated past `Int.max` inside the
  inverse DCT. Fixed on both sides: quantization values are held to the
  spec's 1…255 for 8-bit precision, and coefficient magnitudes to 32767.

## Amplification

The library's central resource guard is `Image.maxPixelCount` (2^28). Two
findings defeated it outright and the rest turned small inputs into very large
working sets.

**SVG bypassed the pixel budget entirely.** The clamp was applied to
`deviceWidth * deviceHeight`, but `pixelHeight` was then raised with
`max(1, …)`, so `<svg width="1e9" height="0.5">` yielded a
732,714,755 × 1 image — 2.7× over the limit, measured at 2.94 GB — scaling
linearly with the width attribute. Fixed by clamping each side and then
trimming the product.

**AV1 bypassed it too**: `frame_size_override_flag` re-read the frame
dimensions with no check against the sequence header, so a sub-200-byte file
could ask for 65536×65536. The spec requires the frame to fit inside the
sequence header's maximum, and that is now enforced.

Other measured or computed amplification, all now bounded:

| Site | Input → cost | Fix |
| --- | --- | --- |
| SVG Bézier flattening | 123 bytes → 2.09 GB, 12.7 s | Per-path point budget; flattening stops when it is spent, which bounds the subdivision work too |
| SVG stroke joins | 80 KB → 10.09 GB, 106 s | Segment count per circle capped; outline point budget |
| SVG `use` expansion | ~1.25 KB → ~10^12 shapes | Traversal visit budget, separate from the geometry budget because a `use` chain that bottoms out at the depth limit draws nothing and so spends no geometry |
| AV1 per-tile decoders | 4096 tiles × 4096² frame → 73 GB | `decodeFrame` keeps only the restoration units, so memory scales with frame area rather than tiles × frame area |
| AV1 tile count | Non-uniform spacing ignored `MAX_TILE_COLS/ROWS` | 64 enforced in both dimensions |
| AV1 frame working set | 2^28 samples → ~10 GB | Frame area capped at 2^26 (8192×8192); planes hold an `Int` per sample and CDEF and restoration each keep a further copy alive, so the real cost is ~24 bytes per luma sample against the finished image's 4 |
| HEIF item assembly | 1 MB → ~4 GB (4096 extents × whole file) | Total assembled item capped at 256 MB |
| WebP prefix groups | 780 KB → ~650 MB | Group count bounded by the meta-block count instead of by the largest 16-bit value in the meta image |
| DEFLATE output | ~158× expansion before the caller checks the size | Output ceiling in the window itself; PNG passes the exact size from its header |
| GIF / TIFF / QOI reservations | Up to 2 GiB reserved from header fields before validating any payload byte | Bounded initial reservation; growth is amortized anyway |

## Latent unsafe-code fragility

Not exploitable as written, but each was one refactor away from a heap bug —
so these are the real answer to "does the unsafe code increase risk":

- **`InflateWindow` was a copyable struct owning a raw pointer with no
  `deinit`.** Correct only because it was private and used as a single `inout`
  local; any future copy would have been an immediate double free. Now
  `~Copyable` with a `deinit`, which also removes the need for the manual
  `release()` on throw paths.
- **`JPEGBitWriter.finish()` left `buffer` dangling** with `capacity = 0`, so a
  second `finish()` or any later `write()` would take the grow path and
  deallocate freed memory. Held off only by a call-once convention. `finish()`
  is now idempotent, and `grown` treats zero capacity as "already released"
  instead of freeing again — the check sits in `grown` rather than `write` so
  it stays off the hot path.
- **The bit writer's 8-byte headroom was exactly tight** (4 drained bytes plus
  4 stuffing bytes for at most 27 new bits). Widening the coefficient clamp or
  admitting a Huffman code longer than 16 bits would have turned it into a
  heap overflow with no release-mode assertion. Now asserted.

## Correctness

`AV1LoopFilters.swift` had the self-guided restoration weights swapped
relative to spec 7.17.3: `parameters[2]` is the spec's `w2`, but it was used
as the weight of the unfiltered sample `u`, while the derived
`128 - w0 - parameters[2]` — the spec's `w1` — weighted `flt1`. Wrong output
pixels wherever SGR ran with both radii non-zero. Not a safety issue.

## Residual risk

- **The rasterizer's per-scanline cost grows with the number of edges active
  at once.** A very wide stroke makes every outline polygon span the whole
  canvas, so they all stay in the active set. The stroke budget is set with
  that in mind, which is why it is much lower than the fill-side budget, but
  adversarial input is still slower than ordinary artwork of the same size:
  the worst case measured went from 106 s to about 6 s, not to nothing.
- **`maxPixelCount` is 2^28, so a legitimate maximum-size request is a 1 GB
  allocation.** That is by design, but it means "bounded" is not the same as
  "small", and callers under memory pressure should impose their own limit.
- **The AV1 and HEVC decoders assume 8-bit sample precision** in places
  (`HEVCReconstruction` hardcodes the dequantization shift). The QP range
  check added here uses the 8-bit range accordingly. A 10-bit HEVC stream is
  not rejected outright and would decode to wrong values; that is pre-existing
  and out of scope for this audit.
- **A single upstream guard protects several downstream lookups.** The 4:2:2
  block-size check in `AV1TileDecoder.decodeBlock` is what keeps
  `planeTxSize`, `allZeroCtx` and the intra block-copy path from indexing with
  `ss_size_lookup`'s `BLOCK_INVALID` sentinel. That is deliberate — one
  authoritative check beats four scattered ones — but it is an invariant a
  future change could break silently, so
  `HostileInputTests.av1SubsampledSizeIsUndefinedForTallBlocksIn422` pins the
  table shape it depends on.

## Notes for further fuzzing

Three areas random mutation is unlikely to reach on its own:

1. **AVIF profile 2 specifically.** That is the only door to 4:2:2, and the
   4:2:2 table entries were the most severe AV1 finding. Reaching it requires
   the profile field to be exactly 2, which mutation hits rarely.
2. **Extreme aspect ratios rather than extreme pixel counts.**
   `width="1e9" height="0.5"` is the shape that walked past `maxPixelCount`;
   fuzzers that scale both dimensions together never produce it.
3. **HEVC SPS dimensions** that are not multiples of `MinCbSizeY`, or that
   exceed 65536 in one axis.

Also worth noting: the amplification findings and the stack-exhaustion
findings do not surface as catchable errors. A 10 GB allocation and a
`SIGSEGV` from stack overflow both look like a hung or killed process, not a
test failure, so the harness needs resident-memory and wall-clock limits to
score them at all.
