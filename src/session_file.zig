//! Streaming import and export of finished Flamez sessions.

const std = @import("std");

const Allocator = std.mem.Allocator;
const CaptureEnvironment = @import("tracer/CaptureEnvironment.zig");
const Process = @import("tracer/Process.zig");
const Session = @import("tracer/Session.zig");
const capture = @import("tracer/capture.zig");

const max_argv_bytes = 6 * 1024 * 1024;

pub const ValidationError = error{
    SessionNotFinished,
    InvalidSession,
    UnsupportedCaptureFidelity,
    InvalidTargetArgv,
    InvalidProcessTopology,
    InvalidProcessInterval,
    InvalidProcessImage,
    InvalidMetadata,
    InvalidExecInterval,
    InvalidCpuSlice,
    StaleDerivedCache,
};

pub const WriteError = Allocator.Error || std.Io.Writer.Error || ValidationError;

pub const WriteFileOptions = struct {
    install: Install = .exclusive,

    pub const Install = enum { exclusive, replace };
};

pub const WriteFileError =
    WriteError ||
    std.Io.Dir.CreateFileAtomicError ||
    std.Io.File.Writer.Error ||
    std.Io.File.Atomic.LinkError ||
    std.Io.File.Atomic.ReplaceError;

pub const Diagnostics = struct {
    byte_offset: u64 = 0,
    reason: Reason = .none,

    pub const Reason = enum {
        none,
        invalid_json,
        unsupported_version,
        duplicate_field,
        unknown_field,
        value_too_long,
        invalid_base64,
        invalid_integer,
        invalid_byte_string,
        invariant_violated,
        read_failed,
        out_of_memory,
    };
};

pub const ReadError =
    Allocator.Error ||
    std.Io.Reader.Error ||
    error{
        InvalidJson,
        UnsupportedVersion,
        DuplicateField,
        UnknownField,
        ValueTooLong,
        InvalidBase64,
        InvalidInteger,
        InvalidByteString,
        InvariantViolated,
    };

pub const ReadFileError = std.Io.File.OpenError || ReadError;

const max_encoded_argv_bytes = 8 * 1024 * 1024;

const Text = union(enum) {
    borrowed: []const u8,
    owned: []u8,

    fn slice(self: Text) []const u8 {
        return switch (self) {
            .borrowed => |bytes| bytes,
            .owned => |bytes| bytes,
        };
    }

    fn deinit(self: *Text, gpa: Allocator) void {
        switch (self.*) {
            .borrowed => {},
            .owned => |bytes| gpa.free(bytes),
        }
        self.* = undefined;
    }

    fn toOwned(self: *Text, gpa: Allocator) Allocator.Error![]u8 {
        return switch (self.*) {
            .borrowed => |bytes| try gpa.dupe(u8, bytes),
            .owned => |bytes| owned: {
                self.* = .{ .borrowed = "" };
                break :owned bytes;
            },
        };
    }
};

const Parser = struct {
    gpa: Allocator,
    tokens: std.json.Reader,

    fn init(gpa: Allocator, reader: *std.Io.Reader) Parser {
        return .{
            .gpa = gpa,
            .tokens = .init(gpa, reader),
        };
    }

    fn deinit(self: *Parser) void {
        self.tokens.deinit();
        self.* = undefined;
    }

    fn next(self: *Parser) ReadError!std.json.Token {
        return self.tokens.next() catch |err| return mapJsonError(err);
    }

    fn peek(self: *Parser) ReadError!std.json.TokenType {
        return self.tokens.peekNextTokenType() catch |err| return mapJsonError(err);
    }

    fn expect(self: *Parser, expected: std.json.TokenType) ReadError!void {
        const token = try self.next();
        const actual: std.json.TokenType = switch (token) {
            .object_begin => .object_begin,
            .object_end => .object_end,
            .array_begin => .array_begin,
            .array_end => .array_end,
            .true => .true,
            .false => .false,
            .null => .null,
            .number, .allocated_number => .number,
            .string, .allocated_string => .string,
            .end_of_document => .end_of_document,
            .partial_number,
            .partial_string,
            .partial_string_escaped_1,
            .partial_string_escaped_2,
            .partial_string_escaped_3,
            .partial_string_escaped_4,
            => return error.InvalidJson,
        };
        if (actual != expected) return error.InvalidJson;
        switch (token) {
            .allocated_number, .allocated_string => |bytes| self.gpa.free(bytes),
            else => {},
        }
    }

    fn text(self: *Parser, max_len: usize) ReadError!Text {
        const token = self.tokens.nextAllocMax(self.gpa, .alloc_if_needed, max_len) catch |err|
            return mapJsonError(err);
        return switch (token) {
            .string => |bytes| .{ .borrowed = bytes },
            .allocated_string => |bytes| .{ .owned = bytes },
            else => error.InvalidJson,
        };
    }

    fn integer(self: *Parser, comptime T: type) ReadError!T {
        var value = value: {
            const token = self.tokens.nextAllocMax(self.gpa, .alloc_if_needed, 64) catch |err|
                return mapJsonError(err);
            break :value switch (token) {
                .number => |bytes| Text{ .borrowed = bytes },
                .allocated_number => |bytes| Text{ .owned = bytes },
                else => return error.InvalidJson,
            };
        };
        defer value.deinit(self.gpa);
        return std.fmt.parseInt(T, value.slice(), 10) catch error.InvalidInteger;
    }

    fn boolean(self: *Parser) ReadError!bool {
        return switch (try self.next()) {
            .true => true,
            .false => false,
            else => error.InvalidJson,
        };
    }

    fn fieldName(self: *Parser) ReadError!Text {
        return self.text(64);
    }
};

const MetadataTables = struct {
    argv: std.ArrayList(ArgvRange) = .empty,
    paths: std.ArrayList(PathRange) = .empty,

    fn deinit(self: *MetadataTables, gpa: Allocator) void {
        self.argv.deinit(gpa);
        self.paths.deinit(gpa);
        self.* = undefined;
    }
};

const Row = union(enum) {
    first_exec,
    image: Process.Exec,
};

const ArgvRange = struct {
    offset: usize,
    len: usize,
    count: usize,
};

const PathRange = struct {
    offset: usize,
    len: usize,
};

const ArgvHash = struct {
    metadata: []const u8,

    pub fn hash(self: ArgvHash, range: ArgvRange) u64 {
        var hasher = std.hash.Wyhash.init(0);
        var args = argvIter(self.metadata, range);
        while (args.next()) |arg| {
            hasher.update(arg);
            hasher.update("\x00");
        }
        return hasher.final();
    }

    pub fn eql(self: ArgvHash, lhs: ArgvRange, rhs: ArgvRange) bool {
        if (lhs.count != rhs.count) return false;
        var lhs_args = argvIter(self.metadata, lhs);
        var rhs_args = argvIter(self.metadata, rhs);
        while (lhs_args.next()) |lhs_arg| {
            const rhs_arg = rhs_args.next() orelse return false;
            if (!std.mem.eql(u8, lhs_arg, rhs_arg)) return false;
        }
        return rhs_args.next() == null;
    }
};

const PathHash = struct {
    metadata: []const u8,

    pub fn hash(self: PathHash, range: PathRange) u64 {
        return std.hash.Wyhash.hash(0, rangeBytes(self.metadata, range.offset, range.len));
    }

    pub fn eql(self: PathHash, lhs: PathRange, rhs: PathRange) bool {
        return std.mem.eql(
            u8,
            rangeBytes(self.metadata, lhs.offset, lhs.len),
            rangeBytes(self.metadata, rhs.offset, rhs.len),
        );
    }
};

const ArgvMap = std.HashMapUnmanaged(
    ArgvRange,
    usize,
    ArgvHash,
    std.hash_map.default_max_load_percentage,
);
const PathMap = std.HashMapUnmanaged(
    PathRange,
    usize,
    PathHash,
    std.hash_map.default_max_load_percentage,
);
const ArgvIdentityMap = std.AutoHashMapUnmanaged(ArgvRange, usize);
const PathIdentityMap = std.AutoHashMapUnmanaged(PathRange, usize);

const Tables = struct {
    metadata: []const u8,
    argv: std.ArrayList(ArgvRange) = .empty,
    paths: std.ArrayList(PathRange) = .empty,
    argv_identity: ArgvIdentityMap = .empty,
    path_identity: PathIdentityMap = .empty,
    argv_map: ArgvMap = .empty,
    path_map: PathMap = .empty,

    fn deinit(self: *Tables, gpa: Allocator) void {
        self.argv.deinit(gpa);
        self.paths.deinit(gpa);
        self.argv_identity.deinit(gpa);
        self.path_identity.deinit(gpa);
        self.argv_map.deinit(gpa);
        self.path_map.deinit(gpa);
        self.* = undefined;
    }

    fn internArgv(self: *Tables, gpa: Allocator, range: ArgvRange) Allocator.Error!usize {
        if (self.argv_identity.get(range)) |index| return index;
        const hash = ArgvHash{ .metadata = self.metadata };
        if (self.argv_map.getContext(range, hash)) |index| {
            try self.argv_identity.put(gpa, range, index);
            return index;
        }
        try self.argv.ensureUnusedCapacity(gpa, 1);
        const result = try self.argv_map.getOrPutContext(gpa, range, hash);
        if (result.found_existing) {
            try self.argv_identity.put(gpa, range, result.value_ptr.*);
            return result.value_ptr.*;
        }
        const index = self.argv.items.len;
        self.argv.appendAssumeCapacity(range);
        result.value_ptr.* = index;
        try self.argv_identity.put(gpa, range, index);
        return index;
    }

    fn internPath(self: *Tables, gpa: Allocator, range: PathRange) Allocator.Error!usize {
        if (self.path_identity.get(range)) |index| return index;
        const hash = PathHash{ .metadata = self.metadata };
        if (self.path_map.getContext(range, hash)) |index| {
            try self.path_identity.put(gpa, range, index);
            return index;
        }
        try self.paths.ensureUnusedCapacity(gpa, 1);
        const result = try self.path_map.getOrPutContext(gpa, range, hash);
        if (result.found_existing) {
            try self.path_identity.put(gpa, range, result.value_ptr.*);
            return result.value_ptr.*;
        }
        const index = self.paths.items.len;
        self.paths.appendAssumeCapacity(range);
        result.value_ptr.* = index;
        try self.path_identity.put(gpa, range, index);
        return index;
    }

    fn argvRef(self: *const Tables, range: ArgvRange) usize {
        return self.argv_identity.get(range).?;
    }

    fn pathRef(self: *const Tables, range: PathRange) usize {
        return self.path_identity.get(range).?;
    }
};

