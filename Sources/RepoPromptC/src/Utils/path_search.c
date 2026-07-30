#include "path_search.h"
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <regex.h>
#include <stdio.h>
#include <stdatomic.h>
#include <stdint.h>
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
        size_t path_length = strlen(paths[i]);
        if (path_length > index->maximum_path_length) {
            index->maximum_path_length = path_length;
        }
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

struct path_search_cancellation {
    atomic_bool cancelled;
};

path_search_cancellation_t* path_search_cancellation_create(void) {
    path_search_cancellation_t* cancellation = calloc(1, sizeof(path_search_cancellation_t));
    if (cancellation) atomic_init(&cancellation->cancelled, false);
    return cancellation;
}

void path_search_cancellation_cancel(path_search_cancellation_t* cancellation) {
    if (cancellation) atomic_store_explicit(&cancellation->cancelled, true, memory_order_release);
}

void path_search_cancellation_destroy(path_search_cancellation_t* cancellation) {
    free(cancellation);
}

static bool projected_cancelled(const path_search_cancellation_t* cancellation) {
    return cancellation
        && atomic_load_explicit(&cancellation->cancelled, memory_order_acquire);
}

typedef struct projected_key_cursor {
    const char* segments[4];
    size_t lengths[4];
    size_t segment;
    size_t offset;
} projected_key_cursor_t;

static bool projected_key_next(projected_key_cursor_t* cursor, unsigned char* byte) {
    while (cursor->segment < 4 && cursor->offset >= cursor->lengths[cursor->segment]) {
        cursor->segment++;
        cursor->offset = 0;
    }
    if (cursor->segment >= 4) return false;
    *byte = (unsigned char)cursor->segments[cursor->segment][cursor->offset++];
    return true;
}

static int projected_index_compare(
    const path_search_index_t* index,
    const char* absolute_prefix,
    size_t lhs,
    size_t rhs,
    path_search_work_stats_t* stats
) {
    if (stats) stats->heap_comparison_count++;
    const char* lhs_path = index->original_paths[lhs];
    const char* rhs_path = index->original_paths[rhs];
    const char separator[] = "\n";
    size_t absolute_length = strlen(absolute_prefix);
    projected_key_cursor_t lhs_cursor = {
        .segments = {lhs_path, separator, absolute_prefix, lhs_path},
        .lengths = {strlen(lhs_path), 1, absolute_length, strlen(lhs_path)}
    };
    projected_key_cursor_t rhs_cursor = {
        .segments = {rhs_path, separator, absolute_prefix, rhs_path},
        .lengths = {strlen(rhs_path), 1, absolute_length, strlen(rhs_path)}
    };
    while (true) {
        unsigned char lhs_byte = 0;
        unsigned char rhs_byte = 0;
        bool has_lhs = projected_key_next(&lhs_cursor, &lhs_byte);
        bool has_rhs = projected_key_next(&rhs_cursor, &rhs_byte);
        if (!has_lhs || !has_rhs) {
            if (has_lhs != has_rhs) return has_lhs ? 1 : -1;
            if (lhs < rhs) return -1;
            if (lhs > rhs) return 1;
            return 0;
        }
        if (lhs_byte < rhs_byte) return -1;
        if (lhs_byte > rhs_byte) return 1;
    }
}

static void projected_heap_sift_up(
    size_t* heap,
    size_t position,
    const path_search_index_t* index,
    const char* absolute_prefix,
    path_search_work_stats_t* stats
) {
    while (position > 0) {
        size_t parent = (position - 1) / 2;
        if (projected_index_compare(index, absolute_prefix, heap[parent], heap[position], stats) >= 0) break;
        size_t swap = heap[parent];
        heap[parent] = heap[position];
        heap[position] = swap;
        position = parent;
    }
}

static void projected_heap_sift_down(
    size_t* heap,
    size_t count,
    size_t position,
    const path_search_index_t* index,
    const char* absolute_prefix,
    path_search_work_stats_t* stats
) {
    while (true) {
        size_t left = position * 2 + 1;
        if (left >= count) break;
        size_t right = left + 1;
        size_t worst = left;
        if (right < count
            && projected_index_compare(index, absolute_prefix, heap[left], heap[right], stats) < 0) {
            worst = right;
        }
        if (projected_index_compare(index, absolute_prefix, heap[position], heap[worst], stats) >= 0) break;
        size_t swap = heap[position];
        heap[position] = heap[worst];
        heap[worst] = swap;
        position = worst;
    }
}

static bool projected_space_and_matches(const char* key, char* const* terms, size_t term_count) {
    for (size_t index = 0; index < term_count; index++) {
        if (strcasestr(key, terms[index]) == NULL) return false;
    }
    return true;
}

search_result_t* path_search_projected_find(
    const path_search_index_t* relative_index,
    const char* pattern,
    const char* display_prefix,
    const char* absolute_prefix,
    size_t limit
) {
    return path_search_projected_find_cancellable(
        relative_index,
        pattern,
        display_prefix,
        absolute_prefix,
        limit,
        NULL,
        NULL
    );
}

