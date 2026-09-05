#define _GNU_SOURCE /* O_CLOEXEC, O_NOFOLLOW */

#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/bpf.h>
#include <linux/capability.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

#include "flamez_event.h"

typedef void (*flamez_event_callback)(const struct flamez_event *, size_t, void *);

struct flamez_process_cpu_snapshot {
    uint64_t total_ns;
    uint64_t live_threads;
};

struct flamez_running_thread_snapshot {
    uint32_t tgid;
    uint32_t running;
    uint64_t started_at_ns;
};

struct flamez_cpu_total {
    uint32_t tgid;
    uint32_t reserved;
    uint64_t total_ns;
};

struct flamez_cpu_index_slot {
    uint32_t tgid;
    uint32_t pos;
};

struct flamez_ebpf {
#if FLAMEZ_CAPTURE_TEST
    int test_empty;
#endif
    struct bpf_object *object;
    void *object_bytes;
    struct bpf_link **links;
    size_t link_count;
    struct ring_buffer *ring;
    int counters_fd;
    int process_cpu_fd;
    int running_threads_fd;
    int tracked_pids_fd;
    struct flamez_cpu_total *cpu_totals;
    size_t cpu_total_capacity;
    struct flamez_cpu_index_slot *cpu_index;
    size_t cpu_index_capacity;
    flamez_event_callback callback;
    void *userdata;
};

struct expected_program {
    const char *name;
    const char *section;
};

static const struct expected_program expected_programs[] = {
    { "handle_process_fork", "raw_tp/sched_process_fork" },
    { "handle_thread_create", "raw_tp/task_newtask" },
    { "handle_process_exec", "raw_tp/sched_process_exec" },
    { "handle_process_exit", "raw_tp/sched_process_exit" },
    { "handle_sched_switch", "raw_tp/sched_switch" },
};

enum { expected_program_count = 5 };

static void set_err(char *err, size_t err_size, const char *fmt, ...)
{
    va_list args;

    if (!err || err_size == 0)
        return;
    va_start(args, fmt);
    vsnprintf(err, err_size, fmt, args);
    va_end(args);
}

static int has_tracing_capabilities(unsigned long long effective)
{
    const unsigned long long cap_sys_admin = 1ULL << 21;
    const unsigned long long cap_perfmon = 1ULL << 38;
    const unsigned long long cap_bpf = 1ULL << 39;

    return (effective & cap_sys_admin) ||
           ((effective & cap_perfmon) && (effective & cap_bpf));
}

static int read_effective_capabilities(unsigned long long *effective)
{
    FILE *status;
    char line[256];
    int found = 0;

    *effective = 0;
    status = fopen("/proc/self/status", "re");
    if (!status)
        return -errno;
    while (fgets(line, sizeof(line), status)) {
        if (sscanf(line, "CapEff: %llx", effective) == 1) {
            found = 1;
            break;
        }
    }
    fclose(status);
    return found ? 0 : -EINVAL;
}

static int check_kernel_version(char *err, size_t err_size)
{
    struct utsname system;
    char *end;
    long major;

    if (uname(&system) != 0) {
        set_err(err, err_size, "cannot read the Linux kernel version: %s (%d)",
                strerror(errno), errno);
        return -1;
    }
    errno = 0;
    major = strtol(system.release, &end, 10);
    if (errno != 0 || end == system.release || major < 7) {
        set_err(err, err_size,
                "Linux v7 or newer is required (running kernel: %s)",
                system.release);
        return -1;
    }
    return 0;
}

/* Fail before libbpf feature probes when the process cannot possibly load
 * and attach the programs. Root is checked too: UID 0 in a restricted user
 * namespace does not imply the needed capabilities in the owning namespace. */
