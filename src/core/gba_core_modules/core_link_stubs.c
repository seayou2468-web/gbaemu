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

struct _MemoryVFile {
	struct VFile d;
	uint8_t* data;
	size_t size;
	size_t cursor;
	bool owned;
	bool writable;
};

static struct _CoreVideoCacheMirror _fallbackCacheMirror;

void* anonymousMemoryMap(size_t size) {
	if (size == 0) {
		return NULL;
	}
	return calloc(1, size);
}

void GBACreate(struct GBA* gba) {
	if (!gba) {
		return;
	}
	memset(gba, 0, sizeof(*gba));
	gba->d.init = _GBAMasterComponentInit;
	gba->d.deinit = _GBAMasterComponentDeinit;
}

void GBADestroy(struct GBA* gba) {
	if (!gba) {
		return;
	}
	_GBAMasterComponentDeinit(&gba->d);
}

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

static void _memoryVFileClose(struct VFile* vf) {
	if (!vf) {
		return;
	}
	struct _MemoryVFile* mvf = (struct _MemoryVFile*) vf;
	if (mvf->owned) {
		free(mvf->data);
	}
	free(mvf);
}

static ssize_t _memoryVFileRead(struct VFile* vf, void* out, size_t size) {
	struct _MemoryVFile* mvf = (struct _MemoryVFile*) vf;
	if (!mvf || !out || size == 0) {
		return 0;
	}
	size_t remain = mvf->size > mvf->cursor ? mvf->size - mvf->cursor : 0;
	size_t n = size < remain ? size : remain;
	if (n == 0) {
		return 0;
	}
	memcpy(out, mvf->data + mvf->cursor, n);
	mvf->cursor += n;
	return (ssize_t) n;
}

static ssize_t _memoryVFileWrite(struct VFile* vf, const void* in, size_t size) {
	struct _MemoryVFile* mvf = (struct _MemoryVFile*) vf;
	if (!mvf || !in || size == 0 || !mvf->writable) {
		return 0;
	}
	size_t remain = mvf->size > mvf->cursor ? mvf->size - mvf->cursor : 0;
	size_t n = size < remain ? size : remain;
	if (n == 0) {
		return 0;
	}
	memcpy(mvf->data + mvf->cursor, in, n);
	mvf->cursor += n;
	return (ssize_t) n;
}

static off_t _memoryVFileSeek(struct VFile* vf, off_t offset, int whence) {
	struct _MemoryVFile* mvf = (struct _MemoryVFile*) vf;
	if (!mvf) {
		return -1;
	}
	off_t base = 0;
	switch (whence) {
	case SEEK_SET: base = 0; break;
	case SEEK_CUR: base = (off_t) mvf->cursor; break;
	case SEEK_END: base = (off_t) mvf->size; break;
	default: return -1;
	}
	off_t pos = base + offset;
	if (pos < 0 || (size_t) pos > mvf->size) {
		return -1;
	}
	mvf->cursor = (size_t) pos;
	return pos;
}

static off_t _memoryVFileSize(struct VFile* vf) {
	struct _MemoryVFile* mvf = (struct _MemoryVFile*) vf;
	return mvf ? (off_t) mvf->size : 0;
}

static void _memoryVFileTruncate(struct VFile* vf, size_t size) {
	UNUSED(vf);
	UNUSED(size);
}

static bool _memoryVFileSync(struct VFile* vf, const void* in, size_t size) {
	UNUSED(vf);
	UNUSED(in);
	UNUSED(size);
	return true;
}

static void* _memoryVFileMap(struct VFile* vf, size_t size, int mode) {
	UNUSED(mode);
	struct _MemoryVFile* mvf = (struct _MemoryVFile*) vf;
	if (!mvf || size > mvf->size) {
		return NULL;
	}
	return mvf->data;
}

static void _memoryVFileUnmap(struct VFile* vf, void* memory, size_t size) {
	UNUSED(vf);
	UNUSED(memory);
	UNUSED(size);
}

static struct _MemoryVFile* _memoryVFileCreate(uint8_t* data, size_t size, bool owned, bool writable) {
	if (!data || size == 0) {
		return NULL;
	}
	struct _MemoryVFile* mvf = calloc(1, sizeof(*mvf));
	if (!mvf) {
		if (owned) {
			free(data);
		}
		return NULL;
	}
	mvf->data = data;
	mvf->size = size;
	mvf->owned = owned;
	mvf->writable = writable;
	mvf->d.close = _memoryVFileClose;
	mvf->d.read = _memoryVFileRead;
	mvf->d.write = _memoryVFileWrite;
	mvf->d.seek = _memoryVFileSeek;
	mvf->d.size = _memoryVFileSize;
	mvf->d.truncate = _memoryVFileTruncate;
	mvf->d.sync = _memoryVFileSync;
	mvf->d.map = _memoryVFileMap;
	mvf->d.unmap = _memoryVFileUnmap;
	return mvf;
}

struct VFile* VFileFromMemory(void* data, size_t size) {
	struct _MemoryVFile* mvf = _memoryVFileCreate((uint8_t*) data, size, false, true);
	return mvf ? &mvf->d : NULL;
}

struct VFile* VFileMemChunk(const void* data, size_t size) {
	if (!data || size == 0) {
		return NULL;
	}
	uint8_t* copy = malloc(size);
	if (!copy) {
		return NULL;
	}
	memcpy(copy, data, size);
	struct _MemoryVFile* mvf = _memoryVFileCreate(copy, size, true, false);
	return mvf ? &mvf->d : NULL;
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
