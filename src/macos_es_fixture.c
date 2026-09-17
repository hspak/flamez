/* Separate process fixtures: all readiness comes from stop notifications,
 * blocked signals, pipes, or child waits. No timing delays are used. */
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static void require(int condition)
{
    if (!condition) _exit(90);
}

static void wait_child(pid_t pid)
{
    int status;
    pid_t result;
    do { result = waitpid(pid, &status, 0); } while (result < 0 && errno == EINTR);
    require(result == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

static sigset_t release_signals;

static void await_release(void)
{
    int signal;
    require(sigwait(&release_signals, &signal) == 0 && signal == SIGUSR1);
}

static void ready(void)
{
    require(raise(SIGSTOP) == 0);
}

static void work(void)
{
    volatile uint64_t result = 1;
    for (uint64_t i = 0; i < 8000000; ++i) result = result * 33 + i;
    require(result != 0);
}

int main(int argc, char **argv)
{
    require(argc >= 2);
    require(sigemptyset(&release_signals) == 0);
    require(sigaddset(&release_signals, SIGUSR1) == 0);
    require(sigprocmask(SIG_BLOCK, &release_signals, NULL) == 0);
    if (strcmp(argv[1], "immediate") == 0) return 23;
    if (strcmp(argv[1], "image") == 0) {
        require(argc == 4 && argv[2][0] == '\0' && strcmp(argv[3], "two words") == 0);
        ready();
        return 0;
    }
    if (strcmp(argv[1], "exec") == 0) {
        ready();
        char *image[] = {argv[0], "image", "", "two words", NULL};
        execv(argv[0], image);
        return 91;
    }
    if (strcmp(argv[1], "hold") == 0) {
        ready();
        await_release();
        return 0;
    }
    if (strcmp(argv[1], "double") == 0) {
        int completion[2];
        require(pipe(completion) == 0);
        pid_t intermediate = fork();
        require(intermediate >= 0);
        if (intermediate == 0) {
            close(completion[0]);
            require(setsid() >= 0);
            pid_t grandchild = fork();
            require(grandchild >= 0);
            if (grandchild > 0) wait_child(grandchild);
            _exit(0);
        }
        close(completion[1]);
        char byte;
        ssize_t amount;
        do { amount = read(completion[0], &byte, 1); } while (amount < 0 && errno == EINTR);
        require(amount == 0);
        close(completion[0]);
        wait_child(intermediate);
        ready();
        return 0;
    }
    if (strcmp(argv[1], "survivor") == 0) {
        pid_t child = fork();
        require(child >= 0);
        if (child == 0) {
            await_release();
            _exit(0);
        }
        ready();
        return 0;
    }
    const int cpu = strcmp(argv[1], "cpu") == 0;
    require(cpu || strcmp(argv[1], "burst") == 0);
    const int count = cpu ? 2 : 32;
    pid_t children[32];
    for (int i = 0; i < count; ++i) {
        children[i] = fork();
        require(children[i] >= 0);
        if (children[i] == 0) {
            if (cpu) {
                for (int round = 0; round < 3; ++round) {
                    work();
                    ready();
                }
            } else {
                await_release();
            }
            _exit(0);
        }
    }
    if (cpu) {
        for (int round = 0; round < 3; ++round) {
            for (int i = 0; i < count; ++i) {
                int status;
                require(waitpid(children[i], &status, WUNTRACED) == children[i]);
                require(WIFSTOPPED(status));
            }
            ready();
            for (int i = 0; i < count; ++i) require(kill(children[i], SIGCONT) == 0);
        }
    } else {
        ready();
        for (int i = 0; i < count; ++i) require(kill(children[i], SIGUSR1) == 0);
    }
    for (int i = 0; i < count; ++i) wait_child(children[i]);
    return 0;
}
