# Threading experiment: capture versus presentation

This document defines an experiment, not an implementation commitment. The
question is whether Flamez can present frames more consistently when capture
and data preparation cannot consume the renderer's frame deadline.

The blunt version of the hypothesis is narrow: threading can improve visible
frame pacing only when non-render work is causing missed presents and the
renderer can reuse a coherent older snapshot instead of waiting. It cannot
make an over-budget renderer or GPU faster. Repeating an old frame also trades
stutter for data age and input latency, so FPS alone is not a success metric.

The raylib window, input polling, Clay, OpenGL calls, and buffer presentation
stay together on the OS main thread throughout the experiment. The identity
of the thread is irrelevant to the performance claim; separation between the
presentation owner and the producer is what matters. Moving the graphics
context between threads would add platform and library behavior to the test
without increasing the available parallelism.

Related docs: [PERF.md](PERF.md) describes the broader performance model,
[ARCHITECTURE.md](ARCHITECTURE.md) describes session ownership, and
[EBPF.md](EBPF.md) describes collection.

---

## 1. Question and hypotheses

The current live frame is one serial deadline:

```
input
  -> drain lifecycle events
  -> snapshot and apply CPU totals when due
  -> rebuild derived tree state when stale
  -> Clay layout
  -> timeline and detail preparation/playback
  -> raylib submission
  -> swap at vsync
```

All of this runs in `src/main.zig`. `Session.update` performs lifecycle polling
and periodic CPU snapshots before layout and drawing begin. A burst in any
earlier phase can therefore miss the same vblank as rendering.

The experiment distinguishes three hypotheses:

- **H0 — threading is irrelevant:** misses come from timeline/detail drawing,
  GPU work, buffer presentation, or external scheduling. Moving capture work
  does not materially improve frame intervals.
- **H1 — collector separation is sufficient:** ring polling and CPU map
  snapshots have variable latency. Performing those operations on a worker
  reduces misses even if the main thread still applies every result to
  `Session`.
- **H2 — presentation must tolerate stale state:** applying capture results or
  rebuilding display state is also bursty. Stable presentation requires the
  main thread to draw the newest completed immutable snapshot and repeat the
  previous one when no new snapshot is ready.

H2 is the expensive design. Do not build it unless the earlier measurements
show that H0 is false and that H1 leaves meaningful producer-side misses.

## 2. Invariants and non-goals

The experiment must preserve these invariants:

- The raylib/Clay owner never takes a lock that can wait for the collector or
  snapshot producer.
- A mutable `Session`, `Collector`, or `App` has exactly one owning thread.
- Published display state is immutable for as long as the renderer can read it.
- Lifecycle events are never silently discarded or reordered.
- Scheduled CPU samples are never silently discarded. CPU temporal resolution
  is capture fidelity, not expendable presentation state.
- It is acceptable to skip an intermediate *display publication*. The next
  publication must still contain all canonical capture changes.
- Stop, window close, natural target exit, and fatal-signal teardown retain the
  existing no-orphan guarantee.
- Queue saturation, stale snapshots, collection loss, and missed publications
  are measured and exposed. None is treated as a normal success path.
- Allocator use is either owned by one thread or explicitly thread-safe.

This experiment does not attempt to:

- exceed the monitor refresh rate;
- call raylib or Clay concurrently;
- parallelize individual draw calls;
- hide lower CPU-sampling precision behind smoother animation;
- redesign the process tree, lane packer, or renderer unless a measured phase
  is independently over budget;
- ship a permanent worker or queue before it passes the decision gates below.

## 3. Measurement required before threading

The existing `-Dperf-telemetry=true` mode is the starting point, but its phase
fields describe the frame that happened to trigger the one-second log. Extend
it so every phase has an in-memory p50, p95, p99, and maximum for the whole
measurement interval. Do not log once per frame.

Record at least:

- frame start-to-start interval and complete frame duration;
- expected vblank interval and counts above 1.25, 1.5, and 2.0 vblanks;
- ring poll, CPU snapshot, capture-result application, tree rebuild, Clay
  layout/playback, timeline, detail, and `endDrawing` distributions;
- lifecycle events and CPU entries produced and consumed per interval;
- queue depth in items and bytes, oldest-item age, and saturation count;
- display snapshot generation, publication age, repeated-frame count, and
  skipped-publication count;
- process count, slice count, visible rows, slices scanned, and slices drawn;
- Flamez CPU time, RSS/peak RSS, and traced-target wall time;
- lost events, inferred recovery, final CPU totals, and target-exit result.

Use monotonic timestamps captured at the producer, publication, render
acquisition, and end of presentation. Snapshot age means render-acquisition
time minus publication time. Do not infer it from queue length.

Add one experimental build option with explicit variants rather than unrelated
booleans:

