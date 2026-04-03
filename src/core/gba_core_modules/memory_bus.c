#if defined(__cplusplus)
// Imported from reference implementation: gbaEeprom.cpp
/* BEGIN gbaEeprom.cpp */
#include "../embedded_include/gba/gbaEeprom.h"

#include <cstring>

#include "../embedded_include/base/file_util.h"
#include "../embedded_include/gba/gba.h"
#include "../embedded_include/gba/gbaEeprom.h"

extern int cpuDmaCount;

int eepromMode = EEPROM_IDLE;
int eepromByte = 0;
int eepromBits = 0;
int eepromAddress = 0;

uint8_t eepromData[SIZE_EEPROM_8K];

uint8_t eepromBuffer[16];
bool eepromInUse = false;
int eepromSize = SIZE_EEPROM_512;
uint32_t eepromMask = 0;

variable_desc eepromSaveData[] = {
    { &eepromMode, sizeof(int) },
    { &eepromByte, sizeof(int) },
    { &eepromBits, sizeof(int) },
    { &eepromAddress, sizeof(int) },
    { &eepromInUse, sizeof(bool) },
    { &eepromData[0], SIZE_EEPROM_512 },
    { &eepromBuffer[0], 16 },
    { NULL, 0 }
};

void eepromInit()
{
    eepromInUse = false;
    eepromSize = SIZE_EEPROM_512;
    memset(eepromData, 255, sizeof(eepromData));
}

void eepromReset()
{
    eepromMode = EEPROM_IDLE;
    eepromByte = 0;
    eepromBits = 0;
    eepromAddress = 0;
}

void eepromSetSize(int size) {
    eepromSize = size;
    eepromMask = (gbaGetRomSize() > (16 * 1024 * 1024)) ? 0x01FFFF00 : 0x01000000;
}

#ifdef __LIBRETRO__
void eepromSaveGame(uint8_t*& data)
{
    utilWriteDataMem(data, eepromSaveData);
    utilWriteIntMem(data, eepromSize);
    utilWriteMem(data, eepromData, SIZE_EEPROM_8K);
}

void eepromReadGame(const uint8_t*& data)
{
    utilReadDataMem(data, eepromSaveData);
    eepromSize = utilReadIntMem(data);
    utilReadMem(eepromData, data, SIZE_EEPROM_8K);
}

#else // !__LIBRETRO__

void eepromSaveGame(gzFile gzFile)
{
    utilWriteData(gzFile, eepromSaveData);
    utilWriteInt(gzFile, eepromSize);
    utilGzWrite(gzFile, eepromData, SIZE_EEPROM_8K);
}

void eepromReadGame(gzFile gzFile, int version)
{
    utilReadData(gzFile, eepromSaveData);
    if (version >= SAVE_GAME_VERSION_3) {
        eepromSize = utilReadInt(gzFile);
        utilGzRead(gzFile, eepromData, SIZE_EEPROM_8K);
    } else {
        // prior to 0.7.1, only 4K EEPROM was supported
        eepromSize = SIZE_EEPROM_512;
    }
}

void eepromReadGameSkip(gzFile gzFile, int version)
{
    // skip the eeprom data in a save game
    utilReadDataSkip(gzFile, eepromSaveData);
    if (version >= SAVE_GAME_VERSION_3) {
        utilGzSeek(gzFile, sizeof(int), SEEK_CUR);
        utilGzSeek(gzFile, SIZE_EEPROM_8K, SEEK_CUR);
    }
}
#endif

int eepromRead(uint32_t /* address */)
{
    switch (eepromMode) {
    case EEPROM_IDLE:
    case EEPROM_READADDRESS:
    case EEPROM_WRITEDATA:
        return 1;
    case EEPROM_READDATA: {
        eepromBits++;
        if (eepromBits == 4) {
            eepromMode = EEPROM_READDATA2;
            eepromBits = 0;
            eepromByte = 0;
        }
        return 0;
    }
    case EEPROM_READDATA2: {
        int address = eepromAddress << 3;
        int mask = 1 << (7 - (eepromBits & 7));
        int data = (eepromData[address + eepromByte] & mask) ? 1 : 0;
        eepromBits++;
        if ((eepromBits & 7) == 0)
            eepromByte++;
        if (eepromBits == 0x40)
            eepromMode = EEPROM_IDLE;
        return data;
    }
    default:
        break;
    }
    return 0;
}

