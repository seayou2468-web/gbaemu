#if defined(__cplusplus)
#include "../../../reference implementation/gba/gba.h"

#ifdef __LIBRETRO__
#include <stddef.h>

unsigned int CPUWriteState(uint8_t* data)
{
    const uint8_t* orig = data;

    utilWriteIntMem(data, SAVE_GAME_VERSION);
    utilWriteMem(data, &g_rom[0xa0], 16);
    utilWriteIntMem(data, coreOptions.useBios);
    utilWriteMem(data, &reg[0], sizeof(reg));

    utilWriteDataMem(data, saveGameStruct);

    utilWriteIntMem(data, stopState);
    utilWriteIntMem(data, IRQTicks);

    // new DMA variables
    utilWriteIntMem(data, cpuDmaRunning);
    utilWriteIntMem(data, cpuDmaPC);
    utilWriteIntMem(data, cpuDmaCount);
    utilWriteIntMem(data, cpuDmaBusValue);
    utilWriteMem(data, cpuDmaLatchData, sizeof(uint32_t) * 4);

    utilWriteMem(data, g_internalRAM, SIZE_IRAM);
    utilWriteMem(data, g_paletteRAM, SIZE_PRAM);
    utilWriteMem(data, g_workRAM, SIZE_WRAM);
    utilWriteMem(data, g_vram, SIZE_VRAM);
    utilWriteMem(data, g_oam, SIZE_OAM);
    utilWriteMem(data, g_pix, SIZE_PIX);
    utilWriteMem(data, g_ioMem, SIZE_IOMEM);

    eepromSaveGame(data);
    flashSaveGame(data);
    soundSaveGame(data);
    rtcSaveGame(data);

    if (pristineRomSize > SIZE_ROM) {
        uint8_t ident = 0;
        memcpy(&ident, &g_rom[0xAC], 1);

        if (ident == 'M') {
            utilWriteMem(data, &GBAMatrix, sizeof(GBAMatrix));
        }
    }

    return static_cast<unsigned int>(data - orig);
}

bool CPUReadState(const uint8_t* data)
{
    // Don't really care about version.
    int version = utilReadIntMem(data);
    if (version > SAVE_GAME_VERSION || version < SAVE_GAME_VERSION_1)
        return false;

    char romname[16];
    utilReadMem(romname, data, 16);
    if (memcmp(&g_rom[0xa0], romname, 16) != 0)
        return false;

    // Don't care about use bios ...
    utilReadIntMem(data);

    utilReadMem(&reg[0], data, sizeof(reg));

    utilReadDataMem(data, saveGameStruct);

    stopState = utilReadIntMem(data) ? true : false;

    IRQTicks = utilReadIntMem(data);
    if (IRQTicks > 0)
        intState = true;
    else {
        intState = false;
        IRQTicks = 0;
    }

    if (version >= SAVE_GAME_VERSION_11) {
        cpuDmaRunning = utilReadIntMem(data) ? true : false;
        cpuDmaPC = utilReadIntMem(data);
        cpuDmaCount = utilReadIntMem(data);
        cpuDmaBusValue = utilReadIntMem(data);
        utilReadMem(cpuDmaLatchData, data, sizeof(uint32_t) * 4);
    }

    utilReadMem(g_internalRAM, data, SIZE_IRAM);
    utilReadMem(g_paletteRAM, data, SIZE_PRAM);
    utilReadMem(g_workRAM, data, SIZE_WRAM);
    utilReadMem(g_vram, data, SIZE_VRAM);
    utilReadMem(g_oam, data, SIZE_OAM);
    utilReadMem(g_pix, data, SIZE_PIX);
    utilReadMem(g_ioMem, data, SIZE_IOMEM);

    eepromReadGame(data);
    flashReadGame(data);
    soundReadGame(data);
    rtcReadGame(data);

    if (pristineRomSize > SIZE_ROM) {
        uint8_t ident = 0;
        memcpy(&ident, &g_rom[0xAC], 1);

        if (ident == 'M') {
            utilReadMem(&stateMatrix, data, sizeof(stateMatrix));
        }
    }

    //// Copypasta stuff ...
    // set pointers!
    coreOptions.layerEnable = coreOptions.layerSettings & DISPCNT;

    CPUUpdateRender();

    // CPU Update Render Buffers set to true
    CLEAR_ARRAY(g_line0);
    CLEAR_ARRAY(g_line1);
    CLEAR_ARRAY(g_line2);
    CLEAR_ARRAY(g_line3);
    // End of CPU Update Render Buffers set to true

    CPUUpdateWindow0();
    CPUUpdateWindow1();

    SetSaveType(coreOptions.saveType);

    systemSaveUpdateCounter = SYSTEM_SAVE_NOT_UPDATED;
    if (armState) {
        ARM_PREFETCH;
    } else {
        THUMB_PREFETCH;
    }

    CPUUpdateRegister(0x204, CPUReadHalfWordQuick(0x4000204));

    if (pristineRomSize > SIZE_ROM) {
        uint8_t ident = 0;
        memcpy(&ident, &g_rom[0xAC], 1);

        if (ident == 'M') {
            GBAMatrix.size = 0x200;

            for (int i = 0; i < 16; ++i) {
                GBAMatrix.mappings[i] = stateMatrix.mappings[i];
                GBAMatrix.paddr = GBAMatrix.mappings[i];
                GBAMatrix.vaddr = i << 9;
                _remapMatrix(&GBAMatrix);
            }

            GBAMatrix.cmd = stateMatrix.cmd;
            GBAMatrix.paddr = stateMatrix.paddr;
            GBAMatrix.vaddr = stateMatrix.vaddr;
            GBAMatrix.size = stateMatrix.size;
        }
    }

    return true;
}

