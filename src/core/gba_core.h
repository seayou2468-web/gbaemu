#pragma once

#include "./gba_core_c_api.h"

#ifndef MGBA_EXPORT
#define MGBA_EXPORT
#endif

#ifndef UNUSED
#define UNUSED(x) (void) (x)
#endif

#ifndef ATTRIBUTE_NOINLINE
#define ATTRIBUTE_NOINLINE
#endif

#ifndef mLOG_DEFINE_CATEGORY
#define mLOG_DEFINE_CATEGORY(...)
#endif

#ifndef mLOG
#define mLOG(...)
#endif

#ifdef __cplusplus

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace gba {

class GBACore {
public:
    static constexpr int kScreenWidth = 240;
    static constexpr int kScreenHeight = 160;
    static constexpr std::size_t kPixelCount = static_cast<std::size_t>(kScreenWidth) * static_cast<std::size_t>(kScreenHeight);

    GBACore()
        : handle_(GBA_Create()), framebuffer_(kPixelCount, 0xFF000000u) {}

    ~GBACore() {
        if (handle_ != nullptr) {
            GBA_Destroy(handle_);
            handle_ = nullptr;
        }
    }

    GBACore(const GBACore&) = delete;
    GBACore& operator=(const GBACore&) = delete;

    GBACore(GBACore&& other) noexcept
        : handle_(other.handle_), framebuffer_(std::move(other.framebuffer_)) {
        other.handle_ = nullptr;
    }

    GBACore& operator=(GBACore&& other) noexcept {
        if (this == &other) {
            return *this;
        }
        if (handle_ != nullptr) {
            GBA_Destroy(handle_);
        }
        handle_ = other.handle_;
        framebuffer_ = std::move(other.framebuffer_);
        other.handle_ = nullptr;
        return *this;
    }

    bool LoadBIOS(const std::vector<uint8_t>& bios, std::string* error = nullptr) {
        if (handle_ == nullptr) {
            if (error) *error = "core handle is null";
            return false;
        }
        if (!GBA_LoadBIOSFromBuffer(handle_, bios.data(), bios.size())) {
            if (error) *error = GBA_GetLastError(handle_);
            return false;
        }
        if (error) error->clear();
        return true;
    }

    void LoadBuiltInBIOS() {
        if (handle_ != nullptr) {
            GBA_LoadBuiltInBIOS(handle_);
        }
    }

    bool LoadROM(const std::vector<uint8_t>& rom, std::string* warning = nullptr) {
        if (handle_ == nullptr) {
            if (warning) *warning = "core handle is null";
            return false;
        }
        if (!GBA_LoadROMFromBuffer(handle_, rom.data(), rom.size())) {
            if (warning) *warning = GBA_GetLastError(handle_);
            return false;
        }
        if (warning) warning->clear();
        GBA_Reset(handle_);
        return true;
    }

    void StepFrame() {
        if (handle_ == nullptr) {
            return;
        }
        GBA_StepFrame(handle_);
        const uint32_t* px = GBA_GetFrameBufferRGBA(handle_, nullptr);
        if (px != nullptr) {
            framebuffer_.assign(px, px + kPixelCount);
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

#endif  // __cplusplus
