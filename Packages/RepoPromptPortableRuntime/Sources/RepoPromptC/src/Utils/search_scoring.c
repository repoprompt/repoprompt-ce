/*
 * search_scoring.c
 *
 * High-performance search scoring implementation
 */

#include <string.h>
#include <ctype.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <unistd.h>
#include "search_scoring.h"

/* External functions from similarity.c and wildmatch wrapper */
extern double repo_similarity_score(const char *s1, const char *s2);
extern int repo_wildmatch(const char *pattern, const char *text, unsigned int flags);

/* Wildmatch flag definitions (from wildmatch.h) */
#define WM_PATHNAME     0x02
#define WM_WILDSTAR     0x20
#define WM_CASEFOLD     0x08
#define WM_MATCH        0

/* Convert string to lowercase - used for fallback when pre-lowercased strings not available */
static void to_lowercase(char *dest, const char *src, size_t max_len) {
    if (!dest || !src || max_len == 0) {
        if (dest && max_len > 0) dest[0] = '\0';
        return;
    }
    
    size_t i = 0;
    while (i < max_len - 1 && src[i]) {
        dest[i] = tolower((unsigned char)src[i]);
        i++;
    }
    dest[i] = '\0';
}

/* Check if str starts with prefix (case-insensitive) */
static bool has_prefix_ci(const char *str, const char *prefix) {
    while (*prefix) {
        if (tolower((unsigned char)*str) != tolower((unsigned char)*prefix)) {
            return false;
        }
        str++;
        prefix++;
    }
    return true;
}

/* Check if str starts with prefix (direct comparison for pre-lowercased strings) */
static bool has_prefix(const char *str, const char *prefix) {
    while (*prefix) {
        if (*str != *prefix) {
            return false;
        }
        str++;
        prefix++;
    }
    return true;
}

