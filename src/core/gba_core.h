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

#ifndef GBAEMU_ENABLE_DEBUG_FEATURES
#define GBAEMU_ENABLE_DEBUG_FEATURES 0
#endif

#ifndef GBA_CORE_COMMON_FOUNDATION_DEFINED
#define GBA_CORE_COMMON_FOUNDATION_DEFINED 1

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifndef MAX_GBAS
#define MAX_GBAS 4
#endif

#ifndef GBA_CORE_ENABLE_FULL_SIO_RUNTIME
#define GBA_CORE_ENABLE_FULL_SIO_RUNTIME 1
#endif

struct mTiming;
typedef void (*mTimingCallback)(struct mTiming* timing, void* context, uint32_t cyclesLate);

struct mTimingEvent {
	const char* name;
	uint32_t priority;
	int32_t when;
	void* context;
	mTimingCallback callback;
	struct mTimingEvent* next;
};

struct mTiming {
	struct mTimingEvent* root;
	struct mTimingEvent* reroot;
	int32_t globalCycles;
	int32_t masterCycles;
	int32_t* relativeCycles;
	int32_t* nextEvent;
};

void mTimingSchedule(struct mTiming* timing, struct mTimingEvent* event, int32_t when);
void mTimingDeschedule(struct mTiming* timing, struct mTimingEvent* event);

enum GBASIOMode {
	GBA_SIO_NORMAL_8 = 0,
	GBA_SIO_NORMAL_32 = 1,
	GBA_SIO_MULTI = 2,
	GBA_SIO_UART = 3,
	GBA_SIO_JOYBUS = 8,
	GBA_SIO_GPIO = 12
};

enum GBASIOJOYCommand {
	JOY_CMD_RESET = 0xFF
};

struct GBASIO;

struct GBASIODriver {
	struct GBASIO* p;
	bool (*init)(struct GBASIODriver*);
	void (*deinit)(struct GBASIODriver*);
	void (*reset)(struct GBASIODriver*);
	void (*setMode)(struct GBASIODriver*, enum GBASIOMode);
	bool (*handlesMode)(struct GBASIODriver*, enum GBASIOMode);
	bool (*start)(struct GBASIODriver*);
	int (*connectedDevices)(struct GBASIODriver*);
	int (*deviceId)(struct GBASIODriver*);
	uint16_t (*writeRCNT)(struct GBASIODriver*, uint16_t);
	uint16_t (*writeSIOCNT)(struct GBASIODriver*, uint16_t);
	uint16_t (*writeRegister)(struct GBASIODriver*, uint32_t, uint16_t);
	uint16_t (*readRegister)(struct GBASIODriver*, uint32_t);
	bool (*finishMultiplayer)(struct GBASIODriver*, uint16_t);
};

struct GBASIOPlayer {
	struct GBA* p;
};

struct GBA;

struct GBAMemoryBusMini {
	uint16_t io[0x400];
};

struct GBASIO {
	struct GBA* p;
	struct GBASIODriver* driver;
	uint16_t rcnt;
	uint16_t siocnt;
	enum GBASIOMode mode;
	struct mTimingEvent completeEvent;
	struct GBASIOPlayer gbp;
};

#ifndef GBA_ARM7TDMI_FREQUENCY
#define GBA_ARM7TDMI_FREQUENCY 16777216
#endif

#ifndef VIDEO_TOTAL_LENGTH
#define VIDEO_TOTAL_LENGTH 228
#endif

#ifndef JOY_RESET
#define JOY_RESET 0xFF
#define JOY_POLL  0x00
#define JOY_RECV  0x14
#define JOY_TRANS 0x15
#endif

enum GBASavedataType {
	GBA_SAVEDATA_AUTODETECT = 0,
	GBA_SAVEDATA_EEPROM = 1,
	GBA_SAVEDATA_SRAM = 2,
	GBA_SAVEDATA_FLASH512 = 3,
	GBA_SAVEDATA_FLASH1M = 4
};

