# Architecture

Flamez is a live **process-lifetime and CPU-activity flamegraph**: it launches a
target command, tracks the target and every descendant process, and renders
each process as a lifetime bar anchored to the wall-clock interval in which it
ran. Red slices over that bar show intervals in which threads belonging to the
process consumed CPU. Capture is platform-specific: Linux requires the eBPF
backend, while macOS prefers exact Endpoint Security capture and otherwise
uses a best-effort kqueue/libproc recovery backend. The UI is immediate-mode
[Clay](https://github.com/nicbarker/clay) layout rendered by raylib.

This document describes how the pieces fit together. For usage, see README.md.
For the eBPF load/attach path and the Linux 7.x `EACCES` trap, see EBPF.md.
For macOS API contracts, limitations, entitlement requirements, and the exact
capture validation plan, see MACAPI.md.
For session JSON export, GUI import, and headless capture (not implemented),
see HEADLESS.md.

## High-level view

```
src/main.zig (raylib + Clay UI)
    ↕
src/tracer.zig (Session + Process model)
    ├── src/tracer/process_ops.zig
    │     └── platform spawn, wait, inspect, and signal operations
    └── src/tracer/capture.zig
          └── normalized lifecycle events, CPU snapshots, and fidelity
                ├── Linux: capture/linux.zig → ebpf_shim.c → flamez.bpf.c
                └── macOS: capture/macos.zig
                      ├── exact: macos_es_shim.c → Endpoint Security
                      └── fallback worker: kqueue/libproc → macos_shim.c
```

The UI, `Session`, normalized-event consumption, and process model stay on the
main thread. Linux collection is asynchronous in the kernel. Exact macOS
callbacks and the macOS fallback worker copy data into owned queues that the
main thread drains; neither mutates `Session` directly.

## Components

### `src/tracer.zig` — capture sessions and the process data model

Owns everything that is *not* UI:

- **`Process`** — one record per observed pid: `pid`, optional `parent_pid`,
  stable `parent_index`, fixed-capacity name (`max_name_len = 48` bytes), tree
  `depth`, `start_ns`, nullable `end_ns`, lifecycle `origin` / `end_kind`, and
  offsets into the session's append-only metadata store for argv/executable/CWD,
  with metadata-source and path-truncation state. Argv is stored at its complete
  captured length, including empty arguments. Forked children share their
  parent's immutable metadata bytes instead of copying multi-KiB buffers. A null
  `end_ns` means "still running"; bars are clipped to "now" while live. Recovered
  parent/exec/exit stubs and capture-clipped ends are labeled so they are not
  read as exact observations. Each record also owns cumulative self CPU time and
  a compact list of CPU slices. Self CPU includes every thread in the process
  and excludes descendant processes. Cumulative CPU totals are sampled on a
  documented ~16 ms cadence, independent of render FPS. Active buckets are
  classified in quarter-core bands; adjacent buckets in the same band coalesce
  so storage grows with changes in activity rather than with every context
  switch. Idle buckets advance the snapshot cursor without allocating a slice.
  Canonical slices are retained for the whole capture; pixel aggregation and the
  detail graph are derived views over that source data.
- **`Session`** — the heart of the tracker:
  - `start(collector, argv)` asks the selected collector to arm the launch,
    directly spawns the target in its own process group, inserts it as the first
    `Process`, and completes the backend-specific launch handoff before target
    code can escape observation. Linux seeds kernel tracking around spawn;
    macOS registers the concrete PID while the target is suspended and then
    resumes it. No platform uses a shell wrapper for discovery.
  - `update(collector)` runs once per live frame: advances `elapsed_ns`
    (monotonic awake clock), drains normalized capture events into the process
    tree, snapshots cumulative CPU accounting on `cpu_sample_period_ns`
    (~16 ms) rather than the render rate, and non-blockingly checks the root for
    exit code/signal. Backend loss marks the session incomplete.
  - `consumeEvent` folds backend-neutral events into records: `fork` appends a
    child below its parent and inherits its metadata, `exec` renames an
    existing record, applies event-supplied filename/argv metadata, and tries to
    refresh CWD, while an exit records final self CPU when available and closes
    its lifetime. A finished PID that is reused becomes a new record.
    `by_pid` is live-only; finished generations are found with `latestIndex`
    when duplicate-exit recovery needs them. A fork whose parent is missing,
    an exec whose pid is missing, or an exit whose pid was never seen, is
    recovered under the session root rather than dropped, so a lost backend
    record cannot hide that subtree. Recovered rows carry `origin` and are
    shown as inferred. An exit-only recovery is a zero-width bar at the death
    timestamp: the fork time is unknown. Root exit and forced Stop close
    remaining open descendants with `end_kind = capture_clipped`. Platform
    inspection only enriches fields absent from the event path. Identical
    CWD/exe refreshes reuse the stored offset; reachable metadata is compacted
    when capture ends. Backend timestamps are rebased against session start so all
    lifetimes share the session's timeline domain.
  - CPU snapshots are cumulative, so a missed userspace frame delays
    attribution but does not lose accounted CPU time. A slice's `cpu_ns` may
    exceed its wall duration when several threads run in parallel; the ratio is
    average core occupancy, not a percentage capped at one core. A snapshot read
    and its userspace timestamp have bounded sampling skew; a natural exit's
    final total reconciles any transient overestimate from the newest slices.
  - Root exit is detected with `process_ops.waitNowait()`. Before ending the
    session, Session asks the backend to flush lifecycle work already known to
    the capture source and forces one final cumulative CPU snapshot. An observed
    root-exit timestamp becomes the timeline ceiling for the last CPU sample and
    every surviving descendant. Any records still open are then closed at that
    boundary, tracked-process state is cleared, and the collector is detached.
    Natural exits distinguish a final CPU total from a partial last sample; a
    user-forced Stop always retains the last available sample.

### Capture and process-operation boundary

`src/tracer/capture.zig` defines the backend-neutral `Event`, `Sink`, and
`Collector` contract. `Session` sees normalized fork, exec, and exit events,
cumulative CPU snapshots, loss accounting, and one of three fidelity levels:

- `.exact` means the backend observes lifecycle events rather than discovering
  surviving processes later;
- `.snapshot_recovery` means known failures are reported, but an entire
  short-lived branch can still escape observation; and
- `.unavailable` means capture cannot start.

`src/tracer/process_ops.zig` separately selects platform spawn, wait, process
inspection, existence, and signaling operations. Keeping lifecycle capture and
ordinary process control behind these two façades prevents platform APIs from
leaking into `Session` or the UI.

The collectors provide the same model from different operating-system sources:

| Concern | Linux | macOS exact | macOS fallback |
|---|---|---|---|
| Lifecycle | eBPF fork/exec/exit events | descendant-scoped Endpoint Security events | kqueue hints plus libproc recovery snapshots |
| Event time | kernel monotonic timestamp | kernel Mach timestamp | userspace observation time |
| Exec metadata | kernel event plus procfs enrichment | Endpoint Security event | identity-checked process inspection |
| Self CPU | eBPF scheduler accounting | `proc_pid_rusage` | `proc_pid_rusage` |
| Identity | tracked TGID lifetime | audit-token PID version | process identity plus local registration generation |
| Fidelity | exact; startup fails if unavailable | exact when the runtime and entitlement permit it | snapshot recovery, shown as best effort in the UI |

### Linux collector

`src/tracer/capture/linux.zig` wraps `src/ebpf_shim.c`, which loads the trusted
BPF object, drains lifecycle records, reads cumulative CPU snapshots, and
reports loss. `src/flamez.bpf.c` performs descendant admission and CPU
accounting in the kernel. Linux has no lifecycle fallback: initialization or
attachment failure aborts startup with a diagnostic, and capabilities are
dropped before the target and GUI start. [EBPF.md](EBPF.md) owns the program,
map, ABI, privilege, and loader details.

### macOS collector and shims

The macOS backend supports Apple silicon and is split across four implementation
boundaries:

- `src/tracer/capture/macos.zig` selects exact or fallback capture for each
  launch, owns platform process identities, and normalizes both paths into the
  shared collector contract.
- `src/macos_es_shim.c` and `.h` isolate Endpoint Security and copy borrowed
  framework messages into an owned queue. Dynamic API lookup keeps the binary
  compatible with systems that do not provide descendant-scoped capture.
- `src/macos_shim.c` and `.h` expose a small project-owned ABI for Darwin
  process launch, inspection, and CPU totals, keeping private structure layouts
  out of Zig and the shared model.
- `src/tracer/process_ops/macos.zig` starts the target as a suspended process-
  group leader, then resumes it after the chosen collector has admitted the
  concrete root PID. It also supplies the shared wait, signal, and metadata
  operations.

Exact mode receives descendant fork, exec, and exit events through Endpoint
Security, queues them off-thread, and drains them through `pollEvents()` on the
main thread. It requires an operating system with the descendant client API and
a signed executable carrying Apple's restricted entitlement.

When exact capture cannot activate, the same collector starts a kqueue/libproc
worker. The worker registers observed processes, uses lifecycle hints to drive
recursive recovery, copies metadata while processes remain inspectable, and
queues owned records for the main thread. The target remains suspended until
root registration closes the initial launch race. Snapshot discovery still
cannot guarantee observation of a descendant branch that starts and finishes
between recovery passes, so the session is marked `.snapshot_recovery` even
when no explicit local loss was counted.

Both modes use per-process cumulative CPU totals and the same awake clock domain
as `Session`. At root reap they finish their queued lifecycle work, take a
boundary CPU sample, and then let `Session` close surviving descendants. See
[MACAPI.md](MACAPI.md) for API semantics, identity rules, recovery limits,
entitlement and signing requirements, and validation evidence.

Shared tests feed synthetic normalized events into `Session` to cover tree
construction, PID reuse, recovery, final CPU attribution, and timeline rules
without requiring a capture privilege. Platform suites then exercise launch
handoff, collection, metadata, CPU accounting, queue loss, final draining, and
teardown through the real platform boundaries. Synchronization-sensitive tests
use signals or conditions with monotonic failure deadlines rather than sleeps.
EBPF.md and MACAPI.md describe the backend-specific fixtures and external
validation gates.

### `src/flamez.bpf.c` — kernel-side collector

A libbpf CO-RE program uses raw tracepoints to observe fork, exec, final process
exit, and scheduler switches. Lifecycle events go to a ring buffer; scheduler
activity stays in cumulative maps so context switches do not flood userspace.
Kernel-side descendant admission filters unrelated system activity and closes
the child-before-observation race. `src/flamez_event.h` is the C event ABI that
the Linux Zig collector mirrors.

### `src/ebpf_shim.c` — libbpf loader bridge

This C bridge owns capability and object validation, program attachment,
ring-buffer polling, tracked-root handoff, and cumulative CPU-map snapshots. It
exposes a small synchronous ABI to Zig and supplies a human-readable diagnostic
for every startup failure. The Linux collector polls it without blocking the UI
thread and clears tracing capabilities before launching the target.

The raw tracepoint choice, event and map schemas, trust checks, capabilities,
loss behavior, and Linux-version constraints are specified in
[EBPF.md](EBPF.md).

### `src/main.zig` — interaction, Clay layout, raylib rendering

The UI is split between two rendering strategies:

1. **Clay-driven chrome** (edge-to-edge body, one-row footer, status metrics,
   and selected-process pane).
   Each frame `createLayout()` declares the whole tree declaratively; Clay
   computes boxes and returns `RenderCommand`s which `renderClay()` plays back
   onto raylib (rectangles, borders, text, scissors).
   Text measurement is delegated to raylib through the
   `setMeasureTextFunction` callback so layout matches what is drawn. Normal
   chrome uses Inter, while the footer's live metrics use Roboto Mono so digit
   updates retain stable glyph widths.
2. **Hand-drawn timeline** (the flamegraph itself). The layout reserves a
   `TimelineViewport` placeholder element; after `clay.endLayout()`,
   `renderTimeline()` fetches its computed `BoundingBox` via
   `clay.getElementData` and draws directly with raylib inside a scissor rect:
   one-row header with five duration ticks, alternating row shading, normalized
   lifetime bars, and red self-CPU slices along the bottom of each bar. Red
   means CPU activity, not an error. Hover metadata describes the process;
   slice height is the bucket's average cores divided by 75% of the host's
   logical CPU count. It reaches the full row at three-quarters of host
   capacity while retaining a two-pixel minimum for light activity. Color
   intensity also rises with occupancy.
   A fixed gutter at the left of the timeline holds transparent, border-only
   disclosure buttons with full-row-height hit targets. The control belongs to
   the timeline row rather than to an individual lifetime bar and wins input
   resolution over row selection. On a standalone process row it toggles that
   process's descendants. On a packed lane, its single control applies the
   same state to every top-level process block in the lane; collapsing the lane
   therefore rebuilds it at exactly one physical row high. Click-to-select
   outlines and wheel scrolling operate over visible rows.
   This hybrid keeps the graph pixel-precise without fighting a retained-mode
   layout engine.

Other responsibilities:

- argv parsing (`flamez <target> [args...]`, passed through verbatim — no
  intermediate shell);
- wiring input into Clay (`setPointerState`, `updateScrollContainers`);
- timeline zoom through Ctrl+wheel or the centered Ctrl+= / Ctrl+- keyboard
  equivalents, with Ctrl+0 restoring the full follow-live view;
- the Stop button (kills the target process group via `Session.stop`);
- F5 toggling Clay's debug inspector;
- `App` owns dynamically sized selected-process detail buffers, so complete
  argv can be displayed and scrolled without a fixed text cap. Per-frame
  strings are `bufPrint`ed into stack buffers (`ViewText`) where their contracts
  are bounded; CPU-slice storage grows only when a new occupancy band or a busy
  interval after idle requires a slice;
- revision-gated process-tree geometry split into topology, interval, and
  label revisions. Exec does not rebuild tree geometry. Finished intervals keep
  their lane assignment while capture is live and are compacted when capture
  ends. Packed members are stored in start-time order and range-queried against
  the visible window. Lane assignment uses interval partitioning (`O(J log J)`
  after sort) instead of scanning every lane per job;
- time-culled, pixel-aggregated CPU overlays: canonical slices stay in the
  process record, while drawing emits at most one primitive per pixel column.
  Bar labels are omitted when the name cannot fit. A stable frame visits only
  visible rows and visible time;
- cached selected-process detail text and line heights. Display storage grows
  from wrapping overflow rather than a worst-case line estimate; clipboard
  staging is allocated only on Ctrl+C. Above that text, a width-decimated
  step-area graph renders the selected process's aggregate thread CPU over its
  full lifetime, with its own session-time axis independent of the timeline
  zoom window. The pane has an independent scrollbar and supports
  wheel/page/home/end navigation, mouse text selection, and Ctrl+A/Ctrl+C
  clipboard actions;
- after capture ends, the frame loop drops to a low idle rate unless the user
  is interacting. Live and interactive frames are paced by vsync
  (`setTargetFPS(0)`); screenshots keep a fixed 60 FPS clock because they
  disable vsync;
- an optional compile-time `-Dfps-counter=true` flag adds the measured FPS in
  a fixed-width green slot between the footer title and target command;
- an optional compile-time `-Dperf-telemetry=true` flag logs one performance
  summary line per second plus a final session summary;
- screenshot automation: `FLAMEZ_SCREENSHOT=<path>` captures frame ~40 and
  exits, for CI-style visual checks.

## Frame-by-frame data flow

```
per live frame (vsync, main thread; completed captures drop to a low idle rate):
  1. read mouse/wheel/keys            (raylib)
  2. feed Clay pointer + scroll state
  3. session.update(&collector) when capturing
       ├─ advance elapsed_ns
       ├─ collector.pollEvents() → N × consumeEvent()
       ├─ if cpu_sample_period_ns elapsed: one CPU snapshot array
       └─ process_ops.waitNowait(root) → exit_code/signal or still-running
  4. format counters/status into ViewText (stack)
  5. createLayout() → clay.endLayout() → render commands
  6. renderClay(commands)              (raylib)
  7. renderTimeline(bounding box)      (raylib, direct draws; time-culled
     slices, pixel-aggregated CPU, packed members range-queried)
```

Exact lifecycle events accumulate in a backend-owned queue and are drained at
the start of the next `update()`, so their capture is independent of render
FPS. The macOS recovery backend instead discovers surviving processes on its
worker cadence and reports best-effort fidelity even if it records no explicit
loss. Every backend reports known queue, map, or registration failures through
the shared dropped-event count.

CPU accounting is cumulative and sampled on its own cadence. CPU slice
boundaries are userspace buckets rather than exact scheduler transitions;
delayed frames postpone attribution without discarding previously accumulated
CPU. Natural exits reconcile the final cumulative total when the platform can
obtain it, while forced stops and raced final reads retain the last sampled
total.

## Concurrency model

`Session`, UI layout, rendering, and normalized event consumption always run on
the main thread. On Linux, all userspace capture work also runs there; the
kernel produces lifecycle records and cumulative CPU accounting asynchronously,
and `update()` drains snapshots without a blocking wait.

On macOS, Endpoint Security invokes exact-mode callbacks on its framework
queue, while fallback mode owns a dedicated kqueue/recovery worker. Both paths
copy platform data into bounded owned queues. `pollEvents()` transfers those
records to the main thread before invoking the shared event sink. Process
identity is checked around asynchronous inspection and CPU reads so a raced
exec or reused PID cannot update the wrong record. Neither macOS producer
mutates `Session` or UI state. Fatal-signal teardown uses its separate atomic
PID handoff described below.

## Fatal-signal lifecycle

The target deliberately lives in its **own process group** (`pgid = 0` at
spawn) so that `stop()` can cancel the whole build tree with one
`kill(-pid)`. That isolation has a sharp edge: terminal-generated signals
(Ctrl+C's SIGINT, a closed tab's SIGHUP, SIGTERM, SIGQUIT) reach flamez alone
and never the target group. With default dispositions flamez would die
instantly — defers never run — and the build would survive as an unstoppable,
silent orphan writing into the void.

To close that hole, `installFatalSignalHandlers()` (called first thing in
`main()`) registers handlers for SIGINT/SIGTERM/SIGHUP/SIGQUIT and ignores
SIGPIPE. The handler is async-signal-safe by construction: it reads the
target's pgid from an atomic (`live_target_pgid`, armed right after spawn,
disarmed when the root exits naturally or the session stops), sends TERM to
the group, waits ~120 ms via raw `nanosleep`, escalates to KILL, then restores
the default disposition and re-raises so the process still dies from the
signal it received. Group teardown tolerates `ESRCH` (group already gone) via
a raw syscall wrapper instead of `std.posix.kill`, whose debug-mode behavior
panics on `ESRCH`.

