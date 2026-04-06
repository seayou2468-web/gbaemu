
#ifndef M_CPU_H
#define M_CPU_H

#include <aurora-util/common.h>

CXX_GUARD_START

enum mCPUComponentType {
	CPU_COMPONENT_DEBUGGER,
	CPU_COMPONENT_CHEAT_DEVICE,
	CPU_COMPONENT_MISC_1,
	CPU_COMPONENT_MISC_2,
	CPU_COMPONENT_MISC_3,
	CPU_COMPONENT_MISC_4,
	CPU_COMPONENT_MAX
};

enum mMemoryAccessSource {
	mACCESS_UNKNOWN = 0,
	mACCESS_PROGRAM,
	mACCESS_DMA,
	mACCESS_SYSTEM,
	mACCESS_DECOMPRESS,
	mACCESS_COPY,
};

struct mCPUComponent {
	uint32_t id;
	void (*init)(void* cpu, struct mCPUComponent* component);
	void (*deinit)(struct mCPUComponent* component);
};

CXX_GUARD_END

#endif
