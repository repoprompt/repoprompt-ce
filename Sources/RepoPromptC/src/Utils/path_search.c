#include "path_search.h"
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <regex.h>
#include <stdio.h>
#include "wildmatch.h"

// Debug logging macros
//#define DEBUG_SEARCH 1
#ifdef DEBUG_SEARCH
#define SEARCH_LOG(...) printf(__VA_ARGS__)
#else
#define SEARCH_LOG(...) ((void)0)
#endif

// Create path search index
path_search_index_t* path_search_create(const char** paths, size_t count) {
    SEARCH_LOG("path_search_create: count=%zu\n", count);
    if (!paths || count == 0) {
        SEARCH_LOG("path_search_create: invalid input\n");
        return NULL;
    }
    
    path_search_index_t* index = calloc(1, sizeof(path_search_index_t));
    if (!index) return NULL;
    
    index->count = count;
    index->capacity = count;
    
    // Allocate arrays
    index->forward_paths = calloc(count, sizeof(char*));
    index->reversed_paths = calloc(count, sizeof(char*));
    index->original_paths = calloc(count, sizeof(char*));
    index->forward_indices = calloc(count, sizeof(size_t));
    index->reversed_indices = calloc(count, sizeof(size_t));
    
    if (!index->forward_paths || !index->reversed_paths || 
        !index->original_paths || !index->forward_indices || 
        !index->reversed_indices) {
        path_search_destroy(index);
        return NULL;
    }
    
    // Copy original paths
    for (size_t i = 0; i < count; i++) {
        index->original_paths[i] = strdup(paths[i]);
    }
    
    // Copy and sort forward paths
    for (size_t i = 0; i < count; i++) {
        index->forward_paths[i] = strdup(paths[i]);
        index->forward_indices[i] = i;
    }
    
    // Sort forward paths with index tracking
    // We need a custom sort that maintains the index mapping
    typedef struct {
        char* path;
        size_t original_index;
    } path_with_index_t;
    
    path_with_index_t* temp = calloc(count, sizeof(path_with_index_t));
    for (size_t i = 0; i < count; i++) {
        temp[i].path = index->forward_paths[i];
        temp[i].original_index = i;
    }
    
    qsort(temp, count, sizeof(path_with_index_t), 
          (int (*)(const void*, const void*))path_compare);
    
    // Update arrays with sorted data
    for (size_t i = 0; i < count; i++) {
        index->forward_paths[i] = temp[i].path;
        index->forward_indices[i] = temp[i].original_index;
    }
    
    // Create reversed paths
    for (size_t i = 0; i < count; i++) {
        size_t orig_idx = index->forward_indices[i];
        index->reversed_paths[i] = path_reverse(index->original_paths[orig_idx]);
        index->reversed_indices[i] = orig_idx;
    }
    
    // Sort reversed paths
    for (size_t i = 0; i < count; i++) {
        temp[i].path = index->reversed_paths[i];
        temp[i].original_index = index->reversed_indices[i];
    }
    
    qsort(temp, count, sizeof(path_with_index_t),
          (int (*)(const void*, const void*))path_compare);
    
    for (size_t i = 0; i < count; i++) {
        index->reversed_paths[i] = temp[i].path;
        index->reversed_indices[i] = temp[i].original_index;
    }
    
    
    free(temp);
    return index;
}

// Destroy path search index
void path_search_destroy(path_search_index_t* index) {
    if (!index) return;
    
    if (index->forward_paths) {
        for (size_t i = 0; i < index->count; i++) {
            free(index->forward_paths[i]);
        }
        free(index->forward_paths);
    }
    
    if (index->reversed_paths) {
        for (size_t i = 0; i < index->count; i++) {
            free(index->reversed_paths[i]);
        }
        free(index->reversed_paths);
    }
    
    if (index->original_paths) {
        for (size_t i = 0; i < index->count; i++) {
            free(index->original_paths[i]);
        }
        free(index->original_paths);
    }
    
    free(index->forward_indices);
    free(index->reversed_indices);
    free(index);
}


