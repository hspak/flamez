/* Native helper replacements for exercising the actual tracepoint programs. */
#ifndef FLAMEZ_BPF_TEST_H
#define FLAMEZ_BPF_TEST_H

#include <stddef.h>
#include <string.h>

#define SEC(name)
#define __uint(name, value) int (*name)[value]
#define __type(name, value) value *name
#define BPF_CORE_READ(source, field) ((source)->field)
#define bpf_core_read(destination, size, source) memcpy(destination, source, size)

int handle_thread_create(struct bpf_raw_tracepoint_args *) __attribute__((weak));

static void *bpf_map_lookup_elem(const void *, const void *);
static long bpf_map_update_elem(const void *, const void *, const void *, unsigned long long);
static long bpf_map_delete_elem(const void *, const void *);
static unsigned long long bpf_ktime_get_ns(void);
static unsigned long long bpf_get_current_pid_tgid(void);
static long bpf_get_current_comm(void *, unsigned int);
static void *bpf_ringbuf_reserve(void *, unsigned long long, unsigned long long);
static void bpf_ringbuf_submit(void *, unsigned long long);
static long bpf_ringbuf_reserve_dynptr(void *, unsigned long long, unsigned long long,
                                     struct bpf_dynptr *);
static void bpf_ringbuf_discard_dynptr(struct bpf_dynptr *, unsigned long long);
static void bpf_ringbuf_submit_dynptr(struct bpf_dynptr *, unsigned long long);
static void *bpf_dynptr_data(const struct bpf_dynptr *, unsigned int, unsigned int);
static long bpf_probe_read_user(void *, unsigned int, const void *);
static long bpf_probe_read_kernel_str(void *, unsigned int, const void *);

#endif