void eepromWrite(uint32_t /* address */, uint8_t value)
{
    if (cpuDmaCount == 0)
        return;
    int bit = value & 1;
    switch (eepromMode) {
    case EEPROM_IDLE:
        eepromByte = 0;
        eepromBits = 1;
        eepromBuffer[eepromByte] = (uint8_t)bit;
        eepromMode = EEPROM_READADDRESS;
        break;
    case EEPROM_READADDRESS:
        eepromBuffer[eepromByte] <<= 1;
        eepromBuffer[eepromByte] |= bit;
        eepromBits++;
        if ((eepromBits & 7) == 0) {
            eepromByte++;
        }
        if (cpuDmaCount == 0x11 || cpuDmaCount == 0x51) {
            if (eepromBits == 0x11) {
                eepromSetSize(SIZE_EEPROM_8K);
                eepromInUse = true;
                eepromAddress = ((eepromBuffer[0] & 0x3F) << 8) | ((eepromBuffer[1] & 0xFF));
                if (!(eepromBuffer[0] & 0x40)) {
                    eepromBuffer[0] = (uint8_t)bit;
                    eepromBits = 1;
                    eepromByte = 0;
                    eepromMode = EEPROM_WRITEDATA;
                } else {
                    eepromMode = EEPROM_READDATA;
                    eepromByte = 0;
                    eepromBits = 0;
                }
            }
        } else {
            if (eepromBits == 9) {
                eepromSetSize(SIZE_EEPROM_512);
                eepromInUse = true;
                eepromAddress = (eepromBuffer[0] & 0x3F);
                if (!(eepromBuffer[0] & 0x40)) {
                    eepromBuffer[0] = (uint8_t)bit;
                    eepromBits = 1;
                    eepromByte = 0;
                    eepromMode = EEPROM_WRITEDATA;
                } else {
                    eepromMode = EEPROM_READDATA;
                    eepromByte = 0;
                    eepromBits = 0;
                }
            }
        }
        break;
    case EEPROM_READDATA:
    case EEPROM_READDATA2:
        // should we reset here?
        eepromMode = EEPROM_IDLE;
        break;
    case EEPROM_WRITEDATA:
        eepromBuffer[eepromByte] <<= 1;
        eepromBuffer[eepromByte] |= bit;
        eepromBits++;
        if ((eepromBits & 7) == 0) {
            eepromByte++;
        }
        if (eepromBits == 0x40) {
            eepromInUse = true;
            // write data;
            for (int i = 0; i < 8; i++) {
                eepromData[(eepromAddress << 3) + i] = eepromBuffer[i];
            }
            systemSaveUpdateCounter = SYSTEM_SAVE_UPDATED;
        } else if (eepromBits == 0x41) {
            eepromMode = EEPROM_IDLE;
            eepromByte = 0;
            eepromBits = 0;
        }
        break;
    }
}
/* END gbaEeprom.cpp */

// Imported from reference implementation: gbaFlash.cpp
/* BEGIN gbaFlash.cpp */
#include "../embedded_include/gba/gbaFlash.h"

#include <cstdio>
#include <cstring>

#include "../embedded_include/base/file_util.h"
#include "../embedded_include/base/port.h"
#include "../embedded_include/gba/gba.h"
#include "../embedded_include/gba/gbaGlobals.h"
#include "../embedded_include/gba/gbaRtc.h"
#include "../embedded_include/gba/internal/gbaSram.h"

#define FLASH_READ_ARRAY 0
#define FLASH_CMD_1 1
#define FLASH_CMD_2 2
#define FLASH_AUTOSELECT 3
#define FLASH_CMD_3 4
#define FLASH_CMD_4 5
#define FLASH_CMD_5 6
#define FLASH_ERASE_COMPLETE 7
#define FLASH_PROGRAM 8
#define FLASH_SETBANK 9

uint8_t flashSaveMemory[SIZE_FLASH1M];

int flashState = FLASH_READ_ARRAY;
int flashReadState = FLASH_READ_ARRAY;
int g_flashSize = SIZE_FLASH512;
int flashDeviceID = 0x1b;
int flashManufacturerID = 0x32;
int flashBank = 0;

