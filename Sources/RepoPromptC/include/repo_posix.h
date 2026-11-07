#ifndef REPO_POSIX_H
#define REPO_POSIX_H

#include <stddef.h>
#include <sys/types.h>

int repo_flock(int descriptor, int operation);
int repo_directory_search_flags(void);
int repo_rename_exclusive(int source_directory, const char *source, int destination_directory, const char *destination);
int repo_random_bytes(void *buffer, size_t count);
ssize_t repo_write_no_sigpipe(int descriptor, const void *buffer, size_t count);
int repo_try_lock_stderr(void);
void repo_unlock_stderr(void);

#endif
