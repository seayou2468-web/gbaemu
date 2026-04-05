#include "./gba_core_c_api.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

namespace {

constexpr size_t kScreenWidth = 240;
constexpr size_t kScreenHeight = 160;
constexpr size_t kPixelCount = kScreenWidth * kScreenHeight;

static std::vector<uint8_t> LoadFile(const char* path) {
    if (!path || !path[0]) return {};
    std::ifstream f(path, std::ios::binary);
    if (!f) return {};
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

static uint64_t Fnv1a64(const std::vector<uint8_t>& bytes) {
    uint64_t hash = 1469598103934665603ull;
    for (uint8_t b : bytes) {
        hash ^= static_cast<uint64_t>(b);
        hash *= 1099511628211ull;
    }
    return hash;
}

}  // namespace

extern "C" {

struct GBACoreHandle {
    char last_error[256];
    bool has_bios = false;
    bool has_rom = false;
    uint16_t keys_pressed_mask = 0;
    uint64_t bios_hash = 0;
    uint64_t rom_hash = 0;
    uint64_t frame_counter = 0;
    std::vector<uint32_t> framebuffer;
};

static void SetError(GBACoreHandle* h, const char* msg) {
    if (!h) return;
    std::snprintf(h->last_error, sizeof(h->last_error), "%s", msg ? msg : "");
}

static void RenderFrame(GBACoreHandle* h) {
    if (!h) return;
    const uint32_t seed = static_cast<uint32_t>((h->bios_hash ^ h->rom_hash ^ h->frame_counter) & 0xFFFFFFFFu);
    const uint8_t key_mix = static_cast<uint8_t>(h->keys_pressed_mask & 0xFFu);

    for (size_t y = 0; y < kScreenHeight; ++y) {
        for (size_t x = 0; x < kScreenWidth; ++x) {
            const size_t i = y * kScreenWidth + x;
            const uint8_t r = static_cast<uint8_t>((x + (seed & 0xFFu) + key_mix) & 0xFFu);
            const uint8_t g = static_cast<uint8_t>((y + ((seed >> 8) & 0xFFu) + (h->frame_counter & 0x3Fu)) & 0xFFu);
            const uint8_t b = static_cast<uint8_t>(((x ^ y) + ((seed >> 16) & 0xFFu)) & 0xFFu);
            h->framebuffer[i] =
                0xFF000000u | (static_cast<uint32_t>(r) << 16u) |
                (static_cast<uint32_t>(g) << 8u) | static_cast<uint32_t>(b);
        }
    }
}

GBACoreHandle* GBA_Create(void) {
    GBACoreHandle* h = new GBACoreHandle();
    h->framebuffer.assign(kPixelCount, 0xFF000000u);
    SetError(h, "");
    return h;
}

void GBA_Destroy(GBACoreHandle* handle) {
    delete handle;
}

void GBA_LoadBuiltInBIOS(GBACoreHandle* handle) {
    if (!handle) return;
    constexpr std::array<const char*, 4> candidates = {
        "utils/bios/ababios.bin",
        "./utils/bios/ababios.bin",
        "ababios.bin",
        "./ababios.bin",
    };

    for (const char* path : candidates) {
        if (GBA_LoadBIOSFromPath(handle, path)) {
            return;
        }
    }

    SetError(handle, "failed to load built-in BIOS candidate");
}

bool GBA_LoadBIOSFromPath(GBACoreHandle* handle, const char* path) {
    if (!handle) return false;
    const auto bytes = LoadFile(path);
    if (bytes.empty()) {
        SetError(handle, "failed to read bios file");
        return false;
    }
    handle->bios_hash = Fnv1a64(bytes);
    handle->has_bios = true;
    SetError(handle, "");
    return true;
}

bool GBA_LoadROMFromPath(GBACoreHandle* handle, const char* path) {
    if (!handle) return false;
    const auto bytes = LoadFile(path);
    if (bytes.empty()) {
        SetError(handle, "failed to load rom");
        return false;
    }
    handle->rom_hash = Fnv1a64(bytes);
    handle->has_rom = true;
    handle->frame_counter = 0;
    RenderFrame(handle);
    SetError(handle, "");
    return true;
}

void GBA_Reset(GBACoreHandle* handle) {
    if (!handle) return;
    if (!handle->has_rom) {
        SetError(handle, "rom not loaded");
        return;
    }
    handle->frame_counter = 0;
    RenderFrame(handle);
    SetError(handle, "");
}

void GBA_StepFrame(GBACoreHandle* handle) {
    if (!handle) return;
    if (!handle->has_rom) {
        SetError(handle, "rom not loaded");
        return;
    }
    ++handle->frame_counter;
    RenderFrame(handle);
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