/// Validates and writes one finished session as compact v1 JSON plus a newline.
/// Validation and metadata-table preparation finish before the first output byte.
pub fn write(
    gpa: Allocator,
    session: *const Session,
    writer: *std.Io.Writer,
) WriteError!void {
    var tables = try prepare(gpa, session);
    defer tables.deinit(gpa);

    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try field(&json, "flamez", @as(u8, 1));
    try field(&json, "loss_count", session.loss_count);
    try field(&json, "capture_fidelity", @tagName(session.capture_fidelity));
    try field(&json, "cpu_sample_period_ns", session.sample_period_ns);
    try field(&json, "host_cpu_count", session.host_cpu_count);
    try json.objectField("environment");
    try writeCaptureEnvironment(&json, session.environment);
    try field(&json, "target_argv", tables.argvRef(targetArgvRange(session)));
    try field(&json, "elapsed_ns", session.elapsed_ns);
    try json.objectField("root_exit");
    try writeRootExit(&json, session.root_exit);
    try json.objectField("metadata");
    try writeMetadata(&json, &tables);
    try json.objectField("processes");
    try json.beginArray();
    for (session.processes.items, 0..) |process, index| {
        try writeProcess(&json, &tables, &process, index);
    }
    try json.endArray();
    try json.endObject();
    try writer.writeByte('\n');
}

/// Atomically installs a validated session file at `path`.
pub fn writeFile(
    gpa: Allocator,
    io: std.Io,
    session: *const Session,
    path: []const u8,
    options: WriteFileOptions,
) WriteFileError!void {
    const replace = options.install == .replace;
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .replace = replace,
    });
    defer atomic_file.deinit(io);

    var buffer: [16 * 1024]u8 = undefined;
    var file_writer = atomic_file.file.writer(io, &buffer);
    try write(gpa, session, &file_writer.interface);
    try file_writer.flush();
    switch (options.install) {
        .exclusive => try atomic_file.link(io),
        .replace => try atomic_file.replace(io),
    }
}

/// Streams one v1 JSON document into an owning, finished session.
/// The caller must call `deinit` on the returned session.
pub fn read(
    gpa: Allocator,
    io: std.Io,
    reader: *std.Io.Reader,
    diagnostics: *Diagnostics,
) ReadError!Session {
    diagnostics.* = .{};
    var parser = Parser.init(gpa, reader);
    defer parser.deinit();
    var json_diagnostics: std.json.Diagnostics = .{};
    parser.tokens.enableDiagnostics(&json_diagnostics);

    return readSession(&parser, io) catch |err| {
        diagnostics.byte_offset = json_diagnostics.getByteOffset();
        diagnostics.reason = reasonForError(err);
        return err;
    };
}

/// Opens and streams one session file from `path`.
pub fn readFile(
    gpa: Allocator,
    io: std.Io,
    path: []const u8,
    diagnostics: *Diagnostics,
) ReadFileError!Session {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [16 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    return read(gpa, io, &file_reader.interface, diagnostics);
}

fn readSession(parser: *Parser, io: std.Io) ReadError!Session {
    var session = Session.init(parser.gpa, io);
    errdefer session.deinit();
    var metadata_tables: MetadataTables = .{};
    defer metadata_tables.deinit(parser.gpa);
    var target_argv_ref: ?usize = null;
    var seen: u16 = 0;

    try parser.expect(.object_begin);
    var version_field = try parser.fieldName();
    defer version_field.deinit(parser.gpa);
    if (!std.mem.eql(u8, version_field.slice(), "flamez")) return error.UnsupportedVersion;
    const version = try parser.integer(u8);
    if (version != 1) return error.UnsupportedVersion;

    while (try parser.peek() != .object_end) {
        var name = try parser.fieldName();
        defer name.deinit(parser.gpa);
        const bytes = name.slice();
        if (std.mem.eql(u8, bytes, "loss_count")) {
            try mark(&seen, 0);
            session.loss_count = try parser.integer(u64);
        } else if (std.mem.eql(u8, bytes, "capture_fidelity")) {
            try mark(&seen, 1);
            session.capture_fidelity = try parseCaptureFidelity(parser);
        } else if (std.mem.eql(u8, bytes, "cpu_sample_period_ns")) {
            try mark(&seen, 2);
            session.sample_period_ns = try parser.integer(u64);
        } else if (std.mem.eql(u8, bytes, "host_cpu_count")) {
            try mark(&seen, 3);
            session.host_cpu_count = try parser.integer(usize);
        } else if (std.mem.eql(u8, bytes, "target_argv")) {
            try mark(&seen, 4);
            target_argv_ref = try parser.integer(usize);
        } else if (std.mem.eql(u8, bytes, "elapsed_ns")) {
            try mark(&seen, 5);
            session.elapsed_ns = try parser.integer(u64);
        } else if (std.mem.eql(u8, bytes, "root_exit")) {
            try mark(&seen, 6);
            session.root_exit = try parseRootExit(parser);
        } else if (std.mem.eql(u8, bytes, "metadata")) {
            try mark(&seen, 7);
            try parseMetadata(parser, &session, &metadata_tables);
        } else if (std.mem.eql(u8, bytes, "processes")) {
            try mark(&seen, 8);
            try parseProcesses(parser, &session);
        } else if (std.mem.eql(u8, bytes, "environment")) {
            try mark(&seen, 9);
            session.environment = try parseCaptureEnvironment(parser);
        } else if (std.mem.eql(u8, bytes, "flamez")) {
            return error.DuplicateField;
        } else {
            return error.UnknownField;
        }
    }
    try parser.expect(.object_end);
    try parser.expect(.end_of_document);
    const expected_fields: u16 = (1 << 10) - 1;
    if (seen != expected_fields) return error.InvariantViolated;

    const target_ref = target_argv_ref orelse return error.InvariantViolated;
    if (target_ref >= metadata_tables.argv.items.len) return error.InvariantViolated;
    const target = metadata_tables.argv.items[target_ref];
    session.target_argv_offset = target.offset;
    session.target_argv_len = target.len;
    session.target_argv_count = target.count;
    try resolveProcessMetadata(&session, &metadata_tables);
    session.rebuildDerivedCaches();
    session.topology_revision = 1;
    session.interval_revision = 1;
    session.label_revision = 1;
    session.finished = true;

    var checked = prepare(parser.gpa, &session) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvariantViolated,
    };
    checked.deinit(parser.gpa);
    return session;
}

fn parseCaptureFidelity(parser: *Parser) ReadError!capture.Fidelity {
    var text = try parser.text(32);
    defer text.deinit(parser.gpa);
    if (std.mem.eql(u8, text.slice(), "exact")) return .exact;
    if (std.mem.eql(u8, text.slice(), "snapshot_recovery")) return .snapshot_recovery;
    return error.InvariantViolated;
}

fn parseCaptureEnvironment(parser: *Parser) ReadError!CaptureEnvironment {
    var environment: CaptureEnvironment = .{};
    var seen: u8 = 0;
    try parser.expect(.object_begin);
    while (try parser.peek() != .object_end) {
        var name = try parser.fieldName();
        defer name.deinit(parser.gpa);
        if (std.mem.eql(u8, name.slice(), "started_at_unix_seconds")) {
            try mark(&seen, 0);
            if (try parser.peek() == .null) {
                try parser.expect(.null);
            } else {
                environment.started_at_unix_seconds = try parser.integer(i64);
            }
        } else if (std.mem.eql(u8, name.slice(), "flamez_version")) {
            try mark(&seen, 1);
            if (try parser.peek() == .null) {
                try parser.expect(.null);
            } else {
                var value = try parser.text(CaptureEnvironment.max_tool_version_len);
                defer value.deinit(parser.gpa);
                environment.setFlamezVersion(value.slice());
            }
        } else if (std.mem.eql(u8, name.slice(), "flamez_build_zig_version")) {
            try mark(&seen, 2);
            if (try parser.peek() == .null) {
                try parser.expect(.null);
            } else {
                var value = try parser.text(CaptureEnvironment.max_tool_version_len);
                defer value.deinit(parser.gpa);
                environment.setFlamezBuildZigVersion(value.slice());
            }
        } else if (std.mem.eql(u8, name.slice(), "os")) {
            try mark(&seen, 3);
            var value = try parser.text(16);
            defer value.deinit(parser.gpa);
            environment.host_os = if (std.mem.eql(u8, value.slice(), "linux"))
                .linux
            else if (std.mem.eql(u8, value.slice(), "macos"))
                .macos
            else if (std.mem.eql(u8, value.slice(), "unknown"))
                .unknown
            else
                return error.InvariantViolated;
        } else if (std.mem.eql(u8, name.slice(), "architecture")) {
            try mark(&seen, 4);
            var value = try parser.text(16);
            defer value.deinit(parser.gpa);
            environment.architecture = if (std.mem.eql(u8, value.slice(), "x86_64"))
                .x86_64
            else if (std.mem.eql(u8, value.slice(), "aarch64"))
                .aarch64
            else if (std.mem.eql(u8, value.slice(), "unknown"))
                .unknown
            else
                return error.InvariantViolated;
        } else if (std.mem.eql(u8, name.slice(), "kernel_version")) {
            try mark(&seen, 5);
            if (try parser.peek() == .null) {
                try parser.expect(.null);
            } else {
                var value = try parser.text(CaptureEnvironment.max_kernel_version_len);
                defer value.deinit(parser.gpa);
                environment.setKernelVersion(value.slice());
            }
        } else {
            return error.UnknownField;
        }
    }
    try parser.expect(.object_end);
    if (seen != 0b11_1111) return error.InvariantViolated;
    return environment;
}

fn parseRootExit(parser: *Parser) ReadError!Session.RootExit {
    const Kind = enum { exited, signaled, unknown };
    var kind: ?Kind = null;
    var code: ?u8 = null;
    var signal: ?u8 = null;
    var seen: u8 = 0;
    try parser.expect(.object_begin);
    while (try parser.peek() != .object_end) {
        var name = try parser.fieldName();
        defer name.deinit(parser.gpa);
        if (std.mem.eql(u8, name.slice(), "kind")) {
            try mark(&seen, 0);
            var value = try parser.text(16);
            defer value.deinit(parser.gpa);
            if (std.mem.eql(u8, value.slice(), "exited")) {
                kind = .exited;
            } else if (std.mem.eql(u8, value.slice(), "signaled")) {
                kind = .signaled;
            } else if (std.mem.eql(u8, value.slice(), "unknown")) {
                kind = .unknown;
            } else {
                return error.InvariantViolated;
            }
        } else if (std.mem.eql(u8, name.slice(), "code")) {
            try mark(&seen, 1);
            code = try parser.integer(u8);
        } else if (std.mem.eql(u8, name.slice(), "signal")) {
            try mark(&seen, 2);
            signal = try parser.integer(u8);
        } else {
            return error.UnknownField;
        }
    }
    try parser.expect(.object_end);
    return switch (kind orelse return error.InvariantViolated) {
        .exited => if (code != null and signal == null and seen == 0b011)
            .{ .exited = code.? }
        else
            error.InvariantViolated,
        .signaled => if (signal != null and signal.? > 0 and code == null and seen == 0b101)
            .{ .signaled = signal.? }
        else
            error.InvariantViolated,
        .unknown => if (code == null and signal == null and seen == 0b001)
            .unknown
        else
            error.InvariantViolated,
    };
}

