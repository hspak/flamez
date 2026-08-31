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
For session JSON export, GUI import, and headless capture (not implemented),
see HEADLESS.md.

## High-level view

```
┌────────────────────────────── flamez (single process, single thread) ─────────────────────────────┐
│                                                                                                   │
│  ┌─────────── UI layer (src/main.zig) ───────────┐   ┌───────── Data layer (src/tracer.zig) ───┐  │
│  │                                               │   │                                          │  │
│  │  raylib window + frame loop                   │   │  Session                                 │  │
│  │  ├── input → Clay pointer/scroll state        │──▶│  ├── Process records + CPU slices        │  │
│  │  ├── createLayout() → Clay render commands    │   │  ├── spawn target (own process group)    │  │
│  │  ├── renderClay() → raylib draws              │◀──│  └── process_ops root polling            │  │
│  │  └── renderTimeline(): custom Gantt rows      │   │                                          │  │
│  │       drawn over a Clay placeholder box       │   └──────────────────▲───────────────────────┘  │
│  └───────────────────────────────────────────────┘                      │ normalized events        │
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
  stable `parent_index`, fixed-capacity name (`max_name_len = 48` bytes), tree
  `depth`, `start_ns`, nullable `end_ns`, lifecycle `origin` / `end_kind`, and
  offsets into the session's append-only metadata store for argv/executable/CWD,
  with metadata-source and path-truncation state. Argv is stored at its complete
  captured length, including empty arguments. Forked children share their
  parent's immutable metadata bytes instead of copying multi-KiB buffers. A null
  `end_ns` means "still running"; bars are clipped to "now" while live. Recovered
  parent/exec/exit stubs and capture-clipped ends are labeled so they are not
  read as exact observations. Each record also owns cumulative self CPU time and
  a compact list of CPU slices. Self CPU includes every thread in the process's
  TGID and excludes descendant processes. Cumulative CPU maps are snapshotted on
  a documented ~16 ms cadence, independent of render FPS. Active buckets are
  classified in quarter-core bands; adjacent buckets in the same band coalesce
  so storage grows with changes in activity rather than with every context
  switch. Idle buckets advance the snapshot cursor without allocating a slice.
  Canonical slices are retained for the whole capture; pixel aggregation and the
  detail graph are derived views over that source data.
- **`Session`** — the heart of the tracker:
  - `start(collector, argv)` asks the selected collector to arm the launch,
    directly spawns the target in its own process group, inserts it as the first
    `Process`, and removes the launch marker. On macOS the target starts
    suspended, and Session resumes it only after exact ES admission or fallback
    kqueue registration. On Linux the eBPF fork hook
    installs the target pid in `tracked_pids` before it can run, closing the
    launch-to-exec race without a shell wrapper or procfs discovery.
  - `update(collector)` runs once per live frame: advances `elapsed_ns`
    (monotonic awake clock), drains normalized capture events into the process
    tree, snapshots cumulative CPU accounting on `cpu_sample_period_ns`
    (~16 ms) rather than the render rate, and non-blockingly checks the root for
    exit code/signal. Backend loss marks the session incomplete.
  - `consumeEvent` folds backend-neutral events into records: `fork` appends a
    child below its parent and inherits its metadata, `exec` renames an
    existing record, applies the kernel's filename/argv snapshot, and tries to
    refresh CWD, while the final `group_dead` exit records final self CPU and
    closes its lifetime. A finished tgid that is reused becomes a new record.
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
  - Root exit is detected with `process_ops.waitNowait()`. Before ending the
    session, Session asks the backend to flush lifecycle work already known to
    the kernel and forces one final cumulative CPU snapshot. Exact macOS capture
    uses `es_sync_client`; Linux drains the eBPF ring; macOS fallback joins its
    worker after a final kqueue/recovery pass. An observed root-exit timestamp
    becomes the timeline ceiling for the last CPU sample and every surviving
    descendant. Any records still open are then closed at that target-exit time,
    tracked-pid state is cleared, and the collector is detached. While the
    target is live, teardown can still kill every remembered tgid, not only
    `-pgid`. Natural process exits carry the latest CPU snapshot plus a bit
    stating whether the backend obtained the final cumulative total. If a
    macOS descendant was already reaped before `proc_pid_rusage`, Flamez keeps
    the latest periodic total and labels it partial (`CPU~`). A user-forced
    Stop likewise closes bars at the last sampled total because it tears down
    without waiting for another collector poll.
- **`capture.zig`** — defines the backend-neutral `Event`, callback `Sink`, and
  compile-time `Collector` selection. It also exposes `.exact`,
  `.snapshot_recovery`, or `.unavailable` lifecycle fidelity so the UI does not
  equate zero known drops with guaranteed completeness. `Session` depends only
  on this contract.
  Linux selects `capture/linux.zig`; macOS selects `capture/macos.zig`, which
  attempts exact descendant-scoped Endpoint Security before spawn and otherwise
  combines kqueue lifecycle hints with recursive libproc snapshots. Runtime
  fidelity is copied into Session so the UI distinguishes the two without
  changing the event contract. [MACAPI.md](MACAPI.md) documents both paths.
- **Linux `Collector`** — owns the loaded BPF object via the C shim. `init()`
  attempts load + attach; on any failure it stores a human-readable reason
  (missing capabilities, missing BPF object, failed load/attach) retrievable
  through `diagnosticSlice()`, and `available()` returns false. Because there
  is no fallback backend, callers abort startup when that happens. After the
  programs attach, `dropPrivileges()` clears the process capability sets
  before target spawn and GUI initialization. `pollEvents()` drains the ring
  buffer with timeout 0 so rendering is never blocked; `snapshotCpu()` is
  scheduled independently. Collection and rendering share the main thread;
  the backend delivers normalized events through a file-scope `Sink` active
  only during polling, keeping C ignorant of Zig layouts. The C shim batch-reads
  the completed-CPU and running-thread
  maps, merges them through a reusable hash index, and returns the snapshot
  array once for Zig to apply.
- **macOS `Collector`** — attempts to resolve the macOS 27
  `es_new_descendants_client` before each target spawn. When its signed binary
  has the Endpoint Security entitlement, a C callback copies exact fork/exec/
  exit records into an owned queue. Zig filters the root subtree by audit-token
  PID version, uses kernel Mach timestamps and exec metadata, reports global
  sequence gaps, and marks the launch `.exact`. Stable ES and libbsm helpers are
  also dynamically resolved, keeping macOS 26 builds loadable. At root reap,
  the new `es_sync_client` marker guarantees all earlier messages have reached
  the bridge before its final drain.

  The fallback owns a kqueue, capture worker, mutex-protected event queue, and
  allocator-backed live-PID map. It registers each known PID for
  fork/exec/exit hints, recursively snapshots direct children on kqueue wakeup
  and every 4 ms, and scans the root's dedicated process group for live
  descendants reparented after a missed intermediate process. The worker copies
  argv, executable, and CWD before a short-lived process disappears; only the
  GUI thread delivers those owned events into `Session`. Because those fields
  require separate inspection calls, the worker brackets them with combined
  process-identity reads and accepts them only if both the immutable lifetime
  identity and exec-image PID version remain stable. A raced exec or PID reuse
  discards the partial snapshot and schedules another attempt. A
  generation-authenticated `NOTE_EXEC` is still delivered when inspection is
  denied: Session clears inherited argv/executable state, retains only the
  explicitly inherited CWD, and suppresses unbracketed live-PID enrichment.
  Recovered group members enter through the inferred-exec path rather than an
  invented parent edge. A valid tracked `NOTE_FORK` hint also triggers one
  all-PID identity scan: candidates are admitted only when XNU's immutable
  original-parent unique ID matches a tracked process unique ID. This safely
  recovers a direct child that has already reparented and left the process group
  without continuously inspecting the system. Unique ID plus BSD start time and
  a kqueue `udata` generation protect PID reuse. `proc_pid_rusage` supplies
  cumulative self CPU totals on the shared cadence and, when the zombie remains
  inspectable, a final total at exit. Its
  task-recount values are Mach absolute-time ticks; the shim applies
  one `pthread_once`-cached `mach_timebase_info` conversion before exposing
  nanoseconds, which is essential on Apple silicon where the timebase is not
  1:1. Exact ES event timestamps use the same conversion.
  `src/macos_shim.c` confines private libproc structure layouts and
  `KERN_PROCARGS2` to a small project-owned ABI. The macOS backend intentionally
  supports only `aarch64-macos`. This deployable fallback has no
  privilege requirement but cannot observe a descendant branch whose entire
  lifetime falls between snapshots. It also cannot connect a double-forked
  daemon after an unobserved intermediate has vanished, because the surviving
  process's immutable parent edge names that missing process. Private
  responsible-process and coalition identities were rejected as substitutes
  because they group the whole launching application, not one Flamez target;
  using them would adopt unrelated terminal work.
- **macOS process launch** — `process_ops/macos.zig` uses Darwin `posix_spawnp`
  with `POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED`. Session creates
  the root model and arms the selected collector around its concrete PID before
  sending `SIGCONT`. Target code therefore cannot create an unregistered early
  branch; the remaining fallback gap begins only after the target is resumed.
- **`process_ops.zig`** — compile-time-selected process operations used by
  `Session` and signal teardown: current PID, nonblocking wait/status decoding,
  metadata enrichment, best-effort signaling, existence checks, and the short
  termination grace period. Linux raw syscalls and procfs live only in
  `process_ops/linux.zig`; the macOS implementation uses libc plus the process
  inspection shim and does not leak platform calls into the shared session.

Unit tests cover duration clamping, name trimming, CPU-bucket coalescing and
parallel occupancy, CPU timing formatting, fatal-signal handler installation,
process-group teardown, session lifecycle across child churn, and — by feeding
synthesized events directly to `consumeEvent` without kernel privileges —
the full fork/exec/exit tree-building rules including final CPU attribution,
live-pid dedup, pid-reuse after exit, and recovery of missing parents/execs/exits.
A macOS launch fixture additionally proves the suspended target cannot execute
before collector registration. Fallback-only fixtures explicitly disable ES so
they keep covering snapshot recovery on entitled macOS 27 hosts. A signal-gated
fan-out fixture verifies admission and clustered exits for 32 simultaneous
children without depending on a duration floor. A shebang fixture separates the
resolved interpreter executable from its script argv and preserves an empty
argument. Another fixture admits a child before it calls `setsid()` and verifies
per-PID tracking survives process-group escape. A complementary fixture delays
ordinary recovery until a direct child has called `setsid()` and reparented,
then verifies immutable-parent recovery. A third follows a double fork and
verifies no process is attributed after the unobserved intermediate identity
has vanished. Test polling uses condition checks, yields, and monotonic failure
deadlines; targets remain alive through stop or signal handshakes rather than
timed delays.

Test builds also compile the production TERM grace period out of
`terminateTargetGroup`, so cleanup sends TERM and KILL immediately instead of sleeping.
A test-only Endpoint Security bridge constructor injects owned event fields through
the production queue internals, covering deep-copy lifetime, FIFO order, byte-budget
loss, and global sequence gaps without needing the restricted entitlement. Native
SDK message fixtures additionally traverse the production fork/exec/exit extractor,
including audit-token versions, packed argv, truncation flags, Mach timestamps, and
final CPU. Those helpers are absent from the application build.
A condition-gated fake `es_sync_client` also completes a copied queue-marker
block from another thread, proving the production root-exit waiter blocks until
the ES barrier fires and propagates marker rejection without sleeps.
A live calibration brackets converted `mach_absolute_time` with
`CLOCK_UPTIME_RAW`, proving exact events and Session share the awake clock domain.
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

Lifecycle events accumulate in the kernel ring buffer and are drained at the
start of the next `update()`, so subprocesses that live for less than one frame
are not missed by frame sampling. If a burst fills the ring, the BPF counter
reports the loss explicitly. CPU accounting is cumulative and map-based;
context switches do not consume ring-buffer capacity. CPU slice boundaries
are frame-time buckets rather than exact scheduler transitions. Natural exits
reconcile the final cumulative total; forced stops retain the last sampled
total. Accounting-map failures are reported in `DROPPED`.

## Concurrency model

`Session`, UI layout, rendering, and normalized event consumption always run on
the main thread. On Linux, all userspace capture work also runs there: the
kernel collects lifecycle events asynchronously into the BPF ring buffer and
atomically adds completed run intervals for tracked threads. The system-wide
`sched_switch` hook does a cheap miss path for unrelated work: one running-TID
lookup for the outgoing thread and one tracked-TGID lookup for the incoming
thread. It emits no records. Userspace drains and batch-snapshots once inside
`update()` with no blocking wait.

On macOS fallback launches, a dedicated worker blocks in kqueue with a 4 ms
recovery timeout, owns the live-PID map, and copies process-inspection metadata
into pending records. During fork bursts it registers every live child before
performing slower metadata inspection, drains kqueue until a 250 us quiet point,
or at most eight additional busy batches, then runs one coalesced all-PID
immutable-parent recovery scan. `pollEvents()` swaps the pending and delivery
lists and their byte accounting under a pthread mutex, then invokes Session
callbacks after releasing it. The pending payload budget is 16 MiB, matching
the Linux ring and exact ES bridge; overflow increments `lost_events` instead
of allowing worker memory to grow without bound. Every libproc PID snapshot
adds sizing slack and retries a full result with doubled capacity; four
consecutive full fills raise `lost_events` rather than feeding a potentially
truncated snapshot into discovery. Exact launches instead receive
callbacks on Endpoint Security's serial queue; the C
bridge copies borrowed messages before returning, and `pollEvents()` drains the
owned list synchronously on the main thread. CPU sampling in either mode copies
PID identity and generation under the Zig mutex, performs `proc_pid_rusage`
without holding the lock, timestamps each PID immediately after its cumulative
read, and verifies identity again before delivery. Per-PID timestamps prevent
the tail of a large process scan from being projected back to a single boundary
captured before the scan began. Neither worker mutates Session or UI state.
Fatal-signal teardown uses its separate atomic PID handoff described below.

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
  target Apple silicon (`aarch64-macos`); `src/macos_shim.c` is compiled into the
  application and test roots. The pinned framework package is a direct lazy
  dependency because raylib's static-library framework search paths are not
  transitive in Zig 0.16. `zig build test-compile -Dtarget=aarch64-macos`
  validates the complete graph without trying to execute a cross-built binary.
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
