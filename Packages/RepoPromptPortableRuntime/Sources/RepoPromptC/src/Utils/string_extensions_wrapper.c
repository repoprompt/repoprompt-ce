/*
 * string_extensions_wrapper.c
 * 
 * High-performance C implementations of string manipulation functions
 * originally implemented in Swift's StringExtensions.swift
 */

#include "string_extensions_wrapper.h"
#include <string.h>
#include <stdlib.h>
#include <stdbool.h>
#include <stdint.h>
#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <errno.h>
#include <limits.h>

/* MARK: - Levenshtein Distance */

/**
 * Count UTF-8 characters (not bytes) in a string
 */
static size_t utf8_strlen(const char *s) {
    size_t len = 0;
    while (*s) {
        if ((*s & 0xC0) != 0x80) len++;
        s++;
    }
    return len;
}

/**
 * Get the nth UTF-8 character from a string
 * Returns pointer to the character, or NULL if out of bounds
 */
static const char* utf8_char_at(const char *s, size_t n) {
    size_t i = 0;
    while (*s && i < n) {
        if ((*s & 0xC0) != 0x80) i++;
        if (i <= n) s++;
    }
    return *s ? s : NULL;
}

/**
 * Compare two UTF-8 characters for equality
 * Returns 1 if equal, 0 if different
 */
static int utf8_char_equal(const char *a, const char *b) {
    if (!a || !b) return 0;
    
    /* Get the length of the first character */
    int len_a = 1;
    if ((*a & 0x80) == 0) len_a = 1;
    else if ((*a & 0xE0) == 0xC0) len_a = 2;
    else if ((*a & 0xF0) == 0xE0) len_a = 3;
    else if ((*a & 0xF8) == 0xF0) len_a = 4;
    
    /* Compare the bytes */
    for (int i = 0; i < len_a; i++) {
        if (a[i] != b[i]) return 0;
        if ((a[i] & 0xC0) != 0x80 && i > 0) return 0; /* Invalid UTF-8 */
    }
    
    return 1;
}

int repo_levenshtein_distance(const char *a, const char *b, int maxDist) {
    if (!a || !b) return -1;
    if (strcmp(a, b) == 0) return 0;

    /* Length in UTF-8 code-points (not bytes) */
    size_t len_a = utf8_strlen(a);
    size_t len_b = utf8_strlen(b);

    if (len_a == 0) return (int)len_b;
    if (len_b == 0) return (int)len_a;

    /* Fast reject when a capped distance is impossible */
    if (maxDist >= 0 && abs((int)len_a - (int)len_b) > maxDist)
        return maxDist + 1;

    /* Always iterate over the shorter string */
    if (len_b < len_a)
        return repo_levenshtein_distance(b, a, maxDist);

    /* Build lookup tables of UTF-8 character starts */
    const char **chars_a = malloc(len_a * sizeof(char*));
    const char **chars_b = malloc(len_b * sizeof(char*));
    if (!chars_a || !chars_b) {
        free(chars_a); free(chars_b);
        return -1;
    }

    const char *p = a;
    size_t idx = 0;
    while (*p) {
        if ((*p & 0xC0) != 0x80) chars_a[idx++] = p;
        p++;
    }

    p = b;
    idx = 0;
    while (*p) {
        if ((*p & 0xC0) != 0x80) chars_b[idx++] = p;
        p++;
    }

    /* DP rows */
    int *prev = malloc((len_b + 1) * sizeof(int));
    int *curr = malloc((len_b + 1) * sizeof(int));
    if (!prev || !curr) {
        free(prev); free(curr);
        free(chars_a); free(chars_b);
        return -1;
    }

    for (size_t j = 0; j <= len_b; j++) prev[j] = (int)j;

    /* ---------- Uncapped standard DP ---------- */
    if (maxDist < 0) {
        for (size_t i = 1; i <= len_a; i++) {
            curr[0] = (int)i;
            for (size_t j = 1; j <= len_b; j++) {
                int ins = curr[j - 1] + 1;
                int del = prev[j] + 1;
                int sub = prev[j - 1] +
                          (utf8_char_equal(chars_a[i - 1], chars_b[j - 1]) ? 0 : 1);
                int v = ins < del ? ins : del;
                if (sub < v) v = sub;
                curr[j] = v;
            }
            int *tmp = prev; prev = curr; curr = tmp;
        }
        int result = prev[len_b];
        free(prev); free(curr); free(chars_a); free(chars_b);
        return result;
    }

    /* ---------- Capped (banded) DP ---------- */
    int big = maxDist + 1;

    for (size_t j = 0; j <= len_b; j++) {
        prev[j] = big;
        curr[j] = big;
    }
    prev[0] = 0;
    size_t hi = (len_b < (size_t)maxDist) ? len_b : (size_t)maxDist;
    for (size_t j = 1; j <= hi; j++) prev[j] = (int)j;

    for (size_t i = 1; i <= len_a; i++) {
        int j_lo = (int)i - maxDist;
        if (j_lo < 1) j_lo = 1;
        int j_hi = (int)i + maxDist;
        if (j_hi > (int)len_b) j_hi = (int)len_b;

        for (size_t j = 0; j <= len_b; j++) curr[j] = big;
        if (j_lo == 1) curr[0] = (int)i;

        int row_min = big;

        for (int j = j_lo; j <= j_hi; j++) {
            int ins = curr[j - 1] + 1;
            int del = prev[j] + 1;
            int sub = prev[j - 1] +
                      (utf8_char_equal(chars_a[i - 1], chars_b[j - 1]) ? 0 : 1);
            int v = ins < del ? ins : del;
            if (sub < v) v = sub;
            curr[j] = v;
            if (v < row_min) row_min = v;
        }

        /* Bail out early if row can't beat maxDist */
        if (row_min > maxDist) {
            free(prev); free(curr); free(chars_a); free(chars_b);
            return big;
        }

        int *tmp = prev; prev = curr; curr = tmp;
    }

    int dist = prev[len_b];
    free(prev); free(curr); free(chars_a); free(chars_b);
    return (dist > maxDist) ? big : dist;
}

/* MARK: - Dice Coefficient */

/**
 * Sørensen–Dice coefficient on character bigrams
 * Returns value between 0.0 and 1.0
 */
