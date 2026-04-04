#if defined(__cplusplus)
// Imported from reference implementation: gba.cpp
/* BEGIN gba.cpp */
#include "../embedded_include/gba/gba.h"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#ifndef _MSC_VER
#include <strings.h>
#endif

#include "../embedded_include/base/file_util.h"
#include "../embedded_include/base/message.h"
#include "../embedded_include/base/port.h"
#include "../embedded_include/base/sizes.h"
#include "../embedded_include/base/system.h"
#include "../embedded_include/gba/gbaCheats.h"
#include "../embedded_include/gba/gbaCpu.h"
#include "../embedded_include/gba/gbaEeprom.h"
#include "../embedded_include/gba/gbaFlash.h"
#include "../embedded_include/gba/gbaGlobals.h"
#include "../embedded_include/gba/gbaGfx.h"
#include "../embedded_include/gba/gbaInline.h"
#include "../embedded_include/gba/gbaPrint.h"
#include "../embedded_include/gba/gbaSound.h"
#include "../embedded_include/gba/internal/gbaBios.h"
#include "../embedded_include/gba/internal/gbaEreader.h"
#include "../embedded_include/gba/internal/gbaSram.h"

#if defined(VBAM_ENABLE_DEBUGGER)
#include "../embedded_include/gba/gbaElf.h"
#endif  // defined(VBAM_ENABLE_DEBUGGER)

#if !defined(NO_LINK)
#include "../embedded_include/gba/gbaLink.h"
#endif  // !defined(NOLINK)

#if !defined(__LIBRETRO__)
#include "../embedded_include/base/image_util.h"
#endif // !__LIBRETRO__

#ifdef PROFILING
#include "../embedded_include/gba/prof/prof.h"
#endif

#ifdef __GNUC__
#define _stricmp strcasecmp
#endif

#ifdef _MSC_VER
#define strdup _strdup
#endif

extern int emulating;
bool debugger = false;

int SWITicks = 0;
int IRQTicks = 0;

uint32_t mastercode = 0;
int layerEnableDelay = 0;
bool busPrefetch = false;
bool busPrefetchEnable = false;
uint32_t busPrefetchCount = 0;
int cpuDmaTicksToUpdate = 0;
int cpuDmaCount = 0;
bool cpuDmaRunning = false;
uint32_t cpuDmaPC = 0;
int dummyAddress = 0;
uint32_t cpuDmaLatchData[4];
uint32_t cpuDmaBusValue = 0;

const uint32_t cpuDmaSrcMask[4] = { 0x07ffffff, 0x0fffffff, 0x0fffffff, 0x0fffffff };
const uint32_t cpuDmaDstMask[4] = { 0x07ffffff, 0x07ffffff, 0x07ffffff, 0x0fffffff };

bool cpuBreakLoop = false;
int cpuNextEvent = 0;

bool intState = false;
bool stopState = false;
bool holdState = false;
int holdType = 0;
bool cpuSramEnabled = true;
bool cpuFlashEnabled = true;
bool cpuEEPROMEnabled = true;
bool cpuEEPROMSensorEnabled = false;

uint32_t cpuPrefetch[2];

int cpuTotalTicks = 0;
#ifdef PROFILING
int profilingTicks = 0;
int profilingTicksReload = 0;
static profile_segment* profilSegment = NULL;
#endif

#ifdef VBAM_ENABLE_DEBUGGER
uint8_t freezeWorkRAM[SIZE_WRAM];
uint8_t freezeInternalRAM[SIZE_IRAM];
uint8_t freezeVRAM[0x18000];
uint8_t freezePRAM[SIZE_PRAM];
uint8_t freezeOAM[SIZE_OAM];
bool debugger_last;
#endif

int lcdTicks = (coreOptions.useBios && !coreOptions.skipBios) ? 1008 : 208;
uint8_t timerOnOffDelay = 0;
uint16_t timer0Value = 0;
bool timer0On = false;
int timer0Ticks = 0;
int timer0Reload = 0;
int timer0ClockReload = 0;
uint16_t timer1Value = 0;
bool timer1On = false;
int timer1Ticks = 0;
int timer1Reload = 0;
int timer1ClockReload = 0;
uint16_t timer2Value = 0;
bool timer2On = false;
int timer2Ticks = 0;
int timer2Reload = 0;
int timer2ClockReload = 0;
uint16_t timer3Value = 0;
bool timer3On = false;
int timer3Ticks = 0;
int timer3Reload = 0;
int timer3ClockReload = 0;
uint32_t dma0Source = 0;
uint32_t dma0Dest = 0;
uint32_t dma1Source = 0;
uint32_t dma1Dest = 0;
uint32_t dma2Source = 0;
uint32_t dma2Dest = 0;
uint32_t dma3Source = 0;
uint32_t dma3Dest = 0;
void (*cpuSaveGameFunc)(uint32_t, uint8_t) = flashSaveDecide;
void (*renderLine)() = mode0RenderLine;
bool fxOn = false;
bool windowOn = false;
int frameCount = 0;
char g_buffer[1024];
uint32_t lastTime = 0;
int g_count = 0;

int capture = 0;
int capturePrevious = 0;
int captureNumber = 0;

int armOpcodeCount = 0;
int thumbOpcodeCount = 0;

const int TIMER_TICKS[4] = {
    0,
    6,
    8,
    10
};

const uint32_t objTilesAddress[3] = { 0x010000, 0x014000, 0x014000 };
const uint8_t gamepakRamWaitState[4] = { 4, 3, 2, 8 };
const uint8_t gamepakWaitState[4] = { 4, 3, 2, 8 };
const uint8_t gamepakWaitState0[2] = { 2, 1 };
const uint8_t gamepakWaitState1[2] = { 4, 1 };
const uint8_t gamepakWaitState2[2] = { 8, 1 };

uint8_t memoryWait[16] = { 0, 0, 2, 0, 0, 0, 0, 0, 4, 4, 4, 4, 4, 4, 4, 0 };
uint8_t memoryWait32[16] = { 0, 0, 5, 0, 0, 1, 1, 0, 7, 7, 9, 9, 13, 13, 4, 0 };
uint8_t memoryWaitSeq[16] = { 0, 0, 2, 0, 0, 0, 0, 0, 2, 2, 4, 4, 8, 8, 4, 0 };
uint8_t memoryWaitSeq32[16] = { 0, 0, 5, 0, 0, 1, 1, 0, 5, 5, 9, 9, 17, 17, 4, 0 };

GBAMatrix_t stateMatrix;

// The videoMemoryWait constants are used to add some waitstates
// if the opcode access video memory data outside of vblank/hblank
// It seems to happen on only one ticks for each pixel.
// Not used for now (too problematic with current code).
//const uint8_t videoMemoryWait[16] =
//  {0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0};

uint8_t biosProtected[4];

#ifdef WORDS_BIGENDIAN
bool cpuBiosSwapped = false;
#endif

uint32_t myROM[] = {
    0xEA000006,
    0xEA000093,
    0xEA000006,
    0x00000000,
    0x00000000,
    0x00000000,
    0xEA000088,
    0x00000000,
    0xE3A00302,
    0xE1A0F000,
    0xE92D5800,
    0xE55EC002,
    0xE28FB03C,
    0xE79BC10C,
    0xE14FB000,
    0xE92D0800,
    0xE20BB080,
    0xE38BB01F,
    0xE129F00B,
    0xE92D4004,
    0xE1A0E00F,
    0xE12FFF1C,
    0xE8BD4004,
    0xE3A0C0D3,
    0xE129F00C,
    0xE8BD0800,
    0xE169F00B,
    0xE8BD5800,
    0xE1B0F00E,
    0x0000009C,
    0x0000009C,
    0x0000009C,
    0x0000009C,
    0x000001F8,
    0x000001F0,
    0x000000AC,
    0x000000A0,
    0x000000FC,
    0x00000168,
    0xE12FFF1E,
    0xE1A03000,
    0xE1A00001,
    0xE1A01003,
    0xE2113102,
    0x42611000,
    0xE033C040,
    0x22600000,
    0xE1B02001,
    0xE15200A0,
    0x91A02082,
    0x3AFFFFFC,
    0xE1500002,
    0xE0A33003,
    0x20400002,
    0xE1320001,
    0x11A020A2,
    0x1AFFFFF9,
    0xE1A01000,
    0xE1A00003,
    0xE1B0C08C,
    0x22600000,
    0x42611000,
    0xE12FFF1E,
    0xE92D0010,
    0xE1A0C000,
    0xE3A01001,
    0xE1500001,
    0x81A000A0,
    0x81A01081,
    0x8AFFFFFB,
    0xE1A0000C,
    0xE1A04001,
    0xE3A03000,
    0xE1A02001,
    0xE15200A0,
    0x91A02082,
    0x3AFFFFFC,
    0xE1500002,
    0xE0A33003,
    0x20400002,
    0xE1320001,
    0x11A020A2,
    0x1AFFFFF9,
    0xE0811003,
    0xE1B010A1,
    0xE1510004,
    0x3AFFFFEE,
    0xE1A00004,
    0xE8BD0010,
    0xE12FFF1E,
    0xE0010090,
    0xE1A01741,
    0xE2611000,
    0xE3A030A9,
    0xE0030391,
    0xE1A03743,
    0xE2833E39,
    0xE0030391,
    0xE1A03743,
    0xE2833C09,
    0xE283301C,
    0xE0030391,
    0xE1A03743,
    0xE2833C0F,
    0xE28330B6,
    0xE0030391,
    0xE1A03743,
    0xE2833C16,
    0xE28330AA,
    0xE0030391,
    0xE1A03743,
    0xE2833A02,
    0xE2833081,
    0xE0030391,
    0xE1A03743,
    0xE2833C36,
    0xE2833051,
    0xE0030391,
    0xE1A03743,
    0xE2833CA2,
    0xE28330F9,
    0xE0000093,
    0xE1A00840,
    0xE12FFF1E,
    0xE3A00001,
    0xE3A01001,
    0xE92D4010,
    0xE3A03000,
    0xE3A04001,
    0xE3500000,
    0x1B000004,
    0xE5CC3301,
    0xEB000002,
    0x0AFFFFFC,
    0xE8BD4010,
    0xE12FFF1E,
    0xE3A0C301,
    0xE5CC3208,
    0xE15C20B8,
    0xE0110002,
    0x10222000,
    0x114C20B8,
    0xE5CC4208,
    0xE12FFF1E,
    0xE92D500F,
    0xE3A00301,
    0xE1A0E00F,
    0xE510F004,
    0xE8BD500F,
    0xE25EF004,
    0xE59FD044,
    0xE92D5000,
    0xE14FC000,
    0xE10FE000,
    0xE92D5000,
    0xE3A0C302,
    0xE5DCE09C,
    0xE35E00A5,
    0x1A000004,
    0x05DCE0B4,
    0x021EE080,
    0xE28FE004,
    0x159FF018,
    0x059FF018,
    0xE59FD018,
    0xE8BD5000,
    0xE169F00C,
    0xE8BD5000,
    0xE25EF004,
    0x03007FF0,
    0x09FE2000,
    0x09FFC000,
    0x03007FE0
};