// Pattern decomposition
pattern_parts_t* pattern_decompose(const char* pattern) {
    if (!pattern) return NULL;
    
    pattern_parts_t* parts = calloc(1, sizeof(pattern_parts_t));
    if (!parts) return NULL;
    
    size_t len = strlen(pattern);
    const char* meta_chars = "*?[]{}()|.+^$\\";
    
    // Check if pattern contains wildcards
    parts->is_wildcard = (strpbrk(pattern, "*?") != NULL);
    
    // Check if pattern contains spaces (for multi-term search)
    bool has_spaces = strchr(pattern, ' ') != NULL && !parts->is_wildcard;
    
    // For non-wildcard patterns, use empty prefix/suffix to search all files
    if (!parts->is_wildcard) {
        parts->prefix = strdup("");
        parts->suffix = strdup("");
    } else {
        // Find prefix (longest literal before first metachar)
        size_t prefix_len = 0;
        for (size_t i = 0; i < len; i++) {
            if (strchr(meta_chars, pattern[i])) {
                break;
            }
            prefix_len++;
        }
        
        parts->prefix = strndup(pattern, prefix_len);
        
        // Find suffix (longest literal after last metachar)
        // For *.swift, we want suffix="swift" not ".swift"
        size_t suffix_start = len;
        for (size_t i = len; i > prefix_len; i--) {
            if (strchr(meta_chars, pattern[i - 1])) {
                suffix_start = i;
                break;
            }
        }
        
        if (suffix_start < len) {
            parts->suffix = strdup(pattern + suffix_start);
        } else {
            parts->suffix = strdup("");
        }
    }
    
    // Convert glob to regex
    char* regex_buf = calloc(len * 10 + 100, sizeof(char)); // Extra space for AND logic
    if (!regex_buf) {
        pattern_parts_destroy(parts);
        return NULL;
    }
    
    char* out = regex_buf;
    
    // Handle space-separated terms as AND conditions
    if (has_spaces) {
        // For space-separated patterns, we'll store the pattern as-is
        // and handle the AND logic during matching
        // Store a special marker to indicate this needs AND processing
        strcpy(out, "SPACE_AND:");
        out += 10;
        strcpy(out, pattern);
        out += strlen(pattern);
        *out = '\0';
    } else {
        // Original single-pattern logic
        // If pattern has no wildcards, search for it as a substring
        if (!parts->is_wildcard) {
            *out++ = '.';
            *out++ = '*';
        } else {
            // For wildcard patterns, check if pattern starts with *
            // If so, we want to match anywhere in the path
            if (pattern[0] == '*') {
                *out++ = '.';
                *out++ = '*';
            } else {
                *out++ = '^';
            }
        }
        
        for (size_t i = 0; i < len; i++) {
            char c = pattern[i];
            
            if (c == '*') {
                // Check for **
                if (i + 1 < len && pattern[i + 1] == '*') {
                    *out++ = '.';
                    *out++ = '*';
                    i++; // Skip next *
                } else {
                    *out++ = '[';
                    *out++ = '^';
                    *out++ = '/';
                    *out++ = ']';
                    *out++ = '*';
                }
            } else if (c == '?') {
                *out++ = '[';
                *out++ = '^';
                *out++ = '/';
                *out++ = ']';
            } else if (strchr("[]{}().|+^$\\", c)) {
                *out++ = '\\';
                *out++ = c;
            } else {
                *out++ = c;
            }
        }
        
        if (!parts->is_wildcard) {
            *out++ = '.';
            *out++ = '*';
        } else {
            *out++ = '$';
        }
        *out = '\0';
    }
    
    parts->regex_pattern = regex_buf;
    
    SEARCH_LOG("pattern_decompose: pattern='%s'\n", pattern);
    SEARCH_LOG("  is_wildcard=%d, has_spaces=%d\n", parts->is_wildcard, has_spaces);
    SEARCH_LOG("  prefix='%s', suffix='%s'\n", parts->prefix, parts->suffix);
    SEARCH_LOG("  regex='%s' (strlen=%zu)\n", parts->regex_pattern, strlen(parts->regex_pattern));
    // Check if regex ends with $
    size_t regex_len = strlen(parts->regex_pattern);
    if (regex_len > 0) {
        SEARCH_LOG("  regex last char: '%c' (0x%02x)\n", 
                   parts->regex_pattern[regex_len-1], 
                   (unsigned char)parts->regex_pattern[regex_len-1]);
    }
    
    return parts;
}

void pattern_parts_destroy(pattern_parts_t* parts) {
    if (!parts) return;
    free(parts->prefix);
    free(parts->suffix);
    free(parts->regex_pattern);
    free(parts);
}

