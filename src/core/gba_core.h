#pragma once

#include "./gba_core_c_api.h"

#ifndef MGBA_EXPORT
#define MGBA_EXPORT
#endif

#ifndef UNUSED
#define UNUSED(x) (void) (x)
#endif

#if !defined(__cplusplus) && !defined(static_assert)
#define static_assert _Static_assert
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

#ifndef GBA_CORE_COMMON_FOUNDATION_DEFINED
#define GBA_CORE_COMMON_FOUNDATION_DEFINED 1

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <sys/types.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <time.h>

#ifndef MAX_GBAS
#define MAX_GBAS 4
#endif

#ifndef GBA_CORE_ENABLE_FULL_SIO_RUNTIME
#define GBA_CORE_ENABLE_FULL_SIO_RUNTIME 1
#endif

struct mTiming;
typedef void (*mTimingCallback)(struct mTiming* timing, void* context, uint32_t cyclesLate);

enum mPlatform { mPLATFORM_GBA = 1 };
enum mCoreFeature { mCORE_FEATURE_OPENGL = 1 };
enum mCoreChecksumType { mCHECKSUM_CRC32 = 0, mCHECKSUM_MD5 = 1, mCHECKSUM_SHA1 = 2 };

struct Configuration;
const char* ConfigurationGetValue(const struct Configuration* config, const char* section, const char* key);
void ConfigurationSetValue(struct Configuration* config, const char* section, const char* key, const char* value);
void ConfigurationSetIntValue(struct Configuration* config, const char* section, const char* key, int value);
void ConfigurationSetUIntValue(struct Configuration* config, const char* section, const char* key, uint32_t value);
void ConfigurationClearValue(struct Configuration* config, const char* section, const char* key);

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
void mTimingScheduleAbsolute(struct mTiming* timing, struct mTimingEvent* event, int32_t when);
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
struct GBASIOPlayer;
struct mKeyCallback {
	uint16_t (*readKeys)(struct mKeyCallback*);
	bool requireOpposingDirections;
};

struct GBASIOPlayerKeyCallback {
	struct mKeyCallback d;
	struct GBASIOPlayer* p;
};

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
	uint16_t (*finishNormal8)(struct GBASIODriver*);
	uint32_t (*finishNormal32)(struct GBASIODriver*);
	bool (*finishMultiplayer)(struct GBASIODriver*, uint16_t out[4]);
	uint32_t (*driverId)(struct GBASIODriver*);
	bool (*loadState)(struct GBASIODriver*, const void*, size_t);
	void (*saveState)(struct GBASIODriver*, void**, size_t*);
};

struct GBASIOPlayer {
	struct GBASIODriver d;
	struct GBASIOPlayerKeyCallback callback;
	struct GBA* p;
	int inputsPosted;
	struct mKeyCallback* oldCallback;
	int txPosition;
};

struct GBA;
struct GBASavedata;
struct GBAHardware;
struct GBACartEReader;
struct VFile;
struct ARMCore;
struct GBATimer;
struct GBADMA;
struct GBAVideo;
struct GBAVideoSoftwareBackground;
struct GBAObj;
struct mCoreSync;

enum {
	GBA_REGION_BIOS = 0,
	GBA_REGION_EWRAM = 2,
	GBA_REGION_IWRAM = 3,
	GBA_REGION_IO = 4,
	GBA_REGION_PALETTE_RAM = 5,
	GBA_REGION_VRAM = 6,
	GBA_REGION_OAM = 7,
	GBA_REGION_ROM0 = 8,
	GBA_REGION_ROM1 = 9,
	GBA_REGION_ROM2 = 10,
	GBA_REGION_SRAM = 14,
	GBA_REGION_SRAM_MIRROR = 15
};

#define GBA_BASE_BIOS 0x00000000u
#define GBA_BASE_EWRAM 0x02000000u
#define GBA_BASE_IWRAM 0x03000000u
#define GBA_BASE_IO 0x04000000u
#define GBA_BASE_PALETTE_RAM 0x05000000u
#define GBA_BASE_VRAM 0x06000000u
#define GBA_BASE_OAM 0x07000000u
#define GBA_BASE_ROM0 0x08000000u
#define GBA_BASE_ROM1 0x0A000000u
#define GBA_BASE_ROM2 0x0C000000u
#define GBA_BASE_SRAM 0x0E000000u

#define GBA_SIZE_BIOS 0x00004000u
#define GBA_SIZE_EWRAM 0x00040000u
#define GBA_SIZE_IWRAM 0x00008000u
#define GBA_SIZE_IO 0x00000400u
#define GBA_SIZE_PALETTE_RAM 0x00000400u
#define GBA_SIZE_VRAM 0x00018000u
#define GBA_SIZE_OAM 0x00000400u
#define GBA_SIZE_ROM0 0x02000000u
#define GBA_SIZE_ROM1 0x02000000u
#define GBA_SIZE_ROM2 0x02000000u
#define GBA_SIZE_SRAM 0x00008000u
#define GBA_SIZE_SRAM512 0x00010000u
#define GBA_SIZE_FLASH512 0x00010000u
#define GBA_SIZE_FLASH1M 0x00020000u
#define GBA_SIZE_EEPROM 0x00002000u
#define GBA_SIZE_EEPROM512 0x00000200u

enum {
	mCORE_MEMORY_RW = 1 << 0,
	mCORE_MEMORY_READ = 1 << 1,
	mCORE_MEMORY_MAPPED = 1 << 2,
	mCORE_MEMORY_WORM = 1 << 3,
	mCORE_MEMORY_VIRTUAL = 1 << 4
};

struct mCoreMemoryBlock {
	int id;
	const char* key;
	const char* shortName;
	const char* longName;
	uint32_t start;
	uint32_t end;
	uint32_t size;
	uint32_t flags;
	int bank;
	uint32_t bankAddress;
};

struct mCoreScreenRegion {
	int id;
	const char* name;
	int32_t x;
	int32_t y;
	uint32_t width;
	uint32_t height;
};

struct mCoreChannelInfo {
	int id;
	const char* key;
	const char* name;
	const char* desc;
};

struct mCoreRegisterInfo {
	const char* name;
	const char** aliases;
	size_t size;
	uint32_t mask;
	uint32_t flags;
};

struct GBASavedata {
	int type;
	uint8_t* data;
	uint8_t* currentBank;
	int command;
	int flashState;
	struct VFile* vf;
	struct VFile* realVf;
	int mapMode;
	bool maskWriteback;
	bool dirty;
	uint32_t dirtAge;
	struct mTimingEvent dust;
	struct GBA* p;
	uint32_t writeAddress;
	uint32_t readAddress;
	uint32_t readBitsRemaining;
	uint32_t settling;
};

struct GBAHardware {
	unsigned devices;
	struct {
		uint8_t time[7];
		uint8_t control;
		uint64_t lastLatch;
		int64_t offset;
	} rtc;
};

struct GBACartEReader {
	int _unused;
};

#define GBA_VIDEO_HORIZONTAL_PIXELS 240u
#define GBA_VIDEO_VERTICAL_PIXELS 160u

typedef uint16_t mColor;

struct GBAVideoRenderer {
	void (*init)(struct GBAVideoRenderer*);
	void (*reset)(struct GBAVideoRenderer*);
	void (*deinit)(struct GBAVideoRenderer*);
	uint16_t (*writeVideoRegister)(struct GBAVideoRenderer*, uint32_t, uint16_t);
	void (*writeVRAM)(struct GBAVideoRenderer*, uint32_t);
	void (*writePalette)(struct GBAVideoRenderer*, uint32_t, uint16_t);
	void (*writeOAM)(struct GBAVideoRenderer*, uint32_t);
	void (*drawScanline)(struct GBAVideoRenderer*, int);
	void (*finishFrame)(struct GBAVideoRenderer*);
	void (*getPixels)(struct GBAVideoRenderer*, size_t*, const void**);
	void (*putPixels)(struct GBAVideoRenderer*, size_t, const void*);
	uint32_t (*rendererId)(struct GBAVideoRenderer*);
	bool (*loadState)(struct GBAVideoRenderer*, const void*, size_t);
	void (*saveState)(struct GBAVideoRenderer*, void**, size_t*);
	uint16_t* palette;
	uint8_t* vram;
	void* oam;
	void* cache;
	bool disableBG[4];
	bool disableOBJ;
	bool disableWIN[2];
	bool disableOBJWIN;
	int highlightAmount;
};

