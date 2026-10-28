#ifndef REPOPROMPT_SESSION_CATALOG_SQLITE_H
#define REPOPROMPT_SESSION_CATALOG_SQLITE_H

// Platform SQLite is the durable transaction engine for the session catalog.
// Keep C declarations in the C target; no first-party bridging header.
#include <sqlite3.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <unistd.h>

// NSURL symlink resolution can retain macOS's /var alias. SQLite NOFOLLOW needs
// the physical parent path, but must never resolve a symlink at the database itself.
static inline int rpce_catalog_resolve_directory(const char *path, char *resolved) {
    return realpath(path, resolved) == NULL ? errno : 0;
}

// Create with private permissions atomically. A competing initializer cannot truncate
// an existing catalog between a fileExists check and FileManager.createFile.
static inline int rpce_catalog_create_private(const char *path) {
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) return errno == EEXIST ? 0 : errno;
    if (close(fd) < 0) return errno;
    return 0;
}

static inline int rpce_catalog_bind_text(sqlite3_stmt *statement, int index, const char *value, int count) {
    return sqlite3_bind_text(statement, index, value, count, SQLITE_TRANSIENT);
}

static inline int rpce_catalog_bind_blob(sqlite3_stmt *statement, int index, const void *value, int count) {
    // SQLite interprets a NULL address as SQL NULL, even for a zero-length Data.
    return count == 0 ? sqlite3_bind_zeroblob(statement, index, 0)
                      : sqlite3_bind_blob(statement, index, value, count, SQLITE_TRANSIENT);
}

#endif
