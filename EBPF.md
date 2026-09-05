# eBPF in Flamez

eBPF process-event capture is mandatory on Linux v7 or newer. If the object
cannot be validated, loaded, or attached, Flamez prints a diagnostic and exits
before opening a window. `/proc` is used only for one-shot metadata enrichment;
it is not a lifecycle-discovery fallback.

This document describes the current implementation, its privilege boundary,
and the checks that should remain true when the collector changes.

## Runtime path

```
zig build
  clang -target bpf -O2 -g -Wall -Wextra -Werror
    src/flamez.bpf.c -> share/flamez/flamez.bpf.o
  compile src/ebpf_shim.c into flamez and link libbpf

./build.sh
  install root-owned binary + object under FLAMEZ_PREFIX (/usr/local)
  setcap cap_bpf,cap_perfmon=ep on the binary
  reject a nosuid target mount

/usr/local/bin/flamez <target> ...
  Collector.init()
    reject kernels older than Linux v7
    check effective capabilities
    open and snapshot a trusted BPF object
    validate its exact programs and map schemas
    load, attach, and create the ring-buffer reader
  clear all effective/permitted/inheritable capabilities
  Session.start()
    seed Flamez as a temporary parent through the open map fd
    spawn and track the target
    remove the seed
  initialize the GUI
  each live frame: ring_buffer__poll(0), CPU-map snapshot on the
                   documented ~16 ms cadence, update the tree,
                   waitpid(root, WNOHANG)
```

The relevant files are:

| File | Responsibility |
|---|---|
| `src/flamez.bpf.c` | kernel programs, filtering, metadata capture, CPU accounting |
| `src/flamez_event.h` | shared C record layout and ABI assertions |
| `src/ebpf_shim.c` | trust gate, libbpf load/attach, capabilities, map access |
| `src/tracer/capture/linux.zig` | Zig ABI mirror and Linux collector wrapper |
| `src/tracer/capture.zig` | backend-neutral events, sink, and collector selection |
| `src/tracer/Session.zig` | target handoff and event-to-process state |
| `build.zig` | warning-clean host/BPF compilation and installation graph |
| `build.sh` | privileged install, file capabilities, and mount validation |

## Programs and filtering

The object is GPL-licensed and uses CO-RE raw tracepoints:

| Section | Tracepoint arguments | Emitted data |
|---|---|---|
| `raw_tp/sched_process_fork` | parent and child `task_struct *` | TGID, parent TGID, child comm |
| `raw_tp/task_newtask` | child task and clone flags | no record; admits threads including io_uring workers |
| `raw_tp/sched_process_exec` | task, old PID, `linux_binprm *` | TGID, comm, bounded filename and complete argv |
| `raw_tp/sched_process_exit` | task and `group_dead` | TGID, comm, final self CPU |
| `raw_tp/sched_switch` | preempt flag, previous task, next task, previous state | no record; updates CPU maps |

Lifecycle identity is the thread-group ID (the userspace PID), not the thread
ID. Fork events where child and parent have the same TGID are thread creation
and emit no lifecycle record. The task-creation hook counts them before they
can run, including io_uring workers that bypass `sched_process_fork`.

All hooks run system-wide. Lifecycle hooks reject unrelated TGIDs before
reserving a record. The scheduler miss path performs a `running_threads`
lookup for each outgoing and incoming TID; unrelated switches update no state and reserve no ring-buffer space. On a
tracked fork, the kernel inserts the child before it can exec or fork, so
tracking propagates synchronously through the tree.

`Session.start` inserts Flamez as a one-child seed parent immediately before
spawn. The fork hook tracks that first child but suppresses its redundant fork
record; userspace already owns the root record. The seed is removed as soon as
spawn returns.

## Kernel memory

Map sizes are a correctness tradeoff, not leftover headroom. The collector
preallocates:

| Map | Type | Bound | Role |
|---|---|---|---|
| `events` | ring buffer | 16 MiB | lifecycle records |
| `tracked_pids` | hash | 65,536 | admission + sched_switch miss path |
| `process_cpu` | hash | 65,536 | cumulative self-CPU totals |
| `running_threads` | hash | 65,536 | admitted threads, with running flag and schedule-in time |