struct GBAVideoSoftwareRenderer {
	struct GBAVideoRenderer d;
	mColor* outputBuffer;
	size_t outputBufferStride;
	struct { int32_t offsetX; int32_t offsetY; } bg[4];
	struct { int32_t offsetX; int32_t offsetY; } winN[2];
	int32_t objOffsetX;
	int32_t objOffsetY;
	int oamDirty;
	int start;
	int end;
	uint16_t mosaic;
	uint16_t blendEffect;
	uint32_t scanlineDirty[256];
	uint32_t* normalPalette;
	uint8_t* target1Obj;
	int currentWindow;
};

struct GBAVideo {
	struct GBAVideoRenderer* renderer;
	uint16_t* palette;
	uint8_t* vram;
};

struct GBAVideoSoftwareBackground {
	int x;
	int y;
	int offsetX;
	int offsetY;
	bool mosaic;
};

struct GBAObj {
	uint16_t a;
	uint16_t b;
	uint16_t c;
};

typedef uint16_t GBATimerFlags;
struct GBATimer {
	uint16_t reload;
	GBATimerFlags flags;
	int32_t lastEvent;
	struct mTimingEvent event;
};

struct mCoreSync {
	bool videoFrameWait;
	bool audioWait;
	size_t audioHighWater;
	int videoFramePending;
	void* videoFrameMutex;
	void* videoFrameAvailableCond;
	void* videoFrameRequiredCond;
	void* audioBufferMutex;
	void* audioRequiredCond;
	void* frameMutex;
	void* frameAvailableCond;
	int waiting;
};

struct VFile {
	void (*close)(struct VFile*);
	ssize_t (*read)(struct VFile*, void*, size_t);
	ssize_t (*write)(struct VFile*, const void*, size_t);
	off_t (*seek)(struct VFile*, off_t, int);
	off_t (*size)(struct VFile*);
	void (*truncate)(struct VFile*, size_t);
	bool (*sync)(struct VFile*, const void*, size_t);
	void* (*map)(struct VFile*, size_t, int);
	void (*unmap)(struct VFile*, void*, size_t);
};

struct GBASavedataRTCBuffer {
	uint8_t time[7];
	uint8_t control;
	uint8_t lastLatch[8];
};

struct mAudioBuffer {
	size_t _unused;
};

typedef uint16_t GBASerializedSavedataFlags;
static inline GBASerializedSavedataFlags GBASerializedSavedataFlagsSetFlashState(GBASerializedSavedataFlags flags, int flashState) { return (GBASerializedSavedataFlags) ((flags & ~0x3) | (flashState & 0x3)); }
static inline GBASerializedSavedataFlags GBASerializedSavedataFlagsTestFillFlashBank(GBASerializedSavedataFlags flags, bool bank) { return bank ? (GBASerializedSavedataFlags) (flags | 0x4) : (GBASerializedSavedataFlags) (flags & ~0x4); }
static inline GBASerializedSavedataFlags GBASerializedSavedataFlagsFillDustSettling(GBASerializedSavedataFlags flags) { return (GBASerializedSavedataFlags) (flags | 0x8); }
static inline int GBASerializedSavedataFlagsGetFlashState(GBASerializedSavedataFlags flags) { return flags & 0x3; }
static inline bool GBASerializedSavedataFlagsIsFlashBank(GBASerializedSavedataFlags flags) { return (flags & 0x4) != 0; }
static inline bool GBASerializedSavedataFlagsIsDustSettling(GBASerializedSavedataFlags flags) { return (flags & 0x8) != 0; }
static inline int GBASerializedSavedataFlagsGetFlashBank(GBASerializedSavedataFlags flags) { return GBASerializedSavedataFlagsIsFlashBank(flags) ? 1 : 0; }

struct GBASerializedState {
	uint8_t io[0x400];
	struct {
		uint16_t reload;
		uint32_t lastEvent;
		uint32_t nextEvent;
		uint32_t flags;
	} timers[4];
	uint32_t bus;
	uint32_t versionMagic;
	struct {
		uint32_t type;
		uint32_t command;
		uint16_t flags;
		uint8_t readBitsRemaining;
		uint8_t settlingDust[4];
		uint8_t readAddress[4];
		uint8_t writeAddress[4];
		uint8_t settlingSector[2];
	} savedata;
};

struct GBAVideoProxyRenderer {
	struct GBAVideoRenderer d;
	int flushScanline;
	void* logger;
};

struct mVideoThreadProxy {
	struct { int _unused; } d;
};

struct mCoreCallbacks {
	void (*videoFrameEnded)(void*);
	void (*keysRead)(void*);
	void* context;
};

struct mCoreOptions {
	bool mute;
	int volume;
	int frameskip;
	bool skipBios;
};

struct mRTCSourceDummy { int _unused; };
struct mRTCGenericSource { struct mRTCSourceDummy d; };
struct mCoreOptsDummy { int _unused; };
struct mDirectorySet { int _unused; };
struct mCoreConfig { int _unused; };

struct mCore {
	void* cpu;
	void* board;
	struct mTiming* timing;
	void* debugger;
	void* symbolTable;
	void* videoLogger;
	void (*currentVideoSize)(struct mCore*, unsigned*, unsigned*);
	struct mRTCGenericSource rtc;
	struct mCoreOptions opts;
	struct mCoreConfig config;
	struct mCoreOptsDummy optsData;
	struct mDirectorySet dirs;
};

struct mCPUComponent {
	void (*init)(struct ARMCore*, struct mCPUComponent*);
	void (*deinit)(struct mCPUComponent*);
};

#ifndef CPU_COMPONENT_MAX
#define CPU_COMPONENT_MAX 16
#endif

struct ARMStatusPacked {
	uint32_t packed;
	unsigned n;
	unsigned z;
	unsigned c;
	unsigned v;
	unsigned i;
	unsigned flags;
	unsigned priv;
};

union PSR {
	struct ARMStatusPacked cpsr;
	struct {
		uint32_t packed;
		unsigned n;
		unsigned z;
		unsigned c;
		unsigned v;
		unsigned i;
		unsigned flags;
		unsigned priv;
	};
};

enum PrivilegeMode {
	MODE_USER = 0x10,
	MODE_FIQ = 0x11,
	MODE_IRQ = 0x12,
	MODE_SVC = 0x13,
	MODE_UNDEFINED = 0x1B,
	MODE_SYSTEM = 0x1F
};

#define MODE_SUPERVISOR MODE_SVC
#define BASE_UNDEF 0x00000004
#define BASE_SWI 0x00000008
#define BASE_IRQ 0x00000018

enum RegisterBank {
	BANK_NORMAL = 0,
	BANK_FIQ = 1
};

struct ARMMemory {
	uint32_t (*load32)(struct ARMCore*, uint32_t, int32_t*);
	uint16_t (*load16)(struct ARMCore*, uint32_t, int32_t*);
	uint8_t (*load8)(struct ARMCore*, uint32_t, int32_t*);
	uint32_t (*loadMultiple)(struct ARMCore*, uint32_t, int, int, int32_t*);
	void (*store32)(struct ARMCore*, uint32_t, int32_t, int32_t*);
	void (*store16)(struct ARMCore*, uint32_t, int16_t, int32_t*);
	void (*store8)(struct ARMCore*, uint32_t, int8_t, int32_t*);
	uint32_t (*storeMultiple)(struct ARMCore*, uint32_t, int, int, int32_t*);
	int32_t (*stall)(struct ARMCore*, int32_t);
	int activeSeqCycles16;
	int activeSeqCycles32;
	int activeNonseqCycles32;
	uint32_t activeMask;
	uint8_t* activeRegion;
};

struct ARMCoprocessor {
	uint32_t (*mrc)(struct ARMCore*, int, int, int, int);
	void (*mcr)(struct ARMCore*, int, int, int, int, uint32_t);
	void (*cdp)(struct ARMCore*, int, int, int, int, int);
};

struct ARMCore {
	int32_t gprs[16];
	int cycles;
	int32_t shifterOperand;
	unsigned shifterCarryOut;
	union PSR cpsr;
	union PSR spsr;
	int privilegeMode;
	int executionMode;
	uint32_t bankedRegisters[2][7];
	uint32_t bankedSPSRs[2];
	struct ARMMemory memory;
	struct mCPUComponent* master;
	struct ARMCoprocessor cp[16];
	uint32_t prefetch[2];
	int nextEvent;
	struct { void (*bkpt32)(struct ARMCore*, uint32_t); void (*swi32)(struct ARMCore*, uint32_t); void (*reset)(struct ARMCore*); void (*processEvents)(struct ARMCore*); } irqh;
	int halted;
	size_t numComponents;
	struct mCPUComponent** components;
};

enum {
	ARM_SHIFT_NONE = 0,
	ARM_SHIFT_LSL,
	ARM_SHIFT_LSR,
	ARM_SHIFT_ASR,
	ARM_SHIFT_ROR,
	ARM_SHIFT_RRX
};

