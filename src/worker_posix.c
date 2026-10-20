/* Process and socket helpers for worker.zig: spawning the helper process with
 * its channel on fd 3, and the few socket calls that need exact flags. */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/poll.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif

/* Forks `exe` with one end of a socketpair as fd 3 and every other inherited
 * descriptor above 3 closed. On Linux the child dies with the thread that
 * spawned it (PR_SET_PDEATHSIG), so call this from a thread that lives as long
 * as the worker should. Returns the pid, or -1. */
int tachi_spawn(const char *exe, char *const *argv, int *parent_fd) {
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair))
        return -1;
    int parent = fcntl(pair[0], F_DUPFD_CLOEXEC, 4), child = fcntl(pair[1], F_DUPFD_CLOEXEC, 4);
    close(pair[0]);
    close(pair[1]);
    if (parent < 0 || child < 0) {
        if (parent >= 0)
            close(parent);
        if (child >= 0)
            close(child);
        return -1;
    }
    int toclose[1024];
    size_t count = 0;
    DIR *directory = opendir("/proc/self/fd");
    if (directory) {
        struct dirent *entry;
        while ((entry = readdir(directory)) && count < 1024) {
            int fd = atoi(entry->d_name);
            if (fd > 3)
                toclose[count++] = fd;
        }
        closedir(directory);
    }
    pid_t owner = getpid(), pid = fork();
    if (pid == 0) {
        close(parent);
#ifdef __linux__
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != owner)
            _exit(127);
#endif
        if (dup2(child, 3) < 0)
            _exit(127);
        close(child);
        if (fcntl(3, F_SETFD, 0) < 0)
            _exit(127);
        for (size_t i = 0; i < count; i++)
            close(toclose[i]);
        /* No setsid: the worker stays in its parent's process group. */
        execv(exe, argv);
        _exit(127);
    }
    close(child);
    if (pid < 0) {
        close(parent);
        return -1;
    }
    *parent_fd = parent;
    return pid;
}

int tachi_poll(int fd, int ms) {
    struct pollfd p = {fd, POLLIN, 0};
    int n;
    do {
        n = poll(&p, 1, ms);
    } while (n < 0 && errno == EINTR);
    return n;
}

ssize_t tachi_send(int fd, const void *buf, size_t n, int nonblocking) {
    int flags = nonblocking ? MSG_DONTWAIT : 0;
#ifdef MSG_NOSIGNAL
    flags |= MSG_NOSIGNAL;
#else
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof yes);
#endif
    return send(fd, buf, n, flags);
}

ssize_t tachi_recv(int fd, void *buf, size_t n) { return recv(fd, buf, n, 0); }

/* Wakes anything blocked on `fd` and kills `pid` unless it has exited. */
void tachi_interrupt(int pid, int fd) {
    if (fd >= 0)
        shutdown(fd, SHUT_RDWR);
    if (pid > 0) {
        int status;
        pid_t n;
        do {
            n = waitpid(pid, &status, WNOHANG);
        } while (n < 0 && errno == EINTR);
        if (n == 0)
            kill(pid, SIGKILL);
    }
}

/* Reaps `pid`; returns 1 once it has exited (or is not our child). */
int tachi_reap(int pid, int block) {
    int status = 0;
    pid_t n;
    do {
        n = waitpid(pid, &status, block ? 0 : WNOHANG);
    } while (n < 0 && errno == EINTR);
    return n == pid || (n < 0 && errno == ECHILD);
}

void tachi_eof(int fd) { shutdown(fd, SHUT_WR); }

uint64_t tachi_now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

/* Resident set size from /proc, or 0 where there is none. */
size_t tachi_rss_kib(void) {
    FILE *f = fopen("/proc/self/status", "r");
    if (!f)
        return 0;
    char line[256];
    unsigned long n = 0;
    while (fgets(line, sizeof line, f)) {
        if (sscanf(line, "VmRSS: %lu kB", &n) == 1)
            break;
    }
    fclose(f);
    return n;
}
