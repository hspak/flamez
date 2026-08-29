//! Process-tree row construction, collapse behavior, and packed-lane assignment.

const std = @import("std");

const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const perf = @import("perf.zig");
const tracer = @import("tracer.zig");

pub fn ensureProcessTree(
    app: *App,
    session: *const tracer.Session,
) Allocator.Error!void {
    const topology_stale = app.topology_revision_seen != session.topology_revision;
    const collapse_stale = app.collapse_revision_seen != app.collapse_revision;
    const pack_stale = topology_stale or collapse_stale or
        (!session.running and app.interval_revision_seen != session.interval_revision);
    if (!topology_stale and !collapse_stale and !pack_stale) return;
    perf.enter(.tree_rebuild);
    defer perf.leave();
    try rebuildProcessTree(app, session);
    app.topology_revision_seen = session.topology_revision;
    app.interval_revision_seen = session.interval_revision;
    app.collapse_revision_seen = app.collapse_revision;
}

fn rebuildProcessTree(
    app: *App,
    session: *const tracer.Session,
) Allocator.Error!void {
    const n = session.processes.items.len;
    try app.first_child.ensureTotalCapacity(app.gpa, n);
    try app.next_sibling.ensureTotalCapacity(app.gpa, n);
    try app.visual_depth.ensureTotalCapacity(app.gpa, n);
    try app.pack_slot.ensureTotalCapacity(app.gpa, n);
    try app.slot_next.ensureTotalCapacity(app.gpa, n);
    try app.lane_height_off.ensureTotalCapacity(app.gpa, n);
    try app.last_child_scratch.ensureTotalCapacity(app.gpa, n);
    try app.bar_name_widths.ensureTotalCapacity(app.gpa, n);
    try app.bar_name_hashes.ensureTotalCapacity(app.gpa, n);
    if (app.bar_name_widths.items.len < n) {
        const old_len = app.bar_name_widths.items.len;
        try app.bar_name_widths.resize(app.gpa, n);
        @memset(app.bar_name_widths.items[old_len..], -1);
        try app.bar_name_hashes.resize(app.gpa, n);
        @memset(app.bar_name_hashes.items[old_len..], 0);
    }
    if (app.collapsed.items.len < n) {
        try app.collapsed.ensureTotalCapacity(app.gpa, n);
    }

    app.row_order.clearRetainingCapacity();
    app.first_child.clearRetainingCapacity();
    app.next_sibling.clearRetainingCapacity();
    app.visual_depth.clearRetainingCapacity();
    app.pack_slot.clearRetainingCapacity();
    app.slot_next.clearRetainingCapacity();
    app.packed_members.clearRetainingCapacity();
    app.lane_height_off.clearRetainingCapacity();
    app.lane_heights.clearRetainingCapacity();
    app.last_child_scratch.clearRetainingCapacity();
    app.roots_scratch.clearRetainingCapacity();
    if (n == 0) return;
    app.first_child.appendNTimesAssumeCapacity(null, n);
    app.next_sibling.appendNTimesAssumeCapacity(null, n);
    app.visual_depth.appendNTimesAssumeCapacity(0, n);
    app.pack_slot.appendNTimesAssumeCapacity(0, n);
    app.slot_next.appendNTimesAssumeCapacity(null, n);
    app.lane_height_off.appendNTimesAssumeCapacity(0, n);
    app.last_child_scratch.appendNTimesAssumeCapacity(null, n);
    if (app.collapsed.items.len < n) {
        app.collapsed.appendNTimesAssumeCapacity(false, n - app.collapsed.items.len);
    }

    // Parent identity is Process.parent_index; Flamez does not retain a
    // parallel visual-parent array. pack_root/pack_job/slot_count are derived
    // from the packed row model and are not stored.
    for (0..n) |index| {
        const process = &session.processes.items[index];
        if (process.parent_index) |parent| {
            app.visual_depth.items[index] = app.visual_depth.items[parent] + 1;
            if (app.first_child.items[parent] == null) {
                app.first_child.items[parent] = index;
            } else if (app.last_child_scratch.items[parent]) |prev| {
                app.next_sibling.items[prev] = index;
            }
            app.last_child_scratch.items[parent] = index;
        } else {
            try app.roots_scratch.append(app.gpa, index);
        }
    }

    const now_ns = session.timelineNs();
    for (app.roots_scratch.items) |root| try appendSubtree(app, session, root, now_ns);
}