static int check_privileges(char *err, size_t err_size)
{
    unsigned long long effective;
    int cap_err = read_effective_capabilities(&effective);

    if (cap_err != 0) {
        set_err(err, err_size, "cannot read effective capabilities: %s (%d)",
                strerror(-cap_err), cap_err);
        return -1;
    }
    if (!has_tracing_capabilities(effective)) {
        FILE *setting;
        int disabled = 0;

        setting = fopen("/proc/sys/kernel/unprivileged_bpf_disabled", "re");
        if (setting) {
            if (fscanf(setting, "%d", &disabled) != 1)
                disabled = 0;
            fclose(setting);
        }
        set_err(err, err_size,
                "effective capabilities lack CAP_BPF + CAP_PERFMON "
                "(or CAP_SYS_ADMIN)%s",
                disabled ? "; kernel.unprivileged_bpf_disabled is set" : "");
        return -1;
    }
    return 0;
}

static int receive_event(void *context, void *data, size_t size)
{
    struct flamez_ebpf *collector = context;
    const struct flamez_exec_event *exec_event;
    uint32_t kind;

    if (size < sizeof(kind))
        return 0;
    memcpy(&kind, data, sizeof(kind));
    switch (kind) {
    case FLAMEZ_EVENT_FORK:
    case FLAMEZ_EVENT_EXIT:
        if (size != sizeof(struct flamez_event))
            return 0;
        break;
    case FLAMEZ_EVENT_EXEC:
        if (size < sizeof(struct flamez_exec_event))
            return 0;
        exec_event = data;
        if (exec_event->base.args_len != size - sizeof(*exec_event) ||
            exec_event->base.exe_len > FLAMEZ_MAX_PATH)
            return 0;
        break;
    default:
        return 0;
    }
    collector->callback(data, size, collector->userdata);
    return 0;
}

static void destroy_collector(struct flamez_ebpf *collector)
{
    size_t index;

    if (!collector)
        return;
    ring_buffer__free(collector->ring);
    for (index = 0; index < collector->link_count; ++index)
        bpf_link__destroy(collector->links[index]);
    free(collector->links);
    bpf_object__close(collector->object);
    free(collector->object_bytes);
    free(collector->cpu_totals);
    free(collector->cpu_index);
    free(collector);
}

static int resolve_object_path(char *path, size_t path_size,
                               char *err, size_t err_size)
{
    const char *override = getenv("FLAMEZ_BPF_OBJECT");
    ssize_t length;
    char *separator;

    if (override && override[0]) {
        if (snprintf(path, path_size, "%s", override) >= (int)path_size) {
            set_err(err, err_size, "FLAMEZ_BPF_OBJECT path is too long");
            return -1;
        }
        return 0;
    }

    length = readlink("/proc/self/exe", path, path_size - 1);
    if (length <= 0 || (size_t)length >= path_size - 1) {
        set_err(err, err_size, "cannot resolve /proc/self/exe: %s", strerror(errno));
        return -1;
    }
    path[length] = '\0';
    separator = strrchr(path, '/');
    if (!separator) {
        set_err(err, err_size, "executable path has no parent directory");
        return -1;
    }
    *separator = '\0';
    separator = strrchr(path, '/');
    if (!separator) {
        set_err(err, err_size, "executable path has no installation prefix");
        return -1;
    }
    *separator = '\0';
    if (strlen(path) + sizeof("/share/flamez/flamez.bpf.o") > path_size) {
        set_err(err, err_size, "installed BPF object path is too long");
        return -1;
    }
    strcat(path, "/share/flamez/flamez.bpf.o");
    return 0;
}

/* A file-capable executable must not let an unprivileged caller choose the
 * program run with those capabilities. Open without following a final
 * symlink, then validate the selected inode before reading it. Root may use
 * FLAMEZ_BPF_OBJECT for development; non-root callers get only a root-owned,
 * non-writable installed object. */
