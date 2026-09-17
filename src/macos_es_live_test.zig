//! Installed production-mode Endpoint Security acceptance checks and unsigned diagnostics.

const std = @import("std");
const capture = @import("tracer/capture.zig");
const Process = @import("tracer/Process.zig");
const Session = @import("tracer/Session.zig");
const process_ops = @import("tracer/process_ops.zig");
const signals = @import("tracer/signals.zig");

const active_diagnostic = "using exact descendant-scoped Endpoint Security capture";
const timeout_ns = 10 * std.time.ns_per_s;

const Watchdog = struct {
    io: std.Io,
    expires_ns: i96,
    finished: std.atomic.Value(bool) = .init(false),

    fn run(self: *Watchdog) void {
        while (!self.finished.load(.acquire)) {
            if (std.Io.Clock.awake.now(self.io).nanoseconds >= self.expires_ns) {
                const message = "FAIL: validator exceeded its awake-time deadline (including ES barriers)\n";
                _ = std.c.write(std.posix.STDERR_FILENO, message.ptr, message.len);
                signals.killTargetTree(signals.armedTargetPgid());
                std.process.exit(1);
            }
            std.Thread.yield() catch {};
        }
    }
};

extern "c" fn pause() c_int;

const Fixture = enum {
    burst,
    double,
    exec,
    cpu,
    script,
};

const Record = struct {
    pid: std.posix.pid_t,
    parent_pid: ?std.posix.pid_t = null,
    version: i32 = 0,
    execs: usize = 0,
    exited: bool = false,
    cpu_ns: u64 = 0,
    samples: usize = 0,
    terminal_cpu: enum { absent, final, partial } = .absent,
    signal_slot: ?signals.TrackedSlot = null,
};