fn parseMetadata(
    parser: *Parser,
    session: *Session,
    tables: *MetadataTables,
) ReadError!void {
    var seen: u8 = 0;
    try parser.expect(.object_begin);
    while (try parser.peek() != .object_end) {
        var name = try parser.fieldName();
        defer name.deinit(parser.gpa);
        if (std.mem.eql(u8, name.slice(), "argv")) {
            try mark(&seen, 0);
            try parseArgvTable(parser, session, &tables.argv);
        } else if (std.mem.eql(u8, name.slice(), "paths")) {
            try mark(&seen, 1);
            try parsePathTable(parser, session, &tables.paths);
        } else {
            return error.UnknownField;
        }
    }
    try parser.expect(.object_end);
    if (seen != 0b11) return error.InvariantViolated;
}

fn parseArgvTable(
    parser: *Parser,
    session: *Session,
    entries: *std.ArrayList(ArgvRange),
) ReadError!void {
    try parser.expect(.array_begin);
    while (try parser.peek() != .array_end) {
        try parser.expect(.array_begin);
        const offset = session.metadata.items.len;
        var count: usize = 0;
        var total: usize = 0;
        while (try parser.peek() != .array_end) {
            const argument = try parseByteString(parser, max_argv_bytes);
            defer parser.gpa.free(argument);
            if (std.mem.indexOfScalar(u8, argument, 0) != null) {
                return error.InvalidByteString;
            }
            total = std.math.add(usize, total, argument.len) catch
                return error.ValueTooLong;
            total = std.math.add(usize, total, 1) catch return error.ValueTooLong;
            if (total > max_argv_bytes) return error.ValueTooLong;
            try session.metadata.appendSlice(parser.gpa, argument);
            try session.metadata.append(parser.gpa, 0);
            count = std.math.add(usize, count, 1) catch return error.ValueTooLong;
        }
        try parser.expect(.array_end);
        if (count == 0) return error.InvariantViolated;
        try entries.append(parser.gpa, .{
            .offset = offset,
            .len = total,
            .count = count,
        });
    }
    try parser.expect(.array_end);
}

fn parsePathTable(
    parser: *Parser,
    session: *Session,
    entries: *std.ArrayList(PathRange),
) ReadError!void {
    try parser.expect(.array_begin);
    while (try parser.peek() != .array_end) {
        const path = try parseByteString(parser, Process.max_path_len);
        defer parser.gpa.free(path);
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) {
            return error.InvalidByteString;
        }
        const offset = session.metadata.items.len;
        try session.metadata.appendSlice(parser.gpa, path);
        try entries.append(parser.gpa, .{ .offset = offset, .len = path.len });
    }
    try parser.expect(.array_end);
}

fn parseProcesses(parser: *Parser, session: *Session) ReadError!void {
    try parser.expect(.array_begin);
    while (try parser.peek() != .array_end) {
        var process = try parseProcess(parser, session);
        errdefer process.deinit(parser.gpa);
        try session.processes.append(parser.gpa, process);
    }
    try parser.expect(.array_end);
}

fn parseProcess(parser: *Parser, session: *const Session) ReadError!Process {
    var process = Process{ .pid = 0 };
    errdefer process.deinit(parser.gpa);
    var parent: ?usize = null;
    var row: ?Row = null;
    var seen: u16 = 0;

    try parser.expect(.object_begin);
    while (try parser.peek() != .object_end) {
        var name = try parser.fieldName();
        defer name.deinit(parser.gpa);
        const bytes = name.slice();
        if (std.mem.eql(u8, bytes, "pid")) {
            try mark(&seen, 0);
            process.pid = try parser.integer(std.posix.pid_t);
        } else if (std.mem.eql(u8, bytes, "parent")) {
            try mark(&seen, 1);
            parent = if (try parser.peek() == .null) parent: {
                try parser.expect(.null);
                break :parent null;
            } else try parser.integer(usize);
        } else if (std.mem.eql(u8, bytes, "start_ns")) {
            try mark(&seen, 2);
            process.start_ns = try parser.integer(u64);
        } else if (std.mem.eql(u8, bytes, "end_ns")) {
            try mark(&seen, 3);
            process.end_ns = try parser.integer(u64);
        } else if (std.mem.eql(u8, bytes, "origin")) {
            try mark(&seen, 4);
            process.origin = try parseOrigin(parser);
        } else if (std.mem.eql(u8, bytes, "end_kind")) {
            try mark(&seen, 5);
            process.end_kind = try parseEndKind(parser);
        } else if (std.mem.eql(u8, bytes, "row")) {
            try mark(&seen, 6);
            row = try parseRow(parser);
        } else if (std.mem.eql(u8, bytes, "execs")) {
            try mark(&seen, 7);
            try parseExecs(parser, &process.execs);
        } else if (std.mem.eql(u8, bytes, "cpu_time_ns")) {
            try mark(&seen, 8);
            process.cpu_time_ns = try parser.integer(u64);
        } else if (std.mem.eql(u8, bytes, "cpu_final")) {
            try mark(&seen, 9);
            process.cpu_final = try parser.boolean();
        } else if (std.mem.eql(u8, bytes, "slices")) {
            try mark(&seen, 10);
            try parseCpuSlices(parser, &process.cpu_slices);
        } else {
            return error.UnknownField;
        }
    }
    try parser.expect(.object_end);
    if (seen != (1 << 11) - 1 or process.execs.items.len == 0) {
        return error.InvariantViolated;
    }

    const current = process.execs.items[process.execs.items.len - 1];
    if (current.end_ns != process.end_ns) return error.InvariantViolated;
    process.execs.items.len -= 1;
    process.setCurrentExec(current);
    switch (row orelse return error.InvariantViolated) {
        .first_exec => {},
        .image => |image| {
            var retained = image;
            retained.row_only = true;
            try process.execs.insert(parser.gpa, 0, retained);
        },
    }

    const index = session.processes.items.len;
    process.parent_index = parent;
    if (parent) |parent_index| {
        if (parent_index >= index) return error.InvariantViolated;
        const parent_process = session.processes.items[parent_index];
        process.parent_pid = parent_process.pid;
        process.depth = std.math.add(u16, parent_process.depth, 1) catch
            return error.InvariantViolated;
    } else {
        process.parent_pid = null;
        process.depth = 0;
    }
    process.revision = 1;
    return process;
}

fn parseOrigin(parser: *Parser) ReadError!Process.Origin {
    var text = try parser.text(32);
    defer text.deinit(parser.gpa);
    inline for (std.meta.tags(Process.Origin)) |tag| {
        if (std.mem.eql(u8, text.slice(), @tagName(tag))) return tag;
    }
    return error.InvariantViolated;
}

fn parseEndKind(parser: *Parser) ReadError!Process.EndKind {
    var text = try parser.text(32);
    defer text.deinit(parser.gpa);
    if (std.mem.eql(u8, text.slice(), "observed_exit")) return .observed_exit;
    if (std.mem.eql(u8, text.slice(), "capture_clipped")) return .capture_clipped;
    return error.InvariantViolated;
}

fn parseRow(parser: *Parser) ReadError!Row {
    return switch (try parser.peek()) {
        .string => row: {
            var text = try parser.text(32);
            defer text.deinit(parser.gpa);
            if (!std.mem.eql(u8, text.slice(), "first_exec")) {
                return error.InvariantViolated;
            }
            break :row .first_exec;
        },
        .object_begin => .{ .image = try parseImage(parser, false) },
        else => error.InvalidJson,
    };
}

fn parseExecs(parser: *Parser, execs: *std.ArrayList(Process.Exec)) ReadError!void {
    try parser.expect(.array_begin);
    while (try parser.peek() != .array_end) {
        try execs.append(parser.gpa, try parseImage(parser, true));
    }
    try parser.expect(.array_end);
}

fn parseImage(parser: *Parser, with_times: bool) ReadError!Process.Exec {
    var image = Process.Exec{ .start_ns = 0, .end_ns = null };
    var seen: u8 = 0;
    try parser.expect(.object_begin);
    while (try parser.peek() != .object_end) {
        var name = try parser.fieldName();
        defer name.deinit(parser.gpa);
        const bytes = name.slice();
        if (with_times and std.mem.eql(u8, bytes, "start_ns")) {
            try mark(&seen, 0);
            image.start_ns = try parser.integer(u64);
        } else if (with_times and std.mem.eql(u8, bytes, "end_ns")) {
            try mark(&seen, 1);
            image.end_ns = try parser.integer(u64);
        } else if (std.mem.eql(u8, bytes, "name")) {
            try mark(&seen, if (with_times) 2 else 0);
            const value = try parseByteString(parser, Process.max_name_len);
            defer parser.gpa.free(value);
            if (value.len == 0 or std.mem.indexOfScalar(u8, value, 0) != null) {
                return error.InvalidByteString;
            }
            @memcpy(image.name[0..value.len], value);
            image.name_len = @intCast(value.len);
        } else if (std.mem.eql(u8, bytes, "name_kind")) {
            try mark(&seen, if (with_times) 3 else 1);
            image.name_kind = try parseNameKind(parser);
        } else if (std.mem.eql(u8, bytes, "argv")) {
            try mark(&seen, if (with_times) 4 else 2);
            try parseArgvRef(parser, &image);
        } else if (std.mem.eql(u8, bytes, "exe")) {
            try mark(&seen, if (with_times) 5 else 3);
            const path = try parsePathRef(parser);
            image.exe_offset = path.ref;
            image.exe_source = path.source;
            image.exe_truncated = path.truncated;
        } else if (std.mem.eql(u8, bytes, "cwd")) {
            try mark(&seen, if (with_times) 6 else 4);
            const path = try parsePathRef(parser);
            image.cwd_offset = path.ref;
            image.cwd_source = path.source;
            image.cwd_truncated = path.truncated;
        } else {
            return error.UnknownField;
        }
    }
    try parser.expect(.object_end);
    const expected: u8 = if (with_times) (1 << 7) - 1 else (1 << 5) - 1;
    if (seen != expected) return error.InvariantViolated;
    return image;
}

fn parseNameKind(parser: *Parser) ReadError!Process.NameKind {
    var text = try parser.text(16);
    defer text.deinit(parser.gpa);
    if (std.mem.eql(u8, text.slice(), "process")) return .process;
    if (std.mem.eql(u8, text.slice(), "other")) return .other;
    return error.InvariantViolated;
}

