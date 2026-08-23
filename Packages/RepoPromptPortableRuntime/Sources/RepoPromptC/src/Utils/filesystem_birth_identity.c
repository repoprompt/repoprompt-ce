#define _GNU_SOURCE
#include "filesystem_birth_identity.h"

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <sys/stat.h>

#if defined(__linux__)
#include <linux/stat.h>
#endif

int rp_filesystem_birth_identity(const char *path, uint64_t *seconds, uint32_t *nanoseconds) {
    if (path == NULL || seconds == NULL || nanoseconds == NULL) {
        errno = EINVAL;
        return -1;
    }
#if defined(__linux__)
    struct statx info;
    if (statx(AT_FDCWD, path, AT_SYMLINK_NOFOLLOW, STATX_BTIME, &info) != 0 ||
        (info.stx_mask & STATX_BTIME) == 0) {
        return -1;
    }
    *seconds = (uint64_t)info.stx_btime.tv_sec;
    *nanoseconds = info.stx_btime.tv_nsec;
    return 0;
#elif defined(__APPLE__)
    struct stat info;
    if (lstat(path, &info) != 0) {
        return -1;
    }
    *seconds = (uint64_t)info.st_birthtimespec.tv_sec;
    *nanoseconds = (uint32_t)info.st_birthtimespec.tv_nsec;
    return 0;
#else
    errno = ENOTSUP;
    return -1;
#endif
}
