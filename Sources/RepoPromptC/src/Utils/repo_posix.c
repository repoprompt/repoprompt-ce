#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "repo_posix.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <sys/file.h>
#include <sys/random.h>
#include <unistd.h>

int repo_flock(int descriptor, int operation) {
    return flock(descriptor, operation);
}

int repo_try_lock_stderr(void) {
    return ftrylockfile(stderr);
}

void repo_unlock_stderr(void) {
    funlockfile(stderr);
}

int repo_directory_search_flags(void) {
#if defined(__linux__)
    return O_PATH | O_DIRECTORY;
#else
    return O_SEARCH;
#endif
}

int repo_rename_exclusive(int source_directory, const char *source, int destination_directory, const char *destination) {
#if defined(__linux__)
    return renameat2(source_directory, source, destination_directory, destination, RENAME_NOREPLACE);
#else
    return renameatx_np(source_directory, source, destination_directory, destination, RENAME_EXCL);
#endif
}

int repo_random_bytes(void *buffer, size_t count) {
#if defined(__linux__)
    size_t offset = 0;
    while (offset < count) {
        ssize_t received = getrandom((unsigned char *)buffer + offset, count - offset, 0);
        if (received < 0 && errno == EINTR) continue;
        if (received <= 0) {
            if (received == 0) errno = EIO;
            return -1;
        }
        offset += (size_t)received;
    }
    return 0;
#else
    return getentropy(buffer, count);
#endif
}

ssize_t repo_write_no_sigpipe(int descriptor, const void *buffer, size_t count) {
#if defined(__linux__)
    sigset_t blocked, previous, pending;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGPIPE);
    int status = pthread_sigmask(SIG_BLOCK, &blocked, &previous);
    if (status != 0) {
        errno = status;
        return -1;
    }
    if (sigpending(&pending) != 0) {
        int saved_errno = errno;
        pthread_sigmask(SIG_SETMASK, &previous, NULL);
        errno = saved_errno;
        return -1;
    }
    int already_pending = sigismember(&pending, SIGPIPE);
    ssize_t result = write(descriptor, buffer, count);
    int saved_errno = errno;
    if (result < 0 && saved_errno == EPIPE && !already_pending) {
        struct timespec no_wait = {0, 0};
        while (sigtimedwait(&blocked, NULL, &no_wait) < 0 && errno == EINTR) {}
    }
    pthread_sigmask(SIG_SETMASK, &previous, NULL);
    errno = saved_errno;
    return result;
#else
    return write(descriptor, buffer, count);
#endif
}
