# Performance implementation

This document describes the performance-specific code that exists in Flamez.
It is not a list of optimization ideas or a claim that a particular path is a
measured bottleneck. Cross-platform ownership and data flow are documented in
[ARCHITECTURE.md](ARCHITECTURE.md); Linux collector details are in
[EBPF.md](EBPF.md), and macOS API details are in [MACAPI.md](MACAPI.md).

## Implemented performance model

Flamez keeps canonical capture data for the full session, but tries to make
recurring work depend on current activity and the visible viewport rather than
all retained history.

| Area | Implemented behavior | Scope |
|---|---|---|
| Lifecycle collection | Producers queue normalized lifecycle events; the main thread drains them without a blocking wait | Shared contract, platform-specific producers |
| CPU sampling | Cumulative totals are sampled on a ~16 ms cadence independent of render FPS | Shared |
| CPU history | Idle samples allocate nothing; adjacent active samples in the same quarter-core band coalesce | Shared |
| Process lookup | The PID hash contains live processes only | Shared |
| Metadata | Forks share immutable offsets, identical paths reuse storage, and reachable bytes are compacted at capture completion | Shared |
| Tree layout | Revision-gated rebuilds, stable live lanes, and heap-based sibling lane assignment | UI |
| Timeline | Vertical and temporal culling, followed by pixel-column aggregation | UI |
| Detail pane | Revision/width caches and a width-decimated CPU graph | UI |
| Completed capture | Unchanged frames are not laid out or rendered; input is polled on a short idle interval | UI |
| Telemetry | Compile-time phase timing and shape counters | Shared/UI |

## Shared capture and storage

### CPU sampling is independent of rendering

`Session.update` polls lifecycle events every live frame, but calls
`Collector.snapshotCpu` only when `cpu_sample_period_ns` has elapsed. The
period is currently 16 ms. A slow or skipped frame delays a sample; it does not
lose CPU already accumulated by the platform collector because every sample is
cumulative.

Each delivered sample has its own observation timestamp. `Process` converts
successive cumulative totals into activity intervals. A natural exit can carry
a final authoritative total; `recordFinalCpuSnapshot` reconciles a newer live
sample that temporarily overestimated CPU, removes or shortens affected tail
slices, and coalesces the corrected tail again.

This design keeps lifecycle polling responsive while preventing CPU collection
from accidentally running once per render call or once per displayed process.

### CPU slices compress repeated and idle activity

`Process.recordCpuSnapshot` stores only intervals with a positive CPU delta.
It classifies average core occupancy in quarter-core bands, capped at sixteen
cores. A new interval that is adjacent to the previous interval and has the same
band extends that slice in place. Idle intervals advance the cumulative
snapshot cursor without appending a slice.

The process also maintains `cpu_peak_cores` while recording. The detail graph
therefore does not rescan all CPU history merely to choose its vertical scale.
Final-total correction recomputes the peak because it can rewrite previously
recorded slices.

Canonical slices remain retained for the capture. Rendering builds bounded
views over them; it does not replace old source slices with screen-resolution
data.

### Process and metadata storage retain capacity

`Session`, `Process`, and `App` use unmanaged lists and maps whose capacity
is retained across updates and rebuilds. The warmed-up main/UI frame normally
allocates only when the capture grows into new process, exec-history, CPU-band,
or viewport capacity.

Variable-length argv, executable, and CWD bytes live in one session metadata
store. Process and exec records hold offsets, so arena growth cannot invalidate
them. A fork copies offsets and provenance instead of duplicating inherited
metadata. Path setters compare the current value before appending, avoiding
repeated storage for unchanged executable and CWD observations from the same
source.

When capture stops or the root exits, `Session.compactMetadata` rebuilds the
store from reachable process and exec-history references. An offset-remap table
copies shared byte ranges once and updates every retained offset. Compaction is
kept out of the live event path; its temporary allocation can approach the
pre-compaction store size.

`Session.by_pid` contains live processes only. Finishing the current
generation removes its entry. Recovery code that needs a historical generation
uses the slower reverse `latestIndex` scan instead of making every hot lookup
pay for all historical PIDs.

Fatal-signal teardown uses a fixed 65,536-entry atomic PID table. Each process
stores the `u16` slot returned at admission, so normal process completion clears
the exact slot without searching the table. Admission starts from a retained
free-slot hint. The rare Stop/fatal-signal path deliberately scans the complete
table so it can signal process groups that escaped the root group.

### Loss bounds prevent producer memory from growing silently

