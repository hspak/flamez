# Flamez

Flamez is a live process-lifetime and CPU-activity flamegraph for builds and
other commands. It spawns a command in its own process group, follows
descendants, and keeps every process anchored to the wall-clock interval in
which it ran. Red slices show where each process's threads consumed CPU.

## Feaures
- Live sub-process following
- Exec process following, tracks all args
- Process thread CPU usage tracking
- Import/export trace data

## Usage
```sh
# General usage
flamez <your target program> [target program args]

# Run headless
flamez -o trace-data-output.json <your target program> [target program args]

# Load trace export
flamez -i trace-data-output.json
```

## Building

Use Zig 0.16.0, matching `build.zig.zon`. The GUI uses SDL **3.4 or newer**,
FreeType, and libpng development libraries discovered through `pkg-config`.
Linux also needs clang and libbpf development files for capture. For example,
on Arch Linux the GUI packages are `sdl3 freetype2 libpng pkgconf`.

SDL libraries are supplied by the target system; no raylib or GLFW is linked.
`SDL_RENDER_DRIVER` can select an installed SDL backend for diagnostics. Linux
prefers Wayland by default; `SDL_VIDEODRIVER` can override that preference.
Antialiasing uses geometry coverage and filtered font atlases, so the former
`-Dmsaa` option has been removed.

```sh
zig build
zig build -Dfps-counter=true  # enable builtin FPS counter
```

Native macOS builds use the SDK selected by `xcrun`. Override it with
`-Dmacos-sdk=/absolute/path/to/MacOSX.sdk`. Cross-builds without an SDK override
use the pinned framework package for Apple APIs. SDL, FreeType, and libpng still
need **macOS** headers and libraries; the framework package does not contain them.
`-Dgui-prefix=/absolute/target/prefix` selects an `include/` and `lib/` tree without
host pkg-config discovery. macOS targets Apple silicon; see [MACOS_SDL.md](MACOS_SDL.md)
for the pending native validation and packaging work.

The macOS 27 production capture validator installs separately:

```sh
zig build macos-es-live-test -Dtarget=aarch64-macos
zig-out/bin/macos-es-live-test --unsigned
```