#else // !__LIBRETRO__

static bool CPUWriteState(gzFile gzFile)
{
    utilWriteInt(gzFile, SAVE_GAME_VERSION);

    utilGzWrite(gzFile, &g_rom[0xa0], 16);

    utilWriteInt(gzFile, coreOptions.useBios);

    utilGzWrite(gzFile, &reg[0], sizeof(reg));

    utilWriteData(gzFile, saveGameStruct);

    // new to version 0.7.1
    utilWriteInt(gzFile, stopState);
    // new to version 0.8
    utilWriteInt(gzFile, IRQTicks);

    // new DMA variables
    utilWriteInt(gzFile, cpuDmaRunning);
    utilWriteInt(gzFile, cpuDmaPC);
    utilWriteInt(gzFile, cpuDmaCount);
    utilWriteInt(gzFile, cpuDmaBusValue);
    utilGzWrite(gzFile, cpuDmaLatchData, sizeof(uint32_t) * 4);

    utilGzWrite(gzFile, g_internalRAM, SIZE_IRAM);
    utilGzWrite(gzFile, g_paletteRAM, SIZE_PRAM);
    utilGzWrite(gzFile, g_workRAM, SIZE_WRAM);
    utilGzWrite(gzFile, g_vram, SIZE_VRAM);
    utilGzWrite(gzFile, g_oam, SIZE_OAM);
    utilGzWrite(gzFile, g_pix, SIZE_PIX);
    utilGzWrite(gzFile, g_ioMem, SIZE_IOMEM);

    eepromSaveGame(gzFile);
    flashSaveGame(gzFile);
    soundSaveGame(gzFile);

    cheatsSaveGame(gzFile);

    // version 1.5
    rtcSaveGame(gzFile);

    if (pristineRomSize > SIZE_ROM) {
        uint8_t ident = 0;
        memcpy(&ident, &g_rom[0xAC], 1);

        if (ident == 'M') {
            utilGzWrite(gzFile, &GBAMatrix, sizeof(GBAMatrix));
        }
    }

    return true;
}

bool CPUWriteState(const char* file)
{
    gzFile gzFile = utilGzOpen(file, "wb");

    if (gzFile == NULL) {
        systemMessage(MSG_ERROR_CREATING_FILE, N_("Error creating file %s"), file);
        return false;
    }

    bool res = CPUWriteState(gzFile);

    utilGzClose(gzFile);

    return res;
}