fn parseArgvRef(parser: *Parser, image: *Process.Exec) ReadError!void {
    if (try parser.peek() == .null) {
        try parser.expect(.null);
        return;
    }
    var ref: ?usize = null;
    var source: ?Process.MetadataSource = null;
    var seen: u8 = 0;
    try parser.expect(.object_begin);
    while (try parser.peek() != .object_end) {
        var name = try parser.fieldName();
        defer name.deinit(parser.gpa);
        if (std.mem.eql(u8, name.slice(), "ref")) {
            try mark(&seen, 0);
            ref = try parser.integer(usize);
        } else if (std.mem.eql(u8, name.slice(), "source")) {
            try mark(&seen, 1);
            source = try parseMetadataSource(parser, true);
        } else {
            return error.UnknownField;
        }
    }
    try parser.expect(.object_end);
    if (seen != 0b11) return error.InvariantViolated;
    image.args_offset = ref.?;
    image.args_source = source.?;
}

const ParsedPath = struct {
    ref: usize = 0,
    source: Process.MetadataSource = .unavailable,
    truncated: bool = false,
};

fn parsePathRef(parser: *Parser) ReadError!ParsedPath {
    if (try parser.peek() == .null) {
        try parser.expect(.null);
        return .{};
    }
    var path = ParsedPath{};
    var seen: u8 = 0;
    try parser.expect(.object_begin);
    while (try parser.peek() != .object_end) {
        var name = try parser.fieldName();
        defer name.deinit(parser.gpa);
        if (std.mem.eql(u8, name.slice(), "ref")) {
            try mark(&seen, 0);
            path.ref = try parser.integer(usize);
        } else if (std.mem.eql(u8, name.slice(), "source")) {
            try mark(&seen, 1);
            path.source = try parseMetadataSource(parser, false);
        } else if (std.mem.eql(u8, name.slice(), "truncated")) {
            try mark(&seen, 2);
            path.truncated = try parser.boolean();
        } else {
            return error.UnknownField;
        }
    }
    try parser.expect(.object_end);
    if (seen != 0b111) return error.InvariantViolated;
    return path;
}

fn parseMetadataSource(parser: *Parser, argv: bool) ReadError!Process.MetadataSource {
    var text = try parser.text(32);
    defer text.deinit(parser.gpa);
    for (std.meta.tags(Process.MetadataSource)) |source| {
        if (source == .unavailable or (!argv and source == .launch)) continue;
        if (std.mem.eql(u8, text.slice(), @tagName(source))) return source;
    }
    return error.InvariantViolated;
}

fn parseCpuSlices(
    parser: *Parser,
    slices: *std.ArrayList(Process.CpuSlice),
) ReadError!void {
    try parser.expect(.array_begin);
    while (try parser.peek() != .array_end) {
        try parser.expect(.array_begin);
        const start_ns = try parser.integer(u64);
        const end_ns = try parser.integer(u64);
        const cpu_ns = try parser.integer(u64);
        if (try parser.peek() != .array_end) return error.InvariantViolated;
        try parser.expect(.array_end);
        try slices.append(parser.gpa, .{
            .start_ns = start_ns,
            .end_ns = end_ns,
            .cpu_ns = cpu_ns,
            .band = 0,
        });
    }
    try parser.expect(.array_end);
}

fn resolveProcessMetadata(
    session: *Session,
    tables: *const MetadataTables,
) ReadError!void {
    for (session.processes.items) |*process| {
        for (process.execs.items) |*exec| try resolveImageMetadata(exec, tables);
        var current = process.currentExec();
        try resolveImageMetadata(&current, tables);
        process.setCurrentExec(current);
    }
}

fn resolveImageMetadata(image: *Process.Exec, tables: *const MetadataTables) ReadError!void {
    if (image.args_source != .unavailable) {
        if (image.args_offset >= tables.argv.items.len) return error.InvariantViolated;
        const argv = tables.argv.items[image.args_offset];
        image.args_offset = argv.offset;
        image.args_len = argv.len;
        image.args_count = argv.count;
    }
    try resolvePathMetadata(
        &image.exe_offset,
        &image.exe_len,
        image.exe_source,
        tables.paths.items,
    );
    try resolvePathMetadata(
        &image.cwd_offset,
        &image.cwd_len,
        image.cwd_source,
        tables.paths.items,
    );
}

fn resolvePathMetadata(
    offset: *usize,
    len: *u16,
    source: Process.MetadataSource,
    paths: []const PathRange,
) ReadError!void {
    if (source == .unavailable) return;
    if (offset.* >= paths.len) return error.InvariantViolated;
    const path = paths[offset.*];
    offset.* = path.offset;
    len.* = @intCast(path.len);
}

fn parseByteString(parser: *Parser, max_len: usize) ReadError![]u8 {
    switch (try parser.peek()) {
        .string => {
            var text = try parser.text(max_len);
            defer text.deinit(parser.gpa);
            return text.toOwned(parser.gpa);
        },
        .object_begin => {},
        else => return error.InvalidJson,
    }

    try parser.expect(.object_begin);
    var name = try parser.fieldName();
    defer name.deinit(parser.gpa);
    if (!std.mem.eql(u8, name.slice(), "base64")) return error.UnknownField;
    const encoded_limit = std.base64.standard.Encoder.calcSize(max_len);
    var encoded = try parser.text(encoded_limit);
    defer encoded.deinit(parser.gpa);
    if (try parser.peek() != .object_end) return error.DuplicateField;
    try parser.expect(.object_end);

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded.slice()) catch
        return error.InvalidBase64;
    if (decoded_len > max_len) return error.ValueTooLong;
    const decoded = try parser.gpa.alloc(u8, decoded_len);
    errdefer parser.gpa.free(decoded);
    std.base64.standard.Decoder.decode(decoded, encoded.slice()) catch
        return error.InvalidBase64;
    return decoded;
}

fn mark(seen: anytype, bit: u4) ReadError!void {
    const mask = @as(@TypeOf(seen.*), 1) << @intCast(bit);
    if (seen.* & mask != 0) return error.DuplicateField;
    seen.* |= mask;
}

fn mapJsonError(err: anyerror) ReadError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ReadFailed => error.ReadFailed,
        error.ValueTooLong => error.ValueTooLong,
        error.SyntaxError, error.UnexpectedEndOfInput, error.EndOfStream => error.InvalidJson,
        else => error.InvalidJson,
    };
}

fn reasonForError(err: ReadError) Diagnostics.Reason {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.ReadFailed => .read_failed,
        error.InvalidJson, error.EndOfStream => .invalid_json,
        error.UnsupportedVersion => .unsupported_version,
        error.DuplicateField => .duplicate_field,
        error.UnknownField => .unknown_field,
        error.ValueTooLong => .value_too_long,
        error.InvalidBase64 => .invalid_base64,
        error.InvalidInteger => .invalid_integer,
        error.InvalidByteString => .invalid_byte_string,
        error.InvariantViolated => .invariant_violated,
    };
}

fn prepare(gpa: Allocator, session: *const Session) (Allocator.Error || ValidationError)!Tables {
    try validateSessionBoundary(session);
    var tables = Tables{ .metadata = session.metadata.items };
    errdefer tables.deinit(gpa);

    const target_argv = targetArgvRange(session);
    validateArgvRange(tables.metadata, target_argv) catch return error.InvalidTargetArgv;
    _ = try tables.internArgv(gpa, target_argv);

    var recovered_count: u64 = 0;
    for (session.processes.items, 0..) |process, index| {
        if (process.origin != .observed) recovered_count +|= 1;
        try validateProcess(&tables, gpa, session, &process, index);
    }
    if (recovered_count != session.recovered_count) return error.StaleDerivedCache;
    return tables;
}

fn validateSessionBoundary(session: *const Session) ValidationError!void {
    if (!session.finished) return error.SessionNotFinished;
    if (session.running or
        session.child != null or
        session.root_pid != null or
        session.active_count != 0 or
        session.by_pid.count() != 0 or
        session.processes.items.len == 0)
    {
        return error.InvalidSession;
    }
    if (session.host_cpu_count == 0 or session.sample_period_ns == 0) {
        return error.InvalidSession;
    }
    switch (session.capture_fidelity) {
        .exact, .snapshot_recovery => {},
        .unavailable => return error.UnsupportedCaptureFidelity,
    }
    switch (session.root_exit) {
        .unknown, .exited => {},
        .signaled => |signal| if (signal == 0) return error.InvalidSession,
    }
}

fn validateProcess(
    tables: *Tables,
    gpa: Allocator,
    session: *const Session,
    process: *const Process,
    index: usize,
) (Allocator.Error || ValidationError)!void {
    if (process.pid <= 0 or process.signal_slot != null) return error.InvalidSession;
    const end_ns = process.end_ns orelse return error.InvalidProcessInterval;
    if (process.start_ns > end_ns or end_ns > session.elapsed_ns) {
        return error.InvalidProcessInterval;
    }
    switch (process.end_kind) {
        .open => return error.InvalidProcessInterval,
        .observed_exit => {},
        .capture_clipped => if (process.cpu_final) return error.InvalidProcessInterval,
    }

    if (index == 0) {
        if (process.parent_index != null or
            process.parent_pid != null or
            process.depth != 0 or
            process.origin != .observed or
            process.start_ns != 0)
        {
            return error.InvalidProcessTopology;
        }
    } else {
        const parent_index = process.parent_index orelse
            return error.InvalidProcessTopology;
        if (parent_index >= index) return error.InvalidProcessTopology;
        const parent = session.processes.items[parent_index];
        const parent_end_ns = parent.end_ns orelse return error.InvalidProcessTopology;
        if (process.parent_pid != parent.pid or
            process.start_ns < parent.start_ns or
            process.start_ns > parent_end_ns)
        {
            return error.InvalidProcessTopology;
        }
        const expected_depth = std.math.add(u16, parent.depth, 1) catch
            return error.InvalidProcessTopology;
        if (process.depth != expected_depth) return error.StaleDerivedCache;
    }

    for (process.execs.items, 0..) |exec, stored_index| {
        if (exec.row_only and (index != 0 or stored_index != 0)) {
            return error.InvalidProcessImage;
        }
    }
    if (process.execCount() == 0) return error.InvalidExecInterval;

    const row = process.rowExec();
    try validateImage(tables, gpa, row);
    var previous_end_ns: ?u64 = null;
    for (0..process.execCount()) |exec_index| {
        const exec = process.execAt(exec_index);
        try validateImage(tables, gpa, exec);
        const exec_end_ns = exec.end_ns orelse return error.InvalidExecInterval;
        if (exec.start_ns < process.start_ns or
            exec.start_ns > exec_end_ns or
            exec_end_ns > end_ns or
            (previous_end_ns != null and previous_end_ns.? > exec.start_ns))
        {
            return error.InvalidExecInterval;
        }
        previous_end_ns = exec_end_ns;
    }
    if (previous_end_ns.? != end_ns) return error.InvalidExecInterval;

    const first_exec = process.execAt(0);
    if (!imageEql(tables.metadata, row, first_exec)) {
        if (index != 0 or
            row.args_source != .launch or
            row.exe_source != .unavailable or
            row.exe_len != 0 or
            !argvRangeEql(tables.metadata, argvRange(row), targetArgvRange(session)))
        {
            return error.InvalidProcessImage;
        }
    }

    try validateCpu(process, end_ns);
}