| Variant | Meaning |
|---|---|
| `single` | Current ownership and scheduling, with improved telemetry only. |
| `batched` | Refactored batch interface, still called synchronously on the main thread. |
| `collector` | Collector work on a worker; main thread applies complete batches. |
| `snapshot` | Worker-owned canonical session and immutable display publication. |

The exact option spelling can follow the build API available in Zig 0.16. The
important requirement is that all variants compile from the same commit and
that `single` remains an unthreaded control.

## 4. Workloads and test protocol

Measure an installed ReleaseSafe build with vsync enabled. Keep display,
refresh rate, compositor, window size, high-DPI mode, MSAA setting, CPU power
profile, and target parallelism fixed. Record them with every result.

Use these workloads:

1. **Presentation floor:** a completed large capture while idle. Exercise zoom,
   pan, hover, selection, and scrolling separately. This isolates renderer and
   interaction cost from live collection.
2. **High churn:** tens of thousands of short fork/exec/exit processes. This
   stresses lifecycle polling, result application, and topology rebuilds.
3. **High parallelism:** a real Zig, Ninja, or Make build at a fixed `-j` value.
   This stresses CPU map snapshots and many simultaneous live processes.
4. **Long history:** several minutes of changing CPU occupancy. This separates
   history-dependent timeline/detail work from collection latency.
5. **Controlled stalls:** an experiment-only producer probe injects a known
   deterministic sequence of 4, 8, 16, and 24 ms delays before publication.
   This establishes the best possible pacing benefit and verifies stale-frame
   accounting; it is not evidence that real collection has those costs.

Run each real workload at least five times per variant. Alternate variant order
to reduce warm-cache and thermal bias. Ignore startup and font-loading frames,
but do not discard later outliers. Report the median of run-level percentiles
and retain each run's maximum.

Before testing a worker, capture the `single` baseline and set the provisional
decision thresholds in section 8. Thresholds may be revised once from that
baseline, before threaded results are viewed; they must not move afterward.

## 5. Stage A: make collection return owned batches

First separate collection from mutation without creating a thread.

Today the eBPF callback reaches a global active `Session` and mutates it while
the ring is polled. Replace that coupling with a batch contract:

- lifecycle polling appends copied, validated records to collector-owned batch
  storage in callback order;
- a due CPU snapshot appends its timestamp and cumulative totals;
- loss counters and collection diagnostics travel with the batch;
- `Session.applyBatch` performs the existing canonical mutations in the same
  order on its owning thread;
- batch storage has explicit ownership and can be returned to the producer for
  reuse only after consumption.

Run this as the `batched` variant on the main thread. It must produce the same
session behavior as `single` before any concurrent execution is introduced.
This control separates the cost of copying/batching from the effect of a
worker.

Required tests:

- applying an ordered synthetic event stream directly and through arbitrary
  batch boundaries produces identical canonical session state;
- fork/exec/exit ordering and PID reuse survive a boundary between every pair
  of records;
- CPU slice output is identical when batch boundaries do and do not coincide
  with a CPU sample;
- loss and malformed-record handling are identical;
- allocation failure leaves ownership clear and marks capture incomplete when
  fidelity cannot be preserved.

If `batched` causes a material regression by itself, stop. A worker should not
be used to disguise an unnecessarily expensive handoff.

## 6. Stage B: collector worker

The `collector` variant moves only kernel-facing collection work to a worker.
The main thread continues to own `Session`, `App`, Clay, and raylib.

Use a single-producer/single-consumer handoff of complete owned batches. The
worker polls lifecycle events frequently and takes CPU snapshots on the
existing 16 ms capture cadence. The main thread acquires and fully applies
available batches before building the frame.

The queue policy is deliberately strict:

- preallocate/reuse storage for the normal path;
- preserve lifecycle record order across batches;
- do not overwrite CPU samples merely because a newer cumulative total exists,
  because doing so changes activity timing;
- never drop lifecycle records to protect FPS;
- measure backlog and saturation;
- if the consumer cannot keep up, fail the variant rather than quietly changing
  capture semantics.

Input actions that affect collection use a small command mailbox. `Session`
still belongs to the main thread in this variant, so the worker may not perform
its state transition. A Stop request must terminate the target promptly through
the existing signal-safe target-group path, tell the worker to stop admission
at a defined capture boundary, apply every batch accepted before that boundary,
and only then finish the main-thread `Session`. The acknowledgement is observed
asynchronously; rendering does not wait for it. Shutdown joins the worker before
collector or batch storage is destroyed. A second termination signal must
retain the existing emergency teardown behavior.

This stage answers H1. If syscall/map work is the source of jitter, frame
intervals should improve without stale display snapshots. If result application
or tree rebuilds still spike, the telemetry should say so explicitly.

## 7. Stage C: immutable display snapshots

Build the `snapshot` variant only if Stage B demonstrates producer-side value
but cannot keep presentation within the agreed budget.