double repo_dice_coefficient(const char *a, const char *b) {
    if (!a || !b) return 0.0;
    
    size_t len_a = strlen(a);
    size_t len_b = strlen(b);
    
    if (len_a == 0 || len_b == 0) return 0.0;
    if (strcmp(a, b) == 0) return 1.0;
    if (len_a == 1 || len_b == 1) {
        return (a[0] == b[0]) ? 1.0 : 0.0;
    }
    
    /* Count bigrams using a simple hash table */
    /* We'll use a 16-bit hash for bigrams (8 bits per char) */
    #define BIGRAM_TABLE_SIZE 65536
    int *bigrams_a = calloc(BIGRAM_TABLE_SIZE, sizeof(int));
    int *bigrams_b = calloc(BIGRAM_TABLE_SIZE, sizeof(int));
    
    if (!bigrams_a || !bigrams_b) {
        free(bigrams_a);
        free(bigrams_b);
        return 0.0;
    }
    
    /* Convert to lowercase and count bigrams for string a */
    for (size_t i = 0; i < len_a - 1; i++) {
        unsigned char c1 = tolower((unsigned char)a[i]);
        unsigned char c2 = tolower((unsigned char)a[i + 1]);
        uint16_t key = ((uint16_t)c1 << 8) | c2;
        bigrams_a[key]++;
    }
    
    /* Count bigrams for string b */
    for (size_t i = 0; i < len_b - 1; i++) {
        unsigned char c1 = tolower((unsigned char)b[i]);
        unsigned char c2 = tolower((unsigned char)b[i + 1]);
        uint16_t key = ((uint16_t)c1 << 8) | c2;
        bigrams_b[key]++;
    }
    
    /* Compute intersection size */
    int intersection = 0;
    for (int i = 0; i < BIGRAM_TABLE_SIZE; i++) {
        if (bigrams_a[i] > 0 && bigrams_b[i] > 0) {
            intersection += (bigrams_a[i] < bigrams_b[i]) ? bigrams_a[i] : bigrams_b[i];
        }
    }
    
    free(bigrams_a);
    free(bigrams_b);
    
    /* Total bigrams */
    int total_a = (int)(len_a - 1);
    int total_b = (int)(len_b - 1);
    
    return (2.0 * intersection) / (double)(total_a + total_b);
}

/* MARK: - Longest Common Subsequence */

/**
 * Get the next UTF-8 character and advance the pointer
 */
static const char* next_utf8_char(const char *s, int *char_len) {
    if (!s || !*s) {
        *char_len = 0;
        return NULL;
    }
    
    unsigned char c = *s;
    if ((c & 0x80) == 0) *char_len = 1;
    else if ((c & 0xE0) == 0xC0) *char_len = 2;
    else if ((c & 0xF0) == 0xE0) *char_len = 3;
    else if ((c & 0xF8) == 0xF0) *char_len = 4;
    else *char_len = 1; /* Invalid UTF-8, treat as single byte */
    
    return s;
}

/**
 * Compare UTF-8 characters at given positions
 */
static bool utf8_chars_equal(const char *a, int a_len, const char *b, int b_len) {
    if (a_len != b_len) return false;
    return memcmp(a, b, a_len) == 0;
}

/**
 * Finds the longest common subsequence between two strings
 * Returns dynamically allocated string that must be freed by caller
 */
char* repo_longest_common_subsequence(const char *a, const char *b) {
    if (!a || !b) return NULL;
    
    /* Count UTF-8 characters and build position arrays */
    size_t m = 0, n = 0;
    const char *p;
    
    /* Count characters in a */
    p = a;
    while (*p) {
        int char_len;
        next_utf8_char(p, &char_len);
        if (char_len == 0) break;
        p += char_len;
        m++;
    }
    
    /* Count characters in b */
    p = b;
    while (*p) {
        int char_len;
        next_utf8_char(p, &char_len);
        if (char_len == 0) break;
        p += char_len;
        n++;
    }
    
    if (m == 0 || n == 0) {
        return strdup("");
    }
    
    /* Build character position arrays */
    const char **a_chars = malloc(m * sizeof(char*));
    int *a_lens = malloc(m * sizeof(int));
    const char **b_chars = malloc(n * sizeof(char*));
    int *b_lens = malloc(n * sizeof(int));
    
    if (!a_chars || !a_lens || !b_chars || !b_lens) {
        free(a_chars); free(a_lens); free(b_chars); free(b_lens);
        return NULL;
    }
    
    /* Fill position arrays */
    p = a;
    for (size_t i = 0; i < m; i++) {
        a_chars[i] = next_utf8_char(p, &a_lens[i]);
        p += a_lens[i];
    }
    
    p = b;
    for (size_t i = 0; i < n; i++) {
        b_chars[i] = next_utf8_char(p, &b_lens[i]);
        p += b_lens[i];
    }
    
    /* Allocate DP table */
    int **dp = malloc((m + 1) * sizeof(int*));
    if (!dp) {
        free(a_chars); free(a_lens); free(b_chars); free(b_lens);
        return NULL;
    }
    
    for (size_t i = 0; i <= m; i++) {
        dp[i] = calloc(n + 1, sizeof(int));
        if (!dp[i]) {
            for (size_t j = 0; j < i; j++) free(dp[j]);
            free(dp);
            free(a_chars); free(a_lens); free(b_chars); free(b_lens);
            return NULL;
        }
    }
    
    /* Fill DP table */
    for (size_t i = 1; i <= m; i++) {
        for (size_t j = 1; j <= n; j++) {
            if (utf8_chars_equal(a_chars[i-1], a_lens[i-1], b_chars[j-1], b_lens[j-1])) {
                dp[i][j] = dp[i - 1][j - 1] + 1;
            } else {
                dp[i][j] = (dp[i - 1][j] > dp[i][j - 1]) ? dp[i - 1][j] : dp[i][j - 1];
            }
        }
    }
    
    /* Calculate space needed for LCS */
    size_t lcs_char_count = dp[m][n];
    size_t lcs_byte_size = 0;
    
    /* Backtrack to calculate byte size */
    size_t i = m, j = n;
    size_t *indices = malloc(lcs_char_count * sizeof(size_t));
    size_t idx = lcs_char_count;
    
    while (i > 0 && j > 0) {
        if (utf8_chars_equal(a_chars[i-1], a_lens[i-1], b_chars[j-1], b_lens[j-1])) {
            indices[--idx] = i - 1;
            lcs_byte_size += a_lens[i - 1];
            i--;
            j--;
        } else if (dp[i - 1][j] > dp[i][j - 1]) {
            i--;
        } else {
            j--;
        }
    }
    
    /* Build result string */
    char *lcs = malloc(lcs_byte_size + 1);
    if (!lcs) {
        free(indices);
        for (size_t k = 0; k <= m; k++) free(dp[k]);
        free(dp);
        free(a_chars); free(a_lens); free(b_chars); free(b_lens);
        return NULL;
    }
    
    char *dest = lcs;
    for (size_t k = 0; k < lcs_char_count; k++) {
        size_t char_idx = indices[k];
        memcpy(dest, a_chars[char_idx], a_lens[char_idx]);
        dest += a_lens[char_idx];
    }
    *dest = '\0';
    
    /* Clean up */
    free(indices);
    for (size_t k = 0; k <= m; k++) free(dp[k]);
    free(dp);
    free(a_chars); free(a_lens); free(b_chars); free(b_lens);
    
    return lcs;
}

