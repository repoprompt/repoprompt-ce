#ifndef REPOPROMPT_LINUX_SUPPORT_H
#define REPOPROMPT_LINUX_SUPPORT_H

#include <sys/types.h>

int rp_enable_child_subreaper(void);
pid_t rp_waitpid_nohang(pid_t pid, int *status);

#endif