const Probe = struct {
    collector: *capture.Collector,
    records: [40]Record = undefined,
    len: usize = 0,
    forks: usize = 0,
    execs: usize = 0,
    exits: usize = 0,
    failure: ?[]const u8 = null,
    metadata_argv: ?[]const []const u8 = null,
    metadata_exe: ?[]const u8 = null,
    metadata_cwd: []const u8,
    metadata_seen: bool = false,

    fn sink(self: *Probe) capture.Sink {
        return .{
            .ptr = self,
            .event_fn = event,
            .cpu_sample_fn = cpu,
        };
    }

    fn expect(self: *Probe, condition: bool, message: []const u8) void {
        if (!condition and self.failure == null) self.failure = message;
    }

    fn record(self: *Probe, pid: std.posix.pid_t) ?*Record {
        for (self.records[0..self.len]) |*item| if (item.pid == pid) return item;
        return null;
    }

    fn event(ptr: *anyopaque, value: capture.Event) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (value.payload) {
            .fork => |fork| {
                self.forks += 1;
                const parent = self.record(fork.parent_pid) orelse {
                    self.expect(false, "fork has an unobserved parent");
                    return;
                };
                self.expect(!parent.exited, "fork follows parent exit");
                self.expect(
                    parent.version != 0 and
                        self.collector.es_versions.get(fork.parent_pid) == parent.version,
                    "fork parent generation differs from the observed image",
                );
                self.expect(self.record(fork.pid) == null, "duplicate or unrelated fork");
                if (self.len == self.records.len) {
                    self.expect(false, "unexpected process count exceeds fixture bound");
                    return;
                }
                self.records[self.len] = .{
                    .pid = fork.pid,
                    .parent_pid = fork.parent_pid,
                    .version = self.collector.es_versions.get(fork.pid) orelse 0,
                    .signal_slot = signals.rememberPid(fork.pid),
                };
                self.expect(self.records[self.len].version != 0, "fork lacks an audit generation");
                self.len += 1;
            },
            .exec => |exec| {
                self.execs += 1;
                const item = self.record(exec.pid) orelse {
                    self.expect(false, "exec belongs to an unrelated process");
                    return;
                };
                const version = self.collector.es_versions.get(exec.pid) orelse 0;
                self.expect(version > item.version, "exec did not advance the PID version");
                item.version = version;
                item.execs += 1;
                self.expect(
                    exec.metadata_source == .kernel and !exec.inspect_missing,
                    "exec metadata did not come from the kernel",
                );
                if (self.metadata_argv) |expected| {
                    // The first image of the two-stage exec fixture has different argv.
                    if (argvMatches(exec.args, expected)) {
                        self.metadata_seen = true;
                        self.expect(
                            exec.exe != null and std.mem.eql(u8, exec.exe.?, self.metadata_exe.?),
                            "kernel executable differs from the fixture image",
                        );
                        self.expect(
                            exec.cwd != null and std.mem.eql(u8, exec.cwd.?, self.metadata_cwd),
                            "kernel CWD differs from the launch directory",
                        );
                        self.expect(
                            !exec.exe_truncated and !exec.cwd_truncated,
                            "controlled metadata was truncated",
                        );
                    }
                }
            },
            .exit => |exit| {
                self.exits += 1;
                const item = self.record(exit.pid) orelse {
                    self.expect(false, "exit belongs to an unrelated process");
                    return;
                };
                self.expect(!item.exited, "duplicate exit");
                self.expect(
                    self.collector.es_versions.get(exit.pid) == null,
                    "exit retained a live audit generation",
                );
                item.exited = true;
                signals.forgetPid(item.signal_slot, item.pid);
                item.signal_slot = null;
                item.terminal_cpu = if (exit.cpu_final) .final else .partial;
            },
        }
    }

    fn cpu(ptr: *anyopaque, pid: std.posix.pid_t, total_ns: u64, _: u64) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        const item = self.record(pid) orelse {
            self.expect(false, "CPU sample belongs to an unrelated process");
            return;
        };
        self.expect(total_ns >= item.cpu_ns, "cumulative CPU went backwards");
        item.cpu_ns = total_ns;
        item.samples += 1;
    }

    fn report(self: *Probe, name: []const u8) !void {
        std.debug.print("{s}: fidelity={s} processes={d} fork={d} exec={d} exit={d} " ++
            "loss={d}\n  {s}\n", .{
            name,
            @tagName(self.collector.fidelity()),
            self.len,
            self.forks,
            self.execs,
            self.exits,
            self.collector.lost_events,
            self.collector.exactDiagnosticSlice(),
        });
        self.expect(self.collector.lost_events == 0, "controlled run lost events");
        if (self.failure) |message| {
            std.debug.print("FAIL: {s}\n", .{message});
            return error.LiveAssertion;
        }
    }
};

fn argvMatches(bytes: ?[]const u8, expected: []const []const u8) bool {
    var remaining = bytes orelse return false;
    for (expected) |argument| {
        const end = std.mem.indexOfScalar(u8, remaining, 0) orelse return false;
        if (!std.mem.eql(u8, remaining[0..end], argument)) return false;
        remaining = remaining[end + 1 ..];
    }
    return remaining.len == 0;
}

fn check(condition: bool, message: []const u8) !void {
    if (condition) return;
    std.debug.print("FAIL: {s}\n", .{message});
    return error.LiveAssertion;
}

fn deadline(io: std.Io, start: std.Io.Timestamp) !void {
    try check(
        start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds < timeout_ns,
        "fixture did not reach its condition within ten seconds",
    );
    try std.Thread.yield();
}

fn waitStopped(io: std.Io, pid: std.posix.pid_t) !void {
    const start = std.Io.Clock.awake.now(io);
    while (true) {
        var status: c_int = 0;
        const result = std.c.waitpid(pid, &status, std.c.W.NOHANG | std.c.W.UNTRACED);
        if (result == pid) {
            try check(std.c.W.IFSTOPPED(@bitCast(status)), "fixture exited before readiness");
            return;
        }
        if (result < 0) try check(
            std.c.errno(result) == .INTR,
            "waitpid rejected fixture readiness",
        );
        try deadline(io, start);
    }
}

