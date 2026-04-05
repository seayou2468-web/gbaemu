#pragma once

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <fstream>
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

    bool LoadBIOS(const std::vector<uint8_t>& bios, std::string* error) {
        if (!handle_) {
            if (error) *error = "core handle is null";
            return false;
        }
        if (bios.empty()) {
            if (error) *error = "bios buffer is empty";
            return false;
        }

        const char* tmp_path = "/tmp/gbaemu_bios.bin";
        std::ofstream out(tmp_path, std::ios::binary);
        out.write(reinterpret_cast<const char*>(bios.data()), static_cast<std::streamsize>(bios.size()));
        out.close();
        if (!out) {
            if (error) *error = "failed to write temporary bios file";
            return false;
        }

        const bool ok = GBA_LoadBIOSFromPath(handle_, tmp_path);
        if (!ok && error) {
            *error = GBA_GetLastError(handle_);
        } else if (error) {
            error->clear();
        }
        std::remove(tmp_path);
        return ok;
    }

    void LoadBuiltInBIOS() {
        if (handle_) {
            GBA_LoadBuiltInBIOS(handle_);
        }
    }

    bool LoadROM(const std::vector<uint8_t>& rom, std::string* warning) {
        if (!handle_) {
            if (warning) *warning = "core handle is null";
            return false;
        }
        if (rom.empty()) {
            if (warning) *warning = "rom buffer is empty";
            return false;
        }

        const char* tmp_path = "/tmp/gbaemu_rom.gba";
        std::ofstream out(tmp_path, std::ios::binary);
        out.write(reinterpret_cast<const char*>(rom.data()), static_cast<std::streamsize>(rom.size()));
        out.close();
        if (!out) {
            if (warning) *warning = "failed to write temporary rom file";
            return false;
        }

        const bool ok = GBA_LoadROMFromPath(handle_, tmp_path);
        if (!ok && warning) {
            *warning = GBA_GetLastError(handle_);
        } else if (warning) {
            warning->clear();
        }
        std::remove(tmp_path);
        return ok;
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
