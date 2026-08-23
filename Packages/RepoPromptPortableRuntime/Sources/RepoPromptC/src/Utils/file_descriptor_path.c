#include "file_descriptor_path.h"

#include <errno.h>

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
#else
    (void)file_descriptor;
    (void)buffer;
    (void)buffer_size;
    errno = ENOTSUP;
    return -1;
#endif
}