bool CPUWriteMemState(char* memory, int available, long& reserved)
{
    gzFile gzFile = utilMemGzOpen(memory, available, "w");

    if (gzFile == NULL) {
        return false;
    }

    bool res = CPUWriteState(gzFile);

    reserved = utilGzMemTell(gzFile) + 8;

    if (reserved >= (available))
        res = false;

    utilGzClose(gzFile);

    return res;
}

static bool CPUReadState(gzFile gzFile)
{
    int version = utilReadInt(gzFile);

    if (version > SAVE_GAME_VERSION || version < SAVE_GAME_VERSION_1) {
        systemMessage(MSG_UNSUPPORTED_VBA_SGM,
            N_("Unsupported VisualBoyAdvance save game version %d"),
            version);
        return false;
    }

    uint8_t romname[17];

    utilGzRead(gzFile, romname, 16);

    if (memcmp(&g_rom[0xa0], romname, 16) != 0) {
        romname[16] = 0;
        for (int i = 0; i < 16; i++)
            if (romname[i] < 32)
                romname[i] = 32;
        systemMessage(MSG_CANNOT_LOAD_SGM, N_("Cannot load save game for %s"), romname);
        return false;
    }

    bool ub = utilReadInt(gzFile) ? true : false;

    if (ub != (bool)(coreOptions.useBios)) {
        if (coreOptions.useBios)
            systemMessage(MSG_SAVE_GAME_NOT_USING_BIOS,
                N_("Save game is not using the BIOS files"));
        else
            systemMessage(MSG_SAVE_GAME_USING_BIOS,
                N_("Save game is using the BIOS file"));
        return false;
    }

    utilGzRead(gzFile, &reg[0], sizeof(reg));

    utilReadData(gzFile, saveGameStruct);

    if (version < SAVE_GAME_VERSION_3)
        stopState = false;
    else
        stopState = utilReadInt(gzFile) ? true : false;

    if (version < SAVE_GAME_VERSION_4) {
        IRQTicks = 0;
        intState = false;
    } else {
        IRQTicks = utilReadInt(gzFile);
        if (IRQTicks > 0)
            intState = true;
        else {
            intState = false;
            IRQTicks = 0;
        }
    }

    // new DMA variables
    if (version >= SAVE_GAME_VERSION_11) {
        cpuDmaRunning = utilReadInt(gzFile) ? true : false;
        cpuDmaPC = utilReadInt(gzFile);
        cpuDmaCount = utilReadInt(gzFile);
        cpuDmaBusValue = utilReadInt(gzFile);
        utilGzRead(gzFile, cpuDmaLatchData, sizeof(uint32_t) * 4);
    }

    utilGzRead(gzFile, g_internalRAM, SIZE_IRAM);
    utilGzRead(gzFile, g_paletteRAM, SIZE_PRAM);
    utilGzRead(gzFile, g_workRAM, SIZE_WRAM);
    utilGzRead(gzFile, g_vram, SIZE_VRAM);
    utilGzRead(gzFile, g_oam, SIZE_OAM);
    if (version < SAVE_GAME_VERSION_6)
        utilGzRead(gzFile, g_pix, 4 * 240 * 160);
    else
        utilGzRead(gzFile, g_pix, SIZE_PIX);
    utilGzRead(gzFile, g_ioMem, SIZE_IOMEM);

    if (coreOptions.skipSaveGameBattery) {
        // skip eeprom data
        eepromReadGameSkip(gzFile, version);
        // skip flash data
        flashReadGameSkip(gzFile, version);
    } else {
        eepromReadGame(gzFile, version);
        flashReadGame(gzFile, version);
    }
    soundReadGame(gzFile, version);

    if (version > SAVE_GAME_VERSION_1) {
        if (coreOptions.skipSaveGameCheats) {
            // skip cheats list data
            cheatsReadGameSkip(gzFile, version);
        } else {
            cheatsReadGame(gzFile, version);
        }
    }
    if (version > SAVE_GAME_VERSION_6) {
        rtcReadGame(gzFile);
    }

    if (pristineRomSize > SIZE_ROM) {
        uint8_t ident = 0;
        memcpy(&ident, &g_rom[0xAC], 1);

        if (ident == 'M') {
            utilGzRead(gzFile, &stateMatrix, sizeof(stateMatrix));
        }
    }

    if (version <= SAVE_GAME_VERSION_7) {
        uint32_t temp;
#define SWAP(a, b, c)      \
    temp = (a);            \
    (a) = (b) << 16 | (c); \
    (b) = (temp) >> 16;    \
    (c) = (temp)&0xFFFF;

        SWAP(dma0Source, DM0SAD_H, DM0SAD_L);
        SWAP(dma0Dest, DM0DAD_H, DM0DAD_L);
        SWAP(dma1Source, DM1SAD_H, DM1SAD_L);
        SWAP(dma1Dest, DM1DAD_H, DM1DAD_L);
        SWAP(dma2Source, DM2SAD_H, DM2SAD_L);
        SWAP(dma2Dest, DM2DAD_H, DM2DAD_L);
        SWAP(dma3Source, DM3SAD_H, DM3SAD_L);
        SWAP(dma3Dest, DM3DAD_H, DM3DAD_L);
    }

    if (version <= SAVE_GAME_VERSION_8) {
        timer0ClockReload = TIMER_TICKS[TM0CNT & 3];
        timer1ClockReload = TIMER_TICKS[TM1CNT & 3];
        timer2ClockReload = TIMER_TICKS[TM2CNT & 3];
        timer3ClockReload = TIMER_TICKS[TM3CNT & 3];

        timer0Ticks = ((0x10000 - TM0D) << timer0ClockReload) - timer0Ticks;
        timer1Ticks = ((0x10000 - TM1D) << timer1ClockReload) - timer1Ticks;
        timer2Ticks = ((0x10000 - TM2D) << timer2ClockReload) - timer2Ticks;
        timer3Ticks = ((0x10000 - TM3D) << timer3ClockReload) - timer3Ticks;
        interp_rate();
    }

    // set pointers!
    coreOptions.layerEnable = coreOptions.layerSettings & DISPCNT;

    CPUUpdateRender();
    CPUUpdateRenderBuffers(true);
    CPUUpdateWindow0();
    CPUUpdateWindow1();

    SetSaveType(coreOptions.saveType);

    systemSaveUpdateCounter = SYSTEM_SAVE_NOT_UPDATED;
    if (armState) {
        ARM_PREFETCH;
    } else {
        THUMB_PREFETCH;
    }

    CPUUpdateRegister(0x204, CPUReadHalfWordQuick(0x4000204));

    if (pristineRomSize > SIZE_ROM) {
        uint8_t ident = 0;
        memcpy(&ident, &g_rom[0xAC], 1);

        if (ident == 'M') {
            GBAMatrix.size = 0x200;

            for (int i = 0; i < 16; ++i) {
                GBAMatrix.mappings[i] = stateMatrix.mappings[i];
                GBAMatrix.paddr = GBAMatrix.mappings[i];
                GBAMatrix.vaddr = i << 9;
                _remapMatrix(&GBAMatrix);
            }

            GBAMatrix.cmd = stateMatrix.cmd;
            GBAMatrix.paddr = stateMatrix.paddr;
            GBAMatrix.vaddr = stateMatrix.vaddr;
            GBAMatrix.size = stateMatrix.size;
        }
    }

    return true;
}

