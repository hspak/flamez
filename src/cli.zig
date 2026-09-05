//! Explicit capture, output, import, and analysis command-line modes.

const std = @import("std");
const Session = @import("tracer/Session.zig");

/// Mutually exclusive application modes selected by Flamez flags.
pub const Mode = enum {
    capture_gui,
    capture_file,
    import_file,
    analyze_file,
};

/// Borrowed result of parsing arguments after the executable name.
pub const Parsed = struct {
    mode: Mode,
    path: ?[]const u8 = null,
    target: []const []const u8 = &.{},
};

/// Usage failures reported before collector or GUI initialization.
pub const ParseError = error{
    MissingFlagValue,
    DuplicateOutput,
    DuplicateImport,
    DuplicateAnalyze,
    ConflictingModes,
    OutputNeedsTarget,
    ImportRejectsTarget,
    AnalyzeRejectsTarget,
    AnalyzeNeedsFile,
    MissingTarget,
    UnknownFlag,
};

pub const AnalysisPathError = error{
    AnalyzeNeedsFile,
    PathTooLong,
};

/// Parses Flamez flags from `arguments`, which excludes the executable name.
/// Returned slices borrow `arguments` and its strings.
pub fn parse(arguments: []const []const u8) ParseError!Parsed {
    var output_path: ?[]const u8 = null;
    var import_path: ?[]const u8 = null;
    var analyze_path: ?[]const u8 = null;
    var target_start: ?usize = null;
    var index: usize = 0;

    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "--")) {
            target_start = index + 1;
            break;
        }
        if (std.mem.eql(u8, argument, "-o") or std.mem.eql(u8, argument, "--output")) {
            if (output_path != null) return error.DuplicateOutput;
            index += 1;
            if (index >= arguments.len) return error.MissingFlagValue;
            output_path = arguments[index];
            if (output_path.?.len == 0) return error.MissingFlagValue;
            continue;
        }
        if (std.mem.startsWith(u8, argument, "--output=")) {
            if (output_path != null) return error.DuplicateOutput;
            output_path = argument["--output=".len..];
            if (output_path.?.len == 0) return error.MissingFlagValue;
            continue;
        }
        if (std.mem.eql(u8, argument, "-i") or std.mem.eql(u8, argument, "--import")) {
            if (import_path != null) return error.DuplicateImport;
            index += 1;
            if (index >= arguments.len) return error.MissingFlagValue;
            import_path = arguments[index];
            if (import_path.?.len == 0) return error.MissingFlagValue;
            continue;
        }
        if (std.mem.startsWith(u8, argument, "--import=")) {
            if (import_path != null) return error.DuplicateImport;
            import_path = argument["--import=".len..];
            if (import_path.?.len == 0) return error.MissingFlagValue;
            continue;
        }
        if (std.mem.eql(u8, argument, "-a") or std.mem.eql(u8, argument, "--analyze")) {
            if (analyze_path != null) return error.DuplicateAnalyze;
            index += 1;
            if (index >= arguments.len) return error.MissingFlagValue;
            analyze_path = arguments[index];
            if (analyze_path.?.len == 0) return error.MissingFlagValue;
            continue;
        }
        if (std.mem.startsWith(u8, argument, "--analyze=")) {
            if (analyze_path != null) return error.DuplicateAnalyze;
            analyze_path = argument["--analyze=".len..];
            if (analyze_path.?.len == 0) return error.MissingFlagValue;
            continue;
        }
        if (std.mem.startsWith(u8, argument, "-")) return error.UnknownFlag;
        target_start = index;
        break;
    }

    const mode_count = @as(u2, @intFromBool(output_path != null)) +
        @intFromBool(import_path != null) +
        @intFromBool(analyze_path != null);
    if (mode_count > 1) return error.ConflictingModes;
    const target = if (target_start) |start| arguments[start..] else arguments[arguments.len..];
    if (import_path) |path| {
        if (target.len != 0) return error.ImportRejectsTarget;
        return .{ .mode = .import_file, .path = path };
    }
    if (analyze_path) |path| {
        if (target.len != 0) return error.AnalyzeRejectsTarget;
        if (std.mem.eql(u8, path, "-")) return error.AnalyzeNeedsFile;
        return .{ .mode = .analyze_file, .path = path };
    }
    if (output_path) |path| {
        if (target.len == 0) return error.OutputNeedsTarget;
        return .{ .mode = .capture_file, .path = path, .target = target };
    }
    if (target.len == 0) return error.MissingTarget;
    return .{ .mode = .capture_gui, .target = target };
}

/// Writes the sibling `analyzed-<basename>` path into caller-owned storage.
pub fn analysisOutputPath(input_path: []const u8, output: []u8) AnalysisPathError![]const u8 {
    if (input_path.len == 0 or std.mem.eql(u8, input_path, "-")) {
        return error.AnalyzeNeedsFile;
    }
    const basename = std.fs.path.basename(input_path);
    if (basename.len == 0) return error.AnalyzeNeedsFile;
    const directory_len = input_path.len - basename.len;
    return std.fmt.bufPrint(
        output,
        "{s}analyzed-{s}",
        .{ input_path[0..directory_len], basename },
    ) catch error.PathTooLong;
}

