#include "./gba_core_c_api.h"

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "./embedded_include/base/file_util.h"
#include "./embedded_include/base/image_util.h"
#include "./embedded_include/base/message.h"
#include "./embedded_include/base/system.h"
#include "./embedded_include/gba/gba.h"
#include "./embedded_include/gba/gbaGlobals.h"
#include "./embedded_include/gba/gbaLink.h"
#include "./embedded_include/gba/gbaSound.h"
#include "./gba_core_modules/module_forward_decls.h"

#if defined(_MSC_VER)
#define strcasecmp _stricmp
#else
#include <strings.h>
#endif

namespace {
constexpr int kFrameTicks = 280896;
constexpr size_t kPixelCount = 240u * 160u;
uint16_t g_keys = 0x0000;
#if defined(__LIBRETRO__)
constexpr int kFrameStride32 = 240;
constexpr int kFrameOffset32 = 0;
#else
constexpr int kFrameStride32 = 241;
constexpr int kFrameOffset32 = 1;
#endif

void InitColorMaps() {
    static bool init = false;
    if (init) return;
    init = true;
    int c = 0;
    for (; c < 0x10000; ++c) {
        systemColorMap8[c] = static_cast<uint8_t>((((c & 0x1f) << 3) & 0xE0) |
                                                  ((((c & 0x3e0) >> 5) << 0) & 0x1C) |
                                                  ((((c & 0x7c00) >> 10) >> 3) & 0x03));
        systemColorMap16[c] = static_cast<uint16_t>(((c & 0x1f) << systemRedShift) |
                                                     (((c & 0x3e0) >> 5) << systemGreenShift) |
                                                     (((c & 0x7c00) >> 10) << systemBlueShift));
        systemColorMap32[c] = ((c & 0x1f) << systemRedShift) |
                              (((c & 0x3e0) >> 5) << systemGreenShift) |
                              (((c & 0x7c00) >> 10) << systemBlueShift);
    }
}

bool FileExists(const char* path) {
    if (!path || !path[0]) return false;
    FILE* f = std::fopen(path, "rb");
    if (!f) return false;
    std::fclose(f);
    return true;
}

}  // namespace

// ---- frontend stubs required by embedded core ----
CoreOptions coreOptions;
int emulating = 0;
int systemRedShift = 19;
int systemGreenShift = 11;
int systemBlueShift = 3;
int systemColorDepth = 32;
int systemVerbose = 0;
int systemFrameSkip = 0;
int systemSaveUpdateCounter = SYSTEM_SAVE_NOT_UPDATED;
int systemSpeed = 0;
uint8_t systemColorMap8[0x10000];
uint16_t systemColorMap16[0x10000];
uint32_t systemColorMap32[0x10000];
uint16_t systemGbPalette[24] = {
    0x7FFF, 0x56B5, 0x318C, 0,
    0x7FFF, 0x56B5, 0x318C, 0,
    0x7FFF, 0x56B5, 0x318C, 0,
    0x7FFF, 0x56B5, 0x318C, 0,
    0x7FFF, 0x56B5, 0x318C, 0,
    0x7FFF, 0x56B5, 0x318C, 0,
};
void (*dbgOutput)(const char* s, uint32_t addr) = nullptr;
void (*dbgSignal)(int sig, int number) = nullptr;

void log(const char*, ...) {}
void systemMessage(int, const char*, ...) {}
bool systemPauseOnFrame() { return false; }
void systemGbPrint(uint8_t*, int, int, int, int, int) {}
void systemScreenCapture(int) {}
void systemDrawScreen() {}
void systemSendScreen() {}
bool systemReadJoypads() { return true; }
uint32_t systemReadJoypad(int) { return g_keys; }
uint32_t systemGetClock() { return 0; }
void systemSetTitle(const char*) {}

class NullSoundDriver : public SoundDriver {
public:
    bool init(long) override { return true; }
    void pause() override {}
    void reset() override {}
    void resume() override {}
    void write(uint16_t*, int) override {}
    void setThrottle(unsigned short) override {}
};

