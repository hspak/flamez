//! Process-tree capture subsystem: spawns the target in its own process group,
//! ingests backend-neutral lifecycle events and CPU snapshots, and maintains
//! process lifetimes and activity slices for the UI.

const process_mod = @import("tracer/Process.zig");
const capture = @import("tracer/capture.zig");
const signals = @import("tracer/signals.zig");

/// Spawn orchestration and the process timeline.
pub const Session = @import("tracer/Session.zig");
/// One captured process record.
pub const Process = process_mod;
/// How a record's display name was derived (kernel comm vs. fallback label).
pub const NameKind = process_mod.NameKind;
/// How a process record entered the session (observed vs recovered).
pub const Origin = process_mod.Origin;
/// How a lifetime ended (observed exit vs capture boundary).
pub const EndKind = process_mod.EndKind;

pub const max_name_len = process_mod.max_name_len;
pub const max_path_len = process_mod.max_path_len;
pub const cpu_sample_period_ns = Session.cpu_sample_period_ns;

/// Process-event collector selected for the target operating system.
pub const Collector = capture.Collector;
/// Compile-time capture backend selected for the target operating system.
pub const capture_backend = capture.backend;
/// Lifecycle fidelity shown before the collector arms its first launch.
pub const default_capture_fidelity = capture.default_fidelity;

pub const installFatalSignalHandlers = signals.installFatalSignalHandlers;

test {
    _ = @import("tracer/signals.zig");
    _ = @import("tracer/Process.zig");
    _ = @import("tracer/Session.zig");
    _ = @import("tracer/capture.zig");
    _ = @import("tracer/process_ops.zig");
}