void flashDetectSaveType(const int size) {
    uint32_t* p = (uint32_t*)&g_rom[0];
    uint32_t* end = (uint32_t*)(&g_rom[0] + size);
    int detectedSaveType = 0;
    int flashSize = 0x10000;
    bool rtcFound = false;

    while (p < end) {
        uint32_t d = READ32LE(p);

        if (d == 0x52504545) {
            if (memcmp(p, "EEPROM_", 7) == 0) {
                if (detectedSaveType == 0 || detectedSaveType == 4)
                    detectedSaveType = 1;
            }
        } else if (d == 0x4D415253) {
            if (memcmp(p, "SRAM_", 5) == 0) {
                if (detectedSaveType == 0 || detectedSaveType == 1 || detectedSaveType == 4)
                    detectedSaveType = 2;
            }
        } else if (d == 0x53414C46) {
            if (memcmp(p, "FLASH1M_", 8) == 0) {
                if (detectedSaveType == 0) {
                    detectedSaveType = 3;
                    flashSize = 0x20000;
                }
            } else if (memcmp(p, "FLASH512_", 9) == 0) {
                if (detectedSaveType == 0) {
                    detectedSaveType = 3;
                    flashSize = 0x10000;
                }
            } else if (memcmp(p, "FLASH", 5) == 0) {
                if (detectedSaveType == 0) {
                    detectedSaveType = 4;
                    flashSize = 0x10000;
                }
            }
        } else if (d == 0x52494953) {
            if (memcmp(p, "SIIRTC_V", 8) == 0)
                rtcFound = true;
        }
        p++;
    }
    // if no matches found, then set it to NONE
    if (detectedSaveType == 0) {
        detectedSaveType = 5;
    }
    if (detectedSaveType == 4) {
        detectedSaveType = 3;
    }
    rtcEnable(rtcFound);
    rtcEnableRumble(!rtcFound);
    coreOptions.saveType = detectedSaveType;
    flashSetSize(flashSize);
}

void flashInit()
{
    memset(flashSaveMemory, 0xff, sizeof(flashSaveMemory));
}

void flashReset()
{
    flashState = FLASH_READ_ARRAY;
    flashReadState = FLASH_READ_ARRAY;
    flashBank = 0;
}

void flashSetSize(int size)
{
    //  log("Setting flash size to %d\n", size);
    if (size == SIZE_FLASH512) {
        flashDeviceID = 0x1b;
        flashManufacturerID = 0x32;
    } else {
        flashDeviceID = 0x13; //0x09;
        flashManufacturerID = 0x62; //0xc2;
    }
    // Added to make 64k saves compatible with 128k ones
    // (allow wrongfuly set 64k saves to work for Pokemon games)
    if ((size == SIZE_FLASH1M) && (g_flashSize == SIZE_FLASH512))
        memcpy((uint8_t*)(flashSaveMemory + SIZE_FLASH512), (uint8_t*)(flashSaveMemory), SIZE_FLASH512);
    g_flashSize = size;
}

uint8_t flashRead(uint32_t address)
{
    //  log("Reading %08x from %08x\n", address, reg[15].I);
    //  log("Current read state is %d\n", flashReadState);
    address &= 0xFFFF;

    switch (flashReadState) {
    case FLASH_READ_ARRAY:
        return flashSaveMemory[(flashBank << 16) + address];
    case FLASH_AUTOSELECT:
        switch (address & 0xFF) {
        case 0:
            // manufacturer ID
            return (uint8_t)flashManufacturerID;
        case 1:
            // device ID
            return (uint8_t)flashDeviceID;
        }
        break;
    case FLASH_ERASE_COMPLETE:
        flashState = FLASH_READ_ARRAY;
        flashReadState = FLASH_READ_ARRAY;
        return 0xFF;
    };
    return 0;
}

void flashSaveDecide(uint32_t address, uint8_t byte)
{
    if (coreOptions.saveType == GBA_SAVE_EEPROM)
        return;

    if (cpuSramEnabled && cpuFlashEnabled) {
        if (address == 0x0e005555) {
            coreOptions.saveType = GBA_SAVE_FLASH;
            cpuSramEnabled = false;
            cpuSaveGameFunc = flashWrite;
        } else {
            coreOptions.saveType = GBA_SAVE_SRAM;
            cpuFlashEnabled = false;
            cpuSaveGameFunc = sramWrite;
        }

        log("%s emulation is enabled by writing to:  $%08x : %02x\n",
            cpuSramEnabled ? "SRAM" : "FLASH", address, byte);
    }

    if (coreOptions.saveType == GBA_SAVE_NONE)
        return;

    (*cpuSaveGameFunc)(address, byte);
}