static int open_trusted_object(const char *path, char *err, size_t err_size)
{
    struct stat file_stat;
    char fd_path[64];
    int caller_can_write = 0;
    int fd;

    fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        set_err(err, err_size, "cannot open BPF object '%s': %s (%d)",
                path, strerror(errno), errno);
        return -1;
    }
    if (fstat(fd, &file_stat) != 0) {
        set_err(err, err_size, "cannot inspect BPF object '%s': %s (%d)",
                path, strerror(errno), errno);
        close(fd);
        return -1;
    }
    if (!S_ISREG(file_stat.st_mode)) {
        set_err(err, err_size, "BPF object '%s' is not a regular file", path);
        close(fd);
        return -1;
    }
    if (file_stat.st_size <= 0 || file_stat.st_size > 16 * 1024 * 1024) {
        set_err(err, err_size, "BPF object '%s' has an invalid size", path);
        close(fd);
        return -1;
    }
    if (geteuid() != 0) {
        snprintf(fd_path, sizeof(fd_path), "/proc/self/fd/%d", fd);
        caller_can_write = access(fd_path, W_OK) == 0;
    }
    if (geteuid() != 0 &&
        (file_stat.st_uid != 0 || (file_stat.st_mode & (S_IWGRP | S_IWOTH)) ||
         caller_can_write)) {
        set_err(err, err_size,
                "refusing untrusted BPF object '%s': a capable non-root run "
                "requires a root-owned file the caller cannot write; "
                "install it with ./build.sh",
                path);
        close(fd);
        return -1;
    }
    return fd;
}

static int read_object(int fd, const char *path, void **bytes, size_t *size,
                       char *err, size_t err_size)
{
    struct stat file_stat;
    unsigned char *buffer;
    size_t offset = 0;

    if (fstat(fd, &file_stat) != 0) {
        set_err(err, err_size, "cannot inspect BPF object '%s': %s (%d)",
                path, strerror(errno), errno);
        return -1;
    }
    if (file_stat.st_size <= 0 || file_stat.st_size > 16 * 1024 * 1024) {
        set_err(err, err_size, "BPF object '%s' changed to an invalid size", path);
        return -1;
    }
    buffer = malloc((size_t)file_stat.st_size);
    if (!buffer) {
        set_err(err, err_size, "out of memory reading BPF object '%s'", path);
        return -1;
    }
    while (offset < (size_t)file_stat.st_size) {
        ssize_t amount = read(fd, buffer + offset, (size_t)file_stat.st_size - offset);

        if (amount > 0) {
            offset += (size_t)amount;
            continue;
        }
        if (amount < 0 && errno == EINTR)
            continue;
        set_err(err, err_size, "cannot read BPF object '%s': %s (%d)",
                path, amount == 0 ? "unexpected end of file" : strerror(errno),
                amount == 0 ? 0 : errno);
        free(buffer);
        return -1;
    }
    *bytes = buffer;
    *size = offset;
    return 0;
}

static int validate_programs(struct bpf_object *object, const char *path,
                             char *err, size_t err_size)
{
    int seen[sizeof(expected_programs) / sizeof(expected_programs[0])] = { 0 };
    struct bpf_program *program;
    size_t count = 0;

    bpf_object__for_each_program(program, object) {
        const char *name = bpf_program__name(program);
        const char *section = bpf_program__section_name(program);
        size_t index;

        for (index = 0; index < sizeof(expected_programs) / sizeof(expected_programs[0]);
             ++index) {
            if (name && section && !strcmp(name, expected_programs[index].name) &&
                !strcmp(section, expected_programs[index].section))
                break;
        }
        if (index == sizeof(expected_programs) / sizeof(expected_programs[0]) ||
            seen[index]) {
            set_err(err, err_size,
                    "BPF object '%s' contains unexpected program '%s' in section '%s'",
                    path, name ? name : "?", section ? section : "?");
            return -1;
        }
        seen[index] = 1;
        ++count;
    }
    if (count != sizeof(expected_programs) / sizeof(expected_programs[0])) {
        set_err(err, err_size,
                "BPF object '%s' does not contain the expected lifecycle/CPU programs",
                path);
        return -1;
    }
    return 0;
}

static int validate_map(struct bpf_object *object, const char *path,
                        const char *name, enum bpf_map_type type,
                        uint32_t key_size, uint32_t value_size,
                        uint32_t max_entries, char *err, size_t err_size)
{
    struct bpf_map *map = bpf_object__find_map_by_name(object, name);

    if (!map) {
        set_err(err, err_size, "BPF object '%s' is missing map '%s'", path, name);
        return -1;
    }
    if (bpf_map__type(map) != type || bpf_map__key_size(map) != key_size ||
        bpf_map__value_size(map) != value_size ||
        bpf_map__max_entries(map) != max_entries || bpf_map__map_flags(map) != 0 ||
        bpf_map__map_extra(map) != 0 || bpf_map__pin_path(map) != NULL ||
        bpf_map__inner_map(map) != NULL) {
        set_err(err, err_size,
                "BPF object '%s' has an incompatible '%s' map; rebuild it",
                path, name);
        return -1;
    }
    return 0;
}

