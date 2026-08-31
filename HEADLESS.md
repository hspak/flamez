# Session files: export, import, and headless capture

This document specifies Flamez session files, replaying them in the GUI without
a collector, and capturing without a GUI. Agent-oriented derived output is
specified separately in [ANALYSIS.md](ANALYSIS.md).

Capture already lives in `Session` / `Process` without a raylib dependency.
The GUI is a derived view: lane packing, pixel aggregation, zoom, and selection
do not belong in the file. The file contains the finished process tree,
stable row identities, chronological exec-image history, metadata snapshots,
and canonical CPU slices needed to rebuild that view.

There are four ways to get the same finished `Session` and one session-file
reader/writer:

| Mode | How the session is filled | Window | Collector |
|---|---|---|---|
| Capture + GUI | Spawn and update until exit or Stop | yes | platform collector required |
| Capture + file | Same capture loop, then write and exit | no | platform collector required |
| Open file | Read a finished session | yes | not initialized |
| Analyze file | Read a finished session, then write derived analysis | no | not initialized |

Stabilize the finished-session boundary first, then implement the file module
and round-trip tests, cooperative signals, headless `-o`, GUI save, and GUI
import.

Related docs: [README.md](README.md) (usage),
[ARCHITECTURE.md](ARCHITECTURE.md) (session model), [EBPF.md](EBPF.md)
(Linux collector), [MACAPI.md](MACAPI.md) (macOS collectors), and
[PERF.md](PERF.md) (canonical vs derived data).

---

## 1. Reviewed decisions

The following decisions replace the earlier draft. They are intentional
constraints, not implementation suggestions.

| Earlier decision | Revised decision | Reason |
|---|---|---|
| Serialize `id`, `depth`, and `parent_pid` alongside `parent` | Array position is the stable ID; serialize only `parent` | The removed fields are derivable and can disagree. Parent-before-child ordering makes cycles impossible and lets the reader rebuild cached depth and PPID in one pass. |
| Serialize only the process's final name/metadata snapshot | Serialize the stable row image and every chronological exec image | `Process.execs`, `execAt`, and the detail pane now retain and display the images that occupied a PID. Saving only the scalar current-image fields would discard that history. |
| Serialize the internal `Exec.row_only` marker | Encode `row` as `first_exec` normally, or as the root's retained launch image | `row_only` is a storage optimization used only to keep the launched root command stable; it is not an execution interval or a portable schema concept. Avoiding a repeated image object on every ordinary process also keeps the file compact. |
| Repeat argv/exe/cwd bytes in every process image | Intern argv vectors and paths in top-level tables; row/exec images store references plus provenance | Forked children and successive images commonly share metadata. Repeating a large inherited argv can multiply a few MiB into GiB on disk and again in memory after import. |
| Treat every Linux byte sequence as a JSON string | Use a string-or-base64 `ByteString` | Linux argv, paths, and comm are bytes, not guaranteed UTF-8. The common UTF-8 case remains readable without making invalid JSON or losing bytes. |
| Serialize `cpu_peak_cores` and slice `band` | Derive both from slice triples | Both are caches. Serializing them creates mismatches, uses floating-point text, and repeats one value per slice. |
| Infer that every observed exit has an authoritative CPU total | Serialize `cpu_final` beside `cpu_time_ns` | macOS can observe a lifetime exit but lose the final rusage read. The UI already distinguishes `CPU` from partial `CPU~`; `end_kind` cannot carry this independent fact. |
| Serialize `incomplete` and `recovered_count` | Serialize one canonical `loss_count`; derive recovery count from process origins and derive incomplete status from both | Summary fields are convenient for display but redundant in the file; the boolean should be a query in memory too. |
| Treat every supported capture as one guarantee | Serialize `capture_fidelity` | macOS selects exact Endpoint Security or best-effort snapshot recovery at runtime. Replay must retain the `CAPTURE BEST EFFORT` qualification even when no explicit loss was counted. |
| Two nullable fields, `exit_code` and `exit_signal` | One required tagged `root_exit` object, including an explicit `unknown` tag | The root cannot both exit and be signaled. A tagged result makes the invalid state unrepresentable without using null as an implicit third state. |
| Store an absolute monotonic timestamp | Do not store it in v1 | A monotonic timestamp is boot-local, exceeds JavaScript's exact integer range on long-running hosts, and cannot align traces without a clock identity and boot ID. Add a complete clock-correlation object later if needed. |
| Load the whole file and optionally build a JSON DOM | Stream the reader directly into session-owned storage | Sessions can contain millions of slices and multi-MiB argv. Import should require only final session memory plus bounded token/table scratch. |
| Truncate the destination before writing | Validate first and atomically replace path outputs | A failed save must not destroy the previous good capture or leave a file that looks valid by name. |
| Guess that one positional `*.json` is an import | Import only with `-i` / `--import` | Auto-detection makes an existing executable or script ambiguous. Explicit mode selection is easier to explain and hard to misuse. |
| Let target stdout remain inherited with `-o -` | Redirect target stdout to Flamez's stderr for this one mode | Otherwise target output corrupts the JSON stream. |

The format remains compact JSON. It is easy to inspect and convert, while
interned metadata and tuple slices remove the dominant avoidable waste. A
binary format or transparent compression is a later decision based on measured
files, not a second v1 capture model.

---

## 2. Goals and non-goals

### Goals

- Preserve every process record Flamez retained, including PID-reuse
  generations, exact parentage, lifetimes, stable row identity, every retained
  exec image, CPU totals, and coalesced CPU slices.
- Preserve observed vs recovered vs capture-clipped provenance, exact vs
  snapshot-recovery fidelity, and final vs partial CPU totals.
- Represent known collection loss without redundant fields that can disagree.
- Preserve arbitrary non-NUL bytes retained by capture in names, argv,
  executable paths, and working directories, including non-UTF-8 Linux bytes.
- Avoid duplicating shared metadata on disk or after import.
- Stream both directions; never construct a whole-session JSON value tree.
- Validate before exposing an imported session to the GUI.
- Use the same capture, finish, and write path for GUI save, natural headless
  exit, Stop, and cooperative Ctrl+C.
- Make path saves atomic and stdout export unambiguous.

### Non-goals for v1

- Writing a file while capture is still live.
- Chrome/Perfetto trace format or folded-stack text.
- Packed-lane layout, collapse state, zoom, or selection.
- Per-thread records; CPU remains TGID-aggregated.
- Symbolized stacks.
- A separate summary-only capture format.
- Compression or a binary container.
- Cross-host clock correlation.