fn validateImage(
    tables: *Tables,
    gpa: Allocator,
    image: Process.Exec,
) (Allocator.Error || ValidationError)!void {
    if (image.name_len == 0 or image.name_len > Process.max_name_len) {
        return error.InvalidProcessImage;
    }
    switch (image.args_source) {
        .unavailable => {
            if (image.args_len != 0 or image.args_count != 0) return error.InvalidMetadata;
        },
        .launch, .kernel, .procfs, .process_inspection, .inherited => {
            const range = argvRange(image);
            try validateArgvRange(tables.metadata, range);
            _ = try tables.internArgv(gpa, range);
        },
    }
    try validateImagePath(
        tables,
        gpa,
        image.exe_offset,
        image.exe_len,
        image.exe_source,
    );
    try validateImagePath(
        tables,
        gpa,
        image.cwd_offset,
        image.cwd_len,
        image.cwd_source,
    );
}

fn validateImagePath(
    tables: *Tables,
    gpa: Allocator,
    offset: usize,
    len: u16,
    source: Process.MetadataSource,
) (Allocator.Error || ValidationError)!void {
    switch (source) {
        .unavailable => if (len != 0) return error.InvalidMetadata,
        .kernel, .procfs, .process_inspection, .inherited => {
            const range = PathRange{ .offset = offset, .len = len };
            try validatePathRange(tables.metadata, range);
            _ = try tables.internPath(gpa, range);
        },
        .launch => return error.InvalidMetadata,
    }
}

fn validateArgvRange(metadata: []const u8, range: ArgvRange) ValidationError!void {
    if (range.count == 0 or !rangeValid(metadata, range.offset, range.len)) {
        return error.InvalidMetadata;
    }
    const bytes = rangeBytes(metadata, range.offset, range.len);
    var position: usize = 0;
    var total: usize = 0;
    for (0..range.count) |index| {
        const end = std.mem.indexOfScalarPos(u8, bytes, position, 0) orelse end: {
            if (index + 1 != range.count or position == bytes.len) return error.InvalidMetadata;
            break :end bytes.len;
        };
        total = std.math.add(usize, total, end - position) catch
            return error.InvalidMetadata;
        total = std.math.add(usize, total, 1) catch return error.InvalidMetadata;
        if (total > max_argv_bytes) return error.InvalidMetadata;
        position = if (end < bytes.len) end + 1 else end;
    }
    if (position != bytes.len) return error.InvalidMetadata;
}

fn validatePathRange(metadata: []const u8, range: PathRange) ValidationError!void {
    if (range.len == 0 or
        range.len > Process.max_path_len or
        !rangeValid(metadata, range.offset, range.len))
    {
        return error.InvalidMetadata;
    }
}

fn validateCpu(process: *const Process, end_ns: u64) ValidationError!void {
    var total: u64 = 0;
    var peak: f64 = 0;
    var previous_end_ns: ?u64 = null;
    var previous_band: u8 = 0;
    for (process.cpu_slices.items) |slice| {
        if (slice.start_ns < process.start_ns or
            slice.end_ns > end_ns or
            slice.end_ns <= slice.start_ns or
            slice.cpu_ns == 0 or
            (previous_end_ns != null and previous_end_ns.? > slice.start_ns))
        {
            return error.InvalidCpuSlice;
        }
        const band = cpuBand(slice.cpu_ns, slice.end_ns - slice.start_ns);
        if (slice.band != band) return error.StaleDerivedCache;
        if (previous_end_ns == slice.start_ns and previous_band == band) {
            return error.InvalidCpuSlice;
        }
        total = std.math.add(u64, total, slice.cpu_ns) catch return error.InvalidCpuSlice;
        peak = @max(peak, slice.averageCores());
        previous_end_ns = slice.end_ns;
        previous_band = band;
    }
    if (total > process.cpu_time_ns) return error.InvalidCpuSlice;
    if (peak != process.cpu_peak_cores) return error.StaleDerivedCache;
}

fn writeRootExit(json: *std.json.Stringify, root_exit: Session.RootExit) !void {
    try json.beginObject();
    switch (root_exit) {
        .unknown => try field(json, "kind", "unknown"),
        .exited => |code| {
            try field(json, "kind", "exited");
            try field(json, "code", code);
        },
        .signaled => |signal| {
            try field(json, "kind", "signaled");
            try field(json, "signal", signal);
        },
    }
    try json.endObject();
}

fn writeCaptureEnvironment(
    json: *std.json.Stringify,
    environment: CaptureEnvironment,
) !void {
    try json.beginObject();
    try json.objectField("started_at_unix_seconds");
    try json.write(environment.started_at_unix_seconds);
    try json.objectField("flamez_version");
    if (environment.flamezVersion().len == 0) {
        try json.write(@as(?[]const u8, null));
    } else {
        try json.write(environment.flamezVersion());
    }
    try json.objectField("flamez_build_zig_version");
    if (environment.flamezBuildZigVersion().len == 0) {
        try json.write(@as(?[]const u8, null));
    } else {
        try json.write(environment.flamezBuildZigVersion());
    }
    try field(json, "os", @tagName(environment.host_os));
    try field(json, "architecture", @tagName(environment.architecture));
    try json.objectField("kernel_version");
    if (environment.kernelVersion().len == 0) {
        try json.write(@as(?[]const u8, null));
    } else {
        try json.write(environment.kernelVersion());
    }
    try json.endObject();
}

fn writeMetadata(json: *std.json.Stringify, tables: *const Tables) !void {
    try json.beginObject();
    try json.objectField("argv");
    try json.beginArray();
    for (tables.argv.items) |range| {
        try json.beginArray();
        var args = argvIter(tables.metadata, range);
        while (args.next()) |arg| try writeByteString(json, arg);
        try json.endArray();
    }
    try json.endArray();
    try json.objectField("paths");
    try json.beginArray();
    for (tables.paths.items) |range| {
        try writeByteString(json, rangeBytes(tables.metadata, range.offset, range.len));
    }
    try json.endArray();
    try json.endObject();
}

fn writeProcess(
    json: *std.json.Stringify,
    tables: *const Tables,
    process: *const Process,
    index: usize,
) !void {
    try json.beginObject();
    try field(json, "pid", process.pid);
    try json.objectField("parent");
    if (process.parent_index) |parent| {
        try json.write(parent);
    } else {
        try json.write(@as(?usize, null));
    }
    try field(json, "start_ns", process.start_ns);
    try field(json, "end_ns", process.end_ns.?);
    try field(json, "origin", @tagName(process.origin));
    try field(json, "end_kind", @tagName(process.end_kind));
    try json.objectField("row");
    const row = process.rowExec();
    if (imageEql(tables.metadata, row, process.execAt(0))) {
        try json.write("first_exec");
    } else {
        std.debug.assert(index == 0);
        try json.beginObject();
        try writeImageFields(json, tables, row);
        try json.endObject();
    }
    try json.objectField("execs");
    try json.beginArray();
    for (0..process.execCount()) |exec_index| {
        const exec = process.execAt(exec_index);
        try json.beginObject();
        try field(json, "start_ns", exec.start_ns);
        try field(json, "end_ns", exec.end_ns.?);
        try writeImageFields(json, tables, exec);
        try json.endObject();
    }
    try json.endArray();
    try field(json, "cpu_time_ns", process.cpu_time_ns);
    try field(json, "cpu_final", process.cpu_final);
    try json.objectField("slices");
    try json.beginArray();
    for (process.cpu_slices.items) |slice| {
        try json.beginArray();
        try json.write(slice.start_ns);
        try json.write(slice.end_ns);
        try json.write(slice.cpu_ns);
        try json.endArray();
    }
    try json.endArray();
    try json.endObject();
}

fn writeImageFields(
    json: *std.json.Stringify,
    tables: *const Tables,
    image: Process.Exec,
) !void {
    try json.objectField("name");
    try writeByteString(json, image.nameSlice());
    try field(json, "name_kind", @tagName(image.name_kind));
    try json.objectField("argv");
    if (image.args_source == .unavailable) {
        try json.write(@as(?usize, null));
    } else {
        try json.beginObject();
        try field(json, "ref", tables.argvRef(argvRange(image)));
        try field(json, "source", @tagName(image.args_source));
        try json.endObject();
    }
    try json.objectField("exe");
    try writePathRef(
        json,
        tables,
        image.exe_offset,
        image.exe_len,
        image.exe_source,
        image.exe_truncated,
    );
    try json.objectField("cwd");
    try writePathRef(
        json,
        tables,
        image.cwd_offset,
        image.cwd_len,
        image.cwd_source,
        image.cwd_truncated,
    );
}

fn writePathRef(
    json: *std.json.Stringify,
    tables: *const Tables,
    offset: usize,
    len: u16,
    source: Process.MetadataSource,
    truncated: bool,
) !void {
    if (source == .unavailable) {
        try json.write(@as(?usize, null));
        return;
    }
    try json.beginObject();
    try field(json, "ref", tables.pathRef(.{ .offset = offset, .len = len }));
    try field(json, "source", @tagName(source));
    try field(json, "truncated", truncated);
    try json.endObject();
}

fn writeByteString(json: *std.json.Stringify, bytes: []const u8) !void {
    if (std.unicode.utf8ValidateSlice(bytes)) {
        try json.write(bytes);
        return;
    }
    try json.beginObject();
    try json.objectField("base64");
    try json.beginWriteRaw();
    try json.writer.writeByte('"');
    try std.base64.standard.Encoder.encodeWriter(json.writer, bytes);
    try json.writer.writeByte('"');
    json.endWriteRaw();
    try json.endObject();
}

fn field(json: *std.json.Stringify, name: []const u8, value: anytype) !void {
    try json.objectField(name);
    try json.write(value);
}

fn targetArgvRange(session: *const Session) ArgvRange {
    return .{
        .offset = session.target_argv_offset,
        .len = session.target_argv_len,
        .count = session.target_argv_count,
    };
}

fn argvRange(image: Process.Exec) ArgvRange {
    return .{
        .offset = image.args_offset,
        .len = image.args_len,
        .count = image.args_count,
    };
}

fn argvIter(metadata: []const u8, range: ArgvRange) Process.ArgIter {
    return .{
        .bytes = rangeBytes(metadata, range.offset, range.len),
        .remaining = range.count,
    };
}

fn argvRangeEql(metadata: []const u8, lhs: ArgvRange, rhs: ArgvRange) bool {
    return (ArgvHash{ .metadata = metadata }).eql(lhs, rhs);
}

fn imageEql(metadata: []const u8, lhs: Process.Exec, rhs: Process.Exec) bool {
    return lhs.name_kind == rhs.name_kind and
        std.mem.eql(u8, lhs.nameSlice(), rhs.nameSlice()) and
        lhs.args_source == rhs.args_source and
        (lhs.args_source == .unavailable or
            argvRangeEql(metadata, argvRange(lhs), argvRange(rhs))) and
        lhs.exe_source == rhs.exe_source and
        lhs.exe_truncated == rhs.exe_truncated and
        std.mem.eql(u8, lhs.exeSlice(metadata), rhs.exeSlice(metadata)) and
        lhs.cwd_source == rhs.cwd_source and
        lhs.cwd_truncated == rhs.cwd_truncated and
        std.mem.eql(u8, lhs.cwdSlice(metadata), rhs.cwdSlice(metadata));
}

