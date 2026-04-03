#include "../gba_core.h"

#if defined(__clang__) || defined(__GNUC__)
#define GBA_WEAK __attribute__((weak))
#else
#define GBA_WEAK
#endif

GBA_WEAK const char* ConfigurationGetValue(const struct Configuration* config, const char* section, const char* key) {
	UNUSED(config);
	UNUSED(section);
	UNUSED(key);
	return NULL;
}

GBA_WEAK void ConfigurationSetValue(struct Configuration* config, const char* section, const char* key, const char* value) {
	UNUSED(config);
	UNUSED(section);
	UNUSED(key);
	UNUSED(value);
}

GBA_WEAK void ConfigurationSetIntValue(struct Configuration* config, const char* section, const char* key, int value) {
	UNUSED(config);
	UNUSED(section);
	UNUSED(key);
	UNUSED(value);
}

GBA_WEAK void ConfigurationSetUIntValue(struct Configuration* config, const char* section, const char* key, uint32_t value) {
	UNUSED(config);
	UNUSED(section);
	UNUSED(key);
	UNUSED(value);
}

GBA_WEAK void ConfigurationClearValue(struct Configuration* config, const char* section, const char* key) {
	UNUSED(config);
	UNUSED(section);
	UNUSED(key);
}

GBA_WEAK enum RegisterBank ARMSelectBank(enum PrivilegeMode mode) {
	UNUSED(mode);
	return BANK_NORMAL;
}

GBA_WEAK void GBAFrameStarted(struct GBA* gba) {
	UNUSED(gba);
}

GBA_WEAK void GBAFrameEnded(struct GBA* gba) {
	UNUSED(gba);
}

GBA_WEAK void GBAInterrupt(struct GBA* gba) {
	UNUSED(gba);
}

GBA_WEAK uint16_t mColorFrom555(uint16_t color) {
	return color & 0x7FFF;
}

GBA_WEAK uint16_t mColorMix5Bit(unsigned aWeight, uint16_t a, unsigned bWeight, uint16_t b) {
	unsigned ar = a & 0x1F;
	unsigned ag = (a >> 5) & 0x1F;
	unsigned ab = (a >> 10) & 0x1F;
	unsigned br = b & 0x1F;
	unsigned bg = (b >> 5) & 0x1F;
	unsigned bb = (b >> 10) & 0x1F;
	unsigned r = (ar * aWeight + br * bWeight) >> 4;
	unsigned g = (ag * aWeight + bg * bWeight) >> 4;
	unsigned bl = (ab * aWeight + bb * bWeight) >> 4;
	if (r > 31) r = 31;
	if (g > 31) g = 31;
	if (bl > 31) bl = 31;
	return (uint16_t) (r | (g << 5) | (bl << 10));
}

GBA_WEAK void mCacheSetWriteVRAM(void* cache, uint32_t address) {
	UNUSED(cache);
	UNUSED(address);
}

GBA_WEAK void mCacheSetWritePalette(void* cache, uint32_t index, uint16_t color) {
	UNUSED(cache);
	UNUSED(index);
	UNUSED(color);
}

GBA_WEAK void GBAVideoCacheWriteVideoRegister(void* cache, uint32_t address, uint16_t value) {
	UNUSED(cache);
	UNUSED(address);
	UNUSED(value);
}
