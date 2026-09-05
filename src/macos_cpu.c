/* Identity-bound CPU reads shared by kqueue and Endpoint Security capture.
 * Kept independent of Darwin headers so PID-reuse races can be tested natively. */
#include "macos_shim.h"

#include <errno.h>

static int same_lifetime(const struct flamez_macos_process_identity *a,
                         const struct flamez_macos_process_identity *b)
{
    return a->unique_id == b->unique_id && a->start_seconds == b->start_seconds &&
           a->start_microseconds == b->start_microseconds;
}

static int read_stable_cpu(int32_t pid,
                           const struct flamez_macos_process_identity *before,
                           uint64_t *total_ns)
{
    struct flamez_macos_process_identity after;
    uint64_t sampled_ns;
    int result = flamez_macos_cpu_time(pid, &sampled_ns);
    if (result != 0) return result;
    result = flamez_macos_process_identity(pid, &after);
    if (result != 0) return result;
    if (!same_lifetime(before, &after) || before->pid_version != after.pid_version)
        return EAGAIN;
    *total_ns = sampled_ns;
    return 0;
}

int flamez_macos_cpu_time_for_identity(
    int32_t pid,
    const struct flamez_macos_process_identity *identity,
    uint64_t *total_ns)
{
    struct flamez_macos_process_identity before;
    int result;
    if (identity == NULL || total_ns == NULL) return EINVAL;
    result = flamez_macos_process_identity(pid, &before);
    if (result != 0) return result;
    if (!same_lifetime(identity, &before)) return EAGAIN;
    return read_stable_cpu(pid, &before, total_ns);
}

int flamez_macos_cpu_time_for_version(int32_t pid, int32_t pid_version, uint64_t *total_ns)
{
    struct flamez_macos_process_identity before;
    int result;
    if (total_ns == NULL) return EINVAL;
    result = flamez_macos_process_identity(pid, &before);
    if (result != 0) return result;
    if (before.pid_version != pid_version) return EAGAIN;
    return read_stable_cpu(pid, &before, total_ns);
}

#ifdef FLAMEZ_MACOS_CPU_TEST
static unsigned int test_scenario, test_identity_reads;
static const struct flamez_macos_process_identity test_identity = {
    .pid_version = 9,
    .unique_id = 100,
    .start_seconds = 10,
    .start_microseconds = 20,
};

int flamez_macos_process_identity(int32_t pid, struct flamez_macos_process_identity *identity)
{
    const unsigned int read = test_identity_reads++;
    if (pid != 6101 || (test_scenario == 3 && read == 0) ||
        (test_scenario == 4 && read != 0)) return ESRCH;
    *identity = test_identity;
    if (test_scenario == 1 || (test_scenario == 2 && read != 0)) {
        identity->unique_id += 1;
        identity->pid_version += 1;
    }
    if (test_scenario == 6 || (test_scenario == 7 && read != 0))
        identity->pid_version += 1;
    return 0;
}

int flamez_macos_cpu_time(int32_t pid, uint64_t *total_ns)
{
    if (pid != 6101 || test_scenario == 5) return ESRCH;
    *total_ns = 777;
    return 0;
}

int flamez_macos_test_cpu_identity(int by_version, unsigned int scenario)
{
    uint64_t total_ns = 42;
    int result;
    int expect_success = scenario == 0 || (scenario == 6 && !by_version);
    test_scenario = scenario;
    test_identity_reads = 0;
    if (by_version)
        result = flamez_macos_cpu_time_for_version(6101, 9, &total_ns);
    else
        result = flamez_macos_cpu_time_for_identity(6101, &test_identity, &total_ns);
    if (expect_success) return result == 0 && total_ns == 777 ? 0 : 1;
    return result != 0 && total_ns == 42 ? 0 : 2;
}
#endif
