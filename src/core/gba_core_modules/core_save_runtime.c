#include "../gba_core.h"
#include <string.h>

MGBA_EXPORT const uint32_t GBASavestateMagic = 0x01000000;
MGBA_EXPORT const uint32_t GBASavestateVersion = 0x0000000A;

mLOG_DEFINE_CATEGORY(GBA_STATE, "GBA Savestate", "gba.serialize");

void GBAAudioSerialize(const void* audio, struct GBASerializedState* state) {
	if (!state) {
		return;
	}
	uint32_t signature = 0;
	if (audio) {
		memcpy(&signature, audio, sizeof(signature));
	}
	STORE_32(signature, 0, &state->audio.lastSample);
}

void GBAAudioDeserialize(void* audio, const struct GBASerializedState* state) {
	if (!audio || !state) {
		return;
	}
	uint32_t signature = 0;
	LOAD_32(signature, 0, &state->audio.lastSample);
	memcpy(audio, &signature, sizeof(signature));
}

void GBAHardwareSerialize(const struct GBAHardware* hw, struct GBASerializedState* state) {
	if (!hw || !state) {
		return;
	}
	STORE_32(hw->devices, 0, &state->hardware.devices);
	memcpy(state->hardware.rtcTime, hw->rtc.time, sizeof(state->hardware.rtcTime));
	state->hardware.rtcControl = hw->rtc.control;
	STORE_64LE(hw->rtc.lastLatch, 0, &state->hardware.rtcLastLatch);
	STORE_64LE(hw->rtc.offset, 0, &state->hardware.rtcOffset);
}

void GBAHardwareDeserialize(struct GBAHardware* hw, const struct GBASerializedState* state) {
	if (!hw || !state) {
		return;
	}
	LOAD_32(hw->devices, 0, &state->hardware.devices);
	memcpy(hw->rtc.time, state->hardware.rtcTime, sizeof(hw->rtc.time));
	hw->rtc.control = state->hardware.rtcControl;
	LOAD_64LE(hw->rtc.lastLatch, 0, &state->hardware.rtcLastLatch);
	LOAD_64LE(hw->rtc.offset, 0, &state->hardware.rtcOffset);
}

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