fn cpuBand(cpu_ns: u64, duration_ns: u64) u8 {
    const numerator = @as(u128, cpu_ns) * 4;
    const band = (numerator + duration_ns - 1) / duration_ns;
    return @intCast(@min(band, 64));
}

fn rangeValid(metadata: []const u8, offset: usize, len: usize) bool {
    return offset <= metadata.len and len <= metadata.len - offset;
}

fn rangeBytes(metadata: []const u8, offset: usize, len: usize) []const u8 {
    std.debug.assert(rangeValid(metadata, offset, len));
    return metadata[offset..][0..len];
}

fn finishedSession(
    gpa: Allocator,
    io: std.Io,
    argv: []const []const u8,
) Allocator.Error!Session {
    var session = Session.init(gpa, io);
    errdefer session.deinit();
    session.elapsed_ns = 100;
    session.root_exit = .{ .exited = 0 };
    session.host_cpu_count = 4;
    session.sample_period_ns = Session.default_cpu_sample_period_ns;
    session.environment = CaptureEnvironment.capture(io);
    session.capture_fidelity = .exact;

    var root = Process{
        .pid = 42,
        .end_ns = 100,
        .end_kind = .observed_exit,
        .cpu_final = true,
    };
    errdefer root.deinit(gpa);
    root.setName("tool", .process);
    try root.setArgsFromArgv(&session.metadata, gpa, argv);
    session.target_argv_offset = root.args_offset;
    session.target_argv_len = root.args_len;
    session.target_argv_count = root.args_count;
    try root.setCwd(&session.metadata, gpa, " /tmp/project\t");
    try root.recordCpuSnapshot(gpa, 100, 25);
    try session.processes.append(gpa, root);
    session.finished = true;
    return session;
}

fn appendChildWithEqualMetadata(session: *Session) Allocator.Error!void {
    var child = Process{
        .pid = 43,
        .parent_pid = 42,
        .parent_index = 0,
        .depth = 1,
        .start_ns = 10,
        .exec_start_ns = 10,
        .end_ns = 100,
        .end_kind = .observed_exit,
    };
    errdefer child.deinit(session.gpa);
    child.setName("child", .process);
    try child.setArgsFromKernel(&session.metadata, session.gpa, "tool\x00\x00");
    try child.setCwd(&session.metadata, session.gpa, " /tmp/project\t");
    try session.processes.append(session.gpa, child);
}

const minimal_fixture = @embedFile("testdata/session-v1-minimal.json");
const processes_first_fixture = @embedFile("testdata/session-v1-processes-first.json");
const exec_history_fixture = @embedFile("testdata/session-v1-exec-history.json");

fn changedFixture(
    gpa: Allocator,
    needle: []const u8,
    replacement: []const u8,
) Allocator.Error![]u8 {
    return changedBytes(gpa, minimal_fixture, needle, replacement);
}

fn changedBytes(
    gpa: Allocator,
    input: []const u8,
    needle: []const u8,
    replacement: []const u8,
) Allocator.Error![]u8 {
    std.debug.assert(std.mem.count(u8, input, needle) == 1);
    return std.mem.replaceOwned(u8, gpa, input, needle, replacement);
}

fn expectChangedFixtureError(
    expected: ReadError,
    reason: Diagnostics.Reason,
    needle: []const u8,
    replacement: []const u8,
) !void {
    const testing = std.testing;
    const changed = try changedFixture(testing.allocator, needle, replacement);
    defer testing.allocator.free(changed);
    var input: std.Io.Reader = .fixed(changed);
    var diagnostics: Diagnostics = .{};
    try testing.expectError(
        expected,
        read(testing.allocator, testing.io, &input, &diagnostics),
    );
    try testing.expectEqual(reason, diagnostics.reason);
}

test "writer emits compact finished session and interns equal metadata" {
    const testing = std.testing;
    var session = try finishedSession(testing.allocator, testing.io, &.{ "tool", "" });
    defer session.deinit();
    try appendChildWithEqualMetadata(&session);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try write(testing.allocator, &session, &output.writer);
    const json = output.written();

    try testing.expect(std.mem.startsWith(u8, json, "{\"flamez\":1,"));
    try testing.expect(std.mem.indexOf(u8, json, "\"environment\":{") != null);
    try testing.expect(std.mem.endsWith(u8, json, "}\n"));
    try testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"argv\":[[\"tool\",\"\"]],\"paths\":[\" /tmp/project\\t\"]",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"argv\":{\"ref\":0,\"source\":\"kernel\"}",
    ) != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, json, " /tmp/project"));
    try testing.expect(std.mem.indexOf(u8, json, "\"slices\":[[0,100,25]]") != null);
}

test "writer preserves a distinct root launch row" {
    const testing = std.testing;
    var session = try finishedSession(testing.allocator, testing.io, &.{ "tool", "build" });
    defer session.deinit();
    const root = &session.processes.items[0];
    try root.retainCurrentExecForRow(testing.allocator);
    root.setName("execed", .process);
    root.clearExecMetadata();
    try root.setArgsFromKernel(&session.metadata, testing.allocator, "execed\x00build\x00");

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try write(testing.allocator, &session, &output.writer);
    const json = output.written();

    try testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"row\":{\"name\":\"tool\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"execs\":[{\"start_ns\":0,\"end_ns\":100,\"name\":\"execed\"",
    ) != null);
}

test "writer uses base64 for non-UTF-8 bytes" {
    const testing = std.testing;
    var session = try finishedSession(testing.allocator, testing.io, &.{ "tool", "\xffbin" });
    defer session.deinit();
    session.processes.items[0].setName("\xffbin", .process);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try write(testing.allocator, &session, &output.writer);

    try testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "{\"base64\":\"/2Jpbg==\"}",
    ) != null);
}

test "writer validation failure emits no bytes" {
    const testing = std.testing;
    var session = try finishedSession(testing.allocator, testing.io, &.{"tool"});
    defer session.deinit();
    session.finished = false;

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try testing.expectError(
        error.SessionNotFinished,
        write(testing.allocator, &session, &output.writer),
    );
    try testing.expectEqual(@as(usize, 0), output.written().len);
}

test "writer accepts a CPU sample observed after the process exit boundary" {
    const testing = std.testing;
    var session = try finishedSession(testing.allocator, testing.io, &.{"tool"});
    defer session.deinit();
    const root = &session.processes.items[0];
    root.end_ns = null;
    root.end_kind = .open;
    try root.recordCpuSnapshot(testing.allocator, 120, 50);
    try testing.expect(root.finish(100, .observed_exit));

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try write(testing.allocator, &session, &output.writer);
    try testing.expect(output.written().len != 0);
}

fn writeWithAllocator(gpa: Allocator, session: *const Session) !void {
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try write(gpa, session, &writer);
}

test "writer allocation failures release scratch storage" {
    const testing = std.testing;
    var session = try finishedSession(testing.allocator, testing.io, &.{ "tool", "build" });
    defer session.deinit();
    try testing.checkAllAllocationFailures(
        testing.allocator,
        writeWithAllocator,
        .{&session},
    );
}

test "reader round trip preserves canonical session fields" {
    const testing = std.testing;
    var original = try finishedSession(testing.allocator, testing.io, &.{ "tool", "" });
    defer original.deinit();
    try appendChildWithEqualMetadata(&original);
    original.loss_count = 3;
    original.root_exit = .{ .signaled = 9 };

    var first_output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer first_output.deinit();
    try write(testing.allocator, &original, &first_output.writer);

    var input: std.Io.Reader = .fixed(first_output.written());
    var diagnostics: Diagnostics = .{};
    var imported = try read(
        testing.allocator,
        testing.io,
        &input,
        &diagnostics,
    );
    defer imported.deinit();

    try testing.expect(imported.finished);
    try testing.expect(!imported.running);
    try testing.expectEqual(original.loss_count, imported.loss_count);
    try testing.expectEqual(original.root_exit, imported.root_exit);
    try testing.expectEqual(original.capture_fidelity, imported.capture_fidelity);
    try testing.expectEqual(original.sample_period_ns, imported.sample_period_ns);
    try testing.expectEqual(original.host_cpu_count, imported.host_cpu_count);
    try testing.expectEqual(
        original.environment.started_at_unix_seconds,
        imported.environment.started_at_unix_seconds,
    );
    try testing.expectEqualStrings(
        original.environment.kernelVersion(),
        imported.environment.kernelVersion(),
    );
    try testing.expectEqualStrings(
        original.environment.flamezBuildZigVersion(),
        imported.environment.flamezBuildZigVersion(),
    );
    try testing.expectEqual(original.elapsed_ns, imported.elapsed_ns);
    try testing.expectEqual(original.processes.items.len, imported.processes.items.len);
    var target_argv = imported.targetArgvIter();
    try testing.expectEqualStrings("tool", target_argv.next().?);
    try testing.expectEqualStrings("", target_argv.next().?);
    try testing.expect(target_argv.next() == null);
    try testing.expectEqualStrings(
        " /tmp/project\t",
        imported.processes.items[0].cwdSlice(imported.metadata.items),
    );
    try testing.expectEqual(@as(u64, 25), imported.processes.items[0].cpu_time_ns);
    try testing.expectEqual(@as(u8, 1), imported.processes.items[0].cpu_slices.items[0].band);
    try testing.expectEqual(@as(u16, 1), imported.processes.items[1].depth);
    try testing.expectEqual(@as(std.posix.pid_t, 42), imported.processes.items[1].parent_pid.?);

    var second_output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer second_output.deinit();
    try write(testing.allocator, &imported, &second_output.writer);
    try testing.expectEqualStrings(first_output.written(), second_output.written());
}

