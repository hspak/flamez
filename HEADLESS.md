# Session files: export, import, and headless capture

This document is the implementation spec for the Flamez session JSON file:
writing it after a capture, reading it back into a `Session`, rendering that
session in the GUI with no collector, and running a capture with no GUI. It
is not implemented yet.

Capture already lives in `Session` / `Process` with no raylib dependency. The
GUI is a derived view: packed lanes, pixel-aggregated CPU bars, and tooltip
wrapping are not part of the file. The file is the canonical tree plus
canonical CPU slices, including provenance so inferred values are not mistaken
for observations.

Three ways to get a finished `Session`, one renderer, one `write()` / `read()`
pair:

| Mode | How the session is filled | Window | BPF |
|---|---|---|---|
| Capture + GUI | spawn, `update` until exit or Stop | yes | required |
| Capture + file | same loop, then `write()` and exit | no | required |
| Open file | `read()` into a finished `Session` | yes | no |

Collection and export are the same path. Flamez always runs a live session
until capture ends — target root exited, or the user stopped it — and only
then serializes that snapshot. Headless is that path without a window: wait,
then write, then exit. The GUI is the same wait, then keep the window for
browsing; Ctrl+S is the same `write()` on the same immutable snapshot.
Opening a file **skips capture** and installs that snapshot directly; the
idle GUI path already exists for `!session.running`.

Implement `write`/`read` and round-trip tests first, then cooperative Ctrl+C,
then headless `-o`, then GUI save and GUI open.

Related docs: [README.md](README.md) (usage), [ARCHITECTURE.md](ARCHITECTURE.md)
(session model), [EBPF.md](EBPF.md) (collector), [PERF.md](PERF.md)
(canonical vs derived data).

---

## 1. Goals and non-goals

**Goals**

- Dump every process record Flamez kept, with parentage, lifetimes, argv/exe/cwd,
  self-CPU totals, and coalesced CPU slices.
- Preserve PID-reuse generations as distinct records.
- Label observed vs recovered vs capture-clipped data.
- Mark incomplete sessions instead of looking complete after ring/map loss.
- Stream the file so a pathological 6 MiB exec argv does not require a second
  copy of the whole session in a JSON value tree.
- Headless: no window, same BPF attach/spawn/teardown as the GUI.
- One finish-and-write epilogue for natural exit, Stop, and Ctrl+C.
- Open a session file in the GUI with no BPF, using the same records the
  writer emits.

**Non-goals (v1)**

- Chrome/Perfetto trace format (possible later converter).
- Folded-stack flamegraph text (too lossy).
- Packed-lane layout, collapse state, zoom window, selection.
- Writing JSON while the target is still running.
- A headless “streaming” format that differs from GUI save.
- Per-thread records (CPU is TGID-aggregated).
- Symbolized stacks.

---

## 2. One path: run until capture ends, then write

A dump is always a serialization of a **finished** session. The schema in §3
assumes every process has an `end_ns` and `end_kind` is not `open`. That is
the same state the GUI already reaches when the root exits or the user hits
Stop.

### 2.1 How capture ends

Three inputs, one `Session` outcome (`running == false`):

| Input | What happens |
|---|---|
| Target root exits | `waitpid` in `update` → `onRootExited`: remaining open descendants are `capture_clipped`, metadata compacted, collector detached. |
| GUI **Stop** | `Session.stop()`: TERM/KILL the process group, then the same close/compact. |
| Ctrl+C / SIGTERM / SIGHUP | Must become the same stop, **on the main thread**, then the same close/compact. Not “kill Flamez and hope.” |

After any of those:

- still-open descendants are closed with `end_kind = capture_clipped`;
- reachable metadata is compacted;
- natural exits already have kernel-final CPU; a forced stop keeps the last
  userspace snapshot (partial, labeled by `end_kind`).

That finished `Session` is what `write()` consumes. Headless and GUI capture
do not build a different record. `read()` produces the same kind of finished
session (`running == false`, every `end_ns` set) without ever attaching BPF.

### 2.2 Shared shape in `main`

