#include "./gba_core_c_api.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#if !defined(_WIN32)
#include <strings.h>
#endif

namespace {

constexpr size_t kScreenWidth = 240;
constexpr size_t kScreenHeight = 160;
constexpr size_t kPixelCount = kScreenWidth * kScreenHeight;
constexpr size_t kBiosSize = 0x4000;

struct TinyCPU {
    std::array<uint32_t, 16> regs{};  // r0-r15 (r15=pc)
    uint32_t cpsr = 0;
    uint64_t cycles = 0;

    void reset(uint32_t start_pc) {
        regs.fill(0);
        regs[15] = start_pc;
        cpsr = 0;
        cycles = 0;
    }
};

#if defined(__GNUC__) || defined(__clang__)
#define GBA_MODULE_CPU_BRIDGE_SUPPORTED 1
#define GBA_WEAK __attribute__((weak))
extern "C" {
GBA_WEAK int GBA_ModuleCPU_IsAvailable(void);
GBA_WEAK size_t GBA_ModuleCPU_StateSize(void);
GBA_WEAK void GBA_ModuleCPU_Reset(void* state, uint32_t start_pc);
GBA_WEAK void GBA_ModuleCPU_StepFrame(void* state, const uint8_t* rom, size_t rom_size,
                                      uint32_t rom_hash, uint16_t keys_pressed_mask,
                                      uint32_t steps_per_frame);
}
#else
#define GBA_MODULE_CPU_BRIDGE_SUPPORTED 0
#endif

struct ModuleCPUBridge {
    bool available = false;
    std::vector<uint8_t> state;
};

static void InitModuleBridge(ModuleCPUBridge* bridge) {
    if (!bridge) return;
    bridge->available = false;
    bridge->state.clear();

#if GBA_MODULE_CPU_BRIDGE_SUPPORTED
    if (!GBA_ModuleCPU_IsAvailable || !GBA_ModuleCPU_StateSize || !GBA_ModuleCPU_Reset ||
        !GBA_ModuleCPU_StepFrame) {
        return;
    }
    if (GBA_ModuleCPU_IsAvailable() == 0) {
        return;
    }

    const size_t sz = GBA_ModuleCPU_StateSize();
    if (sz == 0) {
        return;
    }

    bridge->state.assign(sz, 0);
    bridge->available = true;
#endif
}

static void ResetModuleBridge(ModuleCPUBridge* bridge, uint32_t start_pc) {
#if GBA_MODULE_CPU_BRIDGE_SUPPORTED
    if (!bridge || !bridge->available || bridge->state.empty()) return;
    GBA_ModuleCPU_Reset(bridge->state.data(), start_pc);
#else
    (void)bridge;
    (void)start_pc;
#endif
}

static void StepModuleBridge(ModuleCPUBridge* bridge, const uint8_t* rom, size_t rom_size,
                             uint32_t rom_hash, uint16_t keys_pressed_mask,
                             uint32_t steps_per_frame) {
#if GBA_MODULE_CPU_BRIDGE_SUPPORTED
    if (!bridge || !bridge->available || bridge->state.empty() || !rom || rom_size == 0) return;
    GBA_ModuleCPU_StepFrame(bridge->state.data(), rom, rom_size, rom_hash, keys_pressed_mask,
                            steps_per_frame);
#else
    (void)bridge;
    (void)rom;
    (void)rom_size;
    (void)rom_hash;
    (void)keys_pressed_mask;
    (void)steps_per_frame;
#endif
}

static bool ReadAllBytes(const char* path, std::vector<uint8_t>* out) {
    if (!path || !path[0] || !out) return false;
    FILE* fp = std::fopen(path, "rb");
    if (!fp) return false;
    std::fseek(fp, 0, SEEK_END);
    const long size = std::ftell(fp);
    if (size <= 0) {
        std::fclose(fp);
        return false;
    }
    std::fseek(fp, 0, SEEK_SET);
    out->assign(static_cast<size_t>(size), 0);
    const size_t n = std::fread(out->data(), 1, out->size(), fp);
    std::fclose(fp);
    return n == out->size();
}

static bool HasGBAExtension(const char* path) {
    if (!path) return false;
    const char* dot = std::strrchr(path, '.');
    if (!dot) return false;
#if defined(_WIN32)
#define STRCASECMP _stricmp
#else
#define STRCASECMP strcasecmp
#endif
    return STRCASECMP(dot, ".gba") == 0 || STRCASECMP(dot, ".agb") == 0 ||
           STRCASECMP(dot, ".bin") == 0 || STRCASECMP(dot, ".mb") == 0 ||
           STRCASECMP(dot, ".elf") == 0;
#undef STRCASECMP
}

static uint32_t FastHash32(const uint8_t* data, size_t size) {
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < size; ++i) {
        h ^= data[i];
        h *= 16777619u;
    }
    return h;
}

}  // namespace

