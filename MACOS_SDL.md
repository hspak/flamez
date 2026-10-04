# Native macOS SDL follow-up

The Linux migration replaces raylib/GLFW with SDL3 rendering and events while
retaining Clay, embedded Inter/Roboto Mono fonts, capture shims, import/export,
and analysis. macOS code is best effort until the checks below run on Apple
silicon. No Cocoa/Metal runtime result is claimed from this Linux host.

## Build and packaging

Use Zig 0.16.0, a selected Xcode SDK, SDL **3.4+**, FreeType, libpng, and pkg-config.
Install the target's development packages, then verify discovery on the Mac:

```sh
pkg-config --modversion sdl3 freetype2 libpng
zig build -Doptimize=ReleaseSafe
zig build test
zig build test -Doptimize=ReleaseSafe -Dperf-telemetry=true -Dfps-counter=true
```

Native builds retain `xcrun --sdk macosx --show-sdk-path`. `-Dmacos-sdk` overrides
that SDK. `-Dgui-prefix=/absolute/prefix` instead supplies `include/` and `lib/`
for all three GUI dependencies without pkg-config; the prefix must contain
`include/SDL3`, `include/freetype2`, `png.h`, and the target libraries. FreeType
and libpng's own dynamic dependencies must also be resolvable on the target.
Zrct receives the same SDL headers/library, avoiding a second SDL instance.

Linux cross-build attempt: `zig build test-compile -Dtarget=aarch64-macos` stopped
at missing target `SDL3`, `freetype`, and `png16` libraries. The bundled Apple
framework package covers Apple APIs only. Host pkg-config found Linux headers;
those are not a valid cross-build environment. With a complete target tree:

```sh
zig build test-compile -Dtarget=aarch64-macos \
  -Dmacos-sdk=/path/to/MacOSX.sdk -Dgui-prefix=/path/to/macos-gui-prefix
```

Before release, inspect `otool -L zig-out/bin/flamez`, deployment targets,
architecture, install names and rpaths. Decide whether the distribution requires
installed packages or bundles dylibs; retain SDL, FreeType, libpng and embedded
font notices if bundling. Revisit signing/notarization after changing linkage.
The former raylib SDK path patch and `-Dmsaa` option are removed. No local Vulkan
renderer patch is included. Let SDL select Metal normally; record its selected
backend and version from startup logs, and exercise an available fallback.

`release.sh` currently cross-builds `aarch64-macos.13.0` without a target GUI prefix
and packages only the executable/schema. Before using it, supply the target SDK
and GUI dependency paths, verify the minimum supported macOS version against
those libraries, and implement the chosen dylib packaging/rpath policy. The
separate `../homebrew-tap/Formula/flamez.rb` currently declares no GUI-library
dependencies. Add `sdl3`, `freetype`, and `libpng` if using Homebrew's libraries,
or validate the bundled alternative. Updating only release versions/checksums
will not make this SDL binary distributable. No release was published here.

## Window, input and rendering

- Launch an imported fixture without capture privileges. Check the title,
  760×520 minimum, resizing, hide/show, minimize/restore, native close, Escape,
  focus changes and Dock behavior. SDL initialization, event processing,
  renderer/texture ownership, and shutdown remain on the main thread.
- Move between Retina/non-Retina displays, including during resize. Window
  coordinates drive Clay/hit testing; stable `SDL_GetWindowPixelDensity()` scales
  them to pixels. Verify actual Cocoa density behavior and screenshots at each
  scale. Framebuffer dimensions are independently observed for redraws.
- Check rounded corners, thin outlines, alpha, nested scissor restoration, selected
  bars, CPU plots, details, hover tooltips and all three fonts. Font rasters are
  generated once at a 64-pixel ascent-to-descent height and filtered when drawn;
  assess readability at 1×, 2× and larger accessibility sizes. Glyph coverage is
  intentionally the former Latin-1 plus UI-symbol set, with `?` fallback; no
  shaping/emoji expansion is part of this migration.
- Verify precise wheel deltas, horizontal/Shift scrolling, Ctrl-wheel anchored
  zoom, trackpad pinch direction and magnitude, scrollbar dragging and releases
  outside the window. SDL 3.4 pinch updates accumulate logarithmic zoom deltas.
  Linux injected pinch tests do not establish native Mac trackpad delivery.
- Check Ctrl-S export, Ctrl-C/Ctrl-A details selection, Ctrl-0/+/- zoom and F5
  Clay debug. Ctrl shortcuts are preserved; decide separately whether to add
  Command equivalents to match native conventions. Verify clipboard exchange
  with another application and focus loss while keys/buttons are held.
- `FLAMEZ_SCREENSHOT=/tmp/flamez.png` uses a fixed 60 Hz clock, disables VSync and
  high-density opt-in, and exits after frame 40. Capture occurs before present;
  verify PNG dimensions/orientation and failure diagnostics. Normal UI uses
  high density and VSync. SDL render-device reset currently reports an error and
  exits; test whether Metal/device transitions need a texture-recreation path.

## Frame pacing and capture

Review [FRAME_PACING.md](FRAME_PACING.md) and [PERFORMANCE.md](PERFORMANCE.md)
alongside the concrete Flamez adoption notes in [README.md](README.md).

- Measure 60 Hz and ProMotion displays, refresh/display changes, rapid width and
  height resize, held modifiers beyond 120 ms, drag/scroll, idle wakeups and
  minimize/restore. SDL's reported display cadence sets the minimum frame-start
  interval, with a 120 Hz fallback. A successful VSync request is not proof that
  every present blocks. Drawing/presentation time already counts toward the
  deadline; overdue frames incur no additional full-interval sleep.
- Confirm unchanged imported/completed captures stop presenting. A visible FPS
  diagnostic deliberately requests one idle frame per second and displays `Idle`.
  SDL waits retain events, cap service delay at 25 ms, and use a separate delay
  for sub-millisecond remainders. These are scheduling bounds, not guaranteed
  input-to-display latency. Measure macOS idle CPU and timer wake behavior.
- Preserve the backend's capture lifecycle: run live kqueue/libproc capture and
  signed/unsigned Endpoint Security validation from [MACAPI.md](MACAPI.md).
  Exercise target completion while minimized, Stop, quit while capturing, import,
  GUI export/reopen and headless `-o`/analysis. Capture polling is independent of
  frame deadlines, and a final capture update stays pending until drawn.
- Benchmark a fixed ReleaseSafe executable with matching fonts, renderer,
  dimensions and fixture. Separate draw/present work, frame-start intervals,
  process CPU and physical presentation evidence. Current telemetry reports
  recent 64-sample quantiles, not full-run p99 values. Linux software-compositor
  timings cannot establish Metal performance or ProMotion smoothness.

The local Zrct runner provisions Linux tools, so `test-zrct`,
`test-zrct-desktop`, and `bench-zrct` are Linux-host workflows today. Native SDL
instrumentation can be built on macOS, but first validate its Unix socket,
clipboard, screenshot and shutdown behavior with a Mac-capable harness. Record
all native results and remaining issues here rather than treating Linux passes
as macOS validation.
