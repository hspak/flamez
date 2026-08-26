#include <linux/bpf.h>
#include <linux/types.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>

#include "flamez_event.h"

/*
 * Classic SEC("tracepoint/sched/...") programs take a pointer to the
 * tracefs event layout, including struct trace_entry. Linux 7.x changed
 * sched_process_fork (and several siblings) from
 *   __array(char, comm, TASK_COMM_LEN)
 * to a dynamic
 *   __string(comm, ...)
 * so the recorded fields are __data_loc u32s plus strings in __data[].
 *
 * The kernel then rejects attach with -EACCES when the program's
 * max_ctx_offset is past the last *fixed* field
 * (perf_event_set_bpf_prog → trace_event_get_offsets). That looks like a
 * permission error and is easy to chase into capabilities; it is not.
 *
 * Raw tracepoints get the kernel function arguments (task_struct pointers)
 * instead of that event struct, so they survive the layout change. CO-RE
 * relocates pid/tgid/comm against the running kernel's BTF.
 *
 * Process identity is tgid (userspace pid), not tid. Thread clones
 * (CLONE_THREAD) do not produce lifecycle records, but sched_switch accounts
 * their on-CPU time to the owning tgid. Linux v7 exposes group_dead to
 * sched_process_exit, so only the final thread-group exit is emitted.
 */
struct task_struct {
    int pid;
    int tgid;
    char comm[FLAMEZ_COMM_LEN];
    struct mm_struct *mm;
} __attribute__((preserve_access_index));

struct mm_struct {
    unsigned long arg_start;
    unsigned long arg_end;
} __attribute__((preserve_access_index));

struct linux_binprm {
    const char *filename;
} __attribute__((preserve_access_index));

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 24);
} events SEC(".maps");

/* The loader checks this map name before accepting records. Bump it whenever
 * the record layout or userspace-visible event semantics change. */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, __u32);
} abi_v7 SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, __u32);
    __type(value, __u8);
} tracked_pids SEC(".maps");

struct flamez_process_cpu {
    __u64 total_ns;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, __u32);
    __type(value, struct flamez_process_cpu);
} process_cpu SEC(".maps");

struct flamez_running_thread {
    __u32 tgid;
    __u32 reserved;
    __u64 started_at_ns;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, __u32);
    __type(value, struct flamez_running_thread);
} running_threads SEC(".maps");

#define FLAMEZ_TRACKED_PROCESS 1
#define FLAMEZ_TRACKED_SEED_PARENT 2

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, __u64);
} counters SEC(".maps");

static __always_inline void record_lost_event(void)
{
    __u32 key = 0;
    __u64 *count = bpf_map_lookup_elem(&counters, &key);
    if (count)
        __sync_fetch_and_add(count, 1);
}

static __always_inline int is_tracked(__u32 pid)
{
    return bpf_map_lookup_elem(&tracked_pids, &pid) != 0;
}

static __always_inline int initialize_process_cpu(__u32 tgid)
{
    struct flamez_process_cpu initial = {};

    if (bpf_map_lookup_elem(&process_cpu, &tgid))
        return 0;
    if (bpf_map_update_elem(&process_cpu, &tgid, &initial, BPF_NOEXIST)) {
        record_lost_event();
        return -1;
    }
    return 0;
}

static __always_inline void account_schedule_in(__u32 tid, __u32 tgid, __u64 now)
{
    struct flamez_running_thread running = {
        .tgid = tgid,
        .started_at_ns = now,
    };
    struct flamez_process_cpu *cpu;

    if (!is_tracked(tgid))
        return;
    if (bpf_map_lookup_elem(&running_threads, &tid))
        return;
    cpu = bpf_map_lookup_elem(&process_cpu, &tgid);
    if (!cpu) {
        if (initialize_process_cpu(tgid)) {
            return;
        }
        cpu = bpf_map_lookup_elem(&process_cpu, &tgid);
        if (!cpu) {
            record_lost_event();
            return;
        }
    }
    if (bpf_map_update_elem(&running_threads, &tid, &running, BPF_NOEXIST))
        record_lost_event();
}

static __always_inline void account_schedule_out(__u32 tid, __u64 now)
{
    struct flamez_running_thread *running;
    struct flamez_process_cpu *cpu;
    __u64 started_at_ns;
    __u32 tgid;

    running = bpf_map_lookup_elem(&running_threads, &tid);
    if (!running)
        return;
    tgid = running->tgid;
    started_at_ns = running->started_at_ns;
    /* Remove first so a userspace snapshot can temporarily miss this interval
     * but can never count it both here and as a still-running contribution. */
    if (bpf_map_delete_elem(&running_threads, &tid)) {
        record_lost_event();
        return;
    }
    if (now < started_at_ns)
        return;
    cpu = bpf_map_lookup_elem(&process_cpu, &tgid);
    if (cpu)
        __sync_fetch_and_add(&cpu->total_ns, now - started_at_ns);
}

static __always_inline __u64 process_cpu_ns(__u32 tgid)
{
    struct flamez_process_cpu *cpu = bpf_map_lookup_elem(&process_cpu, &tgid);

    if (!cpu)
        return 0;
    return __sync_fetch_and_add(&cpu->total_ns, 0);
}

