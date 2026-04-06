#ifndef AURORA_UTIL_COMMON_H
#define AURORA_UTIL_COMMON_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
#define CXX_GUARD_START extern "C" {
#define CXX_GUARD_END }
#else
#define CXX_GUARD_START
#define CXX_GUARD_END
#endif

#define UNUSED(V) ((void)(V))
#define ATTRIBUTE_UNUSED __attribute__((unused))

#ifndef ATTRIBUTE_NOINLINE
#define ATTRIBUTE_NOINLINE __attribute__((noinline))
#endif
#ifndef UNLIKELY
#define UNLIKELY(x) __builtin_expect(!!(x), 0)
#endif
#ifndef LIKELY
#define LIKELY(x) __builtin_expect(!!(x), 1)
#endif

#define ROR(V, S) (((uint32_t)(V) >> (S)) | ((uint32_t)(V) << (32 - (S))))

#endif