void flashDelayedWrite(uint32_t address, uint8_t byte)
{
    coreOptions.saveType = GBA_SAVE_FLASH;
    cpuSaveGameFunc = flashWrite;
    flashWrite(address, byte);
}

void flashWrite(uint32_t address, uint8_t byte)
{
    //  log("Writing %02x at %08x\n", byte, address);
    //  log("Current state is %d\n", flashState);
    address &= 0xFFFF;
    switch (flashState) {
    case FLASH_READ_ARRAY:
        if (address == 0x5555 && byte == 0xAA)
            flashState = FLASH_CMD_1;
        break;
    case FLASH_CMD_1:
        if (address == 0x2AAA && byte == 0x55)
            flashState = FLASH_CMD_2;
        else
            flashState = FLASH_READ_ARRAY;
        break;
    case FLASH_CMD_2:
        if (address == 0x5555) {
            if (byte == 0x90) {
                flashState = FLASH_AUTOSELECT;
                flashReadState = FLASH_AUTOSELECT;
            } else if (byte == 0x80) {
                flashState = FLASH_CMD_3;
            } else if (byte == 0xF0) {
                flashState = FLASH_READ_ARRAY;
                flashReadState = FLASH_READ_ARRAY;
            } else if (byte == 0xA0) {
                flashState = FLASH_PROGRAM;
            } else if (byte == 0xB0 && g_flashSize == SIZE_FLASH1M) {
                flashState = FLASH_SETBANK;
            } else {
                flashState = FLASH_READ_ARRAY;
                flashReadState = FLASH_READ_ARRAY;
            }
        } else {
            flashState = FLASH_READ_ARRAY;
            flashReadState = FLASH_READ_ARRAY;
        }
        break;
    case FLASH_CMD_3:
        if (address == 0x5555 && byte == 0xAA) {
            flashState = FLASH_CMD_4;
        } else {
            flashState = FLASH_READ_ARRAY;
            flashReadState = FLASH_READ_ARRAY;
        }
        break;
    case FLASH_CMD_4:
        if (address == 0x2AAA && byte == 0x55) {
            flashState = FLASH_CMD_5;
        } else {
            flashState = FLASH_READ_ARRAY;
            flashReadState = FLASH_READ_ARRAY;
        }
        break;
    case FLASH_CMD_5:
        if (byte == 0x30) {
            // SECTOR ERASE
            memset(&flashSaveMemory[(flashBank << 16) + (address & 0xF000)],
                0xff,
                0x1000);
            systemSaveUpdateCounter = SYSTEM_SAVE_UPDATED;
            flashReadState = FLASH_ERASE_COMPLETE;
        } else if (byte == 0x10) {
            // CHIP ERASE
            memset(flashSaveMemory, 0xff, g_flashSize);
            systemSaveUpdateCounter = SYSTEM_SAVE_UPDATED;
            flashReadState = FLASH_ERASE_COMPLETE;
        } else {
            flashState = FLASH_READ_ARRAY;
            flashReadState = FLASH_READ_ARRAY;
        }
        break;
    case FLASH_AUTOSELECT:
        if (byte == 0xF0) {
            flashState = FLASH_READ_ARRAY;
            flashReadState = FLASH_READ_ARRAY;
        } else if (address == 0x5555 && byte == 0xAA)
            flashState = FLASH_CMD_1;
        else {
            flashState = FLASH_READ_ARRAY;
            flashReadState = FLASH_READ_ARRAY;
        }
        break;
    case FLASH_PROGRAM:
        flashSaveMemory[(flashBank << 16) + address] = byte;
        systemSaveUpdateCounter = SYSTEM_SAVE_UPDATED;
        flashState = FLASH_READ_ARRAY;
        flashReadState = FLASH_READ_ARRAY;
        break;
    case FLASH_SETBANK:
        if (address == 0) {
            flashBank = (byte & 1);
        }
        flashState = FLASH_READ_ARRAY;
        flashReadState = FLASH_READ_ARRAY;
        break;
    }
}

