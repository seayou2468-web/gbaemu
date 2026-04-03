#include "./gba_core_c_api.h"
#include "./gba_core.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// NOTE:
// Embedding runtime .c modules directly is useful for standalone integration,
// but can trigger duplicate-definition linker errors in targets that already
// compile those modules as separate translation units.
//
// Keep this path opt-in to avoid duplicate symbols by default.
#if defined(GBA_C_API_EMBED_RUNTIME_MODULES)
#include "./gba_core_modules/core_input_runtime.c"
#include "./gba_core_modules/core_overrides_runtime.c"
#include "./gba_core_modules/core_bootstrap.c"
#include "./gba_core_modules/core_io_runtime.c"
#include "./gba_core_modules/core_reset_state.c"
#include "./gba_core_modules/core_timing_runtime.c"
#include "./gba_core_modules/core_sync_runtime.c"
#include "./gba_core_modules/core_save_runtime.c"
#include "./gba_core_modules/core_backup_runtime.c"
#include "./gba_core_modules/core_link_stubs.c"
#include "./gba_core_modules/core_unlicensed_runtime.c"
#include "./gba_core_modules/cpu_helpers.c"
#include "./gba_core_modules/cpu_swi.c"
#include "./gba_core_modules/cpu_arm_execute.c"
#include "./gba_core_modules/cpu_thumb_run.c"
#include "./gba_core_modules/memory_bus.c"
#include "./gba_core_modules/ppu_common.c"
#include "./gba_core_modules/timing_dma.c"
#include "./gba_core_modules/apu_interrupts.c"

// Temporary bridge stubs for renderer split functions that are referenced by
// ppu_common in this trimmed tree but not linked automatically here.
void GBAVideoSoftwareRendererDrawBackgroundMode0(struct GBAVideoSoftwareRenderer* renderer, struct GBAVideoSoftwareBackground* background, int y) {
    UNUSED(renderer); UNUSED(background); UNUSED(y);
}
void GBAVideoSoftwareRendererDrawBackgroundMode2(struct GBAVideoSoftwareRenderer* renderer, struct GBAVideoSoftwareBackground* background, int y) {
    UNUSED(renderer); UNUSED(background); UNUSED(y);
}
void GBAVideoSoftwareRendererDrawBackgroundMode3(struct GBAVideoSoftwareRenderer* renderer, struct GBAVideoSoftwareBackground* background, int y) {
    UNUSED(renderer); UNUSED(background); UNUSED(y);
}
void GBAVideoSoftwareRendererDrawBackgroundMode4(struct GBAVideoSoftwareRenderer* renderer, struct GBAVideoSoftwareBackground* background, int y) {
    UNUSED(renderer); UNUSED(background); UNUSED(y);
}
void GBAVideoSoftwareRendererDrawBackgroundMode5(struct GBAVideoSoftwareRenderer* renderer, struct GBAVideoSoftwareBackground* background, int y) {
    UNUSED(renderer); UNUSED(background); UNUSED(y);
}
int GBAVideoSoftwareRendererPreprocessSprite(struct GBAVideoSoftwareRenderer* renderer, struct GBAObj* sprite, int index, int y) {
    UNUSED(renderer); UNUSED(sprite); UNUSED(index); UNUSED(y); return 0;
}
void GBAVideoSoftwareRendererPostprocessSprite(struct GBAVideoSoftwareRenderer* renderer, unsigned priority) {
    UNUSED(renderer); UNUSED(priority);
}
#endif

#define GBA_SCREEN_WIDTH 240
#define GBA_SCREEN_HEIGHT 160
#define GBA_PIXEL_COUNT (GBA_SCREEN_WIDTH * GBA_SCREEN_HEIGHT)
#define GBA_BIOS_SIZE (16 * 1024)

typedef struct {
    uint8_t* data;
    size_t size;
} GBABlob;

struct GBACoreHandle {
    uint32_t frame[GBA_PIXEL_COUNT];
    mColor frame16[GBA_PIXEL_COUNT];
    GBABlob rom;
    GBABlob bios;
    char lastError[256];
    uint16_t keys;
    bool hasRom;
    bool hasBios;

    struct ARMCore* cpu;
    struct GBA* gba;
    struct GBAVideoSoftwareRenderer renderer;
    bool runtimeReady;
};

static void _setError(GBACoreHandle* h, const char* msg) {
    if (!h) {
        return;
    }
    if (!msg) {
        h->lastError[0] = '\0';
        return;
    }
    snprintf(h->lastError, sizeof(h->lastError), "%s", msg);
}

static void _freeBlob(GBABlob* blob) {
    if (!blob) {
        return;
    }
    free(blob->data);
    blob->data = NULL;
    blob->size = 0;
}

