#ifndef FLAMEZ_EVENT_H
#define FLAMEZ_EVENT_H

#include <linux/types.h>

#define FLAMEZ_COMM_LEN 16
#define FLAMEZ_MAX_ARGS (6U * 1024U * 1024U)
#define FLAMEZ_MAX_PATH 512
#define FLAMEZ_EVENT_ABI_VERSION 7

enum flamez_event_kind {
    FLAMEZ_EVENT_FORK = 1,
    FLAMEZ_EVENT_EXEC = 2,
    FLAMEZ_EVENT_EXIT = 3,
};

enum flamez_metadata_flag {
    FLAMEZ_METADATA_ARGS = 1U << 0,
    FLAMEZ_METADATA_EXE = 1U << 1,
    FLAMEZ_METADATA_EXE_TRUNCATED = 1U << 3,
};

struct flamez_event {
    __u32 kind;
    __s32 pid;
    __s32 parent_pid;
    __u32 metadata_flags;
    __u64 timestamp_ns;
    char comm[FLAMEZ_COMM_LEN];
    __u32 args_len;
    __u16 exe_len;
    __u16 reserved;
    __u64 cpu_ns;
};

struct flamez_exec_event {
    struct flamez_event base;
    char exe[FLAMEZ_MAX_PATH];
    char args[];
};

_Static_assert(sizeof(struct flamez_event) == 56, "flamez event header ABI changed");
_Static_assert(sizeof(struct flamez_exec_event) == 568, "flamez exec header ABI changed");

#endif