/* MARK: - Similarity Score */

/**
 * Calculates similarity score based on algorithm selection
 * For strings <= 64 chars: Uses Levenshtein distance
 * For longer strings: Uses Dice coefficient
 */
double repo_similarity_score(const char *a, const char *b) {
    if (!a || !b) return 0.0;
    if (strcmp(a, b) == 0) return 1.0;
    
    size_t len_a = strlen(a);
    size_t len_b = strlen(b);
    
    /* Use Dice coefficient for long strings */
    if (len_a > 64 || len_b > 64) {
        return repo_dice_coefficient(a, b);
    }
    
    /* Use Levenshtein for shorter strings */
    size_t max_len = (len_a > len_b) ? len_a : len_b;
    if (max_len == 0) return 1.0;
    
    /* Calculate with reasonable cap for 85% similarity */
    int max_allowed_dist = (int)ceil(max_len * 0.15);
    int dist = repo_levenshtein_distance(a, b, max_allowed_dist);
    
    /* If distance exceeds cap, fall back to Dice */
    if (dist > max_allowed_dist) {
        return repo_dice_coefficient(a, b);
    }
    
    return 1.0 - (double)dist / (double)max_len;
}

/* MARK: - Indentation Encoding/Decoding */

/**
 * Encodes indentation as <sN> or <tN> format
 * type: 's' for spaces, 't' for tabs
 * Returns dynamically allocated string that must be freed by caller
 */
char* repo_encode_indentation(const char *line, char type) {
    if (!line) return NULL;
    
    size_t effective_spaces = 0;
    const char *p = line;
    
    /* Count leading whitespace only, converting tabs to spaces */
    while (*p && (*p == ' ' || *p == '\t')) {
        if (*p == '\t') {
            effective_spaces += 4; /* Each tab counts as 4 spaces */
        } else {
            effective_spaces++;
        }
        p++;
    }
    
    /* Find start of actual content (first non-whitespace) */
    const char *content_start = p;
    
    /* Find end of content (trim trailing whitespace) */
    const char *content_end = p + strlen(p);
    while (content_end > content_start && isspace((unsigned char)*(content_end - 1))) {
        content_end--;
    }
    
    size_t content_len = content_end - content_start;
    
    /* Build result */
    size_t result_len = 20 + content_len + 1; /* <sNNNNN> + content + null */
    char *result = malloc(result_len);
    if (!result) return NULL;
    
    if (content_len == 0) {
        /* Empty line or whitespace only */
        snprintf(result, result_len, "<%c%zu>", type, effective_spaces);
    } else {
        /* Format tag and append content */
        int tag_len = snprintf(result, result_len, "<%c%zu>", type, effective_spaces);
        memcpy(result + tag_len, content_start, content_len);
        result[tag_len + content_len] = '\0';
    }
    
    return result;
}

/**
 * Decodes indentation from <sN> or <tN> format
 * Returns dynamically allocated string that must be freed by caller
 */
char* repo_decode_indentation(const char *encoded) {
    if (!encoded) return NULL;

    /* Must start with '<' or we just return a copy */
    if (encoded[0] != '<') {
        return strdup(encoded);
    }

    /* Find closing '>' */
    const char *close = strchr(encoded, '>');
    if (!close) {
        return strdup(encoded);
    }

    /* Minimal valid tag: "<s0>" needs at least 3 chars before '>' */
    if (close - encoded < 3) {
        return strdup(encoded);
    }

    char type = encoded[1];
    if (type != 's' && type != 't') {
        return strdup(encoded);
    }

    /* Extract the substring containing the count */
    size_t count_len = (size_t)(close - encoded - 2);          /* bytes between type and '>' */
    if (count_len == 0 || count_len >= 20) {                   /* empty or unreasonably long */
        return strdup(encoded);
    }

    char count_str[21];
    memcpy(count_str, encoded + 2, count_len);
    count_str[count_len] = '\0';

    /* Ensure the count is strictly numeric (reject "-", "+", letters, etc.) */
    for (size_t i = 0; i < count_len; i++) {
        if (!isdigit((unsigned char)count_str[i])) {
            return strdup(encoded);
        }
    }

    /* Parse count and validate range */
    errno = 0;
    char *endptr = NULL;
    unsigned long count_ul = strtoul(count_str, &endptr, 10);
    if (errno != 0 || endptr == NULL || *endptr != '\0') {
        return strdup(encoded);
    }

    /* Impose a hard upper limit to avoid absurd allocations */
    const unsigned long MAX_INDENT = 1000000UL;
    if (count_ul > MAX_INDENT) {
        return strdup(encoded);
    }

    size_t indent_len = (size_t)count_ul;
    const char *content = close + 1;
    size_t content_len = strlen(content);

    /* Prevent size_t overflow in allocation */
    if (indent_len > SIZE_MAX - content_len - 1) {
        return strdup(encoded);
    }

    size_t total_len = indent_len + content_len;
    char *result = malloc(total_len + 1);
    if (!result) {
        return NULL;
    }

    /* Fill indentation */
    if (indent_len > 0) {
        memset(result, (type == 't') ? '\t' : ' ', indent_len);
    }

    /* Copy content (may be empty) */
    memcpy(result + indent_len, content, content_len);
    result[total_len] = '\0';

    return result;
}

/* MARK: - HTML Entity Decoding */

/**
 * Decodes common HTML entities
 * Returns dynamically allocated string that must be freed by caller
 */
char* repo_decode_html_entities(const char *html) {
    if (!html) return NULL;
    
    /* Common entities and their replacements */
    struct {
        const char *entity;
        const char *replacement;
    } entities[] = {
        {"&lt;", "<"},
        {"&gt;", ">"},
        {"&amp;", "&"},
        {"&quot;", "\""},
        {"&#39;", "'"},
        {"&nbsp;", " "},
        {"&#160;", " "},
        {NULL, NULL}
    };
    
    /* First pass: count total length needed */
    size_t result_len = 0;
    const char *p = html;
    
    while (*p) {
        bool found = false;
        for (int i = 0; entities[i].entity; i++) {
            size_t entity_len = strlen(entities[i].entity);
            if (strncmp(p, entities[i].entity, entity_len) == 0) {
                result_len += strlen(entities[i].replacement);
                p += entity_len;
                found = true;
                break;
            }
        }
        if (!found) {
            result_len++;
            p++;
        }
    }
    
    /* Allocate result */
    char *result = malloc(result_len + 1);
    if (!result) return NULL;
    
    /* Second pass: build result */
    p = html;
    char *out = result;
    
    while (*p) {
        bool found = false;
        for (int i = 0; entities[i].entity; i++) {
            size_t entity_len = strlen(entities[i].entity);
            if (strncmp(p, entities[i].entity, entity_len) == 0) {
                strcpy(out, entities[i].replacement);
                out += strlen(entities[i].replacement);
                p += entity_len;
                found = true;
                break;
            }
        }
        if (!found) {
            *out++ = *p++;
        }
    }
    
    *out = '\0';
    return result;
}