variable_desc saveGameStruct[] = {
    { &DISPCNT, sizeof(uint16_t) },
    { &DISPSTAT, sizeof(uint16_t) },
    { &VCOUNT, sizeof(uint16_t) },
    { &BG0CNT, sizeof(uint16_t) },
    { &BG1CNT, sizeof(uint16_t) },
    { &BG2CNT, sizeof(uint16_t) },
    { &BG3CNT, sizeof(uint16_t) },
    { &BG0HOFS, sizeof(uint16_t) },
    { &BG0VOFS, sizeof(uint16_t) },
    { &BG1HOFS, sizeof(uint16_t) },
    { &BG1VOFS, sizeof(uint16_t) },
    { &BG2HOFS, sizeof(uint16_t) },
    { &BG2VOFS, sizeof(uint16_t) },
    { &BG3HOFS, sizeof(uint16_t) },
    { &BG3VOFS, sizeof(uint16_t) },
    { &BG2PA, sizeof(uint16_t) },
    { &BG2PB, sizeof(uint16_t) },
    { &BG2PC, sizeof(uint16_t) },
    { &BG2PD, sizeof(uint16_t) },
    { &BG2X_L, sizeof(uint16_t) },
    { &BG2X_H, sizeof(uint16_t) },
    { &BG2Y_L, sizeof(uint16_t) },
    { &BG2Y_H, sizeof(uint16_t) },
    { &BG3PA, sizeof(uint16_t) },
    { &BG3PB, sizeof(uint16_t) },
    { &BG3PC, sizeof(uint16_t) },
    { &BG3PD, sizeof(uint16_t) },
    { &BG3X_L, sizeof(uint16_t) },
    { &BG3X_H, sizeof(uint16_t) },
    { &BG3Y_L, sizeof(uint16_t) },
    { &BG3Y_H, sizeof(uint16_t) },
    { &WIN0H, sizeof(uint16_t) },
    { &WIN1H, sizeof(uint16_t) },
    { &WIN0V, sizeof(uint16_t) },
    { &WIN1V, sizeof(uint16_t) },
    { &WININ, sizeof(uint16_t) },
    { &WINOUT, sizeof(uint16_t) },
    { &MOSAIC, sizeof(uint16_t) },
    { &BLDMOD, sizeof(uint16_t) },
    { &COLEV, sizeof(uint16_t) },
    { &COLY, sizeof(uint16_t) },
    { &DM0SAD_L, sizeof(uint16_t) },
    { &DM0SAD_H, sizeof(uint16_t) },
    { &DM0DAD_L, sizeof(uint16_t) },
    { &DM0DAD_H, sizeof(uint16_t) },
    { &DM0CNT_L, sizeof(uint16_t) },
    { &DM0CNT_H, sizeof(uint16_t) },
    { &DM1SAD_L, sizeof(uint16_t) },
    { &DM1SAD_H, sizeof(uint16_t) },
    { &DM1DAD_L, sizeof(uint16_t) },
    { &DM1DAD_H, sizeof(uint16_t) },
    { &DM1CNT_L, sizeof(uint16_t) },
    { &DM1CNT_H, sizeof(uint16_t) },
    { &DM2SAD_L, sizeof(uint16_t) },
    { &DM2SAD_H, sizeof(uint16_t) },
    { &DM2DAD_L, sizeof(uint16_t) },
    { &DM2DAD_H, sizeof(uint16_t) },
    { &DM2CNT_L, sizeof(uint16_t) },
    { &DM2CNT_H, sizeof(uint16_t) },
    { &DM3SAD_L, sizeof(uint16_t) },
    { &DM3SAD_H, sizeof(uint16_t) },
    { &DM3DAD_L, sizeof(uint16_t) },
    { &DM3DAD_H, sizeof(uint16_t) },
    { &DM3CNT_L, sizeof(uint16_t) },
    { &DM3CNT_H, sizeof(uint16_t) },
    { &TM0D, sizeof(uint16_t) },
    { &TM0CNT, sizeof(uint16_t) },
    { &TM1D, sizeof(uint16_t) },
    { &TM1CNT, sizeof(uint16_t) },
    { &TM2D, sizeof(uint16_t) },
    { &TM2CNT, sizeof(uint16_t) },
    { &TM3D, sizeof(uint16_t) },
    { &TM3CNT, sizeof(uint16_t) },
    { &P1, sizeof(uint16_t) },
    { &IE, sizeof(uint16_t) },
    { &IF, sizeof(uint16_t) },
    { &IME, sizeof(uint16_t) },
    { &holdState, sizeof(bool) },
    { &holdType, sizeof(int) },
    { &lcdTicks, sizeof(int) },
    { &timer0On, sizeof(bool) },
    { &timer0Ticks, sizeof(int) },
    { &timer0Reload, sizeof(int) },
    { &timer0ClockReload, sizeof(int) },
    { &timer1On, sizeof(bool) },
    { &timer1Ticks, sizeof(int) },
    { &timer1Reload, sizeof(int) },
    { &timer1ClockReload, sizeof(int) },
    { &timer2On, sizeof(bool) },
    { &timer2Ticks, sizeof(int) },
    { &timer2Reload, sizeof(int) },
    { &timer2ClockReload, sizeof(int) },
    { &timer3On, sizeof(bool) },
    { &timer3Ticks, sizeof(int) },
    { &timer3Reload, sizeof(int) },
    { &timer3ClockReload, sizeof(int) },
    { &dma0Source, sizeof(uint32_t) },
    { &dma0Dest, sizeof(uint32_t) },
    { &dma1Source, sizeof(uint32_t) },
    { &dma1Dest, sizeof(uint32_t) },
    { &dma2Source, sizeof(uint32_t) },
    { &dma2Dest, sizeof(uint32_t) },
    { &dma3Source, sizeof(uint32_t) },
    { &dma3Dest, sizeof(uint32_t) },
    { &fxOn, sizeof(bool) },
    { &windowOn, sizeof(bool) },
    { &N_FLAG, sizeof(bool) },
    { &C_FLAG, sizeof(bool) },
    { &Z_FLAG, sizeof(bool) },
    { &V_FLAG, sizeof(bool) },
    { &armState, sizeof(bool) },
    { &armIrqEnable, sizeof(bool) },
    { &armNextPC, sizeof(uint32_t) },
    { &armMode, sizeof(int) },
    { &coreOptions.saveType, sizeof(int) },
    { NULL, 0 }
};

static int romSize = SIZE_ROM;
static int pristineRomSize = 0;

#define MAPPING_MASK (GBA_MATRIX_MAPPINGS_MAX - 1)

static void _remapMatrix(GBAMatrix_t *matrix)
{
    if (matrix == NULL) {
        log("Matrix is NULL");
        return;
    }

    if (matrix->vaddr & 0xFFFFE1FF) {
        log("Invalid Matrix mapping: %08X", matrix->vaddr);
        return;
    }
    if (matrix->size & 0xFFFFE1FF) {
        log("Invalid Matrix size: %08X", matrix->size);
        return;
    }
    if ((matrix->vaddr + matrix->size - 1) & 0xFFFFE000) {
        log("Invalid Matrix mapping end: %08X", matrix->vaddr + matrix->size);
        return;
    }
    int start = matrix->vaddr >> 9;
    int size = (matrix->size >> 9) & MAPPING_MASK;
    int i;
    for (i = 0; i < size; ++i) {
        matrix->mappings[(start + i) & MAPPING_MASK] = matrix->paddr + (i << 9);
    }

    if ((g_rom2 != NULL) && (g_rom != NULL)) {
        memcpy(&g_rom[matrix->vaddr], &g_rom2[matrix->paddr], matrix->size);
    }
}

void gbaUpdateRomSize(int size)
{
    // Only change memory block if new size is larger
    if (size > romSize) {
        romSize = size;

        uint8_t* tmp = (uint8_t*)realloc(g_rom, romSize);
        g_rom = tmp;
    }
}

size_t gbaGetRomSize() {
    return romSize;
}

#ifdef PROFILING
void cpuProfil(profile_segment* seg)
{
    profilSegment = seg;
}

void cpuEnableProfiling(int hz)
{
    if (hz == 0)
        hz = 100;
    profilingTicks = profilingTicksReload = 16777216 / hz;
    profSetHertz(hz);
}
#endif


