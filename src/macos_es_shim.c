#include "macos_es_shim.h"

#include "macos_shim.h"

#include <EndpointSecurity/EndpointSecurity.h>
#include <bsm/libbsm.h>
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef FLAMEZ_TEST
#include <Block.h>
#endif

#define FLAMEZ_MACOS_ES_QUEUE_BYTES (16U * 1024U * 1024U)

struct flamez_macos_es_record {
    struct flamez_macos_es_record *next;
    size_t allocation_size;
    struct flamez_macos_es_event event;
    uint8_t storage[];
};

struct flamez_macos_es {
    es_client_t *client;
    void *es_library;
    void *bsm_library;
    pthread_t creator;
    pthread_mutex_t mutex;
    struct flamez_macos_es_record *head;
    struct flamez_macos_es_record *tail;
    size_t queued_bytes;
    size_t queue_limit;
    uint64_t lost_events;
    uint64_t last_global_sequence;
    bool has_global_sequence;
    es_return_t (*subscribe)(
        es_client_t *client,
        const es_event_type_t *events,
        uint32_t event_count);
    es_return_t (*sync_client)(es_client_t *client, void (^block)(void));
    es_return_t (*delete_client)(es_client_t *client);
    uint32_t (*exec_arg_count)(const es_event_exec_t *event);
    es_string_token_t (*exec_arg)(const es_event_exec_t *event, uint32_t index);
    pid_t (*audit_pid)(audit_token_t token);
    int (*audit_pid_version)(audit_token_t token);
    int (*cpu_time)(int32_t pid, uint64_t *total_ns);
#ifdef FLAMEZ_TEST
    pthread_cond_t test_sync_condition;
    void (^test_sync_block)(void);
    bool test_sync_reject;
#endif
};

_Static_assert(
    sizeof(struct flamez_macos_es_event) == 120,
    "macOS ES event ABI changed");