static __always_inline void initialize_event(struct flamez_event *event, __u32 kind)
{
    __builtin_memset(event, 0, sizeof(*event));
    event->kind = kind;
    event->timestamp_ns = bpf_ktime_get_ns();
}

static __always_inline struct flamez_event *reserve_event(__u32 kind)
{
    struct flamez_event *event = bpf_ringbuf_reserve(&events, sizeof(*event), 0);
    if (!event) {
        record_lost_event();
        return 0;
    }
    initialize_event(event, kind);
    return event;
}

#define FLAMEZ_ARG_COPY_CHUNK 4096U

static __always_inline int copy_exec_args(struct bpf_dynptr *record,
                                          unsigned long arg_start,
                                          __u32 args_len)
{
    __u32 offset = 0;
    __u32 remaining = args_len;
    void *destination;
    __u32 chunk;

#pragma clang loop unroll(disable)
    for (chunk = 0; chunk < FLAMEZ_MAX_ARGS / FLAMEZ_ARG_COPY_CHUNK; ++chunk) {
        if (remaining < FLAMEZ_ARG_COPY_CHUNK)
            break;
        destination = bpf_dynptr_data(record,
                                      sizeof(struct flamez_exec_event) + offset,
                                      FLAMEZ_ARG_COPY_CHUNK);
        if (!destination ||
            bpf_probe_read_user(destination, FLAMEZ_ARG_COPY_CHUNK,
                                (const void *)(arg_start + offset)))
            return -1;
        offset += FLAMEZ_ARG_COPY_CHUNK;
        remaining -= FLAMEZ_ARG_COPY_CHUNK;
    }

#define COPY_ARG_REMAINDER(size)                                                \
    do {                                                                        \
        if (remaining >= (size)) {                                              \
            destination = bpf_dynptr_data(                                     \
                record, sizeof(struct flamez_exec_event) + offset, (size));     \
            if (!destination ||                                                \
                bpf_probe_read_user(destination, (size),                        \
                                    (const void *)(arg_start + offset)))        \
                return -1;                                                      \
            offset += (size);                                                   \
            remaining -= (size);                                                \
        }                                                                       \
    } while (0)

    COPY_ARG_REMAINDER(2048U);
    COPY_ARG_REMAINDER(1024U);
    COPY_ARG_REMAINDER(512U);
    COPY_ARG_REMAINDER(256U);
    COPY_ARG_REMAINDER(128U);
    COPY_ARG_REMAINDER(64U);
    COPY_ARG_REMAINDER(32U);
    COPY_ARG_REMAINDER(16U);
    COPY_ARG_REMAINDER(8U);
    COPY_ARG_REMAINDER(4U);
    COPY_ARG_REMAINDER(2U);
    COPY_ARG_REMAINDER(1U);
#undef COPY_ARG_REMAINDER

    return remaining == 0 ? 0 : -1;
}

static __always_inline void emit_exec_event(struct task_struct *task,
                                            struct linux_binprm *bprm,
                                            __u32 pid)
{
    const char *filename = BPF_CORE_READ(bprm, filename);
    struct mm_struct *mm = BPF_CORE_READ(task, mm);
    struct bpf_dynptr record;
    struct flamez_exec_event *event;
    unsigned long arg_start = 0;
    unsigned long arg_end = 0;
    unsigned long arg_span = 0;
    __u32 args_len = 0;
    __u32 record_size;
    long copied;

    if (mm) {
        arg_start = BPF_CORE_READ(mm, arg_start);
        arg_end = BPF_CORE_READ(mm, arg_end);
        if (arg_start && arg_end > arg_start)
            arg_span = arg_end - arg_start;
    }
    /* Linux caps a successful exec's combined argument block below 6 MiB.
     * Treat a larger span as corrupt metadata rather than emitting a prefix. */
    if (arg_span > FLAMEZ_MAX_ARGS) {
        record_lost_event();
        return;
    }
    args_len = (__u32)arg_span;
    record_size = sizeof(struct flamez_exec_event) + args_len;
    if (bpf_ringbuf_reserve_dynptr(&events, record_size, 0, &record)) {
        record_lost_event();
        bpf_ringbuf_discard_dynptr(&record, 0);
        return;
    }
    event = bpf_dynptr_data(&record, 0, sizeof(*event));
    if (!event)
        goto discard;
    __builtin_memset(event, 0, sizeof(*event));
    initialize_event(&event->base, FLAMEZ_EVENT_EXEC);
    event->base.pid = (__s32)pid;
    bpf_get_current_comm(event->base.comm, sizeof(event->base.comm));

    if (filename) {
        copied = bpf_probe_read_kernel_str(event->exe, sizeof(event->exe), filename);
        if (copied > 0) {
            event->base.exe_len = (__u16)(copied - 1);
            event->base.metadata_flags |= FLAMEZ_METADATA_EXE;
            if (copied == sizeof(event->exe))
                event->base.metadata_flags |= FLAMEZ_METADATA_EXE_TRUNCATED;
        }
    }
    if (args_len > 0) {
        if (copy_exec_args(&record, arg_start, args_len))
            goto discard;
        event->base.args_len = args_len;
        event->base.metadata_flags |= FLAMEZ_METADATA_ARGS;
    }
    bpf_ringbuf_submit_dynptr(&record, 0);
    return;

discard:
    record_lost_event();
    bpf_ringbuf_discard_dynptr(&record, 0);
}