/* Check if haystack contains needle (case-insensitive) */
static bool contains_ci(const char *haystack, const char *needle) {
    if (!*needle) return true;
    
    size_t needle_len = strlen(needle);
    size_t haystack_len = strlen(haystack);
    
    if (needle_len > haystack_len) return false;
    
    for (size_t i = 0; i <= haystack_len - needle_len; i++) {
        bool match = true;
        for (size_t j = 0; j < needle_len; j++) {
            if (tolower((unsigned char)haystack[i + j]) != tolower((unsigned char)needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

/* Check if haystack contains needle (direct comparison for pre-lowercased strings) */
static bool contains(const char *haystack, const char *needle) {
    if (!*needle) return true;
    
    const char *found = strstr(haystack, needle);
    return found != NULL;
}

/* Extract filename from path */
static const char* get_filename(const char *path) {
    const char *last_slash = strrchr(path, '/');
    return last_slash ? last_slash + 1 : path;
}

/* Main scoring function with optional pre-lowercased strings */
int repo_score_match(const char *file_name, const char *file_path,
                     const char *file_name_lower, const char *file_path_lower,
                     const char *query, const char *query_lower,
                     bool has_slash, bool is_wildcard,
                     double fuzzy_threshold) {
    
    /* Check for empty query */
    if (!query || *query == '\0') return 0;
    
    /* Use provided lowercase versions or fallback to creating them */
    char name_lower_buf[1024];
    char path_lower_buf[2048];
    char query_lower_buf[1024];
    
    const char *name_lower_ptr = file_name_lower;
    const char *path_lower_ptr = file_path_lower;
    const char *query_lower_ptr = query_lower;
    
    if (!name_lower_ptr) {
        to_lowercase(name_lower_buf, file_name, sizeof(name_lower_buf));
        name_lower_ptr = name_lower_buf;
    }
    if (!path_lower_ptr) {
        to_lowercase(path_lower_buf, file_path, sizeof(path_lower_buf));
        path_lower_ptr = path_lower_buf;
    }
    if (!query_lower_ptr) {
        to_lowercase(query_lower_buf, query, sizeof(query_lower_buf));
        query_lower_ptr = query_lower_buf;
    }
    
    /* 1. Exact matches (highest priority) */
    if (strcmp(name_lower_ptr, query_lower_ptr) == 0) return 1000;
    if (strcmp(path_lower_ptr, query_lower_ptr) == 0) return 950;
    
    /* Check if query matches filename without extension exactly */
    char name_no_ext[1024];
    strncpy(name_no_ext, name_lower_ptr, sizeof(name_no_ext) - 1);
    name_no_ext[sizeof(name_no_ext) - 1] = '\0';
    char *last_dot = strrchr(name_no_ext, '.');
    if (last_dot && last_dot != name_no_ext) {
        *last_dot = '\0';
        if (strcmp(name_no_ext, query_lower_ptr) == 0) {
            return 1000;
        }
    }
    
    /* 2. Prefix matches */
    if (has_prefix(name_lower_ptr, query_lower_ptr)) return 900;
    if (has_slash && has_prefix(path_lower_ptr, query_lower_ptr)) return 875;
    
    /* 3. Path component prefix matches */
    char path_copy[2048];
    strncpy(path_copy, path_lower_ptr, sizeof(path_copy) - 1);
    path_copy[sizeof(path_copy) - 1] = '\0';
    
    char *saveptr;
    char *component = strtok_r(path_copy, "/", &saveptr);
    while (component != NULL) {
        if (has_prefix(component, query_lower_ptr)) {
            return 850;
        }
        component = strtok_r(NULL, "/", &saveptr);
    }
    
    /* 4. Substring matches */
    if (contains(name_lower_ptr, query_lower_ptr)) return 750;
    if (has_slash && contains(path_lower_ptr, query_lower_ptr)) return 700;
    /* Also check path substring for non-slash queries (handles backslash paths) */
    if (!has_slash && contains(path_lower_ptr, query_lower_ptr)) return 750;
    
    /* 5. Wildcard patterns */
    if (is_wildcard) {
        int flags = WM_PATHNAME | WM_WILDSTAR | WM_CASEFOLD;
        const char *pattern_after_star;
        const char *path_ptr;
        
        /* Special handling for patterns starting with **/
        if (strncmp(query, "**/", 3) == 0) {
            pattern_after_star = query + 3;
            /* Check if the filename matches the pattern after **/
            if (repo_wildmatch(pattern_after_star, file_name, flags) == WM_MATCH) {
                return 650;
            }
            /* Also check if any path suffix matches */
            path_ptr = file_path;
            while (*path_ptr) {
                if (repo_wildmatch(pattern_after_star, path_ptr, flags) == WM_MATCH) {
                    return 650;
                }
                /* Move to next path component */
                path_ptr = strchr(path_ptr, '/');
                if (!path_ptr) break;
                path_ptr++; /* Skip the slash */
            }
        }
        
        /* Try standard wildcard matching */
        if (repo_wildmatch(query, file_name, flags) == WM_MATCH) {
            return 650;
        }
        if (repo_wildmatch(query, file_path, flags) == WM_MATCH) {
            return 650;
        }
    }
    
    /* 6. Fuzzy matching (only for queries >= 3 chars) */
    if (strlen(query_lower_ptr) >= 3 && !is_wildcard) {
        /* Try fuzzy on filename first */
        double score = repo_similarity_score(name_lower_ptr, query_lower_ptr);
        if (score >= fuzzy_threshold) {
            return 500;
        }
        
        /* Then try fuzzy on path components */
        strncpy(path_copy, path_lower_ptr, sizeof(path_copy) - 1);
        path_copy[sizeof(path_copy) - 1] = '\0';
        
        component = strtok_r(path_copy, "/", &saveptr);
        while (component != NULL) {
            score = repo_similarity_score(component, query_lower_ptr);
            if (score >= fuzzy_threshold) {
                return 450;
            }
            component = strtok_r(NULL, "/", &saveptr);
        }
    }
    
    /* No match */
    return 0;
}

/* Batch scoring function with optional pre-lowercased strings */
void repo_score_matches_batch(const struct repo_file_info *files, size_t file_count,
                             const char *query, const char *query_lower,
                             bool has_slash, bool is_wildcard,
                             double fuzzy_threshold, int *scores) {
    for (size_t i = 0; i < file_count; i++) {
        scores[i] = repo_score_match(files[i].name, files[i].path,
                                    files[i].name_lower, files[i].path_lower,
                                    query, query_lower,
                                    has_slash, is_wildcard, fuzzy_threshold);
    }
}
