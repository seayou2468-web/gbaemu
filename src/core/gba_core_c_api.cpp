#include "./gba_core_c_api.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

extern "C" {
void init_gamepak_buffer(void);
void init_video(void);
void init_main(void);
void init_sound(int need_reset);
void init_input(void);
void init_cpu(void);
void init_memory(void);
void reset_gba(void);
int load_bios(char *name);
unsigned load_gamepak(char *name);
uint32_t execute_arm_translate(uint32_t cycles);
uint32_t update_gba(void);
uint16_t *copy_screen(void);
extern uint32_t execute_cycles;
extern int current_frameskip_type;
extern uint32_t frameskip_value;
extern uint32_t skip_next_frame;
extern uint32_t synchronize_flag;
}

namespace {
constexpr size_t kScreenWidth = 240;
constexpr size_t kScreenHeight = 160;
constexpr size_t kPixelCount = kScreenWidth * kScreenHeight;

static uint32_t Bgr555ToRgba8888(uint16_t px) {
    const uint8_t r5 = static_cast<uint8_t>(px & 0x1Fu);
    const uint8_t g5 = static_cast<uint8_t>((px >> 5u) & 0x1Fu);
    const uint8_t b5 = static_cast<uint8_t>((px >> 10u) & 0x1Fu);

    const uint8_t r8 = static_cast<uint8_t>((r5 << 3u) | (r5 >> 2u));
    const uint8_t g8 = static_cast<uint8_t>((g5 << 3u) | (g5 >> 2u));
    const uint8_t b8 = static_cast<uint8_t>((b5 << 3u) | (b5 >> 2u));

    // Store pixels in little-endian RGBA byte order (R,G,B,A in memory).
    return 0xFF000000u | (static_cast<uint32_t>(b8) << 16u) |
           (static_cast<uint32_t>(g8) << 8u) | static_cast<uint32_t>(r8);
}

}  // namespace

extern "C" {

struct GBACoreHandle {
    char last_error[256];
    bool initialized = false;
    bool has_bios = false;
    bool has_rom = false;
    uint16_t keys_pressed_mask = 0;
    std::vector<uint32_t> framebuffer;
};

static void SetError(GBACoreHandle *h, const char *msg) {
    if (!h) return;
    std::snprintf(h->last_error, sizeof(h->last_error), "%s", msg ? msg : "");
}

static void RefreshFrameBuffer(GBACoreHandle *h) {
    if (!h) return;
    uint16_t *raw = copy_screen();
    if (!raw) return;
    for (size_t i = 0; i < kPixelCount; ++i) {
        h->framebuffer[i] = Bgr555ToRgba8888(raw[i]);
    }
    free(raw);
}

static bool EnsureInitialized(GBACoreHandle *h) {
    if (!h) return false;
    if (h->initialized) return true;

    init_gamepak_buffer();
    init_video();
    init_main();
    init_sound(1);
    init_input();
    init_cpu();
    init_memory();

    // Force deterministic frame production for API callers.
    // main.h enum order: auto_frameskip(0), manual_frameskip(1), no_frameskip(2).
    current_frameskip_type = 2;
    frameskip_value = 0;
    skip_next_frame = 0;
    synchronize_flag = 0;

    h->initialized = true;
    return true;
}

GBACoreHandle *GBA_Create(void) {
    GBACoreHandle *h = new GBACoreHandle();
    h->framebuffer.assign(kPixelCount, 0xFF000000u);
    SetError(h, "");
    return h;
}

void GBA_Destroy(GBACoreHandle *handle) {
    delete handle;
}

void GBA_LoadBuiltInBIOS(GBACoreHandle *handle) {
    if (!handle) return;
    constexpr std::array<const char *, 4> candidates = {
        "utils/bios/ababios.bin",
        "./utils/bios/ababios.bin",
        "ababios.bin",
        "./ababios.bin",
    };

    for (const char *path : candidates) {
        if (GBA_LoadBIOSFromPath(handle, path)) {
            return;
        }
    }

    SetError(handle, "failed to load built-in BIOS candidate");
}

bool GBA_LoadBIOSFromPath(GBACoreHandle *handle, const char *path) {
    if (!handle || !path || !path[0]) return false;
    if (!EnsureInitialized(handle)) return false;

    if (load_bios(const_cast<char *>(path)) != 0) {
        SetError(handle, "failed to read bios file");
        return false;
    }

    handle->has_bios = true;
    if (handle->has_rom) {
        reset_gba();
        RefreshFrameBuffer(handle);
    }
    SetError(handle, "");
    return true;
}

bool GBA_LoadROMFromPath(GBACoreHandle *handle, const char *path) {
    if (!handle || !path || !path[0]) return false;
    if (!EnsureInitialized(handle)) return false;

    if (load_gamepak(const_cast<char *>(path)) == static_cast<unsigned>(-1)) {
        SetError(handle, "failed to load rom");
        return false;
    }

    handle->has_rom = true;
    if (handle->has_bios) {
        reset_gba();
        RefreshFrameBuffer(handle);
    }
    SetError(handle, "");
    return true;
}

void GBA_Reset(GBACoreHandle *handle) {
    if (!handle) return;
    if (!handle->has_rom) {
        SetError(handle, "rom not loaded");
        return;
    }
    if (!handle->has_bios) {
        SetError(handle, "bios not loaded");
        return;
    }

    reset_gba();
    RefreshFrameBuffer(handle);
    SetError(handle, "");
}

void GBA_StepFrame(GBACoreHandle *handle) {
    if (!handle) return;
    if (!handle->has_rom) {
        SetError(handle, "rom not loaded");
        return;
    }
    if (!handle->has_bios) {
        SetError(handle, "bios not loaded");
        return;
    }

    constexpr int kSlicesPerStep = 2;
    for (int i = 0; i < kSlicesPerStep; ++i) {
        const uint32_t executed = execute_cycles > 0 ? execute_cycles : 1;
        execute_arm_translate(executed);
    }
    RefreshFrameBuffer(handle);
    SetError(handle, "");
}

void GBA_SetKeys(GBACoreHandle *handle, uint16_t keys_pressed_mask) {
    if (!handle) return;
    handle->keys_pressed_mask = keys_pressed_mask;
}

size_t GBA_GetFrameBufferSize(GBACoreHandle *handle) {
    return handle ? handle->framebuffer.size() : 0;
}

const uint32_t *GBA_GetFrameBufferRGBA(GBACoreHandle *handle, size_t *out_size) {
    if (!handle) {
        if (out_size) *out_size = 0;
        return nullptr;
    }
    if (out_size) *out_size = handle->framebuffer.size();
    return handle->framebuffer.data();
}

bool GBA_CopyFrameBufferRGBA(GBACoreHandle *handle, uint32_t *out_pixels, size_t out_size) {
    if (!handle || !out_pixels) return false;
    if (out_size < handle->framebuffer.size()) return false;
    std::copy(handle->framebuffer.begin(), handle->framebuffer.end(), out_pixels);
    return true;
}

const char *GBA_GetLastError(GBACoreHandle *handle) {
    if (!handle) return "core handle is null";
    return handle->last_error;
}

}  // extern "C"
