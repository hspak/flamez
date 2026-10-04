# Native macOS SDL validation

Flamez uses SDL3 for windows, input and rendering. Linux defaults to Vulkan;
macOS retains SDL's native renderer selection and selects **Metal** on the
validated host. `SDL_RENDER_DRIVER=software` is an explicit diagnostic fallback.
No Vulkan loader or MoltenVK dependency is needed on macOS. Clay, embedded
Inter/Roboto Mono fonts, capture, import/export and analysis retain their existing
contracts. Command-key equivalents are not added; the documented Ctrl shortcuts
remain available.

## Build and repeatable checks

Use Zig 0.16.0, a selected Xcode/Command Line Tools SDK, SDL **3.4+**, FreeType,
libpng and pkg-config. With Apple-silicon Homebrew:

```sh
brew install sdl3 freetype libpng pkgconf
pkg-config --modversion sdl3 freetype2 libpng
zig build -Doptimize=ReleaseSafe
zig build test
zig build test -Doptimize=ReleaseSafe -Dperf-telemetry=true -Dfps-counter=true
python3 -m unittest discover -s tests -p 'test_*.py'
zig fmt --check build.zig build.zig.zon src
```

Native builds use `xcrun --sdk macosx --show-sdk-path`; `-Dmacos-sdk` overrides
that selection. `-Dgui-prefix=/absolute/prefix` supplies `include/` and `lib/`
for all three GUI dependencies without host pkg-config discovery. The tree must
contain `include/SDL3`, `include/freetype2`, `include/png.h` and target libraries.
Cross-builds require those **target** libraries as well as Apple SDK files:

```sh
zig build test-compile -Dtarget=aarch64-macos \
  -Dmacos-sdk=/path/to/MacOSX.sdk -Dgui-prefix=/path/to/macos-gui-prefix
```

Run native integration checks in an unlocked desktop session with access to
WindowServer. A sandbox that hides displays produces `WindowUnavailable` and
cannot establish a native GUI pass.

```sh
zig build test-native-gui -Doptimize=ReleaseSafe
SDL_RENDER_DRIVER=software zig build test-native-gui -Doptimize=ReleaseSafe \
  -- artifacts/macos-sdl/software
FLAMEZ_SCREENSHOT=artifacts/macos-sdl/import-metal.png \
  zig-out/bin/flamez --import src/testdata/session-v1-exec-history.json
```

`test-native-gui` checks the actual Cocoa window and selected renderer, minimum
size, resize and drawable metrics, hide/show, asynchronous minimize/restore,
nested clips, alpha order, rounded corners, all three font atlases, screenshot
readback and output failure, ordered queued wheel/pinch input, focus clearing,
close and renderer-reset handling. It exercises high-density opt-in and opt-out
separately and logs the **observed** density; opt-in does not imply a 2× display.
Screenshots go to `artifacts/macos-sdl` or the directory after `--`. Input is
injected through SDL's event queue; this does not prove physical trackpad delivery.
The renderer-reset contract remains fail-and-exit, not texture recreation.

`FLAMEZ_SCREENSHOT` disables VSync and high density, uses a 60 Hz deadline and
exits after frame 40. Normal use enables VSync and high density. Font rasters
retain the 64-pixel ascent-to-descent size and the existing Latin-1/UI-symbol
coverage, with `?` fallback.

The sibling Zrct checkout is absent on this Mac. Its current desktop runner is
Linux-specific, so `test-zrct`, `test-zrct-desktop` and `bench-zrct` remain Linux
workflows. The native integration target does not depend on Zrct.

## Results recorded on 2026-10-03

Host: Apple silicon, macOS 27.0.1 (26A434), selected MacOSX 27 SDK, Zig 0.16.0,
SDL 3.4.16, FreeType 2.14.3 (pkg-config ABI version 26.6.20), libpng 1.6.59.
The available display reports 60 Hz and density 1 in both density modes.