pub fn isCollapsed(app: *const App, index: usize) bool {
    return index < app.collapsed.items.len and app.collapsed.items[index];
}

pub const RowCollapseTarget = union(enum) {
    process: usize,
    packed_row: usize,
};

pub fn hasChildren(app: *const App, index: usize) bool {
    return index < app.first_child.items.len and app.first_child.items[index] != null;
}

pub fn canCollapseRow(app: *const App, target: RowCollapseTarget) bool {
    switch (target) {
        .process => |index| return hasChildren(app, index),
        .packed_row => |head| {
            var member: ?usize = head;
            while (member) |index| : (member = app.slot_next.items[index]) {
                if (hasChildren(app, index)) return true;
            }
            return false;
        },
    }
}

pub fn isRowCollapsed(app: *const App, target: RowCollapseTarget) bool {
    switch (target) {
        .process => |index| return isCollapsed(app, index),
        .packed_row => |head| {
            var found = false;
            var member: ?usize = head;
            while (member) |index| : (member = app.slot_next.items[index]) {
                if (!hasChildren(app, index)) continue;
                found = true;
                if (!isCollapsed(app, index)) return false;
            }
            return found;
        },
    }
}

fn setCollapsed(app: *App, index: usize, collapsed: bool) bool {
    if (index >= app.collapsed.items.len or app.collapsed.items[index] == collapsed) return false;
    app.collapsed.items[index] = collapsed;
    return true;
}

pub fn toggleRowCollapsed(app: *App, target: RowCollapseTarget) void {
    const collapsed = !isRowCollapsed(app, target);
    var changed = false;
    switch (target) {
        .process => |index| changed = setCollapsed(app, index, collapsed),
        .packed_row => |head| {
            var member: ?usize = head;
            while (member) |index| : (member = app.slot_next.items[index]) {
                if (!hasChildren(app, index)) continue;
                changed = setCollapsed(app, index, collapsed) or changed;
            }
        },
    }
    if (changed) app.collapse_revision +%= 1;
}

pub fn allCollapsibleRowsCollapsed(app: *const App) bool {
    var found = false;
    for (app.first_child.items, 0..) |first_child, index| {
        if (first_child == null) continue;
        found = true;
        if (!isCollapsed(app, index)) return false;
    }
    return found;
}

pub fn toggleAllRowsCollapsed(app: *App) void {
    const collapsed = !allCollapsibleRowsCollapsed(app);
    var changed = false;
    for (app.first_child.items, 0..) |first_child, index| {
        if (first_child == null) continue;
        changed = setCollapsed(app, index, collapsed) or changed;
    }
    if (changed) app.collapse_revision +%= 1;
}

pub fn toggleCollapsed(app: *App, index: usize) void {
    toggleRowCollapsed(app, .{ .process = index });
}

const JobSpan = App.JobSpan;

const JobBounds = struct {
    start_ns: u64,
    end_ns: u64,
    height: u16 = 1,
};

const JobWalk = struct {
    base_depth: u16,
    now_ns: u64,
    bounds: *JobBounds,
};

