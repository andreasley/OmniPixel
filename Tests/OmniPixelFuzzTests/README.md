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
| `OMNIPIXEL_FUZZ_ITERATIONS` | Cases per test (default 5000), split across one shard per CPU core. |
| `OMNIPIXEL_FUZZ_SEED` | Base seed; replays a reported failure exactly. |
| `OMNIPIXEL_FUZZ_MINUTES` | Time limit per test. Defaults to `max(30, iterations / 100)`, so raising the budget does not fail the run. |

## Reproducing a failure

Every case derives its own seed from the base seed and its index, and a failure
message reports that seed. Setting `OMNIPIXEL_FUZZ_SEED` to it replays the run.

A crash gives no message, because the process is gone. The same goes for a
decoder that loops instead of rejecting: the suite time limit will fail the test,
but it cannot say which case did it. Either way, run the suites sequentially so
the last test case to start is the culprit — and since each case is one shard,
that also narrows the search to every Nth iteration:

```sh
OMNIPIXEL_FUZZ=1 swift test --filter Fuzz --no-parallel
```

then narrow with `--filter` on the individual test name. Writing the candidate
bytes to a file just before each decode is the quickest way to capture the exact
input.

## Worth knowing

- Each test splits its iterations into one shard per CPU core, run as parallel
  test cases — Swift Testing's pool is exactly core-wide, so this saturates the
  machine without oversubscribing it. The shards stride the same global
  iteration indices whatever the core count, so the cases a run covers, and
  what a reported seed means, are identical on every machine.

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

- The time limit is advisory. Swift Testing records an issue when it expires but
  cannot interrupt a synchronous test body, so a decoder genuinely stuck in a
  loop will log the issue and then keep the run wedged; a job timeout is what
  actually stops it. The limit scales with the budget precisely so that a long
  deliberate run does not trip it — if you see it fire, check the iteration
  count before suspecting the library.

- There is deliberately no per-case timer either. A decoder stuck in a loop
  never returns, so nothing measured *after* a decode can report it, and a
  wall-clock check would fire spuriously whenever the machine is busy — which is
  exactly when a long fuzz session runs.

- Cost per case varies enormously by format. Decoding a mutated BMP is
  microseconds; a mutated AVIF or HEIC runs a full AV1 or HEVC decoder, which is
  why `mutatedSampleFilesNeverCrash` takes a tenth of the budget. Keep input
  *generation* out of the loop: seeds are encoded once and reused, since
  encoding a PNG costs far more than decoding the corrupted result.

- These are randomized tests, so a green run proves less than a green
  deterministic one. What they buy is that the space they cover grows with the
  time you give them.
