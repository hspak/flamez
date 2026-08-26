//! Process-tree capture subsystem: spawns the build target in its own process
//! group, ingests eBPF lifecycle events and CPU snapshots plus immediate /proc
//! metadata, and maintains process lifetimes and activity slices for the UI.
//! The UI talks only to this file, never to the children directly.

const process_mod = @import("tracer/Process.zig");
const ebpf_mod = @import("tracer/ebpf.zig");
const signals = @import("tracer/signals.zig");

/// Spawn orchestration and the process timeline.
pub const Session = @import("tracer/Session.zig");
/// One captured process record.
pub const Process = process_mod;
/// How a record's display name was derived (kernel comm vs. fallback label).
pub const NameKind = process_mod.NameKind;

pub const max_name_len = process_mod.max_name_len;
pub const max_path_len = process_mod.max_path_len;

/// eBPF event collector; inert when unsupported — see `available()`.
pub const EbpfCollector = ebpf_mod.Collector;

pub const installFatalSignalHandlers = signals.installFatalSignalHandlers;

test {
    _ = @import("tracer/signals.zig");
    _ = @import("tracer/Process.zig");
    _ = @import("tracer/Session.zig");
    _ = @import("tracer/ebpf.zig");
}