fn appendSubtree(
    app: *App,
    session: *const tracer.Session,
    index: usize,
    now_ns: u64,
) Allocator.Error!void {
    try app.row_order.append(app.gpa, .{ .process = index });
    if (isCollapsed(app, index)) return;
    const first = if (index < app.first_child.items.len) app.first_child.items[index] else null;
    const child_index = first orelse return;
    const unary = app.next_sibling.items[child_index] == null;
    const child_has_kids = child_index < app.first_child.items.len and
        app.first_child.items[child_index] != null;
    if (unary and child_has_kids) {
        try appendSubtree(app, session, child_index, now_ns);
        return;
    }

    var job_count: usize = 0;
    var child = first;
    while (child) |job_root| : (child = app.next_sibling.items[job_root]) job_count += 1;
    app.jobs_scratch.clearRetainingCapacity();
    try app.jobs_scratch.ensureTotalCapacity(app.gpa, job_count);

    child = first;
    while (child) |job_root| {
        app.jobs_scratch.appendAssumeCapacity(collectJob(app, session, job_root, now_ns));
        child = app.next_sibling.items[job_root];
    }
    if (app.jobs_scratch.items.len == 0) return;

    const lanes = try assignJobSlots(app, app.jobs_scratch.items);
    try app.lane_heights.ensureUnusedCapacity(app.gpa, app.heights_scratch.items.len);
    var slot_rows: usize = 0;
    for (app.heights_scratch.items) |height| slot_rows += height;
    try app.row_order.ensureUnusedCapacity(app.gpa, slot_rows);
    app.lane_offsets_scratch.clearRetainingCapacity();
    try app.lane_offsets_scratch.ensureTotalCapacity(app.gpa, lanes);
    var row_offset: usize = 0;
    for (app.heights_scratch.items) |height| {
        app.lane_offsets_scratch.appendAssumeCapacity(row_offset);
        row_offset += height;
    }

    if (index < app.lane_height_off.items.len)
        app.lane_height_off.items[index] = @intCast(app.lane_heights.items.len);
    for (app.heights_scratch.items) |height| app.lane_heights.appendAssumeCapacity(height);
    const row_base = app.row_order.items.len;
    var lane: u16 = 0;
    while (lane < lanes) : (lane += 1) {
        const height = if (lane < app.heights_scratch.items.len)
            app.heights_scratch.items[lane]
        else
            1;
        var subrow: u16 = 0;
        while (subrow < height) : (subrow += 1) {
            app.row_order.appendAssumeCapacity(.{
                .slot = .{ .parent = index, .lane = lane, .subrow = subrow },
            });
        }
    }
    for (app.jobs_scratch.items) |job| {
        linkPackedSubtree(app, job.root, visualDepth(app, job.root), row_base);
    }
    try flattenPackedMembers(app, session, row_base, slot_rows);
}

fn collectJob(
    app: *App,
    session: *const tracer.Session,
    job_root: usize,
    now_ns: u64,
) JobSpan {
    var bounds = JobBounds{
        .start_ns = session.processes.items[job_root].start_ns,
        .end_ns = session.processes.items[job_root].end_ns orelse now_ns,
    };
    markJobTree(app, session, job_root, .{
        .base_depth = visualDepth(app, job_root),
        .now_ns = now_ns,
        .bounds = &bounds,
    });
    return .{
        .root = job_root,
        .start_ns = bounds.start_ns,
        .end_ns = bounds.end_ns,
        .height = bounds.height,
    };
}

fn markJobTree(
    app: *App,
    session: *const tracer.Session,
    index: usize,
    walk: JobWalk,
) void {
    const proc = session.processes.items[index];
    if (proc.start_ns < walk.bounds.start_ns) walk.bounds.start_ns = proc.start_ns;
    const proc_end = proc.end_ns orelse walk.now_ns;
    if (proc_end > walk.bounds.end_ns) walk.bounds.end_ns = proc_end;
    const rel = visualDepth(app, index) -| walk.base_depth;
    if (rel + 1 > walk.bounds.height) walk.bounds.height = rel + 1;
    if (isCollapsed(app, index)) return;
    var child = if (index < app.first_child.items.len) app.first_child.items[index] else null;
    while (child) |child_index| {
        markJobTree(app, session, child_index, walk);
        child = app.next_sibling.items[child_index];
    }
}

fn jobLessThan(_: void, a: JobSpan, b: JobSpan) bool {
    if (a.start_ns != b.start_ns) return a.start_ns < b.start_ns;
    return a.root < b.root;
}

fn laneOccLess(_: void, a: App.LaneOcc, b: App.LaneOcc) bool {
    if (a.end_ns != b.end_ns) return a.end_ns < b.end_ns;
    return a.lane < b.lane;
}