In this variant the worker owns `Collector` and mutable `Session`. The main
thread owns `App` and rendering. Between them is a bounded pool of immutable
`DisplaySnapshot` generations containing exactly the session fields required
to build the visible UI. Canonical capture storage remains worker-owned.

Publication follows these rules:

1. The producer selects a slot not held by the renderer.
2. It brings that slot to one coherent session generation.
3. It publishes the generation with release semantics.
4. At frame start, the renderer acquires the newest published generation.
5. If none is newer, the renderer repeats its current snapshot without waiting.
6. A slot returns to the producer only after the renderer releases it.

If every slot is busy, the producer skips display publication and continues
canonical capture. It does not block collection and does not alter the session.
The UI then displays an older generation, and telemetry records the skipped
publication and age.

Do not protect the live session with a render-side mutex. Do not publish slices,
metadata, or process arrays whose backing allocations the producer can grow or
free. A copied full session may be acceptable for an initial bounded probe, but
publication bytes and time must be reported; it is not a viable result if copy
cost merely moves the missed deadline to another core. A production candidate
would need incremental immutable pages or another measured ownership scheme.

UI commands such as Stop remain mailbox messages. Selection, zoom, scroll, and
collapse remain main-thread `App` state keyed by stable process identity. The
renderer must handle a selected process that is absent from an older or newer
snapshot without dereferencing stale storage.

This stage answers H2. Its improvement is valid only while snapshot age and
input latency remain inside their own budgets.

## 8. Decision gates

Use baseline-informed thresholds fixed before threaded results are inspected.
The following are provisional starting gates for a 60 Hz display:

- at least 50% fewer frame intervals above 1.5 vblanks on two capture-heavy
  workloads;
- at least 25% lower p99 frame interval, with no more than a 5% regression in
  the completed-capture presentation floor;
- p99 display-snapshot age no greater than two vblanks and no unbounded age
  growth during sustained load;
- p95 interaction latency no more than one vblank worse than `single`;
- queue depth returns to zero after bursts and has no saturation in accepted
  workloads;
- no new lifecycle loss, recovery, reordering, CPU-slice difference, wrong exit
  result, or orphaned target;
- no more than 10% Flamez CPU-time regression, 15% peak-RSS regression, or 3%
  traced-target wall-time regression unless the measured pacing win clearly
  justifies and documents it.

Interpret results as follows:

| Result | Decision |
|---|---|
| `single` misses in drawing or `endDrawing` | Reject threading; optimize measured render/GPU work. |
| `batched` regresses materially | Reject the handoff design and simplify it before proceeding. |
| `collector` passes all gates | Prefer it; do not build snapshot publication. |
| `collector` leaves apply/rebuild spikes | Consider `snapshot` after estimating its cost. |
| `snapshot` smooths FPS but violates age or input gates | Reject it; stale frames are masking the problem. |
| Only controlled stalls improve | Reject threading; the benefit is irrelevant to real workloads. |
| A variant improves averages but not p95/p99 or missed-vblank count | Reject it as an FPS-stability change. |

## 9. Correctness and lifecycle matrix

Exercise every accepted threaded variant through:

- natural target exit with pending lifecycle records;
- Stop while the worker is polling;
- window close while capture is live;
- SIGINT, SIGTERM, and SIGHUP during an empty queue, full queue, and publication;
- a second termination signal during shutdown;
- collector error and reported kernel loss;
- allocation failure while producing, queueing, applying, and publishing;
- PID reuse and out-of-order-looking timestamps that are legal in callback
  order;
- renderer acquisition during publication and worker shutdown while a snapshot
  remains acquired.

Unit tests should assert ownership transitions and canonical results. Stress
tests should run with runtime safety enabled and repeat start/stop/join cycles.
No test may depend on timing sleeps to establish correctness; use barriers or
explicit test hooks to force each interleaving.

## 10. Implementation and cleanup sequence

1. Improve telemetry and record the `single` baseline.
2. Add the batch abstraction and equivalence tests.
3. Measure the synchronous `batched` control.
4. Add the collector worker, command mailbox, and shutdown tests.
5. Measure `collector` against the fixed gates.
6. Stop if H1 is accepted or H0 is supported.
7. If justified, prototype immutable publication and measure copy/publication
   cost before optimizing its representation.
8. Measure `snapshot`, including data age and input latency.
9. Append results below, choose one variant, and remove the rejected paths.

Do not leave four permanent runtime architectures in the tree. Experimental
flags, injected stalls, excess telemetry, and rejected queue/snapshot code are
removed once the decision is made. The final implementation keeps the
correctness tests and the small amount of telemetry needed to catch regressions.

## 11. Results

Not measured yet. Record the commit, machine, kernel, display/refresh rate,
compositor, build flags, workload commands, per-run summaries, and final
decision here before claiming that threading improved stability.