fn waitExited(io: std.Io, child: *std.process.Child) !void {
    const start = std.Io.Clock.awake.now(io);
    while (true) {
        switch (process_ops.waitNowait(child.id.?)) {
            .reaped => |status| {
                child.id = null;
                try check(process_ops.exitCode(status) == 0, "fixture exit status was not zero");
                return;
            },
            .no_child => return error.MissingChild,
            .still_running, .interrupted => {},
        }
        try deadline(io, start);
    }
}

fn cleanChild(io: std.Io, child: *std.process.Child, pgid: std.posix.pid_t) void {
    process_ops.safeKill(-pgid, .KILL);
    if (child.id != null) child.kill(io);
}

fn fixtureRun(
    init: std.process.Init,
    collector: *capture.Collector,
    fixture: []const u8,
    cwd: []const u8,
    mode: Fixture,
    exact: bool,
) !void {
    if (exact) {
        try collector.armLaunch(process_ops.currentPid());
        try check(collector.fidelity() == .exact, "required mode did not select exact capture");
        try check(collector.worker == null, "exact capture started a fallback worker");
        try check(
            std.mem.eql(u8, collector.exactDiagnosticSlice(), active_diagnostic),
            "active diagnostic did not identify descendant-scoped ES",
        );
    }
    const script = mode == .script;
    const argv: []const []const u8 = if (script) &.{
        fixture,
        "",
        "two words",
    } else &.{ fixture, @tagName(mode) };
    var child = try process_ops.spawnTarget(init.gpa, init.io, argv, .{});
    const pid = child.id.?;
    defer cleanChild(init.io, &child, pid);
    const root_slot = signals.rememberPid(pid);
    defer signals.forgetPid(root_slot, pid);
    var probe = Probe{ .collector = collector, .metadata_cwd = cwd };
    errdefer if (exact) probe.report(@tagName(mode)) catch {};
    probe.records[0] = .{ .pid = pid };
    probe.len = 1;
    const image_argv = [_][]const u8{
        fixture,
        "image",
        "",
        "two words",
    };
    const script_argv = [_][]const u8{
        "/bin/sh",
        fixture,
        "",
        "two words",
    };
    if (mode == .exec or script) {
        probe.metadata_argv = if (script) &script_argv else &image_argv;
        probe.metadata_exe = if (script) "/bin/sh" else fixture;
    }
    if (exact) try collector.trackRoot(pid);
    defer if (exact) collector.untrack(pid);
    if (exact and mode == .burst) {
        // Generate a complete sibling subtree while this root is admitted but
        // suspended. The OS delivers it to Flamez; root filtering must discard it.
        var sibling = try process_ops.spawnTarget(init.gpa, init.io, &.{ fixture, "burst" }, .{});
        const sibling_pid = sibling.id.?;
        defer cleanChild(init.io, &sibling, sibling_pid);
        const sibling_slot = signals.rememberPid(sibling_pid);
        defer signals.forgetPid(sibling_slot, sibling_pid);
        try process_ops.resumeTarget(sibling_pid);
        try waitStopped(init.io, sibling_pid);
        process_ops.safeKill(sibling_pid, .CONT);
        try waitExited(init.io, &sibling);
        collector.flushEvents(probe.sink());
        probe.expect(
            probe.len == 1 and probe.forks == 0 and probe.exits == 0,
            "an unrelated same-user subtree was admitted",
        );
    }
    try process_ops.resumeTarget(pid);
    // In the double-fork fixture the intermediate is reaped and both descendants
    // have closed the completion pipe before this first userspace poll.
    const rounds: usize = switch (mode) {
        .cpu => 3,
        .exec => 2,
        .burst, .double, .script => 1,
    };
    for (0..rounds) |_| {
        try waitStopped(init.io, pid);
        if (exact) {
            collector.flushEvents(probe.sink());
            collector.snapshotCpu(probe.sink());
        }
        process_ops.safeKill(pid, .CONT);
    }
    try waitExited(init.io, &child);
    if (!exact) {
        std.debug.print("fixture {s}: protocol passed (kernel assertions not run)\n", .{@tagName(mode)});
        return;
    }
    // Reap is the condition: the marker must deliver every final exit already
    // enqueued by the kernel, without another poll or readiness delay.
    collector.flushEvents(probe.sink());
    const children: usize = switch (mode) {
        .burst => 32,
        .cpu, .double => 2,
        .exec, .script => 0,
    };
    probe.expect(
        probe.forks == children and probe.len == children + 1,
        "incorrect fork/process count",
    );
    probe.expect(probe.execs == (if (mode == .exec) @as(usize, 2) else 1), "incorrect exec count");
    probe.expect(probe.exits == children + 1, "final barrier left exits undelivered");
    probe.expect(collector.es_versions.count() == 0, "final barrier left live audit generations");
    for (probe.records[0..probe.len], 0..) |item, index| {
        probe.expect(item.exited and item.terminal_cpu != .absent, "missing terminal record");
        if (index == 0) continue;
        if (mode == .double) {
            probe.expect(
                item.parent_pid == probe.records[index - 1].pid,
                "double-fork ancestry was lost",
            );
        } else {
            probe.expect(item.parent_pid == pid, "child assigned to the wrong parent");
        }
        if (mode == .cpu) {
            std.debug.print("  pid={d}: samples={d} cpu={d}ns terminal={s}\n", .{
                item.pid,
                item.samples,
                item.cpu_ns,
                @tagName(item.terminal_cpu),
            });
            probe.expect(
                item.samples >= 3 and item.cpu_ns > 0,
                "fixed-work child CPU was not sampled",
            );
        }
    }
    if (probe.metadata_argv != null) probe.expect(
        probe.metadata_seen,
        "complete exec argv was not delivered",
    );
    try probe.report(@tagName(mode));
}