search_result_t* path_search_projected_find_cancellable(
    const path_search_index_t* relative_index,
    const char* pattern,
    const char* display_prefix,
    const char* absolute_prefix,
    size_t limit,
    const path_search_cancellation_t* cancellation,
    path_search_work_stats_t* stats
) {
    if (!relative_index || !pattern || !display_prefix || !absolute_prefix) return NULL;
    if (stats) memset(stats, 0, sizeof(*stats));

    pattern_parts_t* parts = pattern_decompose(pattern);
    if (!parts) return NULL;
    bool is_space_and = strncmp(parts->regex_pattern, "SPACE_AND:", 10) == 0;
    char* pattern_copy = NULL;
    char* terms[20] = {0};
    size_t term_count = 0;
    if (is_space_and) {
        pattern_copy = strdup(parts->regex_pattern + 10);
        if (!pattern_copy) {
            pattern_parts_destroy(parts);
            return NULL;
        }
        char* state = NULL;
        char* term = strtok_r(pattern_copy, " ", &state);
        while (term && term_count < 20) {
            if (*term != '\0') terms[term_count++] = term;
            term = strtok_r(NULL, " ", &state);
        }
    }
    regex_t regex;
    bool has_regex = false;
    if (!is_space_and) {
        has_regex = regcomp(&regex, parts->regex_pattern, REG_EXTENDED | REG_ICASE) == 0;
    }

    search_result_t* result = calloc(1, sizeof(search_result_t));
    if (!result) {
        free(pattern_copy);
        if (has_regex) regfree(&regex);
        pattern_parts_destroy(parts);
        return NULL;
    }
    result->capacity = limit < relative_index->count ? limit : relative_index->count;
    size_t* heap = result->capacity > 0
        ? calloc(result->capacity, sizeof(size_t))
        : NULL;
    if (result->capacity > 0) {
        result->indices = calloc(result->capacity, sizeof(size_t));
        result->scores = calloc(result->capacity, sizeof(int32_t));
        if (!result->indices || !result->scores || !heap) {
            free(heap);
            search_result_destroy(result);
            free(pattern_copy);
            if (has_regex) regfree(&regex);
            pattern_parts_destroy(parts);
            return NULL;
        }
    }

    size_t display_length = strlen(display_prefix);
    size_t absolute_length = strlen(absolute_prefix);
    if (relative_index->maximum_path_length > (SIZE_MAX - display_length - absolute_length - 2) / 2) {
        free(heap);
        search_result_destroy(result);
        free(pattern_copy);
        if (has_regex) regfree(&regex);
        pattern_parts_destroy(parts);
        return NULL;
    }
    size_t scratch_bytes = display_length + absolute_length
        + relative_index->maximum_path_length * 2 + 2;
    char* scratch = malloc(scratch_bytes);
    if (!scratch && scratch_bytes > 0) {
        free(heap);
        search_result_destroy(result);
        free(pattern_copy);
        if (has_regex) regfree(&regex);
        pattern_parts_destroy(parts);
        return NULL;
    }
    if (stats) stats->scratch_bytes = scratch_bytes;
    size_t heap_count = 0;
    for (size_t index = 0; index < relative_index->count; index++) {
        if ((index & 63) == 0 && projected_cancelled(cancellation)) {
            if (stats) stats->cancelled = true;
            break;
        }
        const char* relative_path = relative_index->original_paths[index];
        if (!relative_path) continue;
        if (stats) stats->examined_count++;
        size_t relative_length = strlen(relative_path);
        size_t key_length = display_length + relative_length + 1 + absolute_length + relative_length;
        memcpy(scratch, display_prefix, display_length);
        memcpy(scratch + display_length, relative_path, relative_length);
        scratch[display_length + relative_length] = '\n';
        memcpy(scratch + display_length + relative_length + 1, absolute_prefix, absolute_length);
        memcpy(
            scratch + display_length + relative_length + 1 + absolute_length,
            relative_path,
            relative_length
        );
        scratch[key_length] = '\0';

        bool matched = is_space_and
            ? projected_space_and_matches(scratch, terms, term_count)
            : (has_regex && regexec(&regex, scratch, 0, NULL, 0) == 0);
        if (matched) {
            if (stats) stats->matched_count++;
            if (heap_count < result->capacity) {
                heap[heap_count] = index;
                projected_heap_sift_up(heap, heap_count, relative_index, absolute_prefix, stats);
                heap_count++;
                if (stats && heap_count > stats->heap_peak_count) stats->heap_peak_count = heap_count;
            } else if (heap_count > 0
                       && projected_index_compare(relative_index, absolute_prefix, index, heap[0], stats) < 0) {
                heap[0] = index;
                projected_heap_sift_down(heap, heap_count, 0, relative_index, absolute_prefix, stats);
            }
        }
    }
    if (projected_cancelled(cancellation)) {
        if (stats) stats->cancelled = true;
        heap_count = 0;
    }
    result->count = heap_count;
    for (size_t output = heap_count; output > 0; output--) {
        result->indices[output - 1] = heap[0];
        result->scores[output - 1] = 1;
        heap_count--;
        if (heap_count > 0) {
            heap[0] = heap[heap_count];
            projected_heap_sift_down(heap, heap_count, 0, relative_index, absolute_prefix, stats);
        }
    }
    free(scratch);
    free(heap);
    free(pattern_copy);
    if (has_regex) regfree(&regex);
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
