#include "../gba_core.h"

struct _CoreConfigKV {
	char* section;
	char* key;
	char* value;
	struct _CoreConfigKV* next;
};

static struct _CoreConfigKV* _coreConfigHead = NULL;

static char* _dupString(const char* s) {
	if (!s) {
		return NULL;
	}
	size_t n = strlen(s) + 1;
	char* out = malloc(n);
	if (!out) {
		return NULL;
	}
	memcpy(out, s, n);
	return out;
}

static struct _CoreConfigKV* _findConfigKV(const char* section, const char* key) {
	struct _CoreConfigKV* it = _coreConfigHead;
	while (it) {
		if (strcmp(it->section, section) == 0 && strcmp(it->key, key) == 0) {
			return it;
		}
		it = it->next;
	}
	return NULL;
}

const char* ConfigurationGetValue(const struct Configuration* config, const char* section, const char* key) {
	UNUSED(config);
	if (!section || !key) {
		return NULL;
	}
	struct _CoreConfigKV* kv = _findConfigKV(section, key);
	return kv ? kv->value : NULL;
}

void ConfigurationSetValue(struct Configuration* config, const char* section, const char* key, const char* value) {
	UNUSED(config);
	if (!section || !key) {
		return;
	}
	if (!value) {
		ConfigurationClearValue(config, section, key);
		return;
	}
	struct _CoreConfigKV* kv = _findConfigKV(section, key);
	if (!kv) {
		kv = calloc(1, sizeof(*kv));
		if (!kv) {
			return;
		}
		kv->section = _dupString(section);
		kv->key = _dupString(key);
		if (!kv->section || !kv->key) {
			free(kv->section);
			free(kv->key);
			free(kv);
			return;
		}
		kv->next = _coreConfigHead;
		_coreConfigHead = kv;
	}
	char* newValue = _dupString(value);
	if (!newValue) {
		return;
	}
	free(kv->value);
	kv->value = newValue;
}

void ConfigurationSetIntValue(struct Configuration* config, const char* section, const char* key, int value) {
	char buffer[32];
	snprintf(buffer, sizeof(buffer), "%d", value);
	ConfigurationSetValue(config, section, key, buffer);
}

void ConfigurationSetUIntValue(struct Configuration* config, const char* section, const char* key, uint32_t value) {
	char buffer[32];
	snprintf(buffer, sizeof(buffer), "%u", value);
	ConfigurationSetValue(config, section, key, buffer);
}

void ConfigurationClearValue(struct Configuration* config, const char* section, const char* key) {
	UNUSED(config);
	if (!section || !key) {
		return;
	}
	struct _CoreConfigKV** prev = &_coreConfigHead;
	struct _CoreConfigKV* it = _coreConfigHead;
	while (it) {
		if (strcmp(it->section, section) == 0 && strcmp(it->key, key) == 0) {
			*prev = it->next;
			free(it->section);
			free(it->key);
			free(it->value);
			free(it);
			return;
		}
		prev = &it->next;
		it = it->next;
	}
}

enum RegisterBank ARMSelectBank(enum PrivilegeMode mode) {
	if (mode == MODE_FIQ) {
		return BANK_FIQ;
	}
	return BANK_NORMAL;
}

void GBAFrameStarted(struct GBA* gba) {
	UNUSED(gba);
}

void GBAFrameEnded(struct GBA* gba) {
	UNUSED(gba);
}

void GBAInterrupt(struct GBA* gba) {
	UNUSED(gba);
}

uint16_t mColorFrom555(uint16_t color) {
	return color & 0x7FFF;
}

uint16_t mColorMix5Bit(unsigned aWeight, uint16_t a, unsigned bWeight, uint16_t b) {
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

void mCacheSetWriteVRAM(void* cache, uint32_t address) {
	UNUSED(cache);
	UNUSED(address);
}

void mCacheSetWritePalette(void* cache, uint32_t index, uint16_t color) {
	UNUSED(cache);
	UNUSED(index);
	UNUSED(color);
}

void GBAVideoCacheWriteVideoRegister(void* cache, uint32_t address, uint16_t value) {
	UNUSED(cache);
	UNUSED(address);
	UNUSED(value);
}
