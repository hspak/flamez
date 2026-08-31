# macOS process capture APIs

This document owns the macOS API-specific rationale, contracts, limitations,
validation evidence, and release gates. The cross-platform component layout,
collector contract, runtime selection, and data flow live in
[ARCHITECTURE.md](ARCHITECTURE.md).

Status: research and first implementation, 2026-08-30. The supported macOS
target is Apple silicon (`aarch64-macos`); Intel macOS is deliberately out of
scope. The host used for validation runs macOS 26.6.2 with the macOS 26.5 SDK.

## Conclusion

The best macOS lifecycle API is Endpoint Security (ES), specifically the new beta
`es_new_descendants_client`. It creates a client whose kernel-visible scope is the caller and its
complete existing and future descendant subtree. This exactly matches Flamez's launch model and,
unlike the older `es_new_client`, does not require root or Full Disk Access. It still requires the
restricted `com.apple.developer.endpoint-security.client` entitlement, must be code signed, and is
introduced in macOS 27. It is not declared by the installed macOS 26.5 SDK and is absent from the
macOS 26.6 runtime used for validation.

## 1. Endpoint Security

[Endpoint Security](https://developer.apple.com/documentation/endpointsecurity) is Apple's public C
API for security event notification and authorization. It has explicit fork, exec, and exit notify
events and is the only supported modern API considered here that provides the child identity in the
fork record rather than requiring discovery after the fact.

### Descendant-scoped client: preferred

The beta
[`es_new_descendants_client`](https://developer.apple.com/documentation/endpointsecurity/es_new_descendants_client%28_%3A_%3A%29)
has the right semantics for Flamez:

- the caller receives notify events for itself;
- auth and notify events are visible for the entire descendant subtree;
- descendants already alive at client creation and those forked later are included recursively;
- processes outside the subtree are invisible;
- it does not require root;
- it does not require Full Disk Access/TCC approval; and
- it does require the Endpoint Security client entitlement.

Flamez creates this client and subscribes before spawning the target. The C bridge retains events
until `trackRoot(pid)` identifies the target; Zig then admits only the root and fork records whose
parent `(pid, pidversion)` is already tracked. Other descendants of the Flamez process are
discarded. The shared macOS launch path also starts the target suspended and resumes it only after
root admission, so exact and fallback launches use the same ordering invariant.

Apple's beta documentation marks the function as introduced in macOS 27. It does not appear in the
local macOS 26.5 `EndpointSecurity/ESClient.h`. The bridge therefore uses the documented C signature
with existing public ES types but resolves every ES/libbsm function through `dlopen`/`dlsym`. This
keeps both the link graph and deployment binary compatible with macOS 26.

Apple's current DocC data was rechecked on 2026-08-30 and publishes the Objective-C/C declaration as
`es_new_client_result_t es_new_descendants_client(es_client_t **client,
es_handler_block_t handler)`. That exactly matches the bridge typedef. The C shim now also asks a
macOS 27-or-newer SDK to compare the compatibility typedef with
`typeof(&es_new_descendants_client)` at compile time; older SDKs continue to use the checked dynamic
declaration. Both C and Zig assert every cross-language event and process-identity field offset in
addition to total structure size, so padding drift cannot silently scramble a dynamically delivered
record.

### Event mapping

Subscribe only to notification events; Flamez does not need to authorize behavior:

- `ES_EVENT_TYPE_NOTIFY_FORK`: `message->process` is the parent and
  [`event.fork.child`](https://developer.apple.com/documentation/endpointsecurity/es_event_fork_t)
  is the new child. Use audit tokens, not a bare PID, for internal identity.
- `ES_EVENT_TYPE_NOTIFY_EXEC`: the message describes the pre-exec image while
  [`event.exec.target`](https://developer.apple.com/documentation/endpointsecurity/es_event_exec_t)
  describes the post-exec image. The target executable is an `es_file_t`; argv comes from
  `es_exec_arg_count`/`es_exec_arg`; message version 3 and later includes `cwd`. Copy every borrowed
  token before the handler returns.
- `ES_EVENT_TYPE_NOTIFY_EXIT`: `message->process` identifies the exiting process and
  [`event.exit.stat`](https://developer.apple.com/documentation/endpointsecurity/es_event_exit_t)
  uses wait-status encoding.

`es_process_t.audit_token` contains PID and PID version. The `(pid, pidversion)` tuple identifies a
specific process execution; exec increments the version. Version 4 messages also carry
`parent_audit_token`, which is preferable to a numeric PPID when relating events across PID reuse.

`es_message_t.mach_time` is the kernel event time. Convert it with `mach_timebase_info`; it shares
the awake/uptime clock domain Flamez uses on macOS: Zig's `.awake` clock maps to
`CLOCK_UPTIME_RAW`, Apple's nanosecond equivalent of `mach_absolute_time`. Message version 4 and
later provides
[`global_seq_num`](https://developer.apple.com/documentation/endpointsecurity/es_message_t/global_seq_num),
whose gaps report client-side kernel drops. The bridge adds each gap to `Collector.lost_events`, so
Session marks the capture incomplete just as it does for the eBPF loss counter.

Event creation is synchronous with the originating operation, but ES handler delivery is
asynchronous. After `waitpid` observes the root exit, Flamez calls
[`es_sync_client`](https://developer.apple.com/documentation/endpointsecurity/es_sync_client%28_%3A_%3A%29)
to place a marker behind all messages already enqueued for the client. The marker callback runs only
after those messages have passed through the serial ES handler. Flamez then drains its copied-event
queue and forces one last cumulative CPU snapshot before closing surviving descendant intervals.
This prevents root exit, final CPU, or last-moment descendant records from being stranded between
the normal frame poll and root reap. When the root exit record is present, its kernel/observation
timestamp becomes the session boundary; the final descendant CPU samples and clipped lifetimes are
clamped to it rather than extending to the later userspace reap.

Apple's current contract explicitly says the marker block runs after every message ahead of it has
been handled, forces the current handler batch to run to the marker, and is invoked even if the
client is destroyed. It also forbids calling the function from that client's handler block. Flamez
calls it only from the Session/main thread and waits on a condition variable, while ES callbacks run
on the framework-managed serial queue, so the bridge does not violate that reentrancy constraint.

### Entitlement and packaging

The
[`com.apple.developer.endpoint-security.client`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.endpoint-security.client)
entitlement must be requested from Apple. Without it, client creation returns
`ES_NEW_CLIENT_RESULT_ERR_NOT_ENTITLED`. This is a distribution gate, not something root or an
ad-hoc signature can bypass.

`macos.entitlements` contains the single restricted entitlement expected by the executable. It is a
signing input, not an entitlement grant: the signing identity/provisioning profile must already be
approved by Apple. For live validation, build fail-closed so a missing symbol, signature, or grant
cannot be mistaken for a successful test:

```sh
zig build -Dtarget=aarch64-macos -Dmacos-require-endpoint-security=true
codesign --force --options runtime \
  --entitlements macos.entitlements \
  --sign "<Apple-approved signing identity>" \
  zig-out/bin/flamez
codesign --display --entitlements - zig-out/bin/flamez
zig-out/bin/flamez /usr/bin/true
```

In required mode, `armLaunch` returns `ExactCaptureUnavailable` and the UI presents the bridge's
specific diagnostic instead of selecting kqueue. The same build on the current macOS 26 host
therefore fails intentionally with the macOS 27 requirement. Automatic mode remains the production
default and keeps the deployable fallback.

The older stable `es_new_client` also requires that entitlement, and its normal deployment requires
root plus user-approved Full Disk Access. It observes system-wide activity, leaving Flamez to filter
descendants and handle initialization races. Apple's
[Endpoint Security sample](https://developer.apple.com/documentation/endpointsecurity/monitoring-system-events-with-endpoint-security)
documents the system-extension, signing, entitlement, and approval workflow. Because the new
descendant client removes the two operational requirements and narrows kernel delivery correctly,
Flamez should not invest in the older system-wide client unless the beta API changes or disappears.

### ES implementation shape

Endpoint Security invokes a block on a serial framework-managed queue. `src/macos_es_shim.c` owns
the client and copies all needed fields into Flamez-owned records during the callback because ES
messages are borrowed only for that callback. Its mutex-protected queue has one framework producer
and one GUI-thread consumer. A 16 MiB byte budget matches the Linux ring-buffer bound; allocation or
budget failure increments `lost_events`.

The implemented bridge preserves the shared Zig `capture.Sink` contract:

1. Initialize the descendant client and subscribe before target spawn.
2. Copy fork/exec/exit records, including complete argv and paths, in the ES callback.
3. Preserve `mach_time`, audit-token PID generation, and sequence gaps.
4. Drain copied records from `pollEvents()` on the GUI thread.
5. Place an `es_sync_client` marker and perform a final drain after root reap.
6. Continue calling `proc_pid_rusage` from `snapshotCpu()` at the shared 16 ms cadence and once at
   the root capture boundary.
7. Prefer ES at runtime when macOS provides the symbols and the signed binary has the entitlement;
   retain kqueue/libproc as an explicitly best-effort fallback for older, local, and unsigned builds.

## 2. kqueue process filter

`EVFILT_PROC` is a public BSD API. Register the PID as `ident` and request `NOTE_FORK`, `NOTE_EXEC`,
and `NOTE_EXIT`. A returned event identifies the watched process and coalesces the applicable flags.
`NOTE_EXITSTATUS` is useful only where the caller is allowed to obtain status; Flamez already uses
`waitpid(WNOHANG)` for its direct root.

There are two load-bearing limitations in Apple's current
[`sys/event.h`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/event.h):

- the internal fork hint contains the child PID, but that PID is deliberately not copied into the
  userspace kevent; and
- `NOTE_TRACK`, `NOTE_TRACKERR`, and `NOTE_CHILD` are explicitly unsupported since macOS 10.5.

Therefore a fork hint can only prompt a separate child enumeration. Multiple transitions may
coalesce, kqueue records have no occurrence timestamp, and a dead child cannot be inspected. It is
excellent as a wakeup/exit mechanism but cannot by itself provide eBPF-level lifecycle fidelity.

The fallback previously had an avoidable race between returning from `spawn` and registering the
root kqueue filter. Flamez now calls Darwin `posix_spawnp` with `POSIX_SPAWN_SETPGROUP` and
`POSIX_SPAWN_START_SUSPENDED`. The kernel creates the new process-group leader but does not let
target code run. Session establishes the root record, registers kqueue, starts the recovery worker,
and only then sends `SIGCONT`. This does not make snapshot discovery exact for later children, but
it prevents an immediate root child from escaping before capture exists. A regression launches an
immediate `exit 37`, checks its nonblocking wait status while suspended, resumes it, and verifies
that exit status.

The implemented collector registers each discovered process independently. `udata` carries a local
generation number so a delayed kevent cannot close a reused numeric PID. A dedicated worker scans
all tracked parents whenever kqueue wakes it and after a 4 ms timeout, rather than relying solely on
`NOTE_FORK` or the GUI frame cadence. Newly admitted children are scanned immediately,
breadth-first. The worker scans once before consuming exit hints so the shared Session still has a
live root under which to place a recovered process.

During a fork burst, registration is deliberately separated from enrichment: the worker verifies
identity, installs every live child's kqueue filter, and queues its fork record before performing
the slower argv/path/CWD calls. It drains up to eight additional kqueue batches with a 250 us quiet
window and coalesces their fork hints. At that quiet point—or after the eighth busy batch—it runs
one expensive all-PID immutable-parent scan for escaped children. This prioritizes direct lifecycle
admission and exec metadata without delaying the recovery path for a child that already called
`setsid()` beyond the bounded drain.

The worker copies names, argv, executable paths, and CWD into allocator-owned pending records while
the process is still inspectable. `pollEvents()` only swaps queues under a mutex and invokes the
shared Session callbacks on the GUI thread. CPU inspection similarly snapshots PID identity and
generation under the mutex, performs the potentially slower `proc_pid_rusage` calls without holding
it, then verifies identity again before publishing a sample. Consequently no Session or UI state is
mutated from the worker.

The fallback pending queue now has the same 16 MiB payload budget as the Linux BPF ring and the
exact ES bridge. Accounting includes each fixed pending record and the allocation capacity of owned
argv bytes. A record that would cross the budget is destroyed immediately and increments
`lost_events`; the Session therefore displays an incomplete capture instead of allowing an idle GUI
or extreme fork burst to grow memory without bound. Queue bytes move atomically with the
pending/delivery list swap and return to zero after the GUI thread drains the batch.

The 4 ms timeout is a recovery cadence, not a real-time guarantee: scheduler stalls can make an
individual interval longer. Tests therefore do not encode a child-duration floor. The concurrent
burst fixture forks 32 children whose lifetimes are held by a signal gate, waits until all 32 have
been admitted, then releases them together and verifies their exit records. This covers PID-buffer
growth, larger snapshots, clustered exits, and attribution without making correctness depend on
wall-clock delays.

Exploratory fork-only probes, which are deliberately not part of the test suite, demonstrated the
fallback boundary: one run observed 17 of 20 children requested to live for 500 us, while another
observed 15 of 20 at 750 us. Every observed process retained the correct immutable parent and exit,
but a fully vanished child leaves no kernel payload from which fallback can recover its PID. The
non-monotonic counts are why the backend remains `.snapshot_recovery` and why duration-based
completeness assertions were removed.

## 3. Private libproc process inspection

The SDK ships `<libproc.h>` and the symbols in `/usr/lib/libproc.dylib`, but Apple's own
[`libproc.h`](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.h)
labels these as private interfaces subject to change. They are isolated in `src/macos_shim.c` so
private structure layouts do not leak into the shared Zig model.

### Descendant enumeration

`proc_listchildpids(ppid, buffer, buffer_bytes)` returns direct children. Its API has a non-obvious
contract visible in Apple's
[`libproc.c`](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c):
the size argument is bytes but the return value is a count of PIDs, including for the null-buffer
sizing call. The integration test caught and now guards this distinction.

The sizing and fill calls are separate snapshots, so process creation between them can fill the
entire allocation and make truncation indistinguishable from an exact fit. Flamez adds 16 PID slots
to the sizing result, treats a fill that returns the full capacity as potentially truncated, and
doubles the allocation for at most four fill attempts. This policy applies uniformly to all-PID,
direct-child, and process-group enumeration. A persistently full result is never consumed: the
worker records `lost_events` and retries discovery on a later pass. Injected list providers test
both growth and the bounded-loss path without timing, while a live smoke test verifies that an
all-PID snapshot includes Flamez's own process.

Because Session creates the target as the leader of a new process group, the fallback also calls
`proc_listpgrppids(root_pgid, ...)` after recursive PPID discovery. This recovers a live process that
was reparented to launchd after an unobserved intermediate parent exited, provided it did not leave
the target group. If its real parent is no longer tracked, the collector emits exec without an
invented fork edge; Session anchors the process under the root as `.recovered_exec` and marks the
capture incomplete. Directly observed parentage remains `.observed`.

Enumeration is permission-light for Flamez's own children, but it is still a snapshot. Recursive
PPID scans recover live descendants with a tracked parent; the process-group scan recovers live
survivors whose parent is already gone. The backend cannot know that a fully terminated branch ever
existed. Its `lost_events` counter covers observed allocation, registration, and queue failures; it
cannot count processes it never saw.

Once a PID is admitted, its individual kqueue registration and recursive child scans no longer
depend on process-group membership. A live fixture verifies this by admitting a Python child that
calls `setsid()`, allowing the root shell to exit, and confirming that the escaped child remains
represented and capture-clipped at the root boundary.

### Immutable parent identity and fork-hint recovery

The private `PROC_PIDT_BSDINFOWITHUNIQID` flavor returns `proc_bsdinfo` together with
`proc_uniqidentifierinfo`. Apple's current
[`proc_info_private.h`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info_private.h#L41-L56)
defines three fields that are stronger than numeric PPID plus start time:

- `p_uniqueid` is unique to one process lifetime and remains unchanged across exec;
- `p_puniqueid` is the original parent's unique ID; and
- `p_orig_ppidversion` is the original parent's PID version.

XNU's internal
[`struct proc`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_internal.h#L2388-L2415)
explicitly documents that `p_puniqueid` is assigned at fork/spawn and does not change on reparent.
An Apple-silicon runtime probe confirmed the useful case: after a root forked a child, the child
called `setsid()`, the root exited, and the child was reparented, the child's `p_puniqueid` still
equaled the root's `p_uniqueid`.

Flamez now reads the combined record in one shim call and uses unique ID plus start time as fallback
PID-generation identity. `p_idversion` is retained but is not part of lifetime equality because the
native suite demonstrated that it advances across exec; `p_uniqueid` deliberately remains stable.

When kqueue reports `NOTE_FORK` for a tracked PID, the worker performs one `proc_listallpids` scan
in addition to its cheap PPID/process-group scans. It admits only a candidate whose immutable
`p_puniqueid` equals a currently tracked `p_uniqueid`, then repeats over the same snapshot so a
still-live multi-generation chain can be connected. The system-wide scan is event-triggered, not a
4 ms polling loop, and the unique parent edge prevents unrelated same-terminal processes from being
adopted. This recovers a direct child that calls `setsid()` and reparents before ordinary discovery.

The remaining boundary is a daemon that double-forks so quickly that the intermediate process has
both escaped and vanished before Flamez ever reads its unique ID. The surviving daemon names that
missing intermediate—not the root—as `p_puniqueid`, so there is no verifiable chain to follow.

### Rejected recovery scopes: responsibility, originators, and coalitions

Three private interfaces look like possible ways to rediscover a process after it has left both
the recorded PPID tree and root process group. None provides a trace-root-scoped identity:

- `responsibility_get_pid_responsible_for_pid(pid)` is an undocumented libSystem SPI. A runtime
  `dlsym` probe on the validation host found the symbol, but the Flamez test process, an ordinary
  child, and a double-forked child after `setsid()` all resolved to PID 802 (`ghostty`). That is the
  responsible application for the whole terminal activity domain, not the launched trace root.
  Scanning all PIDs for that value would silently adopt unrelated shells, builds, and tools running
  in the same terminal application. Flamez therefore does not use it.
- `proc_pidoriginatorinfo(PROC_PIDORIGINATOR_PID_UUID, ...)` reports the current thread voucher's
  originator, not process ancestry. Apple's
  [`libproc.c`](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c#L105-L115)
  always passes `getpid()`, while XNU's
  [`proc_pidoriginatorinfo`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/proc_info.c#L1532-L1610)
  rejects other PIDs. The kernel source also warns that the voucher-originator PID may already be
  invalid or recycled. The command-line validation process returned no originator record, and the
  interface cannot classify arbitrary candidate PIDs in any case.
- Private `proc_pidinfo(..., PROC_PIDCOALITIONINFO, ...)` returned the same resource and jetsam
  coalition IDs for Ghostty, its Codex child, and the fork/daemon probes. `setsid()` does not create
  a new coalition. XNU's
  [`proc_listcoalitions`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/proc_info.c#L1612-L1673)
  enumerates system coalitions; it does not turn one into a Flamez-owned descendant scope.

The safe fallback scopes are recursive live PPID edges, the dedicated root process group, immutable
parent unique-ID edges, and per-PID kqueue registrations established after admission. A
deterministic regression stops the recovery worker while the suspended root is still childless,
resumes a target that double-forks, calls `setsid()`, and reparents before the next scan, then
verifies the daemon is not adopted after its unobserved intermediate has vanished. This records the
remaining false-negative boundary rather than replacing it with false-positive attribution.
Descendant-scoped Endpoint Security is the API that closes it.

### PID identity and names

`proc_pidinfo(PROC_PIDT_BSDINFOWITHUNIQID)` provides current PPID, process start `timeval`, immutable
unique ID, original-parent unique ID, and PID versions together. The collector combines unique ID
and start time with its own monotonically increasing kqueue generation. A numeric PID with a
different unique ID or start time first closes the stale record, then begins a new lifetime.

`proc_name` provides the display name. Both calls may fail normally if the process exits during
inspection.

### Executable, argv, and CWD

- `proc_pidpath` returns the executable path. It requires a
  `PROC_PIDPATHINFO_MAXSIZE` scratch buffer even though Flamez stores only `max_path_len` bytes. The
  C shim uses the required scratch size and then copies a bounded prefix.
- `sysctl({ CTL_KERN, KERN_PROCARGS2, pid }, ...)` returns a private raw process-argument block:
  native `int argc`, executable path, NUL padding, then `argc` NUL-terminated arguments. The Zig
  parser preserves empty arguments after argv[0] and stores a NUL-separated list matching Linux's
  internal format.
- `proc_pidinfo(PROC_PIDVNODEPATHINFO)` returns `pvi_cdir.vip_path` for the current working
  directory.

All three are best effort. Permission changes, set-ID exec, sandboxing, and exit races can make a
field unavailable. Values captured by ES at exec are preferable because they are part of the event
and do not race subsequent chdir or process exit.

The fallback brackets the separate name, executable, argv, and CWD reads with two combined
`PROC_PIDT_BSDINFOWITHUNIQID` identity reads. It accepts the snapshot only when unique ID and start
time still identify the same process lifetime and `p_idversion` still identifies the same exec
image. If either check changes, Flamez frees the partial snapshot and retries on a later worker
pass. This prevents one event from mixing metadata across exec or PID reuse. A process can still
call `chdir` between the CWD read and the second identity check, so fallback CWD remains a
best-effort observation rather than event-time state.

The kqueue generation authenticates a `NOTE_EXEC` independently of those inspection calls. If the
bracket cannot be read—for example after a set-ID or sandboxed exec—the collector still emits an
exec observation with unavailable name/argv/executable metadata and keeps retrying enrichment.
Session clears inherited argv and executable state for that observation, retains CWD only with its
existing inherited provenance, and does not perform a second unbracketed live-PID lookup. This
preserves the known lifecycle transition without risking metadata from a reused PID or newer image.

Shebang execution demonstrates why executable identity and argv remain separate. On the validation
host, launching an executable `#!/bin/sh` script produces `/bin/bash` from `proc_pidpath`, `bash`
from `proc_name`, and argv beginning with `/bin/sh`, followed by the script path and caller
arguments. `KERN_PROCARGS2` also preserves an empty argument in that sequence. Flamez stores those
observations without rewriting them: the executable identifies the image actually running while
argv retains the interpreter spelling, script identity, and invocation arguments.

Flamez labels these fields `.process_inspection`, distinct from Linux `.procfs`, event-time
`.kernel`, inherited, and launch metadata.

## 4. CPU accounting

`proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, ...)` is the best practical per-process CPU source. The
SDK documents that it accepts a live process or zombie, which permits a final read after
`NOTE_EXIT` and before the process is reaped. `RUSAGE_INFO_CURRENT` currently selects v6.

That final lookup can still lose a race when a descendant's parent reaps it before the asynchronous
ES handler or kqueue worker performs the read. Exit records therefore carry an explicit
`cpu_final` bit. On success, Flamez passes the raw final total to `recordFinalCpuSnapshot`, allowing
it to correct bounded overestimate from the latest periodic sample. On failure, it preserves the
largest periodic total without treating it as final; the process still has an observed lifetime
exit, but the UI labels its CPU as partial (`CPU~`).

The `ri_user_time` and `ri_system_time` values are cumulative Mach absolute-time units, not values
that may be relabeled as nanoseconds. XNU's
[`fill_task_rusage`](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c)
fills them from task recount time, in the same clock units used by `mach_absolute_time`. Flamez first
adds the two raw counters with saturation and then uses
[`mach_timebase_info`](https://developer.apple.com/documentation/kernel/1462446-mach_timebase_info)
to scale the total into nanoseconds with a 128-bit intermediate. One project-owned conversion API
initializes that timebase once through `pthread_once`; both `proc_pid_rusage` totals and ES
`mach_time` fields use it, avoiding a timebase query in every event callback and PID sample. This
distinction is load-bearing on Apple silicon: the validation host reports a 125/3 timebase, while
Intel's commonly observed 1:1 timebase can hide the bug. A four-thread regression fixture must
accumulate more CPU time than wall time and caught the original 41.7× undercount.

A live no-sleep calibration brackets a converted `mach_absolute_time()` read with
`CLOCK_UPTIME_RAW` reads and verifies that it lies inside the same interval, allowing only one
microsecond for integer-conversion rounding. This directly checks the clock-domain invariant used
when Session translates ES kernel timestamps into target-relative time on Apple silicon.

Periodic sampling timestamps each successful `proc_pid_rusage` result immediately after that PID's
read, before performing the second identity check. A single timestamp taken before iterating the
whole target set would project later cumulative totals backward to the beginning of a potentially
long fan-out scan and could overstate short CPU slices. Per-PID observation timestamps retain the
same awake-clock domain while bounding that skew to one process read. An injected provider test
proves the read → timestamp → identity-validation order for every delivered sample without using
wall-clock delays.

The result matches the Linux model:

- it includes every thread in the PID;
- it excludes descendant CPU;
- cumulative snapshots tolerate delayed UI frames; and
- the delta divided by wall time can exceed one core for parallel threads.

XNU's [Recount observability document](https://github.com/apple-oss-distributions/xnu/blob/main/doc/observability/recount.md)
lists `proc_pid_rusage` and `PROC_PIDTASKINFO` as the PID-targeted task accounting interfaces. The
former is preferred because its header explicitly permits zombies and its current flavor remains
forward-extensible.

There is no equally capable unrestricted public replacement. `task_info` needs a Mach task port;
`task_for_pid` is constrained by code-signing and SIP even for debuggers, as described by Apple's
[`com.apple.security.cs.debugger`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.debugger)
documentation. `getrusage(RUSAGE_CHILDREN)` is aggregate and only applies to waited-for direct
children, so it cannot attribute a recursive tree to individual lifetime bars.

## 5. APIs considered but not selected

### Stable system-wide Endpoint Security client

Lifecycle quality is high, but it adds root, Full Disk Access, system-extension packaging, and
system-wide filtering while retaining the same restricted entitlement. The descendant-scoped API
is a materially better fit for a new implementation.

### DTrace `proc`/scheduler providers

DTrace can observe lifecycle and scheduling, but modern macOS privilege/SIP policy and its
system-wide tracing model make it unsuitable as an embedded, normally launched GUI backend. It
would also introduce a script/compiler/consumer control plane and another privileged tracing
resource. It remains useful for development-time validation.

### kdebug, ktrace, kperf, and stackshot

These private facilities power Apple performance tooling and can expose scheduler-level detail.
They are global or privileged resources, have private and changing control ABIs, may conflict with
Instruments or other tracers, and require capabilities unavailable to an ordinary distributable
binary. They are disproportionate for cumulative CPU time already exposed by `proc_pid_rusage`.

### Mach task ports

Per-task and per-thread `task_info` calls are public once a task port exists, but obtaining another
process's port is intentionally restricted. Flamez must also handle platform binaries and arbitrary
descendant code-signing states, so debugger-style attachment is not a sound foundation.

### OpenBSM audit

Audit can record selected exec activity but does not provide a low-latency, self-contained
fork/exec/exit plus CPU stream. It also depends on global audit configuration and is not scoped to
one launched tree.

## 6. Completion audit and external validation gates

The in-repository implementation has evidence for every Linux-facing collector responsibility:

| Requirement | Authoritative evidence | Status |
|---|---|---|
| Apple-silicon-only build | both test roots and the application compile for `aarch64-macos`; the installed artifact is Mach-O arm64 | verified |
| API selection and limitations | sections 1–5 cite Apple documentation and current XNU/libproc source | verified |
| fallback fork/exec/exit and metadata | live Session fixtures cover descendants, shebang argv, empty arguments, immediate exits, process-group escape, and immutable-parent recovery | verified on macOS 26 |
| fallback launch and final-drain races | suspended-launch, restart, 24 immediate-exit, and root-boundary fixtures | verified on macOS 26 |
| CPU totals and time domain | live parallel CPU test, per-PID timestamp ordering, 125/3 conversion, and awake-clock calibration | verified on Apple silicon |
| fallback loss and PID-list bounds | injected queue overflow plus growing and persistently full libproc snapshots | verified |
| exact event mapping and ownership | native SDK fork/exec/exit fixtures traverse the production extractor and owned queue | verified synthetically |
| exact PID generations and loss | Zig filtering tests plus C global-sequence fixtures | verified synthetically |
| exact root-exit drain | condition-gated asynchronous `es_sync_client` fixture | verified synthetically |
| genuine descendant-scoped kernel delivery | requires macOS 27 and an Apple-approved restricted entitlement | not verifiable on this host |

### In-repository validation details

Fallback collector tests cover worker restart, stale kqueue generations,
immutable-parent recovery, deliberate double-fork non-adoption, queue overflow,
bounded libproc list growth, and cumulative CPU sampling. Live Session fixtures
cover suspended root admission, same-PID root exec, a signal-gated 32-child
burst, immediate exits, restart after forced Stop, shebang metadata including an
empty argument, and both admitted and pre-discovery `setsid()` children.
Fallback-specific fixtures disable Endpoint Security explicitly so an entitled
macOS 27 host cannot silently stop exercising snapshot recovery.

The Endpoint Security bridge exposes test-only helpers under `FLAMEZ_TEST`.
They enqueue project-owned event fields through the production allocation,
byte-budget, FIFO, polling, and sequence-gap paths without creating an ES
client. SDK-native `es_message_t`, `es_process_t`, and `es_file_t` fixtures also
traverse the production fork/exec/exit extractor. These tests verify audit-token
versions, parentage, complete argv, path truncation, Mach timestamps, final CPU,
deep-copy ownership, and exact loss accounting; the helpers are absent from the
application build.

A separate condition-gated harness replaces `es_sync_client` with an
asynchronous marker. It proves the production root-exit waiter does not return
before the marker completes and propagates marker rejection. This validates the
barrier control path without assuming callback timing or requiring the
restricted entitlement.

The validation host is arm64 macOS 26.6.2 with the macOS 26.5 SDK. A direct dynamic-symbol probe
finds stable `es_sync_client` but not `es_new_descendants_client`, matching Apple's macOS 27
availability declaration. The entitlement cannot manufacture that missing runtime API, and the
restricted entitlement itself must be granted by Apple. Consequently no additional repository
change can prove genuine exact delivery on this machine.

The remaining work requires the released OS, released SDK, and an entitled signing identity. The
release-day procedure and the exact repository changes to make are specified in section 7.

Synthetic coverage already verifies that a generation-authenticated exec survives unavailable
inspection without retaining inherited argv/executable metadata. Scripts/interpreters,
post-admission `setsid()`, immutable-parent recovery, and the deliberate non-adoption boundary after
an unseen intermediate vanishes have live fallback coverage. Planned session export should retain
`capture_fidelity`, but export does not exist on Linux either and is not a macOS parity blocker.

The private inspection calls are intentionally behind one shim and are replaceable field by field.
The shared `Session`, process tree, CPU-slice model, teardown, and UI require no ES-specific changes.

## 7. macOS 27 GA pickup plan

This section is the release-day runbook. Do not change the audit row above to “verified live” merely
because macOS reports version 27 or an SDK compiles the project. Genuine exact capture is accepted
only after a released runtime delivers real descendant events to a production-mode, entitled
binary.

The permanent product choices remain:

- Apple silicon only: every macOS build and validation command uses `aarch64-macos`.
- Keep the dynamic `dlopen`/`dlsym` boundary while macOS 26 remains supported. Compiling against an
  SDK 27 declaration does not justify adding a load-time dependency on a macOS 27-only symbol.
- Keep automatic mode and the kqueue/libproc fallback for unsigned local builds and older systems.
- Use required mode for exact-path validation so a fallback can never look like a passing ES run.
- Do not replace the descendant client with system-wide `es_new_client` unless Apple removes or
  materially weakens `es_new_descendants_client` at GA.

### 7.1 Release gates

All of these must be true before starting the GA patch:

1. Apple has shipped a non-beta macOS 27 build for Apple silicon.
2. A non-beta Xcode or Command Line Tools release contains a macOS 27 SDK whose public
   `EndpointSecurity/ESClient.h` declares `es_new_descendants_client`.
3. `/usr/lib/libEndpointSecurity.dylib` on the test machine exports the symbol through the dyld
   shared cache. A missing physical dylib file is normal and is not evidence that the API is absent.
4. The Flamez signing team has received Apple's restricted
   `com.apple.developer.endpoint-security.client` entitlement. The checked-in plist alone is not a
   grant.
5. The test identity, provisioning requirements if Apple imposes them, and designated requirement
   all apply to the exact executable being launched. An ad-hoc signature is insufficient.

Record the release inputs before editing code:

```sh
sw_vers
uname -m
xcodebuild -version
xcrun --sdk macosx --show-sdk-version
xcrun --sdk macosx --show-sdk-path
```

The expected architecture is `arm64`, and both the runtime and SDK must report 27 or newer. Preserve
the full macOS build number and Xcode build number in the validation record because ES behavior can
change in servicing releases without changing the major version.

### 7.2 Update the pinned SDK before evaluating the ABI

`build.zig` gets Apple framework headers and stubs from the lazy `xcode_frameworks` dependency, not
from the SDK printed by `xcrun`. Therefore installing Xcode 27 is not sufficient. Replace the
`xcode_frameworks` URL and hash in `build.zig.zon` with a package generated from the released macOS
27 SDK. Do not vendor a beta SDK under a release-looking hash.

Verify both the system SDK and the newly pinned package contain the declaration:

```sh
rg -n "es_new_descendants_client" \
  "$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/EndpointSecurity.framework/Headers"
rg -n "es_new_descendants_client" zig-pkg \
  -g 'ESClient.h' -g 'EndpointSecurity.h'
```

Then compile both policies with the pinned headers:

```sh
~/zig/zig build test-compile -Dtarget=aarch64-macos --summary all
~/zig/zig build test-compile -Dtarget=aarch64-macos \
  -Dmacos-require-endpoint-security=true --summary all
~/zig/zig build -Dtarget=aarch64-macos \
  -Dmacos-require-endpoint-security=true --summary all
file zig-out/bin/flamez
```

The existing SDK-version guard in `src/macos_es_shim.c` makes the compiler compare the local
function-pointer type with `typeof(&es_new_descendants_client)` when
`__MAC_OS_X_VERSION_MAX_ALLOWED >= 270000`. Treat a failure as an Apple ABI change to investigate;
do not delete or weaken that assertion. Also retain the C and Zig size/offset assertions for every
bridge structure.

Compare the released header and documentation against every assumption below:

- exact function name, return type, parameters, and block signature;
- availability version and supported architectures;
- caller plus existing-and-future descendant scope;
- whether notify-only clients still avoid root and Full Disk Access;
- entitlement, signing, provisioning, user-approval, and distribution requirements;
- callback serialization and message ownership;
- `es_sync_client` ordering and handler-reentrancy rules;
- minimum message versions for `cwd`, `parent_audit_token`, and `global_seq_num`; and
- whether fork, exec, or exit structures gained a newer authoritative identity or timestamp field.

If the released contract matches, no event-path rewrite is needed. Update the beta wording and SDK
version recorded in this document, but retain dynamic lookup. If it differs, update the compatibility
typedef, `flamez_capture_message`, the SDK-native synthetic fixtures, and this document in one
change. Never reinterpret a changed field by layout coincidence.

Once SDK 27 is the pinned build input, make the compatibility alias use Apple's declaration on new
SDKs while preserving the manual declaration for SDK 26 builds. The intended shape is:

```c
#if defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && \
    __MAC_OS_X_VERSION_MAX_ALLOWED >= 270000
typedef __typeof__(&es_new_descendants_client) flamez_new_descendants_client_fn;
#else
typedef es_new_client_result_t (*flamez_new_descendants_client_fn)(
    es_client_t **client,
    es_handler_block_t handler);
#endif
```

This is a source-level cleanup, not permission to call the symbol directly. The runtime lookup and
null check remain necessary for the macOS 26 fallback.

### 7.3 Sign and inspect the exact executable

Keep `macos.entitlements` minimal unless Apple's released documentation requires another key. Do
not add Full Disk Access, debugger, disable-library-validation, or root-only packaging as a
workaround. Sign the installed production executable rather than an unidentified file inside
`.zig-cache`:

```sh
~/zig/zig build -Dtarget=aarch64-macos \
  -Dmacos-require-endpoint-security=true --summary all
codesign --force --options runtime \
  --entitlements macos.entitlements \
  --sign "<Apple-approved signing identity>" \
  zig-out/bin/flamez
codesign --verify --strict --verbose=4 zig-out/bin/flamez
codesign --display --entitlements - zig-out/bin/flamez
codesign --display -r- zig-out/bin/flamez
file zig-out/bin/flamez
```

The displayed entitlements must contain the ES client key with a true value, and the Mach-O must be
arm64. Save the Team Identifier and designated requirement in the validation record, but do not
commit certificates, provisioning profiles, or other signing secrets.

Notarization and distribution packaging are separate release gates. They should be validated after
local exact delivery works so a packaging failure is not confused with an ES ABI or event-delivery
failure.

### 7.4 Add a production-mode live validator

The `FLAMEZ_TEST` bridge proves extraction and queue semantics but intentionally cannot prove kernel
delivery. For repeatable GA evidence, add a small installed `macos-es-live-test` executable and Zig
build step with these properties:

- it links `src/macos_es_shim.c` without `FLAMEZ_TEST`;
- it constructs the real macOS `Collector` in required mode and asserts `.exact` before spawning;
- it installs at a stable path under `zig-out/bin` so that exact artifact can be signed;
- it prints the selected fidelity, exact diagnostic, received event counts, loss count, and failed
  assertion before returning nonzero; and
- its fixtures use pipes, signals, `SIGSTOP`/`SIGCONT`, child waits, and monotonic deadlines with
  `std.Thread.yield()`—never `sleep`, `usleep`, `nanosleep`, or a timing delay.

Do not sign and run the ordinary unit-test artifact as the authoritative live check. Its
`FLAMEZ_TEST` surface and cache-dependent path make it a poor representation of the shipped binary.
The live validator may reuse Session fixture logic, but it must traverse the production ES client
creation and real framework callback.

The validator needs the following deterministic scenarios:

| Scenario | Required observation |
|---|---|
| activation | required mode selects `.exact`, the active diagnostic names descendant-scoped ES, and no fallback worker starts |
| scope isolation | an unrelated same-user process is absent while the launched root and its descendants are present |
| fork burst | all 32 signal-gated children have fork and exit records with the correct parent generation |
| short double fork | both generations are retained even when the intermediate exits before userspace polls |
| root exec | one root process record survives exec with an advanced PID version and kernel metadata |
| exec metadata | interpreter, script path, complete argv including an empty argument, executable, and CWD match the ES payload |
| immediate exits | 24 immediate root exits retain exit code, observed-exit kind, final boundary, and zero live records |
| final drain | a root exit followed by queued descendant activity is complete before the `es_sync_client` barrier returns |
| surviving descendant | the descendant is retained and clipped to the root capture boundary without a CPU slice past that boundary |
| restart | a forced stop followed immediately by another launch does not receive stale records from the first client |
| CPU accounting | a fixed-work parallel child has monotonic cumulative self CPU and a final or explicitly partial terminal sample |
| loss accounting | a controlled run reports zero loss; any `global_seq_num` gap or local allocation failure makes the run fail |

Every wait must be condition-driven. A monotonic deadline is only a failure bound, not a substitute
for readiness synchronization. Keep the existing fallback fixtures explicitly set to
`.endpoint_security = .disabled`; they must continue to exercise kqueue recovery on an entitled
macOS 27 machine.

### 7.5 Positive and negative live checks

Run the signed validator and application in required mode first. Acceptance requires all of the
following:

- the collector reports `.exact`;
- the active diagnostic is `using exact descendant-scoped Endpoint Security capture`;
- the application footer does not show `CAPTURE · BEST EFFORT`;
- every controlled fixture reports its exact expected process and event count;
- kernel exec metadata is tagged as `Process.MetadataSource.kernel`;
- no controlled run reports an ES sequence gap, queue rejection, or other lost event; and
- repeated immediate-exit and restart runs leave no live process record or ES client behind.

Also prove required mode fails closed. Sign a separate copy without the restricted entitlement, or
use an identity to which Apple has not granted it, and confirm launch returns
`ExactCaptureUnavailable` with the not-entitled diagnostic. Do not alter the accepted artifact for
this negative check. Repeat automatic mode on that copy and confirm it selects
`.snapshot_recovery`; this preserves the unsigned-development behavior.

Run the existing suites after the live validator:

```sh
~/zig/zig build test --summary all
~/zig/zig build test-compile -Dtarget=aarch64-macos --summary all
~/zig/zig build test-compile -Dtarget=aarch64-macos \
  -Dmacos-require-endpoint-security=true --summary all
git diff --check
```

### 7.6 Manual checks that must not become sleep-based tests

Two remaining checks are intentionally manual because automating them would be disruptive or would
weaken the assertion:

1. Execute a real set-ID transition and confirm the ES exec payload still supplies the new image's
   identity and metadata when subsequent `libproc` inspection is denied. The generation-authenticated
   exec must clear inherited metadata rather than attributing the old argv to the new image.
2. Suspend and resume the whole Apple-silicon machine during a capture. Confirm ES Mach timestamps,
   Zig's awake clock, Session duration, process boundaries, and CPU slices remain in one awake-time
   domain with no negative, wrapped, or post-boundary interval.

Do not add a fixed delay to make either check pass. Record the exact setup and result separately from
the automated suite.

### 7.7 Failure triage

| Symptom or diagnostic | First checks |
|---|---|
| descendant API unavailable | confirm the running OS is GA macOS 27+, probe the dyld-cached symbol, and verify the process is arm64 rather than running under translation |
| not entitled | inspect the entitlement on the final executable, Team Identifier, Apple grant, and any required provisioning profile |
| not permitted | check Apple's GA approval policy, device management policy, and whether the exact signed artifact is authorized; do not retry as root unless the released contract requires it |
| invalid argument | compare the GA declaration and callback ABI with the compatibility typedef; treat this as ABI drift |
| subscriptions rejected | verify the GA event constants and that descendant clients permit fork, exec, and exit notify subscriptions |
| too many clients | find leaked/stale validation processes and confirm every successful open reaches `es_delete_client` on the creator thread |
| events missing with sequence gaps | preserve the lost-event result, inspect the 16 MiB queue and callback allocation failures, and do not call the capture exact |
| events missing without gaps | audit root admission, `(pid, pidversion)` transitions, scope filtering, final synchronization, and fixture signaling |
| metadata differs | check the GA message version and truncation fields before considering a `libproc` fallback |

### 7.8 Evidence and completion record

Attach this matrix to the commit or release issue that enables live exact capture:

| Field | Value to record |
|---|---|
| macOS product/build | `sw_vers` output |
| machine | Apple-silicon model and `arm64` architecture |
| Xcode and SDK | released versions and build identifiers |
| pinned frameworks | new `build.zig.zon` URL and Zig package hash |
| ES declaration | released signature and availability annotation |
| runtime symbol | present/absent result from direct dynamic lookup |
| signing | Team Identifier, designated requirement, and displayed ES entitlement |
| required-mode activation | exact diagnostic and fidelity |
| automated validation | unit, compile-only, and production live-validator totals |
| manual validation | set-ID and suspend/resume results |
| event integrity | controlled-run loss count and short-double-fork result |

Only after every acceptance item passes should section 6 change genuine kernel delivery from “not
verifiable” to “verified live,” the document status move from research/first implementation to
validated macOS 27 support, and release notes claim Linux-equivalent lifecycle completeness. Keep
the fallback limitation language: snapshot recovery remains best effort even when the same binary
runs on macOS 27 without a usable entitlement.
