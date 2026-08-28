# OmniPixelFuzzTests

Hostile and exhaustive input testing, kept apart from `OmniPixelTests` so the
everyday suite stays quick.

Two kinds of test live here, and they answer different questions:

- **`PNGConformance`** — does the decoder read the format *correctly*? Every
  colour type paired with every bit depth the spec allows it, all five row
  filters, both interlace modes, and sizes that straddle byte boundaries. The
  fixtures come from `PNGBuilder`, which implements the spec independently of
  `PNGCodec`, so a misreading mirrored in the decoder cannot hide behind a
  matching mistake in the fixture. Runs by default: deterministic, under a
  second.

- **`FuzzDecoders` / `FuzzPNGStructure`** — does the decoder *survive* bad
  input? Corrupted files are fed to every decoder. The library's contract is to
  reject bad data by throwing, so a trap — an array bounds check, an arithmetic
  overflow, a failed precondition — aborts the whole process and shows up as a
  crashed run rather than a failed expectation. That matters because much of the
  decoding hot path works through raw pointers, where the compiler cannot check
  the arithmetic. Skipped by default.

## Running the fuzz suites

```sh
swift test --filter Fuzz                        # a few seconds per case
OMNIPIXEL_FUZZ_ITERATIONS=200000 swift test --filter Fuzz    # a long session
```

In Xcode, add a test plan that sets `OMNIPIXEL_FUZZ=1` in its environment;
Xcode selects tests without passing a filter this process can see, so the
variable is the reliable switch there. The suites are tagged `.fuzz`, so a test
plan can also include or exclude them as a group.

| Variable | Effect |
| --- | --- |
| `OMNIPIXEL_FUZZ` | Enables the fuzz suites regardless of how tests were selected. |
| `OMNIPIXEL_FUZZ_ITERATIONS` | Cases per test (default 5000). |
| `OMNIPIXEL_FUZZ_SEED` | Base seed; replays a reported failure exactly. |
| `OMNIPIXEL_FUZZ_MINUTES` | Time limit per test, the backstop against a looping decoder (default 10). |

## Reproducing a failure

Every case derives its own seed from the base seed and its index, and a failure
message reports that seed. Setting `OMNIPIXEL_FUZZ_SEED` to it replays the run.

A crash gives no message, because the process is gone. The same goes for a
decoder that loops instead of rejecting: the suite time limit will fail the test,
but it cannot say which case did it. Either way, run the suites sequentially so
the last test to start is the culprit:

```sh
OMNIPIXEL_FUZZ=1 swift test --filter Fuzz --no-parallel
```

then narrow with `--filter` on the individual test name. Writing the candidate
bytes to a file just before each decode is the quickest way to capture the exact
input.

## Worth knowing

- Run the suites under AddressSanitizer from time to time. Swift's bounds checks
  do not cover raw pointer arithmetic, and the decoders use plenty of it:

  ```sh
  OMNIPIXEL_FUZZ=1 ASAN_OPTIONS=detect_leaks=0 swift test --sanitize=address --filter Fuzz
  ```

  Use SwiftPM's own `--sanitize` flag, not `-Xswiftc -sanitize=address`: the
  latter leaves the runtime to be loaded by `dlopen`, which macOS refuses. In
  Xcode, the scheme's Diagnostics tab has the same switch. Expect the run to be
  tens of times slower.

- The corpus is generated, not checked in: seeds come from the library's own
  encoders, plus the repository's `Samples/` directory for the formats that are
  decode-only (AVIF, HEIC, SVG).

- There is deliberately no per-case timer. A decoder stuck in a loop never
  returns, so nothing measured *after* a decode can ever report it, and a
  wall-clock check before it would fire spuriously whenever the machine is busy —
  which is exactly when a long fuzz session runs. Hangs are the suite time
  limit's job, and resource exhaustion is not what these suites measure.

- These are randomized tests, so a green run proves less than a green
  deterministic one. What they buy is that the space they cover grows with the
  time you give them.
