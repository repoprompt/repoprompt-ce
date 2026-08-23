/*
 * repo_wildmatch_wrapper.c
 * 
 * Enhanced wrapper for gitignore-specific pattern matching.
 * Provides gitignore-compatible matching on top of bundled wildmatch.
 */

#include "wildmatch.h"
#include <string.h>
#include <stdbool.h>
#include <stdio.h>

/* Swift-friendly wrapper that matches the function signature we'll use */
int repo_wildmatch(const char *pattern, const char *text, unsigned int flags)
{
    if (!pattern || !text) {
        return WM_NOMATCH;
    }
    return wildmatch(pattern, text, (int)flags);
}

/* Check if pattern contains ** at word boundaries (as globstar) */
static bool has_globstar(const char *pattern)
{
    if (!pattern) return false;
    
    if (strcmp(pattern, "**") == 0) return true;
    if (strncmp(pattern, "**/", 3) == 0) return true;
    
    const char *p = pattern;
    while ((p = strstr(p, "/**")) != NULL) {
        p += 3;
        if (*p == '/' || *p == '\0') return true;
    }
    
    size_t len = strlen(pattern);
    if (len >= 3 && strcmp(pattern + len - 3, "/**") == 0) return true;
    
    return false;
}

static unsigned int gitignore_flags_for_pattern(const char *pattern)
{
    unsigned int flags = WM_PATHNAME | WM_NOESCAPE;
    if (has_globstar(pattern)) {
        flags |= WM_WILDSTAR;
    }
    return flags;
}

static bool pattern_ends_with_slash_double_star(const char *pattern)
{
    size_t len = strlen(pattern);
    return len >= 3 && strcmp(pattern + len - 3, "/**") == 0;
}

static int match_each_basename(const char *pattern, const char *path, unsigned int flags)
{
    const char *component_start = path;

    while (*component_start != '\0') {
        const char *slash = strchr(component_start, '/');
        size_t component_len = slash ? (size_t)(slash - component_start) : strlen(component_start);
        char component[1024];

        if (component_len >= sizeof(component)) {
            return WM_NOMATCH;
        }

        memcpy(component, component_start, component_len);
        component[component_len] = '\0';

        if (wildmatch(pattern, component, (int)flags) == WM_MATCH) {
            return WM_MATCH;
        }

        if (!slash) {
            break;
        }
        component_start = slash + 1;
    }

    return WM_NOMATCH;
}

static int match_each_subpath(const char *pattern, const char *path, unsigned int flags)
{
    const char *subpath_start = path;

    while (*subpath_start != '\0') {
        if (wildmatch(pattern, subpath_start, (int)flags) == WM_MATCH) {
            return WM_MATCH;
        }

        const char *slash = strchr(subpath_start, '/');
        if (!slash) {
            break;
        }
        subpath_start = slash + 1;
    }

    return WM_NOMATCH;
}

/* Gitignore-aware wildmatch for anchored patterns */
int repo_gitignore_match_anchored(const char *pattern, const char *path)
{
    /* Handle null pointers */
    if (!pattern || !path) {
        return WM_NOMATCH;
    }
    
    /* Handle empty path - only ** should match */
    if (*path == '\0') {
        return (strcmp(pattern, "**") == 0) ? WM_MATCH : WM_NOMATCH;
    }
    
    /* Determine flags based on pattern content */
    unsigned int flags = gitignore_flags_for_pattern(pattern);
    
    return wildmatch(pattern, path, (int)flags);
}

/* Gitignore-aware wildmatch for non-anchored patterns */
int repo_gitignore_match_anywhere(const char *pattern, const char *path)
{
    unsigned int flags;
    
    /* Handle null pointers */
    if (!pattern || !path) {
        return WM_NOMATCH;
    }
    
    /* Handle empty path - only ** should match */
    if (*path == '\0') {
        return (strcmp(pattern, "**") == 0) ? WM_MATCH : WM_NOMATCH;
    }
    
    /* Special case: pattern is just "**" */
    if (strcmp(pattern, "**") == 0) {
        return WM_MATCH;
    }

    flags = gitignore_flags_for_pattern(pattern);

    /* Slashless patterns match basenames at any depth. */
    if (strchr(pattern, '/') == NULL) {
        return match_each_basename(pattern, path, flags);
    }

    /* Preserve legacy non-anchored slash-pattern behavior at subpath boundaries. */
    if (pattern_ends_with_slash_double_star(pattern)) {
        char base_pattern[1024];
        size_t pattern_len = strlen(pattern);
        size_t base_len = pattern_len - 3;

        if (base_len == 0 || base_len >= sizeof(base_pattern)) {
            return WM_NOMATCH;
        }

        memcpy(base_pattern, pattern, base_len);
        base_pattern[base_len] = '\0';

        if (match_each_subpath(base_pattern, path, flags) == WM_MATCH) {
            return WM_MATCH;
        }
    }

    return match_each_subpath(pattern, path, flags);
}

