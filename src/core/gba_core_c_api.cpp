#include "./gba_core_c_api.h"

#include <algorithm>
#include <array>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {
constexpr size_t kScreenWidth = 240;
constexpr size_t kScreenHeight = 160;
constexpr size_t kPixels = kScreenWidth * kScreenHeight;

struct GBACoreHandleImpl {
    std::array<uint32_t, kPixels> frame{};
    std::vector<uint8_t> rom;
    std::vector<uint8_t> bios;
    std::string romPath;
    std::string biosPath;
    std::string lastError;
    uint64_t frameCounter = 0;
    uint16_t keys = 0;
    bool hasRom = false;
    bool hasBios = false;
};

static bool loadFile(const char* path, std::vector<uint8_t>& out, std::string& err) {
    if (!path || !path[0]) {
        err = "path is empty";
        return false;
    }
    FILE* f = std::fopen(path, "rb");
    if (!f) {
        err = "failed to open file";
        return false;
    }
    if (std::fseek(f, 0, SEEK_END) != 0) {
        std::fclose(f);
        err = "failed to seek file";
        return false;
    }
    long sz = std::ftell(f);
    if (sz < 0) {
        std::fclose(f);
        err = "failed to tell file size";
        return false;
    }
    std::rewind(f);
    out.resize(static_cast<size_t>(sz));
    if (!out.empty()) {
        size_t n = std::fread(out.data(), 1, out.size(), f);
        if (n != out.size()) {
            std::fclose(f);
            err = "failed to read file";
            return false;
        }
    }
    std::fclose(f);
    return true;
}

static inline uint32_t rgb(uint8_t r, uint8_t g, uint8_t b) {
    return 0xFF000000u | (uint32_t(r) << 16) | (uint32_t(g) << 8) | uint32_t(b);
}

static void renderDummyFrame(GBACoreHandleImpl& h) {
    const uint8_t phase = static_cast<uint8_t>(h.frameCounter & 0xFF);
    for (size_t y = 0; y < kScreenHeight; ++y) {
        for (size_t x = 0; x < kScreenWidth; ++x) {
            uint8_t r = static_cast<uint8_t>((x + phase) & 0xFF);
            uint8_t g = static_cast<uint8_t>((y + (phase / 2)) & 0xFF);
            uint8_t b = static_cast<uint8_t>((x ^ y ^ phase) & 0xFF);
            if (h.keys & 0x0001) {
                r = static_cast<uint8_t>(255 - r);
            }
            h.frame[y * kScreenWidth + x] = rgb(r, g, b);
        }
    }
}
}

struct GBACoreHandle {
    GBACoreHandleImpl impl;
};

extern "C" {
GBACoreHandle* GBA_Create(void) {
    return new GBACoreHandle();
}

void GBA_Destroy(GBACoreHandle* handle) {
    delete handle;
}

bool GBA_LoadROMFromPath(GBACoreHandle* handle, const char* path) {
    if (!handle) {
        return false;
    }
    handle->impl.lastError.clear();
    if (!loadFile(path, handle->impl.rom, handle->impl.lastError)) {
        handle->impl.hasRom = false;
        return false;
    }
    handle->impl.romPath = path;
    handle->impl.hasRom = true;
    return true;
}

bool GBA_LoadBIOSFromPath(GBACoreHandle* handle, const char* path) {
    if (!handle) {
        return false;
    }
    handle->impl.lastError.clear();
    if (!loadFile(path, handle->impl.bios, handle->impl.lastError)) {
        handle->impl.hasBios = false;
        return false;
    }
    handle->impl.biosPath = path;
    handle->impl.hasBios = true;
    return true;
}

void GBA_LoadBuiltInBIOS(GBACoreHandle* handle) {
    if (!handle) {
        return;
    }
    handle->impl.bios.assign(16 * 1024, 0);
    handle->impl.biosPath = "builtin";
    handle->impl.hasBios = true;
    handle->impl.lastError.clear();
}

void GBA_Reset(GBACoreHandle* handle) {
    if (!handle) {
        return;
    }
    handle->impl.frameCounter = 0;
    std::fill(handle->impl.frame.begin(), handle->impl.frame.end(), 0xFF000000u);
    handle->impl.lastError.clear();
}

void GBA_StepFrame(GBACoreHandle* handle) {
    if (!handle) {
        return;
    }
    if (!handle->impl.hasRom) {
        handle->impl.lastError = "ROM is not loaded";
        return;
    }
    if (!handle->impl.hasBios) {
        handle->impl.lastError = "BIOS is not loaded";
        return;
    }
    ++handle->impl.frameCounter;
    renderDummyFrame(handle->impl);
    handle->impl.lastError.clear();
}

void GBA_SetKeys(GBACoreHandle* handle, uint16_t keysPressedMask) {
    if (!handle) {
        return;
    }
    handle->impl.keys = keysPressedMask;
}

const uint32_t* GBA_GetFrameBufferRGBA(GBACoreHandle* handle, size_t* pixelCount) {
    if (pixelCount) {
        *pixelCount = handle ? kPixels : 0;
    }
    if (!handle) {
        return nullptr;
    }
    return handle->impl.frame.data();
}

size_t GBA_GetFrameBufferSize(GBACoreHandle* handle) {
    return handle ? kPixels : 0;
}

bool GBA_CopyFrameBufferRGBA(GBACoreHandle* handle, uint32_t* dst, size_t pixels) {
    if (!handle || !dst || pixels < kPixels) {
        return false;
    }
    std::memcpy(dst, handle->impl.frame.data(), kPixels * sizeof(uint32_t));
    return true;
}

const char* GBA_GetLastError(GBACoreHandle* handle) {
    static const char* kNull = "core handle is null";
    if (!handle) {
        return kNull;
    }
    return handle->impl.lastError.c_str();
}
}
