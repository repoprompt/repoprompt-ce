/*
 * repo_process_security.c
 */

#include "repo_process_security.h"

#include <sys/types.h>
#include <sys/ptrace.h>

#ifndef PT_DENY_ATTACH
#define PT_DENY_ATTACH 31
#endif

int repo_deny_debugger_attachment(void)
{
    return ptrace(PT_DENY_ATTACH, 0, 0, 0);
}