static int is_readonly_internal_map(struct bpf_map *map)
{
    uint32_t flags = bpf_map__map_flags(map);

    return bpf_map__is_internal(map) && bpf_map__type(map) == BPF_MAP_TYPE_ARRAY &&
           bpf_map__key_size(map) == sizeof(uint32_t) &&
           bpf_map__value_size(map) > 0 && bpf_map__max_entries(map) == 1 &&
           (flags & BPF_F_RDONLY_PROG) &&
           !(flags & ~(BPF_F_RDONLY_PROG | BPF_F_MMAPABLE)) &&
           bpf_map__map_extra(map) == 0 && bpf_map__pin_path(map) == NULL &&
           bpf_map__inner_map(map) == NULL;
}

static int validate_maps(struct bpf_object *object, const char *path,
                         char *err, size_t err_size)
{
    static const char *const expected_maps[] = {
        "events", "abi_v8", "tracked_pids", "process_cpu", "running_threads",
        "counters",
    };
    struct bpf_map *map;
    size_t count = 0;

    bpf_object__for_each_map(map, object) {
        const char *name = bpf_map__name(map);
        size_t index;

        /* libbpf materializes compiler constants as internal read-only arrays.
         * Their section names and presence are not part of Flamez's map ABI. */
        if (is_readonly_internal_map(map))
            continue;
        for (index = 0; index < sizeof(expected_maps) / sizeof(expected_maps[0]); ++index) {
            if (name && !strcmp(name, expected_maps[index]))
                break;
        }
        if (index == sizeof(expected_maps) / sizeof(expected_maps[0])) {
            set_err(err, err_size, "BPF object '%s' contains unexpected map '%s'",
                    path, name ? name : "?");
            return -1;
        }
        ++count;
    }
    if (count != sizeof(expected_maps) / sizeof(expected_maps[0])) {
        set_err(err, err_size, "BPF object '%s' has an unexpected map count", path);
        return -1;
    }
    return validate_map(object, path, "events", BPF_MAP_TYPE_RINGBUF,
                        0, 0, 1U << 24, err, err_size) ||
           validate_map(object, path, "abi_v8", BPF_MAP_TYPE_ARRAY,
                        sizeof(uint32_t), sizeof(uint32_t), 1, err, err_size) ||
           validate_map(object, path, "tracked_pids", BPF_MAP_TYPE_HASH,
                        sizeof(uint32_t), sizeof(uint8_t), 65536, err, err_size) ||
           validate_map(object, path, "process_cpu", BPF_MAP_TYPE_HASH,
                        sizeof(uint32_t), sizeof(struct flamez_process_cpu_snapshot),
                        65536, err, err_size) ||
           validate_map(object, path, "running_threads", BPF_MAP_TYPE_HASH,
                        sizeof(uint32_t), sizeof(struct flamez_running_thread_snapshot),
                        65536, err, err_size) ||
           validate_map(object, path, "counters", BPF_MAP_TYPE_ARRAY,
                        sizeof(uint32_t), sizeof(uint64_t), 1, err, err_size);
}

