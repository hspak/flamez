# Performance assessment

Date: 2026-08-28

This is a static review of the current Zig, C, eBPF, Clay, and raylib paths. It
does not claim a measured bottleneck yet. The first recommendation is therefore
to add counters and capture baselines before making the structural changes
below.

## Executive summary

Flamez has a sound performance baseline for small and medium captures:

- lifecycle traffic is filtered in the kernel;
- scheduler switches update maps instead of producing userspace events;
- map reads are batched 256 entries at a time;
- forked processes share immutable metadata bytes;
- CPU activity is quantized and adjacent equal bands coalesce;
- Clay uses fixed arena memory, most transient strings are stack-backed, and
  the UI retains heap capacity;
- tree geometry is revision-gated, timeline drawing is vertically culled, and
  detail text is cached.

The normal warmed-up frame is therefore mostly allocation-free. New process
records, new CPU bands, larger tree caches, and newly selected detail text are
the expected exceptions.

The scaling risks are historical rather than constant overhead. CPU samples,
metadata, process records, and UI indexes all grow for the full capture. Some
render paths then scan or draw that history every frame. At the same time, the
collector snapshots all live CPU map entries at the render rate. Those costs
will eventually dominate a long or highly parallel build even though the
steady-state design is otherwise careful.

The recommended order is:

1. instrument representative captures;
2. cull optional behavior that makes interaction, memory use, target
   distortion, or measurement integrity worse;
3. remove unused UI arrays and redundant scratch preallocation;
4. decouple CPU sampling from 60 FPS and batch the C-to-Zig handoff;
5. time-cull and pixel-aggregate CPU slices before drawing;
6. narrow tree invalidation and improve the packed-lane algorithm;
7. compact metadata/detail storage and only then consider lower-level render
   batching or BPF map changes.

## Product rule: cull before optimizing, preserve measurement integrity

Performance and measurement integrity are both part of the product, especially
for a profiler. A feature is not worth preserving merely because its
implementation can be optimized. If it causes visible hitches, unbounded
memory, unstable layout, excessive battery use, material target slowdown,
dropped events, biased timing, or misleading precision, remove or reduce the
feature unless it is essential to Flamez's core job.

The core experience to protect is small:

- exact process lifecycle and parentage;
- trustworthy process lifetime and total self-CPU accounting;
- a documented temporal-resolution contract for CPU activity;
- explicit loss, truncation, and precision boundaries rather than silent
  degradation;
- a responsive, stable flamegraph that does not materially distort the target;
- enough identity to understand what each process was doing.

Everything beyond that is negotiable. The first culling candidates are:

- coupling capture cadence to render cadence: collect on an independent,
  accuracy-tested schedule and let rendering consume the latest snapshot;
- one hover target per original CPU slice: show a derived pixel/time-bucket
  aggregate without discarding the canonical collected slices;
- the full selected-process CPU graph if it duplicates the timeline without
  adding enough value;
- mouse text selection and retained clipboard staging in the detail pane if
  their memory and complexity remain material after lazy allocation;
- continuous 60 FPS redraw after capture completion;
- optimal live lane repacking when stable, slightly sparse lanes are easier to
  follow and cheaper to maintain;
- rounded corners, outlines, four-times MSAA, high-DPI rendering, or labels on
  bars too narrow to read.

Cull presentation and optional subsystems before reducing canonical capture
precision. Pixel aggregation, fewer labels, and a simpler detail pane are safe
when they remain derived views over unchanged source data. Lower sampling,
truncated argv, compacted history, or disabled CPU activity change the collected
dataset and therefore require an intentional schema/product decision plus an
accuracy test against a higher-fidelity reference.

Culling must be explicit rather than silent. If Flamez intentionally stops
collecting a field, shortens a capture, or lowers temporal resolution, expose
that boundary in the UI and session summary. If an optional feature cannot
operate without drops, skew, or material observer effect, remove the feature
instead of presenting compromised data as trustworthy.

