#include "../gba_core.h"
#include <stdint.h>
#include <stdbool.h>

#ifndef GBA_EXPORT
#define GBA_EXPORT
#endif

#ifndef GBA_KEY_MAX
#define GBA_KEY_MAX 10
#define GBA_KEY_RIGHT 4
#define GBA_KEY_LEFT 5
#define GBA_KEY_UP 6
#define GBA_KEY_DOWN 7
#endif

#ifndef GBA_INPUT_PLATFORM_INFO_DEFINED
#define GBA_INPUT_PLATFORM_INFO_DEFINED
struct InputHatBindings {
	int up;
	int left;
	int down;
	int right;
};

struct InputPlatformInfo {
	const char* platformName;
	const char* const* keyId;
	int nKeys;
	struct InputHatBindings hat;
};
#endif

/* Ref transplant: reference implementation/input.c */
GBA_EXPORT const struct InputPlatformInfo GBAInputInfo = {
	.platformName = "gba",
	.keyId = (const char*[]) {
		"A",
		"B",
		"Select",
		"Start",
		"Right",
		"Left",
		"Up",
		"Down",
		"R",
		"L"
	},
	.nKeys = GBA_KEY_MAX,
	.hat = {
		.up = GBA_KEY_UP,
		.left = GBA_KEY_LEFT,
		.down = GBA_KEY_DOWN,
		.right = GBA_KEY_RIGHT
	}
};
