# Flamez

Flamez is a live process-lifetime and CPU-activity flamegraph for builds and
other commands. It spawns a command in its own process group, follows
descendants, and keeps every process anchored to the wall-clock interval in
which it ran. Red slices show where each process's threads consumed CPU.

The current vertical slice includes:

- argv-preserving target launch and whole-process-group cancellation;
- live elapsed/process/active counters;
- a scrollable, hoverable process tree with normalized lifetime bars and red
  self-CPU slices whose height fills the row at 75% of host logical cores,
  including CPU time and average-core metadata;
- a selected-process detail pane with a full-lifetime thread CPU graph, an
  independent session-time axis, and the existing process metadata below it;
- Linux `sched_process_fork`, `sched_process_exec`, and
  `sched_process_exit` eBPF raw tracepoints delivered through a ring buffer,
  plus map-based `sched_switch` CPU accounting;
- responsive Clay layout rendered with raylib.

## Build and run

The project currently targets Zig 0.16.

An optional green FPS counter can be compiled into the footer beside **FLAMEZ** with:

```sh
zig build -Dfps-counter=true
```

An optional one-line-per-second performance summary (plus a session total) is
compiled in with `-Dperf-telemetry=true`. Use it on an installed ReleaseSafe
build when capturing a baseline; it is off by default.

Build with `zig build`, then install the executable and BPF object with the
narrow capabilities required for tracing:

```sh
./build.sh
/usr/local/bin/flamez <target> [target args...]
```

To install a ReleaseSafe build with the counter enabled, pass the option
through the installer:

```sh
./build.sh -Dfps-counter=true
```

`build.sh` installs under `/usr/local` by default. Set `FLAMEZ_PREFIX` to use
another installation prefix (the destination must support Linux file
capabilities):

```sh
FLAMEZ_PREFIX="$HOME/.local" ./build.sh
```

Run the unit tests with:

```sh
zig build test
```

Compile the complete application and both test roots for macOS without running
the cross-built tests with:

```sh
zig build test-compile -Dtarget=aarch64-macos
```

Apple-silicon macOS (`aarch64-macos`) now has a best-effort live collector using
a dedicated kqueue worker, 4 ms recursive libproc recovery scans,
target-process-group recovery, fork-triggered immutable-parent identity scans,
and cumulative per-process CPU accounting. Its pending lifecycle queue has a
16 MiB budget and reports overflow as dropped capture data. It requires no
special entitlement and retains copied metadata for children that exit before
the next GUI frame.
Targets start suspended and resume only after the root kqueue filter is
registered, eliminating the initial spawn race. A whole later branch shorter
than one worker scan can still be missed;
[MACAPI.md](MACAPI.md) documents that limitation. On macOS 27, Flamez dynamically
prefers the exact descendant-scoped Endpoint Security backend when its signed
binary has Apple's restricted client entitlement; older or unsigned builds fall
back automatically. The footer labels only the fallback `CAPTURE · BEST EFFORT`,
even when no explicit local failure was counted. When the root exits, the exact
path uses an Endpoint Security queue barrier and the fallback joins its worker
before Flamez performs one final CPU snapshot and closes surviving descendants.

An Apple-approved Endpoint Security identity can validate the exact macOS 27 path without risking
a silent fallback:

```sh
zig build -Dtarget=aarch64-macos -Dmacos-require-endpoint-security=true
codesign --force --options runtime \
  --entitlements macos.entitlements \
  --sign "<Apple-approved signing identity>" \
  zig-out/bin/flamez
zig-out/bin/flamez /usr/bin/true
```

The included plist is only a signing input; Apple must grant the restricted entitlement to the
identity. See [MACAPI.md](MACAPI.md) for runtime and packaging details.

For example:

```sh
/usr/local/bin/flamez zig build -Doptimize=ReleaseFast
/usr/local/bin/flamez make -j8 all
/usr/local/bin/flamez -o capture.json -- make -j8 all
/usr/local/bin/flamez --output=- make -j8 | jq .
/usr/local/bin/flamez -i capture.json
/usr/local/bin/flamez -a capture.json
cat capture.json | /usr/local/bin/flamez -i -
```