All lifecycle producers have a bounded queue or ring and expose known loss to
`Session`. A nonzero loss count marks the session incomplete.

- Linux uses a fixed 16 MiB BPF ring buffer.
- Exact macOS Endpoint Security capture uses a 16 MiB owned-record queue.
- The macOS fallback uses a 16 MiB pending-event budget, including owned argv
  capacity.

A failed Linux CPU snapshot also counts as known loss, including a failed final
read. The persisted session retains that incompleteness after replay.

These limits protect Flamez from unbounded producer memory during a fork/exec
burst. They are correctness boundaries as well as performance bounds: overflow
is reported rather than hidden.

## Linux-specific collector optimizations

### Lifecycle filtering and CPU accounting stay in the kernel

`src/flamez.bpf.c` admits a child synchronously when its tracked parent forks.
Unrelated fork, exec, and exit activity is rejected before ring-buffer
reservation. The scheduler tracepoint emits no userspace event. It records
schedule-in state per tracked thread and atomically accumulates completed
intervals per process on schedule-out.

This avoids sending system-wide context-switch traffic to Flamez. The remaining
Linux observer cost is the raw `sched_switch` hook itself: every system context
switch executes one lookup for each outgoing and incoming thread even when neither side belongs to the target.

The BPF object preallocates the hot maps so tracepoint execution does not depend
on kernel allocation under load:

| Object | Bound |
|---|---:|
| lifecycle ring | 16 MiB |
| tracked processes | 65,536 |
| process CPU totals | 65,536 |
| admitted threads, running or idle | 65,536 |

These are fixed startup costs chosen to avoid admission failure during capture.

### CPU map snapshots are batched and reuse scratch storage

`src/ebpf_shim.c` reads `process_cpu` and `running_threads` with
`bpf_map_lookup_batch` in batches of 256. Its `cpu_totals` array starts at
256 entries, grows geometrically, and is retained for later snapshots.

After reading completed totals, the shim rebuilds a reusable open-addressed
index with a power-of-two capacity and a maximum load factor of one half.
Still-running thread intervals are then merged into the owning TGID with
expected constant-time lookup. This replaced the earlier sort plus repeated
binary searches.

The completed array, count, and one snapshot timestamp cross into Zig once.
`capture/linux.zig` iterates the borrowed array directly; there is no
per-process C callback and no copy into a second Zig snapshot buffer. Lifecycle
polling uses `ring_buffer__poll(..., 0)`, so an empty poll never blocks the UI.

## macOS-specific collector optimizations

macOS lifecycle capture has two runtime modes. Both use
`proc_pid_rusage` for cumulative self CPU, but their lifecycle producers are
different.

### Exact Endpoint Security mode

`src/macos_es_shim.c` copies every borrowed ES message before the framework
callback returns. One allocation holds the fixed queue record and its variable
name, argv, executable, and CWD bytes. The callback appends that record to a
mutex-protected linked queue with a 16 MiB byte budget.

Polling detaches the complete linked list and resets its byte count while
holding the mutex, then invokes Zig callbacks and frees records after releasing
the lock. Endpoint Security's producer queue therefore never mutates
`Session`, and the main thread does not hold the queue mutex while consuming
events.

Global ES sequence gaps and allocation/budget failures contribute to the same
loss count. At root reap, `es_sync_client` places a queue barrier before the
final drain so normal frame timing cannot strand already-enqueued events.

### kqueue/libproc fallback mode

`src/tracer/capture/macos.zig` runs fallback discovery on a dedicated worker
instead of the render thread. The worker blocks in `kevent` with a 4 ms
recovery timeout and reads up to 256 events at once.

Fork bursts are handled in two stages:

1. Cheap recursive PPID and process-group discovery admits and registers live
   PIDs before metadata enrichment.
2. A tracked fork hint triggers up to eight additional kqueue drains with a
   250 microsecond quiet window, followed by one coalesced all-PID immutable-
   parent scan for children that already escaped ordinary discovery.

This ordering prioritizes kqueue registration during churn and avoids an
all-system PID scan on every 4 ms recovery pass.

Quiet kqueue batches use the recovery pass already performed before event
consumption. Only nonempty batches need another pass after applying their
lifecycle changes. The descendant parent queue retains capacity between scans.
Fork-burst waits release the collector mutex so the main thread can drain
already queued observations during the 250 microsecond quiet window.

libproc PID lists reuse one `pid_snapshot` buffer. The collector adds sixteen
slots to the sizing result and treats a completely full fill as possibly
truncated. It doubles capacity for at most four attempts; a persistently full
snapshot is rejected and counted as loss rather than consumed as complete.