bool CPUReadMemState(char* memory, int available)
{
    gzFile gzFile = utilMemGzOpen(memory, available, "r");

    bool res = CPUReadState(gzFile);

    utilGzClose(gzFile);

    return res;
}

bool CPUReadState(const char* file)
{
    gzFile gzFile = utilGzOpen(file, "rb");

    if (gzFile == NULL)
        return false;

    bool res = CPUReadState(gzFile);

    utilGzClose(gzFile);

    return res;
}
#endif

bool CPUExportEepromFile(const char* fileName)
{
    if (eepromInUse) {
        FILE* file = utilOpenFile(fileName, "wb");

        if (!file) {
            systemMessage(MSG_ERROR_CREATING_FILE, N_("Error creating file %s"),
                fileName);
            return false;
        }

        for (int i = 0; i < eepromSize;) {
            for (int j = 0; j < 8; j++) {
                if (fwrite(&eepromData[i + 7 - j], 1, 1, file) != 1) {
                    fclose(file);
                    return false;
                }
            }
            i += 8;
        }
        fclose(file);
    }
    return true;
}

bool CPUWriteBatteryFile(const char* fileName)
{
    if ((coreOptions.saveType) && (coreOptions.saveType != GBA_SAVE_NONE)) {
        FILE* file = utilOpenFile(fileName, "wb");

        if (!file) {
            systemMessage(MSG_ERROR_CREATING_FILE, N_("Error creating file %s"),
                fileName);
            return false;
        }

        // only save if Flash/Sram in use or EEprom in use
        if (!eepromInUse) {
            if (coreOptions.saveType == GBA_SAVE_FLASH) { // save flash type
                if (fwrite(flashSaveMemory, 1, g_flashSize, file) != (size_t)g_flashSize) {
                    fclose(file);
                    return false;
                }
            } else if (coreOptions.saveType == GBA_SAVE_SRAM) { // save sram type
                if (fwrite(flashSaveMemory, 1, 0x8000, file) != 0x8000) {
                    fclose(file);
                    return false;
                }
            }
        } else { // save eeprom type
            if (fwrite(eepromData, 1, eepromSize, file) != (size_t)eepromSize) {
                fclose(file);
                return false;
            }
        }
        fclose(file);
    }
    return true;
}

