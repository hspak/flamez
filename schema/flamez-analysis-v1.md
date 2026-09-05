# Flamez analysis v1 metrics

This document defines the semantics of
[`flamez-analysis-v1.schema.json`](flamez-analysis-v1.schema.json). The JSON Schema defines
the machine contract; this document defines accounting, inference, ordering, and rounding.

## Identity and representations

An analysis document identifies itself with `schema.name = "flamez-analysis"` and
`schema.version = 1`. `schema.source_version = 1` identifies the canonical Flamez capture from which
the analysis was derived. The `$schema` URI is versioned and resolves to the JSON Schema beside
this document.

The normal CLI export is UTF-8 JSON indented by two spaces and terminated by one newline.
`analysis_file.writeWithOptions` can emit the same fields in minified transport form. Formatting
does not change IDs, field order, array order, digests, or metric values.

Commands are interned by their recorded name, argv, executable path, and working directory.
Numeric command IDs are assigned in first-use order. Processes retain the canonical capture's
parent-before-child ID order. That order, command first-use order, ranked-metric tie-breaking by
process ID, and fixed component order make repeated exports deterministic.

## Units, intervals, and rounding

Canonical durations are integer nanoseconds. CPU rates are integer millicores, where one fully
occupied logical CPU is 1000 millicores. Ratios are integer permyriad, where 10000 is 100%.
Rates and ratios use nonnegative integer floor division:

```text
millicores = floor(cpu_time_ns * 1000 / elapsed_ns)
permyriad = floor(part * 10000 / whole)
```

A zero denominator produces zero. No formatted seconds or milliseconds occur in core data.

All process, command, CPU-slice, child-lifetime, phase, and envelope intervals are half-open:
`[start_ns, end_ns)`. Consequently `end_ns - start_ns == wall_time_ns`, and an interval ending at
the exact timestamp another starts does not overlap it.

## Capture and CPU accounting

`self_cpu_time_ns` is cumulative CPU consumed by all threads in one process, excluding all
descendant processes. `inclusive_cpu_time_ns` is that self CPU plus the self CPU of every
descendant. `inclusive_process_count` includes the process itself. Inclusive values include
recovered and capture-clipped descendants; their fidelity remains visible on the process and in
capture diagnostics.

While a process is live, Flamez snapshots cumulative self-CPU counters at
`capture.cpu_sample_period_ns`. A natural exit observation supplies the final counter and sets
`cpu_final = true`. A capture boundary or missing final counter sets `cpu_final = false`; the
capture's `partial_cpu_process_count` and invariant status then prevent a consumer from treating
the total as final.

`self_average_cpu_millicores` divides one process's self CPU by its full wall interval.
`totals.average_cpu_millicores` divides total self CPU by root elapsed time. A process's
`peak_cpu_millicores` is the maximum `slice.cpu_ns / slice duration` rate among its retained,
coalesced CPU slices. The observation window for that peak is therefore one retained slice; the
nominal source sampling cadence is `capture.cpu_sample_period_ns`.

`cpu_activity_span_ns` is the union length of retained CPU-slice intervals. CPU amount does not
affect this temporal span. `child_lifetime_span_ns` is the union length of direct-child lifetime
intervals after clipping each interval to the parent lifetime. Overlapping children are counted
once. `explained_wall_time_ns` is the union of the CPU-activity and direct-child intervals, not
their sum. `unexplained_wall_time_ns` is the saturating remainder of process wall time after that
union. `totals.unexplained_wall_time_ns` sums the per-process remainders; because process
lifetimes can nest, it is not a distinct wall-clock union.

## Commands and lifecycle

`command_interval_count` is the number of recorded command images, including an image inherited
at fork. It is not an exec count. `exec_transition_count` counts transitions supported by a fully
observed process history. It is `null` when recovery prevents a complete count;
`observed_exec_transition_count` retains the directly countable subset and
`exec_transition_count_complete` states whether the total is complete.

Every command interval includes an inferred lifecycle kind:

- `launch`: the root launch image.
- `inherited`: the first child image copied at fork.
- `exec`: a later image in an observed process.
- `initial_observation`: an observed initial image whose precise creation kind is unavailable.
- `recovered`: an image associated with a recovered process record.

`kind_inferred = true` is deliberate. Canonical capture v1 retains intervals and metadata
provenance but do not retain a separate fork/clone/vfork/execve event stream. The exporter never
claims direct lifecycle-event evidence that the source does not contain.

Each available argv has a count, up to four head entries, up to four tail entries, and a SHA-256
digest of every recorded argument separated by NUL bytes. `truncated` is true if middle arguments
were omitted from the preview or any preview string exceeded 160 source bytes. The digest still
covers the complete recorded argv. `redacted` distinguishes privacy removal from ordinary
preview truncation. In redacted mode the previews are empty and the digest is `null`. The
canonical session remains the source for lossless argv.