The worker owns `pending_events`; the main thread owns `delivery_events`.
`pollEvents` swaps the two lists and their byte accounting under the mutex,
then delivers and destroys records after unlocking. Both lists retain their
allocation capacity for the next batch.

Fallback CPU sampling also minimizes lock duration around slow system calls.
The main thread copies PID identity and collector generation into a reusable
`cpu_targets` list under the mutex, releases the lock for
`proc_pid_rusage`, timestamps each PID immediately after its read, verifies
the process identity, and briefly locks again before publishing the sample.
This prevents a slow fan-out scan from projecting every total back to one early
timestamp and prevents PID reuse from corrupting another record.

### Shared macOS conversion path

`src/macos_shim.c` caches `mach_timebase_info` with `pthread_once`.
Endpoint Security Mach timestamps and `proc_pid_rusage` task-recount totals
share the same conversion function. A 128-bit intermediate avoids overflow
during scaling. This removes a timebase query from every event and CPU sample
while preserving the non-1:1 Apple-silicon conversion.

The fallback worker performs discovery and metadata inspection while holding
its collector mutex. That serializes worker state safely, but a large libproc
scan can delay a main-thread queue swap or CPU-target snapshot. Exact Endpoint
Security mode does not perform those discovery scans.

### Native fallback measurements

On 2026-09-04, the deferred profiling ran on an 8-core Apple M1 with 8 GiB RAM,
macOS 26.6.2 (25G83), and Zig 0.16.0. An isolated ReleaseSafe test build timed
worker lock holds, main-thread lock waits, discovery, metadata, CPU snapshots,
and complete `pollEvents` calls. Instrumentation was absent from the production
build. The harness used the C allocator, polled every 4 ms, and retained the
normal 16 ms CPU-sample cadence.

Each shape ran three times before and after the changes above. Steady cases
forked sleeping children for 1.2 seconds; the burst case ran six waves of 32
children sleeping for 150 ms. The table reports the median of the three
per-run p95 queue-poll durations and the largest individual poll across them.
Queue-poll duration includes mutex wait and event delivery, not GUI rendering.

| Workload | Poll p95 before | Poll p95 after | Worst poll before | Worst poll after |
|---|---:|---:|---:|---:|
| 1 child | 0.233 ms | 0.192 ms | 2.080 ms | 2.499 ms |
| 32 children | 1.478 ms | 0.844 ms | 15.376 ms | 3.843 ms |
| 128 children | 5.673 ms | 2.950 ms | 45.627 ms | 39.756 ms |
| Six 32-child waves | 2.051 ms | 2.453 ms | 17.619 ms | 8.925 ms |

At 128 children, parent-queue allocations fell from 830–852 to three per run,
and median worker-lock p95 fell from 6.50 ms to 3.36 ms. Every measured run
retained the expected process count, reported zero known loss, and serialized
successfully. Those observations do not establish fallback completeness for
shorter or unobserved descendants.

The steady workloads improve, and releasing the lock during fork waits reduces
burst peaks; burst p95 did not improve in these trials. Wide-tree stalls near
40 ms remain possible because discovery and metadata inspection still share
the collector mutex. An identity index or a larger ownership redesign needs
separate evidence; neither is implied by these measurements. The temporary
harness and raw before/after logs are in `/tmp/flamez-macos-profile-*` for this
workspace session.

## Tree layout and retained UI state

### Rebuilds are revision-gated

`Session` maintains separate topology, interval, and label revisions.

- Adding a process changes topology and rebuilds the tree.
- Exec and metadata changes update process/label revisions but do not rebuild
  tree geometry.
- Finishing a process changes interval state. While capture is live, existing
  lane assignments remain stable; intervals are repacked once capture is
  complete.
- Collapse changes have their own UI revision and rebuild only the row model.

The row model and scratch arrays retain capacity. Structural arrays and the
per-row interval trees and their node storage reserve for the retained process count. Job, height,
occupied-lane, free-lane, and lane-offset scratch buffers reserve only for the
local job or lane count instead of all being pre-grown to the total process
count.

### Packed sibling lanes use interval partitioning

`process_tree.layoutJobLanes` sorts sibling jobs by start time. One `std.PriorityQueue` min-heap
tracks occupied lanes by end time and another tracks reusable lane IDs. Lane
assignment is therefore `O(J log J)` after sorting instead of scanning every
existing lane for every job. Reusing the smallest available lane keeps the
layout deterministic.