void CPUCleanUp()
{
#ifdef PROFILING
    if (profilingTicksReload) {
        profCleanup();
    }
#endif

#if defined(VBAM_ENABLE_DEBUGGER)
    // Free debugger map buffers. These are allocated in SetMapMasks() 
    // and must be freed here before the rest of the emulator state 
	// is torn down to prevent leaking on reset and rom change.
    for (int i = 0; i < 16; i++) {
        if (map[i].breakPoints != NULL) {
            free(map[i].breakPoints);
            map[i].breakPoints = NULL;
        }
        if (map[i].trace != NULL) {
            free(map[i].trace);
            map[i].trace = NULL;
        }
    }
#endif  // defined(VBAM_ENABLE_DEBUGGER)

    if (g_rom != NULL) {
        free(g_rom);
        g_rom = NULL;
    }

    if (g_rom2 != NULL) {
        free(g_rom2);
        g_rom2 = NULL;
    }

    if (g_vram != NULL) {
        free(g_vram);
        g_vram = NULL;
    }

    if (g_paletteRAM != NULL) {
        free(g_paletteRAM);
        g_paletteRAM = NULL;
    }

    if (g_internalRAM != NULL) {
        free(g_internalRAM);
        g_internalRAM = NULL;
    }

    if (g_workRAM != NULL) {
        free(g_workRAM);
        g_workRAM = NULL;
    }

    if (g_bios != NULL) {
        free(g_bios);
        g_bios = NULL;
    }

    if (g_pix != NULL) {
        free(g_pix);
        g_pix = NULL;
    }

    if (g_oam != NULL) {
        free(g_oam);
        g_oam = NULL;
    }

    if (g_ioMem != NULL) {
        free(g_ioMem);
        g_ioMem = NULL;
    }

#if defined(VBAM_ENABLE_DEBUGGER)
    elfCleanUp();
#endif  // defined(VBAM_ENABLE_DEBUGGER)

    systemSaveUpdateCounter = SYSTEM_SAVE_NOT_UPDATED;

    emulating = 0;
}

void SetMapMasks()
{
    map[0].mask = 0x3FFF;
    map[2].mask = 0x3FFFF;
    map[3].mask = 0x7FFF;
    map[4].mask = 0x3FF;
    map[5].mask = 0x3FF;
    map[6].mask = 0x1FFFF;
    map[7].mask = 0x3FF;
    map[8].mask = 0x1FFFFFF;
    map[9].mask = 0x1FFFFFF;
    map[10].mask = 0x1FFFFFF;
    map[12].mask = 0x1FFFFFF;
    map[14].mask = 0xFFFF;

#ifdef VBAM_ENABLE_DEBUGGER
    for (int i = 0; i < 16; i++) {
        map[i].size = map[i].mask + 1;

        const size_t bpSize = map[i].size >> 1;
        const size_t trSize = map[i].size >> 3;

        if (bpSize > 0) {
            if (map[i].breakPoints == NULL) {
                map[i].breakPoints = (uint8_t*)calloc(bpSize, sizeof(uint8_t));
                if (map[i].breakPoints == NULL) {
                    systemMessage(MSG_OUT_OF_MEMORY, N_("Failed to allocate memory for %s"),
                        "BREAKPOINTS");
                }
            } else {
                memset(map[i].breakPoints, 0, bpSize * sizeof(uint8_t));
            }
        }

        if (trSize > 0) {
            if (map[i].trace == NULL) {
                map[i].trace = (uint8_t*)calloc(trSize, sizeof(uint8_t));
                if (map[i].trace == NULL) {
                    systemMessage(MSG_OUT_OF_MEMORY, N_("Failed to allocate memory for %s"),
                        "TRACE");
                }
            } else {
                memset(map[i].trace, 0, trSize * sizeof(uint8_t));
            }
        }
    }
    clearBreakRegList();
#endif
}

void GBAMatrixReset(GBAMatrix_t *matrix) {
    if (matrix == NULL) {
        log("Matrix is NULL");
        return;
    }

    memset(matrix->mappings, 0, sizeof(matrix->mappings));
    matrix->size = 0x1000;

    matrix->paddr = 0;
    matrix->vaddr = 0;
    _remapMatrix(matrix);
    matrix->paddr = 0x200;
    matrix->vaddr = 0x1000;
    _remapMatrix(matrix);
}

void GBAMatrixWrite(GBAMatrix_t *matrix, uint32_t address, uint32_t value)
{
    if (matrix == NULL) {
        log("Matrix is NULL");
        return;
    }

    switch (address) {
    case 0x0:
        matrix->cmd = value;
        switch (value) {
        case 0x01:
        case 0x11:
            _remapMatrix(matrix);
            break;
        default:
            log("Unknown Matrix command: %08X", value);
            break;
        }
        return;
    case 0x4:
        matrix->paddr = value & 0x03FFFFFF;
        return;
    case 0x8:
        matrix->vaddr = value & 0x007FFFFF;
        return;
    case 0xC:
        if (value == 0) {
            log("Rejecting Matrix write for size 0");
            return;
        }
        matrix->size = value << 9;
        return;
    }
    log("Unknown Matrix write: %08X:%04X", address, value);
}

void GBAMatrixWrite16(GBAMatrix_t *matrix, uint32_t address, uint16_t value)
{
    if (matrix == NULL) {
        log("Matrix is NULL");
        return;
    }

    switch (address) {
    case 0x0:
        GBAMatrixWrite(matrix, address, value | (matrix->cmd & 0xFFFF0000));
        break;
    case 0x4:
        GBAMatrixWrite(matrix, address, value | (matrix->paddr & 0xFFFF0000));
        break;
    case 0x8:
        GBAMatrixWrite(matrix, address, value | (matrix->vaddr & 0xFFFF0000));
        break;
    case 0xC:
        GBAMatrixWrite(matrix, address, value | (matrix->size & 0xFFFF0000));
        break;
    }
}

int CPULoadRom(const char* szFile)
{
    romSize = SIZE_ROM * 4;
    if (g_rom != NULL) {
        CPUCleanUp();
    }

    systemSaveUpdateCounter = SYSTEM_SAVE_NOT_UPDATED;

    g_rom = (uint8_t*)malloc(SIZE_ROM * 4);
    if (g_rom == NULL) {
        systemMessage(MSG_OUT_OF_MEMORY, N_("Failed to allocate memory for %s"),
            "ROM");
        return 0;
    }
    g_workRAM = (uint8_t*)calloc(1, SIZE_WRAM);
    if (g_workRAM == NULL) {
        systemMessage(MSG_OUT_OF_MEMORY, N_("Failed to allocate memory for %s"),
            "WRAM");
        return 0;
    }

    uint8_t* whereToLoad = coreOptions.cpuIsMultiBoot ? g_workRAM : g_rom;

#if defined(VBAM_ENABLE_DEBUGGER)
    if (CPUIsELF(szFile)) {
        FILE* f = utilOpenFile(szFile, "rb");
        if (!f) {
            systemMessage(MSG_ERROR_OPENING_IMAGE, N_("Error opening image %s"),
                szFile);
            free(g_rom);
            g_rom = NULL;
            free(g_workRAM);
            g_workRAM = NULL;
            return 0;
        }
        bool res = elfRead(szFile, romSize, f);
        if (!res || romSize == 0) {
            free(g_rom);
            g_rom = NULL;
            free(g_workRAM);
            g_workRAM = NULL;
            elfCleanUp();
            return 0;
        }
    } else
#endif  // defined(VBAM_ENABLE_DEBUGGER)
        if (szFile != NULL) {
        if (!utilLoad(szFile,
                utilIsGBAImage,
                whereToLoad,
                romSize)) {
            free(g_rom);
            g_rom = NULL;
            free(g_workRAM);
            g_workRAM = NULL;
            return 0;
        }
    }

    memset(&GBAMatrix, 0, sizeof(GBAMatrix));
    pristineRomSize = romSize;

    char ident = 0;

    if (romSize > SIZE_ROM) {
        memcpy(&ident, &g_rom[0xAC], 1);

        if (ident == 'M') {
            g_rom2 = (uint8_t*)malloc(SIZE_ROM * 4);
            if (!utilLoad(szFile,
                    utilIsGBAImage,
                    g_rom2,
                    romSize)) {
                free(g_rom2);
                g_rom2 = NULL;
            }

            romSize = 0x01000000;

            log("GBA Matrix detected");
        } else {
            romSize = SIZE_ROM;
        }
    }

    if (g_bios == NULL) {
        g_bios = (uint8_t*)calloc(1, SIZE_BIOS);
        if (g_bios == NULL) {
            systemMessage(MSG_OUT_OF_MEMORY, N_("Failed to allocate memory for %s"),
                "BIOS");
            CPUCleanUp();
            return 0;
        }
    }
    g_internalRAM = (uint8_t*)calloc(1, SIZE_IRAM);
    if (g_internalRAM == NULL) {
        systemMessage(MSG_OUT_OF_MEMORY, N_("Failed to allocate memory for %s"),
            "IRAM");
        CPUCleanUp();
        return 0;
    }
    g_paletteRAM = (uint8_t*)calloc(1, SIZE_PRAM);
    if (g_paletteRAM == NULL) {
        systemMessage(MSG_OUT_OF_MEMORY, N_("Failed to allocate memory for %s"),
            "PRAM");
        CPUCleanUp();
        return 0;
    }
    g_vram = (uint8_t*)calloc(1, SIZE_VRAM);
    if (g_vram == NULL) {
        systemMessage(MSG_OUT_OF_MEMORY, N_("Failed to allocate memory for %s"),
            "VRAM");
        CPUCleanUp();
        return 0;
    }
    g_oam = (uint8_t*)calloc(1, SIZE_OAM);
    if (g_oam == NULL) {
        systemMessage(MSG_OUT_OF_MEMORY, N_("Failed to allocate memory for %s"),
            "OAM");
        CPUCleanUp();
        return 0;
    }

    g_pix = (uint8_t*)calloc(1, 4 * 241 * 162);
    if (g_pix == NULL) {
        systemMessage(MSG_OUT_OF_MEMORY, N_("Failed to allocate memory for %s"),
            "PIX");
        CPUCleanUp();
        return 0;
    }
    g_ioMem = (uint8_t*)calloc(1, SIZE_IOMEM);
    if (g_ioMem == NULL) {
        systemMessage(MSG_OUT_OF_MEMORY, N_("Failed to allocate memory for %s"),
            "IO");
        CPUCleanUp();
        return 0;
    }

    flashInit();
    eepromInit();

    CPUUpdateRenderBuffers(true);

    return romSize;
}