bool CPUReadGSASnapshot(const char* fileName)
{
    int i;
    FILE* file = utilOpenFile(fileName, "rb");

    if (!file) {
        systemMessage(MSG_CANNOT_OPEN_FILE, N_("Cannot open file %s"), fileName);
        return false;
    }

    // check file size to know what we should read
    fseek(file, 0, SEEK_END);

    // long size = ftell(file);
    fseek(file, 0x0, SEEK_SET);
    FREAD_UNCHECKED(&i, 1, 4, file);
    fseek(file, i, SEEK_CUR); // Skip SharkPortSave
    fseek(file, 4, SEEK_CUR); // skip some sort of flag
    FREAD_UNCHECKED(&i, 1, 4, file); // name length
    fseek(file, i, SEEK_CUR); // skip name
    FREAD_UNCHECKED(&i, 1, 4, file); // desc length
    fseek(file, i, SEEK_CUR); // skip desc
    FREAD_UNCHECKED(&i, 1, 4, file); // notes length
    fseek(file, i, SEEK_CUR); // skip notes
    int saveSize;
    FREAD_UNCHECKED(&saveSize, 1, 4, file); // read length
    saveSize -= 0x1c; // remove header size
    char buffer[17];
    char buffer2[17];
    FREAD_UNCHECKED(buffer, 1, 16, file);
    buffer[16] = 0;
    for (i = 0; i < 16; i++)
        if (buffer[i] < 32)
            buffer[i] = 32;
    memcpy(buffer2, &g_rom[0xa0], 16);
    buffer2[16] = 0;
    for (i = 0; i < 16; i++)
        if (buffer2[i] < 32)
            buffer2[i] = 32;
    if (memcmp(buffer, buffer2, 16)) {
        systemMessage(MSG_CANNOT_IMPORT_SNAPSHOT_FOR,
            N_("Cannot import snapshot for %s. Current game is %s"),
            buffer,
            buffer2);
        fclose(file);
        return false;
    }
    fseek(file, 12, SEEK_CUR); // skip some flags
    if (saveSize >= 65536) {
        if (fread(flashSaveMemory, 1, saveSize, file) != (size_t)saveSize) {
            fclose(file);
            return false;
        }
    } else {
        systemMessage(MSG_UNSUPPORTED_SNAPSHOT_FILE,
            N_("Unsupported snapshot file %s"),
            fileName);
        fclose(file);
        return false;
    }
    fclose(file);
    CPUReset();
    return true;
}