Command classification is separate from the human label. `tool` and `action` are normalized from
arguments and executable identity. `primary_input`, `language`, and `output_kind` are emitted only
when arguments establish them. Component ownership is a best-effort path classification for the
known `flamez`, `raylib`, `clay`, and `system` components; unknown ownership is JSON `null`.
`classification_method` exposes the basis, and heuristic classifications would additionally
carry `classification_confidence_permyriad`.

## Observations and inferences

`analysis.bottlenecks.longest_process_chain` repeatedly chooses the longest-lived direct child,
breaking ties by process ID. Its method is `process_ancestry_and_exit_order`; it is explicitly
`inferred = true` and `additive = false`. Entries are nested process lifetimes and must not be
summed. This is not a build dependency path. Flamez will add a separate `build_graph` only when a
build tool supplies authoritative step dependencies; v1 does not synthesize one from parent IDs.

Hotspots and wall-time stragglers are self-contained observations. Each record includes its
interval, self and inclusive CPU, total-CPU share, root-elapsed share, component, and primary
input. Stall candidates are inferences, not I/O observations. They rank unexplained wall time,
state `evidence = "unexplained_wall_time"`, use low confidence, and enumerate plausible causes.
Only a future I/O-specific signal may make `io_wait` definitive.

## Derived component, phase, and capacity summaries

Component aggregation assigns each process at most once from its final command classification.
`self_cpu_sum_ns` therefore sums distinct self-CPU counters without descendant double-counting.
`wall_envelope_ns` is latest end minus earliest start and is not the sum of process wall times.
`critical_path_candidate` means at least one aggregate process occurs on the inferred process
chain; it does not prove a build-graph critical path.

Phases can overlap, as stated by `overlap_allowed = true`. `build_driver_startup` ends at the first
direct child start. Component phases are classified process envelopes. Missing reliable
classification produces no phase rather than an invented phase.

`total_cpu_capacity_ns` is root elapsed time multiplied by capture-host logical CPU count.
`host_capacity_utilization_permyriad` divides total self CPU by that capacity. A leaf for
`peak_leaf_processes` is a process record with no recorded children. The peak is computed by a
half-open interval sweep, with ends processed before starts at equal timestamps. Recovered and
capture-clipped leaf records are included, and the field says so explicitly. Process concurrency
is not a substitute for CPU utilization.

## Target, environment, cache, and privacy

`target.requested` preserves the launch argv and working directory. `target.observed` identifies
process zero and its final observed command, including the resolved executable when capture
metadata supplied it. These are separate so an unresolved launch executable is not confused with
a missing post-launch observation.

Canonical capture v1 preserves capture time, Flamez version, Flamez build Zig version, OS,
architecture, kernel version, and logical CPU count. `environment.zig_version` is reserved
for the captured target Zig toolchain and remains `null` because current capture backends do not
observe it authoritatively. Optimization mode comes from an explicit target option or a consistent
set of observed Zig compiler `-O` arguments. Cache directories come from explicit target options
or the observed Zig build-runner arguments. Cache state remains `unknown` until a build tool
supplies hit/miss metadata. The exporter does not dump environment variables.

`WriteOptions.privacy = .redacted` retains metrics, IDs, classifications, components, and derived
summaries while removing argv previews and digests, executable/CWD/primary-input/cache paths,
path-derived display labels, capture timestamp, and kernel version. The default `.full` mode
retains the bounded values above.

## Diagnostics and invariants

Diagnostic codes are stable API. Messages are optional display text and are never required for
machine interpretation. Relevant v1 codes include `capture_incomplete`, `process_recovered`,
`cpu_partial`, `arguments_truncated`, `target_executable_unresolved`,
`critical_path_inferred`, `stall_cause_unknown`, `single_sample`,
`cache_state_unknown`, `capture_environment_unavailable`, `target_zig_version_unknown`, and
`optimize_mode_unknown`.

`capture.invariants.checked` and `not_checked` make validation scope explicit. Complete captures
enforce:

1. Process and command duration identities.
2. Ordered, non-overlapping command intervals and matching interval counts.
3. Full command coverage of each observed process lifetime.
4. Resolving parent IDs and placing each observed child's birth within its parent's lifetime
   (`child_birth_within_parent_lifetime`). A child may outlive its immediate parent; only the
   overlap contributes to that parent's explained wall time. The former
   `complete_child_containment` label described an invalid restriction and is no longer emitted.
5. Total self CPU equal to the sum of final process self CPU.
6. Total unexplained wall time equal to the sum documented above.
7. Inclusive CPU and process counts equal to descendant traversal.
8. The floor-division ratio rules in this document.
9. Unique process membership inside each component aggregate.
10. Explicit separation and method labeling for every inference.

For recovered, clipped, or partial-CPU captures, invariants that require unavailable facts move to
`not_checked`; the exporter does not silently apply complete-capture semantics.