static struct flamez_ebpf *open_collect(int object_fd, const char *path,
                                        flamez_event_callback callback,
                                        void *userdata, char *err, size_t err_size)
{
    struct flamez_ebpf *collector;
    struct bpf_program *program;
    size_t object_size;
    int map_fd;
    int load_err;

    collector = calloc(1, sizeof(*collector));
    if (!collector) {
        set_err(err, err_size, "out of memory");
        return NULL;
    }
    collector->counters_fd = -1;
    collector->process_cpu_fd = -1;
    collector->running_threads_fd = -1;
    collector->tracked_pids_fd = -1;
    collector->callback = callback;
    collector->userdata = userdata;
    if (read_object(object_fd, path, &collector->object_bytes, &object_size,
                    err, err_size) != 0)
        goto out_fail;

    collector->object = bpf_object__open_mem(collector->object_bytes, object_size, NULL);
    if (!collector->object || libbpf_get_error(collector->object)) {
        int open_err = collector->object
                           ? (int)libbpf_get_error(collector->object)
                           : -errno;

        if (open_err == 0)
            open_err = -EINVAL;
        set_err(err, err_size, "cannot parse BPF object '%s': %s (%d)",
                path, strerror(open_err < 0 ? -open_err : open_err),
                open_err);
        collector->object = NULL;
        goto out_fail;
    }
    if (validate_programs(collector->object, path, err, err_size) != 0 ||
        validate_maps(collector->object, path, err, err_size) != 0)
        goto out_fail;

    load_err = bpf_object__load(collector->object);
    if (load_err != 0) {
        set_err(err, err_size, "cannot load BPF object '%s': %s (%d)",
                path, strerror(load_err < 0 ? -load_err : load_err), load_err);
        goto out_fail;
    }

    collector->tracked_pids_fd =
        bpf_object__find_map_fd_by_name(collector->object, "tracked_pids");
    collector->counters_fd =
        bpf_object__find_map_fd_by_name(collector->object, "counters");
    collector->process_cpu_fd =
        bpf_object__find_map_fd_by_name(collector->object, "process_cpu");
    collector->running_threads_fd =
        bpf_object__find_map_fd_by_name(collector->object, "running_threads");
    map_fd = bpf_object__find_map_fd_by_name(collector->object, "events");
    if (collector->tracked_pids_fd < 0 || collector->process_cpu_fd < 0 ||
        collector->running_threads_fd < 0 || collector->counters_fd < 0 ||
        map_fd < 0) {
        set_err(err, err_size, "loaded BPF object '%s' has inaccessible maps", path);
        goto out_fail;
    }

    collector->ring = ring_buffer__new(map_fd, receive_event, collector, NULL);
    if (!collector->ring) {
        set_err(err, err_size, "cannot create ring-buffer reader for '%s': %s (%d)",
                path, strerror(errno), errno);
        goto out_fail;
    }
    collector->links = calloc(expected_program_count, sizeof(*collector->links));
    if (!collector->links) {
        set_err(err, err_size, "out of memory");
        goto out_fail;
    }

    bpf_object__for_each_program(program, collector->object) {
        struct bpf_link *link;
        int link_err;

        link = bpf_program__attach(program);
        link_err = link ? (int)libbpf_get_error(link) : -errno;
        if (!link || link_err) {
            if (link_err == 0)
                link_err = -EINVAL;

            set_err(err, err_size,
                    "cannot attach BPF program '%s' (section '%s'): %s (%d)",
                    bpf_program__name(program), bpf_program__section_name(program),
                    strerror(link_err < 0 ? -link_err : link_err), link_err);
            goto out_fail;
        }
        collector->links[collector->link_count++] = link;
    }
    if (collector->link_count != expected_program_count) {
        set_err(err, err_size, "BPF object '%s' did not attach five programs", path);
        goto out_fail;
    }
    return collector;

out_fail:
    destroy_collector(collector);
    return NULL;
}

/* Loads one fixed raw-tracepoint object. Every failure is fatal and returned
 * through err; capture never silently degrades to polling or another attach
 * mechanism. */
struct flamez_ebpf *flamez_ebpf_open(flamez_event_callback callback, void *userdata,
                                     char *err, size_t err_size)
{
    char path[4096];
    struct flamez_ebpf *collector;
    int object_fd;

    if (err && err_size)
        err[0] = '\0';
    if (!callback) {
        set_err(err, err_size, "eBPF event callback is null");
        return NULL;
    }
    if (check_kernel_version(err, err_size) != 0 ||
        check_privileges(err, err_size) != 0 ||
        resolve_object_path(path, sizeof(path), err, err_size) != 0)
        return NULL;

    object_fd = open_trusted_object(path, err, err_size);
    if (object_fd < 0)
        return NULL;
    collector = open_collect(object_fd, path, callback, userdata, err, err_size);
    close(object_fd);
    return collector;
}

/* Loading and attaching are the only operations that need BPF/perfmon
 * capabilities. Existing map/link/ring-buffer fds remain usable after the
 * process clears all three capability sets. */