int CPULoadRomData(const char* data, int size)
{
    romSize = SIZE_ROM * 4;
    if (g_rom != NULL) {
        CPUCleanUp();
    }

    systemSaveUpdateCounter = SYSTEM_SAVE_NOT_UPDATED;

    g_rom = (uint8_t*)malloc(SIZE_ROM * 4);
    if (g_rom == NULL) {
        systemMessage(MSG_OUT_OF_MEMORY, N_("Failed to allocate memory for %s"),
            "ROM");
        return 0;
    }
    g_workRAM = (uint8_t*)calloc(1, SIZE_WRAM);
    if (g_workRAM == NULL) {
        systemMessage(MSG_OUT_OF_MEMORY, N_("Failed to allocate memory for %s"),
            "WRAM");
        return 0;
    }

    uint8_t* whereToLoad = coreOptions.cpuIsMultiBoot ? g_workRAM : g_rom;

    romSize = size % 2 == 0 ? size : size + 1;
    memcpy(whereToLoad, data, size);

    memset(&GBAMatrix, 0, sizeof(GBAMatrix));
    pristineRomSize = romSize;

    if (romSize > SIZE_ROM) {
        char ident = 0;
        memcpy(&ident, &g_rom[0xAC], 1);

        if (ident == 'M') {
            g_rom2 = (uint8_t *)malloc(SIZE_ROM * 4);
            if (g_rom2 == NULL) {
                systemMessage(MSG_OUT_OF_MEMORY, N_("Failed to allocate memory for %s"), "ROM2");
                CPUCleanUp();
                return 0;
            }
            memcpy(g_rom2, data, size);
            romSize = 0x01000000;

            log("GBA Matrix detected");
        } else {
            romSize = SIZE_ROM;
        }
    }

    if (g_bios == NULL) {
        g_bios = (uint8_t*)calloc(1, SIZE_BIOS);
        if (g_bios == NULL) {
            systemMessage(MSG_OUT_OF_MEMORY, N_("Failed to allocate memory for %s"),
                "BIOS");
            CPUCleanUp();
            return 0;
        }
    }
    g_internalRAM = (uint8_t*)calloc(1, SIZE_IRAM);
    if (g_internalRAM == NULL) {
        systemMessage(MSG_OUT_OF_MEMORY, N_("Failed to allocate memory for %s"),
            "IRAM");
        CPUCleanUp();
        return 0;
    }
    g_paletteRAM = (uint8_t*)calloc(1, SIZE_PRAM);
    if (g_paletteRAM == NULL) {
        systemMessage(MSG_OUT_OF_MEMORY, N_("Failed to allocate memory for %s"),
            "PRAM");
        CPUCleanUp();
        return 0;
    }
    g_vram = (uint8_t*)calloc(1, SIZE_VRAM);
    if (g_vram == NULL) {
        systemMessage(MSG_OUT_OF_MEMORY, N_("Failed to allocate memory for %s"),
            "VRAM");
        CPUCleanUp();
        return 0;
    }
    g_oam = (uint8_t*)calloc(1, SIZE_OAM);
    if (g_oam == NULL) {
        systemMessage(MSG_OUT_OF_MEMORY, N_("Failed to allocate memory for %s"),
            "OAM");
        CPUCleanUp();
        return 0;
    }

    g_pix = (uint8_t*)calloc(1, 4 * 241 * 162);
    if (g_pix == NULL) {
        systemMessage(MSG_OUT_OF_MEMORY, N_("Failed to allocate memory for %s"),
            "PIX");
        CPUCleanUp();
        return 0;
    }
    g_ioMem = (uint8_t*)calloc(1, SIZE_IOMEM);
    if (g_ioMem == NULL) {
        systemMessage(MSG_OUT_OF_MEMORY, N_("Failed to allocate memory for %s"),
            "IO");
        CPUCleanUp();
        return 0;
    }

    flashInit();
    eepromInit();

    CPUUpdateRenderBuffers(true);

    return romSize;
}

void doMirroring(bool b)
{
    if (static_cast<size_t>(romSize) > k32MiB)
        return;

    int romSizeRounded = romSize;
    romSizeRounded--;
    romSizeRounded |= romSizeRounded >> 1;
    romSizeRounded |= romSizeRounded >> 2;
    romSizeRounded |= romSizeRounded >> 4;
    romSizeRounded |= romSizeRounded >> 8;
    romSizeRounded |= romSizeRounded >> 16;
    romSizeRounded++;
    uint32_t mirroredRomSize = (((romSizeRounded) >> 20) & 0x3F) << 20;
    uint32_t mirroredRomAddress = mirroredRomSize;
    if ((mirroredRomSize <= 0x800000) && (b)) {
        if (mirroredRomSize == 0)
            mirroredRomSize = 0x100000;
        while (mirroredRomAddress < 0x01000000) {
            memcpy((uint16_t*)(g_rom + mirroredRomAddress), (uint16_t*)(g_rom), mirroredRomSize);
            mirroredRomAddress += mirroredRomSize;
        }
    }
}

const char* GetLoadDotCodeFile()
{
    return coreOptions.loadDotCodeFile;
}

const char* GetSaveDotCodeFile()
{
    return coreOptions.saveDotCodeFile;
}

void ResetLoadDotCodeFile()
{
    if (coreOptions.loadDotCodeFile) {
        free((char*)coreOptions.loadDotCodeFile);
    }

    coreOptions.loadDotCodeFile = strdup("");
}

void SetLoadDotCodeFile(const char* szFile)
{
    coreOptions.loadDotCodeFile = strdup(szFile);
}

void ResetSaveDotCodeFile()
{
    if (coreOptions.saveDotCodeFile) {
        free((char*)coreOptions.saveDotCodeFile);
    }

    coreOptions.saveDotCodeFile = strdup("");
}

void SetSaveDotCodeFile(const char* szFile)
{
    coreOptions.saveDotCodeFile = strdup(szFile);
}

void CPUUpdateRender()
{
    switch (DISPCNT & 7) {
    case 0:
        if ((!fxOn && !windowOn && !(coreOptions.layerEnable & 0x8000)) || coreOptions.cpuDisableSfx)
            renderLine = mode0RenderLine;
        else if (fxOn && !windowOn && !(coreOptions.layerEnable & 0x8000))
            renderLine = mode0RenderLineNoWindow;
        else
            renderLine = mode0RenderLineAll;
        break;
    case 1:
        if ((!fxOn && !windowOn && !(coreOptions.layerEnable & 0x8000)) || coreOptions.cpuDisableSfx)
            renderLine = mode1RenderLine;
        else if (fxOn && !windowOn && !(coreOptions.layerEnable & 0x8000))
            renderLine = mode1RenderLineNoWindow;
        else
            renderLine = mode1RenderLineAll;
        break;
    case 2:
        if ((!fxOn && !windowOn && !(coreOptions.layerEnable & 0x8000)) || coreOptions.cpuDisableSfx)
            renderLine = mode2RenderLine;
        else if (fxOn && !windowOn && !(coreOptions.layerEnable & 0x8000))
            renderLine = mode2RenderLineNoWindow;
        else
            renderLine = mode2RenderLineAll;
        break;
    case 3:
        if ((!fxOn && !windowOn && !(coreOptions.layerEnable & 0x8000)) || coreOptions.cpuDisableSfx)
            renderLine = mode3RenderLine;
        else if (fxOn && !windowOn && !(coreOptions.layerEnable & 0x8000))
            renderLine = mode3RenderLineNoWindow;
        else
            renderLine = mode3RenderLineAll;
        break;
    case 4:
        if ((!fxOn && !windowOn && !(coreOptions.layerEnable & 0x8000)) || coreOptions.cpuDisableSfx)
            renderLine = mode4RenderLine;
        else if (fxOn && !windowOn && !(coreOptions.layerEnable & 0x8000))
            renderLine = mode4RenderLineNoWindow;
        else
            renderLine = mode4RenderLineAll;
        break;
    case 5:
        if ((!fxOn && !windowOn && !(coreOptions.layerEnable & 0x8000)) || coreOptions.cpuDisableSfx)
            renderLine = mode5RenderLine;
        else if (fxOn && !windowOn && !(coreOptions.layerEnable & 0x8000))
            renderLine = mode5RenderLineNoWindow;
        else
            renderLine = mode5RenderLineAll;
    default:
        break;
    }
}

void CPUUpdateCPSR()
{
    uint32_t CPSR = reg[16].I & 0x40;
    if (N_FLAG)
        CPSR |= 0x80000000;
    if (Z_FLAG)
        CPSR |= 0x40000000;
    if (C_FLAG)
        CPSR |= 0x20000000;
    if (V_FLAG)
        CPSR |= 0x10000000;
    if (!armState)
        CPSR |= 0x00000020;
    if (!armIrqEnable)
        CPSR |= 0x80;
    CPSR |= (armMode & 0x1F);
    reg[16].I = CPSR;
}