The userspace teardown table is another 65,536 atomic PID slots. Do not shrink
these or switch to non-preallocated hashes without measuring peak live
processes/threads and loss behavior: an allocation failure inside a scheduler
tracepoint is worse than a few idle MiB.

## Exit behavior

`sched_process_exit` fires once per thread. Each callback accounts its last
interval and removes its scheduling entry before atomically releasing its
thread count. The callback releasing the last thread emits the final CPU total
and removes the process maps, even if the ring buffer cannot accept the event.
The event time is the final accounting callback's timestamp.

The kernel determines `group_dead` before reaching the tracepoint. A thread
that decremented the kernel's live count earlier can reach the callback later,
so `group_dead` is not an accounting barrier. Counting thread completion in
the BPF programs prevents premature publication and map deletion. Scheduling
cannot re-admit an exited thread while kernel teardown continues.

- [Linux `sched_process_exit` tracepoint](https://github.com/torvalds/linux/blob/master/include/trace/events/sched.h)
- [Linux process-exit path](https://github.com/torvalds/linux/blob/master/kernel/exit.c)
- [Linux task-creation paths](https://github.com/torvalds/linux/blob/master/kernel/fork.c)

## CO-RE and the classic-tracepoint trap

The BPF source declares only the fields it reads from `task_struct`,
`mm_struct`, and `linux_binprm`, all with `preserve_access_index`.
libbpf relocates those fields against `/sys/kernel/btf/vmlinux`. The `-g`
flag is therefore required; the object must contain `.BTF` and `.BTF.ext`.

Flamez deliberately does not use `SEC("tracepoint/sched/...")`. Classic
tracepoint programs read the tracefs event-record layout, which is not a stable
ABI. In particular, kernels can change fixed character arrays to `__string`
fields represented by `__data_loc`. A stale BPF context struct can then load
successfully but fail attach with `-EACCES` because its
`max_ctx_offset` exceeds the event's last fixed field. That error is a
layout rejection, not necessarily a capability failure.

Raw tracepoints receive the tracepoint function arguments and attach through
`bpf_raw_tracepoint_open`; they do not read tracefs event-ID files. There is
no classic/perf-event attach fallback in the loader and no reason to grant
`CAP_DAC_READ_SEARCH`.

## Event ABI and loss behavior

Fork and exit use a 56-byte header:

```
u32 kind          1=fork, 2=exec, 3=exit
s32 pid
s32 parent_pid    meaningful for fork
u32 metadata_flags
u64 timestamp_ns  bpf_ktime_get_ns()
char comm[16]
u32 args_len
u16 exe_len
u16 reserved
u64 cpu_ns         final self CPU for exit; zero otherwise
```

Exec starts with a 568-byte header: the common header followed by `exe[512]`.
The exact `args_len`-byte NUL-separated argument block follows it. Metadata
flags identify valid fields and filename truncation; argv has no truncation
flag because Flamez emits the complete block or drops the entire record.
`src/flamez_event.h` and Zig both assert the fixed header sizes, and both the C
shim and Zig validate the variable payload length before exposing it.

The `events` ring buffer is 16 MiB. Exec reserves an exact-size ring record
through a dynptr and copies argv with bounded, verifier-compatible chunk reads.
Typical execs therefore consume much less space than the previous fixed
4,664-byte record while valid Linux argument blocks up to the kernel's 6 MiB
upper bound remain representable. A reservation or user-memory copy failure
increments the loss counter and emits no partial argv.

### CPU accounting and snapshots

`running_threads` maps each admitted TID to its TGID, running flag, and
schedule-in timestamp. Sleeping threads retain an idle entry; exiting threads
remove it. `process_cpu` stores completed on-CPU time and the live thread count.
Schedule-out clears the running flag before adding the elapsed interval to the
completed total. Clearing first means a concurrent
snapshot may defer an interval until the next frame, but cannot count the same
interval as both running and complete. A snapshot evaluates:

```
cumulative_cpu_ns = completed_cpu_ns
                  + sum(now_ns - started_at_ns for each running TID in the TGID)
```

The atomic update is valid in tracing programs; `bpf_spin_lock` is deliberately
not used because the verifier rejects it for this program type. The C shim
batch-reads both maps (256 entries at a time), indexes process totals in a
reusable hash table, adds still-running intervals, and delivers the borrowed
`(tgid, cpu_ns)` array plus its snapshot timestamp to Zig. Idle thread entries
are skipped. Snapshot scratch storage grows geometrically with the number of live
processes and is reused across frames.

Zig samples on the session cadence, independently of rendering, and once more
at the root boundary. Consecutive cumulative values become
variable-duration activity buckets; idle buckets require no stored slice, and
adjacent active buckets in the same quarter-core occupancy band coalesce.
This deliberately trades scheduler-transition precision for bounded transfer
and storage overhead. CPU accounting is process-exclusive (all threads in one
TGID, no descendants), and a bucket may exceed one average core. Because the
userspace timestamp follows the running-thread map read, a live bucket can
contain a small scheduling-race overestimate. The kernel-timestamped final exit total
reconciles that skew from the newest slices on natural exit; forced Stop keeps
the most recent successful snapshot.

The `counters[0]` value increments when:

- a ring-buffer reservation fails; or
- the fork hook cannot insert a tracked child; or
- a CPU-accounting map admission fails, for example because a hash is full.

The collector reads this counter once per frame, logs increases, and exposes
`DROPPED` in the footer. A failed fork-record reservation does not untrack
the child, so a later exec, grandchild fork, or exit can recover the missing
node. The final-exit hook always retires its own map entry. Userspace also
recovers an unknown parent/exec/exit under the session root rather than
silently hiding a subtree.

The lifecycle callback accepts only the three known event kinds, exact sizes
for fork/exit, and a validated header-plus-payload size for exec before passing
a record to Zig. The loader also requires:

- five exact program-name/section pairs (fork, thread creation, exec, exit, scheduler switch);
- `events`: ring buffer, 16 MiB;
- `tracked_pids`: hash, `u32 -> u8`, 65,536 entries;
- `process_cpu`: hash, `u32 -> { u64 total_ns, u64 live_threads }`, 65,536 entries;
- `running_threads`: hash,
  `u32 tid -> { u32 tgid, u32 running, u64 started_at_ns }`, 65,536 entries;
- `counters`: array, `u32 -> u64`, one entry;
- `abi_v8`: array, `u32 -> u32`, one entry. This marker covers record layout,
  final-TGID exit semantics, and CPU accounting, so a stale object is rejected.

Compiler-emitted constants can add internal maps such as `.rodata.cst16`.
The loader uses libbpf's `bpf_map__is_internal` interface to recognize these
separately from the six ABI maps. Only read-only single-entry arrays with the
standard key layout and optional mmap flag are accepted; writable internal
maps and changes to the ABI maps are still rejected. This follows
[libbpf's internal-map construction](https://github.com/libbpf/libbpf/blob/v1.7.0/src/libbpf.c#L1837-L1891).
A normal, unprivileged test opens the compiled BPF object and runs the same
program/map validators, so compiler-generated sections cannot hide behind the
privileged collector tests' skips.

## Object trust

A binary with file capabilities must not load arbitrary caller-controlled BPF
bytecode. The non-root path therefore:

1. resolves `<prefix>/share/flamez/flamez.bpf.o` from `/proc/self/exe`, or
   uses `FLAMEZ_BPF_OBJECT` if explicitly set;
2. opens the final component with `O_NOFOLLOW | O_CLOEXEC`;
3. requires a regular, root-owned file with no group/world write bit and
   verifies that the real caller cannot write it (including through an ACL);
4. reads it once into a bounded in-memory snapshot;
5. validates the programs and complete map schemas before load.

There is no cwd-relative fallback. A non-root capable invocation rejects a
user-owned development object even when `FLAMEZ_BPF_OBJECT` names it.
`FLAMEZ_BPF_OBJECT` remains useful for root-run smoke tests and for selecting
another root-owned deployment object.

Program/schema validation catches stale or accidental objects; root ownership
is the actual privilege boundary. `build.sh` installs both files as root and
reapplies file capabilities after replacing the executable inode.

## Capabilities

The installed binary has:

| Capability | Startup use |
|---|---|
| `CAP_BPF` | create maps and load tracing programs |
| `CAP_PERFMON` | load/attach tracing programs without broad `CAP_SYS_ADMIN` |

`CAP_SYS_ADMIN` also satisfies the kernel's older broad tracing checks, but
Flamez does not install it. `CAP_DAC_READ_SEARCH` is not required because raw
tracepoint attachment does not inspect the root-only tracingfs tree.

The shim checks `CapEff` even for effective UID 0; root in a restricted user
namespace is not automatically capable in the namespace that owns BPF.
After attach, `capset` clears the effective, permitted, and inheritable sets
before the target is spawned or raylib/window/font initialization begins.
Existing BPF map, link, and ring-buffer descriptors remain usable for polling
and map updates. A failure to drop capabilities is fatal.

Confirm the installed inode and mount:

```sh
getcap /usr/local/bin/flamez
# cap_perfmon,cap_bpf=ep

findmnt -no OPTIONS --target /usr/local/bin/flamez
# must not contain nosuid

stat -c '%U:%G %A %n' \
  /usr/local/bin/flamez /usr/local/share/flamez/flamez.bpf.o
```

The development executable in `zig-out/bin` intentionally has no file
capabilities. `strace` and `gdb` can also suppress file capabilities for the
traced process, so a denial under ptrace is not proof that the normal
installed invocation is denied.

## Sysctls and policy

| Setting | Effect on Flamez |
|---|---|
| `kernel.unprivileged_bpf_disabled=1` | blocks unprivileged `bpf()` permanently until reboot; Flamez's `CAP_BPF` path remains privileged |
| `kernel.unprivileged_bpf_disabled=2` | blocks unprivileged `bpf()`, but an administrator may change it to 0 or 1; Flamez's capable path remains privileged |
| `kernel.perf_event_paranoid>=2` | blocks kernel profiling for callers without `CAP_PERFMON`; Flamez has it during attach |
| `kernel.kptr_restrict` | not used by this CO-RE/raw-tracepoint path |
| LSM/lockdown policy | can still deny BPF independently of capabilities |

The upstream definitions of values 1 and 2 are in the
[kernel sysctl documentation](https://www.kernel.org/doc/html/latest/admin-guide/sysctl/kernel.html#unprivileged-bpf-disabled).
Do not lower a system-wide sysctl or add `CAP_SYS_ADMIN` merely to work around
an attach error.

## Failure triage

Work in this order:

1. Run the installed binary and inspect it with `getcap`.
2. Check that its mount is not `nosuid`.
3. Read Flamez's capability/object-trust diagnostic.
4. For parse/schema errors, reinstall the binary and object together.
5. For load errors, check `/sys/kernel/btf/vmlinux`, verifier output, and
   LSM/lockdown audit logs.
6. For raw-tracepoint attach errors, check that the tracepoint exists and that
   `CAP_BPF`/`CAP_PERFMON` are effective. The classic
   `max_ctx_offset` diagnosis does not apply to `raw_tp`.

libbpf warnings are intentionally left enabled so verifier and CO-RE
diagnostics are not discarded.

If the verifier reports `tracing progs cannot use bpf_spin_lock yet`, the
installed object predates ABI v6. Rebuild and reinstall the executable and BPF
object together with `./build.sh`.

Do not:

- add `CAP_SYS_ADMIN` “just in case”;
- restore `CAP_DAC_READ_SEARCH` for a raw-tracepoint-only object;
- allow a capable non-root run to load a user-writable object;
- add a cwd-relative object fallback;
- switch back to classic scheduler tracepoints without auditing the running
  kernel's event layouts.

## Capture boundary and validation

Capture ends when `waitpid(target, WNOHANG)` reports the target's exit.
Descendants still open are closed at the same timestamp, tracked state is
dropped with the collector, and descendants do not extend the trace.
`EINTR` does not imply death; `ECHILD` is confirmed with `kill(pid, 0)`.

`zig build test` includes synthesized event/state tests. The live collector
smoke test skips without tracing privilege and must attach successfully when
run with sufficient privilege. Static validation should also confirm:

```sh
llvm-objdump -h zig-out/share/flamez/flamez.bpf.o
# expect .BTF and .BTF.ext

getcap /usr/local/bin/flamez
findmnt -no OPTIONS --target /usr/local/bin/flamez
```

Host requirements are Linux v7 or newer with BPF syscalls, scheduler raw
tracepoints, vmlinux BTF, clang's BPF target, libbpf headers/library, and
Zig 0.16.
