#ifndef REPOPROMPT_FILESYSTEM_BIRTH_IDENTITY_H
#define REPOPROMPT_FILESYSTEM_BIRTH_IDENTITY_H

#include <stdint.h>

int rp_filesystem_birth_identity(const char *path, uint64_t *seconds, uint32_t *nanoseconds);

#endif