static variable_desc flashSaveData3[] = {
    { &flashState, sizeof(int) },
    { &flashReadState, sizeof(int) },
    { &g_flashSize, sizeof(int) },
    { &flashBank, sizeof(int) },
    { &flashSaveMemory[0], SIZE_FLASH1M },
    { NULL, 0 }
};

#ifdef __LIBRETRO__
void flashSaveGame(uint8_t*& data)
{
    utilWriteDataMem(data, flashSaveData3);
}

void flashReadGame(const uint8_t*& data)
{
    utilReadDataMem(data, flashSaveData3);
}

#else // !__LIBRETRO__
static variable_desc flashSaveData[] = {
    { &flashState, sizeof(int) },
    { &flashReadState, sizeof(int) },
    { &flashSaveMemory[0], SIZE_FLASH512 },
    { NULL, 0 }
};

static variable_desc flashSaveData2[] = {
    { &flashState, sizeof(int) },
    { &flashReadState, sizeof(int) },
    { &g_flashSize, sizeof(int) },
    { &flashSaveMemory[0], SIZE_FLASH1M },
    { NULL, 0 }
};

void flashSaveGame(gzFile gzFile)
{
    utilWriteData(gzFile, flashSaveData3);
}

void flashReadGame(gzFile gzFile, int version)
{
    if (version < SAVE_GAME_VERSION_5)
        utilReadData(gzFile, flashSaveData);
    else if (version < SAVE_GAME_VERSION_7) {
        utilReadData(gzFile, flashSaveData2);
        flashBank = 0;
        flashSetSize(g_flashSize);
    } else {
        utilReadData(gzFile, flashSaveData3);
    }
}

void flashReadGameSkip(gzFile gzFile, int version)
{
    // skip the flash data in a save game
    if (version < SAVE_GAME_VERSION_5)
        utilReadDataSkip(gzFile, flashSaveData);
    else if (version < SAVE_GAME_VERSION_7) {
        utilReadDataSkip(gzFile, flashSaveData2);
    } else {
        utilReadDataSkip(gzFile, flashSaveData3);
    }
}
#endif
/* END gbaFlash.cpp */

// Imported from reference implementation: gbaRtc.cpp
/* BEGIN gbaRtc.cpp */

enum RTCSTATE {
    IDLE = 0,
    COMMAND,
    DATA,
    READDATA
};

typedef struct
{
    uint8_t byte0;
    uint8_t select;
    uint8_t enable;
    uint8_t command;
    int dataLen;
    int bits;
    RTCSTATE state;
    uint8_t data[12];
    // reserved variables for future
    uint8_t reserved[12];
    bool reserved2;
    uint32_t reserved3;
} RTCCLOCKDATA;

struct tm gba_time;
static RTCCLOCKDATA rtcClockData;
static bool rtcClockEnabled = true;
static bool rtcRumbleEnabled = false;

uint32_t countTicks = 0;

void rtcEnable(bool e)
{
    rtcClockEnabled = e;
}

bool rtcIsEnabled()
{
    return rtcClockEnabled;
}

void rtcEnableRumble(bool e)
{
    rtcRumbleEnabled = e;
}

uint16_t rtcRead(uint32_t address)
{
    uint16_t res = 0;

    switch (address) {
    case 0x80000c8:
        return rtcClockData.enable;
        break;

    case 0x80000c6:
        return rtcClockData.select;
        break;

    case 0x80000c4:
        if (!(rtcClockData.enable & 1)) {
            return 0;
        }

        // Boktai Solar Sensor
        if (rtcClockData.select == 0x07) {
            if (rtcClockData.reserved[11] >= systemGetSensorDarkness()) {
                res |= 8;
            }
        }

        // WarioWare Twisted Tilt Sensor
        if (rtcClockData.select == 0x0b) {
            uint16_t v = DowncastU16(systemGetSensorZ());
            v = 0x6C0 + v;
            res |= ((v >> rtcClockData.reserved[11]) & 1) << 2;
        }

        // Real Time Clock
        if (rtcClockEnabled && (rtcClockData.select & 0x04)) {
            res |= rtcClockData.byte0;
        }

        return res;
        break;
    }

    return READ16LE((&g_rom[address & 0x1FFFFFE]));
}