enum {
	ARM_MEMORY_REGISTER_BASE = 1 << 0,
	ARM_MEMORY_IMMEDIATE_OFFSET = 1 << 1,
	ARM_MEMORY_REGISTER_OFFSET = 1 << 2,
	ARM_MEMORY_SHIFTED_OFFSET = 1 << 3,
	ARM_MEMORY_POST_INCREMENT = 1 << 4,
	ARM_MEMORY_OFFSET_SUBTRACT = 1 << 5
};

struct ARMRegisterFile {
	int32_t gprs[16];
	union PSR cpsr;
};

struct ARMInstructionInfo {
	struct {
		int format;
		int baseReg;
		struct {
			int immediate;
			int reg;
			uint8_t shifterImm;
			uint8_t shifterOp;
		} offset;
	} memory;
};

enum {
	GBA_UNL_CART_NONE = 0,
	GBA_UNL_CART_MULTICART = 1
};

struct GBAUnlCart {
	int type;
};

struct GBACartridge {
	char id[4];
};

enum {
	IDLE_LOOP_DETECT = 1,
	IDLE_LOOP_REMOVE = 2,
	IDLE_LOOP_IGNORE = 3
};

void GBASavedataForceType(struct GBASavedata* savedata, int type);
void GBASavedataRTCRead(struct GBASavedata* savedata);
void GBASavedataRTCWrite(struct GBASavedata* savedata);
size_t GBASavedataSize(const struct GBASavedata* savedata);
bool GBASavedataLoad(struct GBASavedata* savedata, struct VFile* in);
void GBASavedataInitFlash(struct GBASavedata* savedata);
void GBASavedataInitEEPROM(struct GBASavedata* savedata);
void GBASavedataInitSRAM(struct GBASavedata* savedata);
void GBASavedataInitSRAM512(struct GBASavedata* savedata);
void GBAHardwareClear(struct GBAHardware* hw);
void GBAHardwareInitRTC(struct GBAHardware* hw);
void GBAHardwareInitGyro(struct GBAHardware* hw);
void GBAHardwareInitRumble(struct GBAHardware* hw);
void GBAHardwareInitLight(struct GBAHardware* hw);
void GBAHardwareInitTilt(struct GBAHardware* hw);
void GBACartEReaderInit(struct GBACartEReader* ereader);

struct GBAMemoryBusMini {
	uint16_t io[0x400];
	uint8_t* bios;
	uint8_t* wram;
	uint8_t* iwram;
	uint8_t* rom;
	struct GBASavedata savedata;
	struct GBAHardware hw;
	struct GBACartEReader ereader;
	struct GBAUnlCart unl;
	struct mTimingEvent dmaEvent;
	struct { uint32_t source; uint32_t dest; uint32_t count; uint32_t latch; uint16_t control; } dma[4];
	int activeDMA;
	size_t romSize;
	int activeRegion;
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

void GBASIOSetDriver(struct GBASIO* sio, struct GBASIODriver* driver);

#ifndef GBA_ARM7TDMI_FREQUENCY
#define GBA_ARM7TDMI_FREQUENCY 16777216
#endif

#ifndef VIDEO_TOTAL_LENGTH
#define VIDEO_TOTAL_LENGTH 228
#endif
#ifndef VIDEO_HORIZONTAL_LENGTH
#define VIDEO_HORIZONTAL_LENGTH 1232
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
	GBA_SAVEDATA_FLASH1M = 4,
	GBA_SAVEDATA_EEPROM512 = 5,
	GBA_SAVEDATA_SRAM512 = 6,
	GBA_SAVEDATA_FORCE_NONE = 7
};

enum GBAHardwareDeviceFlags {
	HW_NONE = 0,
	HW_RTC = 1 << 0,
	HW_LIGHT_SENSOR = 1 << 1,
	HW_RUMBLE = 1 << 2,
	HW_GYRO = 1 << 3,
	HW_TILT = 1 << 4,
	HW_EREADER = 1 << 5,
	HW_GB_PLAYER_DETECTION = 1 << 6,
	HW_NO_OVERRIDE = 1 << 30
};

#ifndef GBA_IDLE_LOOP_NONE
#define GBA_IDLE_LOOP_NONE 0
#endif

struct GBACartridgeOverride {
	char id[5];
	int savetype;
	unsigned hardware;
	uint32_t idleLoop;
	bool vbaBugCompat;
};

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
	struct ARMCore* cpu;
	struct GBATimer timers[4];
	struct GBASIO sio;
	struct {
		struct GBAVideoRenderer* renderer;
		uint16_t palette[GBA_SIZE_PALETTE_RAM / sizeof(uint16_t)];
		uint8_t* vram;
		struct { uint8_t raw[GBA_SIZE_OAM]; } oam;
		uint32_t frameCounter;
		int frameskip;
	} video;
	struct {
		bool enable;
		int masterVolume;
		int sampleInterval;
		size_t samples;
		struct { struct { int _unused; } buffer; struct { int volume; } ch3; bool forceDisableCh[4]; } psg;
		int chATimer;
		int chBTimer;
		bool chALeft;
		bool chARight;
		bool chBLeft;
		bool chBRight;
		bool forceDisableChA;
		bool forceDisableChB;
	} audio;
	struct mCPUComponent d;
	struct mCoreCallbacks coreCallbacks;
	void* sync;
	void* rtcSource;
	void* stream;
	void* rotationSource;
	void* luminanceSource;
	struct VFile* biosVf;
	struct VFile* romVf;
	struct VFile* mbVf;
	struct mKeyCallback* keyCallback;
	struct { void (*setRumble)(void*, bool, int32_t); }* rumble;
	int32_t lastRumble;
	bool vbaBugCompat;
	uint32_t idleLoop;
	int idleOptimization;
	bool allowOpposingDirections;
	bool isPristine;
	bool haltPending;
	uint32_t keysActive;
	uint16_t keysLast;
	size_t pristineRomSize;
	uint32_t romCrc32;
	uint32_t bus;
};

enum {
	mPERIPH_ROTATION = 1,
	mPERIPH_RUMBLE = 2,
	mPERIPH_GBA_LUMINANCE = 3,
	mPERIPH_GBA_LINK_PORT = 4
};

#ifndef RCNT_INITIAL
#define RCNT_INITIAL 0x8000
#endif

void GBASIOPlayerInit(struct GBASIOPlayer* player);
void GBASIOPlayerReset(struct GBASIOPlayer* player);

static inline uint16_t GBASIORegisterRCNTSetSi(uint16_t v, bool si) { return si ? (uint16_t) (v | 0x0004) : (uint16_t) (v & ~0x0004); }
static inline uint16_t GBASIORegisterRCNTFillSc(uint16_t v) { return (uint16_t) (v | 0x0002); }
static inline uint16_t GBASIORegisterRCNTClearSc(uint16_t v) { return (uint16_t) (v & ~0x0002); }

int GBASIOTransferCycles(enum GBASIOMode mode, uint16_t siocnt, int connected);

static inline uint16_t GBASIOMultiplayerSetSlave(uint16_t v, bool slave) { return slave ? (uint16_t) (v | 0x0080) : (uint16_t) (v & ~0x0080); }
static inline uint16_t GBASIOMultiplayerSetId(uint16_t v, int id) { return (uint16_t) ((v & ~0x0030) | ((id & 0x3) << 4)); }
static inline bool GBASIOMultiplayerIsBusy(uint16_t v) { return (v & 0x0080) != 0; }
static inline uint16_t GBASIOMultiplayerFillReady(uint16_t v) { return (uint16_t) (v | 0x0008); }
static inline bool GBASIONormalGetSc(uint16_t v) { return (v & 0x0001) != 0; }
static inline bool GBASIONormalIsStart(uint16_t v) { return (v & 0x0080) != 0; }
static inline uint16_t GBASIONormalFillSi(uint16_t v) { return (uint16_t) (v | 0x0004); }

#ifndef MAP_WRITE
#define MAP_WRITE 1
#endif
#ifndef MAP_READ
#define MAP_READ 2
#endif

#ifndef EEPROM_COMMAND_NULL
#define EEPROM_COMMAND_NULL 0
#define EEPROM_COMMAND_PENDING 1
#define EEPROM_COMMAND_WRITE 2
#define EEPROM_COMMAND_READ_PENDING 3
#define EEPROM_COMMAND_READ 4
#endif

#ifndef FLASH_STATE_RAW
#define FLASH_STATE_RAW 0
#define FLASH_STATE_START 1
#define FLASH_STATE_CONTINUE 2
#endif