void CPUUpdateFlags(bool breakLoop)
{
    uint32_t CPSR = reg[16].I;

    N_FLAG = (CPSR & 0x80000000) ? true : false;
    Z_FLAG = (CPSR & 0x40000000) ? true : false;
    C_FLAG = (CPSR & 0x20000000) ? true : false;
    V_FLAG = (CPSR & 0x10000000) ? true : false;
    armState = (CPSR & 0x20) ? false : true;
    armIrqEnable = (CPSR & 0x80) ? false : true;
    if (breakLoop) {
        if (armIrqEnable && (IF & IE) && (IME & 1))
            cpuNextEvent = cpuTotalTicks;
    }
}

void CPUUpdateFlags()
{
    CPUUpdateFlags(true);
}

#ifdef WORDS_BIGENDIAN
static void CPUSwap(volatile uint32_t* a, volatile uint32_t* b)
{
    volatile uint32_t c = *b;
    *b = *a;
    *a = c;
}
#else
static void CPUSwap(uint32_t* a, uint32_t* b)
{
    uint32_t c = *b;
    *b = *a;
    *a = c;
}
#endif

void CPUSwitchMode(int mode, bool saveState, bool breakLoop)
{
    //  if(armMode == mode)
    //    return;

    CPUUpdateCPSR();

    switch (armMode) {
    case 0x10:
    case 0x1F:
        reg[R13_USR].I = reg[13].I;
        reg[R14_USR].I = reg[14].I;
        reg[17].I = reg[16].I;
        break;
    case 0x11:
        CPUSwap(&reg[R8_FIQ].I, &reg[8].I);
        CPUSwap(&reg[R9_FIQ].I, &reg[9].I);
        CPUSwap(&reg[R10_FIQ].I, &reg[10].I);
        CPUSwap(&reg[R11_FIQ].I, &reg[11].I);
        CPUSwap(&reg[R12_FIQ].I, &reg[12].I);
        reg[R13_FIQ].I = reg[13].I;
        reg[R14_FIQ].I = reg[14].I;
        reg[SPSR_FIQ].I = reg[17].I;
        break;
    case 0x12:
        reg[R13_IRQ].I = reg[13].I;
        reg[R14_IRQ].I = reg[14].I;
        reg[SPSR_IRQ].I = reg[17].I;
        break;
    case 0x13:
        reg[R13_SVC].I = reg[13].I;
        reg[R14_SVC].I = reg[14].I;
        reg[SPSR_SVC].I = reg[17].I;
        break;
    case 0x17:
        reg[R13_ABT].I = reg[13].I;
        reg[R14_ABT].I = reg[14].I;
        reg[SPSR_ABT].I = reg[17].I;
        break;
    case 0x1b:
        reg[R13_UND].I = reg[13].I;
        reg[R14_UND].I = reg[14].I;
        reg[SPSR_UND].I = reg[17].I;
        break;
    }

    uint32_t CPSR = reg[16].I;
    uint32_t SPSR = reg[17].I;

    switch (mode) {
    case 0x10:
    case 0x1F:
        reg[13].I = reg[R13_USR].I;
        reg[14].I = reg[R14_USR].I;
        reg[16].I = SPSR;
        break;
    case 0x11:
        CPUSwap(&reg[8].I, &reg[R8_FIQ].I);
        CPUSwap(&reg[9].I, &reg[R9_FIQ].I);
        CPUSwap(&reg[10].I, &reg[R10_FIQ].I);
        CPUSwap(&reg[11].I, &reg[R11_FIQ].I);
        CPUSwap(&reg[12].I, &reg[R12_FIQ].I);
        reg[13].I = reg[R13_FIQ].I;
        reg[14].I = reg[R14_FIQ].I;
        reg[16].I = SPSR;
        if (saveState)
            reg[17].I = CPSR;
        else
            reg[17].I = reg[SPSR_FIQ].I;
        break;
    case 0x12:
        reg[13].I = reg[R13_IRQ].I;
        reg[14].I = reg[R14_IRQ].I;
        reg[16].I = SPSR;
        if (saveState)
            reg[17].I = CPSR;
        else
            reg[17].I = reg[SPSR_IRQ].I;
        break;
    case 0x13:
        reg[13].I = reg[R13_SVC].I;
        reg[14].I = reg[R14_SVC].I;
        reg[16].I = SPSR;
        if (saveState)
            reg[17].I = CPSR;
        else
            reg[17].I = reg[SPSR_SVC].I;
        break;
    case 0x17:
        reg[13].I = reg[R13_ABT].I;
        reg[14].I = reg[R14_ABT].I;
        reg[16].I = SPSR;
        if (saveState)
            reg[17].I = CPSR;
        else
            reg[17].I = reg[SPSR_ABT].I;
        break;
    case 0x1b:
        reg[13].I = reg[R13_UND].I;
        reg[14].I = reg[R14_UND].I;
        reg[16].I = SPSR;
        if (saveState)
            reg[17].I = CPSR;
        else
            reg[17].I = reg[SPSR_UND].I;
        break;
    default:
        systemMessage(MSG_UNSUPPORTED_ARM_MODE, N_("Unsupported ARM mode %02x"), mode);
        break;
    }
    armMode = mode;
    CPUUpdateFlags(breakLoop);
    CPUUpdateCPSR();
}

void CPUSwitchMode(int mode, bool saveState)
{
    CPUSwitchMode(mode, saveState, true);
}

void CPUUndefinedException()
{
    uint32_t PC = reg[15].I;
    bool savedArmState = armState;
    CPUSwitchMode(0x1b, true, false);
    reg[14].I = PC - (savedArmState ? 4 : 2);
    reg[15].I = 0x04;
    armState = true;
    armIrqEnable = false;
    armNextPC = 0x04;
    ARM_PREFETCH;
    reg[15].I += 4;
}

void CPUSoftwareInterrupt()
{
    uint32_t PC = reg[15].I;
    bool savedArmState = armState;
    CPUSwitchMode(0x13, true, false);
    reg[14].I = PC - (savedArmState ? 4 : 2);
    reg[15].I = 0x08;
    armState = true;
    armIrqEnable = false;
    armNextPC = 0x08;
    ARM_PREFETCH;
    reg[15].I += 4;
}

