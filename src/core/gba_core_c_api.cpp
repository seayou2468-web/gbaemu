#include "./gba_core_c_api.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

extern "C" {
void init_main(void);
void reset_gba(void);
uint32_t update_gba(void);
uint16_t* copy_screen(void);
uint32_t load_gamepak(char* name);
int32_t load_bios(char* name);
void trigger_key(uint32_t key_mask);
extern uint32_t key;
}

namespace {

constexpr size_t kScreenWidth = 240;
constexpr size_t kScreenHeight = 160;
constexpr size_t kPixelCount = kScreenWidth * kScreenHeight;

static void ConvertRGB555ToRGBA8888(const uint16_t* src, uint32_t* dst, size_t pixels) {
    for (size_t i = 0; i < pixels; ++i) {
        const uint16_t c = src[i];
        const uint8_t r = static_cast<uint8_t>((c & 0x1Fu) << 3u);
        const uint8_t g = static_cast<uint8_t>(((c >> 5u) & 0x1Fu) << 3u);
        const uint8_t b = static_cast<uint8_t>(((c >> 10u) & 0x1Fu) << 3u);
        dst[i] = 0xFF000000u | (static_cast<uint32_t>(r) << 16u) |
                 (static_cast<uint32_t>(g) << 8u) | static_cast<uint32_t>(b);
    }
}

static bool TryLoadBuiltInBIOSImage(void) {
    std::array<const char*, 4> candidates = {
        "utils/bios/ababios.bin",
        "./utils/bios/ababios.bin",
        "gba_bios.bin",
        "./gba_bios.bin",
    };

    for (const char* path : candidates) {
        char buffer[512];
        std::snprintf(buffer, sizeof(buffer), "%s", path);
        if (load_bios(buffer) == 0) {
            return true;
        }
    }
    return false;
}

}  // namespace

extern "C" {

struct GBACoreHandle {
    char last_error[256];
    bool initialized = false;
    bool has_bios = false;
    bool has_rom = false;
    bool use_builtin_bios = false;
    uint16_t keys_pressed_mask = 0;
    std::vector<uint32_t> framebuffer;
};

static void SetError(GBACoreHandle* h, const char* msg) {
    if (!h) return;
    std::snprintf(h->last_error, sizeof(h->last_error), "%s", msg ? msg : "");
}

static void EnsureInitialized(GBACoreHandle* h) {
    if (!h || h->initialized) return;
    init_main();
    h->framebuffer.assign(kPixelCount, 0xFF000000u);
    h->initialized = true;
}

GBACoreHandle* GBA_Create(void) {
    GBACoreHandle* h = new GBACoreHandle();
    EnsureInitialized(h);
    SetError(h, "");
    return h;
}

void GBA_Destroy(GBACoreHandle* handle) {
    delete handle;
}

void GBA_LoadBuiltInBIOS(GBACoreHandle* handle) {
    if (!handle) return;
    EnsureInitialized(handle);

    if (!TryLoadBuiltInBIOSImage()) {
        SetError(handle, "failed to load built-in bios image");
        return;
    }

    handle->has_bios = true;
    handle->use_builtin_bios = true;
    SetError(handle, "");
}

bool GBA_LoadBIOSFromPath(GBACoreHandle* handle, const char* path) {
    if (!handle) return false;
    EnsureInitialized(handle);

    if (!path || !path[0]) {
        SetError(handle, "bios path is empty");
        return false;
    }

    char bios_path[1024];
    std::snprintf(bios_path, sizeof(bios_path), "%s", path);
    if (load_bios(bios_path) != 0) {
        SetError(handle, "failed to read bios file");
        return false;
    }

    handle->has_bios = true;
    handle->use_builtin_bios = false;
    SetError(handle, "");
    return true;
}

bool GBA_LoadROMFromPath(GBACoreHandle* handle, const char* path) {
    if (!handle) return false;
    EnsureInitialized(handle);

    if (!path || !path[0]) {
        SetError(handle, "rom path is empty");
        return false;
    }

    char rom_path[1024];
    std::snprintf(rom_path, sizeof(rom_path), "%s", path);
    if (load_gamepak(rom_path) != 0) {
        SetError(handle, "failed to load rom");
        return false;
    }

    reset_gba();
    handle->has_rom = true;
    SetError(handle, "");
    return true;
}

void GBA_Reset(GBACoreHandle* handle) {
    if (!handle) return;
    EnsureInitialized(handle);

    if (!handle->has_rom) {
        SetError(handle, "rom not loaded");
        return;
    }

    reset_gba();
    SetError(handle, "");
}

void GBA_StepFrame(GBACoreHandle* handle) {
    if (!handle) return;
    EnsureInitialized(handle);

    if (!handle->has_rom) {
        SetError(handle, "rom not loaded");
        return;
    }

    key = static_cast<uint32_t>(handle->keys_pressed_mask) & 0x03FFu;
    trigger_key(key);

    update_gba();

    uint16_t* frame = copy_screen();
    if (!frame) {
        SetError(handle, "failed to read frame buffer");
        return;
    }

    ConvertRGB555ToRGBA8888(frame, handle->framebuffer.data(), handle->framebuffer.size());
    std::free(frame);

    SetError(handle, "");
}

void GBA_SetKeys(GBACoreHandle* handle, uint16_t keys_pressed_mask) {
    if (!handle) return;
    handle->keys_pressed_mask = keys_pressed_mask;
}

size_t GBA_GetFrameBufferSize(GBACoreHandle* handle) {
    return handle ? handle->framebuffer.size() : 0;
}

const uint32_t* GBA_GetFrameBufferRGBA(GBACoreHandle* handle, size_t* out_size) {
    if (!handle) {
        if (out_size) *out_size = 0;
        return nullptr;
    }
    if (out_size) *out_size = handle->framebuffer.size();
    return handle->framebuffer.data();
}

bool GBA_CopyFrameBufferRGBA(GBACoreHandle* handle, uint32_t* out_pixels, size_t out_size) {
    if (!handle || !out_pixels) return false;
    if (out_size < handle->framebuffer.size()) return false;
    std::copy(handle->framebuffer.begin(), handle->framebuffer.end(), out_pixels);
    return true;
}

const char* GBA_GetLastError(GBACoreHandle* handle) {
    if (!handle) return "core handle is null";
    return handle->last_error;
}

}  // extern "C"
