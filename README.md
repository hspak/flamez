# Flamez

Flamez is a live process-lifetime and CPU-activity flamegraph for builds and
other commands. It spawns a command in its own process group, follows
descendants, and keeps every process anchored to the wall-clock interval in
which it ran. Red slices show where each process's threads consumed CPU.

The current vertical slice includes:

- argv-preserving target launch and whole-process-group cancellation;
- live elapsed/process/active counters;
- a scrollable, hoverable process tree with normalized lifetime bars and red
  self-CPU slices whose height scales to host CPU capacity, including CPU time
  and average-core metadata;
- a selected-process detail pane with a full-lifetime thread CPU graph, an
  independent session-time axis, and the existing process metadata below it;
- Linux `sched_process_fork`, `sched_process_exec`, and
  `sched_process_exit` eBPF raw tracepoints delivered through a ring buffer,
  plus map-based `sched_switch` CPU accounting;
- responsive Clay layout rendered with raylib.

## Build and run

The project currently targets Zig 0.16.

An optional green FPS counter can be compiled into the footer beside **FLAMEZ** with:

```sh
zig build -Dfps-counter=true
```

Build with `zig build`, then install the executable and BPF object with the
narrow capabilities required for tracing:

```sh
./build.sh
/usr/local/bin/flamez <target> [target args...]
```

To install a ReleaseSafe build with the counter enabled, pass the option
through the installer:

```sh
./build.sh -Dfps-counter=true
```

For example:

```sh
/usr/local/bin/flamez zig build -Doptimize=ReleaseFast
/usr/local/bin/flamez make -j8 all
```

Flamez opens the GUI and immediately launches the target with the remaining
arguments unchanged—there is no intermediate shell and no command-entry UI.
Press **Stop** to terminate the target process group. F5 toggles Clay's layout
inspector. Use the arrow button in the timeline header to collapse or expand
every row, or the matching button in the left gutter to toggle one row. For
packed rows, the one button toggles the children of every top-level process
block on that row, reducing a collapsed row to one block in height. Capture
ends when the target process exits; descendants that outlive it do not extend
the trace.

Timeline zoom shortcuts mirror Ctrl+mouse-wheel zoom: **Ctrl+=** zooms in,
**Ctrl+-** zooms out, and **Ctrl+0** restores the full default view.

On Linux v7 or newer, the build always enables the eBPF collector and needs `clang`,
libbpf headers, and libbpf at link time. Capture is mandatory: if the BPF
object cannot be loaded and attached, flamez prints the reason and exits.

The installed `/usr/local/bin/flamez` has the capabilities; the development
artifact at `./zig-out/bin/flamez` does not. Rebuilding also replaces the
development artifact, so do not use it when testing the eBPF backend.

## eBPF permissions

The load/attach path, capabilities, sysctls, and the Linux 7.x attach
`EACCES` that is **not** a permission miss are documented in
[EBPF.md](EBPF.md). Read that before changing `setcap` or the BPF
programs.

Loading tracing programs requires root or appropriate BPF/perf capabilities.
There is no fallback backend: flamez checks capabilities at startup and, when
the kernel forbids it from attaching, prints exactly why and exits non-zero.

The installed binary needs two file capabilities during initialization:

- `cap_bpf` + `cap_perfmon` — load and attach raw-tracepoint programs.

After the programs attach, Flamez clears all capability sets before spawning
the target or initializing raylib.
Raw tracepoints do not read tracefs event-ID files, so
`cap_dac_read_search` is neither needed nor granted.

If attach fails with `Permission denied` / `-EACCES` *after* the programs
have already loaded, check the BPF object layout before adding more
capabilities. The kernel reuses `EACCES` when a classic `tracepoint/`
program reads past the event's fixed fields (Linux 7.x changed
`sched_process_fork` comm from a 16-byte array to a dynamic `__string`).
Flamez attaches via `raw_tp` + CO-RE to avoid that.

If the BPF object is missing or rejected, reinstall via `./build.sh`, which
places a root-owned object under `<prefix>/share/flamez/`. A capable non-root
run will not load a user-owned object through `FLAMEZ_BPF_OBJECT`; allowing
that would let the caller choose code to run with Flamez's BPF privileges.

The dev artifact at `./zig-out/bin/flamez` has no file capabilities, so it
cannot capture; use the installed binary:

```sh
/usr/local/bin/flamez <target> [target args...]
```

Because every tracked process beyond the target root comes from kernel events,
even subprocesses that live for less than one frame are retained — there is no
sampling interval to miss them in. Forked children immediately inherit their
parent's cached argv, executable, and CWD. Successful exec events carry a
bounded filename and a complete variable-length argv snapshot from the kernel,
so short-lived programs do not depend on a later `/proc/<pid>` read for their
process-image metadata.

## Architecture

- `src/main.zig` owns interaction, the Clay layout, and the raylib timeline
  renderer.
- `src/tracer.zig` owns sessions, process records, spawning, eBPF ingestion,
  lifetime state, and bucketed CPU slices.
- `src/flamez.bpf.c` emits three scheduler lifecycle events and accounts
  process-exclusive CPU at scheduler switches without emitting per-switch
  records.
- `src/ebpf_shim.c` loads/attaches the BPF object, bridges libbpf's ring
  buffer and CPU-map snapshots into Zig, and reports initialization failures
  verbosely.

CPU slices answer which process was using cycles and when; they do not yet
identify hot functions or explain off-CPU delay. Stack sampling, symbolization,
wakeup/off-CPU accounting, zoom/pan, export, and explicit thread grouping are
natural follow-on layers; the event/data model is intentionally separate from
the UI so those can be added without rewriting capture sessions.

## Validation hooks

For automated visual checks, `FLAMEZ_SCREENSHOT` writes a screenshot after
roughly two-thirds of a second. Pass the target through the normal command-line
arguments. The screenshot path is interpreted by raylib relative to the
current working directory.