void CPUSoftwareInterrupt(int comment)
{
    static bool disableMessage = false;
    if (armState)
        comment >>= 16;
#ifdef VBAM_ENABLE_DEBUGGER
    if (comment == 0xff) {
        dbgOutput(NULL, reg[0].I);
        return;
    }
#endif
#ifdef PROFILING
    if (comment == 0xfe) {
        profStartup(reg[0].I, reg[1].I);
        return;
    }
    if (comment == 0xfd) {
        profControl(reg[0].I);
        return;
    }
    if (comment == 0xfc) {
        profCleanup();
        return;
    }
    if (comment == 0xfb) {
        profCount();
        return;
    }
#endif
    if (comment == 0xfa) {
        agbPrintFlush();
        return;
    }
#ifdef SDL
    if (comment == 0xf9) {
        emulating = 0;
        cpuNextEvent = cpuTotalTicks;
        cpuBreakLoop = true;
        return;
    }
#endif
    if (coreOptions.useBios) {
#ifdef GBA_LOGGING
        if (systemVerbose & VERBOSE_SWI) {
            log("SWI: %08x at %08x (0x%08x,0x%08x,0x%08x,VCOUNT = %2d)\n", comment,
                armState ? armNextPC - 4 : armNextPC - 2,
                reg[0].I,
                reg[1].I,
                reg[2].I,
                VCOUNT);
        }
#endif
        if ((comment & 0xF8) != 0xE0) {
            CPUSoftwareInterrupt();
            return;
        } else {
            if (CheckEReaderRegion())
                BIOS_EReader_ScanCard(comment);
            else
                CPUSoftwareInterrupt();
            return;
        }
    }
    // This would be correct, but it causes problems if uncommented
    //  else {
    //    biosProtected = 0xe3a02004;
    //  }

    switch (comment) {
    case 0x00:
        BIOS_SoftReset();
        ARM_PREFETCH;
        break;
    case 0x01:
        BIOS_RegisterRamReset();
        break;
    case 0x02:
#ifdef GBA_LOGGING
        if (systemVerbose & VERBOSE_SWI) {
            log("Halt: (VCOUNT = %2d)\n",
                VCOUNT);
        }
#endif
        holdState = true;
        holdType = -1;
        cpuNextEvent = cpuTotalTicks;
        break;
    case 0x03:
#ifdef GBA_LOGGING
        if (systemVerbose & VERBOSE_SWI) {
            log("Stop: (VCOUNT = %2d)\n",
                VCOUNT);
        }
#endif
        holdState = true;
        holdType = -1;
        stopState = true;
        cpuNextEvent = cpuTotalTicks;
        break;
    case 0x04:
#ifdef GBA_LOGGING
        if (systemVerbose & VERBOSE_SWI) {
            log("IntrWait: 0x%08x,0x%08x (VCOUNT = %2d)\n",
                reg[0].I,
                reg[1].I,
                VCOUNT);
        }
#endif
        CPUSoftwareInterrupt();
        break;
    case 0x05:
#ifdef GBA_LOGGING
        if (systemVerbose & VERBOSE_SWI) {
            log("VBlankIntrWait: (VCOUNT = %2d)\n",
                VCOUNT);
        }
#endif
        CPUSoftwareInterrupt();
        break;
    case 0x06:
        CPUSoftwareInterrupt();
        break;
    case 0x07:
        CPUSoftwareInterrupt();
        break;
    case 0x08:
        BIOS_Sqrt();
        break;
    case 0x09:
        BIOS_ArcTan();
        break;
    case 0x0A:
        BIOS_ArcTan2();
        break;
    case 0x0B: {
        int len = (reg[2].I & 0x1FFFFF) >> 1;
        if (!(((reg[0].I & 0xe000000) == 0) || ((reg[0].I + len) & 0xe000000) == 0)) {
            if ((reg[2].I >> 24) & 1) {
                if ((reg[2].I >> 26) & 1)
                    SWITicks = (7 + memoryWait32[(reg[1].I >> 24) & 0xF]) * (len >> 1);
                else
                    SWITicks = (8 + memoryWait[(reg[1].I >> 24) & 0xF]) * (len);
            } else {
                if ((reg[2].I >> 26) & 1)
                    SWITicks = (10 + memoryWait32[(reg[0].I >> 24) & 0xF] + memoryWait32[(reg[1].I >> 24) & 0xF]) * (len >> 1);
                else
                    SWITicks = (11 + memoryWait[(reg[0].I >> 24) & 0xF] + memoryWait[(reg[1].I >> 24) & 0xF]) * len;
            }
        }
    }
        BIOS_CpuSet();
        break;
    case 0x0C: {
        int len = (reg[2].I & 0x1FFFFF) >> 5;
        if (!(((reg[0].I & 0xe000000) == 0) || ((reg[0].I + len) & 0xe000000) == 0)) {
            if ((reg[2].I >> 24) & 1)
                SWITicks = (6 + memoryWait32[(reg[1].I >> 24) & 0xF] + 7 * (memoryWaitSeq32[(reg[1].I >> 24) & 0xF] + 1)) * len;
            else
                SWITicks = (9 + memoryWait32[(reg[0].I >> 24) & 0xF] + memoryWait32[(reg[1].I >> 24) & 0xF] + 7 * (memoryWaitSeq32[(reg[0].I >> 24) & 0xF] + memoryWaitSeq32[(reg[1].I >> 24) & 0xF] + 2)) * len;
        }
    }
        BIOS_CpuFastSet();
        break;
    case 0x0D:
        BIOS_GetBiosChecksum();
        break;
    case 0x0E:
        BIOS_BgAffineSet();
        break;
    case 0x0F:
        BIOS_ObjAffineSet();
        break;
    case 0x10: {
        int len = CPUReadHalfWord(reg[2].I);
        if (!(((reg[0].I & 0xe000000) == 0) || ((reg[0].I + len) & 0xe000000) == 0))
            SWITicks = (32 + memoryWait[(reg[0].I >> 24) & 0xF]) * len;
    }
        BIOS_BitUnPack();
        break;
    case 0x11: {
        uint32_t len = CPUReadMemory(reg[0].I) >> 8;
        if (!(((reg[0].I & 0xe000000) == 0) || ((reg[0].I + (len & 0x1fffff)) & 0xe000000) == 0))
            SWITicks = (9 + memoryWait[(reg[1].I >> 24) & 0xF]) * len;
    }
        BIOS_LZ77UnCompWram();
        break;
    case 0x12: {
        uint32_t len = CPUReadMemory(reg[0].I) >> 8;
        if (!(((reg[0].I & 0xe000000) == 0) || ((reg[0].I + (len & 0x1fffff)) & 0xe000000) == 0))
            SWITicks = (19 + memoryWait[(reg[1].I >> 24) & 0xF]) * len;
    }
        BIOS_LZ77UnCompVram();
        break;
    case 0x13: {
        uint32_t len = CPUReadMemory(reg[0].I) >> 8;
        if (!(((reg[0].I & 0xe000000) == 0) || ((reg[0].I + (len & 0x1fffff)) & 0xe000000) == 0))
            SWITicks = (29 + (memoryWait[(reg[0].I >> 24) & 0xF] << 1)) * len;
    }
        BIOS_HuffUnComp();
        break;
    case 0x14: {
        uint32_t len = CPUReadMemory(reg[0].I) >> 8;
        if (!(((reg[0].I & 0xe000000) == 0) || ((reg[0].I + (len & 0x1fffff)) & 0xe000000) == 0))
            SWITicks = (11 + memoryWait[(reg[0].I >> 24) & 0xF] + memoryWait[(reg[1].I >> 24) & 0xF]) * len;
    }
        BIOS_RLUnCompWram();
        break;
    case 0x15: {
        uint32_t len = CPUReadMemory(reg[0].I) >> 9;
        if (!(((reg[0].I & 0xe000000) == 0) || ((reg[0].I + (len & 0x1fffff)) & 0xe000000) == 0))
            SWITicks = (34 + (memoryWait[(reg[0].I >> 24) & 0xF] << 1) + memoryWait[(reg[1].I >> 24) & 0xF]) * len;
    }
        BIOS_RLUnCompVram();
        break;
    case 0x16: {
        uint32_t len = CPUReadMemory(reg[0].I) >> 8;
        if (!(((reg[0].I & 0xe000000) == 0) || ((reg[0].I + (len & 0x1fffff)) & 0xe000000) == 0))
            SWITicks = (13 + memoryWait[(reg[0].I >> 24) & 0xF] + memoryWait[(reg[1].I >> 24) & 0xF]) * len;
    }
        BIOS_Diff8bitUnFilterWram();
        break;
    case 0x17: {
        uint32_t len = CPUReadMemory(reg[0].I) >> 9;
        if (!(((reg[0].I & 0xe000000) == 0) || ((reg[0].I + (len & 0x1fffff)) & 0xe000000) == 0))
            SWITicks = (39 + (memoryWait[(reg[0].I >> 24) & 0xF] << 1) + memoryWait[(reg[1].I >> 24) & 0xF]) * len;
    }
        BIOS_Diff8bitUnFilterVram();
        break;
    case 0x18: {
        uint32_t len = CPUReadMemory(reg[0].I) >> 9;
        if (!(((reg[0].I & 0xe000000) == 0) || ((reg[0].I + (len & 0x1fffff)) & 0xe000000) == 0))
            SWITicks = (13 + memoryWait[(reg[0].I >> 24) & 0xF] + memoryWait[(reg[1].I >> 24) & 0xF]) * len;
    }
        BIOS_Diff16bitUnFilter();
        break;
    case 0x19:
#ifdef GBA_LOGGING
        if (systemVerbose & VERBOSE_SWI) {
            log("SoundBiasSet: 0x%08x (VCOUNT = %2d)\n",
                reg[0].I,
                VCOUNT);
        }
#endif
        if (reg[0].I)
            soundPause();
        else
            soundResume();
        break;
    case 0x1A:
        BIOS_SndDriverInit();
        SWITicks = 252000;
        break;
    case 0x1B:
        BIOS_SndDriverMode();
        SWITicks = 280000;
        break;
    case 0x1C:
        BIOS_SndDriverMain();
        SWITicks = 11050; //avg
        break;
    case 0x1D:
        BIOS_SndDriverVSync();
        SWITicks = 44;
        break;
    case 0x1E:
        BIOS_SndChannelClear();
        break;
    case 0x1F:
        BIOS_MidiKey2Freq();
        break;
    case 0x28:
        BIOS_SndDriverVSyncOff();
        break;
    case 0x29:
        BIOS_SndDriverVSyncOn();
        break;
    case 0xE0:
    case 0xE1:
    case 0xE2:
    case 0xE3:
    case 0xE4:
    case 0xE5:
    case 0xE6:
    case 0xE7:
        if (CheckEReaderRegion())
            BIOS_EReader_ScanCard(comment);
        break;
    case 0x2A:
        BIOS_SndDriverJmpTableCopy();
        // let it go, because we don't really emulate this function
	/* fallthrough */
    default:
#ifdef GBA_LOGGING
        if (systemVerbose & VERBOSE_SWI) {
            log("SWI: %08x at %08x (0x%08x,0x%08x,0x%08x,VCOUNT = %2d)\n", comment,
                armState ? armNextPC - 4 : armNextPC - 2,
                reg[0].I,
                reg[1].I,
                reg[2].I,
                VCOUNT);
        }
#endif

        if (!disableMessage) {
            systemMessage(MSG_UNSUPPORTED_BIOS_FUNCTION,
                N_("Unsupported BIOS function %02x called from %08x. A BIOS file is needed in order to get correct behaviour."),
                comment,
                armMode ? armNextPC - 4 : armNextPC - 2);
            disableMessage = true;
        }
        break;
    }
}

void CPUCompareVCOUNT()
{
    if (VCOUNT == (DISPSTAT >> 8)) {
        DISPSTAT |= 4;
        UPDATE_REG(IO_REG_DISPSTAT, DISPSTAT);

        if (DISPSTAT & 0x20) {
            IF |= 4;
            UPDATE_REG(IO_REG_IF, IF);
        }
    } else {
        DISPSTAT &= 0xFFFB;
        UPDATE_REG(IO_REG_DISPSTAT, DISPSTAT);
    }
    if (layerEnableDelay > 0) {
        layerEnableDelay--;
        if (layerEnableDelay == 1)
            coreOptions.layerEnable = coreOptions.layerSettings & DISPCNT;
    }
}

