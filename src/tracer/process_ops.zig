//! Compile-time-selected process lifecycle, metadata, and signal operations.

const builtin = @import("builtin");

const implementation = switch (builtin.os.tag) {
    .linux => @import("process_ops/linux.zig"),
    .macos => @import("process_ops/macos.zig"),
    else => @compileError("process operations are implemented only for Linux and macOS"),
};

/// Result of a nonblocking root-process wait.
pub const WaitNowait = implementation.WaitNowait;
/// Failure to resume a target after capture has been armed around its PID.
pub const ResumeError = implementation.ResumeError;
/// Target stdout destination selected at spawn time.
pub const TargetStdout = implementation.TargetStdout;
/// Process spawn behavior independent of capture backend selection.
pub const SpawnOptions = implementation.SpawnOptions;
/// Spawns the target in a dedicated process group. macOS returns it suspended.
pub const spawnTarget = implementation.spawnTarget;
/// Lets a platform-suspended target begin executing after root registration.
pub const resumeTarget = implementation.resumeTarget;
/// Returns the calling process's PID.
pub const currentPid = implementation.currentPid;
/// Observes `pid` without blocking and preserves interruption as a normal result.
pub const waitNowait = implementation.waitNowait;
/// Returns the normal exit code encoded by `status`, or null for another status kind.
pub const exitCode = implementation.exitCode;
/// Returns the terminating signal encoded by `status`, or null for another status kind.
pub const exitSignal = implementation.exitSignal;
/// Borrows `buffer` for a best-effort process name; the result aliases that buffer.
pub const readName = implementation.readName;
/// Returns an owned NUL-separated argv list, or null when unavailable.
/// The caller must deinitialize a returned list with the allocator passed in.
pub const readArgs = implementation.readArgs;
/// Describes the platform fallback used by `readArgs`.
pub const args_source = implementation.args_source;
/// Borrows `buffer` for a best-effort executable path; the result aliases that buffer.
pub const readExecutable = implementation.readExecutable;
/// Borrows `buffer` for a best-effort working directory; the result aliases that buffer.
pub const readCwd = implementation.readCwd;
/// Sends a signal on a best-effort basis; an already exited target is harmless.
pub const safeKill = implementation.safeKill;
/// Returns whether `pid` exists; lack of signaling permission still means it exists.
pub const pidAlive = implementation.pidAlive;
/// Sleeps for the fixed grace period between TERM and KILL, retrying interruption.
pub const sleepTerminationGrace = implementation.sleepTerminationGrace;

test {
    _ = implementation;
}