---

## 3. One path: finish, then write

A v1 file is always a serialization of a finished session. Every process has
an end time and no process has `end_kind = open`.

### 3.1 How capture ends

| Input | Result |
|---|---|
| Target root exits | `waitNowait` in `Session.update` calls the existing root-finish path. It flushes backend work, takes a boundary CPU snapshot, closes remaining descendants, and compacts metadata. |
| GUI Stop or window close | A collector-aware `Session.stop(&collector)` terminates and reaps the target, then uses the same flush/snapshot/close/compact finish path. Window close does not save. |
| SIGINT, SIGTERM, SIGHUP, or SIGQUIT | The signal handler requests a cooperative stop and performs the existing signal-safe target-tree sweep; the main thread reaps and reaches the same finish path. |

After all three:

- `finished == true`, `running == false`, and `active_count == 0`;
- `processes.len > 0` and process zero is the launched root;
- every `end_ns` is set and no `end_kind` is `open`;
- every real exec interval has an end time, while the stable `row` snapshot is
  not mistaken for an exec interval;
- natural exits retain a final CPU total when the backend obtained one and
  retain `cpu_final = false` when it did not;
- capture-clipped records retain the last available CPU snapshot and have
  `cpu_final = false`;
- metadata referenced by the target argv, a row image, or an exec image remains
  valid; finish-time compaction discards unreachable bytes when it succeeds,
  but its allocation failure does not lose canonical data or prevent export;
- cached `depth`, `parent_pid`, `cpu_peak_cores`, and slice `band` agree with
  their canonical inputs.

`write` accepts only that state. It validates the entire session and prepares
metadata tables before emitting the first byte, which is especially important
for stdout where output cannot be rolled back.

### 3.2 Shared control flow

```
session.start(&collector, target_argv, start_options)
while session.running:
    if stop_requested:
        session.stop(&collector)
    else:
        session.update(&collector)
collector.deinit()
if output_path: writeFile(session)
if headless: exit per section 6.1
if GUI: browse; Ctrl+S may call the same writeFile again
```

Import skips capture:

```
session = readFile(path) // finished, no child, no collector
initWindow()
browse(session)
```

Natural completion remains inside `Session.update`: `finishRootCapture` already
flushes and samples before it closes the model. The refactor needed here is to
make forced Stop call that same internal finish routine instead of the current
collector-blind `Session.stop()`, which closes at the previous frame timestamp,
does not flush or sample, and lets `Child.kill` discard the root status.
`Session.deinit()` uses a separate abort-only cleanup path if startup or the
caller fails before an orderly finish; abort cleanup is not writable as a v1
session.

The file's `host_cpu_count` drives CPU visualization. The viewing host's CPU
count is irrelevant to an imported capture. `capture_fidelity` likewise comes
from the capture, not from the reader's platform or currently available
collector.

### 3.3 Cooperative signals

The first SIGINT/SIGTERM/SIGHUP/SIGQUIT must not terminate Flamez before an
orderly capture boundary can be produced:

1. The async-signal-safe handler atomically claims the first signal, records
   `stop_requested`, and terminates the armed target tree using the existing
   fixed PID table and safe syscall path. It does not allocate, log, lock, or
   write JSON. SIGPIPE remains ignored as it is today.
2. The main loop observes the flag and calls `session.stop(&collector)` if the
   session is still live. That call reaps the owned root and runs the normal
   collector flush and final-snapshot path. Headless mode then writes; GUI mode
   exits without an implicit save.
3. A second termination signal restores the existing default-and-reraise
   immediate-abort behavior so a wedged stop or write cannot trap the user.

The flag/state transition must be atomic: simultaneous signals may not both be
treated as the first signal.

Check `stop_requested` before launching a target as well as in the live loop.
If the first signal was already observed before `Session.start` succeeds, do
not deliberately continue into a new capture; without a finished session,
headless mode produces no file and returns code 1.

Window close still stops a live target to prevent orphaning it. It does not
implicitly save in v1.

### 3.4 Why v1 does not write live sessions

Live export would require nullable end times, `end_kind = open`, an
unreconciled CPU-total contract, and metadata that still contains superseded
blocks. That is a second schema and a second correctness path. Finish first.

---

## 4. File format

The file is one RFC 8259 UTF-8 JSON object followed by a newline. The writer
uses compact whitespace. Examples are pretty-printed only for readability.
The media type is `application/json` and the disk suffix is `.json`.

All numeric fields documented as integers are JSON integer tokens. Flamez
parses them directly into checked Zig integer types; it never round-trips them
through `f64`. JavaScript consumers need a lossless integer parser for values
above 2^53.

Every `*_ns` value is unsigned session time: nanoseconds since capture start
on the same awake/monotonic clock used by `Session.elapsed_ns` and event
rebasing. Zero is target spawn; `elapsed_ns` is the capture horizon.

### 4.1 Top-level object

| Field | Type | Meaning |
|---|---|---|
| `flamez` | integer | Schema version; exactly `1` for this draft. It must be the first object field so a streaming reader can dispatch before consuming the body. |
| `loss_count` | integer | Saturating count of known data-loss incidents from kernel collection and userspace admission/storage. Zero means no known loss, not proof that the kernel is omniscient. It never wraps back to zero. |
| `capture_fidelity` | string | `exact` or `snapshot_recovery`, matching the collector selected for this launch. `unavailable` is not a valid completed capture. |
| `cpu_sample_period_ns` | integer | Configured cumulative CPU snapshot cadence; positive. Today it is `16000000`. |
| `host_cpu_count` | integer | Logical CPUs on the tracing host at capture start; at least one. |
| `target_argv` | integer | Reference into `metadata.argv` for the exact non-empty argv passed to `Session.start`. |
| `elapsed_ns` | integer | Finished capture horizon. |
| `root_exit` | object | Reaped target status, or an explicit unknown status. |
| `metadata` | object | Interned argv vectors and paths; see section 4.3. |
| `processes` | array of object | Non-empty, topologically ordered process records. Array position is the stable process ID; position zero is the target root. |

No `root` field is needed because the root is always process zero. There is no
valid finished v1 session from a failed spawn: spawn failure returns an error
and no file is written.

`root_exit` has exactly one of these shapes:

```json
{ "kind": "exited", "code": 0 }
{ "kind": "signaled", "signal": 9 }
{ "kind": "unknown" }
```