/* Normalize pattern by collapsing multiple slashes */
void repo_normalize_pattern(char *dest, const char *src, size_t dest_size)
{
    size_t i = 0, j = 0;
    bool last_was_slash = false;
    
    while (src[i] != '\0' && j < dest_size - 1) {
        if (src[i] == '/') {
            if (!last_was_slash) {
                dest[j++] = '/';
                last_was_slash = true;
            }
            i++;
        } else {
            dest[j++] = src[i++];
            last_was_slash = false;
        }
    }
    
    dest[j] = '\0';
}

/* Parsed pattern structure for Swift interop */
typedef struct {
    char pattern[1024];
    bool is_negation;
    bool directory_only;
    bool absolute;
} repo_gitignore_pattern;

static void trim_trailing_whitespace_preserving_escapes(char *text)
{
    size_t len = strlen(text);
    size_t preserved_suffix = 0;

    while (len > preserved_suffix) {
        size_t whitespace_index = len - preserved_suffix - 1;
        size_t slash_count = 0;
        size_t idx = whitespace_index;

        if (text[whitespace_index] != ' ' && text[whitespace_index] != '\t') {
            break;
        }

        while (idx > 0 && text[idx - 1] == '\\') {
            slash_count++;
            idx--;
        }

        if ((slash_count % 2) == 1) {
            size_t escape_index = whitespace_index - 1;
            memmove(&text[escape_index], &text[escape_index + 1], len - escape_index);
            len--;
            preserved_suffix++;
            continue;
        }

        if (preserved_suffix > 0) {
            break;
        }

        text[whitespace_index] = '\0';
        len--;
    }
}

/* Parse a single gitignore line into a pattern structure */
bool repo_parse_gitignore_line(const char *line, repo_gitignore_pattern *result)
{
    size_t len;
    const char *p = line;
    char temp[1024];
    
    /* Initialize result */
    result->pattern[0] = '\0';
    result->is_negation = false;
    result->directory_only = false;
    result->absolute = false;
    
    /* Skip leading whitespace */
    while (*p == ' ' || *p == '\t') p++;
    
    /* Empty line or comment */
    if (*p == '\0' || *p == '#') {
        return false;
    }
    
    /* Check for negation. Only the first unescaped ! is special. */
    if (*p == '!') {
        result->is_negation = true;
        p++;
        if ((p[0] == '\\' && p[1] == '!') || (p[0] == '\\' && p[1] == '#')) {
            p++; /* Skip only the escape, leaving the literal character. */
        }
    } else if ((p[0] == '\\' && p[1] == '!') || (p[0] == '\\' && p[1] == '#')) {
        p++; /* Skip only the escape, leaving the literal character. */
    }
    
    /* Check for leading slash (absolute path) */
    if (*p == '/') {
        result->absolute = true;
        p++;
    }
    
    /* Copy pattern, removing trailing whitespace */
    strncpy(temp, p, sizeof(temp) - 1);
    temp[sizeof(temp) - 1] = '\0';
    
    /* Trim trailing whitespace, preserving escaped trailing spaces/tabs. */
    trim_trailing_whitespace_preserving_escapes(temp);
    len = strlen(temp);
    
    /* Check for trailing slash (directory only) */
    if (len > 0 && temp[len-1] == '/') {
        result->directory_only = true;
        temp[len-1] = '\0';
    }
    
    /* Normalize the pattern */
    repo_normalize_pattern(result->pattern, temp, sizeof(result->pattern));
    
    /* Don't process empty patterns */
    return result->pattern[0] != '\0';
}