#define FLAMEZ_ASSERT_ES_EVENT_OFFSET(field, expected)                        \
    _Static_assert(                                                           \
        offsetof(struct flamez_macos_es_event, field) == (expected),          \
        "macOS ES event field offset changed: " #field)

FLAMEZ_ASSERT_ES_EVENT_OFFSET(kind, 0);
FLAMEZ_ASSERT_ES_EVENT_OFFSET(pid, 4);
FLAMEZ_ASSERT_ES_EVENT_OFFSET(parent_pid, 8);
FLAMEZ_ASSERT_ES_EVENT_OFFSET(pid_version, 12);
FLAMEZ_ASSERT_ES_EVENT_OFFSET(parent_pid_version, 16);
FLAMEZ_ASSERT_ES_EVENT_OFFSET(timestamp_ns, 24);
FLAMEZ_ASSERT_ES_EVENT_OFFSET(cpu_ns, 32);
FLAMEZ_ASSERT_ES_EVENT_OFFSET(name, 40);
FLAMEZ_ASSERT_ES_EVENT_OFFSET(name_len, 48);
FLAMEZ_ASSERT_ES_EVENT_OFFSET(executable, 56);
FLAMEZ_ASSERT_ES_EVENT_OFFSET(executable_len, 64);
FLAMEZ_ASSERT_ES_EVENT_OFFSET(executable_truncated, 72);
FLAMEZ_ASSERT_ES_EVENT_OFFSET(args, 80);
FLAMEZ_ASSERT_ES_EVENT_OFFSET(args_len, 88);
FLAMEZ_ASSERT_ES_EVENT_OFFSET(cwd, 96);
FLAMEZ_ASSERT_ES_EVENT_OFFSET(cwd_len, 104);
FLAMEZ_ASSERT_ES_EVENT_OFFSET(cwd_truncated, 112);
FLAMEZ_ASSERT_ES_EVENT_OFFSET(cpu_final, 113);

#undef FLAMEZ_ASSERT_ES_EVENT_OFFSET

typedef es_new_client_result_t (*flamez_new_descendants_client_fn)(
    es_client_t **client,
    es_handler_block_t handler);

/* The macOS 26 build SDK predates this declaration. When a newer SDK is used,
 * make the compiler prove that the compatibility declaration still matches
 * Apple's public header instead of trusting the dlsym cast. */
#if defined(__MAC_OS_X_VERSION_MAX_ALLOWED) &&                                \
    __MAC_OS_X_VERSION_MAX_ALLOWED >= 270000
_Static_assert(
    __builtin_types_compatible_p(
        flamez_new_descendants_client_fn,
        __typeof__(&es_new_descendants_client)),
    "es_new_descendants_client declaration changed");
#endif

#define FLAMEZ_LOAD_FUNCTION(target, library, name)                            \
    do {                                                                       \
        void *flamez_symbol = dlsym((library), (name));                        \
        _Static_assert(                                                        \
            sizeof(flamez_symbol) == sizeof(target),                          \
            "function pointer size changed");                                \
        memcpy(&(target), &flamez_symbol, sizeof(target));                     \
    } while (0)

static void flamez_set_diagnostic(
    char *diagnostic,
    size_t diagnostic_size,
    const char *message)
{
    if (diagnostic == NULL || diagnostic_size == 0) {
        return;
    }
    (void)snprintf(diagnostic, diagnostic_size, "%s", message);
}

static bool flamez_add_size(size_t *total, size_t amount)
{
    if (SIZE_MAX - *total < amount) {
        return false;
    }
    *total += amount;
    return true;
}

static es_string_token_t flamez_basename(es_string_token_t path)
{
    size_t start = 0;
    size_t index;

    for (index = 0; index < path.length; ++index) {
        if (path.data[index] == '/') {
            start = index + 1;
        }
    }
    return (es_string_token_t){
        .length = path.length - start,
        .data = path.data + start,
    };
}

static uint8_t *flamez_copy_token(uint8_t *destination, es_string_token_t token)
{
    if (token.length > 0) {
        memcpy(destination, token.data, token.length);
    }
    return destination + token.length;
}

static uint64_t flamez_mach_time_to_ns(uint64_t value)
{
    uint64_t nanoseconds = 0;

    (void)flamez_macos_abstime_to_nanoseconds(value, &nanoseconds);
    return nanoseconds;
}

static void flamez_note_loss_locked(
    struct flamez_macos_es *collector,
    uint64_t amount)
{
    if (UINT64_MAX - collector->lost_events < amount) {
        collector->lost_events = UINT64_MAX;
    } else {
        collector->lost_events += amount;
    }
}

static void flamez_note_loss(struct flamez_macos_es *collector, uint64_t amount)
{
    if (pthread_mutex_lock(&collector->mutex) != 0) {
        return;
    }
    flamez_note_loss_locked(collector, amount);
    (void)pthread_mutex_unlock(&collector->mutex);
}

static void flamez_enqueue(
    struct flamez_macos_es *collector,
    struct flamez_macos_es_record *record)
{
    int lock_result = pthread_mutex_lock(&collector->mutex);

    if (lock_result != 0) {
        free(record);
        return;
    }
    if (collector->queued_bytes >
        collector->queue_limit - record->allocation_size) {
        flamez_note_loss_locked(collector, 1);
        (void)pthread_mutex_unlock(&collector->mutex);
        free(record);
        return;
    }
    if (collector->tail == NULL) {
        collector->head = record;
    } else {
        collector->tail->next = record;
    }
    collector->tail = record;
    collector->queued_bytes += record->allocation_size;
    (void)pthread_mutex_unlock(&collector->mutex);
}

static struct flamez_macos_es_record *flamez_allocate_record(
    struct flamez_macos_es *collector,
    size_t storage_size)
{
    struct flamez_macos_es_record *record;
    size_t allocation_size = sizeof(*record);

    if (!flamez_add_size(&allocation_size, storage_size)) {
        flamez_note_loss(collector, 1);
        return NULL;
    }
    if (allocation_size > collector->queue_limit) {
        flamez_note_loss(collector, 1);
        return NULL;
    }
    record = calloc(1, allocation_size);
    if (record == NULL) {
        flamez_note_loss(collector, 1);
        return NULL;
    }
    record->allocation_size = allocation_size;
    return record;
}

static void flamez_capture_sequence_value(
    struct flamez_macos_es *collector,
    uint32_t version,
    uint64_t global_sequence)
{
    uint64_t expected;

    if (version < 4) {
        return;
    }
    if (collector->has_global_sequence) {
        expected = collector->last_global_sequence + 1;
        if (expected != 0 && global_sequence > expected) {
            flamez_note_loss(collector, global_sequence - expected);
        }
    }
    collector->last_global_sequence = global_sequence;
    collector->has_global_sequence = true;
}

static void flamez_capture_sequence(
    struct flamez_macos_es *collector,
    const es_message_t *message)
{
    if (message->version < 4) {
        return;
    }
    flamez_capture_sequence_value(
        collector,
        message->version,
        message->global_seq_num);
}

static void flamez_capture_fork(
    struct flamez_macos_es *collector,
    const es_message_t *message)
{
    const es_process_t *parent = message->process;
    const es_process_t *child = message->event.fork.child;
    es_string_token_t name = flamez_basename(child->executable->path);
    struct flamez_macos_es_record *record =
        flamez_allocate_record(collector, name.length);

    if (record == NULL) {
        return;
    }
    record->event.kind = FLAMEZ_MACOS_ES_EVENT_FORK;
    record->event.pid = collector->audit_pid(child->audit_token);
    record->event.parent_pid = collector->audit_pid(parent->audit_token);
    record->event.pid_version = collector->audit_pid_version(child->audit_token);
    record->event.parent_pid_version =
        collector->audit_pid_version(parent->audit_token);
    record->event.timestamp_ns = flamez_mach_time_to_ns(message->mach_time);
    record->event.name = record->storage;
    record->event.name_len = name.length;
    (void)flamez_copy_token(record->storage, name);
    flamez_enqueue(collector, record);
}

static bool flamez_exec_storage_size(
    struct flamez_macos_es *collector,
    const es_event_exec_t *exec,
    es_string_token_t name,
    es_string_token_t executable,
    es_string_token_t cwd,
    size_t *storage_size,
    size_t *args_size)
{
    uint32_t index;
    uint32_t count = collector->exec_arg_count(exec);

    *storage_size = 0;
    *args_size = 0;
    if (!flamez_add_size(storage_size, name.length) ||
        !flamez_add_size(storage_size, executable.length) ||
        !flamez_add_size(storage_size, cwd.length)) {
        return false;
    }
    for (index = 0; index < count; ++index) {
        es_string_token_t arg = collector->exec_arg(exec, index);
        if (!flamez_add_size(args_size, arg.length) ||
            !flamez_add_size(args_size, 1)) {
            return false;
        }
    }
    return flamez_add_size(storage_size, *args_size);
}

static void flamez_capture_exec(
    struct flamez_macos_es *collector,
    const es_message_t *message)
{
    const es_event_exec_t *exec = &message->event.exec;
    const es_process_t *target = exec->target;
    es_string_token_t executable = target->executable->path;
    es_string_token_t name = flamez_basename(executable);
    es_string_token_t cwd = {0};
    struct flamez_macos_es_record *record;
    uint8_t *cursor;
    size_t storage_size;
    size_t args_size;
    uint32_t index;
    uint32_t count;

    if (message->version >= 3 && exec->cwd != NULL) {
        cwd = exec->cwd->path;
    }
    if (!flamez_exec_storage_size(
            collector,
            exec,
            name,
            executable,
            cwd,
            &storage_size,
            &args_size)) {
        flamez_note_loss(collector, 1);
        return;
    }
    record = flamez_allocate_record(collector, storage_size);
    if (record == NULL) {
        return;
    }
    record->event.kind = FLAMEZ_MACOS_ES_EVENT_EXEC;
    record->event.pid = collector->audit_pid(target->audit_token);
    record->event.pid_version = collector->audit_pid_version(target->audit_token);
    record->event.timestamp_ns = flamez_mach_time_to_ns(message->mach_time);
    cursor = record->storage;
    record->event.name = cursor;
    record->event.name_len = name.length;
    cursor = flamez_copy_token(cursor, name);
    record->event.executable = cursor;
    record->event.executable_len = executable.length;
    record->event.executable_truncated = target->executable->path_truncated;
    cursor = flamez_copy_token(cursor, executable);
    record->event.args = cursor;
    record->event.args_len = args_size;
    count = collector->exec_arg_count(exec);
    for (index = 0; index < count; ++index) {
        es_string_token_t arg = collector->exec_arg(exec, index);
        cursor = flamez_copy_token(cursor, arg);
        *cursor++ = '\0';
    }
    record->event.cwd = cursor;
    record->event.cwd_len = cwd.length;
    record->event.cwd_truncated =
        message->version >= 3 && exec->cwd != NULL && exec->cwd->path_truncated;
    (void)flamez_copy_token(cursor, cwd);
    flamez_enqueue(collector, record);
}

static void flamez_capture_exit(
    struct flamez_macos_es *collector,
    const es_message_t *message)
{
    const es_process_t *process = message->process;
    es_string_token_t name = flamez_basename(process->executable->path);
    struct flamez_macos_es_record *record =
        flamez_allocate_record(collector, name.length);
    uint64_t cpu_ns = 0;

    if (record == NULL) {
        return;
    }
    record->event.kind = FLAMEZ_MACOS_ES_EVENT_EXIT;
    record->event.pid = collector->audit_pid(process->audit_token);
    record->event.pid_version = collector->audit_pid_version(process->audit_token);
    record->event.timestamp_ns = flamez_mach_time_to_ns(message->mach_time);
    if (collector->cpu_time(record->event.pid, &cpu_ns) == 0) {
        record->event.cpu_ns = cpu_ns;
        record->event.cpu_final = 1;
    }
    record->event.name = record->storage;
    record->event.name_len = name.length;
    (void)flamez_copy_token(record->storage, name);
    flamez_enqueue(collector, record);
}

static void flamez_capture_message(
    struct flamez_macos_es *collector,
    const es_message_t *message)
{
    flamez_capture_sequence(collector, message);
    switch (message->event_type) {
    case ES_EVENT_TYPE_NOTIFY_FORK:
        flamez_capture_fork(collector, message);
        break;
    case ES_EVENT_TYPE_NOTIFY_EXEC:
        flamez_capture_exec(collector, message);
        break;
    case ES_EVENT_TYPE_NOTIFY_EXIT:
        flamez_capture_exit(collector, message);
        break;
    default:
        break;
    }
}

static flamez_new_descendants_client_fn flamez_find_descendants_client(
    void *library)
{
    void *symbol = dlsym(library, "es_new_descendants_client");
    flamez_new_descendants_client_fn function = NULL;

    _Static_assert(sizeof(symbol) == sizeof(function), "function pointer size changed");
    memcpy(&function, &symbol, sizeof(function));
    return function;
}

enum flamez_macos_es_open_result flamez_macos_es_open(
    struct flamez_macos_es **collector,
    char *diagnostic,
    size_t diagnostic_size)
{
    flamez_new_descendants_client_fn create_client;
    struct flamez_macos_es *result;
    void *es_library;
    void *bsm_library;
    es_new_client_result_t create_result;
    es_event_type_t events[] = {
        ES_EVENT_TYPE_NOTIFY_FORK,
        ES_EVENT_TYPE_NOTIFY_EXEC,
        ES_EVENT_TYPE_NOTIFY_EXIT,
    };

    if (collector == NULL) {
        return FLAMEZ_MACOS_ES_OPEN_REJECTED;
    }
    *collector = NULL;
    es_library = dlopen(
        "/usr/lib/libEndpointSecurity.dylib",
        RTLD_LAZY | RTLD_LOCAL);
    if (es_library == NULL) {
        flamez_set_diagnostic(
            diagnostic,
            diagnostic_size,
            "the Endpoint Security runtime library is unavailable");
        return FLAMEZ_MACOS_ES_OPEN_UNAVAILABLE;
    }
    create_client = flamez_find_descendants_client(es_library);
    if (create_client == NULL) {
        (void)dlclose(es_library);
        flamez_set_diagnostic(
            diagnostic,
            diagnostic_size,
            "exact capture requires the macOS 27 descendant Endpoint Security API");
        return FLAMEZ_MACOS_ES_OPEN_UNAVAILABLE;
    }
    bsm_library = dlopen("/usr/lib/libbsm.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (bsm_library == NULL) {
        (void)dlclose(es_library);
        flamez_set_diagnostic(
            diagnostic,
            diagnostic_size,
            "the audit-token runtime library is unavailable");
        return FLAMEZ_MACOS_ES_OPEN_REJECTED;
    }
    result = calloc(1, sizeof(*result));
    if (result == NULL) {
        (void)dlclose(bsm_library);
        (void)dlclose(es_library);
        flamez_set_diagnostic(
            diagnostic,
            diagnostic_size,
            "could not allocate the descendant Endpoint Security collector");
        return FLAMEZ_MACOS_ES_OPEN_REJECTED;
    }
    result->queue_limit = FLAMEZ_MACOS_ES_QUEUE_BYTES;
    result->cpu_time = flamez_macos_cpu_time;
    result->es_library = es_library;
    result->bsm_library = bsm_library;
    FLAMEZ_LOAD_FUNCTION(result->subscribe, es_library, "es_subscribe");
    FLAMEZ_LOAD_FUNCTION(result->sync_client, es_library, "es_sync_client");
    FLAMEZ_LOAD_FUNCTION(result->delete_client, es_library, "es_delete_client");
    FLAMEZ_LOAD_FUNCTION(result->exec_arg_count, es_library, "es_exec_arg_count");
    FLAMEZ_LOAD_FUNCTION(result->exec_arg, es_library, "es_exec_arg");
    FLAMEZ_LOAD_FUNCTION(result->audit_pid, bsm_library, "audit_token_to_pid");
    FLAMEZ_LOAD_FUNCTION(
        result->audit_pid_version,
        bsm_library,
        "audit_token_to_pidversion");
    if (result->subscribe == NULL ||
        result->sync_client == NULL ||
        result->delete_client == NULL ||
        result->exec_arg_count == NULL ||
        result->exec_arg == NULL ||
        result->audit_pid == NULL ||
        result->audit_pid_version == NULL) {
        (void)dlclose(result->bsm_library);
        (void)dlclose(result->es_library);
        free(result);
        flamez_set_diagnostic(
            diagnostic,
            diagnostic_size,
            "the Endpoint Security runtime ABI is incomplete");
        return FLAMEZ_MACOS_ES_OPEN_REJECTED;
    }
    if (pthread_mutex_init(&result->mutex, NULL) != 0) {
        (void)dlclose(result->bsm_library);
        (void)dlclose(result->es_library);
        free(result);
        flamez_set_diagnostic(
            diagnostic,
            diagnostic_size,
            "could not initialize the descendant Endpoint Security queue");
        return FLAMEZ_MACOS_ES_OPEN_REJECTED;
    }
    result->creator = pthread_self();
    create_result = create_client(
        &result->client,
        ^(es_client_t *client, const es_message_t *message) {
            (void)client;
            flamez_capture_message(result, message);
        });
    if (create_result != ES_NEW_CLIENT_RESULT_SUCCESS) {
        (void)pthread_mutex_destroy(&result->mutex);
        (void)dlclose(result->bsm_library);
        (void)dlclose(result->es_library);
        free(result);
        switch (create_result) {
        case ES_NEW_CLIENT_RESULT_ERR_NOT_ENTITLED:
            flamez_set_diagnostic(
                diagnostic,
                diagnostic_size,
                "exact capture requires the Endpoint Security client entitlement");
            return FLAMEZ_MACOS_ES_OPEN_NOT_ENTITLED;
        case ES_NEW_CLIENT_RESULT_ERR_INVALID_ARGUMENT:
            flamez_set_diagnostic(
                diagnostic,
                diagnostic_size,
                "the descendant Endpoint Security runtime rejected the client ABI");
            break;
        case ES_NEW_CLIENT_RESULT_ERR_INTERNAL:
            flamez_set_diagnostic(
                diagnostic,
                diagnostic_size,
                "communication with the Endpoint Security subsystem failed");
            break;
        case ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED:
            flamez_set_diagnostic(
                diagnostic,
                diagnostic_size,
                "Endpoint Security denied the client permission");
            break;
        case ES_NEW_CLIENT_RESULT_ERR_NOT_PRIVILEGED:
            flamez_set_diagnostic(
                diagnostic,
                diagnostic_size,
                "Endpoint Security unexpectedly required a privileged client");
            break;
        case ES_NEW_CLIENT_RESULT_ERR_TOO_MANY_CLIENTS:
            flamez_set_diagnostic(
                diagnostic,
                diagnostic_size,
                "the Endpoint Security client limit has been reached");
            break;
        case ES_NEW_CLIENT_RESULT_SUCCESS:
            break;
        default:
            flamez_set_diagnostic(
                diagnostic,
                diagnostic_size,
                "the descendant Endpoint Security client returned an unknown error");
            break;
        }
        return FLAMEZ_MACOS_ES_OPEN_REJECTED;
    }
    if (result->subscribe(result->client, events, 3) != ES_RETURN_SUCCESS) {
        (void)result->delete_client(result->client);
        (void)pthread_mutex_destroy(&result->mutex);
        (void)dlclose(result->bsm_library);
        (void)dlclose(result->es_library);
        free(result);
        flamez_set_diagnostic(
            diagnostic,
            diagnostic_size,
            "the descendant Endpoint Security client rejected subscriptions");
        return FLAMEZ_MACOS_ES_OPEN_REJECTED;
    }
    *collector = result;
    flamez_set_diagnostic(
        diagnostic,
        diagnostic_size,
        "using exact descendant-scoped Endpoint Security capture");
    return FLAMEZ_MACOS_ES_OPEN_ACTIVE;
}

void flamez_macos_es_close(struct flamez_macos_es *collector)
{
    struct flamez_macos_es_record *record;
    struct flamez_macos_es_record *next;

    if (collector == NULL) {
        return;
    }
    if (!pthread_equal(collector->creator, pthread_self())) {
        return;
    }
    (void)collector->delete_client(collector->client);
    (void)pthread_mutex_lock(&collector->mutex);
    record = collector->head;
    collector->head = NULL;
    collector->tail = NULL;
    collector->queued_bytes = 0;
    (void)pthread_mutex_unlock(&collector->mutex);
    while (record != NULL) {
        next = record->next;
        free(record);
        record = next;
    }
    (void)pthread_mutex_destroy(&collector->mutex);
    (void)dlclose(collector->bsm_library);
    (void)dlclose(collector->es_library);
    free(collector);
}

int flamez_macos_es_poll(
    struct flamez_macos_es *collector,
    flamez_macos_es_event_callback callback,
    void *context)
{
    struct flamez_macos_es_record *record;
    struct flamez_macos_es_record *next;
    int count = 0;

    if (collector == NULL || callback == NULL) {
        return 0;
    }
    (void)pthread_mutex_lock(&collector->mutex);
    record = collector->head;
    collector->head = NULL;
    collector->tail = NULL;
    collector->queued_bytes = 0;
    (void)pthread_mutex_unlock(&collector->mutex);
    while (record != NULL) {
        next = record->next;
        callback(context, &record->event);
        free(record);
        record = next;
        if (count < INT_MAX) {
            ++count;
        }
    }
    return count;
}

struct flamez_macos_es_sync_waiter {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    bool complete;
};

int flamez_macos_es_sync(struct flamez_macos_es *collector)
{
    struct flamez_macos_es_sync_waiter waiter;
    struct flamez_macos_es_sync_waiter *waiter_ptr = &waiter;
    es_return_t result;
    int wait_result = 0;

    if (collector == NULL || collector->sync_client == NULL) {
        return EINVAL;
    }
    if (pthread_mutex_init(&waiter.mutex, NULL) != 0) {
        return EIO;
    }
    if (pthread_cond_init(&waiter.condition, NULL) != 0) {
        (void)pthread_mutex_destroy(&waiter.mutex);
        return EIO;
    }
    waiter.complete = false;
    result = collector->sync_client(collector->client, ^{
        (void)pthread_mutex_lock(&waiter_ptr->mutex);
        waiter_ptr->complete = true;
        (void)pthread_cond_signal(&waiter_ptr->condition);
        (void)pthread_mutex_unlock(&waiter_ptr->mutex);
    });
    if (result != ES_RETURN_SUCCESS) {
        (void)pthread_cond_destroy(&waiter.condition);
        (void)pthread_mutex_destroy(&waiter.mutex);
        return EIO;
    }

    (void)pthread_mutex_lock(&waiter.mutex);
    while (!waiter.complete && wait_result == 0) {
        wait_result = pthread_cond_wait(&waiter.condition, &waiter.mutex);
    }
    (void)pthread_mutex_unlock(&waiter.mutex);
    (void)pthread_cond_destroy(&waiter.condition);
    (void)pthread_mutex_destroy(&waiter.mutex);
    return wait_result;
}

uint64_t flamez_macos_es_lost_events(struct flamez_macos_es *collector)
{
    uint64_t result;

    if (collector == NULL) {
        return 0;
    }
    (void)pthread_mutex_lock(&collector->mutex);
    result = collector->lost_events;
    (void)pthread_mutex_unlock(&collector->mutex);
    return result;
}

#ifdef FLAMEZ_TEST
struct flamez_macos_es *flamez_macos_es_test_create(size_t queue_limit)
{
    struct flamez_macos_es *collector = calloc(1, sizeof(*collector));

    if (collector == NULL) {
        return NULL;
    }
    if (pthread_mutex_init(&collector->mutex, NULL) != 0) {
        free(collector);
        return NULL;
    }
    if (pthread_cond_init(&collector->test_sync_condition, NULL) != 0) {
        (void)pthread_mutex_destroy(&collector->mutex);
        free(collector);
        return NULL;
    }
    collector->creator = pthread_self();
    collector->queue_limit = queue_limit;
    collector->cpu_time = flamez_macos_cpu_time;
    return collector;
}

void flamez_macos_es_test_destroy(struct flamez_macos_es *collector)
{
    struct flamez_macos_es_record *record;
    struct flamez_macos_es_record *next;
    void (^sync_block)(void);

    if (collector == NULL) {
        return;
    }
    (void)pthread_mutex_lock(&collector->mutex);
    record = collector->head;
    collector->head = NULL;
    collector->tail = NULL;
    collector->queued_bytes = 0;
    sync_block = collector->test_sync_block;
    collector->test_sync_block = NULL;
    (void)pthread_mutex_unlock(&collector->mutex);
    if (sync_block != NULL) {
        Block_release(sync_block);
    }
    while (record != NULL) {
        next = record->next;
        free(record);
        record = next;
    }
    (void)pthread_cond_destroy(&collector->test_sync_condition);
    (void)pthread_mutex_destroy(&collector->mutex);
    free(collector);
}

size_t flamez_macos_es_test_record_size(void)
{
    return sizeof(struct flamez_macos_es_record);
}

static bool flamez_macos_es_test_add_slice(
    size_t *storage_size,
    const uint8_t *source,
    size_t source_size)
{
    if (source == NULL && source_size != 0) {
        return false;
    }
    return source == NULL || flamez_add_size(storage_size, source_size);
}

static uint8_t *flamez_macos_es_test_copy_slice(
    uint8_t *destination,
    const uint8_t *source,
    size_t source_size,
    const uint8_t **stored)
{
    if (source == NULL) {
        *stored = NULL;
        return destination;
    }
    *stored = destination;
    if (source_size != 0) {
        memcpy(destination, source, source_size);
    }
    return destination + source_size;
}

int flamez_macos_es_test_enqueue(
    struct flamez_macos_es *collector,
    const struct flamez_macos_es_event *event)
{
    struct flamez_macos_es_record *record;
    uint8_t *cursor;
    size_t storage_size = 0;

    if (collector == NULL || event == NULL ||
        !flamez_macos_es_test_add_slice(
            &storage_size,
            event->name,
            event->name_len) ||
        !flamez_macos_es_test_add_slice(
            &storage_size,
            event->executable,
            event->executable_len) ||
        !flamez_macos_es_test_add_slice(
            &storage_size,
            event->args,
            event->args_len) ||
        !flamez_macos_es_test_add_slice(
            &storage_size,
            event->cwd,
            event->cwd_len)) {
        return EINVAL;
    }
    record = flamez_allocate_record(collector, storage_size);
    if (record == NULL) {
        return ENOMEM;
    }
    record->event = *event;
    cursor = record->storage;
    cursor = flamez_macos_es_test_copy_slice(
        cursor,
        event->name,
        event->name_len,
        &record->event.name);
    cursor = flamez_macos_es_test_copy_slice(
        cursor,
        event->executable,
        event->executable_len,
        &record->event.executable);
    cursor = flamez_macos_es_test_copy_slice(
        cursor,
        event->args,
        event->args_len,
        &record->event.args);
    (void)flamez_macos_es_test_copy_slice(
        cursor,
        event->cwd,
        event->cwd_len,
        &record->event.cwd);
    flamez_enqueue(collector, record);
    return 0;
}

void flamez_macos_es_test_capture_sequence(
    struct flamez_macos_es *collector,
    uint32_t message_version,
    uint64_t global_sequence)
{
    if (collector == NULL) {
        return;
    }
    flamez_capture_sequence_value(
        collector,
        message_version,
        global_sequence);
}

static _Thread_local const es_event_exec_t *flamez_macos_es_test_exec_event;
static _Thread_local es_string_token_t flamez_macos_es_test_exec_args[3];

static es_string_token_t flamez_macos_es_test_string(const char *value)
{
    return (es_string_token_t){
        .length = strlen(value),
        .data = value,
    };
}

static audit_token_t flamez_macos_es_test_audit_token(pid_t pid, int version)
{
    audit_token_t token = {0};

    token.val[0] = (unsigned int)pid;
    token.val[1] = (unsigned int)version;
    return token;
}

static pid_t flamez_macos_es_test_audit_pid(audit_token_t token)
{
    return (pid_t)token.val[0];
}

static int flamez_macos_es_test_audit_pid_version(audit_token_t token)
{
    return (int)token.val[1];
}

static uint32_t flamez_macos_es_test_exec_arg_count(
    const es_event_exec_t *event)
{
    return event == flamez_macos_es_test_exec_event ? 3 : 0;
}

static es_string_token_t flamez_macos_es_test_exec_arg(
    const es_event_exec_t *event,
    uint32_t index)
{
    if (event != flamez_macos_es_test_exec_event || index >= 3) {
        return (es_string_token_t){0};
    }
    return flamez_macos_es_test_exec_args[index];
}

static int flamez_macos_es_test_cpu_time(int32_t pid, uint64_t *total_ns)
{
    if (pid != 6101 || total_ns == NULL) {
        return ESRCH;
    }
    *total_ns = 777;
    return 0;
}

void flamez_macos_es_test_capture_fixture(struct flamez_macos_es *collector)
{
    es_file_t parent_file = {
        .path = flamez_macos_es_test_string("/usr/bin/parent"),
    };
    es_file_t child_file = {
        .path = flamez_macos_es_test_string("/usr/bin/child"),
    };
    es_file_t target_file = {
        .path = flamez_macos_es_test_string("/opt/bin/tool"),
        .path_truncated = true,
    };
    es_file_t cwd = {
        .path = flamez_macos_es_test_string("/working/directory"),
        .path_truncated = true,
    };
    es_process_t parent = {
        .audit_token = flamez_macos_es_test_audit_token(6100, 7),
        .executable = &parent_file,
    };
    es_process_t child = {
        .audit_token = flamez_macos_es_test_audit_token(6101, 8),
        .executable = &child_file,
    };
    es_process_t target = {
        .audit_token = flamez_macos_es_test_audit_token(6101, 9),
        .executable = &target_file,
    };
    es_message_t message = {0};

    if (collector == NULL) {
        return;
    }
    collector->audit_pid = flamez_macos_es_test_audit_pid;
    collector->audit_pid_version = flamez_macos_es_test_audit_pid_version;
    collector->exec_arg_count = flamez_macos_es_test_exec_arg_count;
    collector->exec_arg = flamez_macos_es_test_exec_arg;
    collector->cpu_time = flamez_macos_es_test_cpu_time;

    message.version = 4;
    message.mach_time = 1;
    message.process = &parent;
    message.action_type = ES_ACTION_TYPE_NOTIFY;
    message.event_type = ES_EVENT_TYPE_NOTIFY_FORK;
    message.event.fork.child = &child;
    message.global_seq_num = 100;
    flamez_capture_message(collector, &message);

    memset(&message, 0, sizeof(message));
    message.version = 4;
    message.mach_time = 2;
    message.process = &child;
    message.action_type = ES_ACTION_TYPE_NOTIFY;
    message.event_type = ES_EVENT_TYPE_NOTIFY_EXEC;
    message.event.exec.target = &target;
    message.event.exec.cwd = &cwd;
    message.global_seq_num = 101;
    flamez_macos_es_test_exec_event = &message.event.exec;
    flamez_macos_es_test_exec_args[0] = flamez_macos_es_test_string("tool");
    flamez_macos_es_test_exec_args[1] = flamez_macos_es_test_string("argument");
    flamez_macos_es_test_exec_args[2] = flamez_macos_es_test_string("");
    flamez_capture_message(collector, &message);
    flamez_macos_es_test_exec_event = NULL;

    memset(&message, 0, sizeof(message));
    message.version = 4;
    message.mach_time = 3;
    message.process = &target;
    message.action_type = ES_ACTION_TYPE_NOTIFY;
    message.event_type = ES_EVENT_TYPE_NOTIFY_EXIT;
    message.event.exit.stat = 0;
    message.global_seq_num = 104;
    flamez_capture_message(collector, &message);
}

uint64_t flamez_macos_es_test_mach_time_to_ns(uint64_t value)
{
    return flamez_mach_time_to_ns(value);
}

uint64_t flamez_macos_es_test_mach_now_to_ns(void)
{
    return flamez_mach_time_to_ns(mach_absolute_time());
}

static es_return_t flamez_macos_es_test_sync_client(
    es_client_t *client,
    void (^block)(void))
{
    struct flamez_macos_es *collector = (struct flamez_macos_es *)client;
    void (^copied_block)(void);

    if (collector == NULL || collector->test_sync_reject) {
        return ES_RETURN_ERROR;
    }
    copied_block = Block_copy(block);
    if (copied_block == NULL) {
        return ES_RETURN_ERROR;
    }
    if (pthread_mutex_lock(&collector->mutex) != 0) {
        Block_release(copied_block);
        return ES_RETURN_ERROR;
    }
    if (collector->test_sync_block != NULL) {
        (void)pthread_mutex_unlock(&collector->mutex);
        Block_release(copied_block);
        return ES_RETURN_ERROR;
    }
    collector->test_sync_block = copied_block;
    (void)pthread_cond_signal(&collector->test_sync_condition);
    (void)pthread_mutex_unlock(&collector->mutex);
    return ES_RETURN_SUCCESS;
}

void flamez_macos_es_test_prepare_sync(
    struct flamez_macos_es *collector,
    int reject)
{
    if (collector == NULL) {
        return;
    }
    (void)pthread_mutex_lock(&collector->mutex);
    collector->client = (es_client_t *)collector;
    collector->sync_client = flamez_macos_es_test_sync_client;
    collector->test_sync_reject = reject != 0;
    (void)pthread_mutex_unlock(&collector->mutex);
}

void flamez_macos_es_test_complete_sync(struct flamez_macos_es *collector)
{
    void (^block)(void);

    if (collector == NULL) {
        return;
    }
    (void)pthread_mutex_lock(&collector->mutex);
    while (collector->test_sync_block == NULL) {
        (void)pthread_cond_wait(
            &collector->test_sync_condition,
            &collector->mutex);
    }
    block = collector->test_sync_block;
    collector->test_sync_block = NULL;
    (void)pthread_mutex_unlock(&collector->mutex);
    block();
    Block_release(block);
}
#endif