/* MARK: - Whitespace Condensing */

/**
 * Condenses all whitespace runs to single spaces
 * Returns dynamically allocated string that must be freed by caller
 */
char* repo_condense_whitespace(const char *str) {
    if (!str) return NULL;
    
    size_t len = strlen(str);
    char *result = malloc(len + 1);
    if (!result) return NULL;
    
    size_t out_idx = 0;
    bool was_whitespace = false;
    const unsigned char *p = (const unsigned char *)str;
    
    while (*p) {
        bool is_whitespace = false;
        
        /* Check for regular whitespace */
        if (isspace(*p)) {
            is_whitespace = true;
        }
        /* Check for UTF-8 encoded NBSP (0xC2 0xA0) */
        else if (*p == 0xC2 && *(p + 1) == 0xA0) {
            is_whitespace = true;
            p++; /* Skip the second byte */
        }
        
        if (is_whitespace) {
            if (!was_whitespace) {
                result[out_idx++] = ' ';
                was_whitespace = true;
            }
        } else {
            result[out_idx++] = *p;
            was_whitespace = false;
        }
        p++;
    }
    
    result[out_idx] = '\0';
    
    /* Shrink to actual size */
    char *final = realloc(result, out_idx + 1);
    return final ? final : result;
}

/* MARK: - FNV-1a Hash */

/**
 * 64-bit FNV-1a hash function
 */
uint64_t repo_fnv1a64(const char *str) {
    if (!str) return 0;
    
    uint64_t hash = 0xcbf29ce484222325ULL;
    const uint64_t prime = 0x100000001b3ULL;
    
    const unsigned char *p = (const unsigned char *)str;
    while (*p) {
        hash ^= *p++;
        hash *= prime;
    }
    
    return hash;
}

/* MARK: - String escaping / unescaping */
/**
 * Escapes backslash, quote, newline, carriage return and tab.
 * The caller must free() the returned buffer.
 */
char* repo_escape_string(const char *src) {
    if (!src) return NULL;
    
    size_t len = strlen(src);
    /* Worst-case every byte becomes 2 (e.g. \n -> \\n) */
    size_t cap = len * 2 + 1;
    char *out = malloc(cap);
    if (!out) return NULL;
    
    const unsigned char *p = (const unsigned char *)src;
    char *dst = out;
    
    while (*p) {
        switch (*p) {
            case '\\':
                *dst++ = '\\'; *dst++ = '\\';
                break;
            case '\"':
                *dst++ = '\\'; *dst++ = '\"';
                break;
            case '\n':
                *dst++ = '\\'; *dst++ = 'n';
                break;
            case '\r':
                *dst++ = '\\'; *dst++ = 'r';
                break;
            case '\t':
                *dst++ = '\\'; *dst++ = 't';
                break;
            default:
                *dst++ = *p;
                break;
        }
        p++;
    }
    *dst = '\0';
    return out;
}

/* MARK: - Split content preserving line endings */

/**
 * Splits content by line endings while preserving the line content.
 * Detects the line ending type used in the content.
 * The caller must call repo_free_split_result() when done.
 */
struct repo_split_result* repo_split_content_preserving_endings(const char *content) {
    if (!content) return NULL;
    
    struct repo_split_result *result = malloc(sizeof(struct repo_split_result));
    if (!result) return NULL;
    
    /* Initial capacity for lines array */
    size_t capacity = 16;
    result->lines = malloc(capacity * sizeof(char*));
    if (!result->lines) {
        free(result);
        return NULL;
    }
    result->line_count = 0;
    result->detected_ending = NULL;
    
    /* Count occurrences of each line ending type */
    size_t unix_count   = 0;  /* \n   */
    size_t windows_count= 0;  /* \r\n */
    size_t mac_count    = 0;  /* \r   */
    int    last_end     = 0;  /* 1 = \r\n, 2 = \r, 3 = \n               */
    
    const char *line_start = content;
    const char *p = content;
    
    while (*p) {
        /* Check for line endings */
        if (*p == '\r') {
            /* Check for \r\n (Windows) */
            if (*(p + 1) == '\n') {
                windows_count++;
                last_end = 1;
                
                /* Extract line */
                size_t line_len = p - line_start;
                char *line = malloc(line_len + 1);
                if (!line) goto error;
                memcpy(line, line_start, line_len);
                line[line_len] = '\0';
                
                /* Add to array */
                if (result->line_count >= capacity) {
                    capacity *= 2;
                    char **new_lines = realloc(result->lines, capacity * sizeof(char*));
                    if (!new_lines) {
                        free(line);
                        goto error;
                    }
                    result->lines = new_lines;
                }
                result->lines[result->line_count++] = line;
                
                p += 2; /* Skip \r\n */
                line_start = p;
                continue;
            } else {
                /* Mac-style ending (just \r) */
                mac_count++;
                last_end = 2;
                
                /* Extract line */
                size_t line_len = p - line_start;
                char *line = malloc(line_len + 1);
                if (!line) goto error;
                memcpy(line, line_start, line_len);
                line[line_len] = '\0';
                
                /* Add to array */
                if (result->line_count >= capacity) {
                    capacity *= 2;
                    char **new_lines = realloc(result->lines, capacity * sizeof(char*));
                    if (!new_lines) {
                        free(line);
                        goto error;
                    }
                    result->lines = new_lines;
                }
                result->lines[result->line_count++] = line;
                
                p++;
                line_start = p;
                continue;
            }
        } else if (*p == '\n') {
            /* Unix-style ending */
            unix_count++;
            last_end = 3;
            
            /* Extract line */
            size_t line_len = p - line_start;
            char *line = malloc(line_len + 1);
            if (!line) goto error;
            memcpy(line, line_start, line_len);
            line[line_len] = '\0';
            
            /* Add to array */
            if (result->line_count >= capacity) {
                capacity *= 2;
                char **new_lines = realloc(result->lines, capacity * sizeof(char*));
                if (!new_lines) {
                    free(line);
                    goto error;
                }
                result->lines = new_lines;
            }
            result->lines[result->line_count++] = line;
            
            p++;
            line_start = p;
            continue;
        }
        p++;
    }
    