static bool _loadFile(const char* path, GBABlob* out, char* err, size_t errSize) {
    if (!path || !path[0]) {
        snprintf(err, errSize, "path is empty");
        return false;
    }
    FILE* f = fopen(path, "rb");
    if (!f) {
        snprintf(err, errSize, "failed to open file: %s", path);
        return false;
    }
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        snprintf(err, errSize, "failed to seek file");
        return false;
    }
    long sz = ftell(f);
    if (sz < 0) {
        fclose(f);
        snprintf(err, errSize, "failed to get file size");
        return false;
    }
    rewind(f);

    uint8_t* buf = NULL;
    if (sz > 0) {
        buf = (uint8_t*) malloc((size_t) sz);
        if (!buf) {
            fclose(f);
            snprintf(err, errSize, "out of memory");
            return false;
        }
        size_t n = fread(buf, 1, (size_t) sz, f);
        if (n != (size_t) sz) {
            free(buf);
            fclose(f);
            snprintf(err, errSize, "failed to read file");
            return false;
        }
    }

    fclose(f);
    _freeBlob(out);
    out->data = buf;
    out->size = (size_t) sz;
    return true;
}

static bool _loadBlobFromMemory(GBABlob* out, const uint8_t* data, size_t size, char* err, size_t errSize) {
    if (!data || size == 0) {
        snprintf(err, errSize, "buffer is empty");
        return false;
    }
    uint8_t* buf = (uint8_t*) malloc(size);
    if (!buf) {
        snprintf(err, errSize, "out of memory");
        return false;
    }
    memcpy(buf, data, size);
    _freeBlob(out);
    out->data = buf;
    out->size = size;
    return true;
}

static inline uint32_t _bgr555ToRgba(mColor color) {
    uint8_t r = (uint8_t) ((color & 0x1F) << 3);
    uint8_t g = (uint8_t) (((color >> 5) & 0x1F) << 3);
    uint8_t b = (uint8_t) (((color >> 10) & 0x1F) << 3);
    return 0xFF000000u | ((uint32_t) r << 16) | ((uint32_t) g << 8) | (uint32_t) b;
}

static void _clearFrame(GBACoreHandle* h) {
    for (size_t i = 0; i < GBA_PIXEL_COUNT; ++i) {
        h->frame16[i] = 0;
        h->frame[i] = 0xFF000000u;
    }
}

static bool _initRendererBuffers(GBACoreHandle* h) {
    const size_t paletteEntries = 512;
    h->renderer.normalPalette = (mColor*) anonymousMemoryMap(sizeof(mColor) * paletteEntries);
    h->renderer.variantPalette = (mColor*) anonymousMemoryMap(sizeof(mColor) * paletteEntries);
    h->renderer.highlightPalette = (mColor*) anonymousMemoryMap(sizeof(mColor) * paletteEntries);
    h->renderer.highlightVariantPalette = (mColor*) anonymousMemoryMap(sizeof(mColor) * paletteEntries);
    h->renderer.row = (uint32_t*) anonymousMemoryMap(sizeof(uint32_t) * GBA_SCREEN_WIDTH);
    h->renderer.spriteLayer = (uint32_t*) anonymousMemoryMap(sizeof(uint32_t) * GBA_SCREEN_WIDTH);
    if (!h->renderer.normalPalette || !h->renderer.variantPalette ||
        !h->renderer.highlightPalette || !h->renderer.highlightVariantPalette ||
        !h->renderer.row || !h->renderer.spriteLayer) {
        _setError(h, "failed to allocate software renderer buffers");
        return false;
    }
    return true;
}

static void _freeRendererBuffers(GBACoreHandle* h) {
    if (!h) {
        return;
    }
    h->renderer.normalPalette = NULL;
    h->renderer.variantPalette = NULL;
    h->renderer.highlightPalette = NULL;
    h->renderer.highlightVariantPalette = NULL;
    h->renderer.row = NULL;
    h->renderer.spriteLayer = NULL;
}

static bool _initRuntime(GBACoreHandle* h) {
    if (!h || h->runtimeReady) {
        return h != NULL;
    }

    h->cpu = (struct ARMCore*) anonymousMemoryMap(sizeof(struct ARMCore));
    h->gba = (struct GBA*) anonymousMemoryMap(sizeof(struct GBA));
    if (!h->cpu || !h->gba) {
        _setError(h, "failed to allocate core runtime state");
        return false;
    }

    GBACreate(h->gba);
    ARMSetComponents(h->cpu, &h->gba->d, 0, NULL);
    ARMInit(h->cpu);

    GBAVideoSoftwareRendererCreate(&h->renderer);
    if (!_initRendererBuffers(h)) {
        return false;
    }
    h->renderer.outputBuffer = h->frame16;
    h->renderer.outputBufferStride = GBA_SCREEN_WIDTH;
    GBAVideoAssociateRenderer(&h->gba->video, &h->renderer.d);

    h->runtimeReady = true;
    _setError(h, NULL);
    return true;
}