The same teardown helper backs `Session.stop()`, the spawn error path, and
deinit, so every way flamez can die — Stop button, window close, fatal
signal — ends with the target group terminated.

## Build system

- **Toolchain**: Zig 0.16 (`minimum_zig_version = "0.16.0"`). Linux v7 or newer
  uses exact eBPF lifecycle capture. macOS uses best-effort kqueue/libproc
  capture when the runtime or signature cannot activate Endpoint Security.
- **Dependencies** (`build.zig.zon`): `zclay` (Clay Zig bindings) and
  `raylib-zig` built with the Wayland GLFW backend to avoid X11 fallback.
- **eBPF build graph**: on Linux the build graph always:
  - compiles `src/flamez.bpf.c` with `clang -target bpf` and installs it to
    `share/flamez/flamez.bpf.o`;
  - compiles `src/ebpf_shim.c` into the executable and links `libbpf`
    (requires clang + libbpf headers/libs on the host);
  - exposes the platform decision to Zig as `build_options.ebpf`, which gates
    the `comptime` branches in the Linux collector, plus the default-off
    `build_options.fps_counter` renderer cut and `build_options.perf_telemetry`
    counters.
- **`build.sh`** is the privileged installer: copies the binary and BPF object
  under `/usr/local`, then applies exactly the capabilities the loader needs
  (`cap_bpf,cap_perfmon=ep`) to the installed binary, with a
  required `nosuid` mount check because file capabilities are ignored there.
  Raw tracepoints do not read tracingfs IDs, so no DAC capability is granted.
  The dev
  artifact `zig-out/bin/flamez` intentionally stays unprivileged.