fn updateUntilStopped(session: *Session, collector: *capture.Collector) !void {
    const start = std.Io.Clock.awake.now(session.io);
    while (session.running) {
        session.update(collector);
        if (session.running) try deadline(session.io, start);
    }
}

fn checkSession(session: *const Session, expected: usize, exact: bool) !void {
    std.debug.print("session: fidelity={s} processes={d} loss={d} boundary={d}ns\n", .{
        @tagName(session.capture_fidelity),
        session.processes.items.len,
        session.loss_count,
        session.elapsed_ns,
    });
    try check(
        session.finished and !session.running and session.active_count == 0,
        "finished capture retained a live process",
    );
    try check(session.processes.items.len == expected, "unexpected session process count");
    try check(session.loss_count == 0, "session reported event loss");
    try check(
        session.capture_fidelity == (if (exact) capture.Fidelity.exact else .snapshot_recovery),
        "session selected the wrong capture fidelity",
    );
    for (session.processes.items) |process| {
        try check(
            process.end_ns != null and process.end_ns.? <= session.elapsed_ns,
            "process lifetime exceeds the root boundary",
        );
        for (process.cpu_slices.items) |slice| {
            try check(
                slice.start_ns <= slice.end_ns and slice.end_ns <= session.elapsed_ns,
                "CPU slice exceeds the root boundary",
            );
        }
    }
}

fn waitForExecArgs(
    session: *Session,
    collector: *capture.Collector,
    expected: []const []const u8,
    source: Process.MetadataSource,
) !void {
    const start = std.Io.Clock.awake.now(session.io);
    while (true) {
        session.update(collector);
        try check(session.running and session.processes.items.len == 1, "root exec ended capture or created a duplicate process");
        const root = &session.processes.items[0];
        const args = session.metadataBytes()[root.args_offset..][0..root.args_len];
        if (root.args_source == source and argvMatches(args, expected)) return;
        try deadline(session.io, start);
    }
}

