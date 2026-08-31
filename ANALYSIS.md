# Analysis files

Flamez session JSON is a lossless, canonical interchange format. It preserves
exact byte metadata, exec history, and every CPU slice while interning repeated
argv and path blocks. Those properties make it suitable for replay, but force
an analysis consumer to resolve references, interpret positional slice tuples,
rebuild process-tree aggregates, and rank processes before answering common
questions.

`flamez -a <session.json>` writes a separate analysis file beside the input:

```
flamez -a traces/build.json
# writes traces/analyzed-build.json
```

The analysis file is derived and deliberately not accepted by `-i`. The source
session remains the lossless record for detailed timeline or metadata work.

## Goals

- Put capture quality and exit status before process detail.
- Make every process and parent reference explicit and stable across PID reuse.
- Inline bounded, consistently textual command previews instead of exposing
  metadata-table references or arbitrary byte-string unions.
- Provide the duration, CPU rate, peak CPU rate, and subtree totals that every
  performance consumer would otherwise have to recompute.
- Surface CPU hotspots, longest-lived work, and the dominant process dependency
  chain before the full process detail.
- Preserve topological process order and explicit IDs, parents, depth, and
  timestamps so dependency chains remain easy to follow.
- Identify spans with neither a retained CPU-activity slice nor a direct child
  lifetime as conservative I/O/wait candidates.
- Bound output contributed by an individual argument and command so a captured
  multi-MiB argv cannot consume an agent's context window.
- Keep integer time exact. No nanosecond value is converted through a JSON
  floating-point number.

## Format

The file is one UTF-8 JSON object followed by a newline. It uses compact JSON
because agents and command-line tools can parse it without depending on visual
whitespace. `flamez_analysis` is the first field and versions this derived
format independently from the session schema.

```json
{
  "flamez_analysis": 1,
  "source_flamez": 1,
  "time_unit": "nanoseconds",
  "cpu_rate_unit": "millicores",
  "capture": {
    "fidelity": "exact",
    "incomplete": false,
    "loss_count": 0,
    "recovered_process_count": 0,
    "capture_clipped_process_count": 0,
    "partial_cpu_process_count": 0,
    "host_cpu_count": 8,
    "elapsed_ns": 15000000,
    "root_exit": { "kind": "exited", "code": 0 }
  },
  "totals": {
    "process_count": 1,
    "exec_count": 1,
    "cpu_time_ns": 200000,
    "average_cpu_millicores": 13,
    "unexplained_wall_time_ns": 0
  },
  "target": {
    "label": "clang source.c",
    "name": "clang",
    "argv": {
      "count": 3,
      "preview": ["clang", "-c", "source.c"],
      "truncated": false
    },
    "exe": "/usr/bin/clang",
    "exe_truncated": false,
    "cwd": "/home/user/src",
    "cwd_truncated": false
  },
  "bottlenecks": {
    "longest_dependency_chain": [
      { "id": 0, "label": "clang source.c", "wall_time_ns": 15000000 }
    ],
    "cpu_hotspots": [
      { "id": 0, "label": "clang source.c", "cpu_time_ns": 200000 }
    ],
    "wall_time_bottlenecks": [
      { "id": 0, "label": "clang source.c", "wall_time_ns": 15000000 }
    ],
    "io_wait_candidates": []
  },
  "processes": [
    {
      "id": 0,
      "parent_id": null,
      "depth": 0,
      "pid": 1000,
      "start_ns": 0,
      "end_ns": 15000000,
      "wall_time_ns": 15000000,
      "cpu_time_ns": 200000,
      "average_cpu_millicores": 13,
      "peak_cpu_millicores": 13,
      "cpu_activity_span_ns": 15000000,
      "child_lifetime_span_ns": 0,
      "explained_wall_time_ns": 15000000,
      "unexplained_wall_time_ns": 0,
      "unexplained_wall_permyriad": 0,
      "subtree_cpu_time_ns": 200000,
      "subtree_process_count": 1,
      "origin": "observed",
      "end_kind": "observed_exit",
      "cpu_final": true,
      "command": {},
      "execs": []
    }
  ]
}
```

The abbreviated example uses `{}` only to avoid repeating the command shape;
real `command` and exec `command` objects use the same shape as `target`.
`target` is the stable launched command. A process `command` is its final actual
exec image so bottleneck rankings name the work that occupied the process;
`execs` retains every image when a process changed identity.

One core equals 1000 millicores. Rates use integer floor division:

```
average_cpu_millicores = cpu_time_ns * 1000 / wall_time_ns
peak_cpu_millicores = max(slice.cpu_ns * 1000 / slice_wall_time_ns)
```

A zero-width lifetime has both rates set to zero. `cpu_time_ns` is self CPU;
`subtree_cpu_time_ns` includes the process and every descendant.
`subtree_process_count` likewise includes the process itself.

`processes` remains in parent-before-child order. The explicit `id` is the
source process-array index, so `parent_id` remains unambiguous when PIDs are
reused. The three ranked bottleneck lists contain at most ten entries and break
metric ties by ascending ID. The longest dependency chain starts at the target
and repeatedly selects its longest-lived direct child. It is a process-tree
heuristic, not a claim that Flamez observed application-level dependency edges.

`cpu_activity_span_ns` is wall time covered by retained CPU slices, regardless
of how many cores supplied the measured `cpu_time_ns`. `child_lifetime_span_ns`
is the union of direct child lifetimes. `explained_wall_time_ns` is the union of
both sets of intervals, not their potentially overlapping sum. The remainder
is reported as `unexplained_wall_time_ns` and as a ratio where 10000 means 100%.

The `io_wait_candidates` ranking uses that unexplained remainder. A large value
means the process had no retained CPU bar and no live direct child over those
spans, which is useful for finding possible file, network, lock, pipe, or timer
waits. It is deliberately a heuristic: CPU sampling granularity, scheduler
delay, sleep, missing data, and clipped capture boundaries can produce the same
shape. A child lifetime explains the corresponding parent span; any wait inside
that child is then attributed to the child's own analysis record.

Each argv preview contains at most eight elements and at most 160 source bytes
from each element. `truncated` is true if any element was shortened or any
element was omitted. Invalid UTF-8 and ASCII control bytes are rendered inside
the JSON string as visible `\xNN` sequences; the field type never changes from
string to object. Paths use the same text rendering and are limited to their
existing capture bound.

`incomplete` has the same narrow meaning as `Session.isIncomplete`: Flamez
observed data loss or had to recover a process record. Clipped processes,
partial CPU totals, and snapshot-recovery fidelity are reported separately so
an agent can apply a stricter quality policy without conflating the conditions.

## Transformation

Analysis reuses the streaming, validating session reader. It does not build a
second JSON DOM or parse the canonical format independently.

After import, one forward pass builds a fixed derived record per process and
capture totals. One reverse topological pass adds each process's CPU and count
to its parent, producing all subtree aggregates in linear time. Direct-child
IDs are stored in an `O(P)` offset table and sorted by start time within each
parent. Each already-sorted CPU-slice stream is then merged with its parent's
child intervals to compute covered and unexplained wall time without copying
slices. Fixed-size insertion rankings select the ten largest metrics in
`O(P)` time. Writing streams JSON and command previews directly from the
session arena.

For `P` processes, `E` exec images, and `S` CPU slices, transformation costs
`O(P log P + E + S)` time and `O(P)` additional memory. Output command metadata
is bounded independently of captured argv size. No slice is copied or emitted.