/// Returns the documented exit status after a headless file was written.
pub fn captureExitCode(session: *const Session) u8 {
    if (session.isIncomplete()) return 3;
    return switch (session.root_exit) {
        .exited => |code| if (code == 0) 0 else 4,
        .signaled, .unknown => 4,
    };
}

test "output parsing stops at double dash" {
    const parsed = try parse(&.{ "-o", "a", "--", "zig", "-o", "b" });
    try std.testing.expectEqual(Mode.capture_file, parsed.mode);
    try std.testing.expectEqualStrings("a", parsed.path.?);
    try std.testing.expectEqualSlices([]const u8, &.{ "zig", "-o", "b" }, parsed.target);
}

test "long output equals form selects stdout" {
    const parsed = try parse(&.{ "--output=-", "make", "-j8" });
    try std.testing.expectEqual(Mode.capture_file, parsed.mode);
    try std.testing.expectEqualStrings("-", parsed.path.?);
    try std.testing.expectEqualSlices([]const u8, &.{ "make", "-j8" }, parsed.target);
}

test "import rejects output and extra positionals" {
    try std.testing.expectError(
        error.ConflictingModes,
        parse(&.{ "-i", "capture.json", "-o", "other.json" }),
    );
    try std.testing.expectError(
        error.ImportRejectsTarget,
        parse(&.{ "-i", "capture.json", "extra" }),
    );
}

test "import accepts path and stdin forms without a target" {
    const short = try parse(&.{ "-i", "capture.json" });
    try std.testing.expectEqual(Mode.import_file, short.mode);
    try std.testing.expectEqualStrings("capture.json", short.path.?);
    try std.testing.expectEqual(@as(usize, 0), short.target.len);

    const long = try parse(&.{"--import=-"});
    try std.testing.expectEqual(Mode.import_file, long.mode);
    try std.testing.expectEqualStrings("-", long.path.?);
}

test "analyze accepts a file path and rejects targets or stdin" {
    const short = try parse(&.{ "-a", "capture.json" });
    try std.testing.expectEqual(Mode.analyze_file, short.mode);
    try std.testing.expectEqualStrings("capture.json", short.path.?);

    const long = try parse(&.{"--analyze=traces/build.json"});
    try std.testing.expectEqual(Mode.analyze_file, long.mode);
    try std.testing.expectEqualStrings("traces/build.json", long.path.?);

    try std.testing.expectError(
        error.AnalyzeRejectsTarget,
        parse(&.{ "-a", "capture.json", "extra" }),
    );
    try std.testing.expectError(error.AnalyzeNeedsFile, parse(&.{ "-a", "-" }));
}

test "analyze conflicts with other modes and rejects duplicates" {
    try std.testing.expectError(
        error.ConflictingModes,
        parse(&.{ "-a", "capture.json", "-i", "other.json" }),
    );
    try std.testing.expectError(
        error.ConflictingModes,
        parse(&.{ "-o", "capture.json", "-a", "other.json", "true" }),
    );
    try std.testing.expectError(
        error.DuplicateAnalyze,
        parse(&.{ "-a", "capture.json", "--analyze", "other.json" }),
    );
}

test "analysis output path prefixes the input basename" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "analyzed-capture.json",
        try analysisOutputPath("capture.json", &buffer),
    );
    try std.testing.expectEqualStrings(
        "traces/analyzed-build.json",
        try analysisOutputPath("traces/build.json", &buffer),
    );
    try std.testing.expectEqualStrings(
        "/tmp/analyzed-build.json",
        try analysisOutputPath("/tmp/build.json", &buffer),
    );
}

test "missing mode values and targets are usage errors" {
    try std.testing.expectError(error.MissingTarget, parse(&.{}));
    try std.testing.expectError(error.MissingFlagValue, parse(&.{"-o"}));
    try std.testing.expectError(error.MissingFlagValue, parse(&.{ "-i", "" }));
    try std.testing.expectError(error.OutputNeedsTarget, parse(&.{ "-o", "capture.json" }));
    try std.testing.expectError(
        error.DuplicateOutput,
        parse(&.{ "-o", "one.json", "--output", "two.json", "true" }),
    );
}

test "bare json path remains a capture target" {
    const parsed = try parse(&.{"capture.json"});
    try std.testing.expectEqual(Mode.capture_gui, parsed.mode);
    try std.testing.expectEqualStrings("capture.json", parsed.target[0]);
}

test "target beginning with dash requires double dash" {
    try std.testing.expectError(error.UnknownFlag, parse(&.{"-target"}));
    const parsed = try parse(&.{ "--", "-target" });
    try std.testing.expectEqualStrings("-target", parsed.target[0]);
}

test "headless exit gives incomplete capture precedence" {
    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    session.root_exit = .{ .exited = 9 };
    session.loss_count = 1;
    try std.testing.expectEqual(@as(u8, 3), captureExitCode(&session));

    session.loss_count = 0;
    try std.testing.expectEqual(@as(u8, 4), captureExitCode(&session));
    session.root_exit = .{ .exited = 0 };
    try std.testing.expectEqual(@as(u8, 0), captureExitCode(&session));
    session.root_exit = .unknown;
    try std.testing.expectEqual(@as(u8, 4), captureExitCode(&session));
    session.root_exit = .{ .signaled = 15 };
    try std.testing.expectEqual(@as(u8, 4), captureExitCode(&session));
}