test "round trip preserves process inspection truncation partial CPU and recovery" {
    const testing = std.testing;
    var original = try finishedSession(testing.allocator, testing.io, &.{ "tool", "build" });
    defer original.deinit();
    original.capture_fidelity = .snapshot_recovery;
    const root = &original.processes.items[0];
    root.cpu_final = false;
    try root.setArgsFromProcessInspection(
        &original.metadata,
        testing.allocator,
        "inspected\x00\x00build\x00",
    );
    try root.setExeFromProcessInspection(
        &original.metadata,
        testing.allocator,
        " /usr/bin/inspected ",
    );
    const long_cwd = try testing.allocator.alloc(u8, Process.max_path_len + 1);
    defer testing.allocator.free(long_cwd);
    @memset(long_cwd, 'p');
    try root.setCwdFromProcessInspection(&original.metadata, testing.allocator, long_cwd);
    try appendChildWithEqualMetadata(&original);
    original.processes.items[1].origin = .recovered_exec;
    original.recovered_count = 1;

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try write(testing.allocator, &original, &output.writer);
    var input: std.Io.Reader = .fixed(output.written());
    var diagnostics: Diagnostics = .{};
    var imported = try read(testing.allocator, testing.io, &input, &diagnostics);
    defer imported.deinit();

    const imported_root = imported.processes.items[0];
    try testing.expectEqual(capture.Fidelity.snapshot_recovery, imported.capture_fidelity);
    try testing.expect(imported.isIncomplete());
    try testing.expectEqual(@as(u64, 1), imported.recovered_count);
    try testing.expect(!imported_root.cpu_final);
    try testing.expectEqual(
        Process.MetadataSource.process_inspection,
        imported_root.args_source,
    );
    try testing.expectEqual(
        Process.MetadataSource.process_inspection,
        imported_root.exe_source,
    );
    try testing.expectEqualStrings(
        " /usr/bin/inspected ",
        imported_root.exeSlice(imported.metadata.items),
    );
    try testing.expectEqual(@as(usize, Process.max_path_len), imported_root.cwd_len);
    try testing.expect(imported_root.cwd_truncated);
}

test "reader preserves a distinct root launch row and exec image" {
    const testing = std.testing;
    var original = try finishedSession(testing.allocator, testing.io, &.{ "tool", "build" });
    defer original.deinit();
    const root = &original.processes.items[0];
    try root.retainCurrentExecForRow(testing.allocator);
    root.setName("execed", .process);
    root.clearExecMetadata();
    try root.setArgsFromKernel(&original.metadata, testing.allocator, "execed\x00build\x00");

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try write(testing.allocator, &original, &output.writer);
    var input: std.Io.Reader = .fixed(output.written());
    var diagnostics: Diagnostics = .{};
    var imported = try read(testing.allocator, testing.io, &input, &diagnostics);
    defer imported.deinit();

    const imported_root = &imported.processes.items[0];
    try testing.expectEqual(@as(usize, 1), imported_root.execs.items.len);
    try testing.expect(imported_root.execs.items[0].row_only);
    try testing.expectEqualStrings("tool", imported_root.rowNameSlice());
    try testing.expectEqualStrings("execed", imported_root.nameSlice());
    var command: [32]u8 = undefined;
    try testing.expectEqualStrings(
        "tool build",
        imported_root.rowExec().copyCmdline(imported.metadata.items, &command),
    );
    try testing.expectEqualStrings(
        "execed build",
        imported_root.currentExec().copyCmdline(imported.metadata.items, &command),
    );
}

test "reader rejects an unsupported version before its body" {
    const testing = std.testing;
    var input: std.Io.Reader = .fixed("{\"flamez\":2,\"body\":[1,2,3]}");
    var diagnostics: Diagnostics = .{};
    try testing.expectError(
        error.UnsupportedVersion,
        read(testing.allocator, testing.io, &input, &diagnostics),
    );
    try testing.expectEqual(Diagnostics.Reason.unsupported_version, diagnostics.reason);
    try testing.expect(diagnostics.byte_offset < 20);
}

test "reader requires the v1 capture environment" {
    const testing = std.testing;
    const without_environment = try changedBytes(
        testing.allocator,
        minimal_fixture,
        "\"environment\":{\"started_at_unix_seconds\":1788200580," ++
            "\"flamez_version\":\"0.0.0\",\"flamez_build_zig_version\":\"0.16.0\"," ++
            "\"os\":\"linux\",\"architecture\":\"x86_64\"," ++
            "\"kernel_version\":\"6.18.0\"},",
        "",
    );
    defer testing.allocator.free(without_environment);
    var input: std.Io.Reader = .fixed(without_environment);
    var diagnostics: Diagnostics = .{};
    try testing.expectError(
        error.InvariantViolated,
        read(testing.allocator, testing.io, &input, &diagnostics),
    );
    try testing.expectEqual(Diagnostics.Reason.invariant_violated, diagnostics.reason);
}

test "committed v1 fixtures stream into finished sessions" {
    const testing = std.testing;
    inline for (.{ minimal_fixture, processes_first_fixture, exec_history_fixture }) |fixture| {
        var input: std.Io.Reader = .fixed(fixture);
        var diagnostics: Diagnostics = .{};
        var session = try read(testing.allocator, testing.io, &input, &diagnostics);
        defer session.deinit();

        try testing.expect(session.finished);
        try testing.expectEqual(@as(usize, 1), session.processes.items.len);
        var target_argv = session.targetArgvIter();
        try testing.expect(target_argv.next() != null);
    }
}

test "committed exec-history fixture preserves its launch row and real images" {
    const testing = std.testing;
    var input: std.Io.Reader = .fixed(exec_history_fixture);
    var diagnostics: Diagnostics = .{};
    var session = try read(testing.allocator, testing.io, &input, &diagnostics);
    defer session.deinit();

    const root = session.processes.items[0];
    try testing.expectEqual(@as(usize, 2), root.execCount());
    try testing.expectEqualStrings("sh", root.rowNameSlice());
    try testing.expectEqualStrings("dash", root.execAt(0).nameSlice());
    try testing.expectEqualStrings("clang", root.execAt(1).nameSlice());
    try testing.expectEqualStrings(
        "/home/user/src",
        root.cwdSlice(session.metadata.items),
    );
    try testing.expectEqual(@as(u64, 200000), root.cpu_time_ns);
    try testing.expect(root.cpu_final);
    try testing.expectEqual(@as(usize, 1), root.cpu_slices.items.len);
    try testing.expectEqual(@as(u8, 1), root.cpu_slices.items[0].band);
    var target_argv = session.targetArgvIter();
    try testing.expectEqualStrings("sh", target_argv.next().?);
    try testing.expectEqualStrings("-c", target_argv.next().?);
    try testing.expectEqualStrings("exec clang -c source.c", target_argv.next().?);
    try testing.expect(target_argv.next() == null);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try write(testing.allocator, &session, &output.writer);
    var round_trip_input: std.Io.Reader = .fixed(output.written());
    var round_trip = try read(
        testing.allocator,
        testing.io,
        &round_trip_input,
        &diagnostics,
    );
    defer round_trip.deinit();
    try testing.expectEqual(@as(usize, 2), round_trip.processes.items[0].execCount());
    try testing.expectEqualStrings("sh", round_trip.processes.items[0].rowNameSlice());
}

test "reader accepts zero-width execs and gaps but rejects overlap" {
    const testing = std.testing;
    const first_zero = try changedBytes(
        testing.allocator,
        exec_history_fixture,
        "\"start_ns\":0,\"end_ns\":10000000,\"name\":\"dash\"",
        "\"start_ns\":0,\"end_ns\":0,\"name\":\"dash\"",
    );
    defer testing.allocator.free(first_zero);
    const zero_width = try changedBytes(
        testing.allocator,
        first_zero,
        "\"start_ns\":10000000,\"end_ns\":15000000,\"name\":\"clang\"",
        "\"start_ns\":0,\"end_ns\":15000000,\"name\":\"clang\"",
    );
    defer testing.allocator.free(zero_width);
    var zero_input: std.Io.Reader = .fixed(zero_width);
    var diagnostics: Diagnostics = .{};
    var zero_session = try read(
        testing.allocator,
        testing.io,
        &zero_input,
        &diagnostics,
    );
    defer zero_session.deinit();
    try testing.expectEqual(@as(u64, 0), zero_session.processes.items[0].execAt(0).end_ns.?);

    const gap = try changedBytes(
        testing.allocator,
        exec_history_fixture,
        "\"start_ns\":0,\"end_ns\":10000000,\"name\":\"dash\"",
        "\"start_ns\":0,\"end_ns\":5000000,\"name\":\"dash\"",
    );
    defer testing.allocator.free(gap);
    var gap_input: std.Io.Reader = .fixed(gap);
    var gap_session = try read(testing.allocator, testing.io, &gap_input, &diagnostics);
    defer gap_session.deinit();
    try testing.expectEqual(
        @as(u64, 5000000),
        gap_session.processes.items[0].execAt(0).end_ns.?,
    );

    const overlap = try changedBytes(
        testing.allocator,
        exec_history_fixture,
        "\"start_ns\":10000000,\"end_ns\":15000000,\"name\":\"clang\"",
        "\"start_ns\":9000000,\"end_ns\":15000000,\"name\":\"clang\"",
    );
    defer testing.allocator.free(overlap);
    var overlap_input: std.Io.Reader = .fixed(overlap);
    try testing.expectError(
        error.InvariantViolated,
        read(testing.allocator, testing.io, &overlap_input, &diagnostics),
    );
}

test "reader enforces retained launch row constraints" {
    const testing = std.testing;
    const wrong_source = try changedBytes(
        testing.allocator,
        exec_history_fixture,
        "\"argv\":{\"ref\":0,\"source\":\"launch\"},\"exe\":null",
        "\"argv\":{\"ref\":0,\"source\":\"kernel\"},\"exe\":null",
    );
    defer testing.allocator.free(wrong_source);
    var source_input: std.Io.Reader = .fixed(wrong_source);
    var diagnostics: Diagnostics = .{};
    try testing.expectError(
        error.InvariantViolated,
        read(testing.allocator, testing.io, &source_input, &diagnostics),
    );

    const wrong_ref = try changedBytes(
        testing.allocator,
        exec_history_fixture,
        "\"argv\":{\"ref\":0,\"source\":\"launch\"},\"exe\":null",
        "\"argv\":{\"ref\":1,\"source\":\"launch\"},\"exe\":null",
    );
    defer testing.allocator.free(wrong_ref);
    var ref_input: std.Io.Reader = .fixed(wrong_ref);
    try testing.expectError(
        error.InvariantViolated,
        read(testing.allocator, testing.io, &ref_input, &diagnostics),
    );
}

test "reader rejects noncanonical adjacent CPU slices" {
    const testing = std.testing;
    const changed = try changedBytes(
        testing.allocator,
        exec_history_fixture,
        "\"slices\":[[0,15000000,200000]]",
        "\"slices\":[[0,7500000,100000],[7500000,15000000,100000]]",
    );
    defer testing.allocator.free(changed);
    var input: std.Io.Reader = .fixed(changed);
    var diagnostics: Diagnostics = .{};
    try testing.expectError(
        error.InvariantViolated,
        read(testing.allocator, testing.io, &input, &diagnostics),
    );
}

test "minimal committed fixture retains its exact target command" {
    const testing = std.testing;
    var input: std.Io.Reader = .fixed(minimal_fixture);
    var diagnostics: Diagnostics = .{};
    var session = try read(testing.allocator, testing.io, &input, &diagnostics);
    defer session.deinit();
    try testing.expectEqualStrings("true", session.processes.items[0].nameSlice());
    var target_argv = session.targetArgvIter();
    try testing.expectEqualStrings("true", target_argv.next().?);
    try testing.expect(target_argv.next() == null);
}

