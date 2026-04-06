#ifndef AURORA_UTIL_STRING_H
#define AURORA_UTIL_STRING_H

#include <string.h>
#include <stddef.h>

#ifndef HAVE_STRLCPY
static inline size_t aurora_strlcpy(char* dst, const char* src, size_t size) {
    size_t len = strlen(src);
    if (size) {
        size_t copy = (len >= size) ? size - 1 : len;
        memcpy(dst, src, copy);
        dst[copy] = '\0';
    }
    return len;
}
#define strlcpy aurora_strlcpy
#endif

#endif