bool CPUReadGSASPSnapshot(const char* fileName)
{
    const char gsvfooter[] = "xV4\x12";
    const size_t namepos = 0x0c, namesz = 12;
    const size_t footerpos = 0x42c, footersz = 4;

    char footer[footersz + 1], romname[namesz + 1], savename[namesz + 1];

    FILE* file = utilOpenFile(fileName, "rb");

    if (!file) {
        systemMessage(MSG_CANNOT_OPEN_FILE, N_("Cannot open file %s"), fileName);
        return false;
    }

    // read save name
    fseek(file, namepos, SEEK_SET);
    FREAD_UNCHECKED(savename, 1, namesz, file);
    savename[namesz] = 0;

    memcpy(romname, &g_rom[0xa0], namesz);
    romname[namesz] = 0;

    if (memcmp(romname, savename, namesz)) {
        systemMessage(MSG_CANNOT_IMPORT_SNAPSHOT_FOR,
            N_("Cannot import snapshot for %s. Current game is %s"),
            savename,
            romname);
        fclose(file);
        return false;
    }

    // read footer tag
    fseek(file, footerpos, SEEK_SET);
    FREAD_UNCHECKED(footer, 1, footersz, file);
    footer[footersz] = 0;

    if (memcmp(footer, gsvfooter, footersz)) {
        systemMessage(0,
            N_("Unsupported snapshot file %s. Footer '%s' at %u should be '%s'"),
            fileName,
            footer,
            footerpos,
            gsvfooter);
        fclose(file);
        return false;
    }

    // Read up to 128k save
    FREAD_UNCHECKED(flashSaveMemory, 1, FLASH_128K_SZ, file);

    fclose(file);
    CPUReset();
    return true;
}

bool CPUWriteGSASnapshot(const char* fileName,
    const char* title,
    const char* desc,
    const char* notes)
{
    FILE* file = utilOpenFile(fileName, "wb");

    if (!file) {
        systemMessage(MSG_CANNOT_OPEN_FILE, N_("Cannot open file %s"), fileName);
        return false;
    }

    uint8_t buffer[17];

    utilPutDword(buffer, 0x0d); // SharkPortSave length
    fwrite(buffer, 1, 4, file);
    fwrite("SharkPortSave", 1, 0x0d, file);
    utilPutDword(buffer, 0x000f0000);
    fwrite(buffer, 1, 4, file); // save type 0x000f0000 = GBA save
    utilPutDword(buffer, (uint32_t)strlen(title));
    fwrite(buffer, 1, 4, file); // title length
    fwrite(title, 1, strlen(title), file);
    utilPutDword(buffer, (uint32_t)strlen(desc));
    fwrite(buffer, 1, 4, file); // desc length
    fwrite(desc, 1, strlen(desc), file);
    utilPutDword(buffer, (uint32_t)strlen(notes));
    fwrite(buffer, 1, 4, file); // notes length
    fwrite(notes, 1, strlen(notes), file);
    int saveSize = 0x10000;
    if (coreOptions.saveType == GBA_SAVE_FLASH)
        saveSize = g_flashSize;
    int totalSize = saveSize + 0x1c;

    utilPutDword(buffer, totalSize); // length of remainder of save - CRC
    fwrite(buffer, 1, 4, file);

    char* temp = new char[0x2001c];
    memset(temp, 0, 28);
    memcpy(temp, &g_rom[0xa0], 16); // copy internal name
    temp[0x10] = g_rom[0xbe]; // reserved area (old checksum)
    temp[0x11] = g_rom[0xbf]; // reserved area (old checksum)
    temp[0x12] = g_rom[0xbd]; // complement check
    temp[0x13] = g_rom[0xb0]; // maker
    temp[0x14] = 1; // 1 save ?
    memcpy(&temp[0x1c], flashSaveMemory, saveSize); // copy save
    fwrite(temp, 1, totalSize, file); // write save + header
    uint32_t crc = 0;

    for (int i = 0; i < totalSize; i++) {
        crc += ((uint32_t)temp[i] << (crc % 0x18));
    }

    utilPutDword(buffer, crc);
    fwrite(buffer, 1, 4, file); // CRC?

    fclose(file);
    delete[] temp;
    return true;
}