test "reader accepts every top-level field after processes before metadata" {
    const testing = std.testing;
    var input: std.Io.Reader = .fixed(processes_first_fixture);
    var diagnostics: Diagnostics = .{};
    var session = try read(testing.allocator, testing.io, &input, &diagnostics);
    defer session.deinit();

    try testing.expectEqual(capture.Fidelity.snapshot_recovery, session.capture_fidelity);
    try testing.expect(!session.isIncomplete());
    try testing.expectEqual(Session.RootExit.unknown, session.root_exit);
}

test "reader handles escaped and base64 metadata one byte at a time" {
    const testing = std.testing;
    var original = try finishedSession(testing.allocator, testing.io, &.{ "tool", "\xffbin" });
    defer original.deinit();
    original.processes.items[0].setName("\xffbin", .process);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try write(testing.allocator, &original, &output.writer);

    var tiny_buffer: [1]u8 = undefined;
    var tiny_reader: std.testing.Reader = .init(&tiny_buffer, &.{
        .{ .buffer = output.written() },
    });
    tiny_reader.artificial_limit = .limited(1);
    var diagnostics: Diagnostics = .{};
    var imported = try read(
        testing.allocator,
        testing.io,
        &tiny_reader.interface,
        &diagnostics,
    );
    defer imported.deinit();

    try testing.expectEqualStrings("\xffbin", imported.processes.items[0].nameSlice());
    try testing.expectEqualStrings(
        " /tmp/project\t",
        imported.processes.items[0].cwdSlice(imported.metadata.items),
    );
}

test "reader accepts an argument larger than the JSON default token limit" {
    const testing = std.testing;
    const large_len = 4 * 1024 * 1024 + 1;
    const large_argument = try testing.allocator.alloc(u8, large_len);
    defer testing.allocator.free(large_argument);
    @memset(large_argument, 'x');

    var original = try finishedSession(
        testing.allocator,
        testing.io,
        &.{ "tool", large_argument },
    );
    defer original.deinit();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try write(testing.allocator, &original, &output.writer);

    var input: std.Io.Reader = .fixed(output.written());
    var diagnostics: Diagnostics = .{};
    var imported = try read(testing.allocator, testing.io, &input, &diagnostics);
    defer imported.deinit();
    var argv = imported.targetArgvIter();
    try testing.expectEqualStrings("tool", argv.next().?);
    try testing.expectEqual(large_len, argv.next().?.len);
    try testing.expect(argv.next() == null);
}

test "reader and writer share one interned metadata block across many processes" {
    const testing = std.testing;
    var original = try finishedSession(testing.allocator, testing.io, &.{ "tool", "" });
    defer original.deinit();
    for (0..1000) |_| try appendChildWithEqualMetadata(&original);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try write(testing.allocator, &original, &output.writer);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.written(), " /tmp/project"));

    var input: std.Io.Reader = .fixed(output.written());
    var diagnostics: Diagnostics = .{};
    var imported = try read(testing.allocator, testing.io, &input, &diagnostics);
    defer imported.deinit();
    try testing.expectEqual(@as(usize, 1001), imported.processes.items.len);
    try testing.expectEqual(@as(usize, 20), imported.metadata.items.len);
}

test "reader rejects invalid root exit payloads" {
    try expectChangedFixtureError(
        error.InvariantViolated,
        .invariant_violated,
        "{\"kind\":\"exited\",\"code\":0}",
        "{\"kind\":\"exited\",\"code\":0,\"signal\":9}",
    );
    try expectChangedFixtureError(
        error.InvariantViolated,
        .invariant_violated,
        "{\"kind\":\"exited\",\"code\":0}",
        "{\"kind\":\"signaled\",\"signal\":0}",
    );
    try expectChangedFixtureError(
        error.InvalidInteger,
        .invalid_integer,
        "{\"kind\":\"exited\",\"code\":0}",
        "{\"kind\":\"exited\",\"code\":256}",
    );
}

test "reader rejects malformed metadata and invalid references" {
    try expectChangedFixtureError(
        error.InvalidBase64,
        .invalid_base64,
        "\"name\":\"true\"",
        "\"name\":{\"base64\":\"%%%\"}",
    );
    try expectChangedFixtureError(
        error.InvariantViolated,
        .invariant_violated,
        "{\"ref\":0,\"source\":\"launch\"}",
        "{\"ref\":1,\"source\":\"launch\"}",
    );
    try expectChangedFixtureError(
        error.InvariantViolated,
        .invariant_violated,
        "\"capture_fidelity\":\"exact\"",
        "\"capture_fidelity\":\"unavailable\"",
    );
}

test "reader rejects invalid topology exec intervals and CPU slices" {
    try expectChangedFixtureError(
        error.InvariantViolated,
        .invariant_violated,
        "\"pid\":1,\"parent\":null",
        "\"pid\":1,\"parent\":0",
    );
    try expectChangedFixtureError(
        error.InvariantViolated,
        .invariant_violated,
        "\"start_ns\":0,\"end_ns\":1,\"name\"",
        "\"start_ns\":0,\"end_ns\":0,\"name\"",
    );
    try expectChangedFixtureError(
        error.InvariantViolated,
        .invariant_violated,
        "\"slices\":[]",
        "\"slices\":[[0,1,0]]",
    );
    try expectChangedFixtureError(
        error.InvariantViolated,
        .invariant_violated,
        "\"row\":\"first_exec\"",
        "\"row\":\"unknown\"",
    );
    try expectChangedFixtureError(
        error.InvariantViolated,
        .invariant_violated,
        "\"execs\":[{\"start_ns\":0,\"end_ns\":1,\"name\":\"true\"," ++
            "\"name_kind\":\"process\",\"argv\":{\"ref\":0,\"source\":\"launch\"}," ++
            "\"exe\":null,\"cwd\":null}]",
        "\"execs\":[]",
    );
    try expectChangedFixtureError(
        error.InvariantViolated,
        .invariant_violated,
        "\"end_kind\":\"observed_exit\"",
        "\"end_kind\":\"capture_clipped\"",
    );
}

test "reader accepts capture-clipped partial CPU" {
    const testing = std.testing;
    const clipped = try changedFixture(
        testing.allocator,
        "\"end_kind\":\"observed_exit\"",
        "\"end_kind\":\"capture_clipped\"",
    );
    defer testing.allocator.free(clipped);
    const partial = try changedBytes(
        testing.allocator,
        clipped,
        "\"cpu_final\":true",
        "\"cpu_final\":false",
    );
    defer testing.allocator.free(partial);
    var input: std.Io.Reader = .fixed(partial);
    var diagnostics: Diagnostics = .{};
    var session = try read(testing.allocator, testing.io, &input, &diagnostics);
    defer session.deinit();
    try testing.expectEqual(Process.EndKind.capture_clipped, session.processes.items[0].end_kind);
    try testing.expect(!session.processes.items[0].cpu_final);
}

test "reader rejects a repeated version field and trailing JSON" {
    try expectChangedFixtureError(
        error.DuplicateField,
        .duplicate_field,
        "\"loss_count\":0",
        "\"flamez\":1,\"loss_count\":0",
    );

    const testing = std.testing;
    var trailing: std.Io.Reader = .fixed(minimal_fixture ++ "{}");
    var diagnostics: Diagnostics = .{};
    try testing.expectError(
        error.InvalidJson,
        read(testing.allocator, testing.io, &trailing, &diagnostics),
    );
    try testing.expectEqual(Diagnostics.Reason.invalid_json, diagnostics.reason);
}

test "reader rejects duplicate and unknown top-level fields" {
    const testing = std.testing;
    var duplicate_input: std.Io.Reader = .fixed(
        "{\"flamez\":1,\"loss_count\":0,\"loss_count\":0}",
    );
    var diagnostics: Diagnostics = .{};
    try testing.expectError(
        error.DuplicateField,
        read(testing.allocator, testing.io, &duplicate_input, &diagnostics),
    );
    try testing.expectEqual(Diagnostics.Reason.duplicate_field, diagnostics.reason);

    var unknown_input: std.Io.Reader = .fixed("{\"flamez\":1,\"typo\":0}");
    try testing.expectError(
        error.UnknownField,
        read(testing.allocator, testing.io, &unknown_input, &diagnostics),
    );
    try testing.expectEqual(Diagnostics.Reason.unknown_field, diagnostics.reason);
}

fn readWithAllocator(gpa: Allocator, io: std.Io, bytes: []const u8) !void {
    var input: std.Io.Reader = .fixed(bytes);
    var diagnostics: Diagnostics = .{};
    var session = try read(gpa, io, &input, &diagnostics);
    defer session.deinit();
}

test "reader allocation failures release session and token storage" {
    const testing = std.testing;
    var session = try finishedSession(testing.allocator, testing.io, &.{ "tool", "build" });
    defer session.deinit();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try write(testing.allocator, &session, &output.writer);

    try testing.checkAllAllocationFailures(
        testing.allocator,
        readWithAllocator,
        .{ testing.io, output.written() },
    );
}

test "file APIs install exclusively, replace atomically, and stream read" {
    const testing = std.testing;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/capture.json",
        .{temporary.sub_path[0..]},
    );
    var session = try finishedSession(testing.allocator, testing.io, &.{ "tool", "build" });
    defer session.deinit();

    try writeFile(testing.allocator, testing.io, &session, path, .{});
    try testing.expectError(
        error.PathAlreadyExists,
        writeFile(testing.allocator, testing.io, &session, path, .{}),
    );

    var diagnostics: Diagnostics = .{};
    var imported = try readFile(
        testing.allocator,
        testing.io,
        path,
        &diagnostics,
    );
    defer imported.deinit();
    try testing.expectEqual(@as(u64, 0), imported.loss_count);

    session.loss_count = 7;
    try writeFile(testing.allocator, testing.io, &session, path, .{
        .install = .replace,
    });
    var replaced = try readFile(
        testing.allocator,
        testing.io,
        path,
        &diagnostics,
    );
    defer replaced.deinit();
    try testing.expectEqual(@as(u64, 7), replaced.loss_count);

    session.finished = false;
    try testing.expectError(
        error.SessionNotFinished,
        writeFile(testing.allocator, testing.io, &session, path, .{
            .install = .replace,
        }),
    );
    var preserved = try readFile(
        testing.allocator,
        testing.io,
        path,
        &diagnostics,
    );
    defer preserved.deinit();
    try testing.expectEqual(@as(u64, 7), preserved.loss_count);

    var iterable_dir = try temporary.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer iterable_dir.close(testing.io);
    var directory_buffer: [std.Io.Dir.Reader.min_buffer_len]u8 align(@alignOf(usize)) = undefined;
    var directory_reader = std.Io.Dir.Reader.init(iterable_dir, &directory_buffer);
    var entry_count: usize = 0;
    while (try directory_reader.next(testing.io)) |entry| {
        entry_count += 1;
        try testing.expectEqualStrings("capture.json", entry.name);
    }
    try testing.expectEqual(@as(usize, 1), entry_count);
}
