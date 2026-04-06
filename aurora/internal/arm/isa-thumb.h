
#ifndef ISA_THUMB_H
#define ISA_THUMB_H

#include <aurora-util/common.h>

CXX_GUARD_START

struct ARMCore;

typedef void (*ThumbInstruction)(struct ARMCore*, unsigned opcode);
extern const ThumbInstruction _thumbTable[0x400];

CXX_GUARD_END

#endif