// Binary search for lower bound
size_t path_search_lower_bound(const char** array, size_t count, const char* prefix) {
    if (!array || !prefix || count == 0) return 0;
    
    size_t left = 0;
    size_t right = count;
    size_t prefix_len = strlen(prefix);
    
    while (left < right) {
        size_t mid = (left + right) / 2;
        if (strncmp(array[mid], prefix, prefix_len) < 0) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }
    
    return left;
}

// Binary search for upper bound
size_t path_search_upper_bound(const char** array, size_t count, const char* prefix) {
    if (!array || !prefix || count == 0) return count;
    
    size_t left = 0;
    size_t right = count;
    size_t prefix_len = strlen(prefix);
    
    while (left < right) {
        size_t mid = (left + right) / 2;
        
        // Compare with prefix
        int cmp = strncmp(array[mid], prefix, prefix_len);
        if (cmp <= 0) {
            // array[mid] is less than prefix OR starts with prefix
            left = mid + 1;
        } else {
            // array[mid] is greater than prefix
            right = mid;
        }
    }
    
    return left;
}

// Main search function
search_result_t* path_search_find(
    const path_search_index_t* index,
    const char* pattern,
    size_t limit
) {
    SEARCH_LOG("path_search_find: pattern='%s', limit=%zu\n", pattern, limit);
    if (!index || !pattern) {
        SEARCH_LOG("path_search_find: invalid input\n");
        return NULL;
    }
    
    pattern_parts_t* parts = pattern_decompose(pattern);
    if (!parts) return NULL;
    
    SEARCH_LOG("path_search_find: prefix='%s', suffix='%s', regex='%s'\n", 
           parts->prefix, parts->suffix, parts->regex_pattern);
    
    // Get prefix range
    size_t prefix_start = path_search_lower_bound(
        (const char**)index->forward_paths, index->count, parts->prefix);
    size_t prefix_end = path_search_upper_bound(
        (const char**)index->forward_paths, index->count, parts->prefix);
    
    SEARCH_LOG("path_search_find: prefix range [%zu, %zu) out of %zu paths\n", 
           prefix_start, prefix_end, index->count);
    
    // Create initial candidate set
    size_t* candidates = NULL;
    size_t candidate_count = 0;
    
    if (strlen(parts->suffix) > 0) {
        // Need to intersect with suffix matches
        char* reversed_suffix = path_reverse(parts->suffix);
        
        SEARCH_LOG("path_search_find: suffix='%s', reversed='%s'\n", 
                   parts->suffix, reversed_suffix);
        
        size_t suffix_start = path_search_lower_bound(
            (const char**)index->reversed_paths, index->count, reversed_suffix);
        size_t suffix_end = path_search_upper_bound(
            (const char**)index->reversed_paths, index->count, reversed_suffix);
        
        SEARCH_LOG("path_search_find: suffix range [%zu, %zu)\n", 
                   suffix_start, suffix_end);
        
        
        // Build set of original indices from suffix matches
        bool* suffix_set = calloc(index->count, sizeof(bool));
        for (size_t i = suffix_start; i < suffix_end; i++) {
            suffix_set[index->reversed_indices[i]] = true;
        }
        
        // Intersect with prefix matches
        candidates = calloc(prefix_end - prefix_start, sizeof(size_t));
        for (size_t i = prefix_start; i < prefix_end; i++) {
            size_t orig_idx = index->forward_indices[i];
            if (suffix_set[orig_idx]) {
                candidates[candidate_count++] = orig_idx;
            }
        }
        
        free(suffix_set);
        free(reversed_suffix);
    } else {
        // Just use prefix matches
        candidate_count = prefix_end - prefix_start;
        candidates = calloc(candidate_count, sizeof(size_t));
        for (size_t i = 0; i < candidate_count; i++) {
            candidates[i] = index->forward_indices[prefix_start + i];
        }
    }
    
    
    // Apply regex filter or special space handling
    search_result_t* result = calloc(1, sizeof(search_result_t));
    if (!result) {
        free(candidates);
        pattern_parts_destroy(parts);
        return NULL;
    }
    result->capacity = limit < candidate_count ? limit : candidate_count;
    if (result->capacity > 0) {
        result->indices = calloc(result->capacity, sizeof(size_t));
        result->scores = calloc(result->capacity, sizeof(int32_t));
        result->tie_break_keys = calloc(result->capacity, sizeof(const char*));
        if (!result->indices || !result->scores || !result->tie_break_keys) {
            search_result_destroy(result);
            free(candidates);
            pattern_parts_destroy(parts);
            return NULL;
        }
    }
    result->count = 0;
    
    // Check if this is a space-separated AND pattern
    if (strncmp(parts->regex_pattern, "SPACE_AND:", 10) == 0) {
        // Extract the original pattern
        const char* space_pattern = parts->regex_pattern + 10;
        
        SEARCH_LOG("path_search_find: handling space-separated AND pattern '%s'\n", space_pattern);
        
        // Split the pattern and check each term
        char* pattern_copy = strdup(space_pattern);
        
        // First, collect all terms
        char* terms[20]; // Max 20 terms
        int term_count = 0;
        char* token = strtok(pattern_copy, " ");
        while (token != NULL && term_count < 20) {
            if (strlen(token) > 0) {
                terms[term_count++] = strdup(token);
            }
            token = strtok(NULL, " ");
        }
        free(pattern_copy);
        
        // Now check each candidate against all terms
        SEARCH_LOG("path_search_find: testing %zu candidates with %d terms\n", candidate_count, term_count);
        for (size_t i = 0; i < candidate_count && result->count < limit; i++) {
            size_t orig_idx = candidates[i];
            const char* path = index->original_paths[orig_idx];
            
            if (path) {
                // Check if all terms are present (case-insensitive)
                int all_match = 1;
                for (int j = 0; j < term_count; j++) {
                    if (strcasestr(path, terms[j]) == NULL) {
                        all_match = 0;
                        break;
                    }
                }
                
                if (all_match) {
                    size_t result_index = result->count++;
                    result->indices[result_index] = orig_idx;
                    result->scores[result_index] = 1;
                    result->tie_break_keys[result_index] = path;
                    if (result->count <= 5) {
                        SEARCH_LOG("  matched: %s\n", path);
                    }
                }
            }
        }
        
        // Free the terms
        for (int i = 0; i < term_count; i++) {
            free(terms[i]);
        }
    } else {
        // Regular regex matching
        regex_t regex;
        int ret = regcomp(&regex, parts->regex_pattern, REG_EXTENDED | REG_ICASE);
        
        if (ret == 0) {
            SEARCH_LOG("path_search_find: testing %zu candidates with regex\n", candidate_count);
            for (size_t i = 0; i < candidate_count && result->count < limit; i++) {
                size_t orig_idx = candidates[i];
                // Get the original path using the index
                const char* path = index->original_paths[orig_idx];
                
                if (path && regexec(&regex, path, 0, NULL, 0) == 0) {
                    size_t result_index = result->count++;
                    result->indices[result_index] = orig_idx;
                    result->scores[result_index] = 1;
                    result->tie_break_keys[result_index] = path;
                    if (result->count <= 5) {  // Log first few matches
                        SEARCH_LOG("  matched: %s\n", path);
                    }
                }
            }
            regfree(&regex);
        } else {
            char errbuf[256];
            regerror(ret, &regex, errbuf, sizeof(errbuf));
            SEARCH_LOG("path_search_find: regex compilation failed: %s (error code: %d)\n", errbuf, ret);
        }
    }
    
    free(candidates);
    pattern_parts_destroy(parts);
    
    return result;
}

void search_result_destroy(search_result_t* result) {
    if (!result) return;
    free(result->indices);
    free(result->scores);
    free(result->tie_break_keys);
    free(result);
}

// Helper: reverse a string
char* path_reverse(const char* path) {
    if (!path) return NULL;
    
    size_t len = strlen(path);
    char* reversed = malloc(len + 1);
    if (!reversed) return NULL;
    
    for (size_t i = 0; i < len; i++) {
        reversed[i] = path[len - 1 - i];
    }
    reversed[len] = '\0';
    
    return reversed;
}

// Helper: compare paths for sorting
int path_compare(const void* a, const void* b) {
    typedef struct {
        char* path;
        size_t original_index;
    } path_with_index_t;
    
    const path_with_index_t* pa = (const path_with_index_t*)a;
    const path_with_index_t* pb = (const path_with_index_t*)b;
    
    int comparison = strcmp(pa->path, pb->path);
    if (comparison != 0) return comparison;
    if (pa->original_index < pb->original_index) return -1;
    if (pa->original_index > pb->original_index) return 1;
    return 0;
}