Flags precede the target, and `--` ends Flamez flag parsing. With no mode flag,
Flamez opens the GUI and immediately launches the target with the remaining
arguments unchanged—there is no intermediate shell and no command-entry UI.
`-o`/`--output` captures without initializing a window, atomically replaces a
named output after a successful write, and exits 0, 1, 2, 3, or 4 for success,
Flamez failure, usage error, incomplete capture, or target failure respectively.
When output is `-`, Flamez writes only session JSON to stdout and routes the
target's stdout to stderr so pipelines stay valid.

`-i`/`--import` streams a finished session from a path or stdin and opens it in
the GUI without initializing the platform collector or requiring Linux BPF
capabilities. Import is always explicit: a bare `capture.json` remains a target
command. After any capture finishes, or after import, **Ctrl+S** saves to
a filename derived from the target argv, such as
`flamez-zig-build-doptimize-releasefast.json`. Filename components are
lowercase and hyphen-delimited, the target-derived stem is capped at 50
characters, and the next available numeric suffix is used without replacing an
existing automatic save.

`-a`/`--analyze` validates a session file and atomically writes a compact
performance-debugging view beside it as `analyzed-<filename>`. The analysis
surfaces process dependency chains, CPU and wall-time bottlenecks, bounded
command previews, subtree CPU totals, and conservative I/O/wait candidates.
It requires neither a window nor a collector. See [ANALYSIS.md](ANALYSIS.md)
for the derived format and heuristic definitions.

Press **Stop** to terminate the target process group. F5 toggles Clay's layout
inspector. Use the arrow button in the timeline header to collapse or expand
every row, or the matching button in the left gutter to toggle one row. For
packed rows, the one button toggles the children of every top-level process
block on that row, reducing a collapsed row to one block in height. Capture
ends when the target process exits; descendants that outlive it do not extend
the trace. If the kernel drops lifecycle records, the session is marked
**INCOMPLETE** and recovered rows are labeled as inferred rather than observed.
Completed frames continue to render at the display refresh rate. The default
renderer keeps both high-DPI framebuffers and 4x MSAA enabled for readable text.
Build with `-Dmsaa=false` to disable MSAA when the extra GPU cost is not
acceptable.

Timeline zoom shortcuts mirror Ctrl+mouse-wheel zoom: **Ctrl+=** zooms in,
**Ctrl+-** zooms out, and **Ctrl+0** restores the full default view.
Trackpad taps activate the same controls as a left click. Pinch gestures zoom
around the pointer; compositors that expose pinch as Ctrl+trackpad-scroll use
the same zoom path. When zoomed, **Shift+mouse-wheel** pans horizontally; the
timeline's bottom and right scrollbars can also be dragged. Without Ctrl or
Shift, the wheel scrolls rows. In the timeline, **Up/Down**, **Page Up/Page
Down**, **Home**,
and **End** provide keyboard row navigation; **Left/Right** collapse or expand
the selected process when it has children.

Selecting a process opens its detail pane. The pane contains the process's
full-lifetime CPU graph and metadata, supports its own scrollbar and
mouse-wheel/Page Up/Page Down/Home/End navigation, and allows text selection.
With the detail text focused, **Ctrl+A** selects all metadata and **Ctrl+C**
copies the selection to the clipboard.

On Linux v7 or newer, the build always enables the eBPF collector and needs `clang`,
libbpf headers, and libbpf at link time. Capture is mandatory: if the BPF
object cannot be loaded and attached, flamez prints the reason and exits.

The installed `/usr/local/bin/flamez` has the capabilities; the development
artifact at `./zig-out/bin/flamez` does not. Rebuilding also replaces the
development artifact, so do not use it when testing the eBPF backend.

## eBPF permissions

The load/attach path, capabilities, sysctls, and the Linux 7.x attach
`EACCES` that is **not** a permission miss are documented in
[EBPF.md](EBPF.md). Read that before changing `setcap` or the BPF
programs.

Loading tracing programs requires root or appropriate BPF/perf capabilities.
There is no fallback backend: flamez checks capabilities at startup and, when
the kernel forbids it from attaching, prints exactly why and exits non-zero.

The installed binary needs two file capabilities during initialization:

- `cap_bpf` + `cap_perfmon` — load and attach raw-tracepoint programs.

