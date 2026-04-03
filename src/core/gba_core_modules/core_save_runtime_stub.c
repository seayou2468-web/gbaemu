#include "../gba_core.h"
#include <stdint.h>
#include <stdbool.h>

MGBA_EXPORT const uint32_t GBASavestateMagic = 0;
MGBA_EXPORT const uint32_t GBASavestateVersion = 0;

void GBASerialize(struct GBA* gba, struct GBASerializedState* state) {
	UNUSED(gba);
	UNUSED(state);
}

bool GBADeserialize(struct GBA* gba, const struct GBASerializedState* state) {
	UNUSED(gba);
	UNUSED(state);
	return false;
}

