#include "../gba_core.h"
#include <string.h>

MGBA_EXPORT const uint32_t GBASavestateMagic = 0x01000000;
MGBA_EXPORT const uint32_t GBASavestateVersion = 0x0000000A;

mLOG_DEFINE_CATEGORY(GBA_STATE, "GBA Savestate", "gba.serialize");

void GBASerialize(struct GBA* gba, struct GBASerializedState* state) {
	if (!gba || !state) {
		return;
	}

	memset(state, 0, sizeof(*state));
	STORE_32(GBASavestateMagic + GBASavestateVersion, 0, &state->versionMagic);

	GBAMemorySerialize(&gba->memory, state);
	GBAIOSerialize(gba, state);
	GBAVideoSerialize(&gba->video, state);
	GBAAudioSerialize(&gba->audio, state);
	GBASavedataSerialize(&gba->memory.savedata, state);
}

bool GBADeserialize(struct GBA* gba, const struct GBASerializedState* state) {
	if (!gba || !state) {
		return false;
	}

	uint32_t version = 0;
	LOAD_32(version, 0, &state->versionMagic);
	if (version > GBASavestateMagic + GBASavestateVersion) {
		mLOG(GBA_STATE, WARN, "Invalid or too new savestate: expected <= %08X, got %08X", GBASavestateMagic + GBASavestateVersion, version);
		return false;
	}
	if (version < GBASavestateMagic) {
		mLOG(GBA_STATE, WARN, "Invalid savestate: expected >= %08X, got %08X", GBASavestateMagic, version);
		return false;
	}
	if (version < GBASavestateMagic + GBASavestateVersion) {
		mLOG(GBA_STATE, WARN, "Old savestate detected: %08X", version);
	}

	mTimingClear(&gba->timing);
	GBAVideoDeserialize(&gba->video, state);
	GBAMemoryDeserialize(&gba->memory, state);
	GBAIODeserialize(gba, state);
	GBAAudioDeserialize(&gba->audio, state);
	GBASavedataDeserialize(&gba->memory.savedata, state);
	mTimingInterrupt(&gba->timing);
	return true;
}