| Validation | Result |
|---|---|
| Native ReleaseSafe build, pkg-config discovery | Passed |
| Debug unit/integration suite | 188 passed, 17 skipped, 205 total |
| ReleaseSafe suite with telemetry/FPS | 194 passed, 11 skipped, 205 total |
| Explicit `/opt/homebrew` prefix and required-ES test compilation | Passed |
| Native Cocoa/Metal integration target | Passed in Debug and ReleaseSafe |
| Native Cocoa/software integration target | Passed in ReleaseSafe |
| Imported fixture screenshot | Metal; 1180×760 PNG, visually inspected |
| Native renderer screenshots | 1000×700 PNGs; clipping, blend and glyph pixels asserted before present |
| Imported GUI idle and SIGINT shutdown | Seven frames in five seconds; clean exit; CPU time increased 0.04 s during a three-second idle sample |
| Headless kqueue capture, analysis, GUI reopen | Passed; three-process capture reopened with Metal |
| Production `macos-es-live-test --unsigned` | Passed entitlement rejection, five fixture protocols, repeated sessions and fallback; exact delivery unverified |
| Benchmark/packaging Python checks | Five tests passed; macOS benchmark regression failed before the fix and passed unchanged afterward |
| Local macOS archive | Built with a 27.0 minimum; arm64, dylib closure, signature, version and analysis checks passed; extracted copy rendered with Metal from another directory |

Artifacts are local under `artifacts/macos-sdl/`; they are not release assets.
The render benchmark ran two samples of each of `typical`, `dense` and `packed`
with the fixed ReleaseSafe binary in `benchmark/bin/flamez`. The runner now
selects Metal on macOS and Vulkan on Linux, accepts `--renderer`, and records the
selected backend and executable/fixture hashes. CPU affinity is `null` on macOS.
Each sample discards 120 frames and measures 600; raw logs and hashes are in
`metal-benchmark/result.json`. Mean frame wall times were about 8.2 ms, including
present, with substantial CPU-time variation. These runs validate the measurement
path; they do not establish GPU completion, physical presentation cadence, a
performance improvement over raylib, or ProMotion smoothness.

## Packaging policy

The macOS archive uses **installed Apple-silicon Homebrew libraries** at their
stable `/opt/homebrew/opt/{sdl3,freetype,libpng}/lib` install names. It does not
bundle dylibs. Install those runtime packages before running a downloaded archive.
Embedded Inter, Roboto Mono, Clay and zclay notices install in
`share/flamez/licenses` on every platform. The specific Roboto Mono file embedded
from Clay declares Apache 2.0 in its font metadata; its notice is retained.

Run the release script on the Arch Linux release host with an Apple-silicon SSH
builder, following the same isolated-checkout workflow as Zimbr:

```sh
./release.sh 0.2.0 --macos-host user@mac --check
./release.sh 0.2.0 --macos-host user@mac
```

Use the intended version from `build.zig.zon` and commit/push the source first.
`--check` performs the preparation, builds and checks without tagging, publishing
or editing the AUR/tap checkouts. It saves packages and prepared recipes under
`zig-out/release`. It can still install missing build dependencies. Failed runs
retain their temporary directory for inspection.

