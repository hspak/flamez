#ifndef FLAMEZ_MACOS_ES_SHIM_H
#define FLAMEZ_MACOS_ES_SHIM_H

#include <stddef.h>
#include <stdint.h>

struct flamez_macos_es;

enum flamez_macos_es_open_result {
    FLAMEZ_MACOS_ES_OPEN_ACTIVE = 0,
    FLAMEZ_MACOS_ES_OPEN_UNAVAILABLE = 1,
    FLAMEZ_MACOS_ES_OPEN_NOT_ENTITLED = 2,
    FLAMEZ_MACOS_ES_OPEN_REJECTED = 3,
};

enum flamez_macos_es_event_kind {
    FLAMEZ_MACOS_ES_EVENT_FORK = 1,
    FLAMEZ_MACOS_ES_EVENT_EXEC = 2,
    FLAMEZ_MACOS_ES_EVENT_EXIT = 3,
};

struct flamez_macos_es_event {
    enum flamez_macos_es_event_kind kind;
    int32_t pid;
    int32_t parent_pid;
    int32_t pid_version;
    int32_t parent_pid_version;
    uint64_t timestamp_ns;
    uint64_t cpu_ns;
    const uint8_t *name;
    size_t name_len;
    const uint8_t *executable;
    size_t executable_len;
    uint8_t executable_truncated;
    const uint8_t *args;
    size_t args_len;
    const uint8_t *cwd;
    size_t cwd_len;
    uint8_t cwd_truncated;
    uint8_t cpu_final;
};

/* Event slices are borrowed only for the synchronous poll callback. */
typedef void (*flamez_macos_es_event_callback)(
    void *context,
    const struct flamez_macos_es_event *event);

/*
 * Attempts to create the macOS 27 descendant-scoped client. A non-active
 * result is recoverable and leaves *collector null so Flamez can use kqueue.
 */
enum flamez_macos_es_open_result flamez_macos_es_open(
    struct flamez_macos_es **collector,
    char *diagnostic,
    size_t diagnostic_size);

/* Must run on the thread that called flamez_macos_es_open. */
void flamez_macos_es_close(struct flamez_macos_es *collector);

/* Detaches the pending queue and invokes callback synchronously. */
int flamez_macos_es_poll(
    struct flamez_macos_es *collector,
    flamez_macos_es_event_callback callback,
    void *context);

/* Waits until every message ahead of an ES queue marker reached the handler. */
int flamez_macos_es_sync(struct flamez_macos_es *collector);

uint64_t flamez_macos_es_lost_events(struct flamez_macos_es *collector);

#ifdef FLAMEZ_TEST
/* Deterministic bridge validation without a live Endpoint Security client. */
struct flamez_macos_es *flamez_macos_es_test_create(size_t queue_limit);
void flamez_macos_es_test_destroy(struct flamez_macos_es *collector);
size_t flamez_macos_es_test_record_size(void);
int flamez_macos_es_test_enqueue(
    struct flamez_macos_es *collector,
    const struct flamez_macos_es_event *event);
void flamez_macos_es_test_capture_sequence(
    struct flamez_macos_es *collector,
    uint32_t message_version,
    uint64_t global_sequence);
void flamez_macos_es_test_capture_fixture(struct flamez_macos_es *collector);
uint64_t flamez_macos_es_test_mach_time_to_ns(uint64_t value);
uint64_t flamez_macos_es_test_mach_now_to_ns(void);
void flamez_macos_es_test_prepare_sync(
    struct flamez_macos_es *collector,
    int reject);
void flamez_macos_es_test_complete_sync(struct flamez_macos_es *collector);
#endif

#endif
