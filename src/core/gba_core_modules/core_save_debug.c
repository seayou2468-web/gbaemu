#include "../gba_core.h"
#include <stdint.h>
#include <stdbool.h>

/* ===== Imported from reference implementation/serialize.c ===== */

/*
 * Debug/savestate serialization is intentionally removed from the standalone core.
 * The core keeps runtime execution/rendering only.
 */

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

void GBASerializeExtdata(struct GBA* gba, struct mStateExtdata* extdata) {
	UNUSED(gba);
	UNUSED(extdata);
}

void GBADeserializeExtdata(struct GBA* gba, const struct mStateExtdata* extdata) {
	UNUSED(gba);
	UNUSED(extdata);
}
