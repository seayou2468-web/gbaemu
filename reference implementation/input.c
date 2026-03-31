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