`code` is in `0...255`. `signal` is in `1...255`, matching `RootExit.signaled`.
Fields inappropriate to the selected kind are not accepted.
`Session.stop(&collector)` must reap the root and retain its status instead of
discarding the result after sending KILL. `unknown` is only for a root whose
status genuinely could not be obtained; it is not the normal forced-stop
representation.

### 4.2 ByteString

Capture metadata is bytes, while a JSON string must be Unicode. Linux in
particular does not require argv, paths, or comm to be valid UTF-8. Every schema
field typed `ByteString` uses this tagged representation:

- valid UTF-8 bytes: an ordinary JSON string;
- otherwise: `{ "base64": "<standard padded base64>" }`.

For example:

```json
"clang"
{ "base64": "/2Jpbg==" }
```

The writer always chooses the string form when the bytes are valid UTF-8.
Base64 is only the lossless fallback; it is not used for compression. The
reader rejects malformed base64 and decoded NULs where the captured field
cannot contain them. Empty argv elements are valid empty strings.

String escaping and UTF-8 validation must use standard-library routines.
Base64 encoding should stream to the output writer rather than allocating a
second encoded copy of a multi-MiB argument.

### 4.3 Interned metadata

`metadata` has exactly two arrays:

| Field | Element type | Meaning |
|---|---|---|
| `argv` | array of arrays of `ByteString` | Interned exact argument vectors, including argv[0] and empty arguments. |
| `paths` | array of `ByteString` | Interned executable and working-directory byte paths. |

Each distinct vector/path is emitted once, in first-reference order.
`target_argv` and every row/exec image point into these tables.

The writer first interns by session-arena range identity so inherited blocks
are O(1) lookups. It traverses `target_argv`, `Process.rowExec()`, and every
real `Process.execAt()` image. For a newly seen arena range it hashes and
compares path bytes or logical argv elements so separately captured equal
paths/vectors also share an entry. Argv comparison uses `args_count` and
`argsIter`, not the incidental presence of a final NUL in the arena. Hash
collisions must compare complete bytes and element boundaries. Writer scratch
is proportional to the number of distinct metadata blocks, never their
duplicated payload size.

An argv entry's total decoded bytes plus one NUL separator per element must not
exceed the collector's 6 MiB argv bound. A path contains 1...512 bytes. The
target argv entry is non-empty.

The table form deliberately mirrors `Process.MetadataStore`: the reader
appends each distinct table payload once, maps table indices to arena offsets,
then aliases every row/exec reference. Duplicate table contents from a
third-party writer may be normalized to one arena block; the Flamez writer
never emits them. Imported metadata must not be duplicated per process or per
exec interval.

### 4.4 Process object

| Field | Type | Meaning |
|---|---|---|
| `pid` | integer | Positive userspace TGID. It is not unique; PID reuse creates another array element. |
| `parent` | integer or null | Exact parent process ID. Null only for process zero; otherwise less than the current array index. |
| `start_ns` | integer | Lifetime start in session time. Recovered origins describe when this value is inferred. |
| `end_ns` | integer | Finished lifetime end in session time. |
| `origin` | string | `observed`, `recovered_parent`, `recovered_exec`, or `recovered_exit`. |
| `end_kind` | string | `observed_exit` or `capture_clipped`. |
| `row` | string or image object | `first_exec` for the normal derived row, or the root's retained launch image; see section 4.5. |
| `execs` | non-empty array of exec objects | Chronological real process images returned by `execAt`; see section 4.5. |
| `cpu_time_ns` | integer | Cumulative self-CPU for all threads in the TGID, excluding descendants. |
| `cpu_final` | boolean | Whether `cpu_time_ns` came from an authoritative natural-exit observation. False means best available/partial, even if `end_kind` is `observed_exit`. |
| `slices` | array of triples | Canonical coalesced CPU activity; see section 4.7. |

Array position replaces a serialized `id`. `depth` and `parent_pid` are rebuilt
on import:

```
depth[0] = 0
depth[i] = depth[parent[i]] + 1
parent_pid[i] = processes[parent[i]].pid
```

The imported UI therefore cannot disagree with the canonical tree. For
recovered rows the parent link is explicitly inferred by `origin`; the file
does not pretend an inferred PPID was kernel-observed.

Do not serialize the scalar current-image fields separately. In memory, the
last `execs` element is stored in `Process.exec_start_ns` plus the scalar
name/metadata fields; the preceding elements live in `Process.execs`. The
reader reconstructs that layout. There is one canonical image sequence in the
file, so those two in-memory representations cannot disagree after import.

Do not serialize UI/live caches: `revision` fields, `signal_slot`,
`cpu_snapshot_at_ns`, `cpu_snapshot_initialized`, `depth`, `parent_pid`,
`cpu_peak_cores`, slice `band`, metadata-arena offsets, `by_pid`, or the
internal `Exec.row_only` marker.

### 4.5 Row and exec images

An image object has these fields:

| Field | Type | Meaning |
|---|---|---|
| `name` | `ByteString` | Non-empty process/display name, at most 48 bytes. |
| `name_kind` | string | `process` for a captured process name, `other` for a fallback label. |
| `argv` | object or null | Reference and provenance, or null when unavailable. |
| `exe` | object or null | Path reference, provenance, and truncation, or null. |
| `cwd` | object or null | Path reference, provenance, and truncation, or null. |

`argv` is null for unavailable metadata or:

```json
{ "ref": 1, "source": "kernel" }
```

`ref` indexes `metadata.argv`. Valid argv sources are `launch`, `kernel`,
`procfs`, `process_inspection`, and `inherited`.

`exe` and `cwd` are null or:

```json
{ "ref": 2, "source": "procfs", "truncated": false }
```

Their `ref` indexes `metadata.paths`. Valid path sources are `kernel`,
`procfs`, `process_inspection`, and `inherited`. Null is the only
representation of unavailable metadata; `source = unavailable` is not
serialized. This avoids contradictory states such as a null value claiming to
come from process inspection.

Path bytes are exact. Capture must not trim leading/trailing ASCII whitespace:
those bytes are legal in Linux paths. `truncated` means capture hit its cap and
the bytes may be a prefix; conservative true is safe when the source API
cannot distinguish an exact fit. Procfs `readlink` and macOS process-inspection
capture should read into at least `max_path_len + 1` bytes (or use an
equivalent length check) so they can distinguish a complete 512-byte path from
a longer one. Store-side truncation uses `len > max_path_len`, not `>=`.

