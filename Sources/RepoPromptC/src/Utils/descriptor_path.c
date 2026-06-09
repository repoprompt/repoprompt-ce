#include "descriptor_path.h"

#include <fcntl.h>

int repo_prompt_descriptor_get_path(int descriptor, char *buffer) {
    return fcntl(descriptor, F_GETPATH, buffer);
}
