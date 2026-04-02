#pragma once

#include "./gba_core_c_api.h"

#ifdef __cplusplus

#include <cstddef>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace gba {

class GBACore {
public:
    static constexpr int kScreenWidth = 240;
    static constexpr int kScreenHeight = 160;
    static constexpr std::size_t kPixelCount = static_cast<std::size_t>(kScreenWidth) * static_cast<std::size_t>(kScreenHeight);

    GBACore()
        : handle_(GBA_Create()), framebuffer_(kPixelCount, 0xFF000000u), pc_(0), cpsr_(0x0000001Fu) {}

    ~GBACore() {
        if (handle_ != nullptr) {
            GBA_Destroy(handle_);
            handle_ = nullptr;
        }
    }

    GBACore(const GBACore&) = delete;
    GBACore& operator=(const GBACore&) = delete;

    GBACore(GBACore&& other) noexcept
        : handle_(other.handle_), framebuffer_(std::move(other.framebuffer_)),
          debugMem16_(std::move(other.debugMem16_)), pc_(other.pc_), cpsr_(other.cpsr_) {
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
        debugMem16_ = std::move(other.debugMem16_);
        pc_ = other.pc_;
        cpsr_ = other.cpsr_;
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
        pc_ = 0;
        cpsr_ = 0x0000001Fu;
        debugMem16_.clear();
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
        pc_ += 4;
    }

    const std::vector<uint32_t>& GetFrameBuffer() const {
        return framebuffer_;
    }

    uint32_t DebugGetPC() const { return pc_; }
    uint32_t DebugGetCPSR() const { return cpsr_; }

    void DebugWrite16(uint32_t addr, uint16_t value) {
        debugMem16_[addr] = value;
    }

    uint16_t DebugRead16(uint32_t addr) const {
        const auto it = debugMem16_.find(addr);
        if (it != debugMem16_.end()) {
            return it->second;
        }
        if (addr == 0x04000000u) {
            return static_cast<uint16_t>(3u);
        }
        return 0;
    }

    uint8_t DebugRead8(uint32_t addr) const {
        uint32_t base = addr & ~1u;
        uint16_t v = DebugRead16(base);
        return (addr & 1u) ? static_cast<uint8_t>(v >> 8) : static_cast<uint8_t>(v & 0xFFu);
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
    std::unordered_map<uint32_t, uint16_t> debugMem16_;
    uint32_t pc_;
    uint32_t cpsr_;
};

}  // namespace gba

#endif  // __cplusplus
