# OmniPixel

A cross-platform image library written entirely in Swift. It reads and writes the common image formats, converts between them, and offers basic editing — with **zero dependencies** beyond the Swift core libraries (Foundation's `Data`, plus Dispatch for decoding HEIC and AVIF tiles in parallel), so the same code runs on macOS, iOS and Linux.

OmniPixel is built for correctness and safety rather than raw speed: every decoder is bounds-checked and throws typed errors on malformed input, all public types are value types and `Sendable`, and the compression layers (DEFLATE, two LZW dialects, VP8L, JPEG entropy coding, HEVC CABAC, the AV1 symbol decoder) are implemented from scratch in Swift. Output is routinely validated against Apple's ImageIO and zlib in the test suite, and the HEVC and AV1 decoders were validated sample-exactly against the libde265 and dav1d reference decoders.

## Quick start

```swift
import OmniPixel

// Decode any supported format; the format is detected from the bytes.
let image = try Image(data: fileData)

// Pixels are plain 8-bit RGBA values.
let pixel = image[10, 20]              // bounds-checked subscript
let maybe = image.pixel(atX: 99, y: 0) // nil instead of a crash

// Edit.
let edited = try image
    .cropped(to: Region(x: 10, y: 10, width: 400, height: 300))
    .resized(toWidth: 200, height: 150)          // bilinear by default
    .rotated(by: .clockwise90)
    .mirrored(across: .horizontal)

// Encode — convert to any writable format.
let pngData = try edited.encoded(as: .png)
let jpegData = try edited.encoded(as: .jpeg, options: EncodingOptions(jpegQuality: 90))
```

SVG files decode through `Image(data:)` at their intrinsic size like any other format; being vector graphics, they can also be rasterized at any size:

```swift
let icon = try Image(svgData: svgFileData, width: 512)  // height follows the aspect ratio
```

Images can also be built from scratch:

```swift
var canvas = Image(width: 320, height: 200, fill: .white)
canvas[5, 5] = RGBA(red: 255, green: 0, blue: 0)
```

## Format support

| Format | Read | Write |
| --- | --- | --- |
| **PNG** | Complete: all bit depths (1–16), all color types, Adam7 interlacing, `tRNS` transparency. 16-bit samples are reduced to 8 bits. | 8-bit RGBA with per-row filter selection and real DEFLATE compression |
| **JPEG** | Baseline, extended-sequential and **progressive** Huffman coding; grayscale and YCbCr; any chroma subsampling; restart markers | Baseline 4:4:4, quality 1–100 via `EncodingOptions.jpegQuality` |
| **GIF** | 87a/89a: interlacing, local color tables, transparency. Animated GIFs decode to their first frame | Single-frame GIF89a with median-cut color quantization and 1-bit transparency |
| **TIFF** | Both byte orders; uncompressed, PackBits, LZW and Deflate strips; grayscale, RGB and palette; 8/16-bit samples; horizontal predictor; alpha | Uncompressed 8-bit RGBA (lossless, keeps alpha) |
| **WebP** | Lossless (VP8L) in full: all transforms, color cache, LZ77 | Lossless VP8L (unoptimized: literal pixels) |
| **BMP** | 8-bit palette, 24-bit and 32-bit uncompressed, top-down and bottom-up | 24-bit uncompressed |
| **QOI** | Complete | Complete |
| **PPM/PGM** | Binary (P5/P6), including 16-bit samples | Binary PPM |
| **SVG** | Rasterized with anti-aliasing (own XML parser, path flattener and scanline renderer): all shapes and path commands, transforms, groups, `defs`/`use`, `viewBox`/`preserveAspectRatio`, both fill rules, strokes with caps and joins, linear/radial gradients, opacity, inline styles, named/hex/`rgb()`/`hsl()` colors | — |
| **HEIC** | Full pure-Swift HEVC intra decoder: 4:2:0 streams incl. wavefront parallel processing, delta-QP, SAO and deblocking, **grid (tiled) images**, default and explicit scaling lists, `colr` color conversion (BT.601/709/2020, limited/full range), `irot`/`imir` orientation, odd sizes via clean aperture | — |
| **AVIF** | Full pure-Swift AV1 intra decoder: 8/10/12-bit, 4:2:0/4:2:2/4:4:4 and monochrome, lossless (Walsh–Hadamard) and lossy, screen-content tools (palette mode and intra block copy), quantizer matrices, all in-loop filters (deblocking, CDEF, loop restoration), multi-tile streams, **grid (multi-item) images**, alpha, `irot`/`imir` orientation | — |

Format detection is automatic in `Image(data:)`, or available separately via `ImageFormat(detecting: data)`.

PNG, TIFF, WebP and QOI round-trip **losslessly**, including the alpha channel. JPEG is inherently lossy; GIF is lossless only for images with at most 256 colors and hard transparency.

## EXIF metadata

OmniPixel reads EXIF from JPEG, TIFF, PNG and WebP files, and writes it into JPEG, PNG and WebP:

```swift
if let exif = EXIFData(data: fileData) {
    exif.cameraMake          // "Apple"
    exif.dateTimeOriginal    // "2026:08:19 12:34:56"
    exif.exposureTime        // EXIFRational(numerator: 1, denominator: 250)
    exif.gpsLatitude         // 47.375 (decimal degrees; negative = south)
    exif.tags[EXIFTag.artist]?.stringValue  // any tag, by number
}

// Carry metadata over when converting or re-encoding:
let output = try image.encoded(as: .jpeg, options: EncodingOptions(exif: exif))
```

All tags are exposed — three dictionaries (`tags`, `photoTags`, `gpsTags`) keyed by tag number, with typed convenience accessors for the common ones. Values preserve their TIFF storage type, so metadata round-trips faithfully.

**Orientation is applied automatically.** Camera files usually store pixels unrotated plus an EXIF orientation tag; `Image(data:)` applies it, so decoded pixels are always upright (matching what browsers and ImageIO do). When embedding EXIF, the orientation tag is reset to upright accordingly — no double rotation.

## Editing operations

- `resized(toWidth:height:method:)` and `scaled(by:method:)` — nearest-neighbor or bilinear (default) sampling
- `cropped(to: Region)`
- `rotated(by:)` — quarter turns (`.clockwise90/180/270`), lossless
- `mirrored(across:)` — `.horizontal` (left/right) or `.vertical` (top/bottom)
- `oriented(by:)` — applies an `EXIFOrientation` manually

## Error handling

Everything that can fail throws `ImageError`:

- `.unknownFormat` — the data matches no known format
- `.invalidData(reason:)` — recognized format, malformed content
- `.unsupportedFeature(reason:)` — valid file using a feature OmniPixel doesn't implement (the reason string says exactly which)
- `.invalidDimensions`, `.regionOutOfBounds` — bad operation arguments

Decoders never crash on malformed input: all reads are bounds-checked, sizes are sanity-capped, and arithmetic is overflow-checked.

## Demo app

The package includes **OmniPixelViewer**, a small SwiftUI image viewer for macOS that exercises the library end to end: it opens any supported format (file picker or drag & drop), decodes it with OmniPixel's own codecs, shows the detected format and EXIF metadata, offers rotation, mirroring, scaling and cropping, and re-encodes to any writable format (with a JPEG quality slider) for export. The platform frameworks are only used to draw the finished pixels.

```sh
swift run OmniPixelViewer
```

On non-Apple platforms the executable builds but just prints a note — the viewer's interface is SwiftUI.

## What's missing

Known gaps, all reported as explicit `unsupportedFeature` errors where they apply:

- **HEIC**: encoding (requires an H.265 encoder); 4:4:4 chroma (produced by Apple encoders at quality 1.0 — use ≤ 0.95), HEVC tiles, PCM and dependent slices. The intra decoder was validated sample-exactly against a reference HEVC decoder; the final RGB output can differ from other decoders by small amounts because chroma upsampling filters are not standardized.
- **AVIF**: encoding (requires an AV1 encoder); super-resolution and film grain synthesis (not produced by still-image encoders). The decoder was validated sample-exactly against dav1d on every plane across qualities, speeds, bit depths, chroma formats and screen-content coding (palette and intra block copy); RGB output can differ from other viewers by small amounts because chroma upsampling filters are not standardized.
- **Lossy and animated WebP** (VP8 coding; only lossless VP8L is supported).
- **Animated GIF** beyond the first frame (no multi-frame API yet).
- **JPEG**: arithmetic coding, 12-bit precision, lossless/hierarchical modes (all rare in practice).
- **SVG**: text, embedded images, CSS stylesheets/selectors, patterns, clip paths, masks, filters, markers and dashed strokes are skipped; group opacity is approximated by multiplying it into each shape.
- **TIFF**: tiled or planar layout, CCITT/JPEG-in-TIFF compression, EXIF _embedding_ (reading works).
- **Pixel depth**: images are always 8 bits per channel in memory; 16-bit sources are reduced on decode.
- **Color management**: pixel values are passed through as-is; ICC profiles are ignored.

## Design notes

- `Image` is a `Sendable` value type: a width, a height and a row-major `[RGBA]` buffer. Copies are cheap thanks to copy-on-write.
- Sub-byte bit readers/writers, Huffman coding (canonical tables, plus package-merge for length-limited codes), CRC-32, Adler-32, DEFLATE (both directions), GIF-LZW, TIFF-LZW and VP8L are all independent, reusable internal components.
- The test suite (79 tests) covers round-trips for every codec, hand-built reference files for edge cases, standard checksum test vectors, and — on Apple platforms — interoperability checks against ImageIO and zlib in both directions.

## License

Apache License 2.0 — see <LICENSE.txt> and <NOTICE.txt>.