enum GBAHardwareDeviceFlags {
	HW_NONE = 0,
	HW_RTC = 1 << 0,
	HW_LIGHT_SENSOR = 1 << 1
};

#ifndef GBA_IDLE_LOOP_NONE
#define GBA_IDLE_LOOP_NONE 0
#endif

typedef int Socket;
struct Address { int unused; };

#ifndef INVALID_SOCKET
#define INVALID_SOCKET (-1)
#endif

#ifndef SOCKET_FAILED
#define SOCKET_FAILED(s) ((s) < 0)
#endif

static inline Socket SocketConnectTCP(short port, const struct Address* address) { UNUSED(port); UNUSED(address); return INVALID_SOCKET; }
static inline void SocketClose(Socket s) { UNUSED(s); }
static inline void SocketSetBlocking(Socket s, bool blocking) { UNUSED(s); UNUSED(blocking); }
static inline void SocketSetTCPPush(Socket s, bool push) { UNUSED(s); UNUSED(push); }
static inline int SocketRecv(Socket s, void* buf, size_t len) { UNUSED(s); UNUSED(buf); UNUSED(len); return -1; }
static inline int SocketSend(Socket s, const void* buf, size_t len) { UNUSED(s); UNUSED(buf); return (int) len; }
static inline void SocketPoll(int nRead, Socket* readSet, int nWrite, Socket* writeSet, int timeoutMs) {
	UNUSED(nRead); UNUSED(readSet); UNUSED(nWrite); UNUSED(writeSet); UNUSED(timeoutMs);
}

static inline uint32_t ntohl(uint32_t v) { return v; }

struct GBASIODolphin {
	struct GBASIODriver d;
	struct mTimingEvent event;
	Socket data;
	Socket clock;
	bool active;
	int32_t clockSlice;
	int state;
};

struct GBA {
	struct mTiming timing;
	struct GBAMemoryBusMini memory;
	struct GBASIO sio;
};

#ifndef RCNT_INITIAL
#define RCNT_INITIAL 0x8000
#endif

static inline void GBASIOPlayerInit(struct GBASIOPlayer* player) { UNUSED(player); }
static inline void GBASIOPlayerReset(struct GBASIOPlayer* player) { UNUSED(player); }

static inline uint16_t GBASIORegisterRCNTSetSi(uint16_t v, bool si) { return si ? (uint16_t) (v | 0x0004) : (uint16_t) (v & ~0x0004); }
static inline uint16_t GBASIORegisterRCNTFillSc(uint16_t v) { return (uint16_t) (v | 0x0002); }
static inline uint16_t GBASIORegisterRCNTClearSc(uint16_t v) { return (uint16_t) (v & ~0x0002); }

static inline int GBASIOTransferCycles(enum GBASIOMode mode, uint16_t siocnt, int connected) {
	UNUSED(mode);
	UNUSED(siocnt);
	UNUSED(connected);
	return 1024;
}

static inline uint16_t GBASIOMultiplayerSetSlave(uint16_t v, bool slave) { return slave ? (uint16_t) (v | 0x0080) : (uint16_t) (v & ~0x0080); }
static inline uint16_t GBASIOMultiplayerSetId(uint16_t v, int id) { return (uint16_t) ((v & ~0x0030) | ((id & 0x3) << 4)); }
static inline bool GBASIOMultiplayerIsBusy(uint16_t v) { return (v & 0x0080) != 0; }
static inline uint16_t GBASIOMultiplayerFillReady(uint16_t v) { return (uint16_t) (v | 0x0008); }
static inline bool GBASIONormalGetSc(uint16_t v) { return (v & 0x0001) != 0; }
static inline bool GBASIONormalIsStart(uint16_t v) { return (v & 0x0080) != 0; }
static inline uint16_t GBASIONormalFillSi(uint16_t v) { return (uint16_t) (v | 0x0004); }
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