SEC("raw_tp/sched_process_fork")
int handle_process_fork(struct bpf_raw_tracepoint_args *ctx)
{
    struct task_struct *parent = (struct task_struct *)ctx->args[0];
    struct task_struct *child = (struct task_struct *)ctx->args[1];
    __s32 child_tgid = BPF_CORE_READ(child, tgid);
    __s32 parent_tgid = BPF_CORE_READ(parent, tgid);
    __u32 child_key = (__u32)child_tgid;
    __u32 parent_key = (__u32)parent_tgid;
    __u8 *parent_state_ptr;
    __u8 parent_state;
    __u8 tracked = FLAMEZ_TRACKED_PROCESS;
    struct flamez_event *event;

    if (child_tgid == parent_tgid)
        return 0;
    parent_state_ptr = bpf_map_lookup_elem(&tracked_pids, &parent_key);
    if (!parent_state_ptr)
        return 0;
    parent_state = *parent_state_ptr;
    if (bpf_map_update_elem(&tracked_pids, &child_key, &tracked, BPF_ANY)) {
        record_lost_event();
        return 0;
    }
    initialize_process_cpu(child_key);
    /* Session.start records the one child of its temporary seed entry as the
     * root. The map update above must still happen before that child runs. */
    if (parent_state == FLAMEZ_TRACKED_SEED_PARENT)
        return 0;

    event = reserve_event(FLAMEZ_EVENT_FORK);
    /* Keep the child tracked even if the ring buffer is full. Userspace
     * recovers from a later exec or from a grandchild fork; untracking
     * here would drop the whole subtree. */
    if (!event)
        return 0;
    event->pid = child_tgid;
    event->parent_pid = parent_tgid;
    bpf_core_read(&event->comm, sizeof(event->comm), &child->comm);
    bpf_ringbuf_submit(event, 0);
    return 0;
}

SEC("raw_tp/sched_process_exec")
int handle_process_exec(struct bpf_raw_tracepoint_args *ctx)
{
    struct task_struct *task = (struct task_struct *)ctx->args[0];
    __u32 old_tid = (__u32)ctx->args[1];
    struct linux_binprm *bprm = (struct linux_binprm *)ctx->args[2];
    __u64 pid_tgid = bpf_get_current_pid_tgid();
    __u32 pid = (__u32)(pid_tgid >> 32);
    __u32 tid = (__u32)pid_tgid;

    if (!is_tracked(pid))
        return 0;
    /* A non-leader exec adopts the TGID as its TID. Move the live accounting
     * entry so its later switch-out cannot strand an active-thread count. */
    if (old_tid != tid) {
        __u64 now = bpf_ktime_get_ns();

        account_schedule_out(old_tid, now);
        account_schedule_in(tid, pid, now);
    }
    emit_exec_event(task, bprm, pid);
    return 0;
}

SEC("raw_tp/sched_process_exit")
int handle_process_exit(struct bpf_raw_tracepoint_args *ctx)
{
    __u64 pid_tgid = bpf_get_current_pid_tgid();
    __u32 pid = (__u32)(pid_tgid >> 32);
    __u32 tid = (__u32)pid_tgid;
    __u64 now = bpf_ktime_get_ns();
    __u64 cpu_ns;
    struct flamez_event *event;

    account_schedule_out(tid, now);
    if (!ctx->args[1])
        return 0;
    /* Delete doubles as the membership test, keeping unrelated system exits
     * to one map operation and avoiding a lookup-then-delete race. */
    if (bpf_map_delete_elem(&tracked_pids, &pid))
        return 0;
    cpu_ns = process_cpu_ns(pid);
    event = reserve_event(FLAMEZ_EVENT_EXIT);
    if (event) {
        event->pid = (__s32)pid;
        event->cpu_ns = cpu_ns;
        bpf_get_current_comm(event->comm, sizeof(event->comm));
        bpf_ringbuf_submit(event, 0);
    }
    bpf_map_delete_elem(&process_cpu, &pid);
    return 0;
}

SEC("raw_tp/sched_switch")
int handle_sched_switch(struct bpf_raw_tracepoint_args *ctx)
{
    struct task_struct *prev = (struct task_struct *)ctx->args[1];
    struct task_struct *next = (struct task_struct *)ctx->args[2];
    __u32 prev_tid = (__u32)BPF_CORE_READ(prev, pid);
    __u32 next_tid = (__u32)BPF_CORE_READ(next, pid);
    __u32 next_tgid = (__u32)BPF_CORE_READ(next, tgid);
    __u64 now = bpf_ktime_get_ns();

    account_schedule_out(prev_tid, now);
    account_schedule_in(next_tid, next_tgid, now);
    return 0;
}

char LICENSE[] SEC("license") = "GPL";
