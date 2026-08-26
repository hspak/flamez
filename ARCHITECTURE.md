# Architecture

Flamez is a live **process-lifetime and CPU-activity flamegraph**: it launches a
target command, tracks the target and every descendant process, and renders
each process as a lifetime bar anchored to the wall-clock interval in which it
ran. Red slices over that bar show intervals in which threads belonging to the
process consumed CPU. Capture is mandatory on Linux: if the eBPF object cannot
be loaded and attached, flamez hard-fails with an explanation. The UI is
immediate-mode [Clay](https://github.com/nicbarker/clay) layout rendered by
raylib.

This document describes how the pieces fit together. For usage, see README.md.
For the eBPF load/attach path and the Linux 7.x `EACCES` trap, see EBPF.md.

## High-level view

```
┌────────────────────────────── flamez (single process, single thread) ─────────────────────────────┐
│                                                                                                   │
│  ┌─────────── UI layer (src/main.zig) ───────────┐   ┌───────── Data layer (src/tracer.zig) ───┐  │
│  │                                               │   │                                          │  │
│  │  raylib window + frame loop                   │   │  Session                                 │  │
│  │  ├── input → Clay pointer/scroll state        │──▶│  ├── Process records + CPU slices        │  │
│  │  ├── createLayout() → Clay render commands    │   │  ├── spawn target (own process group)    │  │
│  │  ├── renderClay() → raylib draws              │◀──│  └── waitpid polling of root             │  │
│  │  └── renderTimeline(): custom Gantt rows      │   │                                          │  │
│  │       drawn over a Clay placeholder box       │   └──────────────────▲───────────────────────┘  │
│  └───────────────────────────────────────────────┘                      │ C ABI                    │
│                                              ┌──────────────────────────┴─────────────────┐         │
│                                              │ ebpf_shim.c — loader, ring + CPU snapshots │         │
│                                              │ (hard-fails verbosely when unavailable)    │         │
│                                              └──────────────────────────▲─────────────────┘         │
└─────────────────────────────────────────────────────────────────────────┼───────────────────────────┘
                                                                          │ ring records + map reads
                                                          ┌───────────────┴───────────────────────────┐
                                                          │ flamez.bpf.c — kernel (raw tracepoints)   │
                                                          │  process fork / exec / exit + sched_switch│
                                                          └───────────────────────────────────────────┘
```

## Components

### `src/tracer.zig` — capture sessions and the process data model

Owns everything that is *not* UI:

- **`Process`** — one record per observed pid: `pid`, optional `parent_pid`,
  fixed-capacity name (`max_name_len = 48` bytes), tree `depth`, `start_ns`,
  nullable `end_ns`, and offsets into the session's append-only metadata store
  for argv/executable/CWD, with provenance and path-truncation state. Argv is
  stored at its complete captured length, including empty arguments. Forked
  children share their parent's immutable metadata bytes instead of copying multi-KiB
  buffers. A null `end_ns` means "still running"; bars are clipped to "now"
  while live. Each record also owns cumulative self CPU time and a compact list
  of CPU slices. Self CPU includes every thread in the process's TGID and
  excludes descendant processes. Each UI-frame snapshot closes one variable-
  length bucket. Active buckets are classified in quarter-core bands; adjacent
  buckets in the same band coalesce so storage grows with changes in activity
  rather than with every context switch. Idle buckets advance the snapshot
  cursor without allocating a slice.
- **`Session`** — the heart of the tracker:
  - `start(collector, argv)` temporarily marks Flamez as a BPF seed parent,
    directly spawns the target in its own process group, inserts it as the first
    `Process`, and removes the seed. The fork hook installs the target pid in
    `tracked_pids` before it can run, closing the launch-to-exec race without a
    shell wrapper or procfs discovery.
  - `update(ebpf)` runs once per frame: advances `elapsed_ns` (monotonic awake
    clock), drains the eBPF ring buffer into the process tree, snapshots
    cumulative CPU accounting into process slices, and non-blockingly
    `waitpid`s the root to detect exit code/signal.
  - `consumeEbpfEvent` folds kernel events into records: `fork` appends a
    child below its parent and inherits its metadata, `exec` renames an
    existing record, applies the kernel's filename/argv snapshot, and tries to
    refresh CWD, while the final `group_dead` exit records final self CPU and
    closes its lifetime. A
    finished tgid that is reused becomes a new record. A
    fork whose parent is missing, an exec whose pid is missing, or an exit
    whose pid was never seen, is recovered under the session root rather than
    dropped, so a lost ring-buffer record cannot hide that subtree. An
    exit-only recovery is a zero-width bar at the death timestamp: the fork
    time is unknown. `/proc` only enriches fields
    absent from the event path. Kernel timestamps are rebased against session
    start so all
    lifetimes share the session's timeline domain. The BPF fork handler admits
    a child only when its parent is tracked and adds that child synchronously,
    so unrelated system-wide fork/exec/exit traffic never reaches the ring
    buffer.
  - CPU snapshots are cumulative, so a missed userspace frame delays
    attribution but does not lose accounted CPU time. A slice's `cpu_ns` may
    exceed its wall duration when several threads run in parallel; the ratio is
    average core occupancy, not a percentage capped at one core. The map read
    and its userspace timestamp have bounded sampling skew; a natural exit's
    kernel-timestamped final total reconciles any transient overestimate from
    the newest slices.
  - Root exit is detected with `waitpid(..., WNOHANG)` and ends the session.
    Any descendant records still open are closed at the target's exit time,
    tracked-pid state is cleared, and the eBPF collector is detached. While the
    target is live, teardown can still kill every remembered tgid, not only
    `-pgid`. Natural process exits carry one final CPU snapshot in the exit
    record. A user-forced Stop closes bars at the last frame snapshot because
    it tears down without waiting for another collector poll.
- **`EbpfCollector`** — owns the loaded BPF object via the C shim. `init()`
  attempts load + attach; on any failure it stores a human-readable reason
  (missing capabilities, missing BPF object, failed load/attach) retrievable
  through `diagnosticSlice()`, and `available()` returns false. Because there
  is no fallback backend, callers abort startup when that happens. After the
  programs attach, `dropCapabilities()` clears the process capability sets
  before target spawn and GUI initialization. `poll()` drains the ring buffer with timeout 0
  so rendering is never blocked; since
  collection and rendering share the main thread, it targets the session via
  a file-scope `active_session` slot, keeping C ignorant of Zig layouts. The C
  shim batch-reads the completed-CPU and running-thread maps, merges them, and
  calls a second narrow callback with
  `(tgid, cpu_ns, timestamp_ns)` snapshots.

Unit tests cover duration clamping, name trimming, CPU-bucket coalescing and
parallel occupancy, CPU timing formatting, fatal-signal handler installation,
process-group teardown, session lifecycle across child churn, and — by feeding
synthesized events directly to `consumeEbpfEvent` without kernel privileges —
the full fork/exec/exit tree-building rules including final CPU attribution,
live-pid dedup, pid-reuse after exit, and recovery of missing parents/execs/exits.
A live attach smoke test loads the compiled BPF object and is skipped without
tracing privileges (and fails if root still cannot attach).

### `src/flamez.bpf.c` — kernel-side collector

A minimal libbpf CO-RE program with four **raw** tracepoint handlers
(`SEC("raw_tp/...")`). Classic `SEC("tracepoint/sched/...")` programs are
deliberately avoided: Linux 7.x changed `sched_process_fork` from a fixed
`comm[16]` array to a dynamic `__string`, and the kernel then rejects
attach with `-EACCES` when the BPF program reads past the last fixed field
(`max_ctx_offset > trace_event_get_offsets()`). That error looks like a
capability failure; it is a layout mismatch.

| Raw tracepoint            | Emitted fields |
|---------------------------|----------------|
| `sched_process_fork`      | child pid, parent pid, child comm (CO-RE from `task_struct`) |
| `sched_process_exec`      | pid, current comm, bounded filename and complete NUL-separated argv |
| `sched_process_exit`      | pid, comm, and final self CPU on the final `group_dead` exit |
| `sched_switch`            | no records; updates per-process CPU accounting maps |

`sched_switch` keeps context-switch traffic inside the kernel. A
`running_threads` map records each scheduled tracked TID's TGID and start time.
On schedule-out, that entry is removed before its elapsed interval is
atomically added to the TGID's `process_cpu` total. Userspace combines the
completed total with still-running intervals during each snapshot. This avoids
`bpf_spin_lock`, which tracing programs cannot use, and the hook never emits a
ring-buffer record.

Fork and exit use the fixed 56-byte `struct flamez_event` header. Exec uses a
568-byte `struct flamez_exec_event` header followed by the exact NUL-separated
argument block from the process image. A ring-buffer dynptr makes the record
variable length, and bounded verifier-friendly reads copy the complete block
in chunks. The 6 MiB compile-time bound matches Linux's upper bound for a
successful exec argument block; an impossible larger span drops the whole
record rather than emitting a truncated prefix. `src/flamez_event.h` is the C
source of truth; Zig mirrors both headers and asserts their sizes. Records are
submitted to a 16 MiB `BPF_MAP_TYPE_RINGBUF`. Reservation or copy failures
increment a counter that the collector reports instead of silently hiding loss;
tracked-child and CPU-accounting map admission failures increment the same
counter. The `abi_v7` marker makes the loader reject stale objects with
incompatible records or accounting semantics. A 65,536-entry `tracked_pids`
hash filters lifecycle hooks and schedule-ins; `running_threads` makes
schedule-out independent of membership after a process begins exiting.

### `src/ebpf_shim.c` — libbpf loader bridge

Plain C11, compiled and linked on every Linux build:

- **Capability gate**: before touching libbpf it checks `CapEff` in
  `/proc/self/status` for `CAP_SYS_ADMIN` or `CAP_PERFMON`+`CAP_BPF`, and
  consults `kernel.unprivileged_bpf_disabled`. Without privileges it refuses
  immediately — reporting why — instead of failing slowly through feature
  probes.
- **Object trust**: resolves `FLAMEZ_BPF_OBJECT` or
  `<exe_dir>/../share/flamez/flamez.bpf.o`, opens without following the final
  symlink, and requires a root-owned regular file the real caller cannot write
  for capable non-root runs. It snapshots the object and validates the exact
  program set plus every map schema before load. There is no cwd fallback.
- **Diagnostics**: every failure mode (gate, object not found, open, load,
  attach, map fd, ring buffer) writes a human-readable reason into a caller-
  supplied buffer; there is no silent degradation. The caller hard-fails.
- **Attach**: `bpf_program__attach()` over raw tracepoints, which uses
  `bpf_raw_tracepoint_open` rather than tracefs IDs or perf-event attachment.
  There is no legacy/classic fallback. Linux v7's `group_dead` argument lets
  the exit handler emit exactly one process-exit record per TGID.
- **Lifecycle**: opens the object file, loads it, attaches every program,
  wraps the `events` map fd in a `ring_buffer`, and exposes updates to the
  `tracked_pids` map plus merged batch snapshots of `process_cpu` and
  `running_threads`.
  `flamez_ebpf_poll` uses timeout 0 so draining never blocks a frame. Zig
  clears all effective, permitted, and inheritable
  capabilities before spawning the target or initializing the GUI. The final
  exit hook removes its TGID in kernel context, avoiding per-exit map syscalls
  and stale tracking across PID reuse.

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
   means CPU activity, not an error. Hover metadata describes both the process
   and an activity slice (`start`, `end`, wall time, CPU time, average cores);
   slice height is the bucket's average cores divided by the host's logical CPU
   count. It reaches the full row at host capacity while retaining a two-pixel
   minimum for light activity. Color intensity also rises with occupancy.
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
- revision-gated process-tree geometry, retained tree-building scratch buffers,
  and per-row packed-member links. A stable
  frame visits only visible rows instead of rebuilding and rescanning the
  complete process set;
- cached selected-process detail text and line heights. Only the timing row is
  refreshed while the selected process remains live. Above that text, a
  scrollable step-area graph renders the selected process's aggregate thread
  CPU over its full lifetime, with its own session-time axis independent of the
  timeline zoom window;
- an optional compile-time `-Dfps-counter=true` flag adds the measured FPS in
  a fixed-width green slot between the footer title and target command;
- screenshot automation: `FLAMEZ_SCREENSHOT=<path>` captures frame ~40 and
  exits, for CI-style visual checks.

## Frame-by-frame data flow

```
per frame (~60 Hz, main thread):
  1. read mouse/wheel/keys            (raylib)
  2. feed Clay pointer + scroll state
  3. session.update(&ebpf)
       ├─ advance elapsed_ns
       ├─ ebpf.poll()  → ring_buffer__poll(0) → N × consumeEbpfEvent()
       ├─ batch CPU snapshot → N × consumeCpuSnapshot()
       └─ waitpid(root, NOHANG) → exit_code/signal or still-running
  4. format counters/status into ViewText (stack)
  5. createLayout() → clay.endLayout() → render commands
  6. renderClay(commands)              (raylib)
  7. renderTimeline(bounding box)      (raylib, direct draws)
```

Lifecycle events accumulate in the kernel ring buffer and are drained at the
start of the next `update()`, so subprocesses that live for less than one frame
are not missed by frame sampling. If a burst fills the ring, the BPF counter
reports the loss explicitly. CPU accounting is cumulative and map-based;
context switches do not consume ring-buffer capacity. CPU slice boundaries
are frame-time buckets rather than exact scheduler transitions. Natural exits
reconcile the final cumulative total; forced stops retain the last sampled
total. Accounting-map failures are reported in `DROPPED`.

## Concurrency model

Everything in userspace runs on one thread. The kernel collects lifecycle
events asynchronously into the BPF ring buffer and atomically adds completed
run intervals for tracked threads. The system-wide `sched_switch`
hook does a cheap miss path for unrelated work: one running-TID lookup for the
outgoing thread and one tracked-TGID lookup for the incoming thread. It emits
no records. Userspace drains and batch-snapshots once inside `update()` with no
blocking wait. Capture and rendering require no synchronization with each
other; the fatal-signal teardown uses its separate atomic PID handoff described
below.

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

- **Toolchain**: Zig 0.16 (`minimum_zig_version = "0.16.0"`), Linux v7 or newer
  at runtime (eBPF capture is mandatory).
- **Dependencies** (`build.zig.zon`): `zclay` (Clay Zig bindings) and
  `raylib-zig` built with the Wayland GLFW backend to avoid X11 fallback.
- **eBPF build graph**: on Linux the build graph always:
  - compiles `src/flamez.bpf.c` with `clang -target bpf` and installs it to
    `share/flamez/flamez.bpf.o`;
  - compiles `src/ebpf_shim.c` into the executable and links `libbpf`
    (requires clang + libbpf headers/libs on the host);
  - exposes the platform decision to Zig as `build_options.ebpf`, which gates
    the `comptime` branches in `EbpfCollector`, plus the default-off
    `build_options.fps_counter` renderer cut.
- **`build.sh`** is the privileged installer: copies the binary and BPF object
  under `/usr/local`, then applies exactly the capabilities the loader needs
  (`cap_bpf,cap_perfmon=ep`) to the installed binary, with a
  required `nosuid` mount check because file capabilities are ignored there.
  Raw tracepoints do not read tracingfs IDs, so no DAC capability is granted.
  The dev
  artifact `zig-out/bin/flamez` intentionally stays unprivileged.

## Extension points

The event/data model (`Session`, `Process`, `EbpfEvent`) is deliberately
independent of the UI, and the timeline already works in a wall-clock domain,
so these layers can be added without touching capture:

- sampled user stacks associated with CPU slices, allowing a busy interval to
  identify hot functions after symbolization;
- wakeup/off-CPU accounting to distinguish runnable delay from sleeping or
  blocking;
- zoom/pan and time-window filtering in `renderTimeline`;
- export (the record list is trivially serializable);
- optional per-thread views (CPU is currently aggregated by TGID);
- alternate frontends: `Session` has no raylib dependency and can drive any
  renderer, headless dump, or TUI.