Each exec object contains every image field plus required `start_ns` and
`end_ns`. A finished process always has at least one exec image. Exec intervals
are ordered and non-overlapping within the process lifetime. Zero-width
intervals are legal for same-timestamp exec/exit observations and recovered
exit-only records. Adjacent intervals normally touch; a gap is legal because
`Process.archiveCurrentExec` deliberately leaves one if retaining the replaced
image runs out of memory. That failure must increment `loss_count`.

`execs` means the chronological images exposed by `Process.execAt`, not only
images introduced by an exec event. A forked child's inherited pre-exec image
is its first interval, and a process that never calls exec still has one image.

The final exec's `end_ns` equals the process `end_ns`. `row` is the stable
command/name shown on the timeline, not another execution interval. Its common
form is the string `"first_exec"`, which tells the reader to derive
`Process.rowExec()` from `execs[0]` without duplicating an image object.

The launched root is the only object form. `applyExec` can preserve the exact
launch command in an internal `row_only` snapshot while coalescing the launch
handoff into the first real exec interval. That row object has the image fields
above but no timestamps. Its argv source is `launch`, its argv ref equals
`target_argv`, and its exe is null, matching `Session.start` today. Non-root
processes and a root whose row equals its first exec must use `"first_exec"`.
This preserves current UI behavior without exposing the internal marker,
inventing a fake exec, or repeating names and metadata references for every
ordinary process.

### 4.6 Provenance enumerations

`origin`:

| Value | Meaning |
|---|---|
| `observed` | Created from the launched root or an observed fork. |
| `recovered_parent` | Parent stub created when a child fork referred to an unknown live parent. Start and attachment under the root are inferred. |
| `recovered_exec` | Process created from an exec for an unknown live TGID. Start and parent are inferred. |
| `recovered_exit` | Process created only from an exit. Fork time and parent are unknown; normally a zero-width lifetime. |

`end_kind`:

| Value | Meaning |
|---|---|
| `observed_exit` | Closed by a lifecycle exit event. Whether its CPU total is authoritative is represented independently by `cpu_final`. |
| `capture_clipped` | Closed at the capture horizon without observing this process exit. CPU is the last available snapshot and `cpu_final` is false. |

`recovered_count` remains a useful `Session` cache and is recomputed after
capture/import. Do not store a separate `incomplete` boolean in `Session`;
make it a cheap query so it cannot become stale:

```
recovered_count = count(process.origin != .observed)
isIncomplete() = loss_count != 0 or recovered_count != 0
```

The writer derives both decisions from canonical fields; the reader never
accepts caller-provided summary values. `capture_fidelity = snapshot_recovery`
is a separate capture guarantee, not an implicit nonzero loss count: the
fallback can miss a short-lived branch without observing an event it could
count as lost.

### 4.7 CPU slices

A slice is the compact triple:

```json
[start_ns, end_ns, cpu_ns]
```

- `end_ns > start_ns`;
- `cpu_ns > 0`; idle gaps are omitted;
- `cpu_ns` may exceed wall duration when multiple threads run in parallel;
- slices are sorted and non-overlapping;
- each slice lies within the process lifetime.

The quarter-core coalescing band is derived with checked wide arithmetic:

```
band = min(ceil(4 * cpu_ns / (end_ns - start_ns)), 64)
```

Adjacent slices that touch and have the same derived band are non-canonical
and rejected; the writer should have merged them. `cpu_peak_cores` is the
maximum `cpu_ns / duration` over retained slices and is recomputed when a
session finishes and when one is imported.

`cpu_time_ns` is the cumulative total Flamez retained. The checked sum of slice
CPU must not exceed it. It normally equals it; a difference is legal because
CPU observed at an inferred or zero-width boundary cannot always be assigned a
positive wall interval. `cpu_final` says whether the total is authoritative,
not whether the slice sum matches it. Forced stop by itself is not a reason to
discard already recorded slice CPU.

The file preserves snapshot buckets, not scheduler transitions:

- cadence is `cpu_sample_period_ns`;
- delayed snapshots move bucket boundaries but cumulative CPU is retained;
- a natural exit reconciles newest slices when its event carries
  `cpu_final = true`;
- an observed exit whose final CPU read failed retains `cpu_final = false`;
- capture-clipped processes have `cpu_final = false` and no final
  reconciliation.

### 4.8 Structural invariants

The reader validates all of these before returning:

1. After optional leading whitespace, the first object field is `flamez` and
   its value is exactly one. All required fields occur exactly once.
2. Unknown object fields and duplicate keys are errors in v1.
3. `loss_count` and all counts/times fit their destination integer types;
   checked addition/multiplication never wraps.
4. `capture_fidelity` is `exact` or `snapshot_recovery`; `unavailable` and
   unknown values are rejected.
5. `cpu_sample_period_ns > 0`, `host_cpu_count > 0`, and `target_argv` is an
   in-range reference to a non-empty argv vector.
6. `processes` is non-empty. Process zero has null parent, `origin = observed`,
   and `start_ns = 0`.
7. Every later process has `parent < current_index`. This proves references
   are in range and the graph is rooted and acyclic without a second graph
   walk. Derived depth is computed with checked addition and must fit
   `Process.depth`.
8. `start_ns <= end_ns <= elapsed_ns`. Zero width is legal, especially for
   `recovered_exit`.
9. A child's start is within its parent's recorded lifetime.
10. Metadata references are in range, sources are field-appropriate, decoded
   byte limits hold, and unavailable values are null.
11. Every `row` and exec name is non-empty and at most 48 decoded bytes; paths
    contain 1...512 decoded bytes.
12. Every process has at least one exec. Each exec lies within the process
    lifetime, has `start_ns <= end_ns`, and is ordered and non-overlapping with
    its neighbors. The final exec ends at the process end. Gaps and zero-width
    execs are accepted as described in section 4.5.
13. Every non-root `row` is `"first_exec"`. The root uses either that string or
    an image object satisfying the retained-launch constraints in section 4.5.
14. `end_kind` is never `open`, every enum string is known, and
    `capture_clipped` implies `cpu_final = false`.
15. Slice triples satisfy section 4.7, including lifetime bounds, ordering,
    non-overlap, canonical coalescing, and checked CPU summation.
16. `root_exit` has exactly the fields allowed by its tag and bounded payload;
    `unknown` has no payload fields.
17. The process array ends before trailing non-whitespace; there is exactly one
    JSON document.

The writer applies the same checks to the in-memory session before output.
Assertions inside rendering are not a substitute for file validation.

### 4.9 Example