int flamez_ebpf_drop_capabilities(void)
{
    struct __user_cap_header_struct header = {
        .version = _LINUX_CAPABILITY_VERSION_3,
        .pid = 0,
    };
    struct __user_cap_data_struct data[_LINUX_CAPABILITY_U32S_3] = { 0 };

    if (syscall(SYS_capset, &header, data) != 0)
        return -errno;
    return 0;
}

int flamez_ebpf_poll(struct flamez_ebpf *collector)
{
#if FLAMEZ_CAPTURE_TEST
    if (collector->test_empty)
        return 0;
#endif
    return ring_buffer__poll(collector->ring, 0);
}

uint64_t flamez_ebpf_lost_events(struct flamez_ebpf *collector)
{
    uint32_t key = 0;
    uint64_t count = 0;

    if (!collector || collector->counters_fd < 0)
        return 0;
    if (bpf_map_lookup_elem(collector->counters_fd, &key, &count) != 0)
        return 0;
    return count;
}

enum { cpu_index_empty = 0xffffffffu };

static int ensure_cpu_index_capacity(struct flamez_ebpf *collector, size_t totals)
{
    size_t capacity = collector->cpu_index_capacity;
    size_t required = 8;
    struct flamez_cpu_index_slot *resized;

    if (totals == 0)
        return 0;
    while (required < totals * 2)
        required *= 2;
    if (required <= capacity)
        return 0;
    resized = realloc(collector->cpu_index, required * sizeof(*resized));
    if (!resized)
        return -ENOMEM;
    collector->cpu_index = resized;
    collector->cpu_index_capacity = required;
    return 0;
}

static int rebuild_cpu_index(struct flamez_ebpf *collector, size_t totals)
{
    size_t index;
    size_t capacity;
    int result = ensure_cpu_index_capacity(collector, totals);

    if (result != 0)
        return result;
    capacity = collector->cpu_index_capacity;
    if (capacity == 0)
        return 0;
    for (index = 0; index < capacity; ++index) {
        collector->cpu_index[index].tgid = 0;
        collector->cpu_index[index].pos = cpu_index_empty;
    }
    for (index = 0; index < totals; ++index) {
        uint32_t tgid = collector->cpu_totals[index].tgid;
        size_t slot = tgid & (capacity - 1);

        for (;;) {
            if (collector->cpu_index[slot].pos == cpu_index_empty) {
                collector->cpu_index[slot].tgid = tgid;
                collector->cpu_index[slot].pos = (uint32_t)index;
                break;
            }
            slot = (slot + 1) & (capacity - 1);
        }
    }
    return 0;
}

static struct flamez_cpu_total *find_cpu_total(struct flamez_ebpf *collector,
                                              size_t count, uint32_t tgid)
{
    size_t capacity = collector->cpu_index_capacity;
    size_t slot;

    (void)count;
    if (!collector->cpu_index || capacity == 0)
        return NULL;
    slot = tgid & (capacity - 1);
    for (;;) {
        if (collector->cpu_index[slot].pos == cpu_index_empty)
            return NULL;
        if (collector->cpu_index[slot].tgid == tgid)
            return &collector->cpu_totals[collector->cpu_index[slot].pos];
        slot = (slot + 1) & (capacity - 1);
    }
}

static int ensure_cpu_total_capacity(struct flamez_ebpf *collector, size_t required)
{
    struct flamez_cpu_total *resized;
    size_t capacity = collector->cpu_total_capacity;

    if (required <= capacity)
        return 0;
    if (capacity == 0)
        capacity = 256;
    while (capacity < required) {
        if (capacity >= 65536)
            return -E2BIG;
        capacity *= 2;
    }
    resized = realloc(collector->cpu_totals, capacity * sizeof(*resized));
    if (!resized)
        return -ENOMEM;
    collector->cpu_totals = resized;
    collector->cpu_total_capacity = capacity;
    return 0;
}

