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

#ifndef GBA_CORE_COMMON_FOUNDATION_DEFINED
#define GBA_CORE_COMMON_FOUNDATION_DEFINED 1

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <sys/types.h>
#include <stdlib.h>
#include <stdio.h>

#ifndef MAX_GBAS
#define MAX_GBAS 4
#endif

#ifndef GBA_CORE_ENABLE_FULL_SIO_RUNTIME
#define GBA_CORE_ENABLE_FULL_SIO_RUNTIME 1
#endif

struct mTiming;
typedef void (*mTimingCallback)(struct mTiming* timing, void* context, uint32_t cyclesLate);

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
	void* data;
	void* currentBank;
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
};

struct GBAHardware {
	unsigned devices;
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
	void* (*map)(struct VFile*, size_t, int);
	void (*unmap)(struct VFile*, void*, size_t);
};

struct mAudioBuffer {
	size_t _unused;
};

struct GBAVideoProxyRenderer {
	struct GBAVideoRenderer d;
	int flushScanline;
};

struct mVideoThreadProxy {
	struct { int _unused; } d;
};

struct mCoreCallbacks {
	void (*videoFrameEnded)(void*);
	void* context;
};

struct mCPUComponent {
	int _unused;
};

#ifndef CPU_COMPONENT_MAX
#define CPU_COMPONENT_MAX 16
#endif

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
	IDLE_LOOP_REMOVE = 2
};

void GBASavedataForceType(struct GBASavedata* savedata, int type);
void GBASavedataRTCRead(struct GBASavedata* savedata);
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
	} video;
	struct {
		bool enable;
		int sampleInterval;
		size_t samples;
		struct { struct { int _unused; } buffer; } psg;
		int chATimer;
		int chBTimer;
		bool chALeft;
		bool chARight;
		bool chBLeft;
		bool chBRight;
	} audio;
	struct { int _unused; } d;
	struct { int _unused; } coreCallbacks;
	void* sync;
	void* rtcSource;
	void* stream;
	struct VFile* biosVf;
	struct VFile* romVf;
	struct VFile* mbVf;
	struct mKeyCallback* keyCallback;
	struct { void (*setRumble)(void*, bool, int32_t); }* rumble;
	int32_t lastRumble;
	bool vbaBugCompat;
	uint32_t idleLoop;
	int idleOptimization;
	uint32_t romCrc32;
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
#endif

#ifndef FLASH_STATE_RAW
#define FLASH_STATE_RAW 0
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
	BG3HOFS = 0x028, BG3VOFS = 0x02A, BG3PA = 0x030, BG3PD = 0x036,
	KEYINPUT = 0x130, SOUNDBIAS = 0x088, POSTFLG = 0x300,
	INTERNAL_EXWAITCNT_LO = 0x204, INTERNAL_EXWAITCNT_HI = 0x206, INTERNAL_MAX = 0x400,
	SIOMULTI0 = 0x120, SIOMULTI1 = 0x122, SIOMULTI2 = 0x124, SIOMULTI3 = 0x126,
	SIODATA32_LO = 0x120, SIODATA32_HI = 0x122, SIODATA8 = 0x12A, SIOCNT = 0x128, RCNT = 0x134,
	SIOMLT_SEND = 0x12A, JOYCNT = 0x140, JOY_RECV_LO = 0x150, JOY_TRANS_LO = 0x154,
	SOUND1CNT_LO = 0x060, SOUNDCNT_LO = 0x080
};

#define GBA_REG_DISPCNT GBA_REG(DISPCNT)
#define GBA_REG_SIODATA8 GBA_REG(SIODATA8)
#define GBA_REG_SIODATA32_LO GBA_REG(SIODATA32_LO)
#define GBA_REG_SIODATA32_HI GBA_REG(SIODATA32_HI)
#define GBA_REG_SIOCNT GBA_REG(SIOCNT)
#define GBA_REG_RCNT GBA_REG(RCNT)
#define GBA_REG_SIOMLT_SEND GBA_REG(SIOMLT_SEND)
#define GBA_REG_JOYCNT GBA_REG(JOYCNT)
#define GBA_REG_JOY_RECV_LO GBA_REG(JOY_RECV_LO)
#define GBA_REG_JOY_TRANS_LO GBA_REG(JOY_TRANS_LO)
#define GBA_REG_VCOUNT GBA_REG(VCOUNT)
#define GBA_REG_DISPSTAT GBA_REG(DISPSTAT)
#define GBA_REG_SOUND1CNT_LO GBA_REG(SOUND1CNT_LO)
#define GBA_REG_SOUNDCNT_LO GBA_REG(SOUNDCNT_LO)