- **macOS build graph**: Clay, raylib, the application, and both test roots
  target Apple silicon (`aarch64-macos`); `src/macos_shim.c` and
  `src/macos_es_shim.c` are compiled only into macOS artifacts. The pinned
  framework package supplies Apple SDK headers and libraries.
  `zig build test-compile -Dtarget=aarch64-macos` validates the complete graph
  without trying to execute a cross-built binary.
  `-Dmacos-require-endpoint-security=true` changes automatic selection to
  fail-closed exact capture for signed macOS 27 validation; it does not grant
  the restricted entitlement in `macos.entitlements`.

## Extension points

The event/data model (`Session`, `Process`, `capture.Event`) is deliberately
independent of both the UI and the Linux raw-event ABI. The timeline already
works in a wall-clock domain, so these layers can be added without changing
the renderer:

- sampled user stacks associated with CPU slices, allowing a busy interval to
  identify hot functions after symbolization;
- wakeup/off-CPU accounting to distinguish runnable delay from sleeping or
  blocking;
- additional time-window filtering or export controls around the existing
  timeline zoom/pan implementation;
- session JSON export, GUI import of that file, and headless `-o` capture
  (see HEADLESS.md);
- optional per-thread views (CPU is currently aggregated by TGID);
- alternate frontends: `Session` has no raylib dependency and can drive any
  renderer, headless dump, or TUI.
