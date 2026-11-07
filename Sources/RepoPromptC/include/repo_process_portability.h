#ifndef REPO_PROCESS_PORTABILITY_H
#define REPO_PROCESS_PORTABILITY_H

#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <sys/types.h>
#include <sys/socket.h>

int repo_spawn_addchdir(posix_spawn_file_actions_t *actions, const char *path);
int repo_spawn_close_extra_descriptors(posix_spawn_file_actions_t *actions);
int repo_accept_cloexec(int descriptor, struct sockaddr *address, socklen_t *length);
pid_t repo_siginfo_pid(const siginfo_t *info);
int repo_socket_peer_credentials(int descriptor, pid_t *pid, uid_t *uid, gid_t *gid);
int repo_fd_has_extended_acl(int descriptor);
int repo_clone_file_at(int source, int directory, const char *name, unsigned int flags);
int repo_copy_file_contents_and_metadata(int source, int destination);
int repo_remove_file_extended_attributes(int descriptor);
int repo_filesystem_available_bytes(const char *path, uint64_t *bytes);
int repo_filesystem_reflink_candidate(const char *path);

#endif
