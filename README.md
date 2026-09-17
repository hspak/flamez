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

Use Zig 0.16.0, matching `build.zig.zon`.

```sh
zig build
zig build -Dfps-counter=true  # enable builtin FPS counter
zig build -Dmsaa=true         # enable MSAAx4
```

Native macOS builds use the SDK selected by `xcrun`. Override it with
`-Dmacos-sdk=/absolute/path/to/MacOSX.sdk`. Cross-builds without an SDK override
use the pinned framework package. macOS targets Apple silicon.

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
zig build test-compile -Dtarget=aarch64-macos
```