### Accuracy and precision risks to remove or represent honestly

Several current recovery/boundary behaviors preserve a visible row by placing
an inferred value into a field that otherwise means “observed.” That is useful
for continuity, but it must not look equally authoritative:

- a lost fork can create a parent stub under the root with the later event time
  as its start;
- an unknown exec is attached under the root even though its true parent is
  unknown;
- an exit-only recovery becomes a zero-width lifetime even though only the
  death timestamp is known;
- root exit and forced Stop close every open descendant at the capture boundary,
  which is not proof that each descendant exited then;
- forced Stop retains the last userspace CPU snapshot rather than an exact
  kernel final total;
- live CPU buckets have documented map-read/timestamp skew and already trade
  scheduler-transition precision for quarter-core-band coalescing.

Do not solve these cases by inventing plausible precision. Represent observed,
inferred, unknown, and capture-clipped values separately, for example with a
compact provenance/end-kind flag. Exclude inferred values from calculations
that claim exactness. If the model or UI cannot communicate uncertainty without
becoming confusing, cull the inferred field or row rather than displaying it as
measured fact. A visible gap is more accurate than a fabricated interval.

The dropped-event counter is necessary but not sufficient: once lifecycle loss
occurs, the session should be visibly marked incomplete, and export/summary
consumers must receive that state. Natural-exit CPU reconciliation should have
tests against the kernel total; forced-stop results should be labeled partial.

## Priority findings

| Priority | Finding | Scaling shape | First action |
|---|---|---|---|
| High | CPU maps are fully snapshotted, sorted, merged, and dispatched once per UI frame | `O(F * (P log P + T log P))` | Decouple sampling from rendering; choose cadence from a precision/error budget |
| High | CPU-slice storage is unbounded and visible processes scan every historical slice | memory `O(S)`, frame work `O(visible S)` | Binary-search the visible time range and aggregate to pixel columns |
| High | Process-tree/layout rebuilds are broad and packed-lane assignment can become quadratic | rebuild `O(N + sum(J * lanes))` | Split revision reasons and use an interval-partition heap |
| High | Secondary features can consume resources or perturb the target without improving the primary graph | workload-dependent | Remove them when they breach UX or accuracy budgets; do not optimize by default |
| High | Recovery and capture-boundary values can appear as precise as observed lifecycle data | correctness/interpretation | Track provenance or cull inferred values; mark the session incomplete after loss |
| Medium | The UI keeps many parallel arrays, including four that are never read | at least 50 unused bytes/process before spare capacity | Delete write-only arrays; stop pre-growing local scratch to `N` |
| Medium | Metadata and selected-detail storage duplicate potentially large argv/path content | `O(total exec metadata)` | Avoid identical CWD writes; grow clipboard only on copy |
| Medium | raylib API calls are internally batched, but shapes and three font atlases are interleaved | many render groups and possible batch flushes | Count actual render groups, then stage compatible shape/text passes |
| Medium | `by_pid` retains finished PIDs although lookups mostly need live processes | `O(distinct historical PID)` | Make the primary index live-only; keep a small duplicate-exit policy if required |
| Measure | Three 65,536-entry kernel hashes plus a 16 MiB ring are fixed startup memory, and the scheduler hook runs system-wide | fixed memory plus work per context switch | Measure target slowdown and map memory before changing correctness-oriented sizing |

`F` is CPU snapshot frequency, `P` is the number of live processes, `T` is the
number of currently running tracked threads, `S` is stored slices, `N` is all
captured processes, and `J` is a sibling job group.

The no-loss natural-exit path is designed to preserve lifecycle and final CPU
totals. The recovery and forced-boundary paths need provenance before their
values should be described as equally exact. Elsewhere, “High” means the item
is a likely scaling limit under the workloads Flamez is designed to observe.

## Memory allocations and ownership

### What is already good