One root PID whose stable launch command differs from its first captured image
and which later execs again:

```json
{
  "flamez": 1,
  "loss_count": 0,
  "capture_fidelity": "exact",
  "cpu_sample_period_ns": 16000000,
  "host_cpu_count": 8,
  "target_argv": 0,
  "elapsed_ns": 15000000,
  "root_exit": { "kind": "exited", "code": 0 },
  "metadata": {
    "argv": [
      ["sh", "-c", "exec clang -c source.c"],
      ["dash", "-c", "exec clang -c source.c"],
      ["clang", "-c", "source.c"]
    ],
    "paths": [
      "/home/user/src",
      "/usr/bin/dash",
      "/usr/bin/clang"
    ]
  },
  "processes": [
    {
      "pid": 1000,
      "parent": null,
      "start_ns": 0,
      "end_ns": 15000000,
      "origin": "observed",
      "end_kind": "observed_exit",
      "row": {
        "name": "sh",
        "name_kind": "process",
        "argv": { "ref": 0, "source": "launch" },
        "exe": null,
        "cwd": { "ref": 0, "source": "procfs", "truncated": false }
      },
      "execs": [
        {
          "start_ns": 0,
          "end_ns": 10000000,
          "name": "dash",
          "name_kind": "process",
          "argv": { "ref": 1, "source": "kernel" },
          "exe": { "ref": 1, "source": "kernel", "truncated": false },
          "cwd": { "ref": 0, "source": "procfs", "truncated": false }
        },
        {
          "start_ns": 10000000,
          "end_ns": 15000000,
          "name": "clang",
          "name_kind": "process",
          "argv": { "ref": 2, "source": "kernel" },
          "exe": { "ref": 2, "source": "kernel", "truncated": false },
          "cwd": { "ref": 0, "source": "procfs", "truncated": false }
        }
      ],
      "cpu_time_ns": 200000,
      "cpu_final": true,
      "slices": [[0, 15000000, 200000]]
    }
  ]
}
```

The launch row, both exec images, and `target_argv` preserve distinct roles
while sharing interned metadata references. The cwd appears once even though
three image objects refer to it. An inherited multi-MiB argv receives the same
treatment.

### 4.10 Compatibility and schema evolution

The schema described here is still the draft of the first release. Until v1
is explicitly declared stable:

- change the draft freely when measurements or implementation expose a better
  shape;
- update the current writer, reader, examples, and tests together;
- do not retain migration code or golden fixtures for shapes that never
  shipped;
- treat files produced by development builds as disposable and allow a newer
  development build to reject them.

`flamez = 1` names the planned first stable schema; its presence in this draft
does not freeze today's shape. The release that declares v1 stable establishes
the compatibility boundary and adds committed v1 fixture files.

After that boundary:

- The writer emits only the newest schema version.
- The public reader consumes `flamez` first and dispatches to a dedicated
  `readV1Body`, `readV2Body`, and so on.
- A released version reader keeps that version's field meanings, defaults,
  limits, and validation rules. It normalizes while streaming into the current
  `Session` representation; it is not rewritten to reinterpret old bytes as a
  newer schema.
- New readers continue to open every released older version. Re-export writes
  the newest version and is the supported upgrade path.
- Older readers reject newer versions immediately with
  `UnsupportedVersion`. They never guess, partially load, or silently
  downgrade.
- Bump the monotonically increasing integer for a required/removed field,
  field type change, enum change, changed invariant or meaning, or a new core
  field. The strict unknown-field rule means even an additive core field needs
  a new version unless an older schema explicitly reserved an extension
  point.
- Keep the file schema version independent of the Flamez application version.

Requiring `flamez` first is the one intentional ordering constraint on the
top-level JSON object. JSON tools can still read the file normally; a
third-party Flamez writer must preserve this profile. Remaining top-level
fields may appear in any order. This constraint lets stdin import select the
version parser using bounded memory and lets an unsupported version fail
before a potentially enormous process array is read.

---

## 5. Session-file module

### 5.1 Placement and API

Use `src/session_file.zig`: it is a namespace of peer file functions, not a
primary type. Keep it independent of raylib and import it through the tracer
facade as needed.

API sketch; exact standard-library file error unions may refine the names:

```zig
pub const Diagnostics = struct {
    byte_offset: u64 = 0,
    reason: Reason = .none,
};

pub const WriteFileOptions = struct {
    install: Install = .exclusive,

    pub const Install = enum { exclusive, replace };
};

pub fn write(
    gpa: Allocator,
    session: *const Session,
    writer: *std.Io.Writer,
) WriteError!void

pub fn writeFile(
    gpa: Allocator,
    io: std.Io,
    session: *const Session,
    path: []const u8,
    options: WriteFileOptions,
) WriteFileError!void

pub fn read(
    gpa: Allocator,
    io: std.Io,
    reader: *std.Io.Reader,
    diagnostics: *Diagnostics,
) ReadError!Session

pub fn readFile(
    gpa: Allocator,
    io: std.Io,
    path: []const u8,
    diagnostics: *Diagnostics,
) ReadFileError!Session
```

Allocator arguments precede inputs. `read` returns an owning `Session`; the
caller must immediately `defer session.deinit()` after success.

`WriteFileOptions` has an exclusive default, so an omitted option never
clobbers a capture. Headless `-o path` opts into `.replace` explicitly. Do not
use a boolean whose meaning is unclear at the call site.

Zig errors do not carry messages. `ReadError` is a closed reason set such as
`InvalidJson`, `UnsupportedVersion`, `DuplicateField`,
`UnknownField`, `ValueTooLong`, and `InvariantViolated`, combined with
allocator/reader errors. `Diagnostics` carries byte position and a compact
reason/field identifier for stderr or the GUI. Do not claim the error value
itself contains a string.

### 5.2 Session fields and caches

At capture start, retain:

| Field | Source |
|---|---|
| target argv arena block | Exact argv passed to `Session.start`; keep it reachable even if the root later execs |
| `host_cpu_count` | `max(std.Thread.getCpuCount() catch 1, 1)` |
| `sample_period_ns` | Current `default_cpu_sample_period_ns` (16 ms); retained so import/re-export does not substitute a newer build's default |
| `loss_count` | Collector loss counter plus known userspace admission/storage loss |
| `capture_fidelity` | `collector.fidelity()` after `armLaunch` selects the per-launch macOS backend |