fn sessionExecRun(
    session: *Session,
    collector: *capture.Collector,
    fixture: []const u8,
    exact: bool,
) !void {
    const initial_argv = &.{ fixture, "exec" };
    const image_argv = &.{
        fixture,
        "image",
        "",
        "two words",
    };
    const source: Process.MetadataSource = if (exact) .kernel else .process_inspection;
    try session.start(collector, initial_argv, .{});
    const root_pid = session.root_pid.?;
    try waitStopped(session.io, root_pid);
    try waitForExecArgs(session, collector, initial_argv, source);
    process_ops.safeKill(root_pid, .CONT);
    try waitStopped(session.io, root_pid);
    try waitForExecArgs(session, collector, image_argv, source);
    const root = &session.processes.items[0];
    try check(root.pid == root_pid and root.exe_source == source and root.cwd_source == source, "root exec lost its identity or metadata provenance");
    try check(std.mem.eql(u8, root.exeSlice(session.metadataBytes()), fixture), "root exec retained an old executable path");
    process_ops.safeKill(root_pid, .CONT);
    try updateUntilStopped(session, collector);
    try checkSession(session, 1, exact);
    const finished = &session.processes.items[0];
    try check(finished.execCount() == 2, "root exec history lost or duplicated an image");
    const first = finished.execAt(0);
    const second = finished.execAt(1);
    const metadata = session.metadataBytes();
    try check(first.args_source == source and second.args_source == source and
        argvMatches(metadata[first.args_offset..][0..first.args_len], initial_argv) and
        argvMatches(metadata[second.args_offset..][0..second.args_len], image_argv), "finished exec history lost its argv or metadata provenance");
    try check(first.end_ns == second.start_ns and second.end_ns == session.elapsed_ns, "root exec history does not partition the captured lifetime");
}

fn sessionRuns(
    init: std.process.Init,
    collector: *capture.Collector,
    fixture: []const u8,
    exact: bool,
) !void {
    var session = Session.init(init.gpa, init.io);
    defer session.deinit();
    try sessionExecRun(&session, collector, fixture, exact);
    for (0..24) |_| {
        try session.start(collector, &.{ fixture, "immediate" }, .{});
        try updateUntilStopped(&session, collector);
        try checkSession(&session, 1, exact);
        try check(
            session.root_exit == .exited and session.root_exit.exited == 23,
            "immediate root lost its exit status",
        );
        const root = session.processes.items[0];
        try check(
            root.end_kind == .observed_exit and root.end_ns.? == session.elapsed_ns,
            "immediate root lost its observed exit boundary",
        );
    }
    for (0..4) |_| {
        try session.start(collector, &.{ fixture, "hold" }, .{});
        try waitStopped(init.io, session.root_pid.?);
        session.update(collector);
        session.stop(collector);
        try checkSession(&session, 1, exact);
        try check(
            session.processes.items[0].end_kind == .capture_clipped,
            "forced stop imported teardown as a natural exit",
        );
        try session.start(collector, &.{ fixture, "immediate" }, .{});
        try updateUntilStopped(&session, collector);
        try checkSession(&session, 1, exact);
    }
    try session.start(collector, &.{ fixture, "survivor" }, .{});
    const root_pid = session.root_pid.?;
    defer process_ops.safeKill(-root_pid, .KILL);
    try waitStopped(init.io, root_pid);
    const start = std.Io.Clock.awake.now(init.io);
    while (session.processes.items.len != 2) {
        session.update(collector);
        try check(session.processes.items.len <= 2, "survivor fixture received unrelated records");
        try deadline(init.io, start);
    }
    process_ops.safeKill(root_pid, .CONT);
    try updateUntilStopped(&session, collector);
    try checkSession(&session, 2, exact);
    const descendant = session.processes.items[1];
    try check(
        descendant.end_kind == .capture_clipped and descendant.end_ns.? == session.elapsed_ns,
        "surviving descendant was not clipped at the root boundary",
    );
}