#ifndef FLASH_COMMAND_NONE
#define FLASH_COMMAND_NONE 0
#define FLASH_COMMAND_ID 1
#define FLASH_COMMAND_PROGRAM 2
#define FLASH_COMMAND_SWITCH_BANK 3
#define FLASH_COMMAND_START 0xAA
#define FLASH_COMMAND_CONTINUE 0x55
#define FLASH_COMMAND_ERASE 0x80
#define FLASH_COMMAND_ERASE_CHIP 0x10
#define FLASH_COMMAND_ERASE_SECTOR 0x30
#define FLASH_COMMAND_TERMINATE 0xF0
#endif

#ifndef FLASH_BASE_HI
#define FLASH_BASE_HI 0x5555
#define FLASH_BASE_LO 0x2AAA
#endif

#ifndef FLASH_PANASONIC_MN63F805MNP
#define FLASH_PANASONIC_MN63F805MNP 0x1B32u
#endif

#ifndef FLASH_SANYO_LE26FV10N1TS
#define FLASH_SANYO_LE26FV10N1TS 0x1362u
#endif

#ifndef mSAVEDATA_DIRT_NEW
#define mSAVEDATA_DIRT_NEW 1u
#endif

#ifndef GBA_LAYER_BG0
#define GBA_LAYER_BG0 0
#define GBA_LAYER_BG1 1
#define GBA_LAYER_BG2 2
#define GBA_LAYER_BG3 3
#define GBA_LAYER_OBJ 4
#define GBA_LAYER_WIN0 5
#define GBA_LAYER_WIN1 6
#define GBA_LAYER_OBJWIN 7
#endif

#ifndef mCORE_REGISTER_GPR
#define mCORE_REGISTER_GPR 1u
#endif
#ifndef mCORE_REGISTER_FLAGS
#define mCORE_REGISTER_FLAGS 2u
#endif

#ifndef GBA_IRQ_TIMER0
#define GBA_IRQ_TIMER0 3
#endif
#ifndef GBA_IRQ_SIO
#define GBA_IRQ_SIO 7
#endif

#ifndef HW_GB_PLAYER
#define HW_GB_PLAYER (1u << 7)
#endif

#ifndef VIDEO_HDRAW_LENGTH
#define VIDEO_HDRAW_LENGTH 1006
#endif

#ifndef BLEND_ALPHA
#define BLEND_ALPHA 1
#endif

#ifndef OFFSET_PRIORITY
#define OFFSET_PRIORITY 0
#endif

#ifndef GBA_REG
#define GBA_REG(x) ((x) >> 1)
#endif

enum {
	DISPCNT = 0x000, DISPSTAT = 0x004, VCOUNT = 0x006,
	BG0CNT = 0x008, BG1CNT = 0x00A, BG2CNT = 0x00C, BG3CNT = 0x00E,
	BG0HOFS = 0x010, BG0VOFS = 0x012, BG1HOFS = 0x014, BG1VOFS = 0x016,
	BG2HOFS = 0x018, BG2VOFS = 0x01A, BG2PA = 0x020, BG2PB = 0x022, BG2PC = 0x024, BG2PD = 0x026,
	BG2X_LO = 0x028, BG2X_HI = 0x02A, BG2Y_LO = 0x02C, BG2Y_HI = 0x02E,
	BG3HOFS = 0x030, BG3VOFS = 0x032, BG3PA = 0x034, BG3PB = 0x036, BG3PC = 0x038, BG3PD = 0x03A,
	BG3X_LO = 0x03C, BG3X_HI = 0x03E, BG3Y_LO = 0x040, BG3Y_HI = 0x042,
	WIN0H = 0x040, WIN1H = 0x042, WIN0V = 0x044, WIN1V = 0x046,
	WININ = 0x048, WINOUT = 0x04A, MOSAIC = 0x04C, BLDCNT = 0x050, BLDALPHA = 0x052, BLDY = 0x054,
	DMA0SAD_LO = 0x0B0, DMA0SAD_HI = 0x0B2, DMA0DAD_LO = 0x0B4, DMA0DAD_HI = 0x0B6, DMA0CNT_LO = 0x0B8, DMA0CNT_HI = 0x0BA,
	DMA1SAD_LO = 0x0BC, DMA1SAD_HI = 0x0BE, DMA1DAD_LO = 0x0C0, DMA1DAD_HI = 0x0C2, DMA1CNT_LO = 0x0C4, DMA1CNT_HI = 0x0C6,
	DMA2SAD_LO = 0x0C8, DMA2SAD_HI = 0x0CA, DMA2DAD_LO = 0x0CC, DMA2DAD_HI = 0x0CE, DMA2CNT_LO = 0x0D0, DMA2CNT_HI = 0x0D2,
	DMA3SAD_LO = 0x0D4, DMA3SAD_HI = 0x0D6, DMA3DAD_LO = 0x0D8, DMA3DAD_HI = 0x0DA, DMA3CNT_LO = 0x0DC, DMA3CNT_HI = 0x0DE,
	TM0CNT_LO = 0x100, TM0CNT_HI = 0x102, TM1CNT_LO = 0x104, TM1CNT_HI = 0x106, TM2CNT_LO = 0x108, TM2CNT_HI = 0x10A, TM3CNT_LO = 0x10C, TM3CNT_HI = 0x10E,
	KEYCNT = 0x132, RCNT_EXT = 0x134, JOYSTAT = 0x158, IE = 0x200, IF = 0x202, WAITCNT = 0x204, IME = 0x208,
	KEYINPUT = 0x130, SOUNDBIAS = 0x088, POSTFLG = 0x300,
	INTERNAL_EXWAITCNT_LO = 0x204, INTERNAL_EXWAITCNT_HI = 0x206, INTERNAL_MAX = 0x400,
	SIOMULTI0 = 0x120, SIOMULTI1 = 0x122, SIOMULTI2 = 0x124, SIOMULTI3 = 0x126,
	SIODATA32_LO = 0x120, SIODATA32_HI = 0x122, SIODATA8 = 0x12A, SIOCNT = 0x128, RCNT = 0x134,
	SIOMLT_SEND = 0x12A, JOYCNT = 0x140, JOY_RECV_LO = 0x150, JOY_RECV_HI = 0x152, JOY_TRANS_LO = 0x154, JOY_TRANS_HI = 0x156,
	SOUND1CNT_LO = 0x060, SOUND1CNT_HI = 0x062, SOUND1CNT_X = 0x064,
	SOUND2CNT_LO = 0x068, SOUND2CNT_HI = 0x06C,
	SOUND3CNT_LO = 0x070, SOUND3CNT_HI = 0x072, SOUND3CNT_X = 0x074,
	SOUND4CNT_LO = 0x078, SOUND4CNT_HI = 0x07C,
	SOUNDCNT_LO = 0x080, SOUNDCNT_HI = 0x082, SOUNDCNT_X = 0x084,
	WAVE_RAM0_LO = 0x090, WAVE_RAM0_HI = 0x092, WAVE_RAM1_LO = 0x094, WAVE_RAM1_HI = 0x096,
	WAVE_RAM2_LO = 0x098, WAVE_RAM2_HI = 0x09A, WAVE_RAM3_LO = 0x09C, WAVE_RAM3_HI = 0x09E,
	FIFO_A_LO = 0x0A0, FIFO_A_HI = 0x0A2, FIFO_B_LO = 0x0A4, FIFO_B_HI = 0x0A6
};