extern "C" {

struct GBACoreHandle {
    char last_error[256];

    bool has_bios = false;
    bool use_builtin_bios = false;
    bool has_rom = false;

    std::vector<uint8_t> bios;
    std::vector<uint8_t> rom;

    TinyCPU cpu;
    ModuleCPUBridge module_bridge;

    uint16_t keys_pressed_mask = 0;
    uint32_t rom_hash = 0;
    uint32_t frame_counter = 0;

    std::vector<uint32_t> framebuffer;
};

static void SetError(GBACoreHandle* h, const char* msg) {
    if (!h) return;
    std::snprintf(h->last_error, sizeof(h->last_error), "%s", msg ? msg : "");
}

GBACoreHandle* GBA_Create(void) {
    GBACoreHandle* h = new GBACoreHandle();
    h->framebuffer.assign(kPixelCount, 0xFF000000u);
    h->cpu.reset(0);
    InitModuleBridge(&h->module_bridge);
    SetError(h, "");
    return h;
}

void GBA_Destroy(GBACoreHandle* handle) {
    delete handle;
}

void GBA_LoadBuiltInBIOS(GBACoreHandle* handle) {
    if (!handle) return;
    handle->bios.clear();
    handle->has_bios = true;
    handle->use_builtin_bios = true;
    SetError(handle, "");
}

bool GBA_LoadBIOSFromPath(GBACoreHandle* handle, const char* path) {
    if (!handle) return false;
    std::vector<uint8_t> tmp;
    if (!ReadAllBytes(path, &tmp)) {
        SetError(handle, "failed to read bios file");
        return false;
    }
    if (tmp.size() != kBiosSize) {
        SetError(handle, "invalid bios size (expected 16384 bytes)");
        return false;
    }
    handle->bios = std::move(tmp);
    handle->has_bios = true;
    handle->use_builtin_bios = false;
    SetError(handle, "");
    return true;
}

bool GBA_LoadROMFromPath(GBACoreHandle* handle, const char* path) {
    if (!handle) return false;
    if (!HasGBAExtension(path)) {
        SetError(handle, "unsupported rom extension");
        return false;
    }

    std::vector<uint8_t> tmp;
    if (!ReadAllBytes(path, &tmp)) {
        SetError(handle, "failed to read rom file");
        return false;
    }

    handle->rom = std::move(tmp);
    handle->rom_hash = FastHash32(handle->rom.data(), handle->rom.size());
    handle->has_rom = true;
    handle->frame_counter = 0;

    const uint32_t start_pc = (handle->has_bios && !handle->use_builtin_bios) ? 0x00000000u : 0x08000000u;
    handle->cpu.reset(start_pc);
    ResetModuleBridge(&handle->module_bridge, start_pc);

    SetError(handle, "");
    return true;
}

void GBA_Reset(GBACoreHandle* handle) {
    if (!handle) return;
    if (!handle->has_rom) {
        SetError(handle, "rom not loaded");
        return;
    }
    const uint32_t start_pc = (handle->has_bios && !handle->use_builtin_bios) ? 0x00000000u : 0x08000000u;
    handle->cpu.reset(start_pc);
    ResetModuleBridge(&handle->module_bridge, start_pc);
    handle->frame_counter = 0;
    SetError(handle, "");
}

void GBA_StepFrame(GBACoreHandle* handle) {
    if (!handle) return;
    if (!handle->has_rom) {
        SetError(handle, "rom not loaded");
        return;
    }

    constexpr uint32_t kStepsPerFrame = 50000;
    const size_t rom_size = handle->rom.size();

    for (uint32_t i = 0; i < kStepsPerFrame; ++i) {
        const uint32_t pc = handle->cpu.regs[15];
        const size_t idx = static_cast<size_t>(pc % rom_size);

        uint32_t opcode = 0;
        for (int b = 0; b < 4; ++b) {
            opcode |= static_cast<uint32_t>(handle->rom[(idx + static_cast<size_t>(b)) % rom_size]) << (8u * static_cast<uint32_t>(b));
        }

        const uint32_t major = opcode >> 28;
        const uint32_t rd = (opcode >> 12) & 0xF;
        const uint32_t rn = (opcode >> 16) & 0xF;
        const uint32_t rm = opcode & 0xF;

        switch (major) {
            case 0x0:  // nop
                break;
            case 0x1:  // add
                handle->cpu.regs[rd] = handle->cpu.regs[rn] + handle->cpu.regs[rm] + (opcode & 0xFF);
                break;
            case 0x2:  // xor
                handle->cpu.regs[rd] = handle->cpu.regs[rn] ^ (handle->cpu.regs[rm] + (opcode & 0xFFFF));
                break;
            case 0x3:  // move immediate
                handle->cpu.regs[rd] = opcode & 0x00FFFFFFu;
                break;
            case 0x4: {  // tiny branch
                int8_t rel = static_cast<int8_t>(opcode & 0xFF);
                handle->cpu.regs[15] = pc + 4u + static_cast<int32_t>(rel) * 4;
                continue;
            }
            default:
                handle->cpu.regs[rd] += (opcode ^ handle->rom_hash);
                break;
        }

        // iOS入力マスクをCPU状態に反映
        handle->cpu.regs[0] ^= static_cast<uint32_t>(~handle->keys_pressed_mask) & 0x03FFu;

        handle->cpu.regs[15] = pc + 4u;
        handle->cpu.cycles += 1;
    }

    // 現在の tiny CPU を主実装として維持しつつ、外部CPU実装があれば同一入力で進める。
    StepModuleBridge(&handle->module_bridge, handle->rom.data(), handle->rom.size(),
                     handle->rom_hash, handle->keys_pressed_mask, kStepsPerFrame);

    // --- software framebuffer generation (external dependency free) ---
    const uint32_t t = ++handle->frame_counter;
    const uint32_t r0 = handle->cpu.regs[0];
    const uint32_t r1 = handle->cpu.regs[1];
    const uint32_t r2 = handle->cpu.regs[2];

    for (size_t y = 0; y < kScreenHeight; ++y) {
        for (size_t x = 0; x < kScreenWidth; ++x) {
            const size_t p = y * kScreenWidth + x;
            const uint8_t rr = static_cast<uint8_t>((x + (r0 >> 3) + (t & 0xFF)) & 0xFFu);
            const uint8_t gg = static_cast<uint8_t>((y + (r1 >> 5) + ((t * 3) & 0xFF)) & 0xFFu);
            const uint8_t bb = static_cast<uint8_t>(((x ^ y) + (r2 >> 7) + (handle->rom_hash & 0xFF)) & 0xFFu);
            handle->framebuffer[p] = 0xFF000000u | (static_cast<uint32_t>(rr) << 16u) |
                                     (static_cast<uint32_t>(gg) << 8u) | static_cast<uint32_t>(bb);
        }
    }

    SetError(handle, "");
}

void GBA_SetKeys(GBACoreHandle* handle, uint16_t keys_pressed_mask) {
    if (!handle) return;
    handle->keys_pressed_mask = keys_pressed_mask;
}

bool GBA_IsModuleCPUBridgeActive(GBACoreHandle* handle) {
    return handle ? handle->module_bridge.available : false;
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
