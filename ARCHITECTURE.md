# Architecture

Flamez is a live **process-lifetime and CPU-activity flamegraph**: it launches a
target command, tracks the target and every descendant process, and renders
each process as a lifetime bar anchored to the wall-clock interval in which it
ran. Red slices over that bar show intervals in which threads belonging to the
process consumed CPU. Capture is platform-specific: Linux requires the eBPF
backend, while macOS prefers exact Endpoint Security capture and otherwise
uses a best-effort kqueue/libproc recovery backend. The UI is immediate-mode
[Clay](https://github.com/nicbarker/clay) layout rendered by raylib.

This document describes the runtime, persistence, replay, and analysis
architecture. For usage, see [README.md](README.md). For the eBPF load/attach
path and the Linux 7.x `EACCES` trap, see [EBPF.md](EBPF.md). For macOS API
contracts, limitations, entitlement requirements, and exact-capture validation,
see [MACAPI.md](MACAPI.md). The machine contract and metric semantics for
derived analysis output live under [`schema/`](schema/).

## High-level view

```
src/cli.zig → src/main.zig
                  ├── live capture → Collector → Session + Process model
                  │                                  ├── Clay/raylib GUI
                  │                                  └── session_file.write
                  ├── import → session_file.read → finished Session → GUI
                  └── analyze → session_file.read → analysis_file.write

Collector
    ├── process_ops.zig → platform spawn, wait, inspect, and signal operations
    └── capture.zig → normalized lifecycle events, CPU snapshots, and fidelity
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

Owns the capture and replay model independently of the UI and JSON formats:

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
    root-exit timestamp becomes the timeline ceiling for the complete model.
    Later exits are clipped, later exec images are removed, and records born
    after the boundary are discarded. CPU buckets crossing the boundary keep
    their average occupancy and become partial totals. Process-index remapping
    is reserved during capture so finalization cannot fail to allocate; the UI
    uses the same mapping to preserve selection and collapse state. Tracked-process
    state is cleared and the collector is detached.
    Natural exits distinguish a final CPU total from a partial last sample; a
    user-forced Stop flushes observations and samples CPU before sending teardown
    signals. Processes still live at that boundary remain capture-clipped with
    partial CPU; the exits caused by Stop are not imported as natural exits.

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

The macOS backend supports Apple silicon and is split across five implementation
boundaries:

- `src/tracer/capture/macos.zig` selects exact or fallback capture for each
  launch, owns platform process identities, and normalizes both paths into the
  shared collector contract.
- `src/macos_es_shim.c` and `.h` isolate Endpoint Security and copy borrowed
  framework messages into an owned queue. Dynamic API lookup keeps the binary
  compatible with systems that do not provide descendant-scoped capture.
- `src/macos_cpu.c` binds final CPU reads to a process identity or audit-token
  version, rejecting PID reuse and identity changes during the read.
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
   outlines and wheel scrolling operate over visible rows. The header control
   collapses a fully expanded tree; if any branch is collapsed, it expands all
   branches instead.
   This hybrid keeps the graph pixel-precise without fighting a retained-mode
   layout engine.

Other responsibilities:

- dispatching the CLI-selected capture, import, and analysis paths without an
  intermediate shell around the target;
- coordinating finished-session import/export and collision-safe GUI filenames
  derived from the retained target argv;
- privilege-free imported sessions skip collector setup and render with the
  tracing host's retained CPU count and capture fidelity;
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
  is interacting. Input keeps a short vsync-paced rendering burst alive, while
  hover tooltips bridge one missing timeline hit without delaying a newly hit
  block. Live and interactive frames are paced by vsync (`setTargetFPS(0)`);
  screenshots keep a fixed 60 FPS clock because they disable vsync;
- an optional compile-time `-Dfps-counter=true` flag adds the measured FPS in
  a fixed-width green slot between the footer title and target command;
- an optional compile-time `-Dperf-telemetry=true` flag logs one performance
  summary line per second plus a final session summary;
- screenshot automation: `FLAMEZ_SCREENSHOT=<path>` captures frame ~40 and
  exits, for CI-style visual checks.

### `src/cli.zig` — application modes

The CLI parser selects one of four mutually exclusive modes before any
collector or window is initialized. Flags are recognized only before the
target command, and `--` makes the remaining argv unambiguously target-owned.
A bare JSON path is therefore still a command; import and analysis always
require their explicit flags.

`main.zig` dispatches the parsed mode and owns the corresponding loop. The CLI
module also derives the sibling analysis output name and maps a successfully
written headless capture to its documented exit status. Capture setup, JSON
parsing, and rendering remain outside the parser.

### `src/session_file.zig` — canonical session persistence

This module is the storage boundary for the lossless replay/interchange form.
It validates and streams a finished `Session` as compact Flamez session v1
JSON, or reconstructs an owning, finished `Session` from that format. The
reader does not build a generic JSON tree; it writes decoded metadata and
processes directly into session-owned storage while retaining byte-offset
diagnostics for malformed input.

Named-path writes use an atomic temporary file and support either exclusive
installation for automatic GUI names or replacement for explicit output.
Validation and metadata-table preparation complete before the writer emits its
first byte. The reader and writer are independent of raylib and the platform
collector, so imports and round-trip tests require neither a window nor
capture privileges.

### `src/analysis_file.zig` — bounded derived analysis

Analysis is a deterministic projection of a validated, finished session for
performance tooling and human review. It replaces lossless metadata and CPU
slice streams with bounded command descriptions, per-process aggregates,
ranked observations, and explicitly qualified inferences. The default writer
emits pretty JSON; `writeWithOptions` also provides minified transport output
and a redacted privacy mode. Named output is atomically replaced only after a
successful write.

The JSON Schema is
[`schema/flamez-analysis-v1.schema.json`](schema/flamez-analysis-v1.schema.json).
Its companion
[`schema/flamez-analysis-v1.md`](schema/flamez-analysis-v1.md) defines metric,
rounding, ordering, inference, invariant, and privacy semantics. Those files
are the normative analysis contract; this document describes how the format
fits into the application.

## Application modes and the finished-session boundary

Every mode either produces or consumes the same `Session` model:

| Mode | Session source | Window | Collector | Result |
|---|---|---|---|---|
| GUI capture | `Session.start` and the live update loop | yes | required | Browse, then optionally save |
| File capture | The same start/update/finish path | no | required | Write session JSON and exit |
| GUI import | `session_file.read` | yes | not initialized | Browse and optionally re-export |
| Analysis | `session_file.read` | no | not initialized | Write derived analysis JSON and exit |

The important boundary is not GUI versus headless execution; it is live versus
finished state:

```
platform events → live Session → finish ─────────┐
session JSON → session_file.read ─────────────┴─→ finished Session
                                                      ├─→ GUI
                                                      ├─→ session_file.write
                                                      └─→ analysis_file.write
```

Natural root exit, GUI Stop, window close, and a cooperative termination signal
all converge on the collector-aware finish path. It reaps the root, flushes
capture work already known to the backend, takes the boundary CPU snapshot,
closes surviving descendants, rebuilds derived caches, and compacts reachable
metadata. `Session.deinit` retains a separate abort-only path for startup or
caller failure before this orderly boundary.

A writable finished session has these invariants:

- `finished` is true, `running` is false, and the live PID index is empty;
- process zero is the launched root and has a tagged exited, signaled, or
  genuinely unknown result;
- every process and real command-image interval has an end time;
- capture-clipped lifetimes and partial CPU totals remain explicitly marked;
- target argv, row images, and chronological exec images reference reachable
  metadata; and
- cached depth, parent PID, CPU bands, and peak occupancy agree with canonical
  parent links and slice triples.

Both JSON writers require a finished session. The canonical writer performs a
full preflight validation; the analysis writer validates the tree, interval,
and accounting facts it derives. Import returns only the finished shape, which
is why the GUI can replay without a collector and analysis does not need a
second capture model. Session files do not contain live/open records, UI
selection, lane packing, collapse state, zoom, pixel aggregation, or other
derived renderer state.

In file-capture mode, `-o <path>` atomically replaces the named output after
capture finishes. With `-o -`, session JSON is the only stdout producer and
the target's stdout is routed to Flamez's stderr. After a successful write,
headless exit status distinguishes Flamez/usage failure, incomplete capture,
and target failure. GUI Ctrl+S calls the same file writer with a
collision-resistant exclusive filename; stopping or closing the GUI does not
implicitly save.

## Canonical session JSON

Session v1 preserves the information needed to rebuild a finished `Session`,
including PID-reuse generations, chronological command images, exact retained
metadata bytes, provenance, cumulative self CPU, and canonical CPU slices. It
deliberately omits fields that can be derived or that exist only to accelerate
the live UI.

### Document shape and identity

The file is one RFC 8259 UTF-8 JSON object followed by a newline. Its first
field is `"flamez": 1`, allowing the streaming reader to reject unsupported
versions before consuming the body. Remaining top-level fields have these
roles:

| Fields | Role |
|---|---|
| `loss_count`, `capture_fidelity` | Known loss and the exact versus snapshot-recovery guarantee |
| `cpu_sample_period_ns`, `host_cpu_count` | Capture-time CPU accounting and replay scale |
| `environment` | Capture time plus bounded Flamez, build-Zig, OS, architecture, and kernel provenance |
| `target_argv`, `metadata` | Launch command and interned argv/path byte storage |
| `elapsed_ns`, `root_exit` | Finished timeline horizon and tagged target result |
| `processes` | Parent-before-child process generations, command images, CPU totals, and slices |

Array position is the stable process ID. PID is not an identity because the OS
can reuse it; a reused PID receives a new array element. Process zero is always
the target root, and every other process stores a backward `parent` reference.
The reader derives depth and parent PID in one pass, making cycles and
disagreement between serialized tree caches impossible.

### Metadata and command images

Captured Linux metadata is bytes, not necessarily Unicode. A `ByteString` is a
normal JSON string when the bytes are valid UTF-8 and otherwise an object with
a standard padded-base64 payload. The reader rejects malformed encodings and
field-specific bound violations; empty argv elements remain valid.

Top-level `metadata.argv` and `metadata.paths` tables intern repeated content.
The writer first recognizes shared session-arena ranges, then deduplicates
equal independently captured values. Forked descendants and repeated exec
images can therefore refer to one multi-MiB argv block both on disk and after
import. References retain their capture source and, for paths, whether capture
hit its bound.

Each process has a stable timeline `row` and a non-empty chronological `execs`
sequence. Ordinary rows derive from the first command image; the root may carry
a distinct retained launch image so its requested command stays stable across
the launch handoff. Exec intervals are ordered, non-overlapping, contained by
the process lifetime, and end with it. A gap is legal only when loss prevented
Flamez from retaining a replaced image, in which case the session records that
loss. The format never serializes the internal split between archived execs
and the current scalar image.

The fork tracepoint's child `comm` is a task name and can therefore be copied
from a named worker thread. When the parent command is known, the inherited
child image copies that command name together with argv, executable, and CWD;
the task name is not promoted to process identity. The timeline label advances
from an inherited image to the first observed exec and then remains stable.

Origin and end-kind tags distinguish observed processes from recovered parent,
exec, or exit stubs and natural exits from capture-clipped boundaries. An
independent `cpu_final` bit says whether cumulative self CPU came from an
authoritative natural-exit observation; an observed exit can still have only a
partial CPU total.

### CPU slices and derived caches

CPU activity is stored as compact `[start_ns, end_ns, cpu_ns]` triples. Each
triple is a non-empty, non-overlapping interval inside the process lifetime
with positive CPU. It represents a cumulative-snapshot bucket, not an exact
scheduler transition, and `cpu_ns` may exceed wall duration when several
threads run in parallel.

The writer omits slice band, peak cores, depth, parent PID, metadata offsets,
live PID maps, revisions, signal slots, and UI geometry. Import recomputes those
caches from parent references, lifetimes, and slice triples. The sum of slice
CPU cannot exceed the retained process total, and adjacent triples that belong
to the same canonical occupancy band must already be coalesced.

### Streaming, validation, and evolution

The writer validates the complete session and prepares intern tables before
emission. The reader checks required and duplicate fields, strict enums,
integer bounds, metadata references, parent topology, lifetime and exec
ordering, slice invariants, CPU consistency, root-row rules, and trailing input
before returning ownership. Unknown fields are errors rather than silently
ignored typos. Input can arrive in arbitrarily small chunks and large valid
arguments do not depend on the standard JSON value-length default.

Session v1 is the sole current format. The writer emits only v1 and the reader
rejects every other version with `UnsupportedVersion`. A future required field,
type or meaning change, enum expansion, or invariant change requires a new
version and an explicit reader; older semantics must not be guessed or
partially loaded.

## Derived analysis JSON

`flamez -a traces/build.json` streams and validates the canonical session, then
atomically writes `traces/analyzed-build.json`. Analysis output is deliberately
not accepted by `-i`: retain the session file whenever exact metadata, command
history, CPU slices, or timeline replay matters.

Analysis v1 separates source facts (`capture`, `environment`, `target`,
`commands`, and `processes`) from summaries and interpretations (`totals`,
`cache`, `analysis`, and `diagnostics`). Command records are interned in stable
first-use order, process IDs retain parent-before-child session order, and
rankings use deterministic ID tie-breaking. No nanosecond integer is converted
through floating point. Tool, action, input, and component classifications come
from structured command metadata rather than display-label parsing.

The transformation makes several distinctions explicit:

- self CPU belongs to one process, while inclusive CPU includes descendants;
- command intervals include launch and inherited images, while an exec
  transition is counted only when the retained history supports that claim;
- process ancestry is observed or recovered capture structure, not a build
  dependency graph;
- the longest process chain is a non-additive ancestry heuristic, not a proven
  critical path; and
- spans with neither retained CPU activity nor a live direct child are
  low-confidence stall candidates, not proof of I/O wait.

Forward and reverse topological passes derive subtree totals and component
membership. Interval merges compute CPU, child-lifetime, and unexplained wall
spans without copying canonical slices into the output. Fixed-size rankings,
component/phase envelopes, parallelism summaries, and diagnostics are then
streamed alongside bounded command previews. The result is self-contained for
common performance questions but intentionally less detailed than its source.

Default output is two-space-indented JSON. Minified output has identical IDs,
field order, array order, digests, and metric values. Redacted mode keeps
metrics, classifications, and derived summaries while removing captured paths,
argument previews and digests, host fingerprints, and other identifying
provenance. The schema and semantics documents linked above define the exact
fields and privacy contract.

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

## Cooperative termination lifecycle

The target deliberately lives in its **own process group** (`pgid = 0` at
spawn) so that `stop()` can cancel the whole build tree with one
`kill(-pid)`. That isolation has a sharp edge: terminal-generated signals
(Ctrl+C's SIGINT, a closed tab's SIGHUP, SIGTERM, SIGQUIT) reach flamez alone
and never the target group. With default dispositions flamez would die
instantly — defers never run — and the build would survive as an unstoppable,
silent orphan writing into the void.

To close that hole, `installFatalSignalHandlers()` (called first thing in
`main()`) registers handlers for SIGINT/SIGTERM/SIGHUP/SIGQUIT and ignores
SIGPIPE. The first signal atomically records a cooperative stop request and
performs the async-signal-safe target-tree sweep. The GUI or headless loop then
calls `Session.stop(&collector)`, reaps the root, drains queued lifecycle work,
takes the capture-boundary CPU snapshot, closes every interval, rebuilds
derived caches, and compacts metadata. Headless mode can therefore still write
a complete file after Ctrl+C.

A second termination signal restores the default disposition and re-raises,
so a wedged stop or output write cannot trap the user. The armed root pgid and
fixed tracked-PID table let both passes reach build tools that create their own
process groups. Group teardown tolerates `ESRCH` via raw syscall wrappers.
Window close and the Stop button use the same collector-aware finish path;
deinitialization retains a separate abort-only cleanup path for failures before
an orderly boundary exists.

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
- **macOS build graph**: Clay, raylib, the application, and the complete test root
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
- authoritative build-step dependencies supplied by build-tool-specific
  metadata, rather than inferred from process ancestry;
- optional compression, binary containers, or external trace-format converters
  around the canonical session model, justified by measurements;
- optional per-thread views (CPU is currently aggregated by TGID);
- alternate frontends: `Session` has no raylib dependency and can drive any
  renderer, headless dump, or TUI.