Unsigned validation checks entitlement rejection, fixture protocols, and automatic
kqueue fallback. Run without `--unsigned` after signing the validator with an
Apple-approved Endpoint Security entitlement to check exact kernel delivery.
See [MACAPI.md](MACAPI.md#7-macos-27-validation-and-remaining-release-gates).

`macos-es-live-test --watchdog-check` deliberately blocks the main thread and must
exit with status 1 after its independent watchdog kills the fixture.

Reproduce or verify the SDK package directly from an installed macOS 27 SDK:

```sh
python3 tools/package_macos_sdk.py \
  --sdk "$(xcrun --sdk macosx --show-sdk-path)" --output /tmp/macos-sdk.tar.gz
python3 tools/package_macos_sdk.py \
  --sdk "$(xcrun --sdk macosx --show-sdk-path)" --verify /tmp/macos-sdk.tar.gz
```

To build with the local package, extract it and select its SDK root:

```sh
mkdir -p /tmp/flamez-local-sdk
tar -xzf /tmp/macos-sdk.tar.gz -C /tmp/flamez-local-sdk
zig build -Dtarget=aarch64-macos \
  -Dmacos-sdk=/tmp/flamez-local-sdk/macos-sdk-27.0-26A425
```

Use the version/build directory from your archive. Packaging and local SDK selection require
no release publication.

## Checks

```sh
zig fmt --check build.zig build.zig.zon src
zig build test
zig build test -Doptimize=ReleaseSafe -Dperf-telemetry=true -Dfps-counter=true
# Requires macOS target GUI libraries and SDK; see MACOS_SDL.md.
zig build test-compile -Dtarget=aarch64-macos -Dgui-prefix=/path/to/macos-prefix
```


## SDL migration and GUI validation

The migration follows Zimbr's `0.3.0..0.4.1` changes, especially `b914b1c`
(native SDL), `a9a7d2f` (rendering), and `12d4beb` (pacing), plus Zrct's native
SDL integration. `desktop.zig` owns window/input events; `graphics.zig` owns the
SDL renderer, nested clips, and screenshot readback; `Font.zig` owns embedded-font
atlases. Clay and the process/capture model retain their existing roles.

The application of [FRAME_PACING.md](FRAME_PACING.md) and
[PERFORMANCE.md](PERFORMANCE.md) is deliberately specific to Flamez:

- VSync plus a deadline measured from frame start follows the display's refresh
  rate (120 Hz fallback). Four startup frames and a 120 ms input burst settle
  layout. Held keys/buttons stay active; focus loss clears them. Key repeats do
  not retrigger one-shot shortcuts. Click positions survive subsequent motion
  while a frame waits, preserving hit testing and drag initialization.
- Unchanged imported/completed sessions stop drawing. SDL waits preserve queued
  events and wake on input, with a 25 ms ceiling for signal/automation/capture
  service. Capture updates run independently of whether a frame is due.
- Logical window coordinates, pixel dimensions, and stable SDL pixel density are
  separate. Pixel density scales native Wayland/Cocoa coordinates. Arbitrary X11
  content scaling is not implemented. Screenshots read the finished backbuffer
  before presentation, which invalidates its contents.
- Three 1024×1024 RGBA font atlases use 12 MiB of texture pixels plus driver
  overhead. Startup rasterizes/uploads them once; measurement allocates nothing,
  and drawing uses bounded batches of at most 256 glyphs. Clipped labels find a
  complete UTF-8 prefix in one scan. Unsupported glyphs retain `?` fallback.
- Rounded shapes use indexed coverage geometry adapted from Zimbr. SDL retains
  draw order and batches compatible submissions. There are no per-label textures,
  render-target caches, texture-retirement pools, or local Vulkan patches; measure
  a backend bottleneck before adding those lifetimes to this workload.
- The optional FPS display says `Idle` between active periods. Performance telemetry
  separates rendering wall time from active frame-start cadence; `recent` quantiles
  cover the last 64 samples, while maxima cover the session. Neither measures GPU
  completion or physical display latency.

The application-owned Zrct suites require the optional `../zrct` checkout declared
in `build.zig.zon`. Production builds do not load the driver. Use its
[`SKILL.md`](../zrct/SKILL.md) for artifact inspection and reproduction:

```sh
zig build test-zrct -Dautomation=true -- --json
zig build test-zrct-desktop -Dautomation=true -- --json
zig build bench-zrct -Dautomation=true -Doptimize=ReleaseSafe -- --warmup 2 --repeat 10
```

The first suite covers details, export/reopen, collapse/selection, zoom anchoring,
idle shortcuts, and held input during resize. The desktop suite uses real Wayland
input at 1× and 2×; it starts at 2× to keep the window inside the virtual output
when the coordinate space shrinks. Native unit tests additionally check fractional
shape scaling, clip restoration, blending, font rasterization, queued events,
focus loss, and pinch deltas. Existing raylib PNG baselines are retained as
historical references; they are not SDL pixel baselines.

Benchmarks run serially without recording or passing screenshots. Their endpoints
are completed semantic frames before presentation; startup and idle-to-details
use the small saved-session fixture. Preserve `benchmark.json`, executable hashes,
renderer identity and cache policy, and compare identical workloads. These results
do not establish large-capture throughput, native resize smoothness, or GPU latency.

Linux validation on 2026-10-03 used Zig 0.16.0 and SDL 3.4.18: Debug passed 167
tests (17 skipped), ReleaseSafe with telemetry/FPS passed 172 (12 skipped), all
six GUI scenarios passed three repetitions, and native 2×→1×→2× input passed.
The screenshot path produced a 40-frame run through SDL's software renderer.
The final serial benchmark used Weston/llvmpipe OpenGL, 1180×760 at 1×, two warmups
and ten measured samples per endpoint: startup median 171.5 ms (148.7–175.3 ms),
idle-to-details median 17.2 ms (17.1–17.4 ms). These are pre-presentation endpoints,
not a comparison with raylib. Local provenance is in
`artifacts/20261003-172829-55d99a/benchmark.json`; the instrumented ReleaseSafe
executable SHA-256 is
`6e3de9e2260d5496b8be08236bf082230844c9eb304fafe440312980a3d35933`.

Before the next release, update the separate `../../aur/flamez/PKGBUILD`: add
`sdl3>=3.4`, `freetype2`, and `libpng` runtime dependencies and `pkgconf` for the
build, and remove `-Dmsaa=false` from both build and check commands. The release
script updates versions/hashes only; it does not migrate package dependencies.
macOS release-script and Homebrew work is listed in [MACOS_SDL.md](MACOS_SDL.md).