    /* Handle the last line if there's content after the last line ending */
    if (line_start < p) {
        size_t line_len = p - line_start;
        char *line = malloc(line_len + 1);
        if (!line) goto error;
        memcpy(line, line_start, line_len);
        line[line_len] = '\0';
        
        /* Add to array */
        if (result->line_count >= capacity) {
            capacity *= 2;
            char **new_lines = realloc(result->lines, capacity * sizeof(char*));
            if (!new_lines) {
                free(line);
                goto error;
            }
            result->lines = new_lines;
        }
        result->lines[result->line_count++] = line;
    }
    
    /* Determine the line ending to report */
    if (windows_count > unix_count && windows_count > mac_count) {
        result->detected_ending = strdup("\r\n");
    } else if (mac_count > unix_count && mac_count > windows_count) {
        result->detected_ending = strdup("\r");
    } else if (unix_count > windows_count && unix_count > mac_count) {
        result->detected_ending = strdup("\n");
    } else {
        /* Counts are tied – use the last one we saw, default to '\n' */
        switch (last_end) {
            case 1:  result->detected_ending = strdup("\r\n"); break;
            case 2:  result->detected_ending = strdup("\r");   break;
            case 3:  result->detected_ending = strdup("\n");   break;
            default: result->detected_ending = strdup("\n");   break;
        }
    }
    
    return result;
    
error:
    /* Clean up on error */
    for (size_t i = 0; i < result->line_count; i++) {
        free(result->lines[i]);
    }
    free(result->lines);
    free(result->detected_ending);
    free(result);
    return NULL;
}

/**
 * Frees the memory allocated by repo_split_content_preserving_endings
 */
void repo_free_split_result(struct repo_split_result *result) {
    if (!result) return;
    
    for (size_t i = 0; i < result->line_count; i++) {
        free(result->lines[i]);
    }
    free(result->lines);
    free(result->detected_ending);
    free(result);
}

/**
 * Splits content by line endings, preserving both line content and endings.
 * Returns array of (line, ending) pairs matching Swift's splitContentPreservingAllLineEndings
 */
struct repo_split_with_endings_result* repo_split_content_preserving_all_endings(const char *content) {
    if (!content) return NULL;
    
    struct repo_split_with_endings_result *result = malloc(sizeof(struct repo_split_with_endings_result));
    if (!result) return NULL;
    
    /* Initial capacity */
    size_t capacity = 16;
    result->pairs = malloc(capacity * sizeof(struct repo_line_ending_pair));
    if (!result->pairs) {
        free(result);
        return NULL;
    }
    result->count = 0;
    
    const char *line_start = content;
    const char *p = content;
    
    while (*p) {
        /* Check for line endings */
        if (*p == '\r') {
            /* Ensure we have space */
            if (result->count >= capacity) {
                capacity *= 2;
                struct repo_line_ending_pair *new_pairs = realloc(result->pairs, 
                                                                  capacity * sizeof(struct repo_line_ending_pair));
                if (!new_pairs) goto error;
                result->pairs = new_pairs;
            }
            
            /* Extract line */
            size_t line_len = p - line_start;
            char *line = malloc(line_len + 1);
            if (!line) goto error;
            memcpy(line, line_start, line_len);
            line[line_len] = '\0';
            
            /* Check for \r\n (Windows) */
            char *ending;
            if (*(p + 1) == '\n') {
                ending = strdup("\r\n");
                p += 2;
            } else {
                /* Mac-style ending (just \r) */
                ending = strdup("\r");
                p += 1;
            }
            if (!ending) {
                free(line);
                goto error;
            }
            
            result->pairs[result->count].line = line;
            result->pairs[result->count].ending = ending;
            result->count++;
            
            line_start = p;
		} else if (*p == '\n') {
            /* Unix-style ending */
            if (result->count >= capacity) {
                capacity *= 2;
                struct repo_line_ending_pair *new_pairs = realloc(result->pairs, 
                                                                  capacity * sizeof(struct repo_line_ending_pair));
                if (!new_pairs) goto error;
                result->pairs = new_pairs;
            }
            
            /* Extract line */
            size_t line_len = p - line_start;
            char *line = malloc(line_len + 1);
            if (!line) goto error;
            memcpy(line, line_start, line_len);
            line[line_len] = '\0';
            
            char *ending = strdup("\n");
            if (!ending) {
                free(line);
                goto error;
            }
            
            result->pairs[result->count].line = line;
            result->pairs[result->count].ending = ending;
            result->count++;
            
            p++;
            line_start = p;
        } else {
            p++;
        }
    }
    
    /* Handle the last line if there's no trailing line ending */
    if (line_start < p) {
        if (result->count >= capacity) {
            capacity += 1;
            struct repo_line_ending_pair *new_pairs = realloc(result->pairs, 
                                                              capacity * sizeof(struct repo_line_ending_pair));
            if (!new_pairs) goto error;
            result->pairs = new_pairs;
        }
        
        size_t line_len = p - line_start;
        char *line = malloc(line_len + 1);
        if (!line) goto error;
        memcpy(line, line_start, line_len);
        line[line_len] = '\0';
        
        char *ending = strdup("");
        if (!ending) {
            free(line);
            goto error;
        }
        
        result->pairs[result->count].line = line;
        result->pairs[result->count].ending = ending;
        result->count++;
    }
    
    return result;

error:
    /* Clean up on error */
    for (size_t i = 0; i < result->count; i++) {
        free(result->pairs[i].line);
        free(result->pairs[i].ending);
    }
    free(result->pairs);
    free(result);
    return NULL;
}

/**
 * Frees the memory allocated by repo_split_content_preserving_all_endings
 */
void repo_free_split_with_endings_result(struct repo_split_with_endings_result *result) {
    if (!result) return;
    
    for (size_t i = 0; i < result->count; i++) {
        free(result->pairs[i].line);
        free(result->pairs[i].ending);
    }
    free(result->pairs);
    free(result);
}

/**
 * Reverses repo_escape_string().
 * Converts sequences like \\n to newline, \\\" to quote, etc.
 * The caller must free() the returned buffer.
 */
char* repo_unescape_string(const char *src) {
    if (!src) return NULL;
    
    size_t len = strlen(src);
    /* Result cannot be longer than input */
    char *out = malloc(len + 1);
    if (!out) return NULL;
    
    const unsigned char *p = (const unsigned char *)src;
    char *dst = out;
    
    while (*p) {
        if (*p == '\\') {
            p++;
            switch (*p) {
                case 'n': *dst++ = '\n'; break;
                case 'r': *dst++ = '\r'; break;
                case 't': *dst++ = '\t'; break;
                case '\\': *dst++ = '\\'; break;
                case '\"': *dst++ = '\"'; break;
                case '\0': /* Trailing backslash – copy as-is */
                           *dst++ = '\\'; p--; break;
                default:   /* Unknown escape – keep both bytes */
                           *dst++ = '\\'; *dst++ = *p; break;
            }
            if (*p) p++; /* Advance past escape code if not end */
        } else {
            *dst++ = *p++;
        }
    }
    *dst = '\0';
    return out;
}