std::unique_ptr<SoundDriver> systemSoundInit() { return std::unique_ptr<SoundDriver>(new NullSoundDriver()); }
void systemOnWriteDataToSoundBuffer(const uint16_t*, int) {}
void systemOnSoundShutdown() {}
void systemScreenMessage(const char*) {}
void systemUpdateMotionSensor() {}
int systemGetSensorX() { return 0; }
int systemGetSensorY() { return 0; }
int systemGetSensorZ() { return 0; }
uint8_t systemGetSensorDarkness() { return 0; }
void systemCartridgeRumble(bool) {}
void systemPossibleCartridgeRumble(bool) {}
void updateRumbleFrame() {}
bool systemCanChangeSoundQuality() { return false; }
void systemShowSpeed(int) {}
void system10Frames() {}
void systemFrame() {}
void systemGbBorderOn() {}

bool utilIsGBAImage(const char* file);

FILE* utilOpenFile(const char* filename, const char* mode) { return std::fopen(filename, mode); }
uint8_t* utilLoad(const char* path, bool (*accept)(const char*), uint8_t* data, int& size) {
    if (!path || !data) return nullptr;
    FILE* f = std::fopen(path, "rb");
    if (!f) return nullptr;
    size_t n = std::fread(data, 1, static_cast<size_t>(size), f);
    std::fclose(f);
    if (accept && !accept(path)) {
        if (!(accept == utilIsGBAImage && n >= 0xC0)) {
            return nullptr;
        }
    }
    size = static_cast<int>(n);
    return data;
}
uint8_t* utilLoadFromStream(gzFile, uint8_t*, int&) { return nullptr; }
bool utilIsGBAImage(const char* file) {
    coreOptions.cpuIsMultiBoot = false;
    if (!file) return false;
    if (std::strlen(file) <= 4) return false;
    const char* ext = std::strrchr(file, '.');
    if (!ext) return false;
    if ((strcasecmp(ext, ".agb") == 0) || (strcasecmp(ext, ".gba") == 0) ||
        (strcasecmp(ext, ".bin") == 0) || (strcasecmp(ext, ".elf") == 0)) {
        return true;
    }
    if (strcasecmp(ext, ".mb") == 0) {
        coreOptions.cpuIsMultiBoot = true;
        return true;
    }
    return false;
}
bool utilIsGBABios(const char* file) {
    if (!file || !file[0]) return false;
    FILE* f = std::fopen(file, "rb");
    if (!f) return false;
    std::fseek(f, 0, SEEK_END);
    const long size = std::ftell(f);
    std::fclose(f);
    return size == 0x4000;
}
bool utilWritePNGFile(const char*, int, int, uint8_t*) { return false; }
bool utilWriteBMPFile(const char*, int, int, uint8_t*) { return false; }
void utilWriteData(gzFile, variable_desc*) {}
void utilReadData(gzFile, variable_desc*) {}
void utilReadDataSkip(gzFile, variable_desc*) {}
void utilWriteInt(gzFile, int) {}
int utilReadInt(gzFile) { return 0; }
int utilGzWrite(gzFile, const voidp, unsigned int) { return 0; }
int utilGzRead(gzFile, voidp, unsigned int) { return 0; }
z_off_t utilGzSeek(gzFile, z_off_t, int) { return 0; }

bool agbPrintWrite(uint32_t, uint16_t) { return false; }
void agbPrintFlush() {}
void agbPrintEnable(bool) {}
bool CPUIsGBABios(const char* file) { return utilIsGBABios(file); }
const char* elfGetAddressSymbol(uint32_t) { return nullptr; }

int cheatsCheckKeys(uint32_t, uint32_t) { return 0; }
void StartLink(uint16_t) {}
void StartGPLink(uint16_t) {}
LinkMode GetLinkMode() { return LINK_DISCONNECTED; }
void LinkUpdate(int) {}
void CheckLinkConnection() {}

bool CPUReadBatteryFile(const char*) { return false; }
bool CPUWriteBatteryFile(const char*) { return false; }
bool CPUReadState(const char*) { return false; }
bool CPUWriteState(const char*) { return false; }
bool CPUReadMemState(char*, int) { return false; }
bool CPUWriteMemState(char*, int) { return false; }
bool CPUWritePNGFile(const char*) { return false; }
bool CPUWriteBMPFile(const char*) { return false; }

