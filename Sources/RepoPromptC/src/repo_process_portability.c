#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "repo_process_portability.h"
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

#ifdef __APPLE__
#include <copyfile.h>
#include <sys/clonefile.h>
#include <sys/un.h>
#else
#include <linux/fs.h>
#include <linux/magic.h>
#include <sys/ioctl.h>
#include <sys/vfs.h>
#include <sys/xattr.h>
#endif

int repo_filesystem_available_bytes(const char *path, uint64_t *bytes) {
    struct statvfs status;
    if (statvfs(path, &status) != 0) return -1;
    uint64_t block_size = status.f_frsize ? status.f_frsize : status.f_bsize;
    uint64_t available_blocks = status.f_bavail;
    if (!block_size || available_blocks > UINT64_MAX / block_size) {
        errno = EOVERFLOW;
        return -1;
    }
    *bytes = block_size * available_blocks;
    return 0;
}

int repo_filesystem_reflink_candidate(const char *path) {
#ifdef __APPLE__
    (void)path;
    errno = ENOTSUP;
    return -1;
#else
    struct statfs status;
    if (statfs(path, &status) != 0) return -1;
    // These filesystems can support FICLONE. The actual ioctl remains authoritative:
    // e.g. older XFS formats can lack reflink despite having the same filesystem type.
    return status.f_type == BTRFS_SUPER_MAGIC || status.f_type == XFS_SUPER_MAGIC;
#endif
}

int repo_spawn_addchdir(posix_spawn_file_actions_t *actions, const char *path) {
    return posix_spawn_file_actions_addchdir_np(actions, path);
}

int repo_spawn_close_extra_descriptors(posix_spawn_file_actions_t *actions) {
#ifdef __APPLE__
    (void)actions;
    return ENOTSUP;
#else
    return posix_spawn_file_actions_addclosefrom_np(actions, 3);
#endif
}

int repo_accept_cloexec(int descriptor, struct sockaddr *address, socklen_t *length) {
#ifdef __APPLE__
    int client = accept(descriptor, address, length);
    if (client >= 0 && fcntl(client, F_SETFD, FD_CLOEXEC) < 0) {
        int error = errno; close(client); errno = error; return -1;
    }
    return client;
#else
    return accept4(descriptor, address, length, SOCK_CLOEXEC);
#endif
}

pid_t repo_siginfo_pid(const siginfo_t *info) {
    return info->si_pid;
}

int repo_socket_peer_credentials(int descriptor, pid_t *pid, uid_t *uid, gid_t *gid) {
#ifdef __APPLE__
    socklen_t size = sizeof(*pid);
    if (getpeereid(descriptor, uid, gid) != 0) return -1;
    return getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, pid, &size);
#else
    struct ucred credentials;
    socklen_t size = sizeof(credentials);
    if (getsockopt(descriptor, SOL_SOCKET, SO_PEERCRED, &credentials, &size) != 0) return -1;
    if (size != sizeof(credentials)) { errno = EIO; return -1; }
    *pid = credentials.pid;
    *uid = credentials.uid;
    *gid = credentials.gid;
    return 0;
#endif
}

int repo_fd_has_extended_acl(int descriptor) {
#ifdef __APPLE__
    (void)descriptor;
    errno = ENOTSUP;
    return -1;
#else
    ssize_t size = fgetxattr(descriptor, "system.posix_acl_access", NULL, 0);
    if (size >= 0) return size > 0;
    if (errno == ENODATA || errno == ENOTSUP) return 0;
    return -1;
#endif
}

#ifndef __APPLE__
static int copy_metadata(int source, int destination) {
    struct stat info;
    if (fstat(source, &info) != 0) return -1;
    ssize_t size = flistxattr(source, NULL, 0);
    if (size < 0 && errno != ENOTSUP) return -1;
    if (size > 0) {
        char *names = malloc((size_t)size);
        if (!names) return -1;
        ssize_t length = flistxattr(source, names, (size_t)size);
        if (length < 0) { int error = errno; free(names); errno = error; return -1; }
        for (ssize_t offset = 0; offset < length;) {
            const char *name = names + offset;
            size_t name_length = strnlen(name, (size_t)(length - offset));
            if (name_length == (size_t)(length - offset)) { free(names); errno = EIO; return -1; }
            ssize_t value_size = fgetxattr(source, name, NULL, 0);
            if (value_size < 0) { int error = errno; free(names); errno = error; return -1; }
            void *value = malloc(value_size > 0 ? (size_t)value_size : 1);
            if (!value) { free(names); return -1; }
            ssize_t obtained = fgetxattr(source, name, value, (size_t)value_size);
            int result = obtained < 0 ? -1 : fsetxattr(destination, name, value, (size_t)obtained, 0);
            int error = errno;
            free(value);
            if (result < 0) { free(names); errno = error; return -1; }
            offset += (ssize_t)name_length + 1;
        }
        free(names);
    }
    if (fchmod(destination, info.st_mode & 07777) != 0) return -1;
    struct timespec times[2] = { info.st_atim, info.st_mtim };
    return futimens(destination, times);
}
#endif

int repo_clone_file_at(int source, int directory, const char *name, unsigned int flags) {
#ifdef __APPLE__
    return fclonefileat(source, directory, name, flags);
#else
    (void)flags;
    int destination = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (destination < 0) return -1;
    int result = ioctl(destination, FICLONE, source);
    int error = errno;
    if (result == 0) {
        result = copy_metadata(source, destination);
        error = errno;
    } else if (error == EOPNOTSUPP || error == ENOTTY || error == EINVAL) {
        error = ENOTSUP;
    }
    if (close(destination) != 0 && result == 0) { result = -1; error = errno; }
    if (result != 0) unlinkat(directory, name, 0);
    errno = error;
    return result;
#endif
}

int repo_copy_file_contents_and_metadata(int source, int destination) {
#ifdef __APPLE__
    return fcopyfile(source, destination, NULL, COPYFILE_ALL);
#else
    char buffer[65536];
    off_t offset = 0;
    for (;;) {
        ssize_t count = pread(source, buffer, sizeof(buffer), offset);
        if (count < 0) { if (errno == EINTR) continue; return -1; }
        if (count == 0) break;
        ssize_t written = 0;
        while (written < count) {
            ssize_t amount = write(destination, buffer + written, (size_t)(count - written));
            if (amount < 0) { if (errno == EINTR) continue; return -1; }
            if (amount == 0) { errno = EIO; return -1; }
            written += amount;
        }
        offset += count;
    }
    return copy_metadata(source, destination);
#endif
}

int repo_remove_file_extended_attributes(int descriptor) {
#ifdef __APPLE__
    (void)descriptor;
    errno = ENOTSUP;
    return -1;
#else
    ssize_t size = flistxattr(descriptor, NULL, 0);
    if (size < 0) return errno == ENOTSUP ? 0 : -1;
    if (size == 0) return 0;
    char *names = malloc((size_t)size);
    if (!names) return -1;
    ssize_t length = flistxattr(descriptor, names, (size_t)size);
    if (length < 0) { int error = errno; free(names); errno = error; return -1; }
    for (ssize_t offset = 0; offset < length;) {
        size_t name_length = strnlen(names + offset, (size_t)(length - offset));
        if (name_length == (size_t)(length - offset)) { free(names); errno = EIO; return -1; }
        if (fremovexattr(descriptor, names + offset) != 0 && errno != ENODATA) {
            int error = errno; free(names); errno = error; return -1;
        }
        offset += (ssize_t)name_length + 1;
    }
    free(names);
    return 0;
#endif
}
