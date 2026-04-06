
#ifndef MACROS_H
#define MACROS_H

#include <aurora-util/common.h>

#define LOAD_64LE(DEST, OFF, BASE) ((DEST) = (*(uint64_t*)((uint8_t*)(BASE) + (OFF))))
#define LOAD_32LE(DEST, OFF, BASE) ((DEST) = (*(uint32_t*)((uint8_t*)(BASE) + (OFF))))
#define LOAD_16LE(DEST, OFF, BASE) ((DEST) = (*(uint16_t*)((uint8_t*)(BASE) + (OFF))))
#define STORE_64LE(SRC, OFF, BASE) ((*(uint64_t*)((uint8_t*)(BASE) + (OFF))) = (uint64_t)(SRC))
#define STORE_32LE(SRC, OFF, BASE) ((*(uint32_t*)((uint8_t*)(BASE) + (OFF))) = (uint32_t)(SRC))
#define STORE_16LE(SRC, OFF, BASE) ((*(uint16_t*)((uint8_t*)(BASE) + (OFF))) = (uint16_t)(SRC))

#define LOAD_64 LOAD_64LE
#define LOAD_32 LOAD_32LE
#define LOAD_16 LOAD_16LE
#define STORE_64 STORE_64LE
#define STORE_32 STORE_32LE
#define STORE_16 STORE_16LE

#endif