#define GBA_REG_DISPCNT GBA_REG(DISPCNT)
#define GBA_REG_BG0CNT GBA_REG(BG0CNT)
#define GBA_REG_BG1CNT GBA_REG(BG1CNT)
#define GBA_REG_BG2CNT GBA_REG(BG2CNT)
#define GBA_REG_BG3CNT GBA_REG(BG3CNT)
#define GBA_REG_BG0HOFS GBA_REG(BG0HOFS)
#define GBA_REG_BG0VOFS GBA_REG(BG0VOFS)
#define GBA_REG_BG1HOFS GBA_REG(BG1HOFS)
#define GBA_REG_BG1VOFS GBA_REG(BG1VOFS)
#define GBA_REG_BG2HOFS GBA_REG(BG2HOFS)
#define GBA_REG_BG2VOFS GBA_REG(BG2VOFS)
#define GBA_REG_BG3HOFS GBA_REG(BG3HOFS)
#define GBA_REG_BG3VOFS GBA_REG(BG3VOFS)
#define GBA_REG_BG2PA GBA_REG(BG2PA)
#define GBA_REG_BG2PB GBA_REG(BG2PB)
#define GBA_REG_BG2PC GBA_REG(BG2PC)
#define GBA_REG_BG2PD GBA_REG(BG2PD)
#define GBA_REG_BG2X_LO GBA_REG(BG2X_LO)
#define GBA_REG_BG2X_HI GBA_REG(BG2X_HI)
#define GBA_REG_BG2Y_LO GBA_REG(BG2Y_LO)
#define GBA_REG_BG2Y_HI GBA_REG(BG2Y_HI)
#define GBA_REG_BG3PA GBA_REG(BG3PA)
#define GBA_REG_BG3PB GBA_REG(BG3PB)
#define GBA_REG_BG3PC GBA_REG(BG3PC)
#define GBA_REG_BG3PD GBA_REG(BG3PD)
#define GBA_REG_BG3X_LO GBA_REG(BG3X_LO)
#define GBA_REG_BG3X_HI GBA_REG(BG3X_HI)
#define GBA_REG_BG3Y_LO GBA_REG(BG3Y_LO)
#define GBA_REG_BG3Y_HI GBA_REG(BG3Y_HI)
#define GBA_REG_SIODATA8 GBA_REG(SIODATA8)
#define GBA_REG_SIODATA32_LO GBA_REG(SIODATA32_LO)
#define GBA_REG_SIODATA32_HI GBA_REG(SIODATA32_HI)
#define GBA_REG_SIOMULTI0 GBA_REG(SIOMULTI0)
#define GBA_REG_SIOMULTI1 GBA_REG(SIOMULTI1)
#define GBA_REG_SIOMULTI2 GBA_REG(SIOMULTI2)
#define GBA_REG_SIOMULTI3 GBA_REG(SIOMULTI3)
#define GBA_REG_SIOCNT GBA_REG(SIOCNT)
#define GBA_REG_RCNT GBA_REG(RCNT)
#define GBA_REG_SIOMLT_SEND GBA_REG(SIOMLT_SEND)
#define GBA_REG_JOYCNT GBA_REG(JOYCNT)
#define GBA_REG_JOY_RECV_LO GBA_REG(JOY_RECV_LO)
#define GBA_REG_JOY_RECV_HI GBA_REG(JOY_RECV_HI)
#define GBA_REG_JOY_TRANS_LO GBA_REG(JOY_TRANS_LO)
#define GBA_REG_JOY_TRANS_HI GBA_REG(JOY_TRANS_HI)
#define GBA_REG_VCOUNT GBA_REG(VCOUNT)
#define GBA_REG_DISPSTAT GBA_REG(DISPSTAT)
#define GBA_REG_SOUND1CNT_LO GBA_REG(SOUND1CNT_LO)
#define GBA_REG_SOUNDCNT_LO GBA_REG(SOUNDCNT_LO)
#define GBA_REG_POSTFLG GBA_REG(POSTFLG)
#define GBA_REG_SOUNDBIAS GBA_REG(SOUNDBIAS)
#define GBA_REG_SOUND1CNT_HI GBA_REG(SOUND1CNT_HI)
#define GBA_REG_SOUND1CNT_X GBA_REG(SOUND1CNT_X)
#define GBA_REG_SOUND2CNT_LO GBA_REG(SOUND2CNT_LO)
#define GBA_REG_SOUND2CNT_HI GBA_REG(SOUND2CNT_HI)
#define GBA_REG_SOUND3CNT_LO GBA_REG(SOUND3CNT_LO)
#define GBA_REG_SOUND3CNT_HI GBA_REG(SOUND3CNT_HI)
#define GBA_REG_SOUND3CNT_X GBA_REG(SOUND3CNT_X)
#define GBA_REG_SOUND4CNT_LO GBA_REG(SOUND4CNT_LO)
#define GBA_REG_SOUND4CNT_HI GBA_REG(SOUND4CNT_HI)
#define GBA_REG_SOUNDCNT_HI GBA_REG(SOUNDCNT_HI)
#define GBA_REG_SOUNDCNT_X GBA_REG(SOUNDCNT_X)
#define GBA_REG_WAVE_RAM0_LO GBA_REG(WAVE_RAM0_LO)
#define GBA_REG_WAVE_RAM0_HI GBA_REG(WAVE_RAM0_HI)
#define GBA_REG_WAVE_RAM1_LO GBA_REG(WAVE_RAM1_LO)
#define GBA_REG_WAVE_RAM1_HI GBA_REG(WAVE_RAM1_HI)
#define GBA_REG_WAVE_RAM2_LO GBA_REG(WAVE_RAM2_LO)
#define GBA_REG_WAVE_RAM2_HI GBA_REG(WAVE_RAM2_HI)
#define GBA_REG_WAVE_RAM3_LO GBA_REG(WAVE_RAM3_LO)
#define GBA_REG_WAVE_RAM3_HI GBA_REG(WAVE_RAM3_HI)
#define GBA_REG_FIFO_A_LO GBA_REG(FIFO_A_LO)
#define GBA_REG_FIFO_A_HI GBA_REG(FIFO_A_HI)
#define GBA_REG_FIFO_B_LO GBA_REG(FIFO_B_LO)
#define GBA_REG_FIFO_B_HI GBA_REG(FIFO_B_HI)
#define GBA_REG_WIN0H GBA_REG(WIN0H)
#define GBA_REG_WIN1H GBA_REG(WIN1H)
#define GBA_REG_WIN0V GBA_REG(WIN0V)
#define GBA_REG_WIN1V GBA_REG(WIN1V)
#define GBA_REG_WININ GBA_REG(WININ)
#define GBA_REG_WINOUT GBA_REG(WINOUT)
#define GBA_REG_MOSAIC GBA_REG(MOSAIC)
#define GBA_REG_BLDCNT GBA_REG(BLDCNT)
#define GBA_REG_BLDALPHA GBA_REG(BLDALPHA)
#define GBA_REG_BLDY GBA_REG(BLDY)
#define GBA_REG_DMA0SAD_LO GBA_REG(DMA0SAD_LO)
#define GBA_REG_DMA0SAD_HI GBA_REG(DMA0SAD_HI)
#define GBA_REG_DMA0DAD_LO GBA_REG(DMA0DAD_LO)
#define GBA_REG_DMA0DAD_HI GBA_REG(DMA0DAD_HI)
#define GBA_REG_DMA0CNT_LO GBA_REG(DMA0CNT_LO)
#define GBA_REG_DMA0CNT_HI GBA_REG(DMA0CNT_HI)
#define GBA_REG_DMA1SAD_LO GBA_REG(DMA1SAD_LO)
#define GBA_REG_DMA1SAD_HI GBA_REG(DMA1SAD_HI)
#define GBA_REG_DMA1DAD_LO GBA_REG(DMA1DAD_LO)
#define GBA_REG_DMA1DAD_HI GBA_REG(DMA1DAD_HI)
#define GBA_REG_DMA1CNT_LO GBA_REG(DMA1CNT_LO)
#define GBA_REG_DMA1CNT_HI GBA_REG(DMA1CNT_HI)
#define GBA_REG_DMA2SAD_LO GBA_REG(DMA2SAD_LO)
#define GBA_REG_DMA2SAD_HI GBA_REG(DMA2SAD_HI)
#define GBA_REG_DMA2DAD_LO GBA_REG(DMA2DAD_LO)
#define GBA_REG_DMA2DAD_HI GBA_REG(DMA2DAD_HI)
#define GBA_REG_DMA2CNT_LO GBA_REG(DMA2CNT_LO)
#define GBA_REG_DMA2CNT_HI GBA_REG(DMA2CNT_HI)
#define GBA_REG_DMA3SAD_LO GBA_REG(DMA3SAD_LO)
#define GBA_REG_DMA3SAD_HI GBA_REG(DMA3SAD_HI)
#define GBA_REG_DMA3DAD_LO GBA_REG(DMA3DAD_LO)
#define GBA_REG_DMA3DAD_HI GBA_REG(DMA3DAD_HI)
#define GBA_REG_DMA3CNT_LO GBA_REG(DMA3CNT_LO)
#define GBA_REG_DMA3CNT_HI GBA_REG(DMA3CNT_HI)
#define GBA_REG_TM0CNT_LO GBA_REG(TM0CNT_LO)
#define GBA_REG_TM0CNT_HI GBA_REG(TM0CNT_HI)
#define GBA_REG_TM1CNT_LO GBA_REG(TM1CNT_LO)
#define GBA_REG_TM1CNT_HI GBA_REG(TM1CNT_HI)
#define GBA_REG_TM2CNT_LO GBA_REG(TM2CNT_LO)
#define GBA_REG_TM2CNT_HI GBA_REG(TM2CNT_HI)
#define GBA_REG_TM3CNT_LO GBA_REG(TM3CNT_LO)
#define GBA_REG_TM3CNT_HI GBA_REG(TM3CNT_HI)
#define GBA_REG_KEYINPUT GBA_REG(KEYINPUT)
#define GBA_REG_KEYCNT GBA_REG(KEYCNT)
#define GBA_REG_JOYSTAT GBA_REG(JOYSTAT)
#define GBA_REG_IE GBA_REG(IE)
#define GBA_REG_IF GBA_REG(IF)
#define GBA_REG_WAITCNT GBA_REG(WAITCNT)
#define GBA_REG_IME GBA_REG(IME)
#define GBA_REG_EXWAITCNT_LO GBA_REG(INTERNAL_EXWAITCNT_LO)
#define GBA_REG_EXWAITCNT_HI GBA_REG(INTERNAL_EXWAITCNT_HI)
#define GBA_REG_INTERNAL_EXWAITCNT_LO GBA_REG(INTERNAL_EXWAITCNT_LO)
#define GBA_REG_INTERNAL_EXWAITCNT_HI GBA_REG(INTERNAL_EXWAITCNT_HI)
#define GBA_REG_INTERNAL_MAX GBA_REG(INTERNAL_MAX)
#define GBA_REG_MAX GBA_REG(INTERNAL_MAX)
#define GBA_REG_STEREOCNT GBA_REG(SOUNDCNT_LO)