`Session`, `App`, and the C snapshot bridge consistently retain capacity. Clay
gets one arena at startup. View labels and hover storage are stack-backed. The
C bridge grows `cpu_totals` geometrically and reuses it. These choices avoid a
general-purpose allocation storm on every frame.

The session metadata arena is also a good fit for ownership: process records
store offsets, so growing the arena cannot invalidate them, and a fork can copy
three offset/length pairs rather than duplicate argv, executable, and CWD bytes.

### CPU-slice ownership is the main long-run allocation risk

Each `Process` owns an `ArrayList(CpuSlice)` (`src/tracer/Process.zig:24`). A
new allocation/growth occurs whenever activity cannot merge with the last
quarter-core band (`src/tracer/Process.zig:129-150`). Idle snapshots are free
and equal neighboring bands merge, which is valuable, but alternating bands
can still create one slice per sample.

On the current x86-64 Zig 0.16 build, compile-time sizes are:

| Type | Size |
|---|---:|
| `Process` | 216 bytes |
| empty `ArrayList` header inside each process | 24 bytes |
| `CpuSlice` | 32 bytes |
| `App.GraphRow` | 56 bytes |
| `?usize` | 16 bytes |

At 60 snapshots/second, a continuously busy process whose band alternates can
add 1,920 bytes/second of slice payload before allocator spare capacity. This
is a worst case, not a prediction, but it demonstrates that coalescing does not
provide a hard bound.

Recommended response:

- Measure total slice count, total capacity, median/p95/max slices per process,
  coalescing rate, and bytes per captured second.
- Do not lower the CPU sampling rate solely to save memory. First define and
  test the temporal-resolution contract. Cumulative accounting and exact
  final-exit totals preserve total CPU, but a lower rate still reduces the
  precision of activity timing.
- If most processes have one or two slices, compare a small inline prefix or a
  session-owned slab against the current one-allocation-per-active-process
  shape. Do not add a large inline array blindly: it would inflate all 216-byte
  records, including processes with no CPU slice.
- Define an explicit long-capture policy. Prefer retaining canonical slices and
  building a multiresolution render index beside them. If canonical history
  must be bounded, end/segment the capture or declare the older interval
  coarsened; never silently replace precise samples with buckets while
  presenting the session as lossless.

### The metadata arena retains superseded and duplicate bytes

The append-only arena is simple and makes inherited metadata sharing cheap,
but an exec clears the record's argv/executable offsets and appends replacements
(`src/tracer/Session.zig:544-579`). Old bytes remain because a forked child may
still reference them. Some old bytes will have no remaining reference, but the
arena cannot reclaim them.

There is also a concrete avoidable duplicate: every exec calls `refreshCwd`,
which appends CWD bytes even when the process inherited and retained the exact
same CWD. Large builds commonly run thousands of children from one directory.

Recommended response:

- Before `setCwd`, compare against the current stored CWD and retain the old
  offset when equal. Apply the same compare-before-append rule to paths where it
  is cheap.
- Track total metadata bytes, reachable bytes, bytes by argv/exe/CWD, and the
  duplicate-CWD hit rate.
- Decide whether complete historical argv belongs to the canonical dataset. It
  is the dominant legitimate payload and can be up to the 6 MiB exec bound. If
  it is canonical, preserve it and cull optional consumers/copies first. If it
  is not, remove it from the schema intentionally and expose the resulting
  identity boundary; do not silently truncate a field that claims completeness.
- Consider compaction only at a quiet boundary, such as capture completion.
  Rebuilding the arena while events are arriving adds complexity and copies
  exactly when the UI is busiest.

### Selected-process detail storage is too eager

Selecting a process sizes four retained buffers. `detailCapacity` estimates one
line per eight argument bytes and includes a clipboard buffer large enough for
the complete text (`src/main.zig:1737-1747`, `2308-2314`). For a pathological
multi-megabyte argv this can reserve tens of MiB in `TooltipLine` entries plus a
second large byte buffer before the user copies anything.

