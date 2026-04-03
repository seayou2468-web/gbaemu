#include "../gba_core.h"

void ARMRaiseIRQ(struct ARMCore* cpu);

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
	if (!gba) {
		return;
	}
	gba->haltPending = false;
}

void GBAFrameEnded(struct GBA* gba) {
	if (!gba) {
		return;
	}
	gba->keysLast = (uint16_t) gba->keysActive;
}

void GBAInterrupt(struct GBA* gba) {
	if (!gba || !gba->cpu) {
		return;
	}
	uint16_t ime = gba->memory.io[GBA_REG(IME)] & 1;
	uint16_t ie = gba->memory.io[GBA_REG(IE)];
	uint16_t irqFlags = gba->memory.io[GBA_REG(IF)];
	if (ime && (ie & irqFlags)) {
		ARMRaiseIRQ(gba->cpu);
	}
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

struct _CoreVideoCacheMirror {
	uint16_t videoRegs[0x100];
	uint16_t palette[0x200];
	uint32_t recentVramWrites[64];
	uint32_t recentWritePos;
};

static struct _CoreVideoCacheMirror _fallbackCacheMirror;

void mCacheSetWriteVRAM(void* cache, uint32_t address) {
	UNUSED(cache);
	uint32_t pos = _fallbackCacheMirror.recentWritePos++ & 63;
	_fallbackCacheMirror.recentVramWrites[pos] = address;
}

void mCacheSetWritePalette(void* cache, uint32_t index, uint16_t color) {
	UNUSED(cache);
	_fallbackCacheMirror.palette[index & 0x1FF] = color;
}

void GBAVideoCacheWriteVideoRegister(void* cache, uint32_t address, uint16_t value) {
	UNUSED(cache);
	_fallbackCacheMirror.videoRegs[(address >> 1) & 0xFF] = value;
}

bool GBAIsMB(struct VFile* vf) {
	UNUSED(vf);
	return false;
}

struct VFile* VFileFromMemory(void* data, size_t size) {
	UNUSED(data);
	UNUSED(size);
	return NULL;
}

struct VFile* VFileMemChunk(const void* data, size_t size) {
	UNUSED(data);
	UNUSED(size);
	return NULL;
}

static bool _readWholeVFile(struct VFile* vf, uint8_t** outData, size_t* outSize) {
	if (!vf || !outData || !outSize || !vf->size || !vf->seek || !vf->read) {
		return false;
	}
	off_t fileSize = vf->size(vf);
	if (fileSize <= 0) {
		return false;
	}
	if (vf->seek(vf, 0, SEEK_SET) < 0) {
		return false;
	}
	uint8_t* buf = anonymousMemoryMap((size_t) fileSize);
	if (!buf) {
		return false;
	}
	size_t total = 0;
	while (total < (size_t) fileSize) {
		ssize_t n = vf->read(vf, buf + total, (size_t) fileSize - total);
		if (n <= 0) {
			mappedMemoryFree(buf, (size_t) fileSize);
			return false;
		}
		total += (size_t) n;
	}
	*outData = buf;
	*outSize = (size_t) fileSize;
	return true;
}

bool GBALoadMB(void* board, struct VFile* vf) {
	UNUSED(board);
	UNUSED(vf);
	return false;
}

bool GBALoadROM(void* board, struct VFile* vf) {
	struct GBA* gba = board;
	if (!gba || !vf) {
		return false;
	}
	uint8_t* romData = NULL;
	size_t romSize = 0;
	if (!_readWholeVFile(vf, &romData, &romSize)) {
		return false;
	}
	if (gba->memory.rom) {
		mappedMemoryFree(gba->memory.rom, gba->memory.romSize);
	}
	gba->memory.rom = romData;
	gba->memory.romSize = romSize;
	gba->memory.romMask = (uint32_t) (toPow2(romSize) - 1);
	gba->pristineRomSize = romSize;
	gba->isPristine = true;
	return true;
}

bool GBAIsBIOS(struct VFile* vf) {
	if (!vf || !vf->size) {
		return false;
	}
	return vf->size(vf) == GBA_SIZE_BIOS;
}

void GBALoadBIOS(void* board, struct VFile* vf) {
	struct GBA* gba = board;
	if (!gba || !vf) {
		return;
	}
	uint8_t* biosData = NULL;
	size_t biosSize = 0;
	if (!_readWholeVFile(vf, &biosData, &biosSize) || biosSize != GBA_SIZE_BIOS) {
		return;
	}
	if (gba->memory.bios && (uint8_t*) gba->memory.bios != hleBios) {
		mappedMemoryFree(gba->memory.bios, GBA_SIZE_BIOS);
	}
	gba->memory.bios = (uint32_t*) biosData;
	gba->memory.fullBios = true;
}

void GBAUnloadROM(void* board) {
	struct GBA* gba = board;
	if (!gba || !gba->memory.rom) {
		return;
	}
	mappedMemoryFree(gba->memory.rom, gba->memory.romSize);
	gba->memory.rom = NULL;
	gba->memory.romSize = 0;
	gba->memory.romMask = 0;
}

void GBASkipBIOS(void* board) {
	struct GBA* gba = board;
	if (!gba || !gba->cpu) {
		return;
	}
	gba->memory.io[GBA_REG(POSTFLG)] = 1;
	gba->cpu->gprs[ARM_PC] = GBA_BASE_ROM0;
}