static bool _syncRuntimeROM(GBACoreHandle* h) {
    if (!h || !h->gba || !h->rom.data || h->rom.size == 0) {
        return false;
    }
    struct VFile* vf = VFileMemChunk(h->rom.data, h->rom.size);
    if (!vf) {
        _setError(h, "failed to create ROM VFile");
        return false;
    }
    bool ok = GBALoadROM(h->gba, vf);
    vf->close(vf);
    if (!ok) {
        _setError(h, "failed to load ROM into runtime");
        return false;
    }
    return h->gba->memory.rom && h->gba->memory.romSize > 0;
}

static bool _syncRuntimeBIOS(GBACoreHandle* h) {
    if (!h || !h->gba || !h->bios.data || h->bios.size != GBA_BIOS_SIZE) {
        return false;
    }
    struct VFile* vf = VFileMemChunk(h->bios.data, h->bios.size);
    if (!vf) {
        _setError(h, "failed to create BIOS VFile");
        return false;
    }
    GBALoadBIOS(h->gba, vf);
    vf->close(vf);
    if (!h->gba->memory.bios || !h->gba->memory.fullBios) {
        _setError(h, "failed to load BIOS into runtime");
        return false;
    }
    return true;
}

GBACoreHandle* GBA_Create(void) {
    GBACoreHandle* h = (GBACoreHandle*) calloc(1, sizeof(GBACoreHandle));
    if (!h) {
        return NULL;
    }
    _clearFrame(h);
    if (!_initRuntime(h)) {
        // Keep handle alive for error reporting and fallback behavior.
        _clearFrame(h);
    }
    return h;
}

void GBA_Destroy(GBACoreHandle* handle) {
    if (!handle) {
        return;
    }
    // Runtime teardown is intentionally conservative while bring-up is in
    // progress; avoid deep free paths that are still being stabilized.
    (void)handle->gba;
    _freeRendererBuffers(handle);
    (void)handle->cpu;
    handle->runtimeReady = false;
    handle->gba = NULL;
    handle->cpu = NULL;
    _freeBlob(&handle->rom);
    _freeBlob(&handle->bios);
    free(handle);
}

bool GBA_LoadROMFromPath(GBACoreHandle* handle, const char* path) {
    if (!handle) {
        return false;
    }
    char err[256] = {0};
    if (!_loadFile(path, &handle->rom, err, sizeof(err))) {
        _setError(handle, err);
        handle->hasRom = false;
        return false;
    }
    handle->hasRom = true;
    if (handle->runtimeReady && !_syncRuntimeROM(handle)) {
        handle->hasRom = false;
        return false;
    }
    _setError(handle, NULL);
    return true;
}

bool GBA_LoadROMFromBuffer(GBACoreHandle* handle, const uint8_t* data, size_t size) {
    if (!handle) {
        return false;
    }
    char err[256] = {0};
    if (!_loadBlobFromMemory(&handle->rom, data, size, err, sizeof(err))) {
        _setError(handle, err);
        handle->hasRom = false;
        return false;
    }
    handle->hasRom = true;
    if (handle->runtimeReady && !_syncRuntimeROM(handle)) {
        handle->hasRom = false;
        return false;
    }
    _setError(handle, NULL);
    return true;
}

bool GBA_LoadBIOSFromPath(GBACoreHandle* handle, const char* path) {
    if (!handle) {
        return false;
    }
    char err[256] = {0};
    if (!_loadFile(path, &handle->bios, err, sizeof(err))) {
        _setError(handle, err);
        handle->hasBios = false;
        return false;
    }
    if (handle->bios.size != GBA_BIOS_SIZE) {
        _setError(handle, "invalid BIOS size (expected 16384 bytes)");
        handle->hasBios = false;
        return false;
    }
    handle->hasBios = true;
    if (handle->runtimeReady && !_syncRuntimeBIOS(handle)) {
        handle->hasBios = false;
        return false;
    }
    _setError(handle, NULL);
    return true;
}

bool GBA_LoadBIOSFromBuffer(GBACoreHandle* handle, const uint8_t* data, size_t size) {
    if (!handle) {
        return false;
    }
    char err[256] = {0};
    if (!_loadBlobFromMemory(&handle->bios, data, size, err, sizeof(err))) {
        _setError(handle, err);
        handle->hasBios = false;
        return false;
    }
    if (handle->bios.size != GBA_BIOS_SIZE) {
        _setError(handle, "invalid BIOS size (expected 16384 bytes)");
        handle->hasBios = false;
        return false;
    }
    handle->hasBios = true;
    if (handle->runtimeReady && !_syncRuntimeBIOS(handle)) {
        handle->hasBios = false;
        return false;
    }
    _setError(handle, NULL);
    return true;
}