Recommended response:

- Let the existing geometric overflow/retry loop size display storage from the
  actual wrapping result instead of preallocating the eight-byte worst case.
- Allocate/grow clipboard staging only on Ctrl+C. It need not mirror selected
  detail capacity for the lifetime of the app.
- Longer term, avoid materializing a second space-joined copy of all argv for
  display. A wrapped iterator over NUL-separated metadata can preserve empty
  arguments without duplicating the complete block.

### Fixed kernel memory is intentional but should be visible

The collector creates a 16 MiB ring and three 65,536-entry hash maps with flags
zero (`src/flamez.bpf.c:47-90`). The signal-safe userspace PID table is another
fixed 65,536 atomic entries (`src/tracer/signals.zig:31-40`). This avoids
allocation and admission surprises in hot tracepoint paths, so it is a valid
speed/correctness tradeoff, not automatically waste.

Expose or document the kernel-memory footprint. Only reduce map sizes or use
non-preallocated hashes after measuring peak live processes/threads and loss
behavior; allocation failure inside a scheduler tracepoint is worse than a few
idle MiB for Flamez's correctness.

## Rendering and work dispatch

### Vertical culling is good, temporal culling is incomplete

`renderTimeline` draws only the visible row interval
(`src/main.zig:1451-1452`). That is the right first-level cull. A visible row,
however, calls `paintCpuSlices`, which starts at slice zero and scans the entire
history (`src/main.zig:994-1015`). Slices are already time ordered, so a lower
bound on `end_ns` can jump directly to the first possibly visible slice and stop
when `start_ns` passes the window.

Time culling alone is not enough for a long full-run view. Hundreds of slices
may map to the same horizontal pixel. Convert visible slices into at most one
or a small fixed number of primitives per pixel column, preserving a defined
signal such as maximum band, CPU-weighted occupancy, or total CPU. Hover should
query the original range only for the pointed column.

Packed rows have a second escape hatch around vertical culling: one visible
slot walks every linked member (`src/main.zig:1564-1599`). A lane containing
thousands of non-overlapping jobs can therefore make one visible row expensive.
Store packed members in start-time order and range-query the visible window, or
maintain a compact interval index for each packed row.

### The detail graph redraws all history

Every visible detail graph scans all slices once to find its core scale and
again to emit a rectangle and several line primitives per slice
(`src/main.zig:1757-1763`, `1872-1924`). Cache the scale or maintain it while
recording samples, and build a width-dependent decimated series. The graph is
about one thousand pixels wide; drawing more than roughly that order of data
cannot add horizontal information.

### raylib batches calls, but current ordering fragments the batch

It would be inaccurate to treat each `drawRectangle*`, `drawLine*`, or
`drawText*` call as an immediate GPU dispatch. raylib queues geometry in rlgl.
However, texture or primitive-mode changes create new internal draw groups, and
the bundled raylib flushes after 256 draw groups. Shapes use the shapes texture;
text uses one of three font atlases. The current row order is commonly:

1. bar shape and outline;
2. row-font text;
3. CPU rectangles/lines;
4. repeat for the next process.

That repeatedly switches shape → font → shape. Clay chrome also emits commands
in painter order and moves among UI, row, and footer fonts.

Recommended response:

- Instrument rlgl draw-group count, vertex count, automatic flush count, and
  time in `endDrawing` before creating a custom renderer.
- Within the timeline scissor, stage compatible passes where painter order
  permits: backgrounds/bars, CPU overlays/outlines, then labels and controls.
  Drawing labels last also prevents tall CPU overlays from obscuring them.
- Keep the number of scissor transitions small because render-state changes can
  force synchronization. The current top-level timeline/detail/tooltip regions
  are reasonable; avoid introducing one scissor per row.
- Cache static label summaries or their clipped prefix by process revision and
  width bucket if text measurement appears in profiles. `name_revision` was
  apparently intended for such a cache but is currently never read.