static uint8_t toBCD(uint8_t value)
{
    value = value % 100;
    uint8_t l = value % 10;
    uint8_t h = value / 10;
    return h * 16 + l;
}

void SetGBATime()
{
    time_t long_time;
    time(&long_time); /* Get time as long integer. */
#if __STDC_WANT_SECURE_LIB__
    localtime_s(&gba_time, &long_time); /* Convert to local time. */
#else
    gba_time = *localtime(&long_time); /* Convert to local time. */
#endif
}

void rtcUpdateTime(int ticks)
{
    countTicks += ticks;

    if (countTicks > TICKS_PER_SECOND) {
        countTicks -= TICKS_PER_SECOND;
        gba_time.tm_sec++;
        mktime(&gba_time);
    }
}

bool rtcWrite(uint32_t address, uint16_t value)
{
    if (address == 0x80000c8) {
        rtcClockData.enable = (uint8_t)value; // bit 0 = enable reading from 0x80000c4 c6 and c8
    } else if (address == 0x80000c6) {
        rtcClockData.select = (uint8_t)value; // 0=read/1=write (for each of 4 low bits)

        // rumble is off when not writing to that pin
        if (rtcRumbleEnabled && !(value & 8))
            systemCartridgeRumble(false);
    } else if (address == 0x80000c4) // 4 bits of I/O Port Data (upper bits not used)
    {
        // WarioWare Twisted rumble
        if (rtcRumbleEnabled && (rtcClockData.select & 0x08)) {
            systemCartridgeRumble(value & 8);
        }

        // Boktai solar sensor
        if (rtcClockData.select == 0x07) {
            if (value & 2) {
                // reset counter to 0
                rtcClockData.reserved[11] = 0;
            }

            if ((value & 1) && !(rtcClockData.reserved[10] & 1)) {
                // increase counter, ready to do another read
                if (rtcClockData.reserved[11] < 255) {
                    rtcClockData.reserved[11]++;
                } else {
                    rtcClockData.reserved[11] = 0;
                }
            }

            rtcClockData.reserved[10] = value & rtcClockData.select;
        }

        // WarioWare Twisted rotation sensor
        if (rtcClockData.select == 0x0b) {
            if (value & 2) {
                // clock goes high in preperation for reading a bit
                rtcClockData.reserved[11]--;
            }

            if (value & 1) {
                // start ADC conversion
                rtcClockData.reserved[11] = 15;
            }

            rtcClockData.byte0 = value & rtcClockData.select;
        }

        // Real Time Clock
        if (rtcClockData.select & 4) {
            if (rtcClockData.state == IDLE && rtcClockData.byte0 == 1 && value == 5) {
                rtcClockData.state = COMMAND;
                rtcClockData.bits = 0;
                rtcClockData.command = 0;
            } else if (!(rtcClockData.byte0 & 1) && (value & 1)) // bit transfer
            {
                rtcClockData.byte0 = (uint8_t)value;

                switch (rtcClockData.state) {
                case COMMAND:
                    rtcClockData.command |= ((value & 2) >> 1) << (7 - rtcClockData.bits);
                    rtcClockData.bits++;

                    if (rtcClockData.bits == 8) {
                        rtcClockData.bits = 0;

                        switch (rtcClockData.command) {
                        case 0x60:
                            // not sure what this command does but it doesn't take parameters
                            // maybe it is a reset or stop
                            rtcClockData.state = IDLE;
                            rtcClockData.bits = 0;
                            break;

                        case 0x62:
                            // this sets the control state but not sure what those values are
                            rtcClockData.state = READDATA;
                            rtcClockData.dataLen = 1;
                            break;

                        case 0x63:
                            rtcClockData.dataLen = 1;
                            rtcClockData.data[0] = 0x40;
                            rtcClockData.state = DATA;
                            break;

                        case 0x64:
                            break;

                        case 0x65: {
                            if (coreOptions.rtcEnabled)
                                SetGBATime();

                            rtcClockData.dataLen = 7;
                            rtcClockData.data[0] = toBCD(DowncastU8(gba_time.tm_year));
                            rtcClockData.data[1] = toBCD(DowncastU8(gba_time.tm_mon + 1));
                            rtcClockData.data[2] = toBCD(DowncastU8(gba_time.tm_mday));
                            rtcClockData.data[3] = toBCD(DowncastU8(gba_time.tm_wday));
                            rtcClockData.data[4] = toBCD(DowncastU8(gba_time.tm_hour));
                            rtcClockData.data[5] = toBCD(DowncastU8(gba_time.tm_min));
                            rtcClockData.data[6] = toBCD(DowncastU8(gba_time.tm_sec));
                            rtcClockData.state = DATA;
                        } break;

                        case 0x67: {
                            if (coreOptions.rtcEnabled)
                                SetGBATime();

                            rtcClockData.dataLen = 3;
                            rtcClockData.data[0] = toBCD(DowncastU8(gba_time.tm_hour));
                            rtcClockData.data[1] = toBCD(DowncastU8(gba_time.tm_min));
                            rtcClockData.data[2] = toBCD(DowncastU8(gba_time.tm_sec));
                            rtcClockData.state = DATA;
                        } break;

                        default:
#ifdef GBA_LOGGING
                            log(N_("Unknown RTC command %02x"), rtcClockData.command);
#endif
                            rtcClockData.state = IDLE;
                            break;
                        }
                    }

                    break;

                case DATA:
                    if (rtcClockData.select & 2) {
                    } else if (rtcClockData.select & 4) {
                        rtcClockData.byte0 = (rtcClockData.byte0 & ~2) | ((rtcClockData.data[rtcClockData.bits >> 3] >> (rtcClockData.bits & 7)) & 1) * 2;
                        rtcClockData.bits++;

                        if (rtcClockData.bits == 8 * rtcClockData.dataLen) {
                            rtcClockData.bits = 0;
                            rtcClockData.state = IDLE;
                        }
                    }

                    break;

                case READDATA:
                    if (!(rtcClockData.select & 2)) {
                    } else {
                        rtcClockData.data[rtcClockData.bits >> 3] = (rtcClockData.data[rtcClockData.bits >> 3] >> 1) | ((value << 6) & 128);
                        rtcClockData.bits++;

                        if (rtcClockData.bits == 8 * rtcClockData.dataLen) {
                            rtcClockData.bits = 0;
                            rtcClockData.state = IDLE;
                        }
                    }

                    break;

                default:
                    break;
                }
            } else
                rtcClockData.byte0 = (uint8_t)value;
        }
    }

    return true;
}