void doDMA(int ch, uint32_t& s, uint32_t& d, uint32_t si, uint32_t di, uint32_t c, int transfer32, bool isFIFO)
{
    (void)isFIFO;  // Reserved for future use
    int sm = s >> 24;
    int dm = d >> 24;
    int sw = 0;
    int dw = 0;
    int sc = c;

    cpuDmaRunning = true;
    cpuDmaPC = reg[15].I;
    cpuDmaCount = c;
    // This is done to get the correct waitstates.
    if (sm > 15)
        sm = 15;
    if (dm > 15)
        dm = 15;

    //if ((sm>=0x05) && (sm<=0x07) || (dm>=0x05) && (dm <=0x07))
    //    blank = (((DISPSTAT | ((DISPSTAT>>1)&1))==1) ?  true : false);

    if (transfer32) {
        s &= 0xFFFFFFFC;
        if (s < 0x02000000) {
            while (c != 0) {
                bool dstInROM = ((d >> 24) >= REGION_ROM0) && ((d >> 24) < REGION_SRAM);

                uint32_t value = cpuDmaLatchData[ch];
                CPUWriteMemory(d & 0xFFFFFFFC, value);
                if (!isFIFO)
                    d += dstInROM ? 4u : di;
                d &= cpuDmaDstMask[ch];
                c--;
            }
        } else {
            while (c != 0) {
                bool srcInROM = ((s >> 24) >= REGION_ROM0) && ((s >> 24) < REGION_SRAM);
                bool dstInROM = ((d >> 24) >= REGION_ROM0) && ((d >> 24) < REGION_SRAM);

                uint32_t value = CPUReadMemory(s);
                cpuDmaLatchData[ch] = value;
                cpuDmaBusValue = value;
                CPUWriteMemory(d & 0xFFFFFFFC, value);
                if (!isFIFO)
                    d += dstInROM ? 4u : di;
                s += srcInROM ? 4u : si;
                d &= cpuDmaDstMask[ch];
                s &= cpuDmaSrcMask[ch];
                c--;
            }
        }
    } else {
        s &= 0xFFFFFFFE;
        si = (int)si >> 1;
        di = (int)di >> 1;
        if (s < 0x02000000) {
            while (c != 0) {
                bool dstInROM = ((d >> 24) >= REGION_ROM0) && ((d >> 24) < REGION_SRAM);

                uint32_t value = cpuDmaLatchData[ch];
                CPUWriteHalfWord(d & 0xFFFFFFFE, DowncastU16(value));
                if (!isFIFO)
                    d += dstInROM ? 2u : di;
                d &= cpuDmaDstMask[ch];
                c--;
            }
        } else {
            while (c != 0) {
                bool srcInROM = ((s >> 24) >= REGION_ROM0) && ((s >> 24) < REGION_SRAM);
                bool dstInROM = ((d >> 24) >= REGION_ROM0) && ((d >> 24) < REGION_SRAM);

                uint32_t value = CPUReadHalfWord(s);
                cpuDmaLatchData[ch] = value * 0x00010001;
                cpuDmaBusValue = value * 0x00010001;
                CPUWriteHalfWord(d & 0xFFFFFFFE, DowncastU16(value));
                if (!isFIFO)
                    d += dstInROM ? 2u : di;
                s += srcInROM ? 2u : si;
                d &= cpuDmaDstMask[ch];
                s &= cpuDmaSrcMask[ch];
                c--;
            }
        }
    }

    cpuDmaCount = 0;

    int totalTicks = 0;

    if (transfer32) {
        sw = 1 + memoryWaitSeq32[sm & 15];
        dw = 1 + memoryWaitSeq32[dm & 15];
        totalTicks = (sw + dw) * (sc - 1) + 6 + memoryWait32[sm & 15] + memoryWaitSeq32[dm & 15];
    } else {
        sw = 1 + memoryWaitSeq[sm & 15];
        dw = 1 + memoryWaitSeq[dm & 15];
        totalTicks = (sw + dw) * (sc - 1) + 6 + memoryWait[sm & 15] + memoryWaitSeq[dm & 15];
    }

    cpuDmaTicksToUpdate += totalTicks;
    cpuDmaRunning = false;
}


void CPUInit(const char* biosFileName, bool useBiosFile)
{
#ifdef WORDS_BIGENDIAN
    if (!cpuBiosSwapped) {
        for (unsigned int i = 0; i < sizeof(myROM) / 4; i++) {
            WRITE32LE(&myROM[i], myROM[i]);
        }
        cpuBiosSwapped = true;
    }
#endif
    if (g_bios == NULL) {
        g_bios = (uint8_t*)calloc(1, SIZE_BIOS);
        if (g_bios == NULL) {
            systemMessage(MSG_OUT_OF_MEMORY, N_("Failed to allocate memory for %s"),
                "BIOS");
            return;
        }
    }

    eepromInUse = 0;
    coreOptions.useBios = false;

    if (useBiosFile && strlen(biosFileName) > 0) {
        int size = 0x4000;
        if (utilLoad(biosFileName,
                CPUIsGBABios,
                g_bios,
                size)) {
            if (size == 0x4000)
                coreOptions.useBios = true;
            else
                systemMessage(MSG_INVALID_BIOS_FILE_SIZE, N_("Invalid BIOS file size"));
        }
    }

    if (!coreOptions.useBios) {
        memcpy(g_bios, myROM, sizeof(myROM));
    }

    int i = 0;

    biosProtected[0] = 0x00;
    biosProtected[1] = 0xf0;
    biosProtected[2] = 0x29;
    biosProtected[3] = 0xe1;

    for (i = 0; i < 256; i++) {
        int count = 0;
        int j;
        for (j = 0; j < 8; j++)
            if (i & (1 << j))
                count++;
        cpuBitsSet[i] = DowncastU8(count);

        for (j = 0; j < 8; j++)
            if (i & (1 << j))
                break;
        cpuLowestBitSet[i] = DowncastU8(j);
    }

    for (i = 0; i < 0x400; i++)
        ioReadable[i] = true;
    for (i = 0x10; i < 0x48; i++)
        ioReadable[i] = false;
    for (i = 0x4c; i < 0x50; i++)
        ioReadable[i] = false;
    for (i = 0x54; i < 0x60; i++)
        ioReadable[i] = false;
    for (i = 0x8a; i < 0x90; i++)
        ioReadable[i] = false;
    for (i = 0xa0; i < 0xb8; i++)
        ioReadable[i] = false;
    for (i = 0xbc; i < 0xc4; i++)
        ioReadable[i] = false;
    for (i = 0xc8; i < 0xd0; i++)
        ioReadable[i] = false;
    for (i = 0xd4; i < 0xdc; i++)
        ioReadable[i] = false;
    for (i = 0xe0; i < 0x100; i++)
        ioReadable[i] = false;
    for (i = 0x110; i < 0x120; i++)
        ioReadable[i] = false;
    for (i = 0x12c; i < 0x130; i++)
        ioReadable[i] = false;
    for (i = 0x138; i < 0x140; i++)
        ioReadable[i] = false;
    for (i = 0x142; i < 0x150; i++)
        ioReadable[i] = false;
    for (i = 0x15a; i < 0x200; i++)
        ioReadable[i] = false;
    for (i = 0x20a; i < 0x300; i++)
        ioReadable[i] = false;
    for (i = 0x302; i < 0x400; i++)
        ioReadable[i] = false;
    ioReadable[0x0066] = ioReadable[0x0067] = false;
    ioReadable[0x006A] = ioReadable[0x006B] = false;
    ioReadable[0x006E] = ioReadable[0x006F] = false;
    ioReadable[0x0076] = ioReadable[0x0077] = false;
    ioReadable[0x007A] = ioReadable[0x007B] = false;
    ioReadable[0x007E] = ioReadable[0x007F] = false;
    ioReadable[0x0086] = ioReadable[0x0087] = false;
    // Ancient - Infrared Register (Prototypes only)
    ioReadable[0x0136] = ioReadable[0x0137] = false;
    ioReadable[0x0206] = ioReadable[0x0207] = false;

    if (romSize < 0x1fe2000) {
        *((uint16_t*)&g_rom[0x1fe209c]) = 0xdffa; // SWI 0xFA
        *((uint16_t*)&g_rom[0x1fe209e]) = 0x4770; // BX LR
    } else {
        agbPrintEnable(false);
    }
}

void SetSaveType(int st)
{
    switch (st) {
    case GBA_SAVE_AUTO:
        cpuSramEnabled = true;
        cpuFlashEnabled = true;
        cpuEEPROMEnabled = true;
        cpuEEPROMSensorEnabled = false;
        cpuSaveGameFunc = flashSaveDecide;
        break;
    case GBA_SAVE_EEPROM:
        cpuSramEnabled = false;
        cpuFlashEnabled = false;
        cpuEEPROMEnabled = true;
        cpuEEPROMSensorEnabled = false;
        cpuSaveGameFunc = flashSaveDecide; // to insure we're not still in F/SRAM mode when starting the next rom		
        break;
    case GBA_SAVE_SRAM:
        cpuSramEnabled = true;
        cpuFlashEnabled = false;
        cpuEEPROMEnabled = false;
        cpuEEPROMSensorEnabled = false;
        cpuSaveGameFunc = sramDelayedWrite; // to insure we detect the write
        break;
    case GBA_SAVE_FLASH:
        cpuSramEnabled = false;
        cpuFlashEnabled = true;
        cpuEEPROMEnabled = false;
        cpuEEPROMSensorEnabled = false;
        cpuSaveGameFunc = flashDelayedWrite; // to insure we detect the write
        break;
    case GBA_SAVE_EEPROM_SENSOR:
        cpuSramEnabled = false;
        cpuFlashEnabled = false;
        cpuEEPROMEnabled = true;
        cpuEEPROMSensorEnabled = true;
        cpuSaveGameFunc = flashSaveDecide; // to insure we're not still in F/SRAM mode when starting the next rom		
        break;
    case GBA_SAVE_NONE:
        cpuSramEnabled = false;
        cpuFlashEnabled = false;
        cpuEEPROMEnabled = false;
        cpuEEPROMSensorEnabled = false;
        break;
    }
}