#define GBA_REG_TMCNT_LO(id) (0x100 + ((id) * 4))

static inline uint32_t hash32(const void* data, size_t size, uint32_t seed) { UNUSED(data); UNUSED(size); return seed; }
int32_t mTimingCurrentTime(const struct mTiming* timing);
bool mTimingIsScheduled(const struct mTiming* timing, const struct mTimingEvent* event);
static inline bool mSavedataClean(bool* dirty, uint32_t* dirtAge, uint32_t frameCount) { UNUSED(dirtAge); UNUSED(frameCount); return dirty && *dirty; }
void GBASIOReset(struct GBASIO* sio);
static inline void GBARaiseIRQ(struct GBA* gba, int irq, int32_t cyclesLate) { UNUSED(gba); UNUSED(irq); UNUSED(cyclesLate); }
static inline void GBATestKeypadIRQ(struct GBA* gba) { UNUSED(gba); }
static inline uint32_t GBAView8(struct ARMCore* cpu, uint32_t address) { UNUSED(cpu); UNUSED(address); return 0; }
static inline uint32_t GBAView16(struct ARMCore* cpu, uint32_t address) { UNUSED(cpu); UNUSED(address); return 0; }
static inline uint32_t GBAView32(struct ARMCore* cpu, uint32_t address) { UNUSED(cpu); UNUSED(address); return 0; }
static inline uint16_t GBALoadBad(struct ARMCore* cpu) { UNUSED(cpu); return 0; }
static inline void GBAWrite8(struct ARMCore* cpu, uint32_t address, uint8_t value) { UNUSED(cpu); UNUSED(address); UNUSED(value); }
static inline void GBAWrite16(struct ARMCore* cpu, uint32_t address, uint16_t value) { UNUSED(cpu); UNUSED(address); UNUSED(value); }
static inline void GBAWrite32(struct ARMCore* cpu, uint32_t address, uint32_t value) { UNUSED(cpu); UNUSED(address); UNUSED(value); }
static inline bool GBATimerFlagsIsCountUp(uint16_t flags) { UNUSED(flags); return false; }
static inline bool GBATimerFlagsIsDoIrq(uint16_t flags) { UNUSED(flags); return false; }
static inline bool GBATimerFlagsIsEnable(uint16_t flags) { return (flags & 0x0080) != 0; }
static inline unsigned GBATimerFlagsGetPrescaleBits(uint16_t flags) { return flags & 0x3FF; }
static inline uint16_t GBATimerFlagsSetPrescaleBits(uint16_t flags, unsigned bits) { return (uint16_t) ((flags & ~0x3FF) | (bits & 0x3FF)); }
static inline uint16_t GBATimerFlagsTestFillCountUp(uint16_t flags, bool v) { return v ? (uint16_t) (flags | 0x0004) : (uint16_t) (flags & ~0x0004); }
static inline uint16_t GBATimerFlagsTestFillDoIrq(uint16_t flags, bool v) { return v ? (uint16_t) (flags | 0x0040) : (uint16_t) (flags & ~0x0040); }
static inline uint16_t GBATimerFlagsTestFillEnable(uint16_t flags, bool v) { return v ? (uint16_t) (flags | 0x0080) : (uint16_t) (flags & ~0x0080); }
void GBATimerUpdateRegister(struct GBA* gba, int timerId, int32_t cyclesLate);
static inline bool GBADMARegisterIsEnable(uint16_t control) { return (control & 0x8000) != 0; }
void GBADMAWriteCNT_LO(struct GBA* gba, int dma, uint16_t count);
uint16_t GBADMAWriteCNT_HI(struct GBA* gba, int dma, uint16_t control);
uint32_t GBADMAWriteSAD(struct GBA* gba, int dma, uint32_t address);
uint32_t GBADMAWriteDAD(struct GBA* gba, int dma, uint32_t address);
void GBATimerWriteTMCNT_LO(struct GBA* gba, int timer, uint16_t reload);
void GBATimerWriteTMCNT_HI(struct GBA* gba, int timer, uint16_t control);
void GBASIOWriteSIOCNT(struct GBASIO* sio, uint16_t value);
void GBASIOWriteRCNT(struct GBASIO* sio, uint16_t value);
uint16_t GBASIOWriteRegister(struct GBASIO* sio, uint32_t address, uint16_t value);
void GBAAdjustWaitstates(struct GBA* gba, uint16_t parameters);
void GBAAdjustEWRAMWaitstates(struct GBA* gba, uint16_t parameters);
static inline void GBADMASerialize(struct GBA* gba, struct GBASerializedState* state) { UNUSED(gba); UNUSED(state); }
static inline void GBADMADeserialize(struct GBA* gba, const struct GBASerializedState* state) { UNUSED(gba); UNUSED(state); }
static inline void GBAHardwareSerialize(const struct GBAHardware* hw, struct GBASerializedState* state) { UNUSED(hw); UNUSED(state); }
static inline void GBAHardwareDeserialize(struct GBAHardware* hw, const struct GBASerializedState* state) { UNUSED(hw); UNUSED(state); }
static inline void GBATestIRQ(struct GBA* gba, int32_t cyclesLate) { UNUSED(gba); UNUSED(cyclesLate); }
static inline void GBAHalt(struct GBA* gba) { UNUSED(gba); }
static inline void GBAStop(struct GBA* gba) { UNUSED(gba); }
static inline void GBAAudioSampleFIFO(void* audio, int fifo, uint32_t cyclesLate) { UNUSED(audio); UNUSED(fifo); UNUSED(cyclesLate); }
static inline void GBAAudioSample(void* audio, int32_t cyclesLate) { UNUSED(audio); UNUSED(cyclesLate); }
static inline uint16_t GBAVideoWriteDISPSTAT(void* video, uint16_t value) { UNUSED(video); return value; }
static inline void GBAAudioWriteSOUND1CNT_LO(void* audio, uint16_t value) { UNUSED(audio); UNUSED(value); }
static inline void GBAAudioWriteSOUND1CNT_HI(void* audio, uint16_t value) { UNUSED(audio); UNUSED(value); }
static inline void GBAAudioWriteSOUND1CNT_X(void* audio, uint16_t value) { UNUSED(audio); UNUSED(value); }
static inline void GBAAudioWriteSOUND2CNT_LO(void* audio, uint16_t value) { UNUSED(audio); UNUSED(value); }
static inline void GBAAudioWriteSOUND2CNT_HI(void* audio, uint16_t value) { UNUSED(audio); UNUSED(value); }
static inline void GBAAudioWriteSOUND3CNT_LO(void* audio, uint16_t value) { UNUSED(audio); UNUSED(value); }
static inline void GBAAudioWriteSOUND3CNT_HI(void* audio, uint16_t value) { UNUSED(audio); UNUSED(value); }
static inline void GBAAudioWriteSOUND3CNT_X(void* audio, uint16_t value) { UNUSED(audio); UNUSED(value); }
static inline void GBAAudioWriteSOUND4CNT_LO(void* audio, uint16_t value) { UNUSED(audio); UNUSED(value); }
static inline void GBAAudioWriteSOUND4CNT_HI(void* audio, uint16_t value) { UNUSED(audio); UNUSED(value); }
static inline void GBAAudioWriteSOUNDCNT_LO(void* audio, uint16_t value) { UNUSED(audio); UNUSED(value); }
static inline void GBAAudioWriteSOUNDCNT_HI(void* audio, uint16_t value) { UNUSED(audio); UNUSED(value); }
static inline void GBAAudioWriteSOUNDCNT_X(void* audio, uint16_t value) { UNUSED(audio); UNUSED(value); }
static inline void GBAAudioWriteSOUNDBIAS(void* audio, uint16_t value) { UNUSED(audio); UNUSED(value); }
static inline void GBAAudioWriteWaveRAM(void* audio, uint32_t address, uint16_t value) { UNUSED(audio); UNUSED(address); UNUSED(value); }
static inline uint32_t GBAAudioWriteFIFO(void* audio, int id, uint32_t value) { UNUSED(audio); UNUSED(id); return value; }
static inline uint32_t GBAAudioReadWaveRAM(void* audio, uint32_t address) { UNUSED(audio); UNUSED(address); return 0; }
static inline bool GBAudioEnableIsEnable(uint16_t value) { return (value & 0x0080) != 0; }
static inline void GBAudioWriteNR11(void* psg, uint8_t value) { UNUSED(psg); UNUSED(value); }
static inline void GBAudioWriteNR12(void* psg, uint8_t value) { UNUSED(psg); UNUSED(value); }
static inline void GBAudioWriteNR13(void* psg, uint8_t value) { UNUSED(psg); UNUSED(value); }
static inline void GBAudioWriteNR14(void* psg, uint8_t value) { UNUSED(psg); UNUSED(value); }
static inline void GBAudioWriteNR21(void* psg, uint8_t value) { UNUSED(psg); UNUSED(value); }
static inline void GBAudioWriteNR22(void* psg, uint8_t value) { UNUSED(psg); UNUSED(value); }
static inline void GBAudioWriteNR23(void* psg, uint8_t value) { UNUSED(psg); UNUSED(value); }
static inline void GBAudioWriteNR24(void* psg, uint8_t value) { UNUSED(psg); UNUSED(value); }
static inline void GBAudioWriteNR31(void* psg, uint8_t value) { UNUSED(psg); UNUSED(value); }
static inline void GBAudioWriteNR33(void* psg, uint8_t value) { UNUSED(psg); UNUSED(value); }
static inline void GBAudioWriteNR34(void* psg, uint8_t value) { UNUSED(psg); UNUSED(value); }
static inline void GBAudioWriteNR41(void* psg, uint8_t value) { UNUSED(psg); UNUSED(value); }
static inline void GBAudioWriteNR42(void* psg, uint8_t value) { UNUSED(psg); UNUSED(value); }
static inline void GBAudioWriteNR43(void* psg, uint8_t value) { UNUSED(psg); UNUSED(value); }
static inline void GBAudioWriteNR44(void* psg, uint8_t value) { UNUSED(psg); UNUSED(value); }
static inline int GBAudioRegisterBankVolumeGetVolumeGBA(uint8_t value) { return (value >> 5) & 0x3; }
void GBAIOWrite32(struct GBA* gba, uint32_t address, uint32_t value);
static inline int GBAMosaicControlGetBgV(uint16_t mosaic) { UNUSED(mosaic); return 0; }
static inline int GBAObjAttributesAGetMode(uint16_t a) { UNUSED(a); return 0; }
static inline int GBAObjAttributesAGetShape(uint16_t a) { UNUSED(a); return 0; }
static inline int GBAObjAttributesBGetSize(uint16_t b) { UNUSED(b); return 0; }
static inline int GBAObjAttributesCGetPriority(uint16_t c) { UNUSED(c); return 0; }
static inline bool GBAWindowControlIsBlendEnable(uint16_t control) { UNUSED(control); return false; }
static inline void* anonymousMemoryMap(size_t size) { UNUSED(size); return NULL; }
static inline void MutexLock(void* m) { UNUSED(m); }
static inline void MutexUnlock(void* m) { UNUSED(m); }
static inline void ConditionWait(void* c, void* m) { UNUSED(c); UNUSED(m); }
static inline void ConditionWake(void* c) { UNUSED(c); }
static inline bool ConditionWaitTimed(void* c, void* m, int timeoutMs) { UNUSED(c); UNUSED(m); UNUSED(timeoutMs); return false; }
enum RegisterBank ARMSelectBank(enum PrivilegeMode mode);
void ARMSetComponents(struct ARMCore* cpu, struct mCPUComponent* master, int extra, struct mCPUComponent** extras);
void ARMInit(struct ARMCore* cpu);
void ARMDeinit(struct ARMCore* cpu);
void ARMReset(struct ARMCore* cpu);
void ARMRunLoop(struct ARMCore* cpu);
void ARMRun(struct ARMCore* cpu);
static inline void mRTCGenericSourceInit(struct mRTCGenericSource* rtc, struct mCore* core) { UNUSED(rtc); UNUSED(core); }
static inline void mDirectorySetInit(struct mDirectorySet* dirs) { UNUSED(dirs); }
static inline void mDirectorySetDeinit(struct mDirectorySet* dirs) { UNUSED(dirs); }
static inline void mCoreConfigFreeOpts(struct mCoreOptions* opts) { UNUSED(opts); }
static inline const struct Configuration* mCoreConfigGetOverridesConst(const struct mCoreConfig* config) { UNUSED(config); return NULL; }
static inline const char* mCoreConfigGetValue(const struct mCoreConfig* config, const char* key) { UNUSED(config); UNUSED(key); return NULL; }
static inline bool mCoreConfigGetBoolValue(const struct mCoreConfig* config, const char* key, bool* out) { UNUSED(config); UNUSED(key); if (out) *out = false; return false; }
static inline bool mCoreConfigGetIntValue(const struct mCoreConfig* config, const char* key, int* out) { UNUSED(config); UNUSED(key); if (out) *out = 0; return false; }
static inline void mCoreConfigCopyValue(struct mCoreConfig* out, const struct mCoreConfig* in, const char* key) { UNUSED(out); UNUSED(in); UNUSED(key); }
static inline void GBACreate(struct GBA* gba) { UNUSED(gba); }
static inline void GBADestroy(struct GBA* gba) { UNUSED(gba); }
static inline void GBAVideoDummyRendererCreate(struct GBAVideoRenderer* renderer) { UNUSED(renderer); }
static inline void GBAVideoAssociateRenderer(struct GBAVideo* video, struct GBAVideoRenderer* renderer) { UNUSED(video); UNUSED(renderer); }
static inline void GBAVideoSoftwareRendererCreate(struct GBAVideoSoftwareRenderer* renderer) { UNUSED(renderer); }
static inline void mVideoThreadProxyCreate(struct mVideoThreadProxy* proxy) { UNUSED(proxy); }
static inline void GBAAudioResizeBuffer(void* audio, size_t samples) { UNUSED(audio); UNUSED(samples); }
static inline struct mCoreCallbacks* mCoreCallbacksListAppend(struct mCoreCallbacks* callbacks) { return callbacks; }
static inline void mCoreCallbacksListClear(struct mCoreCallbacks* callbacks) { UNUSED(callbacks); }
static inline size_t mCoreCallbacksListSize(struct mCoreCallbacks* callbacks) { return callbacks ? 1 : 0; }
static inline struct mCoreCallbacks* mCoreCallbacksListGetPointer(struct mCoreCallbacks* callbacks, size_t index) { return index == 0 ? callbacks : NULL; }
struct mAVStream {
	void (*videoDimensionsChanged)(struct mAVStream*, unsigned, unsigned);
	void (*audioRateChanged)(struct mAVStream*, unsigned);
};
static inline bool GBAIsMB(struct VFile* vf) { UNUSED(vf); return false; }
static inline struct VFile* VFileFromMemory(void* data, size_t size) { UNUSED(data); UNUSED(size); return NULL; }
static inline struct VFile* VFileMemChunk(const void* data, size_t size) { UNUSED(data); UNUSED(size); return NULL; }
static inline bool GBALoadMB(void* board, struct VFile* vf) { UNUSED(board); UNUSED(vf); return false; }
static inline bool GBALoadROM(void* board, struct VFile* vf) { UNUSED(board); UNUSED(vf); return false; }
static inline bool GBALoadSave(void* board, struct VFile* vf) { UNUSED(board); UNUSED(vf); return false; }
bool GBASavedataClone(struct GBASavedata* savedata, struct VFile* vf);
static inline bool GBAIsBIOS(struct VFile* vf) { UNUSED(vf); return false; }
static inline void GBALoadBIOS(void* board, struct VFile* vf) { UNUSED(board); UNUSED(vf); }
static inline void GBAUnloadROM(void* board) { UNUSED(board); }
static inline void GBASkipBIOS(void* board) { UNUSED(board); }
void GBASavedataMask(struct GBASavedata* savedata, struct VFile* vf, bool writeback);
void GBAOverrideApply(struct GBA* gba, const struct GBACartridgeOverride* ov);
void GBAOverrideApplyDefaults(struct GBA* gba, const struct Configuration* cfg);
static inline uint32_t doCrc32(const void* data, size_t size) { UNUSED(data); UNUSED(size); return 0; }
void mTimingInterrupt(struct mTiming* timing);
struct Patch { int _unused; };
static inline bool loadPatch(struct VFile* vf, struct Patch* patch) { UNUSED(vf); UNUSED(patch); return false; }
static inline void GBAApplyPatch(void* board, const struct Patch* patch) { UNUSED(board); UNUSED(patch); }
static inline void md5File(struct VFile* vf, void* out) { UNUSED(vf); memset(out, 0, 16); }
static inline void md5Buffer(const void* buf, size_t size, void* out) { UNUSED(buf); UNUSED(size); memset(out, 0, 16); }
static inline void sha1File(struct VFile* vf, void* out) { UNUSED(vf); memset(out, 0, 20); }
static inline void sha1Buffer(const void* buf, size_t size, void* out) { UNUSED(buf); UNUSED(size); memset(out, 0, 20); }
bool GBADeserialize(struct GBA* gba, const struct GBASerializedState* state);
void GBASerialize(struct GBA* gba, struct GBASerializedState* state);