```
session.start(...)
while session.running:
    session.update(collector)     // and GUI: draw; headless: short sleep
    if stop_requested:            // Ctrl+C flag; GUI Stop button already calls stop()
        session.stop()
finishCollector(session, collector)
if output_path: write(session)    // always, in headless; on demand, in GUI
if headless: exit per §5.1
if GUI: idle / browse; Ctrl+S may write again
```

`write(session)` is the only exporter. Headless is not a special collector; it
is this loop with `output_path` set and no window. GUI save is this loop with
a window, `write` invoked later.

Import does not enter the `while session.running` loop:

```
session = read(path)          // running == false, no child, no collector
initWindow / Clay / idle vsync path
```

The packed-lane rebuild, tooltips, detail pane, and CPU-bar scaling then run
exactly as they do after a live capture ends. The file's `host_cpu_count`
must drive bar height, not the viewing machine's CPU count.

### 2.3 Cooperative Ctrl+C

Today the fatal-signal handler TERM/KILLs the target group (required: the
target is in its own process group, so a default SIGINT would kill Flamez and
orphan the build), then restores the default disposition and **re-raises**.
Flamez dies; `defer` may not run; no JSON.

For export to share the path above, the first SIGINT/SIGTERM/SIGHUP must not
kill Flamez:

1. **Handler (async-signal-safe only):** TERM/KILL the target group as now,
   set an atomic `stop_requested` (or reuse the existing teardown so the root
   will reap as dead), do **not** re-raise on the first signal.
2. **Main loop:** sees `!session.running` (waitpid after the group dies) or
   the flag, calls `session.stop()` if still marked running, then hits
   `finishCollector` + `write`.
3. **Second signal:** previous abort behavior (re-raise) so a wedged write or
   hung `stop` cannot trap the user.

Headless Ctrl+C is then the same as GUI Stop plus “exit after write,” not a
second dump format. Descendants that die from the group kill may still produce
`observed_exit` records if `group_dead` arrives before detach; anyone still
open is `capture_clipped` — identical to the Stop button.

SIGHUP/SIGTERM get the same first-signal treatment in headless so `timeout(1)`
or a CI cancel still produces a file when possible.

Window close in the GUI already needs to `stop()` a live target so it does not
orphan; that remains `stop` without a write unless the user already saved.

### 2.4 Why not write while live

Open `end_ns`, unreconciled CPU, and an uncompacted metadata arena would force
a second schema (`end_kind: open`, nullable `end_ns`) and a second writer
path. Waiting until the session is finished keeps one schema and one `write()`.

---

## 3. File format

UTF-8 JSON, one object, no JSONC. The media type is `application/json`.
Suggested names: `*.json` on disk; stdout is a JSON stream with a trailing
newline.

### 3.1 Time domain

Every `*_ns` field except `started_at_monotonic_ns` is **session time**:
nanoseconds since Flamez's capture start, using the same awake/monotonic clock
as `Session.elapsed_ns` and kernel event rebasing.

`0` is the spawn instant of the target. A value of `elapsed_ns` is the capture
horizon (root exit or Stop).

JSON numbers are IEEE-754 doubles. Integer nanoseconds are exact up to 2^53 ns
(~104 days). Captures are expected far below that; do not stringify ns in v1.

### 3.2 Top-level object