void GBA_LoadBuiltInBIOS(GBACoreHandle* handle) {
    if (!handle) {
        return;
    }
    _freeBlob(&handle->bios);
    handle->bios.data = (uint8_t*) calloc(GBA_BIOS_SIZE, 1);
    handle->bios.size = handle->bios.data ? GBA_BIOS_SIZE : 0;
    handle->hasBios = handle->bios.data != NULL;
    if (!handle->hasBios) {
        _setError(handle, "failed to allocate built-in BIOS");
        return;
    }
    if (handle->runtimeReady && !_syncRuntimeBIOS(handle)) {
        handle->hasBios = false;
        return;
    }
    _setError(handle, NULL);
}

void GBA_Reset(GBACoreHandle* handle) {
    if (!handle) {
        return;
    }
    if (!_initRuntime(handle)) {
        _clearFrame(handle);
        return;
    }
    if (handle->hasRom && !_syncRuntimeROM(handle)) {
        return;
    }
    if (handle->hasBios && !_syncRuntimeBIOS(handle)) {
        return;
    }
    GBAMemoryReset(handle->gba);
    GBAVideoReset(&handle->gba->video);
    ARMReset(handle->cpu);
    if (handle->gba->memory.rom) {
        if (handle->cpu->memory.setActiveRegion) {
            handle->cpu->memory.setActiveRegion(handle->cpu, GBA_BASE_ROM0);
        }
        if (!handle->cpu->memory.activeRegion) {
            handle->cpu->memory.activeRegion = handle->gba->memory.rom;
            handle->cpu->memory.activeMask = handle->gba->memory.romMask ? handle->gba->memory.romMask : (GBA_SIZE_ROM0 - 1);
        }
        handle->cpu->gprs[ARM_PC] = GBA_BASE_ROM0;
        LOAD_32(handle->cpu->prefetch[0], 0, handle->cpu->memory.activeRegion);
        LOAD_32(handle->cpu->prefetch[1], 4, handle->cpu->memory.activeRegion);
    }
    mTimingInterrupt(&handle->gba->timing);
    _setError(handle, NULL);
}

void GBA_StepFrame(GBACoreHandle* handle) {
    if (!handle) {
        return;
    }
    if (!handle->hasRom) {
        _setError(handle, "ROM is not loaded");
        return;
    }
    if (!handle->hasBios) {
        _setError(handle, "BIOS is not loaded");
        return;
    }
    if (!_initRuntime(handle)) {
        _setError(handle, "runtime init failed");
        return;
    }
    if (!handle->cpu->memory.activeRegion) {
        _setError(handle, "cpu active memory region is not initialized");
        return;
    }

    uint32_t frameCounter = handle->gba->video.frameCounter;
    int32_t startCycle = mTimingCurrentTime(&handle->gba->timing);
    int safety = 0;
    while (handle->gba->video.frameCounter == frameCounter &&
           mTimingCurrentTime(&handle->gba->timing) - startCycle < VIDEO_TOTAL_LENGTH + VIDEO_HORIZONTAL_LENGTH &&
           safety < 500000) {
        ARMRun(handle->cpu);
        ++safety;
    }
    if (safety >= 500000) {
        _setError(handle, "frame step timeout");
        return;
    }

    for (size_t i = 0; i < GBA_PIXEL_COUNT; ++i) {
        handle->frame[i] = _bgr555ToRgba(handle->frame16[i]);
    }
    _setError(handle, NULL);
}

void GBA_SetKeys(GBACoreHandle* handle, uint16_t keysPressedMask) {
    if (!handle) {
        return;
    }
    handle->keys = keysPressedMask;
    if (handle->gba) {
        // KEYINPUT is active-low.
        handle->gba->memory.io[GBA_REG(KEYINPUT)] = (uint16_t) ~keysPressedMask;
    }
}

const uint32_t* GBA_GetFrameBufferRGBA(GBACoreHandle* handle, size_t* pixelCount) {
    if (pixelCount) {
        *pixelCount = handle ? GBA_PIXEL_COUNT : 0;
    }
    return handle ? handle->frame : NULL;
}

size_t GBA_GetFrameBufferSize(GBACoreHandle* handle) {
    return handle ? GBA_PIXEL_COUNT : 0;
}

bool GBA_CopyFrameBufferRGBA(GBACoreHandle* handle, uint32_t* dst, size_t pixels) {
    if (!handle || !dst || pixels < GBA_PIXEL_COUNT) {
        return false;
    }
    memcpy(dst, handle->frame, GBA_PIXEL_COUNT * sizeof(uint32_t));
    return true;
}

const char* GBA_GetLastError(GBACoreHandle* handle) {
    static const char* kNull = "core handle is null";
    if (!handle) {
        return kNull;
    }
    return handle->lastError;
}