enum {
	EXTDATA_SUBSYSTEM_START = 0x1000,
	GBA_SUBSYSTEM_VIDEO_RENDERER = 1,
	GBA_SUBSYSTEM_SIO_DRIVER = 2
};

struct mStateExtdataItem {
	size_t size;
	const void* data;
	void (*clean)(void*);
};

struct mStateExtdata { int _unused; };
static inline bool mStateExtdataGet(const struct mStateExtdata* ext, int id, struct mStateExtdataItem* item) { UNUSED(ext); UNUSED(id); UNUSED(item); return false; }
static inline void mStateExtdataPut(struct mStateExtdata* ext, int id, const struct mStateExtdataItem* item) { UNUSED(ext); UNUSED(id); UNUSED(item); }
static inline int GBASIOMultiplayerGetBaud(uint16_t siocnt) { return siocnt & 3; }
static inline bool GBASIONormalIsInternalSc(uint16_t siocnt) { return (siocnt & 1) != 0; }
static inline uint16_t GBASIOMultiplayerClearBusy(uint16_t v) { return (uint16_t) (v & ~0x0080); }
static inline bool GBASIOMultiplayerIsIrq(uint16_t v) { return (v & 0x4000) != 0; }
static inline uint16_t GBASIONormalClearStart(uint16_t v) { return (uint16_t) (v & ~0x0080); }
static inline bool GBASIONormalIsIrq(uint16_t v) { return (v & 0x4000) != 0; }
enum { JOYSTAT_RECV = 0x0004, JOYSTAT_TRANS = 0x0008 };
static inline size_t mAudioBufferAvailable(const struct mAudioBuffer* buf) { UNUSED(buf); return 0; }
static inline void mappedMemoryFree(void* p, size_t size) { UNUSED(size); free(p); }
#define STORE_32(v, o, p) do { UNUSED(o); uint32_t _tmp = (uint32_t) (v); memcpy((p), &_tmp, sizeof(uint32_t)); } while (0)
#define LOAD_32(v, o, p) do { UNUSED(o); memcpy(&(v), (p), sizeof(uint32_t)); } while (0)
#define STORE_16(v, o, p) do { UNUSED(o); uint16_t _tmp = (uint16_t) (v); memcpy((p), &_tmp, sizeof(uint16_t)); } while (0)
#define LOAD_16(v, o, p) do { UNUSED(o); memcpy(&(v), (p), sizeof(uint16_t)); } while (0)
#define STORE_64LE(v, o, p) do { UNUSED(o); uint64_t _tmp = (uint64_t) (v); memcpy((p), &_tmp, sizeof(uint64_t)); } while (0)
#define LOAD_64LE(v, o, p) do { UNUSED(o); memcpy(&(v), (p), sizeof(uint64_t)); } while (0)