`started_at` remains live-only for event rebasing. It is not exported.
Rename the current `Session.cpu_sample_period_ns` declaration to
`default_cpu_sample_period_ns`; `Session.update` uses `self.sample_period_ns`,
and the tracer facade may keep its existing public constant as an alias to the
default. A file's top-level `cpu_sample_period_ns` maps to the session field.
Before file work lands, make path capture preserve bytes without
`std.mem.trim` and make the procfs cap observable as described in section 4.5.

Replace `lost_events` with a canonical `loss_count` and keep a live-only
`collector_loss_seen`. Each update adds only the positive delta from the
collector's cumulative counter, saturating into `loss_count`; userspace
failures increment the same total directly. This prevents a later collector
poll from overwriting userspace loss. Every failure to retain canonical data—a
process record, exec history/row snapshot, image metadata, or CPU slice—must
not be logged and then omitted while the file still claims `loss_count = 0`.
Failure of the optional finish-time compaction scratch allocation is not data
loss because the old arena and every reference remain valid. The footer and
`isIncomplete()` read `loss_count`.

Initialize `collector_loss_seen` from the collector after `armLaunch`, rather
than assuming zero, so reusing a Linux collector for another session cannot
charge the new session for an older capture. If a backend counter resets, treat
the new value as the next baseline; never subtract from `loss_count`.

Replace the two nullable session fields with the same tagged shape used by the
file:

```zig
pub const RootExit = union(enum) {
    unknown,
    exited: u8,
    signaled: u8,
};
```

`Session.root_exit` resets to `.unknown` at start. `recordRootStatus` and
`stop` set one union prong, so live code cannot accidentally leave both an
exit code and signal populated.

Add `Session.finished`, reset it to false by `start`, and set it only after the
orderly shared finish path or a successful import. `write` requires it. This
distinguishes a real finished capture from an idle/new session or abort-only
cleanup; `running == false` alone cannot make that distinction.

Thread target stdout routing through a small `Session.StartOptions` bag with
`target_stdout: TargetStdout = .inherit`, then through a matching
`process_ops.SpawnOptions`. Headless `-o -` selects `.stderr`; every other mode
uses the default. The Linux `.stderr` case passes
`.stdout = .{ .file = std.Io.File.stderr() }`; `SpawnOptions.StdIo` has no
dedicated stderr-redirect tag. The macOS suspended-spawn shim adds a
`dup2(STDERR_FILENO, STDOUT_FILENO)` file action. Keep this spawn concern out of
the collector and session-file modules.

At capture finish, recompute `recovered_count`, process depths, derived PPIDs,
slice bands, and peak cores from canonical fields. `isIncomplete()` reads the
loss/recovery counters directly. This gives the writer a single validation
point and fixes stale peak caches on capture-clipped sessions.

`Session.stop(&collector)` must preserve the root wait result. After the
signal-safe tree sweep makes blocking bounded, wait for the owned child through
the API that returns `std.process.Child.Term` and translate it to `root_exit`.
Map `.exited` and `.signal` to their matching prongs; map `.stopped` and
`.unknown` to `RootExit.unknown` rather than assuming an exhaustive normal-exit
status. If `Child.wait` fails, retain `RootExit.unknown`, use the idempotent
kill path only as the cleanup fallback, and continue finishing the capture.
Do not use that convenience kill path for the normal case because it waits and
discards the status. Then flush the collector and take the same
capture-boundary snapshot used by natural root exit before closing remaining
records.

After import:

- `finished == true`, `running == false`, `child == null`, `root_pid == null`,
  and `active_count == 0`;
- `elapsed_ns` is the file horizon and `timelineNs()` returns it;
- process zero is the root;
- `by_pid` remains empty because it is live-only;
- metadata table entries exist once in the arena and row/exec references share
  offsets;
- `parent_index` comes from `parent`, while `parent_pid` and `depth` are
  derived;
- preceding real execs populate `Process.execs`, the last exec populates
  `exec_start_ns` and the scalar current-image fields, and a root `row_only`
  entry is created only when the file's root `row` is an object;
- `cpu_final` is restored independently of `end_kind`;
- slice `band` and `cpu_peak_cores` are derived;
- revision counters are initialized so the first GUI frame rebuilds all
  relevant caches;
- `host_cpu_count`, `sample_period_ns`, `capture_fidelity`, loss accounting,
  root status, and the retained target argv come from the file.

### 5.3 Writer

The writer has two phases:

1. Validate the finished session and build deterministic argv/path intern
   tables plus row/exec-to-table references.
2. Emit compact JSON incrementally through `std.json.Stringify`:
   top-level scalars, metadata entries, process/row/exec objects, slice
   triples, and the closing newline.

Use standard JSON stringification for valid UTF-8 strings and field names.
Never hand-roll escaping. Stream base64 fallback and argv iteration. Do not
materialize a schema-shaped copy or whole JSON document.

For `row`, compare `rowExec()` with `execAt(0)` by complete image contents and
provenance, not arena offsets alone. Emit `"first_exec"` when they are equal;
the only permitted unequal case is process zero's validated launch snapshot,
which is emitted as an image object.

The intern prepass is expected O(processes + execs + distinct metadata bytes)
time and O(distinct metadata entries + image references) scratch space. Slice
emission is O(slice count) and O(1) scratch.

`writeFile` writes to a uniquely created sibling temporary file, flushes and
closes it successfully, then renames it into place. On any failure it removes
the temporary file and leaves an existing destination untouched.
`options.install` controls whether the final install may replace an existing
path:

- headless `-o path` passes `.{ .install = .replace }` because the user
  explicitly named it;
- automatic GUI save uses the default `.exclusive` and reports a collision.

Atomic replacement does not apply to stdout. Validation/table preparation
still happens before the first stdout byte; an I/O failure may necessarily
leave a partial stream.

### 5.4 Reader

Use `std.json.Reader` or its low-level scanner over `std.Io.Reader`. Parse
tokens directly into final session-owned arrays and metadata storage. Do not:

- call `readToEndAlloc` for the whole file;
- parse a `std.json.Value` DOM;
- parse a full temporary schema and then copy every string/slice;
- recursively walk parent links.

A token may need bounded scratch while JSON escapes or base64 are decoded.
Configure the per-value limit explicitly: the standard 4 MiB default is too
small for Flamez's 6 MiB argv bound, and base64 for that bound can reach
8 MiB. Enforce the decoded aggregate argv limit separately.