void rtcReset()
{
    memset(&rtcClockData, 0, sizeof(rtcClockData));
    rtcClockData.byte0 = 0;
    rtcClockData.select = 0;
    rtcClockData.enable = 0;
    rtcClockData.command = 0;
    rtcClockData.dataLen = 0;
    rtcClockData.bits = 0;
    rtcClockData.state = IDLE;
    rtcClockData.reserved[11] = 0;
    SetGBATime();
}

#ifdef __LIBRETRO__
void rtcSaveGame(uint8_t*& data)
{
    utilWriteMem(data, &rtcClockData, sizeof(rtcClockData));
}

void rtcReadGame(const uint8_t*& data)
{
    utilReadMem(&rtcClockData, data, sizeof(rtcClockData));
}
#else
void rtcSaveGame(gzFile gzFile)
{
    utilGzWrite(gzFile, &rtcClockData, sizeof(rtcClockData));
}

void rtcReadGame(gzFile gzFile)
{
    utilGzRead(gzFile, &rtcClockData, sizeof(rtcClockData));
}
#endif
/* END gbaRtc.cpp */

// Imported from reference implementation: internal/gbaSram.cpp
/* BEGIN internal/gbaSram.cpp */

uint8_t sramRead(uint32_t address)
{
    return flashSaveMemory[address & 0xFFFF];
}
void sramDelayedWrite(uint32_t address, uint8_t byte)
{
    coreOptions.saveType = GBA_SAVE_SRAM;
    cpuSaveGameFunc = sramWrite;
    sramWrite(address, byte);
}

void sramWrite(uint32_t address, uint8_t byte)
{
    flashSaveMemory[address & 0xFFFF] = byte;
    systemSaveUpdateCounter = SYSTEM_SAVE_UPDATED;
}
/* END internal/gbaSram.cpp */

#else
/* C translation unit stub: compiled in C++ aggregate mode only. */
#endif