#ifndef mCALLBACKS_INVOKE
#define mCALLBACKS_INVOKE(...)
#endif

typedef void (*ARMInstruction)(struct ARMCore*, uint32_t);
typedef void (*ThumbInstruction)(struct ARMCore*, uint16_t);
#ifndef DECLARE_ARM_EMITTER_BLOCK
#define DECLARE_ARM_EMITTER_BLOCK(x)
#endif
extern const ARMInstruction _armTable[0x1000];
extern const ThumbInstruction _thumbTable[0x400];

#ifndef MODE_FIQ
#define MODE_FIQ 0x11
#endif

#ifndef BANK_FIQ
#define BANK_FIQ 0
#endif

#ifndef ARM_PC
#define ARM_PC 15
#endif
#ifndef ARM_LR
#define ARM_LR 14
#endif
#ifndef ARM_SP
#define ARM_SP 13
#endif

#ifndef ARM_SIGN
#define ARM_SIGN(v) (((v) >> 31) & 1)
#endif

#ifndef ATTRIBUTE_UNUSED
#define ATTRIBUTE_UNUSED __attribute__((unused))
#endif

#ifndef UNLIKELY
#define UNLIKELY(x) (x)
#endif

#ifndef ARM_PREFETCH_CYCLES
#define ARM_PREFETCH_CYCLES 0
#endif

#ifndef WORD_SIZE_ARM
#define WORD_SIZE_ARM 4
#endif
#ifndef WORD_SIZE_THUMB
#define WORD_SIZE_THUMB 2
#endif

#ifndef MODE_ARM
#define MODE_ARM 0
#endif
#ifndef MODE_THUMB
#define MODE_THUMB 1
#endif

enum {
	LSM_DA = 0,
	LSM_DB = 1,
	LSM_IA = 2,
	LSM_IB = 3
};

static inline uint32_t ROR(uint32_t value, unsigned shift) {
	shift &= 31;
	if (!shift) {
		return value;
	}
	return (value >> shift) | (value << (32 - shift));
}

static inline bool ARM_CARRY_FROM(uint32_t m, uint32_t n, uint32_t d) { UNUSED(d); return m > ~n; }
static inline bool ARM_BORROW_FROM(uint32_t m, uint32_t n, uint32_t d) { UNUSED(d); return m >= n; }
static inline bool ARM_BORROW_FROM_CARRY(uint32_t m, uint32_t n, uint32_t d, uint32_t c) { UNUSED(d); return m >= (n + (c ? 1u : 0u)); }
static inline uint64_t ARM_UXT_64(uint32_t v) { return (uint64_t) v; }
static inline int32_t ARM_SXT_8(uint32_t v) { return (int8_t) (v & 0xFF); }
static inline int32_t ARM_SXT_16(uint32_t v) { return (int16_t) (v & 0xFFFF); }
static inline bool ARM_V_ADDITION(uint32_t m, uint32_t n, uint32_t d) { return ((~(m ^ n) & (m ^ d)) >> 31) != 0; }
static inline bool ARM_V_SUBTRACTION(uint32_t m, uint32_t n, uint32_t d) { return (((m ^ n) & (m ^ d)) >> 31) != 0; }
static inline int ARMWritePC(struct ARMCore* cpu) { UNUSED(cpu); return 0; }
static inline int ThumbWritePC(struct ARMCore* cpu) { UNUSED(cpu); return 0; }
void ARMSetPrivilegeMode(struct ARMCore* cpu, enum PrivilegeMode mode);
static inline void _ARMSetMode(struct ARMCore* cpu, int thumbMode) { if (cpu) { cpu->executionMode = thumbMode ? MODE_THUMB : MODE_ARM; } }
static inline bool _ARMModeHasSPSR(int mode) { UNUSED(mode); return false; }
static inline void _ARMReadCPSR(struct ARMCore* cpu) { UNUSED(cpu); }

#ifndef ARM_ILL
#define ARM_ILL do {} while (0)
#endif
#ifndef ARM_STUB
#define ARM_STUB do {} while (0)
#endif

#ifndef ARM_WAIT_SMUL
#define ARM_WAIT_SMUL(v, w) do { UNUSED(v); UNUSED(w); } while (0)
#endif
#ifndef ARM_WAIT_UMUL
#define ARM_WAIT_UMUL(v, w) do { UNUSED(v); UNUSED(w); } while (0)
#endif
#ifndef ARM_WAIT_SMULL
#define ARM_WAIT_SMULL(v, w) do { UNUSED(v); UNUSED(w); } while (0)
#endif
#ifndef ARM_WAIT_UMULL
#define ARM_WAIT_UMULL(v, w) do { UNUSED(v); UNUSED(w); } while (0)
#endif
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