fn siftUpOcc(items: []App.LaneOcc, start: usize) void {
    var i = start;
    while (i > 0) {
        const parent = (i - 1) / 2;
        if (!laneOccLess({}, items[i], items[parent])) break;
        const tmp = items[i];
        items[i] = items[parent];
        items[parent] = tmp;
        i = parent;
    }
}

fn siftDownOcc(items: []App.LaneOcc, start: usize) void {
    var i = start;
    while (true) {
        var best = i;
        const left = 2 * i + 1;
        const right = 2 * i + 2;
        if (left < items.len and laneOccLess({}, items[left], items[best])) best = left;
        if (right < items.len and laneOccLess({}, items[right], items[best])) best = right;
        if (best == i) break;
        const tmp = items[i];
        items[i] = items[best];
        items[best] = tmp;
        i = best;
    }
}

fn siftUpLane(items: []u16, start: usize) void {
    var i = start;
    while (i > 0) {
        const parent = (i - 1) / 2;
        if (items[i] >= items[parent]) break;
        const tmp = items[i];
        items[i] = items[parent];
        items[parent] = tmp;
        i = parent;
    }
}

fn siftDownLane(items: []u16, start: usize) void {
    var i = start;
    while (true) {
        var best = i;
        const left = 2 * i + 1;
        const right = 2 * i + 2;
        if (left < items.len and items[left] < items[best]) best = left;
        if (right < items.len and items[right] < items[best]) best = right;
        if (best == i) break;
        const tmp = items[i];
        items[i] = items[best];
        items[best] = tmp;
        i = best;
    }
}

fn layoutJobLanes(
    app: *App,
    jobs: []JobSpan,
) Allocator.Error!u16 {
    app.occupied_scratch.clearRetainingCapacity();
    app.free_lanes_scratch.clearRetainingCapacity();
    app.heights_scratch.clearRetainingCapacity();
    try app.occupied_scratch.ensureTotalCapacity(app.gpa, jobs.len);
    try app.free_lanes_scratch.ensureTotalCapacity(app.gpa, jobs.len);
    try app.heights_scratch.ensureTotalCapacity(app.gpa, jobs.len);

    std.sort.pdq(JobSpan, jobs, {}, jobLessThan);
    var next_lane: u16 = 0;
    for (jobs) |*job| {
        while (app.occupied_scratch.items.len > 0 and
            app.occupied_scratch.items[0].end_ns <= job.start_ns)
        {
            const freed = app.occupied_scratch.items[0];
            const last = app.occupied_scratch.items[app.occupied_scratch.items.len - 1];
            app.occupied_scratch.items.len -= 1;
            if (app.occupied_scratch.items.len > 0) {
                app.occupied_scratch.items[0] = last;
                siftDownOcc(app.occupied_scratch.items, 0);
            }
            app.free_lanes_scratch.appendAssumeCapacity(freed.lane);
            siftUpLane(app.free_lanes_scratch.items, app.free_lanes_scratch.items.len - 1);
        }

        const lane: u16 = if (app.free_lanes_scratch.items.len > 0) blk: {
            const id = app.free_lanes_scratch.items[0];
            const last = app.free_lanes_scratch.items[app.free_lanes_scratch.items.len - 1];
            app.free_lanes_scratch.items.len -= 1;
            if (app.free_lanes_scratch.items.len > 0) {
                app.free_lanes_scratch.items[0] = last;
                siftDownLane(app.free_lanes_scratch.items, 0);
            }
            break :blk id;
        } else blk: {
            const id = next_lane;
            next_lane += 1;
            app.heights_scratch.appendAssumeCapacity(0);
            break :blk id;
        };
        if (lane < app.heights_scratch.items.len and
            job.height > app.heights_scratch.items[lane])
        {
            app.heights_scratch.items[lane] = job.height;
        }
        app.occupied_scratch.appendAssumeCapacity(.{ .end_ns = job.end_ns, .lane = lane });
        siftUpOcc(app.occupied_scratch.items, app.occupied_scratch.items.len - 1);
        job.lane = lane;
    }
    return next_lane;
}