Nested descendants retain depth-first placement order. Each candidate row uses
an intrusive `std.Treap` over its disjoint intervals to find overlaps in expected
logarithmic time. Nodes live in a retained array reserved before the rebuild,
so inserting intervals does not allocate. Zero-width intervals and equal start
times keep their existing placement semantics.

A ReleaseSafe benchmark on the review host used two overlapping jobs, one with
sequential nested children. One fresh tree rebuild measured:

| Children | Before interval indexing | After interval indexing |
|---:|---:|---:|
| 2,000 | 3.6 ms | 0.29 ms |
| 4,000 | 12.3 ms | 0.47 ms |
| 8,000 | 47.2 ms | 1.14 ms |
| 16,000 | 199.6 ms | 1.91 ms |

These single-run results characterize this shape on this host. Placement still
tries candidate rows in order; a large number of simultaneous intervals can
require trying many rows. A permanent regression bounds interval probes for
sequential children without asserting a machine-specific time limit.

Packed-row members are flattened into contiguous ranges and sorted by start
time. Rendering binary-searches the first member that can overlap the visible
window and stops once member start time reaches the window end. Very narrow
packed bars are reduced to one selected process per pixel column using reusable
column and touched-column buffers.

The row model still stores parallel arrays for traversal-friendly fields such
as first-child, next-sibling, slot, subrow, and lane height. Previously
write-only visual-parent, pack-root, pack-job, and slot-count arrays are no
longer retained.

## Rendering-specific optimizations

### Timeline work is bounded by the viewport

`renderTimeline` visits only the vertically visible row range plus one
partially visible row. Lifetime bars outside the visible time window return
before drawing.

CPU slices are time ordered. `Process.firstVisibleSlice` binary-searches the
first slice whose end can overlap the window, and the draw loop stops when a
slice starts beyond the window. Slices wide enough to display are drawn
directly. Subpixel slices are merged into reusable per-pixel columns; only
touched columns are cleared and emitted.

This keeps full-history CPU slices canonical while bounding the number of
timeline primitives by visible rows and horizontal resolution. Performance
telemetry records slices scanned versus primitives drawn.

Bar-label measurement caches the process name width and a name hash. Labels are
omitted when the name cannot fit, avoiding both unreadable output and work for
the longer summary label on narrow bars.

### The detail pane caches expensive derived views

Selected-process detail text is rebuilt only when the selected process
revision, selection, or wrapping width changes. Heap-backed text, line, and
line-height buffers are retained and grow geometrically if the builder
overflows. The reservation is estimated from retained exec metadata only when rebuilding,
so selecting a process with a very large argv can still cause a correspondingly
large one-time allocation.

Clipboard staging is separate and remains empty until the user copies selected
text. Hover tooltips use fixed-capacity text/line storage and cache by process
revision and width.

The full-lifetime CPU detail graph is reduced to one value per plot pixel. Its
column buffer is cached by process, process revision, lifetime range, and plot
width. Consecutive equal columns render as one run, so unchanged frames do not
rescan or redraw one primitive per canonical slice.

A ReleaseSafe microbenchmark on the review host averaged 100 rebuilds of a
1,000-pixel graph with alternating occupancy bands. At 1,000 / 10,000 / 100,000
retained slices, column preparation took 4.5 / 38 / 396 microseconds. Estimating
detail capacity for the same counts of retained execs took 1.2 / 14 / 132
microseconds. Capacity estimation now shares the detail cache gate. These
measurements isolate CPU preparation and exclude font shaping, drawing, and GPU
presentation; they do not establish whole-frame cost. The graph's live end time
still invalidates its cache, and full-range timeline rendering still scans
retained slices. No additional history index was justified by these results.

### Static captures skip unchanged frames

Live and interactive frames use vsync with no software FPS cap. Screenshot mode
disables vsync and uses a fixed 60 FPS clock for deterministic capture.

After the target exits, the main loop skips Clay layout, timeline work, detail
rendering, and buffer presentation until input, resize, mouse movement, or the
optional FPS display requires a redraw. It sleeps and polls input every 32 ms
while idle. Input starts a 120 ms vsync-paced rendering burst so a quiet input
sample cannot stall an in-progress gesture. A newly hit block replaces the
tooltip immediately, while one missing hit inside a timeline row retains the
previous tooltip to mask a transient gap. A second miss clears it. This reduces
completed-capture CPU and GPU use without changing the retained session.

