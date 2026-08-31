#include "macos_shim.h"

#include <crt_externs.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <unistd.h>

#define FLAMEZ_PROC_PIDT_BSDINFOWITHUNIQID 18

struct flamez_proc_uniqidentifierinfo {
    uint8_t executable_uuid[16];
    uint64_t unique_id;
    uint64_t parent_unique_id;
    int32_t pid_version;
    int32_t original_parent_pid_version;
    uint64_t reserved2;
    uint64_t reserved3;
};

struct flamez_proc_bsdinfowithuniqid {
    struct proc_bsdinfo bsd;
    struct flamez_proc_uniqidentifierinfo identifier;
};

_Static_assert(sizeof(struct flamez_proc_uniqidentifierinfo) == 56,
               "private process identifier layout changed");
_Static_assert(sizeof(struct flamez_macos_process_identity) == 48,
               "project process identity layout changed");

#define FLAMEZ_ASSERT_PROCESS_IDENTITY_OFFSET(field, expected)                \
    _Static_assert(                                                           \
        offsetof(struct flamez_macos_process_identity, field) == (expected),  \
        "process identity field offset changed: " #field)

FLAMEZ_ASSERT_PROCESS_IDENTITY_OFFSET(parent_pid, 0);
FLAMEZ_ASSERT_PROCESS_IDENTITY_OFFSET(pid_version, 4);
FLAMEZ_ASSERT_PROCESS_IDENTITY_OFFSET(start_seconds, 8);
FLAMEZ_ASSERT_PROCESS_IDENTITY_OFFSET(start_microseconds, 16);
FLAMEZ_ASSERT_PROCESS_IDENTITY_OFFSET(unique_id, 24);
FLAMEZ_ASSERT_PROCESS_IDENTITY_OFFSET(parent_unique_id, 32);
FLAMEZ_ASSERT_PROCESS_IDENTITY_OFFSET(parent_pid_version, 40);
FLAMEZ_ASSERT_PROCESS_IDENTITY_OFFSET(reserved, 44);

#undef FLAMEZ_ASSERT_PROCESS_IDENTITY_OFFSET

int flamez_macos_process_identity(int32_t pid,
                                  struct flamez_macos_process_identity *identity)
{
    struct flamez_proc_bsdinfowithuniqid info = {0};
    int amount;

    if (identity == NULL) {
        return EINVAL;
    }
    amount = proc_pidinfo(pid,
                          FLAMEZ_PROC_PIDT_BSDINFOWITHUNIQID,
                          0,
                          &info,
                          sizeof(info));
    if (amount != (int)sizeof(info)) {
        return errno != 0 ? errno : ESRCH;
    }
    identity->parent_pid = (int32_t)info.bsd.pbi_ppid;
    identity->pid_version = info.identifier.pid_version;
    identity->start_seconds = info.bsd.pbi_start_tvsec;
    identity->start_microseconds = info.bsd.pbi_start_tvusec;
    identity->unique_id = info.identifier.unique_id;
    identity->parent_unique_id = info.identifier.parent_unique_id;
    identity->parent_pid_version = info.identifier.original_parent_pid_version;
    identity->reserved = 0;
    return 0;
}

int flamez_macos_spawn_suspended(const char *const *argv, int32_t *pid)
{
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_t actions;
    pid_t child_pid;
    short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED;
    int result;

    if (argv == NULL || argv[0] == NULL || pid == NULL) {
        return EINVAL;
    }
    result = posix_spawnattr_init(&attributes);
    if (result != 0) {
        return result;
    }
    result = posix_spawn_file_actions_init(&actions);
    if (result != 0) {
        (void)posix_spawnattr_destroy(&attributes);
        return result;
    }
    result = posix_spawnattr_setpgroup(&attributes, 0);
    if (result == 0) {
        result = posix_spawnattr_setflags(&attributes, flags);
    }
    if (result == 0) {
        result = posix_spawn_file_actions_addopen(
            &actions,
            STDIN_FILENO,
            "/dev/null",
            O_RDONLY,
            0);
    }
    if (result == 0) {
        result = posix_spawnp(
            &child_pid,
            argv[0],
            &actions,
            &attributes,
            (char *const *)argv,
            *_NSGetEnviron());
    }
    (void)posix_spawn_file_actions_destroy(&actions);
    (void)posix_spawnattr_destroy(&attributes);
    if (result == 0) {
        *pid = child_pid;
    }
    return result;
}

int flamez_macos_resume_process(int32_t pid)
{
    if (kill(pid, SIGCONT) == 0) {
        return 0;
    }
    return errno != 0 ? errno : ESRCH;
}

static mach_timebase_info_data_t flamez_timebase;
static int flamez_timebase_status = EIO;
static pthread_once_t flamez_timebase_once = PTHREAD_ONCE_INIT;

static void flamez_initialize_timebase(void)
{
    if (mach_timebase_info(&flamez_timebase) == KERN_SUCCESS &&
        flamez_timebase.denom != 0) {
        flamez_timebase_status = 0;
    }
}

int flamez_macos_abstime_to_nanoseconds(uint64_t abstime, uint64_t *nanoseconds)
{
    __uint128_t scaled;
    int result;

    if (nanoseconds == NULL) {
        return EINVAL;
    }
    result = pthread_once(&flamez_timebase_once, flamez_initialize_timebase);
    if (result != 0) {
        return result;
    }
    if (flamez_timebase_status != 0) {
        return flamez_timebase_status;
    }
    scaled = (__uint128_t)abstime *
        flamez_timebase.numer / flamez_timebase.denom;
    *nanoseconds = scaled > UINT64_MAX ? UINT64_MAX : (uint64_t)scaled;
    return 0;
}

static int flamez_cpu_time_to_nanoseconds(uint64_t user_abstime,
                                          uint64_t system_abstime,
                                          uint64_t *total_ns)
{
    uint64_t total_abstime;

    if (UINT64_MAX - user_abstime < system_abstime) {
        total_abstime = UINT64_MAX;
    } else {
        total_abstime = user_abstime + system_abstime;
    }
    return flamez_macos_abstime_to_nanoseconds(total_abstime, total_ns);
}

int flamez_macos_cpu_time(int32_t pid, uint64_t *total_ns)
{
    struct rusage_info_v6 usage = {0};

    if (total_ns == NULL) {
        return EINVAL;
    }
    if (proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, (rusage_info_t *)&usage) != 0) {
        return errno != 0 ? errno : ESRCH;
    }
    /* XNU exposes recount CPU totals in Mach absolute-time units. The
     * timebase is not 1:1 on Apple silicon. */
    return flamez_cpu_time_to_nanoseconds(usage.ri_user_time,
                                          usage.ri_system_time,
                                          total_ns);
}