| Field | Type | Required | Meaning |
|---|---|---|---|
| `flamez` | integer | yes | Schema version. v1 is `1`. Readers must reject unknown versions. |
| `incomplete` | boolean | yes | True if lifecycle records or map admissions were lost, or recovered stubs were created. The tree may be missing edges or contain inferred rows. |
| `lost_events` | integer | yes | Kernel drop counter (`Session.lost_events`). `0` if none. |
| `recovered_count` | integer | yes | Number of recovered parent/exec/exit stubs. |
| `cpu_sample_period_ns` | integer | yes | Userspace CPU snapshot cadence. Today `16000000`. Slices are **not** scheduler-transition exact. |
| `host_cpu_count` | integer | yes | Logical CPUs on the tracing host at start (`max(getCpuCount(), 1)`). Needed to interpret occupancy independently of the GUI's 75% bar cap. |
| `target` | array of string | yes | Exact argv passed to `Session.start`. Not a shell line. |
| `root` | integer or null | yes | `id` of the target process record. Null only if spawn failed before a root record existed (then `processes` is empty and the run should have failed earlier). |
| `elapsed_ns` | integer | yes | Capture duration; domain of the timeline. |
| `started_at_monotonic_ns` | integer | yes | Absolute CLOCK_MONOTONIC (or the session clock's raw timestamp) at spawn, so other traces can align. Not used as the record time base. |
| `exit_code` | integer or null | yes | Root exit status if `WIFEXITED`. Null if still unknown, signaled, or forced Stop without a reaped status. |
| `exit_signal` | integer or null | yes | Signal number if the root was signaled. Null otherwise. |
| `processes` | array of object | yes | Process records in **stable index order**. `processes[i].id == i`. |

No other top-level keys in v1. Extra keys from a future version are ignored
only after `flamez` is bumped and documented.

### 3.3 Process object

One object per `Process` record, including recovered stubs.

| Field | Type | Required | Meaning |
|---|---|---|---|
| `id` | integer | yes | Index in `processes`. Parent links use this, not pid. |
| `pid` | integer | yes | Userspace TGID at the time of the record. Not unique across the file: a reused TGID becomes a **new** object with a new `id`. |
| `parent` | integer or null | yes | `id` of the session-tree parent. Null for roots. This is `parent_index`, the layout/parentage edge. |
| `parent_pid` | integer or null | yes | Kernel-reported parent TGID, or the session root pid for recovered stubs. May disagree with `processes[parent].pid` only in recovery situations; consumers that want the drawn tree must use `parent`. |
| `depth` | integer | yes | Tree depth from the session root (`0` at root). |
| `start_ns` | integer | yes | Lifetime start in session time. For `origin` recovered_exit this is the death timestamp (fork time unknown). For recovered_parent / recovered_exec it is the later event time, not a measured birth. |
| `end_ns` | integer | yes | Lifetime end. After capture, every record is closed; v1 does not emit null. |
| `origin` | string | yes | How the row was created. See §3.5. |
| `end_kind` | string | yes | How the lifetime closed. See §3.5. After capture, not `open`. |
| `name` | string | yes | Display name, at most 48 bytes, trimmed. |
| `name_kind` | string | yes | `process` (kernel comm / real name) or `other` (fallback label such as argv basename or `"process"`). |
| `argv` | array of string | yes | Complete captured argument vector, **including argv[0] and empty arguments**. Empty array if none were captured. |
| `argv_source` | string | yes | Provenance of `argv`. See §3.5. |
| `exe` | object or null | yes | Executable path snapshot. Null if unavailable. |
| `cwd` | object or null | yes | Working directory snapshot. Null if unavailable. |
| `cpu_time_ns` | integer | yes | Cumulative self-CPU for every thread in the TGID, excluding descendants. Natural exits are kernel-final; `end_kind` `capture_clipped` means this is the last userspace snapshot (partial). |
| `cpu_peak_cores` | number | yes | Peak average-core occupancy across retained slices (`cpu_ns / wall` per slice). |
| `slices` | array of object | yes | Canonical coalesced CPU activity. Empty if the process never had a busy snapshot. |

`exe` / `cwd` object:

| Field | Type | Meaning |
|---|---|---|
| `path` | string | Bounded path (max 512 bytes). |
| `source` | string | Provenance. |
| `truncated` | boolean | True if the stored path hit the 512-byte cap (or the kernel marked exe truncated). |

Do not emit UI-only fields: `revision`, `signal_slot`, `cpu_snapshot_at_ns`,
`cpu_snapshot_initialized`, metadata arena offsets.

### 3.4 CPU slice object

| Field | Type | Meaning |
|---|---|---|
| `start_ns` | integer | Slice start, session time. |
| `end_ns` | integer | Slice end, `> start_ns`. Idle gaps are omitted, not stored as zero-CPU slices. |
| `cpu_ns` | integer | Self-CPU attributed to this interval. **May exceed** `end_ns - start_ns` when several threads ran in parallel. |
| `band` | integer | Quarter-core occupancy band used for coalescing: `ceil(4 * cpu_ns / duration)`, clamped to `[0, 64]` (16 cores). Adjacent equal bands merge in capture; export the merged slices, do not re-split. |

`average_cores` is not stored; it is `cpu_ns / (end_ns - start_ns)` when duration
is nonzero. The GUI's 75% host-core bar fill is a render cap and must not be
applied in the file.

Slice contract (same as capture):

- Cadence is `cpu_sample_period_ns`, not context-switch edges.
- Missed snapshots delay bucket boundaries; cumulative CPU is not lost.
- A natural `group_dead` exit reconciles the newest slices to the kernel total.
- Forced Stop does not take a final kernel total.

### 3.5 Enumerations

Emit the identifier strings below, not integers.

**`origin`**

| Value | Meaning |
|---|---|
| `observed` | Created from a fork (or the launched root). Start time is an observed fork/spawn. |
| `recovered_parent` | Stub invented because a child forked from an unknown parent. Start is the child's event time. Parentage under the session root is inferred. |
| `recovered_exec` | Exec for a pid that had no live record. True parent unknown; attached under the session root. Start is the exec timestamp. |
| `recovered_exit` | Exit for a pid that was never seen. Zero-width bar: `start_ns == end_ns` at death. Fork time unknown. |

**`end_kind`**

| Value | Meaning |
|---|---|
| `observed_exit` | Closed by a `group_dead` exit record. `cpu_time_ns` is the kernel final. |
| `capture_clipped` | Closed because the session ended (root exit or Stop) while this process was still open. Not proof it exited at `end_ns`. `cpu_time_ns` is the last sampled total. |

v1 files never contain `open`.

**`argv_source` / `exe.source` / `cwd.source`**

| Value | Meaning |
|---|---|
| `unavailable` | No bytes (argv is `[]`, exe/cwd are null). |
| `inherited` | Copied by offset from the parent at fork. |
| `launch` | Flamez's own spawn argv (root). |
| `kernel` | Exec tracepoint snapshot. |
| `procfs` | `/proc/<pid>/…` fill-in when the event lacked the field. |

### 3.6 Invariants

Readers can rely on:

1. `processes[i].id == i`.
2. `parent` is null or a smaller-or-equal index of an existing record (parents
   are created before children in the current collector; do not require
   `parent < id` if a future recovery inserts a stub after the child — v1
   writer should still emit parent before child where possible). Safer rule:
   `parent` is null or `0 <= parent < processes.length`.
3. `root` is null or a valid `id`.
4. `end_ns >= start_ns`. Zero-width is legal for `recovered_exit`.
5. Slice `end_ns > start_ns`, slices per process are sorted by `start_ns` and
   do not overlap (they may gap).
6. Sum of slice `cpu_ns` equals `cpu_time_ns` except after forced-stop
   partials or if idle CPU was never sliced — actually idle is not sliced, and
   coalescing preserves cpu_ns. Writer should treat `cpu_time_ns` as
   authoritative; slice sum should match for natural exits.
7. `incomplete` is true if `lost_events > 0` or `recovered_count > 0`.
8. Empty arguments in `argv` are `""` entries, not omitted.

### 3.7 What the file is not

- Not a screenshot of the timeline. Packed jobs that share a lane in the GUI
  are still separate process objects.
- Not sampled stacks.
- Not a complete system trace: only the target tree Flamez tracked.
- Not lossless vs the kernel scheduler. Slices are ~16 ms occupancy buckets.

### 3.8 Example

Two-process session: launched `sleep 30`, one observed child `clang` that
exited naturally; capture then ended. Host has 8 logical CPUs. Comments are
not present in real files.

```json
{
  "flamez": 1,
  "incomplete": false,
  "lost_events": 0,
  "recovered_count": 0,
  "cpu_sample_period_ns": 16000000,
  "host_cpu_count": 8,
  "target": ["sleep", "30"],
  "root": 0,
  "elapsed_ns": 15000000,
  "started_at_monotonic_ns": 1234567890123,
  "exit_code": 0,
  "exit_signal": null,
  "processes": [
    {
      "id": 0,
      "pid": 1000,
      "parent": null,
      "parent_pid": null,
      "depth": 0,
      "start_ns": 0,
      "end_ns": 15000000,
      "origin": "observed",
      "end_kind": "observed_exit",
      "name": "sleep",
      "name_kind": "process",
      "argv": ["sleep", "30"],
      "argv_source": "launch",
      "exe": { "path": "/usr/bin/sleep", "source": "procfs", "truncated": false },
      "cwd": { "path": "/home/user/src", "source": "procfs", "truncated": false },
      "cpu_time_ns": 200000,
      "cpu_peak_cores": 0.25,
      "slices": [
        { "start_ns": 0, "end_ns": 16000000, "cpu_ns": 200000, "band": 1 }
      ]
    },
    {
      "id": 1,
      "pid": 1001,
      "parent": 0,
      "parent_pid": 1000,
      "depth": 1,
      "start_ns": 10000000,
      "end_ns": 14000000,
      "origin": "observed",
      "end_kind": "observed_exit",
      "name": "clang",
      "name_kind": "process",
      "argv": ["clang", "-c", "source.c"],
      "argv_source": "kernel",
      "exe": { "path": "clang", "source": "kernel", "truncated": false },
      "cwd": { "path": "/home/user/src", "source": "inherited", "truncated": false },
      "cpu_time_ns": 3500000,
      "cpu_peak_cores": 1.0,
      "slices": [
        { "start_ns": 10000000, "end_ns": 14000000, "cpu_ns": 3500000, "band": 4 }
      ]
    }
  ]
}
```

Recovered-exit stub (pid never forked in the ring):

```json
{
  "id": 2,
  "pid": 8888,
  "parent": 0,
  "parent_pid": 1000,
  "depth": 1,
  "start_ns": 6000000,
  "end_ns": 6000000,
  "origin": "recovered_exit",
  "end_kind": "observed_exit",
  "name": "sleep",
  "name_kind": "process",
  "argv": [],
  "argv_source": "unavailable",
  "exe": null,
  "cwd": null,
  "cpu_time_ns": 0,
  "cpu_peak_cores": 0,
  "slices": []
}
```

---

## 4. Writer and reader

### 4.1 Placement

New module, e.g. `src/export.zig`, imported by `tracer.zig` tests and `main`.
Copy `target` argv, `host_cpu_count`, and `started_at_monotonic_ns` onto
`Session` at `start`, and restore them in `read`, so `write` / `read` take
the session alone. That also makes headless, GUI save, and GUI open identical.

Public API sketch:

```zig
pub fn write(session: *const Session, writer: *std.Io.Writer) WriteError!void
pub fn writeFile(session: *const Session, path: []const u8) WriteError!void
pub fn read(gpa: Allocator, io: std.Io, bytes: []const u8) ReadError!Session
pub fn readFile(gpa: Allocator, io: std.Io, path: []const u8) ReadError!Session
```

`WriteError` is `Allocator.Error` (if any scratch is needed) plus file/write
errors. `ReadError` is `Allocator.Error` plus a small closed set (`InvalidJson`,
`UnsupportedVersion`, `InvariantViolated`, …) with a message suitable for
stderr or the GUI status line. Do not allocate a DOM of the whole session
when writing. Reading may parse with `std.json` into temporary values, then
copy into `Process` records and the metadata arena.

### 4.2 Streaming

Write incrementally:

1. Header object keys up through `"processes": [`
2. Each process object, comma-separated
3. Closing `]}` and a newline

For each process, write identity/metadata first, then `"slices": [` and each
slice. Argv: iterate `argsIter` and JSON-string-escape each argument. Do not
space-join then split.

Use `std.json.Stringify` for strings (escaping) and for small nested objects
(`exe`, `cwd`, slices) if convenient; do not stringify the entire session as
one value.

### 4.3 Session fields to add at capture start

| Field | Source |
|---|---|
| retained `target` argv | already applied to root via `setArgsFromArgv`; also keep a session-level copy so spawn failure still has `target` |
| `host_cpu_count` | `std.Thread.getCpuCount()` at start |
| `started_at_monotonic_ns` | `started_at` already exists; export its nanosecond representation |

### 4.4 Size

A busy process at 16 ms cadence with alternating bands can add a slice every
sample (~60/s). Minutes of that is large but still JSON-text sized. Argv is
the other payload (complete, including empties, up to the 6 MiB exec bound).
Streaming avoids doubling it.

Optional later flag `--no-slices` is out of v1 unless files are proven too
large; slices are the red-bar data.

### 4.5 Reader

`read` is the inverse of `write`: bytes in, a finished `Session` out. It does
not spawn, attach BPF, or set `running`. After success:

- `running == false`, `child == null`, `root_pid` unset (the tree root is
  `session` field `root` / `processes[root]`);
- `elapsed_ns` is the file's capture horizon; `timelineNs()` returns that
  without consulting a live clock;
- every process has `end_ns` and `end_kind != open`;
- `by_pid` may be left empty (live-only); the GUI does not need it after
  capture;
- metadata arena is rebuilt by appending each record's argv/exe/cwd. **Do
  not** try to reconstruct fork-time offset sharing; duplicate bytes are
  fine. Semantics of `argv_source: inherited` stay in the field, not in
  pointer equality;
- `cpu_slices` are appended in file order;
- `host_cpu_count` and `target` come from the file, not the viewing host.

Validation (fail the read, do not render a half-tree):

- `flamez == 1`;
- `processes[i].id == i`;
- `parent` is null or an in-range id;
- `root` is null or an in-range id;
- `end_ns >= start_ns`; slice `end_ns > start_ns`, sorted, non-overlapping;
- enums are known strings;
- `incomplete` is true if `lost_events > 0` or `recovered_count > 0` (if the
  file disagrees, prefer the counters and still load, or reject — reject is
  simpler for v1).

A round-trip `write(read(write(session)))` need not be byte-identical
(whitespace, inherited-byte sharing) but must compare equal on the fields in
§3.

Unknown keys: ignore at the object level so a `flamez: 1` file with extra
fields from a newer writer still opens. Unknown `flamez` versions: reject.

---

## 5. Command-line interface

Today every argument after the binary is the target. Flags come **first**,
then an optional `--`, then either a capture target or nothing (import uses
`-i`). GNU-style:

```
flamez [flamez-flags] [--] [<target> [target-args...]]
```

Three mutually exclusive modes:

| Mode | Invocation | Window | BPF |
|---|---|---|---|
| Capture + GUI | `flamez [--] <target> [args...]` | yes | yes |
| Capture + file | `flamez -o <path> [--] <target> [args...]` | no | yes |
| Open file | `flamez -i <path>` or `flamez <file.json>` | yes | no |

| Flag | Meaning |
|---|---|
| `-o <path>`, `--output <path>` | Write the finished session JSON here. `-` is stdout. **Implies headless.** Capture runs until the target exits or the user stops it (Ctrl+C); then one write. |
| `-i <path>`, `--import <path>` | Load a session file and open the GUI. No collector. Path `-` (stdin) is **not** v1: the GUI still needs a TTY. |
| `--` | End of Flamez flags. Required only when the target looks like a flag. |

Examples:

```
flamez -o capture.json -- zig build -Doptimize=ReleaseFast
flamez --output=- make -j8
flamez zig build
flamez -i capture.json
flamez capture.json
```

Rules:

- `-o` and `-i` together: usage error (exit 2). That would be convert-without-
  render; if we want it later, it is `read` + `write` with no new format.
- `-o` without a target: usage error.
- `-i` with extra positionals: usage error.
- **Bare `flamez capture.json`:** if there is exactly one positional, it names
  an existing regular file, and the file is a JSON object with a `flamez`
  integer, treat it as `--import`. Otherwise treat it as a target command
  (including a binary that happens to be named `foo.json`). Peeking the file
  avoids a new subcommand and still allows `flamez ./build.json` as a script
  name when the file is not a session.
- `-o` path: create/truncate. Overwriting is allowed when the user named the
  file.
- Default GUI Ctrl+S path can refuse to clobber; `-o` is explicit.
- Import does **not** require `cap_bpf` / an installed BPF object. Fail on
  parse with a stderr message and exit 1, never on missing capabilities.

Usage text should show all three modes.

### 5.1 Exit status (headless)

| Code | When |
|---|---|
| 0 | Capture ended, file written, `incomplete == false`, and if the root had `exit_code`, it is 0. |
| 1 | BPF unavailable, spawn failed, or write failed. Message on stderr. |
| 2 | CLI usage error. |
| 3 | File written but session `incomplete` (loss/recovery). |
| 4 | File written, session complete, but target `exit_code != 0` or signaled. |

(Exact mapping of 3 vs 4 can be bikeshed at implementation; both must be
distinct from BPF/spawn failure so CI can `&&` on a clean trace.)

A user stop (Ctrl+C / SIGTERM) that still writes a file is not a BPF failure:
use 4 if the root was killed/signaled, 0 if it had already exited 0 before
the signal was applied. Do not use a separate “interrupted, no file” code
for the first signal; that would mean the epilogue was skipped.

GUI process exit code stays as today (window close is success even if the
target failed). The JSON still records `exit_code` / `exit_signal`.

---

## 6. Headless run loop

Headless is §2 with no window: install the same capabilities, attach, drop
caps, spawn, **wait until the session ends**, write, exit. Waiting means the
target root has exited, or the user (or CI) sent SIGINT/SIGTERM/SIGHUP and
the cooperative stop in §2.3 finished. The JSON is not a heartbeat; it is the
whole capture.

```
installFatalSignalHandlers()   // first signal: kill target group, request stop
parse argv into (output_path, target_argv)
collector.init(); fail like GUI if unavailable
dropCapabilities()
session.start(collector, target_argv)
while session.running:
    session.update(collector)
    if stop_requested: session.stop()
    sleep ~1ms
finishCollector(...)
write(session) to output_path or stdout
exit per §5.1
```

Details:

- **Sleep:** `std.Io.sleep` ~1 ms on the awake clock is enough. Faster polling
  only helps drain a bursty ring; `update` already uses timeout-0 poll. If a
  build forks tens of thousands of processes in one millisecond, the 16 MiB
  ring is the real bound — same as the GUI. Do not add a second userspace
  queue.
- **Natural end vs stop:** both fall out of `!session.running` and use the
  same `write()`. Forced stop is visible in the file as `capture_clipped`
  descendants and possibly a null `exit_code` if the root was KILLed before
  reap — same records the GUI already produces for Stop.
- **stdout:** `-o -` writes JSON only to stdout. Diagnostics stay on stderr.
- **stderr of the target:** still inherited, same as GUI, so `make` output
  appears in the terminal while JSON goes to `-o`.
- **No screenshot / FPS / idle vsync paths.**

---

## 7. GUI

### 7.1 After a live capture

The GUI run loop is the same `start` / `update` until `!running` / `stop`.
After capture ends the window stays up (idle vsync path). Export is not a
second collection; it is `write(session)` on that finished snapshot.

- **Ctrl+S** (suggested) after `!session.running` writes
  `flamez-<root-name>-<elapsed>.json` in the cwd, or `flamez-session.json` if
  naming is deferred. Footer: `Wrote capture.json` or `Could not write: …`.
- Repeatable; the session is immutable after capture.
- No file picker in v1.
- **Stop** and a cooperative Ctrl+C *during* capture are §2.3: they end the
  session like today, then the user can Ctrl+S. They do not write unless we
  later add “always save on Stop”; v1 keeps auto-write as a headless `-o`
  property so a GUI session does not surprise-overwrite a file.

If a future flag wants “GUI but also write on exit,” it should call the same
epilogue `write()` when the window closes after capture, not a new format.

### 7.2 Opening a session file

Import is the idle GUI with a session that was never live in this process:

- Do not call `EbpfCollector.init`, `dropCapabilities`, or `session.start`.
- `readFile` → `App.init` → window. Skip the capability hard-fail.
- Fatal-signal handlers can stay installed; they must no-op when no target
  group is armed (already true if `start` was not called).
- Footer: same **FINISHED** / **INCOMPLETE** / exit metadata as a just-ended
  capture. No **Stop** button (`session.running` is false). **ACTIVE** is 0.
- Tree packing, zoom, detail pane, and tooltips run unchanged.
- CPU bar height uses **`session.host_cpu_count` from the file**, so a trace
  taken on a 64-core builder does not flatten on an 8-core laptop.
- Ctrl+S re-exports through `write()`; a round-trip is a supported way to
  copy a file.
- `FLAMEZ_SCREENSHOT` should work on an imported file so fixtures can drive
  visual checks without tracing privileges.

Window title can mention the path (`Flamez — capture.json`) so a replay is
not mistaken for a live session.

---

## 8. Tests

Keep export tests on the tracer test root so they do not need a window.

- Empty-ish session after `start` + synthesized fork/exec/exit: `write` then
  `read`, check `id` / `parent` / `argv` including an empty argument.
- PID reuse: two records, same `pid`, different `id`, second `parent` valid
  after round-trip.
- Recovered parent / exec / exit: `origin`, `incomplete`, `recovered_count`.
- Capture-clipped descendant: `end_kind` `capture_clipped` after `stop`.
- Slice list ordered, non-overlapping; `cpu_time_ns` vs slice sum on the
  natural-exit path.
- `read` rejects unknown `flamez` version, bad `parent` ids, and `open`
  `end_kind`.
- `write(read(write(s)))` matches on §3 fields (not necessarily bytes).

Headless smoke (optional, privileges): `flamez -o /tmp/t.json -- true` and
check `exit_code == 0`, one process, file starts with `{`. Import smoke (no
privileges): `flamez -i /tmp/t.json` with `FLAMEZ_SCREENSHOT` if a display is
available; otherwise `readFile` in the test binary is enough.

Stop-then-write: `session.start` + synthesized child + `session.stop` +
`write` yields `capture_clipped` on the still-open child and a well-formed
file (this is Ctrl+C / Stop, not a second exporter).

---

## 9. Implementation order

1. **Session extras** — store host CPU count, exportable start timestamp, and
   a session-level target argv copy. `timelineNs()` must honor a frozen
   `elapsed_ns` when `running` is false (already true if `update` is not
   called).
2. **Writer + reader + round-trip tests** — `write` / `read` against a buffer;
   include `stop()` then `write` then `read`. No CLI yet.
3. **Cooperative first signal** — atomic stop request; handler still kills
   the target group; main loop `stop()` + continues. Second signal aborts.
   Shared by GUI and headless; required before promising `-o` under Ctrl+C.
4. **CLI parse** — Flamez flags vs target vs import; unit-test the splitter
   (`-o a -- zig -o b` → target `zig -o b`; one positional session file →
   import; `./script.json` that is not a Flamez object → target).
5. **Headless loop** — `-o` skips GUI; wait until `!running`; `write`; exit.
6. **GUI Ctrl+S** — same `write` on a finished live session.
7. **GUI `--import` / bare session path** — `readFile`, no BPF, idle window,
   bar scale from file `host_cpu_count`.
8. **README / usage** — document `-o`, `-i`, Ctrl+C, and the schema pointer
   here.

Do not block (1–7) on Perfetto export or a file-picker dialog.

---

## 10. Follow-ups (not v1)

- Chrome Trace / Perfetto converter for `chrome://tracing`.
- `--no-slices` or a second “summary only” file.
- GUI “write on window close” using the same epilogue.
- `flamez -i in.json -o out.json` as a no-GUI rewrite/canonicalize.
- Include packed-lane assignment as an optional derived section (recomputable
  from the tree; do not make it canonical).