Immediately after the top-level object begins, require and parse the `flamez`
field, then dispatch to the matching version-specific body reader. Reject an
unknown version before reading another body token. The remaining top-level
fields may arrive in any order. If `processes` precedes `metadata`, retain only
small numeric metadata references for row/exec images until the tables arrive,
then resolve them before validation succeeds. This scratch is proportional to
the number of images, not their metadata payload bytes.

Build into a local session and use `errdefer session.deinit()` immediately.
No partially parsed session reaches `App`. On success, release token/table
scratch and return only final canonical storage.

Unknown and duplicate fields are rejected according to the selected version's
rules. Extensibility comes from a new `flamez` version with an explicit reader,
not silently ignored typos inside v1.

### 5.5 Round-trip equality

`write(read(write(session)))` need not be byte-identical if metadata table
intern order is normalized, but it must preserve:

- top-level canonical fields and tagged root exit;
- capture fidelity and loss count;
- process array order, PIDs, parents, lifetime provenance, stable row images,
  and every exec interval/image in order;
- target argv;
- CPU totals, `cpu_final`, and every slice triple.

Derived caches are compared to recomputation, not serialized values.

---

## 6. Command-line interface

Flags precede the target. `--` ends Flamez flag parsing:

```
flamez [flamez-flags] [--] [<target> [target-args...]]
```

Modes:

| Mode | Invocation | Window | Collector |
|---|---|---|---|
| Capture + GUI | `flamez [--] <target> [args...]` | yes | required |
| Capture + file | `flamez -o <path> [--] <target> [args...]` | no | required |
| Open file | `flamez -i <path>` | yes | not initialized |
| Analyze file | `flamez -a <path>` | no | not initialized |

Flags:

| Flag | Meaning |
|---|---|
| `-o <path>`, `--output <path>` | Write the finished capture. Implies headless. `-` means stdout. |
| `-i <path>`, `--import <path>` | Read a finished session and open it in the GUI. `-` means stdin. |
| `-a <path>`, `--analyze <path>` | Write `analyzed-<filename>` beside a session file. |
| `--` | End Flamez flags; required when the target begins with `-`. |

Examples:

```
flamez -o capture.json -- zig build -Doptimize=ReleaseFast
flamez --output=- make -j8 | jq .
flamez zig build
flamez -i capture.json
flamez -a capture.json
cat capture.json | flamez -i -
```

Rules:

- Capture output, import, and analysis modes are mutually exclusive.
- `-o` requires a target.
- `-i` rejects target/extra positionals.
- `-a` requires a named file, rejects stdin and extra positionals, and
  atomically replaces the derived sibling only after a successful write.
- There is no bare-path import heuristic; `flamez capture.json` runs a target
  named `capture.json`. Use `flamez -i capture.json` to import.
- A named `-o` path atomically replaces an existing destination only after a
  complete successful write.
- `-o -` reserves Flamez stdout for JSON. Target stdout is redirected to
  Flamez stderr for that mode; target stderr and Flamez diagnostics also stay
  on stderr. This keeps pipelines valid.
- `-i -` reads stdin completely through the streaming parser before opening
  the window. GUI input does not require the terminal stream afterward.
- Import never initializes a collector, performs capability/entitlement setup,
  or requires an installed Linux BPF object.

Usage text shows all four explicit modes.

### 6.1 Exit status for headless capture

| Code | Meaning |
|---|---|
| 0 | File written with no known loss/recovery, and `root_exit` is `exited` with code zero. |
| 1 | Flamez failed before producing a complete file: collector, spawn, internal, or write failure. |
| 2 | CLI usage error. |
| 3 | File written but the session is incomplete (`loss_count > 0` or recovered records). |
| 4 | File written with no known loss/recovery, but `root_exit` is nonzero `exited`, `signaled`, or `unknown`. |

If both the target failed and the capture is incomplete, code 3 wins because
the capture-quality warning would otherwise be lost; `root_exit` still records
the target result. This precedence must be unit-tested.

`capture_fidelity = snapshot_recovery` does not by itself select code 3. It is
a visible guarantee on an otherwise successful file, whereas code 3 means
Flamez observed concrete loss or had to create recovered records. Deployments
that require exact macOS capture can use the existing exact-capture build
policy and fail before launch when it is unavailable.

A first cooperative termination signal that successfully writes a file is not
a Flamez write failure. It normally produces code 4 because the root was
signaled, or code 3 if capture was also incomplete.

The GUI's own eventual exit remains success unless GUI/import/save itself
fails; target status remains visible in the session.

---

## 7. Headless loop

Headless mode uses capture without window initialization:

```
installCooperativeSignalHandlers()
parse argv
collector.init()
collector.dropPrivileges()
if stop_requested: exit 1 without launching or writing
session.start(&collector, target_argv, start_options)
while session.running:
    if stop_requested:
        session.stop(&collector)
    else:
        session.update(&collector)
    sleep about 1 ms
collector.deinit()
writeFile or write stdout
exit per section 6.1
```

Details:

- Use the awake clock for the roughly 1 ms sleep. Faster polling adds CPU cost
  without changing the collectors' 16 MiB producer bounds.
- Natural exit and forced stop share `Session`'s collector flush, boundary CPU
  snapshot, close/compact, and writer calls.
- Serialize the per-launch `collector.fidelity()` selected by `Session.start`.
- A named path is installed atomically only after the whole JSON file closes
  successfully.
- With `-o -`, JSON is the only stdout producer.
- No window, Clay, raylib, screenshot, FPS, or idle-vsync path is initialized.

---

## 8. GUI

### 8.1 Save after live capture

After `session.running` becomes false, Ctrl+S calls the same
`session_file.writeFile`:

- try `flamez-session.json`, then a numeric suffix if it already exists;
- do not clobber an existing file for an automatically selected name;
- show the actual written path or a concise diagnostic in the footer;
- allow another save by selecting the next available suffix or reporting the
  collision consistently;
- never mutate the finished session while saving.

Add Ctrl+S to `hasKeyboardActivity()`. Finished captures use the idle polling
path, so a save key that does not request a frame would otherwise never reach
the save handler or redraw the footer message.

No file picker is required in v1. Stop/Ctrl+C ends the capture but does not
auto-save a GUI session.

### 8.2 Open a session

Import follows:

- open stdin/path and stream `session_file.read`;
- on error, show the diagnostics and never initialize `App` with partial data;
- skip collector initialization, capability checks, capability dropping, and
  `Session.start`;
- initialize the GUI directly in the existing finished/idle path;
- use the imported `host_cpu_count`;
- hide Stop because `running == false`;
- show derived FINISHED/INCOMPLETE state, imported capture fidelity, tagged
  root exit, partial `CPU~` totals, and the complete exec history;