After the programs attach, Flamez clears all capability sets before spawning
the target or initializing raylib.
Raw tracepoints do not read tracefs event-ID files, so
`cap_dac_read_search` is neither needed nor granted.

If attach fails with `Permission denied` / `-EACCES` *after* the programs
have already loaded, check the BPF object layout before adding more
capabilities. The kernel reuses `EACCES` when a classic `tracepoint/`
program reads past the event's fixed fields (Linux 7.x changed
`sched_process_fork` comm from a 16-byte array to a dynamic `__string`).
Flamez attaches via `raw_tp` + CO-RE to avoid that.

If the BPF object is missing or rejected, reinstall via `./build.sh`, which
places a root-owned object under `<prefix>/share/flamez/`. A capable non-root
run will not load a user-owned object through `FLAMEZ_BPF_OBJECT`; allowing
that would let the caller choose code to run with Flamez's BPF privileges.

The dev artifact at `./zig-out/bin/flamez` has no file capabilities, so it
cannot capture; use the installed binary:

```sh
/usr/local/bin/flamez <target> [target args...]
```

Because every tracked process beyond the target root comes from kernel events,
even subprocesses that live for less than one frame are retained — there is no
sampling interval to miss them in. Forked children immediately inherit their
parent's cached argv, executable, and CWD. Successful exec events carry a
bounded filename and a complete variable-length argv snapshot from the kernel,
so short-lived programs do not depend on a later `/proc/<pid>` read for their
process-image metadata.

## Architecture

- `src/main.zig` owns interaction, the Clay layout, and the raylib timeline
  renderer.
- `src/tracer.zig` owns sessions, process records, spawning, normalized capture
  ingestion, lifetime state, and bucketed CPU slices.
- `src/session_file.zig` validates and streams the compact versioned JSON
  session format, including interned metadata and atomic path installation.
- `src/analysis_file.zig` streams the bounded, dependency- and
  bottleneck-oriented analysis JSON derived from a validated session.
- `src/cli.zig` parses the explicit GUI capture, headless output, import, and
  analysis modes and classifies headless capture results.
- `src/tracer/capture.zig` selects an operating-system collector at compile
  time and exposes the backend-neutral lifecycle event contract.
- `src/tracer/process_ops.zig` selects process wait, metadata, and teardown
  operations without exposing platform syscalls to `Session`.
- `src/flamez.bpf.c` emits three scheduler lifecycle events and accounts
  process-exclusive CPU at scheduler switches without emitting per-switch
  records.
- `src/ebpf_shim.c` loads/attaches the BPF object, bridges libbpf's ring
  buffer and CPU-map snapshots into Zig, and reports initialization failures
  verbosely.
- `src/tracer/capture/macos.zig` combines a dedicated kqueue worker with
  recursive live-child discovery, immutable-parent recovery, owned metadata
  delivery, and synchronized cumulative CPU snapshots.
- `src/macos_shim.c` isolates macOS private process-inspection structures used
  for PID identity, argv, executable, CWD, and CPU totals.

CPU slices answer which process was using cycles and when; they do not identify
hot functions or prove why a process was off CPU. Analysis files expose spans
with neither CPU activity nor a direct child as possible I/O/wait candidates.
Stack sampling, symbolization, wakeup/off-CPU accounting, and explicit thread
grouping are natural follow-on layers; the event/data model is intentionally
separate from the UI so those can be added without rewriting capture sessions.

Session JSON export, import into the GUI, and a headless `-o` mode are
specified in [HEADLESS.md](HEADLESS.md). The derived agent-oriented analysis
format is specified in [ANALYSIS.md](ANALYSIS.md).

## Validation hooks

For automated visual checks, `FLAMEZ_SCREENSHOT=<path>` writes a screenshot on
frame 40 (about two-thirds of a second at the normal 60 FPS target) and exits.
Pass the target through the normal command-line arguments. The screenshot path
is interpreted by raylib relative to the current working directory.

For root-run collector smoke tests, `FLAMEZ_BPF_OBJECT` can select a specific
BPF object. Capable non-root runs still require the selected object to be a
root-owned, non-writable regular file; normal installed runs resolve the object
from the executable's `share/flamez` directory.