int flamez_macos_read_executable(int32_t pid, void *buffer, size_t buffer_size)
{
    char path[PROC_PIDPATHINFO_MAXSIZE];
    size_t length;
    int amount;

    if (buffer == NULL || buffer_size == 0) {
        return -EINVAL;
    }
    amount = proc_pidpath(pid, path, sizeof(path));
    if (amount <= 0) {
        return -(errno != 0 ? errno : ESRCH);
    }
    length = (size_t)amount;
    if (length > 0 && path[length - 1] == '\0') {
        length--;
    }
    if (length > buffer_size) {
        length = buffer_size;
    }
    memcpy(buffer, path, length);
    return (int)length;
}

int flamez_macos_read_cwd(int32_t pid, void *buffer, size_t buffer_size)
{
    struct proc_vnodepathinfo paths = {0};
    const char *path;
    size_t length = 0;
    int amount;

    if (buffer == NULL || buffer_size == 0 || buffer_size > INT_MAX) {
        return -EINVAL;
    }
    amount = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &paths, sizeof(paths));
    if (amount != (int)sizeof(paths)) {
        return -(errno != 0 ? errno : ESRCH);
    }
    path = paths.pvi_cdir.vip_path;
    while (length < sizeof(paths.pvi_cdir.vip_path) && path[length] != '\0') {
        length++;
    }
    if (length == 0) {
        return -ENOENT;
    }
    if (length > buffer_size) {
        return -ERANGE;
    }
    memcpy(buffer, path, length);
    return (int)length;
}

int flamez_macos_read_procargs(int32_t pid, void *buffer, size_t *buffer_size)
{
    int mib[] = {CTL_KERN, KERN_PROCARGS2, pid};

    if (buffer_size == NULL) {
        return EINVAL;
    }
    if (sysctl(mib, 3, buffer, buffer_size, NULL, 0) != 0) {
        return errno != 0 ? errno : EIO;
    }
    return 0;
}