fn assignJobSlots(
    app: *App,
    jobs: []JobSpan,
) Allocator.Error!u16 {
    const lanes = try layoutJobLanes(app, jobs);
    for (jobs) |job| setSubtreeSlot(app, job.root, job.lane);
    perf.noteRebuild(jobs.len);
    return lanes;
}

fn setSubtreeSlot(app: *App, index: usize, lane: u16) void {
    if (index < app.pack_slot.items.len) app.pack_slot.items[index] = lane;
    if (isCollapsed(app, index)) return;
    var child = if (index < app.first_child.items.len) app.first_child.items[index] else null;
    while (child) |child_index| {
        setSubtreeSlot(app, child_index, lane);
        child = app.next_sibling.items[child_index];
    }
}

fn linkPackedSubtree(app: *App, index: usize, base_depth: u16, row_base: usize) void {
    const lane = app.pack_slot.items[index];
    const subrow = visualDepth(app, index) -| base_depth;
    const row_index = row_base + app.lane_offsets_scratch.items[lane] + subrow;
    switch (app.row_order.items[row_index]) {
        .slot => {},
        .process => unreachable,
    }
    const slot = &app.row_order.items[row_index].slot;
    if (slot.tail) |tail| {
        app.slot_next.items[tail] = index;
    } else {
        slot.head = index;
    }
    slot.tail = index;
    if (isCollapsed(app, index)) return;
    var child = app.first_child.items[index];
    while (child) |child_index| {
        linkPackedSubtree(app, child_index, base_depth, row_base);
        child = app.next_sibling.items[child_index];
    }
}

fn packedMemberLessThan(processes: []const tracer.Process, a: usize, b: usize) bool {
    if (processes[a].start_ns != processes[b].start_ns) {
        return processes[a].start_ns < processes[b].start_ns;
    }
    return a < b;
}

fn flattenPackedMembers(
    app: *App,
    session: *const tracer.Session,
    row_base: usize,
    slot_rows: usize,
) Allocator.Error!void {
    const processes = session.processes.items;
    for (row_base..row_base + slot_rows) |row_index| {
        const slot = &app.row_order.items[row_index].slot;
        slot.members_off = @intCast(app.packed_members.items.len);
        var member = slot.head;
        while (member) |index| : (member = app.slot_next.items[index]) {
            try app.packed_members.append(app.gpa, index);
        }
        slot.members_len = @intCast(app.packed_members.items.len - slot.members_off);
        if (slot.members_len > 0) {
            const members = app.packed_members.items[slot.members_off..][0..slot.members_len];
            std.mem.sort(usize, members, processes, packedMemberLessThan);
            slot.head = members[0];
            slot.tail = members[members.len - 1];
            for (members, 0..) |index, i| {
                app.slot_next.items[index] = if (i + 1 < members.len) members[i + 1] else null;
            }
        }
    }
}

pub fn slotMembers(app: *const App, slot: anytype) []const usize {
    const off = slot.members_off;
    const len = slot.members_len;
    if (off >= app.packed_members.items.len) return &.{};
    return app.packed_members.items[off..@min(off + len, app.packed_members.items.len)];
}

pub fn firstPackedVisible(
    members: []const usize,
    processes: []const tracer.Process,
    window_start_ns: u64,
    now_ns: u64,
) usize {
    var lo: usize = 0;
    var hi: usize = members.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const process = processes[members[mid]];
        const end_ns = process.end_ns orelse now_ns;
        if (end_ns <= window_start_ns) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

pub fn laneHeight(app: *const App, parent: usize, lane: u16) u16 {
    if (parent >= app.lane_height_off.items.len) return 1;
    const idx = app.lane_height_off.items[parent] + lane;
    if (idx >= app.lane_heights.items.len) return 1;
    return @max(@as(u16, 1), app.lane_heights.items[idx]);
}

fn visualDepth(app: *const App, index: usize) u16 {
    return if (index < app.visual_depth.items.len) app.visual_depth.items[index] else 0;
}
