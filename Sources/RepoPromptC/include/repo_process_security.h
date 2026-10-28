/*
 * repo_process_security.h
 *
 * Process hardening primitives that Swift cannot reach through the Darwin module
 * (ptrace is not exported to Swift).
 */

#ifndef REPO_PROCESS_SECURITY_H
#define REPO_PROCESS_SECURITY_H

#ifdef __cplusplus
extern "C" {
#endif

/* Deny future debugger attachment to the current process via ptrace(PT_DENY_ATTACH).
 * Returns ptrace's result (0 on success, -1 on failure). */
int repo_deny_debugger_attachment(void);

#ifdef __cplusplus
}
#endif

#endif /* REPO_PROCESS_SECURITY_H */
