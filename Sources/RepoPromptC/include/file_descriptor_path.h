#ifndef FILE_DESCRIPTOR_PATH_H
#define FILE_DESCRIPTOR_PATH_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Resolves the path currently referenced by an open file descriptor.
// On macOS, buffer_size must be at least MAXPATHLEN bytes.
int repo_get_file_descriptor_path(int file_descriptor, char *buffer, size_t buffer_size);

#ifdef __cplusplus
}
#endif

#endif /* FILE_DESCRIPTOR_PATH_H */
