#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace gba {

class GBACore {
public:
    static constexpr int kScreenWidth = 240;
    static constexpr int kScreenHeight = 160;

    GBACore()
        : framebuffer_(static_cast<size_t>(kScreenWidth) * static_cast<size_t>(kScreenHeight), 0xFF000000u),
          frame_counter_(0) {}

    bool LoadBIOS(const std::vector<uint8_t>& bios, std::string* error) {
        bios_ = bios;
        if (bios_.empty()) {
            if (error) {
                *error = "empty bios";
            }
            return false;
        }
        return true;
    }

    void LoadBuiltInBIOS() {
        bios_.assign(16, 0);
    }

    bool LoadROM(const std::vector<uint8_t>& rom, std::string* warning) {
        rom_ = rom;
        if (rom_.empty()) {
            if (warning) {
                *warning = "empty rom";
            }
            return false;
        }
        if (warning) {
            warning->clear();
        }
        return true;
    }

    void Reset() {
        frame_counter_ = 0;
        std::fill(framebuffer_.begin(), framebuffer_.end(), 0xFF000000u);
    }

    void StepFrame() {
        ++frame_counter_;
        for (int y = 0; y < kScreenHeight; ++y) {
            for (int x = 0; x < kScreenWidth; ++x) {
                const uint32_t r = static_cast<uint32_t>((x + frame_counter_) & 0xFFu);
                const uint32_t g = static_cast<uint32_t>((y * 2 + frame_counter_) & 0xFFu);
                const uint32_t b = static_cast<uint32_t>(((x ^ y) + (frame_counter_ * 3)) & 0xFFu);
                framebuffer_[static_cast<size_t>(y) * static_cast<size_t>(kScreenWidth) + static_cast<size_t>(x)] =
                    0xFF000000u | (r << 16) | (g << 8) | b;
            }
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
    std::vector<uint8_t> bios_;
    std::vector<uint8_t> rom_;
    std::vector<uint32_t> framebuffer_;
    uint64_t frame_counter_;
};

}  // namespace gba
