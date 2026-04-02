#include "./gba_core_c_api.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define GBA_SCREEN_WIDTH 240
#define GBA_SCREEN_HEIGHT 160
#define GBA_PIXEL_COUNT (GBA_SCREEN_WIDTH * GBA_SCREEN_HEIGHT)

typedef struct {
    uint8_t* data;
    size_t size;
} GBABlob;

struct GBACoreHandle {
    uint32_t frame[GBA_PIXEL_COUNT];
    GBABlob rom;
    GBABlob bios;
    char lastError[256];
    uint64_t frameCounter;
    uint16_t keys;
    bool hasRom;
    bool hasBios;
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

static inline uint32_t _rgba(uint8_t r, uint8_t g, uint8_t b) {
    return 0xFF000000u | ((uint32_t) r << 16) | ((uint32_t) g << 8) | (uint32_t) b;
}

static inline uint32_t _bgr555ToRgba(uint16_t color) {
    uint8_t r = (uint8_t) ((color & 0x1F) << 3);
    uint8_t g = (uint8_t) (((color >> 5) & 0x1F) << 3);
    uint8_t b = (uint8_t) (((color >> 10) & 0x1F) << 3);
    return _rgba(r, g, b);
}

static void _renderDummyFrame(GBACoreHandle* h) {
    if (!h->rom.data || h->rom.size < 2) {
        memset(h->frame, 0, sizeof(h->frame));
        return;
    }
    size_t srcWords = h->rom.size / 2;
    size_t phase = (size_t) (h->frameCounter * 257u) % srcWords;
    int xScroll = (h->keys & 0x0020) ? 2 : (h->keys & 0x0010) ? -2 : 0;
    int yScroll = (h->keys & 0x0040) ? 2 : (h->keys & 0x0080) ? -2 : 0;
    for (size_t y = 0; y < GBA_SCREEN_HEIGHT; ++y) {
        for (size_t x = 0; x < GBA_SCREEN_WIDTH; ++x) {
            int sx = (int) x + xScroll;
            int sy = (int) y + yScroll;
            if (sx < 0) sx += GBA_SCREEN_WIDTH;
            if (sy < 0) sy += GBA_SCREEN_HEIGHT;
            sx %= GBA_SCREEN_WIDTH;
            sy %= GBA_SCREEN_HEIGHT;
            size_t srcIndex = (phase + (size_t) sy * GBA_SCREEN_WIDTH + (size_t) sx) % srcWords;
            uint16_t color = (uint16_t) h->rom.data[srcIndex * 2] |
                             (uint16_t) (h->rom.data[srcIndex * 2 + 1] << 8);
            uint8_t tint = (uint8_t) ((h->frameCounter + x + y) & 0x7);
            color ^= (uint16_t) (tint << 10);
            if (h->keys & 0x0001) {
                color ^= 0x7FFF;
            }
            h->frame[y * GBA_SCREEN_WIDTH + x] = _bgr555ToRgba(color);
        }
    }
}

GBACoreHandle* GBA_Create(void) {
    GBACoreHandle* h = (GBACoreHandle*) calloc(1, sizeof(GBACoreHandle));
    return h;
}

void GBA_Destroy(GBACoreHandle* handle) {
    if (!handle) {
        return;
    }
    _freeBlob(&handle->rom);
    _freeBlob(&handle->bios);
    free(handle);
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
    handle->hasBios = true;
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
    handle->hasBios = true;
    _setError(handle, NULL);
    return true;
}

void GBA_LoadBuiltInBIOS(GBACoreHandle* handle) {
    if (!handle) {
        return;
    }
    _freeBlob(&handle->bios);
    handle->bios.data = (uint8_t*) calloc(16 * 1024, 1);
    handle->bios.size = handle->bios.data ? 16 * 1024 : 0;
    handle->hasBios = handle->bios.data != NULL;
    _setError(handle, handle->hasBios ? NULL : "failed to allocate built-in BIOS");
}

void GBA_Reset(GBACoreHandle* handle) {
    if (!handle) {
        return;
    }
    handle->frameCounter = 0;
    for (size_t i = 0; i < GBA_PIXEL_COUNT; ++i) {
        handle->frame[i] = 0xFF000000u;
    }
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
    ++handle->frameCounter;
    _renderDummyFrame(handle);
    _setError(handle, NULL);
}

void GBA_SetKeys(GBACoreHandle* handle, uint16_t keysPressedMask) {
    if (!handle) {
        return;
    }
    handle->keys = keysPressedMask;
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