Clay receives one fixed arena at startup. Most per-frame display strings use
stack buffers, and `App` retains viewport, tree, detail, and aggregation
buffers. The first frame at a new capture size, selection, or viewport width
may grow those buffers; stable frames reuse them.

4x MSAA and high-DPI rendering remain enabled by default. The build option
`-Dmsaa=false` disables MSAA when GPU fill or memory bandwidth matters more
than edge quality.

## Verification of performance-sensitive behavior

Tests protect the semantics behind the optimizations, rather than asserting
machine-specific timing thresholds:

- `Process.zig` covers same-band coalescing, idle gaps, final-total correction,
  and the visible-slice lower bound.
- `process_tree.zig` covers non-overlapping packed descendants; UI tests cover
  collapse state surviving rebuilds and packed-row collapse behavior.
- Detail-graph tests cover full-lifetime range and bounded core scaling.
- macOS collector tests cover queue overflow, PID-snapshot growth and bounded
  truncation, FIFO ownership, PID-generation rejection, per-PID CPU timestamps,
  and parallel-thread cumulative CPU.

These tests keep storage and culling changes from altering capture semantics.
They are not throughput benchmarks and do not establish a target-slowdown or
frame-time budget.

## Performance telemetry

Build with:

```sh
zig build -Dperf-telemetry=true
```

`src/perf.zig` compiles to no-op branches when disabled. When enabled, it
emits at most one scoped log line per second and one final session summary.

Timed phases are:

- lifecycle/ring polling;
- CPU snapshots;
- process-tree rebuilds;
- Clay layout and command playback;
- timeline rendering;
- detail rendering; and
- `endDrawing`.

Each periodic line covers the interval since the previous line. Logging uses
elapsed wall time, so a second of idle polling does not require a second of
rendering before the next report. `frames` and `max` cover all measured frames
in that interval; `recent_p50` and `recent_p95` cover its most recent 64 frames.
Phase fields ending in `_avg` divide accumulated phase time by the interval's
frame count, including frames where that phase did no work.

Counters record the latest process/metadata/slice shape, rebuilds and job
counts, delivered lifecycle events and CPU samples, and timeline slices scanned
versus drawn. Observation counters advance where `Session` receives a record,
including a record it cannot attribute; idle frames do not repeat a collector's
previous snapshot count. Successful CPU slice insertion and adjacent-band
coalescing update the final summary's `new_slices` and `coalesced` counters.
Idle samples and failed allocations do not count as slice growth.

The final summary's frame count and maximum cover the whole GUI session. Its
`recent_p50`, `recent_p95`, and `recent_p99` explicitly describe the most recent
64 frames, not a whole-session percentile estimate. All counters, phase totals,
and timing samples reset together at `beginSession`. Telemetry is main-thread
GUI instrumentation; headless capture does not emit frame summaries.

`-Dfps-counter=true` is separate presentation telemetry. It can force an
occasional completed-capture redraw so the displayed value remains current.

## Current scaling bounds

The code avoids many history-dependent frame costs, but it intentionally does
not impose a lossy session-history limit.

| Cost | Current shape and bound |
|---|---|
| Process and exec history | Grows for the full capture |
| Canonical CPU slices | Grows when active occupancy changes band; idle and adjacent equal bands are free |
| Metadata | Grows during capture, then compacts to reachable shared ranges |
| Tree rebuild | Visits retained processes when topology/collapse changes and once for final interval packing |
| Timeline draw | Visible rows, visible time ranges, and pixel-resolution aggregates |
| Detail graph | Canonical history scan only when its process/range/width cache is stale; drawing is width-decimated |
| Linux CPU snapshot | Batched reads over live process totals and all admitted thread entries |
| macOS CPU snapshot | One rusage and identity validation sequence per tracked PID |
| macOS fallback recovery | Recursive live-PID inspection every recovery wake plus event-triggered escaped-child scans |
| Producer memory | 16 MiB lifecycle queue/ring per active backend |
| Linux kernel memory | Fixed ring plus three 65,536-entry hashes |
| Signal-safe teardown | Fixed 65,536-entry atomic PID table; exact-slot removal during normal exits |
| Metadata compaction peak | Old store plus a replacement reserved to the old size and an offset-remap table |

Flamez does not currently truncate canonical CPU history, cap total historical
process records, impose a per-frame lifecycle drain budget, or shrink Linux BPF
maps dynamically. Those choices preserve capture fidelity and make any resource
boundary visible through allocation failure or loss accounting rather than
silently coarsening recorded data.