extern "C" {

struct GBACoreHandle {
    char last_error[256];
    char bios_path[1024];
    char rom_path[1024];
    uint16_t keys_pressed;
    bool has_bios;
    bool has_rom;
    bool bios_boot_watchdog;
    int bios_boot_frames;
    uint32_t frame_cache[240 * 160];
};

static void SetError(GBACoreHandle* h, const char* msg) {
    if (!h) return;
    std::snprintf(h->last_error, sizeof(h->last_error), "%s", msg ? msg : "");
}

GBACoreHandle* GBA_Create(void) {
    InitColorMaps();
    GBACoreHandle* h = static_cast<GBACoreHandle*>(std::calloc(1, sizeof(GBACoreHandle)));
    if (!h) return nullptr;
    h->bios_path[0] = '\0';
    h->rom_path[0] = '\0';
    h->keys_pressed = 0x0000;
    SetError(h, "");
    return h;
}

void GBA_Destroy(GBACoreHandle* handle) {
    if (!handle) return;
    soundShutdown();
    CPUCleanUp();
    std::free(handle);
}

void GBA_LoadBuiltInBIOS(GBACoreHandle* handle) {
    if (!handle) return;
    if (handle->has_rom) {
        SetError(handle, "bios must be set before rom load");
        return;
    }
    handle->bios_path[0] = '\0';
    handle->has_bios = true;
    SetError(handle, "");
}

bool GBA_LoadBIOSFromPath(GBACoreHandle* handle, const char* path) {
    if (!handle || !FileExists(path) || !utilIsGBABios(path)) {
        SetError(handle, "failed to load bios");
        return false;
    }
    if (handle->has_rom) {
        SetError(handle, "bios must be set before rom load");
        return false;
    }
    std::snprintf(handle->bios_path, sizeof(handle->bios_path), "%s", path);
    handle->has_bios = true;
    SetError(handle, "");
    return true;
}

bool GBA_LoadROMFromPath(GBACoreHandle* handle, const char* path) {
    if (!handle || !path || !path[0] || !FileExists(path)) {
        SetError(handle, "failed to load rom");
        return false;
    }
    if (!utilIsGBAImage(path)) {
        SetError(handle, "unsupported rom format");
        return false;
    }

    soundShutdown();
    CPUCleanUp();
    int loaded = CPULoadRom(path);
    if (!loaded) {
        handle->has_rom = false;
        handle->rom_path[0] = '\0';
        SetError(handle, "CPULoadRom failed");
        return false;
    }

    const bool use_bios_file = handle->has_bios && handle->bios_path[0] != '\0';
    CPUInit(use_bios_file ? handle->bios_path : "", use_bios_file);
    soundInit();
    CPUReset();
    handle->bios_boot_watchdog = use_bios_file;
    handle->bios_boot_frames = 0;

    std::snprintf(handle->rom_path, sizeof(handle->rom_path), "%s", path);
    handle->has_rom = true;
    SetError(handle, "");
    return true;
}

void GBA_Reset(GBACoreHandle* handle) {
    if (!handle || !handle->has_rom) {
        if (handle) SetError(handle, "rom not loaded");
        return;
    }
    CPUReset();
    SetError(handle, "");
}

void GBA_StepFrame(GBACoreHandle* handle) {
    if (!handle || !handle->has_rom) {
        if (handle) SetError(handle, "rom not loaded");
        return;
    }
    g_keys = handle->keys_pressed;
    GBAEmulate(kFrameTicks);

    if (handle->bios_boot_watchdog) {
        if (reg[15].I >= 0x08000000u) {
            handle->bios_boot_watchdog = false;
        } else if (++handle->bios_boot_frames >= 300) {
            coreOptions.useBios = false;
            CPUReset();
            handle->bios_boot_watchdog = false;
        }
    }

    SetError(handle, "");
}

void GBA_SetKeys(GBACoreHandle* handle, uint16_t keys_pressed_mask) {
    if (!handle) return;
    handle->keys_pressed = keys_pressed_mask;
}

size_t GBA_GetFrameBufferSize(GBACoreHandle*) { return kPixelCount; }

const uint32_t* GBA_GetFrameBufferRGBA(GBACoreHandle* handle, size_t* out_size) {
    if (!handle || !g_pix) {
        if (out_size) *out_size = 0;
        return nullptr;
    }

    switch (systemColorDepth) {
    case 8: {
        const uint8_t* src = reinterpret_cast<const uint8_t*>(g_pix);
#ifdef __LIBRETRO__
        constexpr int kStride = 240;
#else
        constexpr int kStride = 244;
#endif
        for (int y = 0; y < 160; ++y) {
            const uint8_t* row = src + (kStride * (y + kFrameOffset32));
            for (int x = 0; x < 240; ++x) {
                const uint8_t v = row[x];
                // systemColorMap8 stores RGB332-like packed color.
                uint8_t r = static_cast<uint8_t>(v & 0xE0);
                uint8_t g = static_cast<uint8_t>((v & 0x1C) << 3);
                uint8_t b = static_cast<uint8_t>((v & 0x03) << 6);
                // Bit replication to better expand to 8-bit channels.
                r |= static_cast<uint8_t>(r >> 3);
                g |= static_cast<uint8_t>(g >> 3);
                b |= static_cast<uint8_t>(b >> 2);
                handle->frame_cache[y * 240 + x] = 0xFF000000u | (static_cast<uint32_t>(r) << 16) |
                    (static_cast<uint32_t>(g) << 8) | b;
            }
        }
        break;
    }
    case 16: {
        const uint16_t* src = reinterpret_cast<const uint16_t*>(g_pix);
#ifdef __LIBRETRO__
        constexpr int kStride = 240;
#else
        constexpr int kStride = 242;
#endif
        for (int y = 0; y < 160; ++y) {
            const uint16_t* row = src + (kStride * (y + kFrameOffset32));
            for (int x = 0; x < 240; ++x) {
                const uint16_t c = row[x];
                const uint8_t r = static_cast<uint8_t>((c & 0x1F) << 3);
                const uint8_t g = static_cast<uint8_t>(((c >> 5) & 0x1F) << 3);
                const uint8_t b = static_cast<uint8_t>(((c >> 10) & 0x1F) << 3);
                handle->frame_cache[y * 240 + x] = 0xFF000000u | (static_cast<uint32_t>(r) << 16) |
                    (static_cast<uint32_t>(g) << 8) | b;
            }
        }
        break;
    }
    case 24: {
        const uint8_t* src = reinterpret_cast<const uint8_t*>(g_pix);
        constexpr int kStride = 240 * 3;
        // Sync with core write path: 24-bit mode uses (VCOUNT + 1) layout
        // regardless of __LIBRETRO__.
        constexpr int kOffsetRows = 1;
        for (int y = 0; y < 160; ++y) {
            const uint8_t* row = src + (kStride * (y + kOffsetRows));
            for (int x = 0; x < 240; ++x) {
                const uint8_t b = row[x * 3 + 0];
                const uint8_t g = row[x * 3 + 1];
                const uint8_t r = row[x * 3 + 2];
                handle->frame_cache[y * 240 + x] = 0xFF000000u | (static_cast<uint32_t>(r) << 16) |
                    (static_cast<uint32_t>(g) << 8) | b;
            }
        }
        break;
    }
    case 32:
    default: {
        const uint32_t* src = reinterpret_cast<const uint32_t*>(g_pix);
        for (int y = 0; y < 160; ++y) {
            const uint32_t* row = src + (kFrameStride32 * (y + kFrameOffset32));
            for (int x = 0; x < 240; ++x) {
                handle->frame_cache[y * 240 + x] = 0xFF000000u | (row[x] & 0x00FFFFFFu);
            }
        }
        break;
    }
    }

    if (out_size) *out_size = kPixelCount;
    return handle->frame_cache;
}

bool GBA_CopyFrameBufferRGBA(GBACoreHandle* handle, uint32_t* out_pixels, size_t out_size) {
    if (!handle || !out_pixels || out_size < kPixelCount) return false;
    size_t n = 0;
    const uint32_t* frame = GBA_GetFrameBufferRGBA(handle, &n);
    if (!frame || n < kPixelCount) return false;
    std::memcpy(out_pixels, frame, kPixelCount * sizeof(uint32_t));
    return true;
}

const char* GBA_GetLastError(GBACoreHandle* handle) {
    if (!handle) return "invalid handle";
    return handle->last_error;
}

}  // extern "C"