static int read_process_cpu_totals(struct flamez_ebpf *collector, size_t *total_count)
{
    enum { batch_capacity = 256 };
    uint32_t keys[batch_capacity];
    struct flamez_process_cpu_snapshot values[batch_capacity];
    struct bpf_map_batch_opts opts = { .sz = sizeof(opts) };
    uint32_t cursor = 0;
    uint32_t out_batch = 0;
    void *in_batch = NULL;

    *total_count = 0;
    for (;;) {
        uint32_t count = batch_capacity;
        uint32_t index;
        int result;
        int lookup_errno;
        int capacity_result;

        errno = 0;
        result = bpf_map_lookup_batch(collector->process_cpu_fd, in_batch, &out_batch,
                                      keys, values, &count, &opts);
        lookup_errno = errno;
        /* Only ENOENT is a successful terminal batch. Other errors may leave
         * count unchanged, so none of the output entries are safe to consume. */
        if (result != 0 && lookup_errno != ENOENT)
            return result < 0 ? result : -lookup_errno;
        capacity_result = ensure_cpu_total_capacity(collector, *total_count + count);
        if (capacity_result != 0)
            return capacity_result;
        for (index = 0; index < count; ++index) {
            collector->cpu_totals[*total_count] = (struct flamez_cpu_total){
                .tgid = keys[index],
                .total_ns = values[index].total_ns,
            };
            *total_count += 1;
        }
        if (result == 0) {
            cursor = out_batch;
            in_batch = &cursor;
            continue;
        }
        if (lookup_errno == ENOENT)
            return 0;
        return result < 0 ? result : -lookup_errno;
    }
}