fn watchdogCheck(init: std.process.Init, fixture: []const u8) !void {
    var child = try process_ops.spawnTarget(init.gpa, init.io, &.{ fixture, "hold" }, .{});
    const pid = child.id.?;
    defer cleanChild(init.io, &child, pid);
    const slot = signals.rememberPid(pid);
    defer signals.forgetPid(slot, pid);
    try process_ops.resumeTarget(pid);
    try waitStopped(init.io, pid);
    std.debug.print("watchdog check: stopped fixture pid={d}; main thread will block\n", .{pid});
    var watchdog = Watchdog{
        .io = init.io,
        .expires_ns = std.Io.Clock.awake.now(init.io).nanoseconds,
    };
    const thread = try std.Thread.spawn(.{}, Watchdog.run, .{&watchdog});
    defer {
        watchdog.finished.store(true, .release);
        thread.join();
    }
    // Deliberately model an ES barrier that never returns. Only the independent
    // watchdog can end this check; its expected process exit status is 1.
    while (true) _ = pause();
}

pub fn main(init: std.process.Init) !void {
    signals.installFatalSignalHandlers();
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const unsigned = argv.len == 2 and std.mem.eql(u8, argv[1], "--unsigned");
    const check_watchdog = argv.len == 2 and std.mem.eql(u8, argv[1], "--watchdog-check");
    try check(argv.len == 1 or unsigned or check_watchdog, "usage: macos-es-live-test [--unsigned | --watchdog-check]");
    var watchdog = Watchdog{
        .io = init.io,
        .expires_ns = std.Io.Clock.awake.now(init.io).nanoseconds + 60 * std.time.ns_per_s,
    };
    const watch_thread = try std.Thread.spawn(.{}, Watchdog.run, .{&watchdog});
    defer {
        watchdog.finished.store(true, .release);
        watch_thread.join();
    }
    defer signals.killTargetTree(signals.armedTargetPgid());
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try std.process.executablePath(init.io, &path_buffer);
    const directory = std.fs.path.dirname(path_buffer[0..path_len]).?;
    const fixture = try std.fs.path.join(init.arena.allocator(), &.{ directory, "macos-es-fixture" });
    if (check_watchdog) return watchdogCheck(init, fixture);
    const script = try std.fs.path.join(init.arena.allocator(), &.{ directory, "macos-es-fixture.sh" });
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(init.io, &cwd_buffer);
    const cwd = cwd_buffer[0..cwd_len];
    var collector = capture.Collector.initWithOptions(init.gpa, .{ .endpoint_security = .required });
    defer collector.deinit();
    collector.armLaunch(process_ops.currentPid()) catch |err| {
        std.debug.print("activation: fidelity={s} fork=0 exec=0 exit=0 loss={d}\n  {s}\n", .{
            @tagName(collector.fidelity()),
            collector.lost_events,
            collector.exactDiagnosticSlice(),
        });
        if (!unsigned) return err;
        try check(
            err == error.ExactCaptureUnavailable and
                collector.es_handle == null and collector.worker == null,
            "required mode did not fail closed before spawning",
        );
        try check(
            std.mem.indexOf(u8, collector.exactDiagnosticSlice(), "entitlement") != null,
            "negative check requires the not-entitled diagnostic on macOS 27",
        );
    };
    if (unsigned) {
        try check(collector.fidelity() != .exact, "unsigned check unexpectedly activated ES");
    } else {
        try check(collector.fidelity() == .exact, "activation did not select exact capture");
    }
    for ([_]Fixture{
        .burst,
        .double,
        .exec,
        .cpu,
    }) |mode| {
        try fixtureRun(init, &collector, fixture, cwd, mode, !unsigned);
    }
    try fixtureRun(init, &collector, script, cwd, .script, !unsigned);
    if (unsigned) collector.endpoint_security_mode = .automatic;
    try sessionRuns(init, &collector, fixture, !unsigned);
    std.debug.print("PASS: {s}\n", .{if (unsigned)
        "unsigned entitlement rejection, fixtures, and automatic fallback (exact delivery unverified)"
    else
        "production descendant-scoped ES acceptance checks"});
}
