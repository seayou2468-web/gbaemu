#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "./gba_core_c_api.h"

namespace gba {

class GBACore {
public:
    static constexpr int kScreenWidth = 240;
    static constexpr int kScreenHeight = 160;

    GBACore()
        : handle_(GBA_Create()), framebuffer_(static_cast<size_t>(kScreenWidth) * static_cast<size_t>(kScreenHeight), 0) {}

    ~GBACore() {
        if (handle_) {
            GBA_Destroy(handle_);
            handle_ = nullptr;
        }
    }

    bool LoadBIOS(const std::vector<uint8_t>&, std::string* error) {
        if (error) {
            *error = "LoadBIOS(buffer) is not supported; use GBA_LoadBIOSFromPath in host";
        }
        return false;
    }

    void LoadBuiltInBIOS() {
        if (handle_) {
            GBA_LoadBuiltInBIOS(handle_);
        }
    }

    bool LoadROM(const std::vector<uint8_t>&, std::string* warning) {
        if (warning) {
            *warning = "LoadROM(buffer) is not supported in this adapter";
        }
        return false;
    }

    bool LoadROMFromPath(const std::string& path, std::string* warning) {
        if (!handle_) {
            if (warning) *warning = "core handle is null";
            return false;
        }
        const bool ok = GBA_LoadROMFromPath(handle_, path.c_str());
        if (!ok && warning) {
            *warning = GBA_GetLastError(handle_);
        } else if (warning) {
            warning->clear();
        }
        return ok;
    }

    void Reset() {
        if (handle_) {
            GBA_Reset(handle_);
        }
    }

    void StepFrame() {
        if (!handle_) return;
        GBA_StepFrame(handle_);
        size_t n = 0;
        const uint32_t* src = GBA_GetFrameBufferRGBA(handle_, &n);
        if (src && n >= framebuffer_.size()) {
            framebuffer_.assign(src, src + framebuffer_.size());
        }
    }

    const std::vector<uint32_t>& GetFrameBuffer() const {
        return framebuffer_;
    }

    uint64_t ComputeFrameHash() const {
        uint64_t hash = 1469598103934665603ull;
        for (uint32_t px : framebuffer_) {
            hash ^= static_cast<uint64_t>(px);
            hash *= 1099511628211ull;
        }
        return hash;
    }

private:
    GBACoreHandle* handle_;
    std::vector<uint32_t> framebuffer_;
};

}  // namespace gba