/* MARK: - Fuzzy Space Matching */

/* Helper macros for fuzzy space matching */
#define IS_NBSP(p) ((p)[0] == 0xC2 && (p)[1] == 0xA0)
#define IS_EM_SPACE(p) ((p)[0] == 0xE2 && (p)[1] == 0x80 && (p)[2] == 0x83)
#define IS_ANY_WS(p) (IS_NBSP(p) || IS_EM_SPACE(p) || isspace(*(p)))
#define IS_ASCII_WS(p) (isspace(*(p)))

static void bump_ws(const unsigned char **pp) {
    if (IS_NBSP(*pp)) {
        *pp += 2;
    } else if (IS_EM_SPACE(*pp)) {
        *pp += 3;
    } else {
        (*pp)++;
    }
}

static int only_ws(const unsigned char *p) {
    int seen = 0;
    while (*p) {
        if (!IS_ANY_WS(p)) return 0;
        bump_ws(&p);
        seen = 1;
    }
    return seen;
}

int repo_fuzzy_space_match(const char *pattern, const char *text, int case_insensitive) {
    if (!pattern || !text) return 0;

	/* Empty pattern: match empty text only when case_insensitive != 0 */
	if (*pattern == '\0') {
		return (*text == '\0' && case_insensitive) ? 1 : 0;
	}

    const unsigned char *p = (const unsigned char *)pattern;
    const unsigned char *t = (const unsigned char *)text;

    /* Pattern is whitespace-only special-case */
    if (only_ws(p)) {
        return (*t && only_ws(t)) ? 1 : 0;
    }

    /* Main matching loop */
    while (*p && *t) {
        /* PATTERN ASCII SPACE (0x20) */
        if (*p == ' ') {
            if (!IS_ASCII_WS(t)) return 0;          /* need ≥1 ASCII ws   */
            while (IS_ASCII_WS(t))   t++;           /* consume text run   */
            while (*p == ' ')        p++;           /* consume pattern    */
            continue;
        }

        /* PATTERN NBSP or EM-SPACE */
        if (IS_NBSP(p) || IS_EM_SPACE(p)) {
            if (!IS_ANY_WS(t)) return 0;            /* need ≥1 any ws     */
            while (IS_ANY_WS(t)) bump_ws(&t);       /* text run           */
            /* consume consecutive whitespace in pattern (space/NBSP/EM)  */
            while (*p == ' ' || IS_NBSP(p) || IS_EM_SPACE(p)) bump_ws(&p);
            continue;
        }

        /* Exact TAB / LF / CR etc. */
        if (isspace(*p)) {
            if (*p != *t) return 0;
            p++; t++;
            continue;
        }

        /* Regular character comparison */
        unsigned char pc = case_insensitive ? (unsigned char)tolower(*p) : *p;
        unsigned char tc = case_insensitive ? (unsigned char)tolower(*t) : *t;
        if (pc != tc) return 0;
        p++; t++;
    }

    /* Skip any trailing wildcard whitespace in pattern */
    while (*p == ' ' || IS_NBSP(p) || IS_EM_SPACE(p)) bump_ws(&p);

    /* Allow trailing whitespace in text to be swallowed */
    while (IS_ANY_WS(t)) bump_ws(&t);

    return (*p == '\0' && *t == '\0') ? 1 : 0;
}

#undef IS_NBSP
#undef IS_EM_SPACE
#undef IS_ANY_WS
#undef IS_ASCII_WS

/* MARK: - Canonical Key Generation */

/**
 * Collapses runs of separator characters to a single dash
 * Handles: - _ – — ─ ━ ═
 */
static void collapse_separator_runs(char *str) {
    if (!str || !*str) return;
    
    char *read = str;
    char *write = str;
    bool in_separator = false;
    
    while (*read) {
        bool is_separator = false;
        
        /* Check ASCII separators */
        if (*read == '-' || *read == '_') {
            is_separator = true;
        }
        /* Check UTF-8 separators */
        else if ((unsigned char)*read == 0xE2) {
            /* EN DASH (U+2013): E2 80 93 */
            if ((unsigned char)*(read + 1) == 0x80 && (unsigned char)*(read + 2) == 0x93) {
                is_separator = true;
                read += 2; /* Will be incremented again at loop end */
            }
            /* EM DASH (U+2014): E2 80 94 */
            else if ((unsigned char)*(read + 1) == 0x80 && (unsigned char)*(read + 2) == 0x94) {
                is_separator = true;
                read += 2;
            }
            /* BOX DRAWING chars (U+2500-U+2550 range) */
            else if ((unsigned char)*(read + 1) == 0x94 || (unsigned char)*(read + 1) == 0x95) {
                is_separator = true;
                read += 2;
            }
        }
        
        if (is_separator) {
            if (!in_separator) {
                *write++ = '-';
                in_separator = true;
            }
        } else {
            *write++ = *read;
            in_separator = false;
        }
        read++;
    }
    *write = '\0';
}

/**
 * Generates a canonical key for string comparison in diff generation
 * Applies normalization pipeline: HTML decode, lowercase, whitespace collapse,
 * qualifier stripping, separator collapse, length capping, delimiter stripping
 * Returns dynamically allocated string that must be freed by caller, or NULL if empty
 */