- let Ctrl+S re-export through the same writer;
- keep `FLAMEZ_SCREENSHOT` working for privilege-free visual fixtures.

The title should include the imported path, or `stdin`, so replay cannot be
mistaken for live capture.

---

## 9. Tests

Keep session-file tests under the tracer test root so they do not need a
window or a live platform collector.

### 9.1 Format and round trip

- Minimal finished root for each capture fidelity; write/read and compare
  canonical fields.
- PID reuse: two records with the same PID and different array positions.
- Parent topology: reject null non-root parents, forward/self references, and
  cycles implied by them; derive depth and PPID on success.
- Exec history: preserve multiple chronological images, zero-width intervals,
  legal loss gaps, and the final scalar current-image reconstruction.
- Root launch coalescing: a stable launch `row` that differs from the first real
  exec round-trips without serializing or exposing `row_only`.
- Ordinary processes use `row = "first_exec"`; reject unknown row strings, a
  non-root row object, or a root launch object with the wrong argv/source/exe.
- Reject empty exec arrays, out-of-order/overlapping execs, intervals outside
  the process lifetime, and a final exec that does not end with the process.
- `process_inspection` argv/path provenance round-trips alongside `launch`,
  `kernel`, `procfs`, and `inherited`.
- Metadata interning: thousands of inherited references to one large argv
  across rows and execs produce one table entry and one imported arena block.
- Equal-but-separately-stored paths intern to one table entry.
- Paths with leading/trailing spaces round-trip exactly; a path at/over the
  capture cap has the correct `truncated` value.
- Empty argv arguments survive.
- Valid UTF-8 uses JSON strings; invalid UTF-8 names/args/paths use base64 and
  round-trip byte-for-byte.
- Recovered parent/exec/exit origins derive `recovered_count` and make
  `isIncomplete()` true.
- Nonzero `loss_count` makes `isIncomplete()` true.
- Tagged root exit: exited/signaled/unknown; reject mixed or out-of-range
  payloads.
- Final and partial observed-exit CPU totals round-trip independently of
  `end_kind`; a capture-clipped process retains CPU total and slices but
  rejects `cpu_final = true`.
- Exact and snapshot-recovery fidelity round-trip; reject `unavailable` and
  unknown fidelity strings. Snapshot recovery alone does not derive
  `isIncomplete()`.
- Slice order, lifetime bounds, non-overlap, nonzero CPU, derived band,
  canonical coalescing, peak recomputation, and checked sum.
- A non-first or unknown `flamez` version, unknown field, duplicate field,
  malformed base64, oversized decoded metadata, invalid refs, invalid enums,
  trailing JSON, and integer overflow are rejected with diagnostics.
- An unknown first-field version is rejected without consuming the body.
- Top-level keys after `flamez` still parse in a different order.
- `write(read(write(s)))` preserves all canonical section 5.5 fields.

Once a schema version is declared stable, commit representative files written
by that released writer. Every later reader runs the same semantic assertions
against every committed version fixture. Draft fixtures may be replaced before
v1 is declared stable; they do not create accidental compatibility promises.

### 9.2 Streaming and failure behavior

- A reader that returns small chunks parses correctly, including an escaped or
  base64 value split at every possible boundary.
- A single argument larger than `std.json.default_max_value_len` but within the
  Flamez bound imports successfully.
- Allocation failure at every reader/writer allocation leaves no leaked
  session or scratch storage.
- Writer validation failure emits zero bytes.
- A failed named-path write leaves the old destination byte-for-byte intact
  and removes its temporary file.
- GUI exclusive save refuses an existing suggested name.
- `-o -` keeps target stdout out of the JSON stream through both Linux and
  macOS spawn-option implementations.

### 9.3 CLI and optional smoke tests

- Parse `-o a -- zig -o b` as target `zig -o b`.
- Reject `-o`/`-i` combinations and extra import positionals.
- `capture.json` without `-i` remains a target command.
- Incomplete-plus-target-failure returns code 3; complete target failure
  returns code 4.
- Forced Stop flushes queued events, takes a boundary CPU sample, reaps and
  records the root status, and produces the same finished invariants as natural
  exit.
- Capture smoke where the platform collector is available:
  `flamez -o /tmp/t.json -- true`.
- Privilege-free import smoke: `flamez -i /tmp/t.json` with
  `FLAMEZ_SCREENSHOT` where a display is available.

---

## 10. Implementation order

1. Add the session-owned target argv reference, host CPU count, retained CPU
   sample period, unified loss count/query, tagged root exit, explicit
   `finished` marker, and finish-time derived-cache rebuild. Make path capture
   preserve exact bytes and observable truncation.
2. Refactor forced Stop into the existing collector-aware natural-finish path;
   preserve the root wait result, queued events, boundary CPU sample, exec
   metadata, and compaction. Keep a separate abort-only deinit cleanup.
3. Implement exec-aware `session_file.write` with stable rows, chronological
   execs, metadata interning, ByteString, compact slice triples, preflight
   validation, and buffer tests.
4. Implement streaming `session_file.read` with version-first dispatch,
   diagnostics, invariant validation, shared row/exec metadata reconstruction,
   and round-trip/failure tests.
5. Implement atomic `writeFile` and streaming `readFile`.
6. Thread stdout routing through `Session.StartOptions`, both process-operation
   backends, and the macOS suspended-spawn shim.
7. Implement cooperative first-signal state and second-signal abort.
8. Parse the explicit capture/output/import CLI modes, including stdin/stdout
   routing; add the headless loop and exit-status precedence.
9. Add GUI exclusive Ctrl+S save.
10. Add GUI import without collector/capability setup, using imported host CPU
    scale, fidelity, root/CPU provenance, and exec history.
11. Update README/usage and add smoke coverage.

Do not block this sequence on compression, Perfetto, or a file picker.

---

## 11. Follow-ups

- Measure representative compact JSON files before choosing optional zstd or a
  binary container.
- Chrome Trace / Perfetto converter.
- Additional analysis profiles if a future consumer needs more detail than the
  bounded, slice-free format in `ANALYSIS.md`.
- GUI file picker and explicit overwrite confirmation.
- GUI save-on-window-close using the same atomic writer.
- `flamez -i in.json -o out.json` rewrite/canonicalize mode.
- A complete clock-correlation object containing clock kind, boot identity, and
  a lossless timestamp representation if cross-trace alignment becomes a real
  requirement.