bool CPUImportEepromFile(const char* fileName)
{
    FILE* file = utilOpenFile(fileName, "rb");

    if (!file)
        return false;

    // check file size to know what we should read
    fseek(file, 0, SEEK_END);

    long size = ftell(file);
    fseek(file, 0, SEEK_SET);
    if (size == 512 || size == 0x2000) {
        if (fread(eepromData, 1, size, file) != (size_t)size) {
            fclose(file);
            return false;
        }
        for (int i = 0; i < size;) {
            uint8_t tmp = eepromData[i];
            eepromData[i] = eepromData[7 - i];
            eepromData[7 - i] = tmp;
            i++;
            tmp = eepromData[i];
            eepromData[i] = eepromData[7 - i];
            eepromData[7 - i] = tmp;
            i++;
            tmp = eepromData[i];
            eepromData[i] = eepromData[7 - i];
            eepromData[7 - i] = tmp;
            i++;
            tmp = eepromData[i];
            eepromData[i] = eepromData[7 - i];
            eepromData[7 - i] = tmp;
            i++;
            i += 4;
        }
    } else {
        fclose(file);
        return false;
    }
    fclose(file);
    return true;
}

bool CPUReadBatteryFile(const char* fileName)
{
    FILE* file = utilOpenFile(fileName, "rb");

    if (!file)
        return false;

    // check file size to know what we should read
    fseek(file, 0, SEEK_END);

    long size = ftell(file);
    fseek(file, 0, SEEK_SET);
    systemSaveUpdateCounter = SYSTEM_SAVE_NOT_UPDATED;

    if (size == 512 || size == 0x2000) {
        if (fread(eepromData, 1, size, file) != (size_t)size) {
            fclose(file);
            return false;
        }
    } else {
        if (size == 0x20000) {
            if (fread(flashSaveMemory, 1, 0x20000, file) != 0x20000) {
                fclose(file);
                return false;
            }
            flashSetSize(0x20000);
        } else if (size == 0x10000) {
            if (fread(flashSaveMemory, 1, 0x10000, file) != 0x10000) {
                fclose(file);
                return false;
            }
            flashSetSize(0x10000);
        } else if (size == 0x8000) {
            if (fread(flashSaveMemory, 1, 0x8000, file) != 0x8000) {
                fclose(file);
                return false;
            }
        }
    }
    fclose(file);
    return true;
}

#ifndef __LIBRETRO__
bool CPUWritePNGFile(const char* fileName)
{
    return utilWritePNGFile(fileName, 240, 160, g_pix);
}

bool CPUWriteBMPFile(const char* fileName)
{
    return utilWriteBMPFile(fileName, 240, 160, g_pix);
}
#endif /* !__LIBRETRO__ */

bool CPUIsZipFile(const char* file)
{
    if (strlen(file) > 4) {
        const char* p = strrchr(file, '.');

        if (p != NULL) {
            if (_stricmp(p, ".zip") == 0)
                return true;
        }
    }

    return false;
}

bool CPUIsGBAImage(const char* file)
{
    coreOptions.cpuIsMultiBoot = false;
    if (strlen(file) > 4) {
        const char* p = strrchr(file, '.');

        if (p != NULL) {
            if (_stricmp(p, ".gba") == 0)
                return true;
            if (_stricmp(p, ".agb") == 0)
                return true;
            if (_stricmp(p, ".bin") == 0)
                return true;
            if (_stricmp(p, ".elf") == 0)
                return true;
            if (_stricmp(p, ".mb") == 0) {
                coreOptions.cpuIsMultiBoot = true;
                return true;
            }
        }
    }

    return false;
}

bool CPUIsGBABios(const char* file)
{
    if (strlen(file) > 4) {
        const char* p = strrchr(file, '.');

        if (p != NULL) {
            if (_stricmp(p, ".gba") == 0)
                return true;
            if (_stricmp(p, ".agb") == 0)
                return true;
            if (_stricmp(p, ".bin") == 0)
                return true;
            if (_stricmp(p, ".bios") == 0)
                return true;
            if (_stricmp(p, ".rom") == 0)
                return true;
        }
    }

    return false;
}

bool CPUIsELF(const char* file)
{
    if (file == NULL)
        return false;

    if (strlen(file) > 4) {
        const char* p = strrchr(file, '.');

        if (p != NULL) {
            if (_stricmp(p, ".elf") == 0)
                return true;
        }
    }
    return false;
}

#else
/* C translation unit stub: compiled in C++ aggregate mode only. */
#endif