char* repo_canonical_key(const char *raw) {
    if (!raw) return NULL;
    
    /* Step 1: Decode HTML entities */
    char *decoded = repo_decode_html_entities(raw);
    if (!decoded) return NULL;
    
    /* Step 2: Lowercase only - NBSP will be handled by condense_whitespace */
    char *p = decoded;
    while (*p) {
        *p = tolower((unsigned char)*p);
        p++;
    }
    
    /* Step 3: Condense whitespace and trim */
    char *condensed = repo_condense_whitespace(decoded);
    free(decoded);
    if (!condensed) return NULL;
    
    /* Trim leading whitespace */
    char *start = condensed;
    while (*start && isspace((unsigned char)*start)) start++;
    
    if (*start == '\0') {
        free(condensed);
        return NULL;
    }
    
    /* Trim trailing whitespace */
    size_t len = strlen(start);
    while (len > 0 && isspace((unsigned char)start[len - 1])) len--;
    
    /* Allocate result buffer */
    char *result = malloc(len + 1);
    if (!result) {
        free(condensed);
        return NULL;
    }
    memcpy(result, start, len);
    result[len] = '\0';
    free(condensed);
    
    /* Step 4: Strip leading qualifiers (can be multiple) */
    const char *qualifiers[] = {
        "public ", "private ", "internal ", "fileprivate ",
        "open ", "final ", "static ", "class ", "override ",
        "mutating ", "async ", "throws ", "lazy ", NULL
    };
    
    bool stripped = true;
    while (stripped) {
        stripped = false;
        for (int i = 0; qualifiers[i]; i++) {
            size_t qlen = strlen(qualifiers[i]);
            if (strlen(result) > qlen && strncmp(result, qualifiers[i], qlen) == 0) {
                memmove(result, result + qlen, strlen(result + qlen) + 1);
                stripped = true;
                break;
            }
        }
    }
    
    /* Step 5: Collapse separator runs */
    collapse_separator_runs(result);
    
    /* Step 6: Cap to 150 chars */
    if (strlen(result) > 150) {
        result[150] = '\0';
    }
    
    /* Step 7: Strip trailing delimiters */
    const char *delimiters[] = { "->", "=>", ":=", "=", ":", NULL };
    len = strlen(result);
    
    for (int i = 0; delimiters[i]; i++) {
        size_t dlen = strlen(delimiters[i]);
        if (len >= dlen && strcmp(result + len - dlen, delimiters[i]) == 0) {
            result[len - dlen] = '\0';
            /* Trim trailing whitespace after removing delimiter */
            len = len - dlen;
            while (len > 0 && isspace((unsigned char)result[len - 1])) {
                result[--len] = '\0';
            }
            break;
        }
    }
    
    /* Return NULL if empty after all processing */
    if (*result == '\0') {
        free(result);
        return NULL;
    }
    
    return result;
}

/* MARK: - Bulk Dice Coefficient */

/**
 * Finds the best dice coefficient match for a pattern among multiple candidates
 * Returns the index of the best match, or -1 if no match exceeds threshold
 */
int repo_bulk_dice_best_match(const char *pattern, const char **candidates, 
                             size_t count, double threshold, double *best_score) {
    if (!pattern || !candidates || count == 0) return -1;
    
    int best_idx = -1;
    double best = 0.0;
    
    for (size_t i = 0; i < count; i++) {
        if (!candidates[i]) continue;
        
        double score = repo_dice_coefficient(pattern, candidates[i]);
        if (score > best && score >= threshold) {
            best = score;
            best_idx = (int)i;
        }
    }
    
    if (best_score) *best_score = best;
    return best_idx;
}

/* ─────────────────────────────────────────────────────────────────────────────
 * Chat Content Parser Utilities
 * ───────────────────────────────────────────────────────────────────────────── */

/**
 * Removes outer triple-backtick fences if present (with or without language spec).
 * Also handles partial code blocks by removing opening backticks when no closing exist.
 * 
 * @param dest Output buffer for the result
 * @param src Input string
 * @param dest_size Size of the destination buffer
 * @return true if successful, false if buffer too small
 */
bool repo_remove_outer_backticks(char *dest, const char *src, size_t dest_size) {
    if (!dest || !src || dest_size == 0) return false;
    
    /* Trim whitespace from start and end */
    const char *start = src;
    const char *end = src + strlen(src) - 1;
    
    /* Skip leading whitespace */
    while (*start && isspace((unsigned char)*start)) start++;
    
    /* Skip trailing whitespace */
    while (end > start && isspace((unsigned char)*end)) end--;
    
    size_t trimmed_len = (end - start) + 1;
    
    /* Check if starts with ``` */
    if (trimmed_len >= 3 && strncmp(start, "```", 3) == 0) {
        const char *content_start = start + 3;
        
        /* Skip language identifier if present */
        while (content_start <= end && *content_start != '\n' && *content_start != '\r') {
            content_start++;
        }
        
        /* Skip the newline */
        if (content_start <= end && (*content_start == '\r' || *content_start == '\n')) {
            content_start++;
            if (content_start <= end && *content_start == '\n' && *(content_start - 1) == '\r') {
                content_start++;
            }
        }
        
        /* Check if ends with ``` */
        if (trimmed_len >= 6 && end >= start + 5 && strncmp(end - 2, "```", 3) == 0) {
            /* Has both opening and closing backticks */
            const char *content_end = end - 3;
            
            /* Remove trailing newline before closing ``` if present */
            if (content_end > content_start && *content_end == '\n') {
                content_end--;
                if (content_end > content_start && *content_end == '\r') {
                    content_end--;
                }
            }
            
            /* Calculate content length */
            size_t content_len = content_end - content_start + 1;
            if (content_len + 1 > dest_size) return false;
            
            if (content_len > 0 && content_start <= content_end) {
                memcpy(dest, content_start, content_len);
                dest[content_len] = '\0';
            } else {
                dest[0] = '\0';
            }
            return true;
        } else {
            /* Only has opening backticks - return content after them */
            size_t content_len = (end - content_start) + 1;
            if (content_len + 1 > dest_size) return false;
            
            if (content_len > 0 && content_start <= end) {
                memcpy(dest, content_start, content_len);
                dest[content_len] = '\0';
            } else {
                dest[0] = '\0';
            }
            return true;
        }
    }
    
    /* No backticks - return trimmed content */
    if (trimmed_len + 1 > dest_size) return false;
    if (trimmed_len > 0 && start <= end) {
        memcpy(dest, start, trimmed_len);
        dest[trimmed_len] = '\0';
    } else {
        dest[0] = '\0';
    }
    return true;
}

/**
 * Trims common leading whitespace from an array of lines
 * Note: This modifies the strings in-place. The lines array should contain
 * modifiable strings (e.g., allocated with strdup).
 * 
 * @param lines Array of strings to trim
 * @param line_count Number of lines in the array
 * @return true if successful
 */