The Mac needs working non-interactive SSH authentication, a selected Xcode/Command
Line Tools SDK (`xcode-select --install` for initial setup), and Apple-silicon
[Homebrew](https://docs.brew.sh/Installation) at `/opt/homebrew`. The script checks
these prerequisites, installs missing `sdl3`, `freetype`, `libpng` and `pkgconf`
formulas, and upgrades SDL if it is older than 3.4. It reuses Zig 0.16.0 from the
Mac checkout's `.tools/zig-aarch64-macos-0.16.0`, its release cache, or `PATH`;
otherwise it downloads that version using the checksum in the official
[Zig download index](https://ziglang.org/download/index.json). Downloaded Zig lives
under `~/Library/Caches/flamez-release`.

`FLAMEZ_MACOS_HOST` is equivalent to `--macos-host`. `FLAMEZ_MACOS_REPO` defaults
to `code/flamez` relative to the Mac user's home. An existing checkout supplies
cached objects/tools; the build fetches the exact release commit into a temporary
checkout without modifying the existing working tree. If no checkout exists,
the helper clones from GitHub. Native Zig tests and package validation run on
the Mac before the archive is streamed back and verified on Linux.

`--minimum-macos MAJOR.0` (or `FLAMEZ_MINIMUM_MACOS`) sets the advertised minimum.
The default is the Mac's current major release; every linked library must support
that minimum. `--macos-archive PATH` or `FLAMEZ_MACOS_ARCHIVE` can reuse a previously
validated archive instead of SSH. To prepare one manually:

```sh
python3 tools/package_macos.py --version 0.2.0 --minimum-macos 27.0 \
  --output artifacts/flamez-0.2.0-aarch64-macos.tar.gz
python3 tools/package_macos.py --version 0.2.0 \
  --verify artifacts/flamez-0.2.0-aarch64-macos.tar.gz
```

Use the intended release version. The tool validates every non-system linked
library's architecture, install name and deployment target. It rejects undeclared
runtime dependencies and any library newer than `--minimum-macos`; it removes
build-machine rpaths, restores ad-hoc signing, checks the executable, retains
notices/schema and records provenance in `share/flamez/macos-package.json`.
The libraries installed for this validation have a macOS 27.0 minimum. Claiming
Ventura support requires separately built and validated libraries supporting
13.0; changing the executable target alone is insufficient.

`release.sh` verifies the archive's version, checksum and clean source commit
before publication. It prepares the Homebrew formula's macOS requirement and
`sdl3`, `freetype` and `libpng` dependencies from the archive. It also migrates the
AUR recipe in a temporary directory: adds SDL/font/Vulkan loader and build
dependencies, removes obsolete `-Dmsaa`, embeds the release version and installs
the font/Clay licenses. `makepkg --syncdeps` installs missing Linux dependencies
(sudo access may be needed), then builds the package and runs its checks before
tagging. The published recipe pins the downloaded GitHub source archive checksum.

The Linux host needs Zig 0.16.0, Arch's `base-devel`/`makepkg`, Git, Python 3,
Ruby, curl, file, OpenSSH and the usual GNU core utilities. Publishing additionally
requires authenticated `gh` and writable Git origins. The clean, synchronized
AUR and Homebrew checkouts default to `../../aur/flamez` and `../homebrew-tap`;
override them with `FLAMEZ_AUR_DIR` and `FLAMEZ_TAP_DIR`.
Developer ID signing, notarization, desktop GUI validation and restricted
Endpoint Security entitlements remain separate from this ad-hoc package workflow.

## Remaining physical and signed validation

The migration builds and runs natively; these checks require hardware, human
input or credentials absent from this run:

- Retina/non-Retina moves during resize, accessibility sizes, display refresh
  changes and ProMotion. Check font readability and hit testing at each density.
- Physical precise/horizontal/Shift wheel, Ctrl-wheel anchor, native trackpad
  pinch direction/magnitude, scrollbar releases outside the window, Dock/native
  close behavior, and focus changes while keys/buttons are held.
- Full GUI details, selection/copy, Ctrl-A/C/S, Ctrl-0/+/- and F5 workflows,
  clipboard exchange with another application, GUI export/reopen, Stop and quit
  during capture, and capture completion while minimized. Automated lower-level
  input/capture checks do not establish these entire interaction sequences.
- Entitled Endpoint Security delivery and set-ID validation from [MACAPI.md](MACAPI.md).
  Unsigned fallback is best effort and is not exact capture.

For pacing interpretation and broader performance work, retain the contracts in
[FRAME_PACING.md](FRAME_PACING.md), [PERFORMANCE.md](PERFORMANCE.md) and
[README.md](README.md). Capture polling remains independent of draw deadlines;
unchanged completed/imported sessions stop presenting. FPS diagnostics deliberately
request one idle frame per second. The 25 ms service bound and recent 64-sample
telemetry quantiles are not input-to-display or full-run p99 guarantees.