void CPUReset()
{
    switch (CheckEReaderRegion()) {
    case 1: //US
        EReaderWriteMemory(0x8009134, 0x46C0DFE0);
        break;
    case 2:
        EReaderWriteMemory(0x8008A8C, 0x46C0DFE0);
        break;
    case 3:
        EReaderWriteMemory(0x80091A8, 0x46C0DFE0);
        break;
    }
    rtcReset();
    // clean registers
    memset(&reg[0], 0, sizeof(reg));
    // clean OAM
    memset(g_oam, 0, SIZE_OAM);
    // clean palette
    memset(g_paletteRAM, 0, SIZE_PRAM);
    // clean picture
    memset(g_pix, 0, SIZE_PIX);
    // clean g_vram
    memset(g_vram, 0, SIZE_VRAM);
    // clean io memory
    memset(g_ioMem, 0, SIZE_IOMEM);

    DISPCNT = 0x0080;
    DISPSTAT = 0x0000;
    VCOUNT = (coreOptions.useBios && !coreOptions.skipBios) ? 0 : 0x007E;
    BG0CNT = 0x0000;
    BG1CNT = 0x0000;
    BG2CNT = 0x0000;
    BG3CNT = 0x0000;
    BG0HOFS = 0x0000;
    BG0VOFS = 0x0000;
    BG1HOFS = 0x0000;
    BG1VOFS = 0x0000;
    BG2HOFS = 0x0000;
    BG2VOFS = 0x0000;
    BG3HOFS = 0x0000;
    BG3VOFS = 0x0000;
    BG2PA = 0x0100;
    BG2PB = 0x0000;
    BG2PC = 0x0000;
    BG2PD = 0x0100;
    BG2X_L = 0x0000;
    BG2X_H = 0x0000;
    BG2Y_L = 0x0000;
    BG2Y_H = 0x0000;
    BG3PA = 0x0100;
    BG3PB = 0x0000;
    BG3PC = 0x0000;
    BG3PD = 0x0100;
    BG3X_L = 0x0000;
    BG3X_H = 0x0000;
    BG3Y_L = 0x0000;
    BG3Y_H = 0x0000;
    WIN0H = 0x0000;
    WIN1H = 0x0000;
    WIN0V = 0x0000;
    WIN1V = 0x0000;
    WININ = 0x0000;
    WINOUT = 0x0000;
    MOSAIC = 0x0000;
    BLDMOD = 0x0000;
    COLEV = 0x0000;
    COLY = 0x0000;
    DM0SAD_L = 0x0000;
    DM0SAD_H = 0x0000;
    DM0DAD_L = 0x0000;
    DM0DAD_H = 0x0000;
    DM0CNT_L = 0x0000;
    DM0CNT_H = 0x0000;
    DM1SAD_L = 0x0000;
    DM1SAD_H = 0x0000;
    DM1DAD_L = 0x0000;
    DM1DAD_H = 0x0000;
    DM1CNT_L = 0x0000;
    DM1CNT_H = 0x0000;
    DM2SAD_L = 0x0000;
    DM2SAD_H = 0x0000;
    DM2DAD_L = 0x0000;
    DM2DAD_H = 0x0000;
    DM2CNT_L = 0x0000;
    DM2CNT_H = 0x0000;
    DM3SAD_L = 0x0000;
    DM3SAD_H = 0x0000;
    DM3DAD_L = 0x0000;
    DM3DAD_H = 0x0000;
    DM3CNT_L = 0x0000;
    DM3CNT_H = 0x0000;
    TM0D = 0x0000;
    TM0CNT = 0x0000;
    TM1D = 0x0000;
    TM1CNT = 0x0000;
    TM2D = 0x0000;
    TM2CNT = 0x0000;
    TM3D = 0x0000;
    TM3CNT = 0x0000;
    P1 = 0x03FF;
    IE = 0x0000;
    IF = 0x0000;
    IME = 0x0000;

    armMode = 0x1F;

    if (coreOptions.cpuIsMultiBoot) {
        reg[13].I = 0x03007F00;
        reg[15].I = 0x02000000;
        reg[16].I = 0x00000000;
        reg[R13_IRQ].I = 0x03007FA0;
        reg[R13_SVC].I = 0x03007FE0;
        armIrqEnable = true;
    } else {
        if (coreOptions.useBios && !coreOptions.skipBios) {
            reg[15].I = 0x00000000;
            armMode = 0x13;
            armIrqEnable = false;
        } else {
            reg[13].I = 0x03007F00;
            reg[15].I = 0x08000000;
            reg[16].I = 0x00000000;
            reg[R13_IRQ].I = 0x03007FA0;
            reg[R13_SVC].I = 0x03007FE0;
            armIrqEnable = true;
        }
    }
    armState = true;
    C_FLAG = V_FLAG = N_FLAG = Z_FLAG = false;
    UPDATE_REG(IO_REG_DISPCNT, DISPCNT);
    UPDATE_REG(IO_REG_VCOUNT, VCOUNT);
    UPDATE_REG(IO_REG_BG2PA, BG2PA);
    UPDATE_REG(IO_REG_BG2PD, BG2PD);
    UPDATE_REG(IO_REG_BG3PA, BG3PA);
    UPDATE_REG(IO_REG_BG3PD, BG3PD);
    UPDATE_REG(IO_REG_KEYINPUT, P1);
    UPDATE_REG(IO_REG_SOUNDBIAS, 0x200);

    // disable FIQ
    reg[16].I |= 0x40;

    CPUUpdateCPSR();

    armNextPC = reg[15].I;
    reg[15].I += 4;

    // reset internal state
    holdState = false;
    holdType = 0;

    biosProtected[0] = 0x00;
    biosProtected[1] = 0xf0;
    biosProtected[2] = 0x29;
    biosProtected[3] = 0xe1;

    lcdTicks = (coreOptions.useBios && !coreOptions.skipBios) ? 1008 : 208;
    timer0On = false;
    timer0Ticks = 0;
    timer0Reload = 0;
    timer0ClockReload = 0;
    timer1On = false;
    timer1Ticks = 0;
    timer1Reload = 0;
    timer1ClockReload = 0;
    timer2On = false;
    timer2Ticks = 0;
    timer2Reload = 0;
    timer2ClockReload = 0;
    timer3On = false;
    timer3Ticks = 0;
    timer3Reload = 0;
    timer3ClockReload = 0;
    dma0Source = 0;
    dma0Dest = 0;
    dma1Source = 0;
    dma1Dest = 0;
    dma2Source = 0;
    dma2Dest = 0;
    dma3Source = 0;
    dma3Dest = 0;
    renderLine = mode0RenderLine;
    fxOn = false;
    windowOn = false;
    frameCount = 0;
    coreOptions.layerEnable = DISPCNT & coreOptions.layerSettings;

    CPUUpdateRenderBuffers(true);

    for (int i = 0; i < 256; i++) {
        map[i].address = (uint8_t*)&dummyAddress;
        map[i].mask = 0;
    }

    map[0].address = g_bios;
    map[2].address = g_workRAM;
    map[3].address = g_internalRAM;
    map[4].address = g_ioMem;
    map[5].address = g_paletteRAM;
    map[6].address = g_vram;
    map[7].address = g_oam;
    map[8].address = g_rom;
    map[9].address = g_rom;
    map[10].address = g_rom;
    map[12].address = g_rom;
    map[14].address = flashSaveMemory;

    SetMapMasks();

    soundReset();

    CPUUpdateWindow0();
    CPUUpdateWindow1();

    // make sure registers are correctly initialized if not using BIOS
    if (!coreOptions.useBios) {
        if (coreOptions.cpuIsMultiBoot)
            BIOS_RegisterRamReset(0xfe);
        else
            BIOS_RegisterRamReset(0xff);
    } else {
        if (coreOptions.cpuIsMultiBoot)
            BIOS_RegisterRamReset(0xfe);
    }

    flashReset();
    eepromReset();
    SetSaveType(coreOptions.saveType);

    ARM_PREFETCH;

    systemSaveUpdateCounter = SYSTEM_SAVE_NOT_UPDATED;

    cpuDmaRunning = false;

    lastTime = systemGetClock();

    SWITicks = 0;

    if (pristineRomSize > SIZE_ROM) {
        char ident = 0;
        memcpy(&ident, &g_rom[0xAC], 1);

        if (ident == 'M') {
            GBAMatrixReset(&GBAMatrix);
        }
    }
}


struct EmulatedSystem GBASystem = {
    // emuMain
    GBAEmulate,
    // emuReset
    CPUReset,
    // emuCleanUp
    CPUCleanUp,
#ifdef __LIBRETRO__
    NULL,           // emuReadBattery
    NULL,           // emuReadState
    CPUReadState,   // emuReadState
    CPUWriteState,  // emuWriteState
    NULL,           // emuReadMemState
    NULL,           // emuWriteMemState
    NULL,           // emuWritePNG
    NULL,           // emuWriteBMP
#else
    // emuReadBattery
    CPUReadBatteryFile,
    // emuWriteBattery
    CPUWriteBatteryFile,
    // emuReadState
    CPUReadState,
    // emuWriteState
    CPUWriteState,
    // emuReadMemState
    CPUReadMemState,
    // emuWriteMemState
    CPUWriteMemState,
    // emuWritePNG
    CPUWritePNGFile,
    // emuWriteBMP
    CPUWriteBMPFile,
#endif
    // emuUpdateCPSR
    CPUUpdateCPSR,
    // emuHasDebugger
    true,
    // emuCount
#ifdef FINAL_VERSION
    300000
#else
    5000
#endif
};
/* END gba.cpp */


#else
/* C translation unit stub: compiled in C++ aggregate mode only. */
#endif
