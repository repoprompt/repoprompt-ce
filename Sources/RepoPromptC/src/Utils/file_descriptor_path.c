#include "file_descriptor_path.h"

#include <errno.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <fcntl.h>
#include <sys/param.h>
#endif

int repo_get_file_descriptor_path(int file_descriptor, char *buffer, size_t buffer_size) {
#if defined(__APPLE__)
    if (buffer == NULL || buffer_size < MAXPATHLEN) {
        errno = EINVAL;
        return -1;
    }
    return fcntl(file_descriptor, F_GETPATH, buffer);
#elif defined(__linux__)
    if (buffer == NULL || buffer_size < 2) {
        errno = EINVAL;
        return -1;
    }
    char link_path[64];
    snprintf(link_path, sizeof(link_path), "/proc/self/fd/%d", file_descriptor);
    ssize_t length = readlink(link_path, buffer, buffer_size);
    if (length < 0) return -1;
    if ((size_t)length >= buffer_size) {
        errno = ENAMETOOLONG;
        return -1;
    }
    buffer[length] = '\0';
    struct stat descriptor_info, path_info;
    if (fstat(file_descriptor, &descriptor_info) != 0 || stat(buffer, &path_info) != 0) return -1;
    if (descriptor_info.st_dev != path_info.st_dev || descriptor_info.st_ino != path_info.st_ino) {
        errno = ESTALE;
        return -1;
    }
    return 0;
#else
    (void)file_descriptor;
    (void)buffer;
    (void)buffer_size;
    errno = ENOTSUP;
    return -1;
#endif
}
