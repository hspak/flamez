#ifndef FLAMEZ_MACOS_SHIM_H
#define FLAMEZ_MACOS_SHIM_H

#include <stddef.h>
#include <stdint.h>

struct flamez_macos_process_identity {
    int32_t parent_pid;
    int32_t pid_version;
    uint64_t start_seconds;
    uint64_t start_microseconds;
    uint64_t unique_id;
    uint64_t parent_unique_id;
    int32_t parent_pid_version;
    uint32_t reserved;
};

int flamez_macos_process_identity(int32_t pid,
                                  struct flamez_macos_process_identity *identity);
int flamez_macos_spawn_suspended(const char *const *argv, int32_t *pid);
int flamez_macos_resume_process(int32_t pid);
int flamez_macos_abstime_to_nanoseconds(uint64_t abstime, uint64_t *nanoseconds);
int flamez_macos_cpu_time(int32_t pid, uint64_t *total_ns);
int flamez_macos_read_executable(int32_t pid, void *buffer, size_t buffer_size);
int flamez_macos_read_cwd(int32_t pid, void *buffer, size_t buffer_size);
int flamez_macos_read_procargs(int32_t pid, void *buffer, size_t *buffer_size);

#endif
