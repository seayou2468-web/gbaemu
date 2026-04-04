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
#include "./gba_core_modules/module_forward_decls.h"

namespace {
constexpr int kFrameTicks = 280896;
constexpr size_t kPixelCount = 240u * 160u;
uint16_t g_keys = 0;

void InitColorMaps() {
    static bool init = false;
    if (init) return;
    init = true;
    for (int c = 0; c < 0x10000; ++c) {
        const uint8_t r = static_cast<uint8_t>((c & 0x1F) << 3);
        const uint8_t g = static_cast<uint8_t>(((c >> 5) & 0x1F) << 3);
        const uint8_t b = static_cast<uint8_t>(((c >> 10) & 0x1F) << 3);
        systemColorMap8[c] = static_cast<uint8_t>((r + g + b) / 3);
        systemColorMap16[c] = static_cast<uint16_t>((c & 0x1F) | ((c & 0x03E0) << 1) | ((c & 0x7C00) << 1));
        systemColorMap32[c] = 0xFF000000u | (static_cast<uint32_t>(r) << 16) | (static_cast<uint32_t>(g) << 8) | b;
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
uint16_t systemGbPalette[24] = {0};
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

std::unique_ptr<SoundDriver> systemSoundInit() { return std::make_unique<NullSoundDriver>(); }
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

FILE* utilOpenFile(const char* filename, const char* mode) { return std::fopen(filename, mode); }
uint8_t* utilLoad(const char* path, bool (*accept)(const char*), uint8_t* data, int& size) {
    if (!path || !data) return nullptr;
    if (accept && !accept(path)) return nullptr;
    FILE* f = std::fopen(path, "rb");
    if (!f) return nullptr;
    size_t n = std::fread(data, 1, static_cast<size_t>(size), f);
    std::fclose(f);
    size = static_cast<int>(n);
    return data;
}
uint8_t* utilLoadFromStream(gzFile, uint8_t*, int&) { return nullptr; }
bool utilIsGBAImage(const char* file) {
    if (!file) return false;
    const char* ext = std::strrchr(file, '.');
    if (!ext) return false;
    return std::strcmp(ext, ".gba") == 0 || std::strcmp(ext, ".GBA") == 0 ||
           std::strcmp(ext, ".agb") == 0 || std::strcmp(ext, ".AGB") == 0 ||
           std::strcmp(ext, ".bin") == 0 || std::strcmp(ext, ".BIN") == 0;
}

static bool unused_utilIsGBAImage(const char* file) {
    if (!file) return false;
    const char* ext = std::strrchr(file, '.');
    return ext && std::strcmp(ext, ".gba") == 0;
}
bool utilIsGBABios(const char* file) {
    if (!file) return false;
    const char* ext = std::strrchr(file, '.');
    if (!ext) return false;
    return std::strcmp(ext, ".bin") == 0 || std::strcmp(ext, ".BIN") == 0 ||
           std::strcmp(ext, ".bios") == 0 || std::strcmp(ext, ".BIOS") == 0;
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
bool CPUIsGBABios(const char* file) {
    if (!file) return false;
    const char* ext = std::strrchr(file, '.');
    if (!ext) return true;
    return std::strcmp(ext, ".bin") == 0 || std::strcmp(ext, ".BIN") == 0 ||
           std::strcmp(ext, ".bios") == 0 || std::strcmp(ext, ".BIOS") == 0;
}
const char* elfGetAddressSymbol(uint32_t) { return nullptr; }

int SOUND_CLOCK_TICKS = kFrameTicks;
int soundTicks = 0;
void psoundTickfn() {}
void soundEvent8(uint32_t, uint8_t) {}
void soundEvent16(uint32_t, uint16_t) {}
void soundPause() {}
void soundResume() {}
void soundReset() {}
void soundSetThrottle(unsigned short) {}
float soundGetVolume() { return 1.0f; }
void soundSetVolume(float) {}
void soundTimerOverflow(int) {}
void interp_rate() {}

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
    SetError(h, "");
    return h;
}

void GBA_Destroy(GBACoreHandle* handle) {
    if (!handle) return;
    CPUCleanUp();
    std::free(handle);
}

void GBA_LoadBuiltInBIOS(GBACoreHandle* handle) {
    if (!handle) return;
    handle->has_bios = true;
    handle->bios_path[0] = '\0';
    SetError(handle, "");
}

bool GBA_LoadBIOSFromPath(GBACoreHandle* handle, const char* path) {
    if (!handle || !FileExists(path)) {
        SetError(handle, "failed to load bios");
        return false;
    }
    std::snprintf(handle->bios_path, sizeof(handle->bios_path), "%s", path);
    handle->has_bios = true;
    SetError(handle, "");
    return true;
}

bool GBA_LoadROMFromPath(GBACoreHandle* handle, const char* path) {
    if (!handle || !FileExists(path)) {
        SetError(handle, "failed to load rom");
        return false;
    }

    CPUCleanUp();
    int loaded = CPULoadRom(path);
    if (!loaded) {
        SetError(handle, "CPULoadRom failed");
        return false;
    }

    const bool use_bios_file = handle->has_bios && handle->bios_path[0] != '\0';
    CPUInit(use_bios_file ? handle->bios_path : "", use_bios_file);
    CPUReset();

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
    const uint32_t* src = reinterpret_cast<const uint32_t*>(g_pix);
    for (int y = 0; y < 160; ++y) {
        const uint32_t* row = src + (241 * (y + 1));
        std::memcpy(&handle->frame_cache[y * 240], row, 240 * sizeof(uint32_t));
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