bool repo_trim_leading_whitespace(char **lines, size_t line_count) {
    if (!lines || line_count == 0) return false;
    
    /* First pass: decode indentation and find minimum whitespace */
    size_t min_whitespace = SIZE_MAX;
    
    for (size_t i = 0; i < line_count; i++) {
        if (!lines[i]) continue;
        
        /* Decode indentation */
        char *decoded = repo_decode_indentation(lines[i]);
        if (!decoded) continue;
        
        /* Count leading whitespace for non-empty lines */
        size_t ws_count = 0;
        const char *p = decoded;
        
        /* Skip leading whitespace and count */
        while (*p && isspace((unsigned char)*p)) {
            ws_count++;
            p++;
        }
        
        /* If line has non-whitespace content, update minimum */
        if (*p != '\0') {
            if (ws_count < min_whitespace) {
                min_whitespace = ws_count;
            }
        }
        
        /* Replace original with decoded */
        free(lines[i]);
        lines[i] = decoded;
    }
    
    /* If no content lines found, nothing to trim */
    if (min_whitespace == SIZE_MAX) {
        min_whitespace = 0;
    }
    
    /* Second pass: remove common leading whitespace */
    for (size_t i = 0; i < line_count; i++) {
        if (!lines[i]) continue;
        
        size_t len = strlen(lines[i]);
        if (min_whitespace >= len) {
            /* Line is all whitespace or shorter than min - becomes empty */
            lines[i][0] = '\0';
        } else if (min_whitespace > 0) {
            /* Shift content left */
            memmove(lines[i], lines[i] + min_whitespace, len - min_whitespace + 1);
        }
    }
    
    return true;
}

/**
 * Decodes HTML entities, normalizes indentation to spaces, trims common leading
 * whitespace across non-empty lines, and preserves detected line endings.
 * Returns a malloc()'d buffer the caller must free(), or NULL on failure.
 */
char* repo_trim_common_leading_whitespace_preserving_endings(const char *content) {
    if (!content) return NULL;
    if (*content == '\0') return strdup("");
    
    struct repo_split_result *split = repo_split_content_preserving_endings(content);
    if (!split) return NULL;
    
    for (size_t i = 0; i < split->line_count; i++) {
        char *line = split->lines[i];
        if (!line) continue;
        
        char *decoded = repo_decode_html_entities(line);
        const char *source = decoded ? decoded : line;
        
        char *encoded = repo_encode_indentation(source, 's');
        if (decoded) free(decoded);
        
        if (encoded) {
            free(line);
            split->lines[i] = encoded;
        }
    }
    
    if (!repo_trim_leading_whitespace(split->lines, split->line_count)) {
        repo_free_split_result(split);
        return strdup(content);
    }
    
    const char *ending = split->detected_ending ? split->detected_ending : "\n";
    size_t ending_len = strlen(ending);
    
    size_t total_len = 0;
    for (size_t i = 0; i < split->line_count; i++) {
        size_t line_len = split->lines[i] ? strlen(split->lines[i]) : 0;
        if (line_len > SIZE_MAX - total_len) {
            repo_free_split_result(split);
            return NULL;
        }
        total_len += line_len;
        if (i + 1 < split->line_count) {
            if (ending_len > SIZE_MAX - total_len) {
                repo_free_split_result(split);
                return NULL;
            }
            total_len += ending_len;
        }
    }
    
    char *result = malloc(total_len + 1);
    if (!result) {
        repo_free_split_result(split);
        return NULL;
    }
    
    char *p = result;
    for (size_t i = 0; i < split->line_count; i++) {
        if (split->lines[i]) {
            size_t line_len = strlen(split->lines[i]);
            memcpy(p, split->lines[i], line_len);
            p += line_len;
        }
        if (i + 1 < split->line_count && ending_len > 0) {
            memcpy(p, ending, ending_len);
            p += ending_len;
        }
    }
    *p = '\0';
    
    repo_free_split_result(split);
    return result;
}

/**
 * Extracts description content from XML-like tags
 * Looks for <description>content</description> and extracts the content
 * 
 * @param dest Output buffer for the extracted description
 * @param src Input string containing the description tag
 * @param dest_size Size of the destination buffer
 * @return true if description found and extracted, false otherwise
 */
bool repo_extract_description(char *dest, const char *src, size_t dest_size) {
    if (!dest || !src || dest_size == 0) return false;
    
    dest[0] = '\0';  /* Initialize to empty string */
    
    /* Find <description> tag */
    const char *start_tag = strstr(src, "<description>");
    if (!start_tag) return true;  /* No tag found, return empty string */
    
    /* Find content start */
    const char *content_start = start_tag + 13;  /* strlen("<description>") */
    
    /* Find </description> tag */
    const char *end_tag = strstr(content_start, "</description>");
    if (!end_tag) return true;  /* No closing tag, return empty string */
    
    /* Calculate content length */
    size_t content_len = end_tag - content_start;
    if (content_len == 0) return true;  /* Empty description */
    
    /* Check buffer size */
    if (content_len + 1 > dest_size) return false;
    
    /* Copy content */
    memcpy(dest, content_start, content_len);
    dest[content_len] = '\0';
    
    /* Trim whitespace from result */
    char *p = dest;
    char *end = dest + content_len - 1;
    
    /* Trim leading whitespace */
    while (*p && isspace((unsigned char)*p)) p++;
    
    /* Trim trailing whitespace */
    while (end > p && isspace((unsigned char)*end)) end--;
    
    /* Move trimmed content if needed */
    if (p != dest || end < dest + content_len - 1) {
        size_t trimmed_len = (end - p) + 1;
        if (p != dest) {
            memmove(dest, p, trimmed_len);
        }
        dest[trimmed_len] = '\0';
    }
    
    return true;
}

/**
 * Extracts complexity value from XML-like tags
 * Looks for <complexity>number</complexity> and extracts the integer
 * 
 * @param src Input string containing the complexity tag
 * @return The complexity value, or -1 if not found or invalid
 */
int repo_extract_complexity(const char *src) {
    if (!src) return -1;
    
    /* Find <complexity> tag */
    const char *start_tag = strstr(src, "<complexity>");
    if (!start_tag) return -1;
    
    /* Find content start */
    const char *content_start = start_tag + 12;  /* strlen("<complexity>") */
    
    /* Find </complexity> tag */
    const char *end_tag = strstr(content_start, "</complexity>");
    if (!end_tag) return -1;
    
    /* Extract the number string */
    size_t content_len = end_tag - content_start;
    if (content_len == 0) return -1;  /* Empty */
    
    /* Allow more space for content with whitespace */
    if (content_len > 100) return -1;  /* Unreasonably long */
    
    char number_str[101];
    memcpy(number_str, content_start, content_len);
    number_str[content_len] = '\0';
    
    /* Trim whitespace */
    char *p = number_str;
    while (*p && isspace((unsigned char)*p)) p++;
    
    /* If all whitespace, return -1 */
    if (*p == '\0') return -1;
    
    /* Trim trailing whitespace */
    char *end = p + strlen(p) - 1;
    while (end > p && isspace((unsigned char)*end)) end--;
    *(end + 1) = '\0';
    
    /* Parse the number */
    char *endptr;
    errno = 0;
    long value = strtol(p, &endptr, 10);
    
    /* Check for valid conversion */
    if (errno != 0 || *endptr != '\0' || value < 0 || value > INT_MAX) {
        return -1;
    }
    
    return (int)value;
}