- Treat rounded rectangles, four-times MSAA, and high-DPI fill cost as
  conditional quality knobs. Cull them immediately if GPU timing or battery
  use shows pressure; they are not part of the profiler's core value.

### Rendering and CPU sampling should not share one frequency

The app snapshots CPU immediately before every rendered frame
(`src/main.zig:209-230`, `src/tracer/Session.zig:176-187`). The C bridge batch-
reads every live process total, sorts by TGID, binary-searches that array for
each running thread, and makes one C-to-Zig callback per process
(`src/ebpf_shim.c:675-799`). At 60 FPS this is usually far more temporal detail
than a process flamegraph can display.

Keep lifecycle ring polling frequent and schedule cumulative CPU snapshots on
an independent fixed cadence. Compare candidate cadences against a
higher-frequency reference, including short bursts and parallel occupancy, then
choose the lowest rate that satisfies the documented temporal error/resolution
budget. A 20 Hz experiment is useful, but it is not an acceptable default merely
because it is cheaper. If 60 Hz is needed for precision, cull optional UI work
and optimize snapshot transport instead.

Pass the snapshot array across the C/Zig boundary once instead of invoking one
callback per TGID. If snapshot profiles remain material, replace the per-frame
`qsort` plus binary searches with a reusable flat hash/index. These changes
preserve the collected values and should precede any reduction in cadence.

The zero-timeout ring poll can also consume a large burst on the render thread.
Count events and poll duration per frame. If bursts cause frame misses, cull
render/detail work or move ingestion to a collector thread before imposing a
drain budget that could overflow the ring and lose lifecycle records. Any
bounded queue must surface overflow and mark the capture incomplete rather than
quietly continue with an inaccurate tree. The threaded option is a later step
because it changes ownership and teardown.

### Static captures should not require a permanent 60 FPS loop

After the target exits, most of the screen is static. Continue at 60 FPS while
dragging, scrolling, hovering, or animating, but otherwise redraw on input,
resize, exposure, or a low-rate idle tick. This is primarily an energy and
laptop-thermals win; it can also make completed large captures feel lighter.
If reliable event-driven redraw is awkward, a low idle frame rate is preferable
to preserving 60 FPS for a static screen.

## Data structures and retained data

### Remove known write-only state first

The following fields are allocated, initialized, and written but never read by
production code:

- `App.visual_parent`;
- `App.pack_root`;
- `App.pack_job`;
- `App.slot_count`;
- `Process.name_revision`;
- `Process.args_source`, `exe_source`, and `cwd_source` outside tests.

The four UI arrays alone consume 50 bytes per process on x86-64 before
`ArrayList` spare capacity: three `?usize` arrays at 16 bytes each plus one
`u16` array. Removing them also removes four allocations and four full-array
initialization passes.

Separately, `rebuildProcessTree` pre-grows `jobs_scratch`, `heights_scratch`,
`free_at_scratch`, and `lane_offsets_scratch` to all `N` processes
(`src/main.zig:550-553`). Their consumers already ensure capacity for the
actual job/lane count (`src/main.zig:733-749`, `836-839`). Delete the global
`N` pre-growth. Keep `roots_scratch` bounded by actual root count as well.

These changes are low risk and should precede a container redesign.

When removing a field, leave a concise comment at the place where the value is
still produced or can be derived. The comment should say that Flamez
intentionally does not retain it and name the recovery source so a future
revision does not have to rediscover the data path. For example:

```zig
// Parent PID is derived from parent_index; fork events still provide it if
// direct storage is needed again.

// Metadata provenance is intentionally not retained; the setter/ingestion path
// identifies whether the bytes came from launch, the kernel, or procfs.
```

Prefer one comment at the relevant ingestion or type boundary over a graveyard
of deleted field names. The purpose is to preserve the design decision and the
route back to the data, not to keep dead declarations in memory.

### Consolidate the per-process UI index