static int add_running_cpu(struct flamez_ebpf *collector, size_t total_count,
                           uint64_t *snapshot_at_ns)
{
    enum { batch_capacity = 256 };
    uint32_t keys[batch_capacity];
    struct flamez_running_thread_snapshot values[batch_capacity];
    struct bpf_map_batch_opts opts = { .sz = sizeof(opts) };
    uint32_t cursor = 0;
    uint32_t out_batch = 0;
    void *in_batch = NULL;

    for (;;) {
        struct timespec now;
        uint64_t now_ns;
        uint32_t count = batch_capacity;
        uint32_t index;
        int result;
        int lookup_errno;

        errno = 0;
        result = bpf_map_lookup_batch(collector->running_threads_fd,
                                      in_batch, &out_batch, keys, values,
                                      &count, &opts);
        lookup_errno = errno;
        /* Only ENOENT is a successful terminal batch. Other errors may leave
         * count unchanged, so none of the output entries are safe to consume. */
        if (result != 0 && lookup_errno != ENOENT)
            return result < 0 ? result : -lookup_errno;
        if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
            return -errno;
        now_ns = (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
        *snapshot_at_ns = now_ns;
        for (index = 0; index < count; ++index) {
            struct flamez_cpu_total *total = find_cpu_total(
                collector, total_count, values[index].tgid);

            if (total && values[index].running && now_ns >= values[index].started_at_ns)
                total->total_ns += now_ns - values[index].started_at_ns;
        }
        if (result == 0) {
            cursor = out_batch;
            in_batch = &cursor;
            continue;
        }
        if (lookup_errno == ENOENT)
            return 0;
        return result < 0 ? result : -lookup_errno;
    }
}

int flamez_ebpf_snapshot_cpu(struct flamez_ebpf *collector,
                             const struct flamez_cpu_total **out_samples,
                             size_t *out_count, uint64_t *out_timestamp_ns)
{
    struct timespec now;
    uint64_t snapshot_at_ns;
    size_t total_count;
    int result;

    if (!collector || collector->process_cpu_fd < 0 ||
        collector->running_threads_fd < 0 || !out_samples || !out_count ||
        !out_timestamp_ns)
        return -EINVAL;
    *out_samples = NULL;
    *out_count = 0;
    *out_timestamp_ns = 0;
    result = read_process_cpu_totals(collector, &total_count);
    if (result != 0)
        return result;
    result = rebuild_cpu_index(collector, total_count);
    if (result != 0)
        return result;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
        return -errno;
    snapshot_at_ns = (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
    result = add_running_cpu(collector, total_count, &snapshot_at_ns);
    if (result != 0)
        return result;
    *out_samples = collector->cpu_totals;
    *out_count = total_count;
    *out_timestamp_ns = snapshot_at_ns;
    return 0;
}

static int initialize_process_cpu(struct flamez_ebpf *collector, uint32_t key)
{
    struct flamez_process_cpu_snapshot initial = { .live_threads = 1 };

    if (bpf_map_update_elem(collector->process_cpu_fd, &key, &initial,
                            BPF_NOEXIST) == 0)
        return 0;
    return errno == EEXIST ? 0 : -errno;
}

int flamez_ebpf_track_pid(struct flamez_ebpf *collector, int32_t pid)
{
    uint32_t key = (uint32_t)pid;
    uint8_t value = 1;
    int result;

    if (!collector || collector->tracked_pids_fd < 0 || collector->process_cpu_fd < 0 ||
        pid <= 1)
        return -EINVAL;
    if (bpf_map_update_elem(collector->tracked_pids_fd, &key, &value, BPF_ANY) != 0)
        return -errno;
    result = initialize_process_cpu(collector, key);
    if (result != 0) {
        (void)bpf_map_delete_elem(collector->tracked_pids_fd, &key);
        return result;
    }
    return 0;
}

int flamez_ebpf_seed_parent(struct flamez_ebpf *collector, int32_t pid)
{
    uint32_t key = (uint32_t)pid;
    uint8_t value = 2;

    if (!collector || collector->tracked_pids_fd < 0 || pid <= 1)
        return -EINVAL;
    if (bpf_map_update_elem(collector->tracked_pids_fd, &key, &value, BPF_ANY) != 0)
        return -errno;
    return 0;
}

void flamez_ebpf_untrack_pid(struct flamez_ebpf *collector, int32_t pid)
{
    uint32_t key = (uint32_t)pid;

    if (!collector || collector->tracked_pids_fd < 0 || pid <= 1)
        return;
    (void)bpf_map_delete_elem(collector->tracked_pids_fd, &key);
    if (collector->process_cpu_fd >= 0)
        (void)bpf_map_delete_elem(collector->process_cpu_fd, &key);
}

void flamez_ebpf_close(struct flamez_ebpf *collector)
{
    destroy_collector(collector);
}

#if FLAMEZ_CAPTURE_TEST
/* A real shim with unavailable maps exercises snapshot failure without BPF
 * privileges. Only the empty lifecycle poll is substituted. */
struct flamez_ebpf *flamez_ebpf_test_empty(void)
{
    struct flamez_ebpf *collector = calloc(1, sizeof(*collector));

    if (!collector)
        return NULL;
    collector->test_empty = 1;
    collector->counters_fd = -1;
    collector->process_cpu_fd = -1;
    collector->running_threads_fd = -1;
    collector->tracked_pids_fd = -1;
    return collector;
}

int flamez_ebpf_test_failed_batch(void)
{
    struct flamez_ebpf collector = { .process_cpu_fd = INT_MAX };
    size_t count = 0;
    int result = read_process_cpu_totals(&collector, &count);
    int valid = result != 0 && count == 0 && collector.cpu_totals == NULL;

    free(collector.cpu_totals);
    return valid ? 0 : 1;
}

/* Opening and validating ELF metadata needs no BPF privileges. */
int flamez_ebpf_test_validate_object(const char *path, int writable,
                                     char *err, size_t err_size)
{
    struct bpf_object *object = bpf_object__open_file(path, NULL);
    struct bpf_map *map;
    int result;

    if (!object)
        return -errno;
    result = (int)libbpf_get_error(object);
    if (result)
        return result;
    if (writable) {
        bpf_object__for_each_map(map, object) {
            if (bpf_map__is_internal(map) &&
                (bpf_map__map_flags(map) & BPF_F_RDONLY_PROG))
                break;
        }
        if (!map) {
            bpf_object__close(object);
            return -ENOENT;
        }
        result = bpf_map__set_map_flags(map, bpf_map__map_flags(map) & ~BPF_F_RDONLY_PROG);
        if (result) {
            bpf_object__close(object);
            return result;
        }
    }
    result = validate_programs(object, path, err, err_size) ||
             validate_maps(object, path, err, err_size);
    bpf_object__close(object);
    return result;
}
#endif