#define GBA_REG_TMCNT_LO(id) (0x100 + ((id) * 4))

static inline uint32_t hash32(const void* data, size_t size, uint32_t seed) { UNUSED(data); UNUSED(size); return seed; }
int32_t mTimingCurrentTime(const struct mTiming* timing);
void GBASIOReset(struct GBASIO* sio);
static inline void GBARaiseIRQ(struct GBA* gba, int irq, int32_t cyclesLate) { UNUSED(gba); UNUSED(irq); UNUSED(cyclesLate); }
static inline bool GBATimerFlagsIsCountUp(uint16_t flags) { UNUSED(flags); return false; }
static inline bool GBATimerFlagsIsDoIrq(uint16_t flags) { UNUSED(flags); return false; }
static inline bool GBATimerFlagsIsEnable(uint16_t flags) { return (flags & 0x0080) != 0; }
static inline unsigned GBATimerFlagsGetPrescaleBits(uint16_t flags) { return flags & 0x3FF; }
static inline uint16_t GBATimerFlagsSetPrescaleBits(uint16_t flags, unsigned bits) { return (uint16_t) ((flags & ~0x3FF) | (bits & 0x3FF)); }
static inline uint16_t GBATimerFlagsTestFillCountUp(uint16_t flags, bool v) { return v ? (uint16_t) (flags | 0x0004) : (uint16_t) (flags & ~0x0004); }
static inline uint16_t GBATimerFlagsTestFillDoIrq(uint16_t flags, bool v) { return v ? (uint16_t) (flags | 0x0040) : (uint16_t) (flags & ~0x0040); }
static inline uint16_t GBATimerFlagsTestFillEnable(uint16_t flags, bool v) { return v ? (uint16_t) (flags | 0x0080) : (uint16_t) (flags & ~0x0080); }
static inline void GBATimerUpdateRegister(struct GBA* gba, int timerId, int32_t cyclesLate) { UNUSED(gba); UNUSED(timerId); UNUSED(cyclesLate); }
static inline bool GBADMARegisterIsEnable(uint16_t control) { return (control & 0x8000) != 0; }
static inline void GBAAudioSampleFIFO(void* audio, int fifo, uint32_t cyclesLate) { UNUSED(audio); UNUSED(fifo); UNUSED(cyclesLate); }
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
static inline void ARMSelectBank(struct ARMCore* cpu, unsigned mode) { UNUSED(cpu); UNUSED(mode); }
static inline int GBASIOMultiplayerGetBaud(uint16_t siocnt) { return siocnt & 3; }
static inline bool GBASIONormalIsInternalSc(uint16_t siocnt) { return (siocnt & 1) != 0; }
static inline uint16_t GBASIOMultiplayerClearBusy(uint16_t v) { return (uint16_t) (v & ~0x0080); }
static inline bool GBASIOMultiplayerIsIrq(uint16_t v) { return (v & 0x4000) != 0; }
static inline uint16_t GBASIONormalClearStart(uint16_t v) { return (uint16_t) (v & ~0x0080); }
static inline bool GBASIONormalIsIrq(uint16_t v) { return (v & 0x4000) != 0; }
static inline size_t mAudioBufferAvailable(const struct mAudioBuffer* buf) { UNUSED(buf); return 0; }
static inline void mappedMemoryFree(void* p, size_t size) { UNUSED(size); free(p); }

#ifndef mCALLBACKS_INVOKE
#define mCALLBACKS_INVOKE(...)
#endif

#ifndef MODE_FIQ
#define MODE_FIQ 0x11
#endif

#ifndef BANK_FIQ
#define BANK_FIQ 0
#endif

#ifndef ARM_PC
#define ARM_PC 15
#endif

#ifndef ARM_SIGN
#define ARM_SIGN(v) (((v) >> 31) & 1)
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