After dead fields are removed, the remaining parallel arrays form a clear
per-process layout index: first child, next sibling, visual depth, packed slot,
slot link, lane offset, and collapsed state. A `MultiArrayList`-style structure
would use one allocation while retaining structure-of-arrays traversal. It also
makes it harder for lengths to diverge.

Indexes currently use `usize` and `?usize`; the optional form is 16 bytes here.
If the session adopts an explicit maximum process-record count, a `u32` index
with a sentinel can reduce these arrays substantially. Do not narrow indexes
without a stated bound: the 65,536 kernel limit is for simultaneously tracked
entries, not total historical processes in a long session.

There is also duplicated identity/shape state worth resolving:

- `Process` stores both `parent_pid` and stable `parent_index`; the PID can
  normally be derived from the indexed parent.
- `Process.depth` and `App.visual_depth` describe the same current tree in the
  normal path.

Choose one source of truth for each invariant. Keep duplication only if lost-
event recovery requires different semantics, and document that difference.

### Narrow tree invalidation

`tree_revision` changes on process add, process finish, and exec
(`src/tracer/Session.zig:215-247`, `265-272`, `544-553`). An exec changes a
label/metadata but not topology. A finish changes an interval but not parentage.
During process churn these invalidations make the full revision-gated cache
rebuild nearly every frame.

Split at least topology, interval/packing, and label revisions. Additions must
update topology. Exec should not rebuild tree geometry. Finished intervals can
leave a valid, possibly non-minimal lane assignment in place during capture and
be compacted later, or packing can be debounced. Stable lanes are also easier
for users to follow visually than continuous optimal repacking.

### Use an interval-partition structure for packed lanes

`assignJobSlots` sorts jobs by start and then linearly scans all existing lanes
for a free one (`src/main.zig:827-864`). When many sibling jobs overlap, this is
quadratic. Use the standard interval-partition approach with a min-heap keyed by
lane end time, optionally paired with a free-lane-ID heap for stable small lane
numbers. That gives `O(J log J)` after sorting and directly models the decision
being made.

### Keep the PID hash live-only

`Session.by_pid` maps to the latest record but is not removed in
`finishProcess`. It therefore grows with distinct historical PIDs even though
`liveIndex` is its hot use. Remove an entry at finish only when it still points
to that generation. If duplicate-exit suppression is important, retain a small
recent-finished set or make duplicate exits harmless without preserving the
entire live lookup table.

### Measure the global scheduler-hook tax

Every system context switch executes the Flamez raw tracepoint. The fast path
still performs a running-thread lookup for the outgoing TID and a tracked-TGID
lookup for the incoming thread (`src/flamez.bpf.c:128-178`, `425-437`). This is
far better than emitting each switch, but it is work imposed system-wide and is
not represented by Flamez's own frame time.

Benchmark target wall time and system CPU with Flamez attached versus the same
command without Flamez. This overhead may be acceptable, but it needs an
explicit budget because the profiler must not materially distort the build it
is observing.

## Measurement plan

Add a compile-time performance telemetry mode with one summary line per second
and a final session summary. Avoid logging every event.

Record:

- frame CPU time and p50/p95/p99/max, split into ring poll, CPU snapshot, tree
  rebuild, Clay layout, Clay playback, timeline, detail, and `endDrawing`;
- allocations/reallocations and requested bytes by process records, metadata,
  slices, UI tree caches, and detail buffers;
- live/total processes and threads, metadata live/arena bytes, slice
  count/capacity, new-versus-coalesced slice ratio, and maximum slices/process;
- tree rebuild count/reasons, processes visited, jobs sorted, lanes scanned,
  visible rows, visible packed members, slices scanned, slices drawn, and
  primitives after pixel aggregation;
- CPU snapshot entry count, batch syscall count, sort time, C-to-Zig callback
  count, ring events drained, and ring-poll duration;
- lifecycle loss/recovery count, snapshot timestamp skew, temporal error against
  a higher-cadence reference, and final self-CPU error against an independent
  process-accounting reference;
- rlgl vertices, render groups, batch flushes, and font/shape texture switches;
- process RSS/peak RSS and BPF map/ring memory;
- observed target wall-time slowdown with tracing enabled.

Use at least these workloads:

1. high churn: tens of thousands of very short fork/exec/exit processes;
2. high parallelism: a real `ninja -jN`, `make -jN`, or Zig build;
3. long CPU history: several minutes with occupancy deliberately changing
   between bands;
4. metadata stress: large argv and many children sharing one CWD;
5. completed-capture interaction: zoom, pan, hover, select, and scroll through
   a large static session.

Measure an installed ReleaseSafe build, not the development artifact. Establish
budgets only after the first baseline; useful starting goals are no unexpected
per-frame allocations after warmup, p95 live frames below the 16.7 ms 60 FPS
budget, bounded completed-capture redraw cost at a fixed viewport, and an
explicit maximum acceptable slowdown of the traced command. Accuracy budgets
belong beside them: no unexplained lifecycle loss, no capture presented as
complete after overflow, exact final CPU totals within the accounting contract,
and a stated maximum temporal error for activity slices.

Use those budgets as deletion gates. When a secondary feature breaches one,
first disable it and measure the experience without it. Restore it only when
the user benefit is clear and its implementation fits comfortably inside the
budget. Do not let telemetry work become a reason to retain obvious dead state
or obviously unreadable detail.

## Proposed implementation sequence

### Phase 0 — product cuts

1. Classify each retained field and rendered feature as core, useful, or
   optional.
2. Remove known dead state immediately, leaving a source/derivation comment for
   values that remain available if the design is revisited.
3. Define canonical-data and precision contracts. Cull optional fields instead
   of silently truncating them; bound derived detail-pane and per-pixel render
   work without changing the source capture.
4. Disable continuous completed-capture redraw and unreadable narrow-bar labels.
5. Keep lane positions stable during capture instead of preserving optimal
   packing at the expense of responsiveness or visual continuity.

### Phase 1 — low-risk cleanup and observability

1. Add the counters/timers above.
2. Remove write-only arrays/fields and redundant `N`-sized scratch reserves.
3. Avoid identical CWD appends.
4. Grow clipboard staging only on copy and remove eager worst-case detail-line
   allocation.
5. Stop exec-only metadata changes from invalidating tree geometry.

### Phase 2 — control history-dependent cost

1. Sample cumulative CPU independently from rendering, validate candidate
   cadences against the precision contract, and batch the snapshot handoff.
2. Binary-search visible slice ranges.
3. Pixel-aggregate timeline slices and decimate the detail graph as derived
   views without discarding canonical samples.
4. Range-query packed-row members by time.
5. Define and test the long-capture CPU-history retention policy; any lossy
   policy must be an explicit dataset boundary, not an invisible optimization.

### Phase 3 — improve scaling structures

1. Replace linear lane scans with interval partitioning.
2. Consolidate UI arrays and consider bounded compact indexes.
3. Make `by_pid` live-only.
4. Consider a pooled slice representation after measuring the one/two-slice
   distribution.
5. Compact reachable metadata at capture completion if arena waste is material.

### Phase 4 — conditional rendering/capture work

1. Reorder compatible shape/text passes if rlgl metrics show excessive groups.
2. Add idle/event-driven rendering for completed captures.
3. Consider a collector thread only if bounded main-thread polling still misses
   frame budgets.
4. Tune BPF map/ring sizes only from observed peaks and loss tests.

The key design principle is to make per-frame work depend on the viewport and
current activity, not the full duration or total historical process count. The
current code already applies that principle to rows; extend it to CPU history,
packed members, snapshots, and retained indexes. Where that is still too
expensive, reduce the feature. Core capture fidelity matters; secondary
fidelity and visual polish do not outrank a fast, stable user experience, and
no optimization outranks truthful data.
