// iOS-focused translation-unit optimization hints (no behavior change).
#if defined(__APPLE__) && defined(__clang__)
#pragma clang optimize on
#endif
// Rebuilt Objective-C++ module from reference implementation sources.
// NOTE: Source bodies are embedded and adapted here (no direct include of reference files).
#if defined(__cplusplus)
extern "C" {
#endif

// ---- BEGIN rewritten from reference implementation/memory.c ----
mLOG_DEFINE_CATEGORY(GBA_MEM, "GBA Memory", "gba.memory");

static void _pristineCow(struct GBA* gba);
static void _agbPrintStore(struct GBA* gba, uint32_t address, int16_t value);
static int16_t  _agbPrintLoad(struct GBA* gba, uint32_t address);
static uint8_t _deadbeef[4] = { 0x10, 0xB7, 0x10, 0xE7 }; // Illegal instruction on both ARM and Thumb
static const uint32_t _agbPrintFunc = 0x4770DFFA; // swi 0xFA; bx lr

static void GBASetActiveRegion(struct ARMCore* cpu, uint32_t region);
static int32_t GBAMemoryStall(struct ARMCore* cpu, int32_t wait);
static int32_t GBAMemoryStallVRAM(struct GBA* gba, int32_t wait, int extra);

static const char GBA_BASE_WAITSTATES[16] = { 0, 0, 2, 0, 0, 0, 0, 0, 4, 4, 4, 4, 4, 4, 4 };
static const char GBA_BASE_WAITSTATES_32[16] = { 0, 0, 5, 0, 0, 1, 1, 0, 7, 7, 9, 9, 13, 13, 9 };
static const char GBA_BASE_WAITSTATES_SEQ[16] = { 0, 0, 2, 0, 0, 0, 0, 0, 2, 2, 4, 4, 8, 8, 4 };
static const char GBA_BASE_WAITSTATES_SEQ_32[16] = { 0, 0, 5, 0, 0, 1, 1, 0, 5, 5, 9, 9, 17, 17, 9 };
static const char GBA_ROM_WAITSTATES[] = { 4, 3, 2, 8 };
static const char GBA_ROM_WAITSTATES_SEQ[] = { 2, 1, 4, 1, 8, 1 };

void GBAMemoryInit(struct GBA* gba) {
  struct ARMCore* cpu = gba->cpu;
  cpu->memory.load32 = GBALoad32;
  cpu->memory.load16 = GBALoad16;
  cpu->memory.load8 = GBALoad8;
  cpu->memory.loadMultiple = GBALoadMultiple;
  cpu->memory.store32 = GBAStore32;
  cpu->memory.store16 = GBAStore16;
  cpu->memory.store8 = GBAStore8;
  cpu->memory.storeMultiple = GBAStoreMultiple;
  cpu->memory.stall = GBAMemoryStall;

  gba->memory.bios = (uint32_t*) hleBios;
  gba->memory.fullBios = 0;
  gba->memory.wram = 0;
  gba->memory.iwram = 0;
  gba->memory.rom = 0;
  gba->memory.romSize = 0;
  gba->memory.romMask = 0;
  gba->memory.hw.p = gba;

  int i;
  for (i = 0; i < 16; ++i) {
    gba->memory.waitstatesNonseq16[i] = GBA_BASE_WAITSTATES[i];
    gba->memory.waitstatesSeq16[i] = GBA_BASE_WAITSTATES_SEQ[i];
    gba->memory.waitstatesNonseq32[i] = GBA_BASE_WAITSTATES_32[i];
    gba->memory.waitstatesSeq32[i] = GBA_BASE_WAITSTATES_SEQ_32[i];
  }
  for (; i < 256; ++i) {
    gba->memory.waitstatesNonseq16[i] = 0;
    gba->memory.waitstatesSeq16[i] = 0;
    gba->memory.waitstatesNonseq32[i] = 0;
    gba->memory.waitstatesSeq32[i] = 0;
  }

  gba->memory.activeRegion = -1;
  cpu->memory.activeRegion = 0;
  cpu->memory.activeMask = 0;
  cpu->memory.setActiveRegion = GBASetActiveRegion;
  cpu->memory.activeSeqCycles32 = 0;
  cpu->memory.activeSeqCycles16 = 0;
  cpu->memory.activeNonseqCycles32 = 0;
  cpu->memory.activeNonseqCycles16 = 0;
  cpu->memory.accessSource = mACCESS_UNKNOWN;
  gba->memory.biosPrefetch = 0;

  gba->memory.agbPrintProtect = 0;
  memset(&gba->memory.agbPrintCtx, 0, sizeof(gba->memory.agbPrintCtx));
  gba->memory.agbPrintBuffer = NULL;
  gba->memory.agbPrintBufferBackup = NULL;

  gba->memory.wram = anonymousMemoryMap(GBA_SIZE_EWRAM + GBA_SIZE_IWRAM);
  gba->memory.iwram = &gba->memory.wram[GBA_SIZE_EWRAM >> 2];

  GBADMAInit(gba);
  GBAUnlCartInit(gba);

  gba->memory.ereader.p = gba;
  gba->memory.ereader.dots = NULL;
  memset(gba->memory.ereader.cards, 0, sizeof(gba->memory.ereader.cards));
}

void GBAMemoryDeinit(struct GBA* gba) {
  mappedMemoryFree(gba->memory.wram, GBA_SIZE_EWRAM + GBA_SIZE_IWRAM);
  if (gba->memory.rom) {
    mappedMemoryFree(gba->memory.rom, gba->memory.romSize);
  }
  if (gba->memory.agbPrintBuffer) {
    mappedMemoryFree(gba->memory.agbPrintBuffer, GBA_SIZE_AGB_PRINT);
  }
  if (gba->memory.agbPrintBufferBackup) {
    mappedMemoryFree(gba->memory.agbPrintBufferBackup, GBA_SIZE_AGB_PRINT);
  }

  GBACartEReaderDeinit(&gba->memory.ereader);
}

void GBAMemoryReset(struct GBA* gba) {
  if (gba->memory.wram && gba->memory.rom) {
    memset(gba->memory.wram, 0, GBA_SIZE_EWRAM);
  }

  if (gba->memory.iwram) {
    memset(gba->memory.iwram, 0, GBA_SIZE_IWRAM);
  }

  memset(gba->memory.io, 0, sizeof(gba->memory.io));
  GBAAdjustWaitstates(gba, 0);
  GBAAdjustEWRAMWaitstates(gba, 0x0D00);

  GBAMemoryClearAGBPrint(gba);

  gba->memory.prefetch = false;
  gba->memory.lastPrefetchedPc = 0;
  gba->cpu->memory.accessSource = mACCESS_UNKNOWN;

  if (!gba->memory.wram || !gba->memory.iwram) {
    GBAMemoryDeinit(gba);
    mLOG(GBA_MEM, FATAL, "Could not map memory");
  }

  if (!gba->memory.rom) {
    gba->isPristine = false;
  }

  if (gba->memory.hw.devices & HW_GPIO) {
    _pristineCow(gba);
  }

  GBASavedataReset(&gba->memory.savedata);
  GBAHardwareReset(&gba->memory.hw);
  GBADMAReset(gba);
  GBAUnlCartReset(gba);
  memset(&gba->memory.matrix, 0, sizeof(gba->memory.matrix));
}

void GBAMemoryClearAGBPrint(struct GBA* gba) {
  gba->memory.activeRegion = -1;
  gba->memory.agbPrintProtect = 0;
  gba->memory.agbPrintBase = 0;
  memset(&gba->memory.agbPrintCtx, 0, sizeof(gba->memory.agbPrintCtx));
  if (gba->memory.agbPrintBuffer) {
    mappedMemoryFree(gba->memory.agbPrintBuffer, GBA_SIZE_AGB_PRINT);
    gba->memory.agbPrintBuffer = NULL;
  }
  if (gba->memory.agbPrintBufferBackup) {
    mappedMemoryFree(gba->memory.agbPrintBufferBackup, GBA_SIZE_AGB_PRINT);
    gba->memory.agbPrintBufferBackup = NULL;
  }
}

static void _analyzeForIdleLoop(struct GBA* gba, struct ARMCore* cpu, uint32_t address) {
  struct ARMInstructionInfo info;
  uint32_t nextAddress = address;
  memset(gba->taintedRegisters, 0, sizeof(gba->taintedRegisters));
  if (cpu->executionMode == MODE_THUMB) {
    while (true) {
      uint16_t opcode;
      LOAD_16(opcode, nextAddress & cpu->memory.activeMask, cpu->memory.activeRegion);
      ARMDecodeThumb(opcode, &info);
      switch (info.branchType) {
      case ARM_BRANCH_NONE:
        if (info.operandFormat & ARM_OPERAND_MEMORY_2) {
          if (info.mnemonic == ARM_MN_STR || gba->taintedRegisters[info.memory.baseReg]) {
            gba->idleDetectionStep = -1;
            return;
          }
          uint32_t loadAddress = gba->cachedRegisters[info.memory.baseReg];
          uint32_t offset = 0;
          if (info.memory.format & ARM_MEMORY_IMMEDIATE_OFFSET) {
            offset = info.memory.offset.immediate;
          } else if (info.memory.format & ARM_MEMORY_REGISTER_OFFSET) {
            int reg = info.memory.offset.reg;
            if (gba->cachedRegisters[reg]) {
              gba->idleDetectionStep = -1;
              return;
            }
            offset = gba->cachedRegisters[reg];
          }
          if (info.memory.format & ARM_MEMORY_OFFSET_SUBTRACT) {
            loadAddress -= offset;
          } else {
            loadAddress += offset;
          }
          if ((loadAddress >> BASE_OFFSET) == GBA_REGION_IO && !GBAIOIsReadConstant(loadAddress)) {
            gba->idleDetectionStep = -1;
            return;
          }
          if ((loadAddress >> BASE_OFFSET) < GBA_REGION_ROM0 || (loadAddress >> BASE_OFFSET) > GBA_REGION_ROM2_EX) {
            gba->taintedRegisters[info.op1.reg] = true;
          } else {
            switch (info.memory.width) {
            case 1:
              gba->cachedRegisters[info.op1.reg] = GBALoad8(cpu, loadAddress, 0);
              break;
            case 2:
              gba->cachedRegisters[info.op1.reg] = GBALoad16(cpu, loadAddress, 0);
              break;
            case 4:
              gba->cachedRegisters[info.op1.reg] = GBALoad32(cpu, loadAddress, 0);
              break;
            }
          }
        } else if (info.operandFormat & ARM_OPERAND_AFFECTED_1) {
          gba->taintedRegisters[info.op1.reg] = true;
        }
        nextAddress += WORD_SIZE_THUMB;
        break;
      case ARM_BRANCH:
        if ((uint32_t) info.op1.immediate + nextAddress + WORD_SIZE_THUMB * 2 == address) {
          gba->idleLoop = address;
          gba->idleOptimization = IDLE_LOOP_REMOVE;
        }
        gba->idleDetectionStep = -1;
        return;
      default:
        gba->idleDetectionStep = -1;
        return;
      }
    }
  } else {
    gba->idleDetectionStep = -1;
  }
}

static void GBASetActiveRegion(struct ARMCore* cpu, uint32_t address) {
  struct GBA* gba = (struct GBA*) cpu->master;
  struct GBAMemory* memory = &gba->memory;

  int newRegion = address >> BASE_OFFSET;
  if (gba->idleOptimization >= IDLE_LOOP_REMOVE && memory->activeRegion != GBA_REGION_BIOS) {
    if (address == gba->idleLoop) {
      if (gba->haltPending) {
        gba->haltPending = false;
        GBAHalt(gba);
      } else {
        gba->haltPending = true;
      }
    } else if (gba->idleOptimization >= IDLE_LOOP_DETECT && newRegion == memory->activeRegion) {
      if (address == gba->lastJump) {
        switch (gba->idleDetectionStep) {
        case 0:
          memcpy(gba->cachedRegisters, cpu->gprs, sizeof(gba->cachedRegisters));
          ++gba->idleDetectionStep;
          break;
        case 1:
          if (memcmp(gba->cachedRegisters, cpu->gprs, sizeof(gba->cachedRegisters))) {
            gba->idleDetectionStep = -1;
            ++gba->idleDetectionFailures;
            if (gba->idleDetectionFailures > IDLE_LOOP_THRESHOLD) {
              gba->idleOptimization = IDLE_LOOP_IGNORE;
            }
            break;
          }
          _analyzeForIdleLoop(gba, cpu, address);
          break;
        }
      } else {
        gba->idleDetectionStep = 0;
      }
    }
  }

  gba->lastJump = address;
  memory->lastPrefetchedPc = 0;
  if (newRegion == memory->activeRegion) {
    if (cpu->cpsr.t) {
      cpu->memory.activeMask |= WORD_SIZE_THUMB;
    } else {
      cpu->memory.activeMask &= -WORD_SIZE_ARM;
    }
    if (newRegion < GBA_REGION_ROM0 || (address & (GBA_SIZE_ROM0 - 1)) < memory->romSize) {
      return;
    }
  }

  if (memory->activeRegion == GBA_REGION_BIOS) {
    memory->biosPrefetch = cpu->prefetch[1];
  }
  memory->activeRegion = newRegion;
  switch (newRegion) {
  case GBA_REGION_BIOS:
    cpu->memory.accessSource = mACCESS_SYSTEM;
    cpu->memory.activeRegion = memory->bios;
    cpu->memory.activeMask = GBA_SIZE_BIOS - 1;
    break;
  case GBA_REGION_EWRAM:
    cpu->memory.accessSource = mACCESS_PROGRAM;
    cpu->memory.activeRegion = memory->wram;
    cpu->memory.activeMask = GBA_SIZE_EWRAM - 1;
    break;
  case GBA_REGION_IWRAM:
    cpu->memory.accessSource = mACCESS_PROGRAM;
    cpu->memory.activeRegion = memory->iwram;
    cpu->memory.activeMask = GBA_SIZE_IWRAM - 1;
    break;
  case GBA_REGION_PALETTE_RAM:
    cpu->memory.accessSource = mACCESS_PROGRAM;
    cpu->memory.activeRegion = (uint32_t*) gba->video.palette;
    cpu->memory.activeMask = GBA_SIZE_PALETTE_RAM - 1;
    break;
  case GBA_REGION_VRAM:
    cpu->memory.accessSource = mACCESS_PROGRAM;
    if (address & 0x10000) {
      cpu->memory.activeRegion = (uint32_t*) &gba->video.vram[0x8000];
      cpu->memory.activeMask = 0x00007FFF;
    } else {
      cpu->memory.activeRegion = (uint32_t*) gba->video.vram;
      cpu->memory.activeMask = 0x0000FFFF;
    }
    break;
  case GBA_REGION_OAM:
    cpu->memory.accessSource = mACCESS_PROGRAM;
    cpu->memory.activeRegion = (uint32_t*) gba->video.oam.raw;
    cpu->memory.activeMask = GBA_SIZE_OAM - 1;
    break;
  case GBA_REGION_ROM0:
  case GBA_REGION_ROM0_EX:
  case GBA_REGION_ROM1:
  case GBA_REGION_ROM1_EX:
  case GBA_REGION_ROM2:
  case GBA_REGION_ROM2_EX:
    cpu->memory.accessSource = mACCESS_PROGRAM;
    cpu->memory.activeRegion = memory->rom;
    cpu->memory.activeMask = memory->romMask;
    if ((address & (GBA_SIZE_ROM0 - 1)) < memory->romSize) {
      break;
    }
    if ((address & 0x00FFFFFE) == AGB_PRINT_FLUSH_ADDR && memory->agbPrintProtect == 0x20) {
      cpu->memory.activeRegion = &_agbPrintFunc;
      cpu->memory.activeMask = sizeof(_agbPrintFunc) - 1;
      break;
    }
  // Fall through
  default:
    cpu->memory.accessSource = mACCESS_UNKNOWN;
    memory->activeRegion = -1;
    cpu->memory.activeRegion = (uint32_t*) _deadbeef;
    cpu->memory.activeMask = 0;

    if (!gba->yankedRomSize && mCoreCallbacksListSize(&gba->coreCallbacks)) {
      mCALLBACKS_INVOKE(gba, coreCrashed);
    }

    if (gba->yankedRomSize || !gba->hardCrash) {
      mLOG(GBA_MEM, GAME_ERROR, "Jumped to invalid address: %08X", address);
    } else {
      mLOG(GBA_MEM, FATAL, "Jumped to invalid address: %08X", address);
    }
    return;
  }
  cpu->memory.activeSeqCycles32 = memory->waitstatesSeq32[memory->activeRegion];
  cpu->memory.activeSeqCycles16 = memory->waitstatesSeq16[memory->activeRegion];
  cpu->memory.activeNonseqCycles32 = memory->waitstatesNonseq32[memory->activeRegion];
  cpu->memory.activeNonseqCycles16 = memory->waitstatesNonseq16[memory->activeRegion];
  cpu->memory.activeMask &= -(cpu->cpsr.t ? WORD_SIZE_THUMB : WORD_SIZE_ARM);
}

#define LOAD_BAD \
  value = GBALoadBad(cpu);

#define LOAD_BIOS \
  if (address < GBA_SIZE_BIOS) { \
    if (memory->activeRegion == GBA_REGION_BIOS) { \
      LOAD_32(value, address & -4, memory->bios); \
    } else { \
      mLOG(GBA_MEM, GAME_ERROR, "Bad BIOS Load32: 0x%08X", address); \
      value = memory->biosPrefetch; \
    } \
  } else { \
    mLOG(GBA_MEM, GAME_ERROR, "Bad memory Load32: 0x%08X", address); \
    value = GBALoadBad(cpu); \
  }

#define LOAD_EWRAM \
  LOAD_32(value, address & (GBA_SIZE_EWRAM - 4), memory->wram); \
  wait += waitstatesRegion[GBA_REGION_EWRAM];

#define LOAD_IWRAM LOAD_32(value, address & (GBA_SIZE_IWRAM - 4), memory->iwram);
#define LOAD_IO value = GBAIORead(gba, address & OFFSET_MASK & ~3) | (GBAIORead(gba, (address & OFFSET_MASK & ~1) | 2) << 16);

#define LOAD_PALETTE_RAM \
  LOAD_32(value, address & (GBA_SIZE_PALETTE_RAM - 4), gba->video.palette); \
  wait += waitstatesRegion[GBA_REGION_PALETTE_RAM];

#define LOAD_VRAM \
  if ((address & 0x0001FFFF) >= GBA_SIZE_VRAM) { \
    if ((address & (GBA_SIZE_VRAM | 0x00014000)) == GBA_SIZE_VRAM && (GBARegisterDISPCNTGetMode(gba->memory.io[GBA_REG(DISPCNT)]) >= 3)) { \
      mLOG(GBA_MEM, GAME_ERROR, "Bad VRAM Load32: 0x%08X", address); \
      value = 0; \
    } else { \
      LOAD_32(value, address & 0x00017FFC, gba->video.vram); \
    } \
  } else { \
    LOAD_32(value, address & 0x0001FFFC, gba->video.vram); \
  } \
  ++wait; \
  if (gba->video.stallMask && (address & 0x0001FFFF) < ((GBARegisterDISPCNTGetMode(gba->memory.io[GBA_REG(DISPCNT)]) >= 3) ? 0x00014000 : 0x00010000)) { \
    wait += GBAMemoryStallVRAM(gba, wait, 1); \
  }

#define LOAD_OAM LOAD_32(value, address & (GBA_SIZE_OAM - 4), gba->video.oam.raw);

#define LOAD_CART \
  wait += waitstatesRegion[address >> BASE_OFFSET]; \
  if ((address & (GBA_SIZE_ROM0 - 4)) < memory->romSize) { \
    LOAD_32(value, address & (GBA_SIZE_ROM0 - 4), memory->rom); \
  } else if (memory->unl.type == GBA_UNL_CART_VFAME) { \
    value = GBAVFameGetPatternValue(address, 32); \
  } else { \
    mLOG(GBA_MEM, GAME_ERROR, "Out of bounds ROM Load32: 0x%08X", address); \
    value = ((address & ~3) >> 1) & 0xFFFF; \
    value |= (((address & ~3) + 2) >> 1) << 16; \
  }

#define LOAD_SRAM \
  wait = memory->waitstatesNonseq16[address >> BASE_OFFSET]; \
  value = GBALoad8(cpu, address, 0); \
  value |= value << 8; \
  value |= value << 16;

uint32_t GBALoadBad(struct ARMCore* cpu) {
  struct GBA* gba = (struct GBA*) cpu->master;
  uint32_t value = 0;
  if (gba->performingDMA || cpu->gprs[ARM_PC] - gba->dmaPC == (gba->cpu->executionMode == MODE_THUMB ? WORD_SIZE_THUMB : WORD_SIZE_ARM)) {
    value = gba->bus;
  } else {
    value = cpu->prefetch[1];
    if (cpu->executionMode == MODE_THUMB) {
      /* http://ngemu.com/threads/gba-open-bus.170809/ */
      switch (cpu->gprs[ARM_PC] >> BASE_OFFSET) {
      case GBA_REGION_BIOS:
      case GBA_REGION_OAM:
        /* This isn't right half the time, but we don't have $+6 handy */
        value <<= 16;
        value |= cpu->prefetch[0];
        break;
      case GBA_REGION_IWRAM:
        /* This doesn't handle prefetch clobbering */
        if (cpu->gprs[ARM_PC] & 2) {
          value <<= 16;
          value |= cpu->prefetch[0];
        } else {
          value |= cpu->prefetch[0] << 16;
        }
        break;
      default:
        value |= value << 16;
      }
    }
  }
  return value;
}

uint32_t GBALoad32(struct ARMCore* cpu, uint32_t address, int* cycleCounter) {
  struct GBA* gba = (struct GBA*) cpu->master;
  struct GBAMemory* memory = &gba->memory;
  uint32_t value = 0;
  int wait = 0;
  char* waitstatesRegion = memory->waitstatesNonseq32;

  switch (address >> BASE_OFFSET) {
  case GBA_REGION_BIOS:
    LOAD_BIOS;
    break;
  case GBA_REGION_EWRAM:
    LOAD_EWRAM;
    break;
  case GBA_REGION_IWRAM:
    LOAD_IWRAM;
    break;
  case GBA_REGION_IO:
    LOAD_IO;
    break;
  case GBA_REGION_PALETTE_RAM:
    LOAD_PALETTE_RAM;
    break;
  case GBA_REGION_VRAM:
    LOAD_VRAM;
    break;
  case GBA_REGION_OAM:
    LOAD_OAM;
    break;
  case GBA_REGION_ROM0:
  case GBA_REGION_ROM0_EX:
  case GBA_REGION_ROM1:
  case GBA_REGION_ROM1_EX:
  case GBA_REGION_ROM2:
  case GBA_REGION_ROM2_EX:
    LOAD_CART;
    break;
  case GBA_REGION_SRAM:
  case GBA_REGION_SRAM_MIRROR:
    LOAD_SRAM;
    break;
  default:
    mLOG(GBA_MEM, GAME_ERROR, "Bad memory Load32: 0x%08X", address);
    LOAD_BAD;
    break;
  }

  if (cycleCounter) {
    wait += 2;
    if (address < GBA_BASE_ROM0) {
      wait = GBAMemoryStall(cpu, wait);
    }
    *cycleCounter += wait;
  }
  // Unaligned 32-bit loads are "rotated" so they make some semblance of sense
  int rotate = (address & 3) << 3;
  return ROR(value, rotate);
}

uint32_t GBALoad16(struct ARMCore* cpu, uint32_t address, int* cycleCounter) {
  struct GBA* gba = (struct GBA*) cpu->master;
  struct GBAMemory* memory = &gba->memory;
  uint32_t value = 0;
  int wait = 0;

  switch (address >> BASE_OFFSET) {
  case GBA_REGION_BIOS:
    if (address < GBA_SIZE_BIOS) {
      if (memory->activeRegion == GBA_REGION_BIOS) {
        LOAD_16(value, address & -2, memory->bios);
      } else {
        mLOG(GBA_MEM, GAME_ERROR, "Bad BIOS Load16: 0x%08X", address);
        value = (memory->biosPrefetch >> ((address & 2) * 8)) & 0xFFFF;
      }
    } else {
      mLOG(GBA_MEM, GAME_ERROR, "Bad memory Load16: 0x%08X", address);
      value = (GBALoadBad(cpu) >> ((address & 2) * 8)) & 0xFFFF;
    }
    break;
  case GBA_REGION_EWRAM:
    LOAD_16(value, address & (GBA_SIZE_EWRAM - 2), memory->wram);
    wait = memory->waitstatesNonseq16[GBA_REGION_EWRAM];
    break;
  case GBA_REGION_IWRAM:
    LOAD_16(value, address & (GBA_SIZE_IWRAM - 2), memory->iwram);
    break;
  case GBA_REGION_IO:
    value = GBAIORead(gba, address & (OFFSET_MASK - 1));
    break;
  case GBA_REGION_PALETTE_RAM:
    LOAD_16(value, address & (GBA_SIZE_PALETTE_RAM - 2), gba->video.palette);
    break;
  case GBA_REGION_VRAM:
    if ((address & 0x0001FFFF) >= GBA_SIZE_VRAM) {
      if ((address & (GBA_SIZE_VRAM | 0x00014000)) == GBA_SIZE_VRAM && (GBARegisterDISPCNTGetMode(gba->memory.io[GBA_REG(DISPCNT)]) >= 3)) {
        mLOG(GBA_MEM, GAME_ERROR, "Bad VRAM Load16: 0x%08X", address);
        value = 0;
        break;
      }
      LOAD_16(value, address & 0x00017FFE, gba->video.vram);
    } else {
      LOAD_16(value, address & 0x0001FFFE, gba->video.vram);
    }
    if (gba->video.stallMask && (address & 0x0001FFFF) < ((GBARegisterDISPCNTGetMode(gba->memory.io[GBA_REG(DISPCNT)]) >= 3) ? 0x00014000 : 0x00010000)) {
      wait += GBAMemoryStallVRAM(gba, wait, 0);
    }
    break;
  case GBA_REGION_OAM:
    LOAD_16(value, address & (GBA_SIZE_OAM - 2), gba->video.oam.raw);
    break;
  case GBA_REGION_ROM0:
  case GBA_REGION_ROM0_EX:
  case GBA_REGION_ROM1:
  case GBA_REGION_ROM1_EX:
  case GBA_REGION_ROM2:
    wait = memory->waitstatesNonseq16[address >> BASE_OFFSET];
    if ((address & (GBA_SIZE_ROM0 - 2)) < memory->romSize) {
      LOAD_16(value, address & (GBA_SIZE_ROM0 - 2), memory->rom);
    } else if (memory->unl.type == GBA_UNL_CART_VFAME) {
      value = GBAVFameGetPatternValue(address, 16);
    } else if ((address & (GBA_SIZE_ROM0 - 2)) >= AGB_PRINT_BASE) {
      uint32_t agbPrintAddr = address & 0x00FFFFFF;
      if (agbPrintAddr == AGB_PRINT_PROTECT) {
        value = memory->agbPrintProtect;
      } else if (agbPrintAddr < AGB_PRINT_TOP || (agbPrintAddr & 0x00FFFFF8) == AGB_PRINT_STRUCT) {
        value = _agbPrintLoad(gba, address);
      } else {
        mLOG(GBA_MEM, GAME_ERROR, "Out of bounds ROM Load16: 0x%08X", address);
        value = (address >> 1) & 0xFFFF;
      }
    } else {
      mLOG(GBA_MEM, GAME_ERROR, "Out of bounds ROM Load16: 0x%08X", address);
      value = (address >> 1) & 0xFFFF;
    }
    break;
  case GBA_REGION_ROM2_EX:
    wait = memory->waitstatesNonseq16[address >> BASE_OFFSET];
    if (memory->savedata.type == GBA_SAVEDATA_EEPROM || memory->savedata.type == GBA_SAVEDATA_EEPROM512) {
      value = GBASavedataReadEEPROM(&memory->savedata);
    } else if ((address & 0x0DFC0000) >= 0x0DF80000 && memory->hw.devices & HW_EREADER) {
      value = GBACartEReaderRead(&memory->ereader, address);
    } else if ((address & (GBA_SIZE_ROM0 - 2)) < memory->romSize) {
      LOAD_16(value, address & (GBA_SIZE_ROM0 - 2), memory->rom);
    } else if (memory->unl.type == GBA_UNL_CART_VFAME) {
      value = GBAVFameGetPatternValue(address, 16);
    } else {
      mLOG(GBA_MEM, GAME_ERROR, "Out of bounds ROM Load16: 0x%08X", address);
      value = (address >> 1) & 0xFFFF;
    }
    break;
  case GBA_REGION_SRAM:
  case GBA_REGION_SRAM_MIRROR:
    wait = memory->waitstatesNonseq16[address >> BASE_OFFSET];
    value = GBALoad8(cpu, address, 0);
    value |= value << 8;
    break;
  default:
    mLOG(GBA_MEM, GAME_ERROR, "Bad memory Load16: 0x%08X", address);
    value = (GBALoadBad(cpu) >> ((address & 2) * 8)) & 0xFFFF;
    break;
  }

  if (cycleCounter) {
    wait += 2;
    if (address < GBA_BASE_ROM0) {
      wait = GBAMemoryStall(cpu, wait);
    }
    *cycleCounter += wait;
  }
  // Unaligned 16-bit loads are "unpredictable", but the GBA rotates them, so we have to, too.
  int rotate = (address & 1) << 3;
  return ROR(value, rotate);
}

uint32_t GBALoad8(struct ARMCore* cpu, uint32_t address, int* cycleCounter) {
  struct GBA* gba = (struct GBA*) cpu->master;
  struct GBAMemory* memory = &gba->memory;
  uint32_t value = 0;
  int wait = 0;

  switch (address >> BASE_OFFSET) {
  case GBA_REGION_BIOS:
    if (address < GBA_SIZE_BIOS) {
      if (memory->activeRegion == GBA_REGION_BIOS) {
        value = ((uint8_t*) memory->bios)[address];
      } else {
        mLOG(GBA_MEM, GAME_ERROR, "Bad BIOS Load8: 0x%08X", address);
        value = (memory->biosPrefetch >> ((address & 3) * 8)) & 0xFF;
      }
    } else {
      mLOG(GBA_MEM, GAME_ERROR, "Bad memory Load8: 0x%08x", address);
      value = (GBALoadBad(cpu) >> ((address & 3) * 8)) & 0xFF;
    }
    break;
  case GBA_REGION_EWRAM:
    value = ((uint8_t*) memory->wram)[address & (GBA_SIZE_EWRAM - 1)];
    wait = memory->waitstatesNonseq16[GBA_REGION_EWRAM];
    break;
  case GBA_REGION_IWRAM:
    value = ((uint8_t*) memory->iwram)[address & (GBA_SIZE_IWRAM - 1)];
    break;
  case GBA_REGION_IO:
    value = (GBAIORead(gba, address & 0xFFFE) >> ((address & 0x0001) << 3)) & 0xFF;
    break;
  case GBA_REGION_PALETTE_RAM:
    value = ((uint8_t*) gba->video.palette)[address & (GBA_SIZE_PALETTE_RAM - 1)];
    break;
  case GBA_REGION_VRAM:
    if ((address & 0x0001FFFF) >= GBA_SIZE_VRAM) {
      if ((address & (GBA_SIZE_VRAM | 0x00014000)) == GBA_SIZE_VRAM && (GBARegisterDISPCNTGetMode(gba->memory.io[GBA_REG(DISPCNT)]) >= 3)) {
        mLOG(GBA_MEM, GAME_ERROR, "Bad VRAM Load8: 0x%08X", address);
        value = 0;
        break;
      }
      value = ((uint8_t*) gba->video.vram)[address & 0x00017FFF];
    } else {
      value = ((uint8_t*) gba->video.vram)[address & 0x0001FFFF];
    }
    if (gba->video.stallMask) {
      wait += GBAMemoryStallVRAM(gba, wait, 0);
    }
    break;
  case GBA_REGION_OAM:
    value = ((uint8_t*) gba->video.oam.raw)[address & (GBA_SIZE_OAM - 1)];
    break;
  case GBA_REGION_ROM0:
  case GBA_REGION_ROM0_EX:
  case GBA_REGION_ROM1:
  case GBA_REGION_ROM1_EX:
  case GBA_REGION_ROM2:
  case GBA_REGION_ROM2_EX:
    wait = memory->waitstatesNonseq16[address >> BASE_OFFSET];
    if ((address & (GBA_SIZE_ROM0 - 1)) < memory->romSize) {
      value = ((uint8_t*) memory->rom)[address & (GBA_SIZE_ROM0 - 1)];
    } else if (memory->unl.type == GBA_UNL_CART_VFAME) {
      value = GBAVFameGetPatternValue(address, 8);
    } else {
      mLOG(GBA_MEM, GAME_ERROR, "Out of bounds ROM Load8: 0x%08X", address);
      value = ((address >> 1) >> ((address & 1) * 8)) & 0xFF;
    }
    break;
  case GBA_REGION_SRAM:
  case GBA_REGION_SRAM_MIRROR:
    wait = memory->waitstatesNonseq16[address >> BASE_OFFSET];
    if (memory->savedata.type == GBA_SAVEDATA_AUTODETECT) {
      mLOG(GBA_MEM, INFO, "Detected SRAM savegame");
      GBASavedataInitSRAM(&memory->savedata);
    }
    if (gba->performingDMA == 1) {
      break;
    }
    if (memory->hw.devices & HW_EREADER && (address & 0xE00FF80) >= 0xE00FF80) {
      value = GBACartEReaderReadFlash(&memory->ereader, address);
    } else if (memory->savedata.type == GBA_SAVEDATA_SRAM) {
      value = memory->savedata.data[address & (GBA_SIZE_SRAM - 1)];
    } else if (memory->savedata.type == GBA_SAVEDATA_FLASH512 || memory->savedata.type == GBA_SAVEDATA_FLASH1M) {
      value = GBASavedataReadFlash(&memory->savedata, address);
    } else if (memory->hw.devices & HW_TILT) {
      value = GBAHardwareTiltRead(&memory->hw, address & OFFSET_MASK);
    } else if (memory->savedata.type == GBA_SAVEDATA_SRAM512) {
      value = memory->savedata.data[address & (GBA_SIZE_SRAM512 - 1)];
    } else {
      mLOG(GBA_MEM, GAME_ERROR, "Reading from non-existent SRAM: 0x%08X", address);
      value = 0xFF;
    }
    value &= 0xFF;
    break;
  default:
    mLOG(GBA_MEM, GAME_ERROR, "Bad memory Load8: 0x%08x", address);
    value = (GBALoadBad(cpu) >> ((address & 3) * 8)) & 0xFF;
    break;
  }

  if (cycleCounter) {
    wait += 2;
    if (address < GBA_BASE_ROM0) {
      wait = GBAMemoryStall(cpu, wait);
    }
    *cycleCounter += wait;
  }
  return value;
}

#define STORE_EWRAM \
  STORE_32(value, address & (GBA_SIZE_EWRAM - 4), memory->wram); \
  wait += waitstatesRegion[GBA_REGION_EWRAM];

#define STORE_IWRAM \
  STORE_32(value, address & (GBA_SIZE_IWRAM - 4), memory->iwram);

#define STORE_IO \
  GBAIOWrite32(gba, address & (OFFSET_MASK - 3), value);

#define STORE_PALETTE_RAM \
  LOAD_32(oldValue, address & (GBA_SIZE_PALETTE_RAM - 4), gba->video.palette); \
  if (oldValue != value) { \
    STORE_32(value, address & (GBA_SIZE_PALETTE_RAM - 4), gba->video.palette); \
    gba->video.renderer->writePalette(gba->video.renderer, (address & (GBA_SIZE_PALETTE_RAM - 4)) + 2, value >> 16); \
    gba->video.renderer->writePalette(gba->video.renderer, address & (GBA_SIZE_PALETTE_RAM - 4), value); \
  } \
  wait += waitstatesRegion[GBA_REGION_PALETTE_RAM];

#define STORE_VRAM \
  if ((address & 0x0001FFFF) >= GBA_SIZE_VRAM) { \
    if ((address & (GBA_SIZE_VRAM | 0x00014000)) == GBA_SIZE_VRAM && (GBARegisterDISPCNTGetMode(gba->memory.io[GBA_REG(DISPCNT)]) >= 3)) { \
      mLOG(GBA_MEM, GAME_ERROR, "Bad VRAM Store32: 0x%08X", address); \
    } else { \
      LOAD_32(oldValue, address & 0x00017FFC, gba->video.vram); \
      if (oldValue != value) { \
        STORE_32(value, address & 0x00017FFC, gba->video.vram); \
        gba->video.renderer->writeVRAM(gba->video.renderer, (address & 0x00017FFC) + 2); \
        gba->video.renderer->writeVRAM(gba->video.renderer, (address & 0x00017FFC)); \
      } \
    } \
  } else { \
    LOAD_32(oldValue, address & 0x0001FFFC, gba->video.vram); \
    if (oldValue != value) { \
      STORE_32(value, address & 0x0001FFFC, gba->video.vram); \
      gba->video.renderer->writeVRAM(gba->video.renderer, (address & 0x0001FFFC) + 2); \
      gba->video.renderer->writeVRAM(gba->video.renderer, (address & 0x0001FFFC)); \
    } \
  } \
  ++wait; \
  if (gba->video.stallMask && (address & 0x0001FFFF) < ((GBARegisterDISPCNTGetMode(gba->memory.io[GBA_REG(DISPCNT)]) >= 3) ? 0x00014000 : 0x00010000)) { \
    wait += GBAMemoryStallVRAM(gba, wait, 1); \
  }

#define STORE_OAM \
  LOAD_32(oldValue, address & (GBA_SIZE_OAM - 4), gba->video.oam.raw); \
  if (oldValue != value) { \
    STORE_32(value, address & (GBA_SIZE_OAM - 4), gba->video.oam.raw); \
    gba->video.renderer->writeOAM(gba->video.renderer, (address & (GBA_SIZE_OAM - 4)) >> 1); \
    gba->video.renderer->writeOAM(gba->video.renderer, ((address & (GBA_SIZE_OAM - 4)) >> 1) + 1); \
  }

#define STORE_CART \
  wait += waitstatesRegion[address >> BASE_OFFSET]; \
  if (memory->matrix.size && (address & 0x01FFFF00) == 0x00800100) { \
    GBAMatrixWrite(gba, address & 0x3C, value); \
    break; \
  } \
  mLOG(GBA_MEM, STUB, "Unimplemented memory Store32: 0x%08X", address);

#define STORE_SRAM \
  GBAStore8(cpu, address, value >> (8 * (address & 3)), cycleCounter);

#define STORE_BAD \
  mLOG(GBA_MEM, GAME_ERROR, "Bad memory Store32: 0x%08X", address);

void GBAStore32(struct ARMCore* cpu, uint32_t address, int32_t value, int* cycleCounter) {
  struct GBA* gba = (struct GBA*) cpu->master;
  struct GBAMemory* memory = &gba->memory;
  int wait = 0;
  int32_t oldValue;
  char* waitstatesRegion = memory->waitstatesNonseq32;

  switch (address >> BASE_OFFSET) {
  case GBA_REGION_EWRAM:
    STORE_EWRAM;
    break;
  case GBA_REGION_IWRAM:
    STORE_IWRAM
    break;
  case GBA_REGION_IO:
    STORE_IO;
    break;
  case GBA_REGION_PALETTE_RAM:
    STORE_PALETTE_RAM;
    break;
  case GBA_REGION_VRAM:
    STORE_VRAM;
    break;
  case GBA_REGION_OAM:
    STORE_OAM;
    break;
  case GBA_REGION_ROM0:
  case GBA_REGION_ROM0_EX:
  case GBA_REGION_ROM1:
  case GBA_REGION_ROM1_EX:
  case GBA_REGION_ROM2:
  case GBA_REGION_ROM2_EX:
    STORE_CART;
    break;
  case GBA_REGION_SRAM:
  case GBA_REGION_SRAM_MIRROR:
    STORE_SRAM;
    break;
  default:
    STORE_BAD;
    break;
  }

  if (cycleCounter) {
    ++wait;
    if (address < GBA_BASE_ROM0) {
      wait = GBAMemoryStall(cpu, wait);
    }
    *cycleCounter += wait;
  }
}

void GBAStore16(struct ARMCore* cpu, uint32_t address, int16_t value, int* cycleCounter) {
  struct GBA* gba = (struct GBA*) cpu->master;
  struct GBAMemory* memory = &gba->memory;
  int wait = 0;
  int16_t oldValue;

  switch (address >> BASE_OFFSET) {
  case GBA_REGION_EWRAM:
    STORE_16(value, address & (GBA_SIZE_EWRAM - 2), memory->wram);
    wait = memory->waitstatesNonseq16[GBA_REGION_EWRAM];
    break;
  case GBA_REGION_IWRAM:
    STORE_16(value, address & (GBA_SIZE_IWRAM - 2), memory->iwram);
    break;
  case GBA_REGION_IO:
    GBAIOWrite(gba, address & (OFFSET_MASK - 1), value);
    break;
  case GBA_REGION_PALETTE_RAM:
    LOAD_16(oldValue, address & (GBA_SIZE_PALETTE_RAM - 2), gba->video.palette);
    if (oldValue != value) {
      STORE_16(value, address & (GBA_SIZE_PALETTE_RAM - 2), gba->video.palette);
      gba->video.renderer->writePalette(gba->video.renderer, address & (GBA_SIZE_PALETTE_RAM - 2), value);
    }
    break;
  case GBA_REGION_VRAM:
    if ((address & 0x0001FFFF) >= GBA_SIZE_VRAM) {
      if ((address & (GBA_SIZE_VRAM | 0x00014000)) == GBA_SIZE_VRAM && (GBARegisterDISPCNTGetMode(gba->memory.io[GBA_REG(DISPCNT)]) >= 3)) {
        mLOG(GBA_MEM, GAME_ERROR, "Bad VRAM Store16: 0x%08X", address);
        break;
      }
      LOAD_16(oldValue, address & 0x00017FFE, gba->video.vram);
      if (value != oldValue) {
        STORE_16(value, address & 0x00017FFE, gba->video.vram);
        gba->video.renderer->writeVRAM(gba->video.renderer, address & 0x00017FFE);
      }
    } else {
      LOAD_16(oldValue, address & 0x0001FFFE, gba->video.vram);
      if (value != oldValue) {
        STORE_16(value, address & 0x0001FFFE, gba->video.vram);
        gba->video.renderer->writeVRAM(gba->video.renderer, address & 0x0001FFFE);
      }
    }
    if (gba->video.stallMask && (address & 0x0001FFFF) < ((GBARegisterDISPCNTGetMode(gba->memory.io[GBA_REG(DISPCNT)]) >= 3) ? 0x00014000 : 0x00010000)) {
      wait += GBAMemoryStallVRAM(gba, wait, 0);
    }
    break;
  case GBA_REGION_OAM:
    LOAD_16(oldValue, address & (GBA_SIZE_OAM - 2), gba->video.oam.raw);
    if (value != oldValue) {
      STORE_16(value, address & (GBA_SIZE_OAM - 2), gba->video.oam.raw);
      gba->video.renderer->writeOAM(gba->video.renderer, (address & (GBA_SIZE_OAM - 2)) >> 1);
    }
    break;
  case GBA_REGION_ROM0:
    if (IS_GPIO_REGISTER(address & 0xFFFFFE)) {
      if (!(memory->hw.devices & HW_GPIO)) {
        mLOG(GBA_HW, WARN, "Write to GPIO address %08X on cartridge without GPIO", address);
        break;
      }
      uint32_t reg = address & 0xFFFFFE;
      GBAHardwareGPIOWrite(&memory->hw, reg, value);
      break;
    }
    if (memory->matrix.size && (address & 0x01FFFF00) == 0x00800100) {
      GBAMatrixWrite16(gba, address & 0x3C, value);
      break;
    }
    // Fall through
  case GBA_REGION_ROM0_EX:
    if ((address & 0x00FFFFFF) >= AGB_PRINT_BASE) {
      uint32_t agbPrintAddr = address & 0x00FFFFFF;
      if (agbPrintAddr == AGB_PRINT_PROTECT) {
        memory->agbPrintProtect = value;

        if (!memory->agbPrintBuffer) {
          memory->agbPrintBuffer = anonymousMemoryMap(GBA_SIZE_AGB_PRINT);
          if (memory->romSize >= GBA_SIZE_ROM0 / 2) {
            int base = 0;
            if (memory->romSize == GBA_SIZE_ROM0) {
              base = address & 0x01000000;
            }
            memory->agbPrintBase = base;
            memory->agbPrintBufferBackup = anonymousMemoryMap(GBA_SIZE_AGB_PRINT);
            memcpy(memory->agbPrintBufferBackup, &memory->rom[(AGB_PRINT_TOP | base) >> 2], GBA_SIZE_AGB_PRINT);
            LOAD_16(memory->agbPrintProtectBackup, AGB_PRINT_PROTECT | base, memory->rom);
            LOAD_16(memory->agbPrintCtxBackup.request, AGB_PRINT_STRUCT | base, memory->rom);
            LOAD_16(memory->agbPrintCtxBackup.bank, (AGB_PRINT_STRUCT | base) + 2, memory->rom);
            LOAD_16(memory->agbPrintCtxBackup.get, (AGB_PRINT_STRUCT | base) + 4, memory->rom);
            LOAD_16(memory->agbPrintCtxBackup.put, (AGB_PRINT_STRUCT | base) + 6, memory->rom);
            LOAD_32(memory->agbPrintFuncBackup, AGB_PRINT_FLUSH_ADDR | base, memory->rom);
          }
        }

        if (value == 0x20) {
          _agbPrintStore(gba, address, value);
        }
        break;
      }
      if (memory->agbPrintProtect == 0x20 && (agbPrintAddr < AGB_PRINT_TOP || (agbPrintAddr & 0x00FFFFF8) == AGB_PRINT_STRUCT)) {
        _agbPrintStore(gba, address, value);
        break;
      }
    }
    if (memory->unl.type) {
      GBAUnlCartWriteROM(gba, address & (GBA_SIZE_ROM0 - 1), value);
      break;
    }
    mLOG(GBA_MEM, GAME_ERROR, "Bad cartridge Store16: 0x%08X", address);
    break;
  case GBA_REGION_ROM2_EX:
    if ((address & 0x0DFC0000) >= 0x0DF80000 && memory->hw.devices & HW_EREADER) {
      GBACartEReaderWrite(&memory->ereader, address, value);
      break;
    } else if (memory->savedata.type == GBA_SAVEDATA_AUTODETECT) {
      mLOG(GBA_MEM, INFO, "Detected EEPROM savegame");
      GBASavedataInitEEPROM(&memory->savedata);
    }
    if (memory->savedata.type == GBA_SAVEDATA_EEPROM512 || memory->savedata.type == GBA_SAVEDATA_EEPROM) {
      GBASavedataWriteEEPROM(&memory->savedata, value, 1);
      break;
    }
    mLOG(GBA_MEM, GAME_ERROR, "Bad memory Store16: 0x%08X", address);
    break;
  case GBA_REGION_SRAM:
  case GBA_REGION_SRAM_MIRROR:
    if (address & 1) {
      mLOG(GBA_MEM, GAME_ERROR, "Unaligned SRAM Store16: 0x%08X", address);
      value >>= 8;
    }
    GBAStore8(cpu, address, value, cycleCounter);
    break;
  default:
    mLOG(GBA_MEM, GAME_ERROR, "Bad memory Store16: 0x%08X", address);
    break;
  }

  if (cycleCounter) {
    ++wait;
    if (address < GBA_BASE_ROM0) {
      wait = GBAMemoryStall(cpu, wait);
    }
    *cycleCounter += wait;
  }
}

void GBAStore8(struct ARMCore* cpu, uint32_t address, int8_t value, int* cycleCounter) {
  struct GBA* gba = (struct GBA*) cpu->master;
  struct GBAMemory* memory = &gba->memory;
  int wait = 0;
  uint16_t oldValue;

  switch (address >> BASE_OFFSET) {
  case GBA_REGION_EWRAM:
    ((int8_t*) memory->wram)[address & (GBA_SIZE_EWRAM - 1)] = value;
    wait = memory->waitstatesNonseq16[GBA_REGION_EWRAM];
    break;
  case GBA_REGION_IWRAM:
    ((int8_t*) memory->iwram)[address & (GBA_SIZE_IWRAM - 1)] = value;
    break;
  case GBA_REGION_IO:
    GBAIOWrite8(gba, address & OFFSET_MASK, value);
    break;
  case GBA_REGION_PALETTE_RAM:
    GBAStore16(cpu, address & ~1, ((uint8_t) value) | ((uint8_t) value << 8), cycleCounter);
    break;
  case GBA_REGION_VRAM:
    if ((address & 0x0001FFFF) >= ((GBARegisterDISPCNTGetMode(gba->memory.io[GBA_REG(DISPCNT)]) >= 3) ? 0x00014000 : 0x00010000)) {
      mLOG(GBA_MEM, GAME_ERROR, "Cannot Store8 to OBJ: 0x%08X", address);
      break;
    }
    oldValue = gba->video.renderer->vram[(address & 0x1FFFE) >> 1];
    if (oldValue != (((uint8_t) value) | (value << 8))) {
      gba->video.renderer->vram[(address & 0x1FFFE) >> 1] = ((uint8_t) value) | (value << 8);
      gba->video.renderer->writeVRAM(gba->video.renderer, address & 0x0001FFFE);
    }
    if (gba->video.stallMask) {
      wait += GBAMemoryStallVRAM(gba, wait, 0);
    }
    break;
  case GBA_REGION_OAM:
    mLOG(GBA_MEM, GAME_ERROR, "Cannot Store8 to OAM: 0x%08X", address);
    break;
  case GBA_REGION_ROM0:
    mLOG(GBA_MEM, STUB, "Unimplemented memory Store8: 0x%08X", address);
    break;
  case GBA_REGION_SRAM:
  case GBA_REGION_SRAM_MIRROR:
    if (memory->savedata.type == GBA_SAVEDATA_AUTODETECT) {
      if (address == SAVEDATA_FLASH_BASE) {
        mLOG(GBA_MEM, INFO, "Detected Flash savegame");
        GBASavedataInitFlash(&memory->savedata);
      } else {
        mLOG(GBA_MEM, INFO, "Detected SRAM savegame");
        GBASavedataInitSRAM(&memory->savedata);
      }
    }
    if (memory->hw.devices & HW_EREADER && (address & 0xE00FF80) >= 0xE00FF80) {
      GBACartEReaderWriteFlash(&memory->ereader, address, value);
    } else if (memory->savedata.type == GBA_SAVEDATA_FLASH512 || memory->savedata.type == GBA_SAVEDATA_FLASH1M) {
      GBASavedataWriteFlash(&memory->savedata, address, value);
    } else if (memory->savedata.type == GBA_SAVEDATA_SRAM) {
      if (memory->unl.type) {
        GBAUnlCartWriteSRAM(gba, address & 0xFFFF, value);
      } else {
        memory->savedata.data[address & (GBA_SIZE_SRAM - 1)] = value;
      }
      memory->savedata.dirty |= mSAVEDATA_DIRT_NEW;
    } else if (memory->hw.devices & HW_TILT) {
      GBAHardwareTiltWrite(&memory->hw, address & OFFSET_MASK, value);
    } else if (memory->savedata.type == GBA_SAVEDATA_SRAM512) {
      memory->savedata.data[address & (GBA_SIZE_SRAM512 - 1)] = value;
      memory->savedata.dirty |= mSAVEDATA_DIRT_NEW;
    } else {
      mLOG(GBA_MEM, GAME_ERROR, "Writing to non-existent SRAM: 0x%08X", address);
    }
    wait = memory->waitstatesNonseq16[GBA_REGION_SRAM];
    break;
  default:
    mLOG(GBA_MEM, GAME_ERROR, "Bad memory Store8: 0x%08X", address);
    break;
  }

  if (cycleCounter) {
    ++wait;
    if (address < GBA_BASE_ROM0) {
      wait = GBAMemoryStall(cpu, wait);
    }
    *cycleCounter += wait;
  }
}

uint32_t GBAView32(struct ARMCore* cpu, uint32_t address) {
  struct GBA* gba = (struct GBA*) cpu->master;
  uint32_t value = 0;
  address &= ~3;
  switch (address >> BASE_OFFSET) {
  case GBA_REGION_BIOS:
    if (address < GBA_SIZE_BIOS) {
      LOAD_32(value, address, gba->memory.bios);
    }
    break;
  case GBA_REGION_EWRAM:
  case GBA_REGION_IWRAM:
  case GBA_REGION_PALETTE_RAM:
  case GBA_REGION_VRAM:
  case GBA_REGION_OAM:
  case GBA_REGION_ROM0:
  case GBA_REGION_ROM0_EX:
  case GBA_REGION_ROM1:
  case GBA_REGION_ROM1_EX:
  case GBA_REGION_ROM2:
  case GBA_REGION_ROM2_EX:
    value = GBALoad32(cpu, address, 0);
    break;
  case GBA_REGION_IO:
    value = GBAView16(cpu, address);
    value |= GBAView16(cpu, address + 2) << 16;
    break;
  case GBA_REGION_SRAM:
    value = GBALoad8(cpu, address, 0);
    value |= GBALoad8(cpu, address + 1, 0) << 8;
    value |= GBALoad8(cpu, address + 2, 0) << 16;
    value |= GBALoad8(cpu, address + 3, 0) << 24;
    break;
  default:
    break;
  }
  return value;
}

uint16_t GBAView16(struct ARMCore* cpu, uint32_t address) {
  struct GBA* gba = (struct GBA*) cpu->master;
  uint16_t value = 0;
  address &= ~1;
  switch (address >> BASE_OFFSET) {
  case GBA_REGION_BIOS:
    if (address < GBA_SIZE_BIOS) {
      LOAD_16(value, address, gba->memory.bios);
    }
    break;
  case GBA_REGION_EWRAM:
  case GBA_REGION_IWRAM:
  case GBA_REGION_PALETTE_RAM:
  case GBA_REGION_VRAM:
  case GBA_REGION_OAM:
  case GBA_REGION_ROM0:
  case GBA_REGION_ROM0_EX:
  case GBA_REGION_ROM1:
  case GBA_REGION_ROM1_EX:
  case GBA_REGION_ROM2:
  case GBA_REGION_ROM2_EX:
    value = GBALoad16(cpu, address, 0);
    break;
  case GBA_REGION_IO:
    if ((address & OFFSET_MASK) < GBA_REG_MAX || (address & OFFSET_MASK) == GBA_REG_POSTFLG) {
      value = gba->memory.io[(address & OFFSET_MASK) >> 1];
    } else if ((address & OFFSET_MASK) == GBA_REG_EXWAITCNT_LO || (address & OFFSET_MASK) == GBA_REG_EXWAITCNT_HI) {
      address += GBA_REG_INTERNAL_EXWAITCNT_LO - GBA_REG_EXWAITCNT_LO;
      value = gba->memory.io[(address & OFFSET_MASK) >> 1];
    }
    break;
  case GBA_REGION_SRAM:
    value = GBALoad8(cpu, address, 0);
    value |= GBALoad8(cpu, address + 1, 0) << 8;
    break;
  default:
    break;
  }
  return value;
}

uint8_t GBAView8(struct ARMCore* cpu, uint32_t address) {
  struct GBA* gba = (struct GBA*) cpu->master;
  uint8_t value = 0;
  switch (address >> BASE_OFFSET) {
  case GBA_REGION_BIOS:
    if (address < GBA_SIZE_BIOS) {
      value = ((uint8_t*) gba->memory.bios)[address];
    }
    break;
  case GBA_REGION_EWRAM:
  case GBA_REGION_IWRAM:
  case GBA_REGION_ROM0:
  case GBA_REGION_ROM0_EX:
  case GBA_REGION_ROM1:
  case GBA_REGION_ROM1_EX:
  case GBA_REGION_ROM2:
  case GBA_REGION_ROM2_EX:
  case GBA_REGION_SRAM:
    value = GBALoad8(cpu, address, 0);
    break;
  case GBA_REGION_IO:
  case GBA_REGION_PALETTE_RAM:
  case GBA_REGION_VRAM:
  case GBA_REGION_OAM:
    value = GBAView16(cpu, address) >> ((address & 1) * 8);
    break;
  default:
    break;
  }
  return value;
}

void GBAPatch32(struct ARMCore* cpu, uint32_t address, int32_t value, int32_t* old) {
  struct GBA* gba = (struct GBA*) cpu->master;
  struct GBAMemory* memory = &gba->memory;
  int32_t oldValue = -1;

  switch (address >> BASE_OFFSET) {
  case GBA_REGION_EWRAM:
    LOAD_32(oldValue, address & (GBA_SIZE_EWRAM - 4), memory->wram);
    STORE_32(value, address & (GBA_SIZE_EWRAM - 4), memory->wram);
    break;
  case GBA_REGION_IWRAM:
    LOAD_32(oldValue, address & (GBA_SIZE_IWRAM - 4), memory->iwram);
    STORE_32(value, address & (GBA_SIZE_IWRAM - 4), memory->iwram);
    break;
  case GBA_REGION_IO:
    mLOG(GBA_MEM, STUB, "Unimplemented memory Patch32: 0x%08X", address);
    break;
  case GBA_REGION_PALETTE_RAM:
    LOAD_32(oldValue, address & (GBA_SIZE_PALETTE_RAM - 4), gba->video.palette);
    STORE_32(value, address & (GBA_SIZE_PALETTE_RAM - 4), gba->video.palette);
    gba->video.renderer->writePalette(gba->video.renderer, address & (GBA_SIZE_PALETTE_RAM - 4), value);
    gba->video.renderer->writePalette(gba->video.renderer, (address & (GBA_SIZE_PALETTE_RAM - 4)) + 2, value >> 16);
    break;
  case GBA_REGION_VRAM:
    if ((address & 0x0001FFFF) < GBA_SIZE_VRAM) {
      LOAD_32(oldValue, address & 0x0001FFFC, gba->video.vram);
      STORE_32(value, address & 0x0001FFFC, gba->video.vram);
      gba->video.renderer->writeVRAM(gba->video.renderer, address & 0x0001FFFC);
      gba->video.renderer->writeVRAM(gba->video.renderer, (address & 0x0001FFFC) | 2);
    } else {
      LOAD_32(oldValue, address & 0x00017FFC, gba->video.vram);
      STORE_32(value, address & 0x00017FFC, gba->video.vram);
      gba->video.renderer->writeVRAM(gba->video.renderer, address & 0x00017FFC);
      gba->video.renderer->writeVRAM(gba->video.renderer, (address & 0x00017FFC) | 2);
    }
    break;
  case GBA_REGION_OAM:
    LOAD_32(oldValue, address & (GBA_SIZE_OAM - 4), gba->video.oam.raw);
    STORE_32(value, address & (GBA_SIZE_OAM - 4), gba->video.oam.raw);
    gba->video.renderer->writeOAM(gba->video.renderer, (address & (GBA_SIZE_OAM - 4)) >> 1);
    gba->video.renderer->writeOAM(gba->video.renderer, ((address & (GBA_SIZE_OAM - 4)) + 2) >> 1);
    break;
  case GBA_REGION_ROM0:
  case GBA_REGION_ROM0_EX:
  case GBA_REGION_ROM1:
  case GBA_REGION_ROM1_EX:
  case GBA_REGION_ROM2:
  case GBA_REGION_ROM2_EX:
    _pristineCow(gba);
    if ((address & (GBA_SIZE_ROM0 - 4)) >= gba->memory.romSize) {
      gba->memory.romSize = (address & (GBA_SIZE_ROM0 - 4)) + 4;
      gba->memory.romMask = toPow2(gba->memory.romSize) - 1;
    }
    LOAD_32(oldValue, address & (GBA_SIZE_ROM0 - 4), gba->memory.rom);
    STORE_32(value, address & (GBA_SIZE_ROM0 - 4), gba->memory.rom);
    break;
  case GBA_REGION_SRAM:
  case GBA_REGION_SRAM_MIRROR:
    if (memory->savedata.type == GBA_SAVEDATA_SRAM) {
      LOAD_32(oldValue, address & (GBA_SIZE_SRAM - 4), memory->savedata.data);
      STORE_32(value, address & (GBA_SIZE_SRAM - 4), memory->savedata.data);
    } else {
      mLOG(GBA_MEM, GAME_ERROR, "Writing to non-existent SRAM: 0x%08X", address);
    }
    break;
  default:
    mLOG(GBA_MEM, WARN, "Bad memory Patch16: 0x%08X", address);
    break;
  }
  if (old) {
    *old = oldValue;
  }
}

void GBAPatch16(struct ARMCore* cpu, uint32_t address, int16_t value, int16_t* old) {
  struct GBA* gba = (struct GBA*) cpu->master;
  struct GBAMemory* memory = &gba->memory;
  int16_t oldValue = -1;

  switch (address >> BASE_OFFSET) {
  case GBA_REGION_EWRAM:
    LOAD_16(oldValue, address & (GBA_SIZE_EWRAM - 2), memory->wram);
    STORE_16(value, address & (GBA_SIZE_EWRAM - 2), memory->wram);
    break;
  case GBA_REGION_IWRAM:
    LOAD_16(oldValue, address & (GBA_SIZE_IWRAM - 2), memory->iwram);
    STORE_16(value, address & (GBA_SIZE_IWRAM - 2), memory->iwram);
    break;
  case GBA_REGION_IO:
    mLOG(GBA_MEM, STUB, "Unimplemented memory Patch16: 0x%08X", address);
    break;
  case GBA_REGION_PALETTE_RAM:
    LOAD_16(oldValue, address & (GBA_SIZE_PALETTE_RAM - 2), gba->video.palette);
    STORE_16(value, address & (GBA_SIZE_PALETTE_RAM - 2), gba->video.palette);
    gba->video.renderer->writePalette(gba->video.renderer, address & (GBA_SIZE_PALETTE_RAM - 2), value);
    break;
  case GBA_REGION_VRAM:
    if ((address & 0x0001FFFF) < GBA_SIZE_VRAM) {
      LOAD_16(oldValue, address & 0x0001FFFE, gba->video.vram);
      STORE_16(value, address & 0x0001FFFE, gba->video.vram);
      gba->video.renderer->writeVRAM(gba->video.renderer, address & 0x0001FFFE);
    } else {
      LOAD_16(oldValue, address & 0x00017FFE, gba->video.vram);
      STORE_16(value, address & 0x00017FFE, gba->video.vram);
      gba->video.renderer->writeVRAM(gba->video.renderer, address & 0x00017FFE);
    }
    break;
  case GBA_REGION_OAM:
    LOAD_16(oldValue, address & (GBA_SIZE_OAM - 2), gba->video.oam.raw);
    STORE_16(value, address & (GBA_SIZE_OAM - 2), gba->video.oam.raw);
    gba->video.renderer->writeOAM(gba->video.renderer, (address & (GBA_SIZE_OAM - 2)) >> 1);
    break;
  case GBA_REGION_ROM0:
  case GBA_REGION_ROM0_EX:
  case GBA_REGION_ROM1:
  case GBA_REGION_ROM1_EX:
  case GBA_REGION_ROM2:
  case GBA_REGION_ROM2_EX:
    _pristineCow(gba);
    if ((address & (GBA_SIZE_ROM0 - 2)) >= gba->memory.romSize) {
      gba->memory.romSize = (address & (GBA_SIZE_ROM0 - 2)) + 2;
      gba->memory.romMask = toPow2(gba->memory.romSize) - 1;
    }
    LOAD_16(oldValue, address & (GBA_SIZE_ROM0 - 2), gba->memory.rom);
    STORE_16(value, address & (GBA_SIZE_ROM0 - 2), gba->memory.rom);
    break;
  case GBA_REGION_SRAM:
  case GBA_REGION_SRAM_MIRROR:
    if (memory->savedata.type == GBA_SAVEDATA_SRAM) {
      LOAD_16(oldValue, address & (GBA_SIZE_SRAM - 2), memory->savedata.data);
      STORE_16(value, address & (GBA_SIZE_SRAM - 2), memory->savedata.data);
    } else {
      mLOG(GBA_MEM, GAME_ERROR, "Writing to non-existent SRAM: 0x%08X", address);
    }
    break;
  default:
    mLOG(GBA_MEM, WARN, "Bad memory Patch16: 0x%08X", address);
    break;
  }
  if (old) {
    *old = oldValue;
  }
}

#define MUNGE8 \
  if (address & 1) { \
    oldValue = alignedValue >> 8; \
    alignedValue &= 0xFF; \
    alignedValue |= value << 8; \
  } else { \
    oldValue = alignedValue; \
    alignedValue &= 0xFF00; \
    alignedValue |= (uint8_t) value; \
  }

void GBAPatch8(struct ARMCore* cpu, uint32_t address, int8_t value, int8_t* old) {
  struct GBA* gba = (struct GBA*) cpu->master;
  struct GBAMemory* memory = &gba->memory;
  int8_t oldValue = -1;
  int16_t alignedValue;

  switch (address >> BASE_OFFSET) {
  case GBA_REGION_EWRAM:
    oldValue = ((int8_t*) memory->wram)[address & (GBA_SIZE_EWRAM - 1)];
    ((int8_t*) memory->wram)[address & (GBA_SIZE_EWRAM - 1)] = value;
    break;
  case GBA_REGION_IWRAM:
    oldValue = ((int8_t*) memory->iwram)[address & (GBA_SIZE_IWRAM - 1)];
    ((int8_t*) memory->iwram)[address & (GBA_SIZE_IWRAM - 1)] = value;
    break;
  case GBA_REGION_IO:
    mLOG(GBA_MEM, STUB, "Unimplemented memory Patch8: 0x%08X", address);
    break;
  case GBA_REGION_PALETTE_RAM:
    LOAD_16(alignedValue, address & (GBA_SIZE_PALETTE_RAM - 2), gba->video.palette);
    MUNGE8;
    STORE_16(alignedValue, address & (GBA_SIZE_PALETTE_RAM - 2), gba->video.palette);
    gba->video.renderer->writePalette(gba->video.renderer, address & (GBA_SIZE_PALETTE_RAM - 2), alignedValue);
    break;
  case GBA_REGION_VRAM:
    if ((address & 0x0001FFFF) < GBA_SIZE_VRAM) {
      LOAD_16(alignedValue, address & 0x0001FFFE, gba->video.vram);
      MUNGE8;
      STORE_16(alignedValue, address & 0x0001FFFE, gba->video.vram);
      gba->video.renderer->writeVRAM(gba->video.renderer, address & 0x0001FFFE);
    } else {
      LOAD_16(alignedValue, address & 0x00017FFE, gba->video.vram);
      MUNGE8;
      STORE_16(alignedValue, address & 0x00017FFE, gba->video.vram);
      gba->video.renderer->writeVRAM(gba->video.renderer, address & 0x00017FFE);
    }
    break;
  case GBA_REGION_OAM:
    LOAD_16(alignedValue, address & (GBA_SIZE_OAM - 2), gba->video.oam.raw);
    MUNGE8;
    STORE_16(alignedValue, address & (GBA_SIZE_OAM - 2), gba->video.oam.raw);
    gba->video.renderer->writeOAM(gba->video.renderer, (address & (GBA_SIZE_OAM - 2)) >> 1);
    break;
  case GBA_REGION_ROM0:
  case GBA_REGION_ROM0_EX:
  case GBA_REGION_ROM1:
  case GBA_REGION_ROM1_EX:
  case GBA_REGION_ROM2:
  case GBA_REGION_ROM2_EX:
    _pristineCow(gba);
    if ((address & (GBA_SIZE_ROM0 - 1)) >= gba->memory.romSize) {
      gba->memory.romSize = (address & (GBA_SIZE_ROM0 - 2)) + 2;
      gba->memory.romMask = toPow2(gba->memory.romSize) - 1;
    }
    oldValue = ((int8_t*) memory->rom)[address & (GBA_SIZE_ROM0 - 1)];
    ((int8_t*) memory->rom)[address & (GBA_SIZE_ROM0 - 1)] = value;
    break;
  case GBA_REGION_SRAM:
  case GBA_REGION_SRAM_MIRROR:
    if (memory->savedata.type == GBA_SAVEDATA_SRAM) {
      oldValue = ((int8_t*) memory->savedata.data)[address & (GBA_SIZE_SRAM - 1)];
      ((int8_t*) memory->savedata.data)[address & (GBA_SIZE_SRAM - 1)] = value;
    } else {
      mLOG(GBA_MEM, GAME_ERROR, "Writing to non-existent SRAM: 0x%08X", address);
    }
    break;
  default:
    mLOG(GBA_MEM, WARN, "Bad memory Patch8: 0x%08X", address);
    break;
  }
  if (old) {
    *old = oldValue;
  }
}

#define LDM_LOOP(LDM) \
  if (UNLIKELY(!mask)) { \
    LDM; \
    cpu->gprs[ARM_PC] = value; \
    wait += 16; \
    address += 64; \
  } \
  for (i = 0; i < 16; i += 4) { \
    if (UNLIKELY(mask & (1 << i))) { \
      LDM; \
      cpu->gprs[i] = value; \
      ++wait; \
      address += 4; \
    } \
    if (UNLIKELY(mask & (2 << i))) { \
      LDM; \
      cpu->gprs[i + 1] = value; \
      ++wait; \
      address += 4; \
    } \
    if (UNLIKELY(mask & (4 << i))) { \
      LDM; \
      cpu->gprs[i + 2] = value; \
      ++wait; \
      address += 4; \
    } \
    if (UNLIKELY(mask & (8 << i))) { \
      LDM; \
      cpu->gprs[i + 3] = value; \
      ++wait; \
      address += 4; \
    } \
  }

uint32_t GBALoadMultiple(struct ARMCore* cpu, uint32_t address, int mask, enum LSMDirection direction, int* cycleCounter) {
  struct GBA* gba = (struct GBA*) cpu->master;
  struct GBAMemory* memory = &gba->memory;
  uint32_t value;
  char* waitstatesRegion = memory->waitstatesSeq32;

  int i;
  int offset = 4;
  int popcount = 0;
  if (direction & LSM_D) {
    offset = -4;
    popcount = popcount32(mask);
    address -= (popcount << 2) - 4;
  }

  if (direction & LSM_B) {
    address += offset;
  }

  uint32_t addressMisalign = address & 0x3;
  int region = address >> BASE_OFFSET;
  if (region < GBA_REGION_SRAM) {
    address &= 0xFFFFFFFC;
  }
  int wait = memory->waitstatesSeq32[region] - memory->waitstatesNonseq32[region];

  switch (region) {
  case GBA_REGION_BIOS:
    LDM_LOOP(LOAD_BIOS);
    break;
  case GBA_REGION_EWRAM:
    LDM_LOOP(LOAD_EWRAM);
    break;
  case GBA_REGION_IWRAM:
    LDM_LOOP(LOAD_IWRAM);
    break;
  case GBA_REGION_IO:
    LDM_LOOP(LOAD_IO);
    break;
  case GBA_REGION_PALETTE_RAM:
    LDM_LOOP(LOAD_PALETTE_RAM);
    break;
  case GBA_REGION_VRAM:
    LDM_LOOP(LOAD_VRAM);
    break;
  case GBA_REGION_OAM:
    LDM_LOOP(LOAD_OAM);
    break;
  case GBA_REGION_ROM0:
  case GBA_REGION_ROM0_EX:
  case GBA_REGION_ROM1:
  case GBA_REGION_ROM1_EX:
  case GBA_REGION_ROM2:
  case GBA_REGION_ROM2_EX:
    LDM_LOOP(LOAD_CART);
    break;
  case GBA_REGION_SRAM:
  case GBA_REGION_SRAM_MIRROR:
    LDM_LOOP(LOAD_SRAM);
    break;
  default:
    LDM_LOOP(LOAD_BAD);
    break;
  }

  if (cycleCounter) {
    ++wait;
    if (address < GBA_BASE_ROM0) {
      wait = GBAMemoryStall(cpu, wait);
    }
    *cycleCounter += wait;
  }

  if (direction & LSM_B) {
    address -= offset;
  }

  if (direction & LSM_D) {
    address -= (popcount << 2) + 4;
  }

  return address | addressMisalign;
}

#define STM_LOOP(STM) \
  if (UNLIKELY(!mask)) { \
    value = cpu->gprs[ARM_PC] + (cpu->executionMode == MODE_ARM ? WORD_SIZE_ARM : WORD_SIZE_THUMB); \
    STM; \
    wait += 16; \
    address += 64; \
  } \
  for (i = 0; i < 16; i += 4) { \
    if (UNLIKELY(mask & (1 << i))) { \
      value = cpu->gprs[i]; \
      STM; \
      ++wait; \
      address += 4; \
    } \
    if (UNLIKELY(mask & (2 << i))) { \
      value = cpu->gprs[i + 1]; \
      STM; \
      ++wait; \
      address += 4; \
    } \
    if (UNLIKELY(mask & (4 << i))) { \
      value = cpu->gprs[i + 2]; \
      STM; \
      ++wait; \
      address += 4; \
    } \
    if (UNLIKELY(mask & (8 << i))) { \
      value = cpu->gprs[i + 3]; \
      if (i + 3 == ARM_PC) { \
        value += WORD_SIZE_ARM; \
      } \
      STM; \
      ++wait; \
      address += 4; \
    } \
  }

uint32_t GBAStoreMultiple(struct ARMCore* cpu, uint32_t address, int mask, enum LSMDirection direction, int* cycleCounter) {
  struct GBA* gba = (struct GBA*) cpu->master;
  struct GBAMemory* memory = &gba->memory;
  uint32_t value;
  uint32_t oldValue;
  char* waitstatesRegion = memory->waitstatesSeq32;

  int i;
  int offset = 4;
  int popcount = 0;
  if (direction & LSM_D) {
    offset = -4;
    popcount = popcount32(mask);
    address -= (popcount << 2) - 4;
  }

  if (direction & LSM_B) {
    address += offset;
  }

  uint32_t addressMisalign = address & 0x3;
  int region = address >> BASE_OFFSET;
  if (region < GBA_REGION_SRAM) {
    address &= 0xFFFFFFFC;
  }
  int wait = memory->waitstatesSeq32[region] - memory->waitstatesNonseq32[region];

  switch (region) {
  case GBA_REGION_EWRAM:
    STM_LOOP(STORE_EWRAM);
    break;
  case GBA_REGION_IWRAM:
    STM_LOOP(STORE_IWRAM);
    break;
  case GBA_REGION_IO:
    STM_LOOP(STORE_IO);
    break;
  case GBA_REGION_PALETTE_RAM:
    STM_LOOP(STORE_PALETTE_RAM);
    break;
  case GBA_REGION_VRAM:
    STM_LOOP(STORE_VRAM);
    break;
  case GBA_REGION_OAM:
    STM_LOOP(STORE_OAM);
    break;
  case GBA_REGION_ROM0:
  case GBA_REGION_ROM0_EX:
  case GBA_REGION_ROM1:
  case GBA_REGION_ROM1_EX:
  case GBA_REGION_ROM2:
  case GBA_REGION_ROM2_EX:
    STM_LOOP(STORE_CART);
    break;
  case GBA_REGION_SRAM:
  case GBA_REGION_SRAM_MIRROR:
    STM_LOOP(STORE_SRAM);
    break;
  default:
    STM_LOOP(STORE_BAD);
    break;
  }

  if (cycleCounter) {
    if (address < GBA_BASE_ROM0) {
      wait = GBAMemoryStall(cpu, wait);
    }
    *cycleCounter += wait;
  }

  if (direction & LSM_B) {
    address -= offset;
  }

  if (direction & LSM_D) {
    address -= (popcount << 2) + 4;
  }

  return address | addressMisalign;
}

void GBAAdjustWaitstates(struct GBA* gba, uint16_t parameters) {
  struct GBAMemory* memory = &gba->memory;
  struct ARMCore* cpu = gba->cpu;
  int sram = parameters & 0x0003;
  int ws0 = (parameters & 0x000C) >> 2;
  int ws0seq = (parameters & 0x0010) >> 4;
  int ws1 = (parameters & 0x0060) >> 5;
  int ws1seq = (parameters & 0x0080) >> 7;
  int ws2 = (parameters & 0x0300) >> 8;
  int ws2seq = (parameters & 0x0400) >> 10;
  int prefetch = parameters & 0x4000;

  memory->waitstatesNonseq16[GBA_REGION_SRAM] = memory->waitstatesNonseq16[GBA_REGION_SRAM_MIRROR] = GBA_ROM_WAITSTATES[sram];
  memory->waitstatesSeq16[GBA_REGION_SRAM] = memory->waitstatesSeq16[GBA_REGION_SRAM_MIRROR] = GBA_ROM_WAITSTATES[sram];
  memory->waitstatesNonseq32[GBA_REGION_SRAM] = memory->waitstatesNonseq32[GBA_REGION_SRAM_MIRROR] = 2 * GBA_ROM_WAITSTATES[sram] + 1;
  memory->waitstatesSeq32[GBA_REGION_SRAM] = memory->waitstatesSeq32[GBA_REGION_SRAM_MIRROR] = 2 * GBA_ROM_WAITSTATES[sram] + 1;

  memory->waitstatesNonseq16[GBA_REGION_ROM0] = memory->waitstatesNonseq16[GBA_REGION_ROM0_EX] = GBA_ROM_WAITSTATES[ws0];
  memory->waitstatesNonseq16[GBA_REGION_ROM1] = memory->waitstatesNonseq16[GBA_REGION_ROM1_EX] = GBA_ROM_WAITSTATES[ws1];
  memory->waitstatesNonseq16[GBA_REGION_ROM2] = memory->waitstatesNonseq16[GBA_REGION_ROM2_EX] = GBA_ROM_WAITSTATES[ws2];

  memory->waitstatesSeq16[GBA_REGION_ROM0] = memory->waitstatesSeq16[GBA_REGION_ROM0_EX] = GBA_ROM_WAITSTATES_SEQ[ws0seq];
  memory->waitstatesSeq16[GBA_REGION_ROM1] = memory->waitstatesSeq16[GBA_REGION_ROM1_EX] = GBA_ROM_WAITSTATES_SEQ[ws1seq + 2];
  memory->waitstatesSeq16[GBA_REGION_ROM2] = memory->waitstatesSeq16[GBA_REGION_ROM2_EX] = GBA_ROM_WAITSTATES_SEQ[ws2seq + 4];

  memory->waitstatesNonseq32[GBA_REGION_ROM0] = memory->waitstatesNonseq32[GBA_REGION_ROM0_EX] = memory->waitstatesNonseq16[GBA_REGION_ROM0] + 1 + memory->waitstatesSeq16[GBA_REGION_ROM0];
  memory->waitstatesNonseq32[GBA_REGION_ROM1] = memory->waitstatesNonseq32[GBA_REGION_ROM1_EX] = memory->waitstatesNonseq16[GBA_REGION_ROM1] + 1 + memory->waitstatesSeq16[GBA_REGION_ROM1];
  memory->waitstatesNonseq32[GBA_REGION_ROM2] = memory->waitstatesNonseq32[GBA_REGION_ROM2_EX] = memory->waitstatesNonseq16[GBA_REGION_ROM2] + 1 + memory->waitstatesSeq16[GBA_REGION_ROM2];

  memory->waitstatesSeq32[GBA_REGION_ROM0] = memory->waitstatesSeq32[GBA_REGION_ROM0_EX] = 2 * memory->waitstatesSeq16[GBA_REGION_ROM0] + 1;
  memory->waitstatesSeq32[GBA_REGION_ROM1] = memory->waitstatesSeq32[GBA_REGION_ROM1_EX] = 2 * memory->waitstatesSeq16[GBA_REGION_ROM1] + 1;
  memory->waitstatesSeq32[GBA_REGION_ROM2] = memory->waitstatesSeq32[GBA_REGION_ROM2_EX] = 2 * memory->waitstatesSeq16[GBA_REGION_ROM2] + 1;

  memory->prefetch = prefetch;

  cpu->memory.activeSeqCycles32 = memory->waitstatesSeq32[memory->activeRegion];
  cpu->memory.activeSeqCycles16 = memory->waitstatesSeq16[memory->activeRegion];

  cpu->memory.activeNonseqCycles32 = memory->waitstatesNonseq32[memory->activeRegion];
  cpu->memory.activeNonseqCycles16 = memory->waitstatesNonseq16[memory->activeRegion];

  if (memory->agbPrintBufferBackup) {
    int phi = (parameters >> 11) & 3;
    uint32_t base = memory->agbPrintBase;
    if (phi == 3) {
      memcpy(&memory->rom[(AGB_PRINT_TOP | base) >> 2], memory->agbPrintBuffer, GBA_SIZE_AGB_PRINT);
      STORE_16(memory->agbPrintProtect, AGB_PRINT_PROTECT | base, memory->rom);
      STORE_16(memory->agbPrintCtx.request, AGB_PRINT_STRUCT | base, memory->rom);
      STORE_16(memory->agbPrintCtx.bank, (AGB_PRINT_STRUCT | base) + 2, memory->rom);
      STORE_16(memory->agbPrintCtx.get, (AGB_PRINT_STRUCT | base) + 4, memory->rom);
      STORE_16(memory->agbPrintCtx.put, (AGB_PRINT_STRUCT | base) + 6, memory->rom);
      STORE_32(_agbPrintFunc, AGB_PRINT_FLUSH_ADDR | base, memory->rom);
    } else {
      memcpy(&memory->rom[(AGB_PRINT_TOP | base) >> 2], memory->agbPrintBufferBackup, GBA_SIZE_AGB_PRINT);
      STORE_16(memory->agbPrintProtectBackup, AGB_PRINT_PROTECT | base, memory->rom);
      STORE_16(memory->agbPrintCtxBackup.request, AGB_PRINT_STRUCT | base, memory->rom);
      STORE_16(memory->agbPrintCtxBackup.bank, (AGB_PRINT_STRUCT | base) + 2, memory->rom);
      STORE_16(memory->agbPrintCtxBackup.get, (AGB_PRINT_STRUCT | base) + 4, memory->rom);
      STORE_16(memory->agbPrintCtxBackup.put, (AGB_PRINT_STRUCT | base) + 6, memory->rom);
      STORE_32(memory->agbPrintFuncBackup, AGB_PRINT_FLUSH_ADDR | base, memory->rom);
    }
  }

  if (gba->performingDMA) {
    GBADMARecalculateCycles(gba);
  }
}

void GBAAdjustEWRAMWaitstates(struct GBA* gba, uint16_t parameters) {
  struct GBAMemory* memory = &gba->memory;
  struct ARMCore* cpu = gba->cpu;

  int wait = 15 - ((parameters >> 8) & 0xF);
  if (wait) {
    memory->waitstatesNonseq16[GBA_REGION_EWRAM] = wait;
    memory->waitstatesSeq16[GBA_REGION_EWRAM] = wait;
    memory->waitstatesNonseq32[GBA_REGION_EWRAM] = 2 * wait + 1;
    memory->waitstatesSeq32[GBA_REGION_EWRAM] = 2 * wait + 1;

    cpu->memory.activeSeqCycles32 = memory->waitstatesSeq32[memory->activeRegion];
    cpu->memory.activeSeqCycles16 = memory->waitstatesSeq16[memory->activeRegion];

    cpu->memory.activeNonseqCycles32 = memory->waitstatesNonseq32[memory->activeRegion];
    cpu->memory.activeNonseqCycles16 = memory->waitstatesNonseq16[memory->activeRegion];
  } else {
    if (!gba->hardCrash) {
      mLOG(GBA_MEM, GAME_ERROR, "Cannot set EWRAM to 0 waitstates");
    } else {
      mLOG(GBA_MEM, FATAL, "Cannot set EWRAM to 0 waitstates");
    }
  }
}

int32_t GBAMemoryStall(struct ARMCore* cpu, int32_t wait) {
  struct GBA* gba = (struct GBA*) cpu->master;
  struct GBAMemory* memory = &gba->memory;

  if (memory->activeRegion < GBA_REGION_ROM0 || !memory->prefetch) {
    // The wait is the stall
    return wait;
  }

  int32_t previousLoads = 0;

  // Don't prefetch too much if we're overlapping with a previous prefetch
  uint32_t dist = (memory->lastPrefetchedPc - cpu->gprs[ARM_PC]);
  int32_t maxLoads = 8;
  if (dist < 16) {
    previousLoads = dist >> 1;
    maxLoads -= previousLoads;
  }

  // Figure out how many sequential loads we can jam in
  int32_t s = cpu->memory.activeSeqCycles16;
  int32_t stall = s + 1;
  int32_t loads = 1;

  while (stall < wait && loads < maxLoads) {
    stall += s;
    ++loads;
  }
  memory->lastPrefetchedPc = cpu->gprs[ARM_PC] + WORD_SIZE_THUMB * (loads + previousLoads - 1);

  if (stall > wait) {
    // The wait cannot take less time than the prefetch stalls
    wait = stall;
  }

  // This instruction used to have an N, convert it to an S.
  wait -= cpu->memory.activeNonseqCycles16 - s;

  // The next |loads|S waitstates disappear entirely, so long as they're all in a row
  wait -= stall;

  return wait;
}

int32_t GBAMemoryStallVRAM(struct GBA* gba, int32_t wait, int extra) {
  static const uint16_t stallLUT[32] = {
    GBA_VSTALL_T4(0) | GBA_VSTALL_A3,
    GBA_VSTALL_T4(1) | GBA_VSTALL_A3,
    GBA_VSTALL_T4(2) | GBA_VSTALL_A2,
    GBA_VSTALL_T4(3) | GBA_VSTALL_A2 | GBA_VSTALL_B,

    GBA_VSTALL_T4(0) | GBA_VSTALL_A3,
    GBA_VSTALL_T4(1) | GBA_VSTALL_A3,
    GBA_VSTALL_T4(2) | GBA_VSTALL_A2,
    GBA_VSTALL_T4(3) | GBA_VSTALL_A2 | GBA_VSTALL_B,

    GBA_VSTALL_A3,
    GBA_VSTALL_A3,
    GBA_VSTALL_A2,
    GBA_VSTALL_A2 | GBA_VSTALL_B,

    GBA_VSTALL_T8(0) | GBA_VSTALL_A3,
    GBA_VSTALL_T8(1) | GBA_VSTALL_A3,
    GBA_VSTALL_T8(2) | GBA_VSTALL_A2,
    GBA_VSTALL_T8(3) | GBA_VSTALL_A2 | GBA_VSTALL_B,

    GBA_VSTALL_A3,
    GBA_VSTALL_A3,
    GBA_VSTALL_A2,
    GBA_VSTALL_A2 | GBA_VSTALL_B,

    GBA_VSTALL_T4(0) | GBA_VSTALL_A3,
    GBA_VSTALL_T4(1) | GBA_VSTALL_A3,
    GBA_VSTALL_T4(2) | GBA_VSTALL_A2,
    GBA_VSTALL_T4(3) | GBA_VSTALL_A2 | GBA_VSTALL_B,

    GBA_VSTALL_A3,
    GBA_VSTALL_A3,
    GBA_VSTALL_A2,
    GBA_VSTALL_A2 | GBA_VSTALL_B,

    GBA_VSTALL_T8(0) | GBA_VSTALL_A3,
    GBA_VSTALL_T8(1) | GBA_VSTALL_A3,
    GBA_VSTALL_T8(2) | GBA_VSTALL_A2,
    GBA_VSTALL_T8(3) | GBA_VSTALL_A2 | GBA_VSTALL_B,
  };

  int32_t until = mTimingUntil(&gba->timing, &gba->video.event);
  int period = -until & 0x1F;

  int32_t stall = until;

  int i;
  for (i = 0; i < 16; ++i) {
    if (!(stallLUT[(period + i) & 0x1F] & gba->video.stallMask)) {
      if (!extra) {
        stall = i;
        break;
      }
      --extra;
    }
  }

  stall -= wait;
  if (stall < 0) {
    return 0;
  }
  return stall;
}

void GBAMemorySerialize(const struct GBAMemory* memory, struct GBASerializedState* state) {
  memcpy(state->wram, memory->wram, GBA_SIZE_EWRAM);
  memcpy(state->iwram, memory->iwram, GBA_SIZE_IWRAM);
}

void GBAMemoryDeserialize(struct GBAMemory* memory, const struct GBASerializedState* state) {
  memcpy(memory->wram, state->wram, GBA_SIZE_EWRAM);
  memcpy(memory->iwram, state->iwram, GBA_SIZE_IWRAM);
}

void _pristineCow(struct GBA* gba) {
  if (!gba->isPristine) {
    return;
  }
#if !defined(FIXED_ROM_BUFFER) && !defined(__wii__)
  void* newRom = anonymousMemoryMap(GBA_SIZE_ROM0);
  memcpy(newRom, gba->memory.rom, gba->memory.romSize);
  memset(((uint8_t*) newRom) + gba->memory.romSize, 0xFF, GBA_SIZE_ROM0 - gba->memory.romSize);
  if (gba->cpu->memory.activeRegion == gba->memory.rom) {
    gba->cpu->memory.activeRegion = newRom;
  }
  if (gba->romVf) {
    gba->romVf->unmap(gba->romVf, gba->memory.rom, gba->memory.romSize);
  }
  gba->memory.rom = newRom;
  gba->memory.hw.gpioBase = &((uint16_t*) gba->memory.rom)[GPIO_REG_DATA >> 1];
#endif
  gba->isPristine = false;
}

void GBAPrintFlush(struct GBA* gba) {
  if (!gba->memory.agbPrintBuffer) {
    return;
  }

  char oolBuf[0x101];
  size_t i;
  for (i = 0; gba->memory.agbPrintCtx.get != gba->memory.agbPrintCtx.put && i < 0x100; ++i) {
    int16_t value;
    LOAD_16(value, gba->memory.agbPrintCtx.get & -2, gba->memory.agbPrintBuffer);
    if (gba->memory.agbPrintCtx.get & 1) {
      value >>= 8;
    } else {
      value &= 0xFF;
    }
    oolBuf[i] = value;
    oolBuf[i + 1] = 0;
    ++gba->memory.agbPrintCtx.get;
  }
  _agbPrintStore(gba, (AGB_PRINT_STRUCT + 4) | gba->memory.agbPrintBase, gba->memory.agbPrintCtx.get);

  mLOG(GBA_DEBUG, INFO, "%s", oolBuf);
}

static void _agbPrintStore(struct GBA* gba, uint32_t address, int16_t value) {
  struct GBAMemory* memory = &gba->memory;
  if ((address & 0x00FFFFFF) < AGB_PRINT_TOP) {
    STORE_16(value, address & (GBA_SIZE_AGB_PRINT - 2), memory->agbPrintBuffer);
  } else if ((address & 0x00FFFFF8) == AGB_PRINT_STRUCT) {
    (&memory->agbPrintCtx.request)[(address & 7) >> 1] = value;
  }
  if (memory->romSize == GBA_SIZE_ROM0) {
    _pristineCow(gba);
    STORE_16(value, address & (GBA_SIZE_ROM0 - 2), memory->rom);
  } else if (memory->agbPrintCtx.bank == 0xFD && memory->romSize >= GBA_SIZE_ROM0 / 2) {
    _pristineCow(gba);
    STORE_16(value, address & (GBA_SIZE_ROM0 / 2 - 2), memory->rom);
  }
}

static int16_t _agbPrintLoad(struct GBA* gba, uint32_t address) {
  struct GBAMemory* memory = &gba->memory;
  int16_t value = address >> 1;
  if (address < AGB_PRINT_TOP && memory->agbPrintBuffer) {
    LOAD_16(value, address & (GBA_SIZE_AGB_PRINT - 1), memory->agbPrintBuffer);
  } else if ((address & 0x00FFFFF8) == AGB_PRINT_STRUCT) {
    value = (&memory->agbPrintCtx.request)[(address & 7) >> 1];
  }
  return value;
}
// ---- END rewritten from reference implementation/memory.c ----

// ---- BEGIN rewritten from reference implementation/bios.c ----

static void _unLz77(struct GBA* gba, int width);
static void _unHuffman(struct GBA* gba);
static void _unRl(struct GBA* gba, int width);
static void _unFilter(struct GBA* gba, int inwidth, int outwidth);
static void _unBitPack(struct GBA* gba);

static int _mulWait(int32_t r) {
  if ((r & 0xFFFFFF00) == 0xFFFFFF00 || !(r & 0xFFFFFF00)) {
    return 1;
  } else if ((r & 0xFFFF0000) == 0xFFFF0000 || !(r & 0xFFFF0000)) {
    return 2;
  } else if ((r & 0xFF000000) == 0xFF000000 || !(r & 0xFF000000)) {
    return 3;
  } else {
    return 4;
  }
}

static void _RegisterRamReset(struct GBA* gba) {
  uint32_t registers = gba->cpu->gprs[0];
  struct ARMCore* cpu = gba->cpu;
  cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DISPCNT, 0x0080, 0);
  if (registers & 0x01) {
    memset(gba->memory.wram, 0, GBA_SIZE_EWRAM);
  }
  if (registers & 0x02) {
    memset(gba->memory.iwram, 0, GBA_SIZE_IWRAM - 0x200);
  }
  if (registers & 0x04) {
    memset(gba->video.palette, 0, GBA_SIZE_PALETTE_RAM);
  }
  if (registers & 0x08) {
    memset(gba->video.vram, 0, GBA_SIZE_VRAM);
  }
  if (registers & 0x10) {
    memset(gba->video.oam.raw, 0, GBA_SIZE_OAM);
  }
  if (registers & 0x20) {
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_SIOCNT, 0x0000, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_RCNT, RCNT_INITIAL, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_SIOMLT_SEND, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_JOYCNT, 0, 0);
    cpu->memory.store32(cpu, GBA_BASE_IO | GBA_REG_JOY_RECV_LO, 0, 0);
    cpu->memory.store32(cpu, GBA_BASE_IO | GBA_REG_JOY_TRANS_LO, 0, 0);
  }
  if (registers & 0x40) {
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_SOUND1CNT_LO, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_SOUND1CNT_HI, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_SOUND1CNT_X, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_SOUND2CNT_LO, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_SOUND2CNT_HI, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_SOUND3CNT_LO, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_SOUND3CNT_HI, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_SOUND3CNT_X, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_SOUND4CNT_LO, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_SOUND4CNT_HI, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_SOUNDCNT_LO, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_SOUNDCNT_HI, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_SOUNDCNT_X, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_SOUNDBIAS, 0x200, 0);
    memset(gba->audio.psg.ch3.wavedata32, 0, sizeof(gba->audio.psg.ch3.wavedata32));
  }
  if (registers & 0x80) {
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DISPSTAT, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_VCOUNT, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_BG0CNT, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_BG1CNT, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_BG2CNT, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_BG3CNT, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_BG0HOFS, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_BG0VOFS, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_BG1HOFS, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_BG1VOFS, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_BG2HOFS, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_BG2VOFS, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_BG3HOFS, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_BG3VOFS, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_BG2PA, 0x100, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_BG2PB, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_BG2PC, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_BG2PD, 0x100, 0);
    cpu->memory.store32(cpu, GBA_BASE_IO | GBA_REG_BG2X_LO, 0, 0);
    cpu->memory.store32(cpu, GBA_BASE_IO | GBA_REG_BG2Y_LO, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_BG3PA, 0x100, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_BG3PB, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_BG3PC, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_BG3PD, 0x100, 0);
    cpu->memory.store32(cpu, GBA_BASE_IO | GBA_REG_BG3X_LO, 0, 0);
    cpu->memory.store32(cpu, GBA_BASE_IO | GBA_REG_BG3Y_LO, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_WIN0H, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_WIN1H, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_WIN0V, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_WIN1V, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_WININ, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_WINOUT, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_MOSAIC, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_BLDCNT, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_BLDALPHA, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_BLDY, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA0SAD_LO, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA0SAD_HI, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA0DAD_LO, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA0DAD_HI, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA0CNT_LO, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA0CNT_HI, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA1SAD_LO, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA1SAD_HI, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA1DAD_LO, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA1DAD_HI, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA1CNT_LO, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA1CNT_HI, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA2SAD_LO, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA2SAD_HI, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA2DAD_LO, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA2DAD_HI, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA2CNT_LO, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA2CNT_HI, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA3SAD_LO, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA3SAD_HI, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA3DAD_LO, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA3DAD_HI, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA3CNT_LO, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_DMA3CNT_HI, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_TM0CNT_LO, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_TM0CNT_HI, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_TM1CNT_LO, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_TM1CNT_HI, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_TM2CNT_LO, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_TM2CNT_HI, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_TM3CNT_LO, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_TM3CNT_HI, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_IE, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_IF, 0xFFFF, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_WAITCNT, 0, 0);
    cpu->memory.store16(cpu, GBA_BASE_IO | GBA_REG_IME, 0, 0);
  }
  if (registers & 0x9C) {
    gba->video.renderer->reset(gba->video.renderer);
    gba->video.renderer->writeVideoRegister(gba->video.renderer, GBA_REG_DISPCNT, gba->memory.io[GBA_REG(DISPCNT)]);
    int i;
    for (i = GBA_REG_BG0CNT; i < GBA_REG_SOUND1CNT_LO; i += 2) {
      gba->video.renderer->writeVideoRegister(gba->video.renderer, i, gba->memory.io[i >> 1]);
    }
  }
}

static void _BgAffineSet(struct GBA* gba) {
  struct ARMCore* cpu = gba->cpu;
  int i = cpu->gprs[2];
  float ox, oy;
  float cx, cy;
  float sx, sy;
  float theta;
  int offset = cpu->gprs[0];
  int destination = cpu->gprs[1];
  float a, b, c, d;
  float rx, ry;
  enum mMemoryAccessSource oldAccess = cpu->memory.accessSource;
  cpu->memory.accessSource = mACCESS_SYSTEM;
  while (i--) {
    // [ sx   0  0 ]   [ cos(theta)  -sin(theta)  0 ]   [ 1  0  cx - ox ]   [ A B rx ]
    // [  0  sy  0 ] * [ sin(theta)   cos(theta)  0 ] * [ 0  1  cy - oy ] = [ C D ry ]
    // [  0   0  1 ]   [     0            0       1 ]   [ 0  0     1    ]   [ 0 0  1 ]
    ox = (int32_t) cpu->memory.load32(cpu, offset, 0) / 256.f;
    oy = (int32_t) cpu->memory.load32(cpu, offset + 4, 0) / 256.f;
    cx = (int16_t) cpu->memory.load16(cpu, offset + 8, 0);
    cy = (int16_t) cpu->memory.load16(cpu, offset + 10, 0);
    sx = (int16_t) cpu->memory.load16(cpu, offset + 12, 0) / 256.f;
    sy = (int16_t) cpu->memory.load16(cpu, offset + 14, 0) / 256.f;
    theta = (cpu->memory.load16(cpu, offset + 16, 0) >> 8) / 128.f * M_PI;
    offset += 20;
    // Rotation
    a = d = cosf(theta);
    b = c = sinf(theta);
    // Scale
    a *= sx;
    b *= -sx;
    c *= sy;
    d *= sy;
    // Translate
    rx = ox - (a * cx + b * cy);
    ry = oy - (c * cx + d * cy);
    cpu->memory.store16(cpu, destination, a * 256, 0);
    cpu->memory.store16(cpu, destination + 2, b * 256, 0);
    cpu->memory.store16(cpu, destination + 4, c * 256, 0);
    cpu->memory.store16(cpu, destination + 6, d * 256, 0);
    cpu->memory.store32(cpu, destination + 8, rx * 256, 0);
    cpu->memory.store32(cpu, destination + 12, ry * 256, 0);
    destination += 16;
  }
  cpu->memory.accessSource = oldAccess;
}

static void _ObjAffineSet(struct GBA* gba) {
  struct ARMCore* cpu = gba->cpu;
  int i = cpu->gprs[2];
  float sx, sy;
  float theta;
  int offset = cpu->gprs[0];
  int destination = cpu->gprs[1];
  int diff = cpu->gprs[3];
  float a, b, c, d;
  enum mMemoryAccessSource oldAccess = cpu->memory.accessSource;
  cpu->memory.accessSource = mACCESS_SYSTEM;
  while (i--) {
    // [ sx   0 ]   [ cos(theta)  -sin(theta) ]   [ A B ]
    // [  0  sy ] * [ sin(theta)   cos(theta) ] = [ C D ]
    sx = (int16_t) cpu->memory.load16(cpu, offset, 0) / 256.f;
    sy = (int16_t) cpu->memory.load16(cpu, offset + 2, 0) / 256.f;
    theta = (cpu->memory.load16(cpu, offset + 4, 0) >> 8) / 128.f * M_PI;
    offset += 8;
    // Rotation
    a = d = cosf(theta);
    b = c = sinf(theta);
    // Scale
    a *= sx;
    b *= -sx;
    c *= sy;
    d *= sy;
    cpu->memory.store16(cpu, destination, a * 256, 0);
    cpu->memory.store16(cpu, destination + diff, b * 256, 0);
    cpu->memory.store16(cpu, destination + diff * 2, c * 256, 0);
    cpu->memory.store16(cpu, destination + diff * 3, d * 256, 0);
    destination += diff * 4;
  }
  cpu->memory.accessSource = oldAccess;
}

static void _MidiKey2Freq(struct GBA* gba) {
  struct ARMCore* cpu = gba->cpu;

  int oldRegion = gba->memory.activeRegion;
  gba->memory.activeRegion = GBA_REGION_BIOS;
  enum mMemoryAccessSource oldAccess = cpu->memory.accessSource;
  cpu->memory.accessSource = mACCESS_SYSTEM;
  uint32_t key = cpu->memory.load32(cpu, cpu->gprs[0] + 4, 0);
  cpu->memory.accessSource = oldAccess;
  gba->memory.activeRegion = oldRegion;

  cpu->gprs[0] = key / exp2f((180.f - cpu->gprs[1] - cpu->gprs[2] / 256.f) / 12.f);
}

static void _Div(struct GBA* gba, int32_t num, int32_t denom) {
  struct ARMCore* cpu = gba->cpu;
  if (denom == 0) {
    if (num == 0 || num == -1 || num == 1) {
      mLOG(GBA_BIOS, GAME_ERROR, "Attempting to divide %i by zero!", num);
    } else {
      mLOG(GBA_BIOS, FATAL, "Attempting to divide %i by zero!", num);
    }
    // If abs(num) > 1, this should hang, but that would be painful to
    // emulate in HLE, and no game will get into a state under normal
    // operation where it hangs...
    cpu->gprs[0] = (num < 0) ? -1 : 1;
    cpu->gprs[1] = num;
    cpu->gprs[3] = 1;
  } else if (denom == -1 && num == INT32_MIN) {
    mLOG(GBA_BIOS, GAME_ERROR, "Attempting to divide INT_MIN by -1!");
    cpu->gprs[0] = INT32_MIN;
    cpu->gprs[1] = 0;
    cpu->gprs[3] = INT32_MIN;
  } else {
    div_t result = div(num, denom);
    cpu->gprs[0] = result.quot;
    cpu->gprs[1] = result.rem;
    cpu->gprs[3] = abs(result.quot);
  }
  int loops = clz32(denom) - clz32(num);
  if (loops < 1) {
    loops = 1;
  }
  gba->biosStall = 4 /* prologue */ + 13 * loops + 7 /* epilogue */;
}

static int16_t _ArcTan(int32_t i, int32_t* r1, int32_t* r3, uint32_t* cycles) {
  uint32_t currentCycles = 37;
  currentCycles += _mulWait(i * i);
  int32_t a = -((i * i) >> 14);
  currentCycles += _mulWait(0xA9 * a);
  int32_t b = ((0xA9 * a) >> 14) + 0x390;
  currentCycles += _mulWait(b * a);
  b = ((b * a) >> 14) + 0x91C;
  currentCycles += _mulWait(b * a);
  b = ((b * a) >> 14) + 0xFB6;
  currentCycles += _mulWait(b * a);
  b = ((b * a) >> 14) + 0x16AA;
  currentCycles += _mulWait(b * a);
  b = ((b * a) >> 14) + 0x2081;
  currentCycles += _mulWait(b * a);
  b = ((b * a) >> 14) + 0x3651;
  currentCycles += _mulWait(b * a);
  b = ((b * a) >> 14) + 0xA2F9;
  if (r1) {
    *r1 = a;
  }
  if (r3) {
    *r3 = b;
  }
  *cycles = currentCycles;
  return (i * b) >> 16;
}

static int16_t _ArcTan2(int32_t x, int32_t y, int32_t* r1, uint32_t* cycles) {
  if (!y) {
    *cycles = 11;
    if (x >= 0) {
      return 0;
    }
    return 0x8000;
  }
  if (!x) {
    *cycles = 11;
    if (y >= 0) {
      return 0x4000;
    }
    return 0xC000;
  }
  if (y >= 0) {
    if (x >= 0) {
      if (x >= y) {
        return _ArcTan((y << 14) / x, r1, NULL, cycles);
      }
    } else if (-x >= y) {
      return _ArcTan((y << 14) / x, r1, NULL, cycles) + 0x8000;
    }
    return 0x4000 - _ArcTan((x << 14) / y, r1, NULL, cycles);
  } else {
    if (x <= 0) {
      if (-x > -y) {
        return _ArcTan((y << 14) / x, r1, NULL, cycles) + 0x8000;
      }
    } else if (x >= -y) {
      return _ArcTan((y << 14) / x, r1, NULL, cycles) + 0x10000;
    }
    return 0xC000 - _ArcTan((x << 14) / y, r1, NULL, cycles);
  }
}

static int32_t _Sqrt(uint32_t x, uint32_t* cycles) {
  if (!x) {
    *cycles = 53;
    return 0;
  }
  int32_t currentCycles = 15;
  uint32_t lower;
  uint32_t upper = x;
  uint32_t bound = 1;
  while (bound < upper) {
    upper >>= 1;
    bound <<= 1;
    currentCycles += 6;
  }
  while (true) {
    currentCycles += 6;
    upper = x;
    uint32_t accum = 0;
    lower = bound;
    while (true) {
      currentCycles += 5;
      uint32_t oldLower = lower;
      if (lower <= upper >> 1) {
        lower <<= 1;
      }
      if (oldLower >= upper >> 1) {
        break;
      }
    }
    while (true) {
      currentCycles += 8;
      accum <<= 1;
      if (upper >= lower) {
        ++accum;
        upper -= lower;
      }
      if (lower == bound) {
        break;
      }
      lower >>= 1;
    }
    uint32_t oldBound = bound;
    bound += accum;
    bound >>= 1;
    if (bound >= oldBound) {
      bound = oldBound;
      break;
    }
  }
  *cycles = currentCycles;
  return bound;
}

void GBASwi16(struct ARMCore* cpu, int immediate) {
  struct GBA* gba = (struct GBA*) cpu->master;
  mLOG(GBA_BIOS, DEBUG, "SWI: %02X r0: %08X r1: %08X r2: %08X r3: %08X",
      immediate, cpu->gprs[0], cpu->gprs[1], cpu->gprs[2], cpu->gprs[3]);

  switch (immediate) {
  case 0xF0: // Used for internal stall counting
    cpu->gprs[11] = gba->biosStall;
    return;
  case 0xFA:
    GBAPrintFlush(gba);
    return;
  }

  if (gba->memory.fullBios) {
    ARMRaiseSWI(cpu);
    return;
  }

  bool useStall = false;
  switch (immediate) {
  case GBA_SWI_SOFT_RESET:
    ARMRaiseSWI(cpu);
    break;
  case GBA_SWI_REGISTER_RAM_RESET:
    _RegisterRamReset(gba);
    break;
  case GBA_SWI_HALT:
    ARMRaiseSWI(cpu);
    return;
  case GBA_SWI_STOP:
    GBAStop(gba);
    break;
  case GBA_SWI_VBLANK_INTR_WAIT:
  // VBlankIntrWait
  // Fall through:
  case GBA_SWI_INTR_WAIT:
    // IntrWait
    ARMRaiseSWI(cpu);
    return;
  case GBA_SWI_DIV:
    useStall = true;
    _Div(gba, cpu->gprs[0], cpu->gprs[1]);
    break;
  case GBA_SWI_DIV_ARM:
    useStall = true;
    _Div(gba, cpu->gprs[1], cpu->gprs[0]);
    break;
  case GBA_SWI_SQRT:
    useStall = true;
    cpu->gprs[0] = _Sqrt(cpu->gprs[0], &gba->biosStall);
    break;
  case GBA_SWI_ARCTAN:
    useStall = true;
    cpu->gprs[0] = _ArcTan(cpu->gprs[0], &cpu->gprs[1], &cpu->gprs[3], &gba->biosStall);
    break;
  case GBA_SWI_ARCTAN2:
    useStall = true;
    cpu->gprs[0] = (uint16_t) _ArcTan2(cpu->gprs[0], cpu->gprs[1], &cpu->gprs[1], &gba->biosStall);
    cpu->gprs[3] = 0x170;
    break;
  case GBA_SWI_CPU_SET:
  case GBA_SWI_CPU_FAST_SET:
    if (cpu->gprs[0] >> BASE_OFFSET < GBA_REGION_EWRAM) {
      mLOG(GBA_BIOS, GAME_ERROR, "Cannot CpuSet from BIOS");
      break;
    }
    if (cpu->gprs[0] & (cpu->gprs[2] & (1 << 26) ? 3 : 1)) {
      mLOG(GBA_BIOS, GAME_ERROR, "Misaligned CpuSet source");
    }
    if (cpu->gprs[1] & (cpu->gprs[2] & (1 << 26) ? 3 : 1)) {
      mLOG(GBA_BIOS, GAME_ERROR, "Misaligned CpuSet destination");
    }
    ARMRaiseSWI(cpu);
    return;
  case GBA_SWI_GET_BIOS_CHECKSUM:
    cpu->gprs[0] = GBA_BIOS_CHECKSUM;
    cpu->gprs[1] = 1;
    cpu->gprs[3] = GBA_SIZE_BIOS;
    break;
  case GBA_SWI_BG_AFFINE_SET:
    _BgAffineSet(gba);
    break;
  case GBA_SWI_OBJ_AFFINE_SET:
    _ObjAffineSet(gba);
    break;
  case GBA_SWI_BIT_UNPACK:
    if (cpu->gprs[0] < GBA_BASE_EWRAM) {
      mLOG(GBA_BIOS, GAME_ERROR, "Bad BitUnPack source");
      break;
    }
    switch (cpu->gprs[1] >> BASE_OFFSET) {
    default:
      mLOG(GBA_BIOS, GAME_ERROR, "Bad BitUnPack destination");
    // Fall through
    case GBA_REGION_EWRAM:
    case GBA_REGION_IWRAM:
    case GBA_REGION_VRAM:
      _unBitPack(gba);
      break;
    }
    break;
  case GBA_SWI_LZ77_UNCOMP_WRAM:
  case GBA_SWI_LZ77_UNCOMP_VRAM:
    if (!(cpu->gprs[0] & 0x0E000000)) {
      mLOG(GBA_BIOS, GAME_ERROR, "Bad LZ77 source");
      break;
    }
    switch (cpu->gprs[1] >> BASE_OFFSET) {
    default:
      mLOG(GBA_BIOS, GAME_ERROR, "Bad LZ77 destination");
    // Fall through
    case GBA_REGION_EWRAM:
    case GBA_REGION_IWRAM:
    case GBA_REGION_VRAM:
      useStall = true;
      _unLz77(gba, immediate == GBA_SWI_LZ77_UNCOMP_WRAM ? 1 : 2);
      break;
    }
    break;
  case GBA_SWI_HUFFMAN_UNCOMP:
    if (!(cpu->gprs[0] & 0x0E000000)) {
      mLOG(GBA_BIOS, GAME_ERROR, "Bad Huffman source");
      break;
    }
    switch (cpu->gprs[1] >> BASE_OFFSET) {
    default:
      mLOG(GBA_BIOS, GAME_ERROR, "Bad Huffman destination");
    // Fall through
    case GBA_REGION_EWRAM:
    case GBA_REGION_IWRAM:
    case GBA_REGION_VRAM:
      _unHuffman(gba);
      break;
    }
    break;
  case GBA_SWI_RL_UNCOMP_WRAM:
  case GBA_SWI_RL_UNCOMP_VRAM:
    if (!(cpu->gprs[0] & 0x0E000000)) {
      mLOG(GBA_BIOS, GAME_ERROR, "Bad RL source");
      break;
    }
    switch (cpu->gprs[1] >> BASE_OFFSET) {
    default:
      mLOG(GBA_BIOS, GAME_ERROR, "Bad RL destination");
    // Fall through
    case GBA_REGION_EWRAM:
    case GBA_REGION_IWRAM:
    case GBA_REGION_VRAM:
      _unRl(gba, immediate == GBA_SWI_RL_UNCOMP_WRAM ? 1 : 2);
      break;
    }
    break;
  case GBA_SWI_DIFF_8BIT_UNFILTER_WRAM:
  case GBA_SWI_DIFF_8BIT_UNFILTER_VRAM:
  case GBA_SWI_DIFF_16BIT_UNFILTER:
    if (!(cpu->gprs[0] & 0x0E000000)) {
      mLOG(GBA_BIOS, GAME_ERROR, "Bad UnFilter source");
      break;
    }
    switch (cpu->gprs[1] >> BASE_OFFSET) {
    default:
      mLOG(GBA_BIOS, GAME_ERROR, "Bad UnFilter destination");
    // Fall through
    case GBA_REGION_EWRAM:
    case GBA_REGION_IWRAM:
    case GBA_REGION_VRAM:
      _unFilter(gba, immediate == GBA_SWI_DIFF_16BIT_UNFILTER ? 2 : 1, immediate == GBA_SWI_DIFF_8BIT_UNFILTER_WRAM ? 1 : 2);
      break;
    }
    break;
  case GBA_SWI_SOUND_BIAS:
    // SoundBias is mostly meaningless here
    mLOG(GBA_BIOS, STUB, "Stub software interrupt: SoundBias (19)");
    break;
  case GBA_SWI_MIDI_KEY_2_FREQ:
    _MidiKey2Freq(gba);
    break;
  case GBA_SWI_SOUND_DRIVER_GET_JUMP_LIST:
    ARMRaiseSWI(cpu);
    return;
  default:
    mLOG(GBA_BIOS, STUB, "Stub software interrupt: %02X", immediate);
  }
  if (useStall) {
    if (gba->biosStall >= 18) {
      gba->biosStall -= 18;
      gba->cpu->cycles += gba->biosStall & 3;
      gba->biosStall &= ~3;
      ARMRaiseSWI(cpu);
    } else {
      gba->cpu->cycles += gba->biosStall;
      useStall = false;
    }
  }
  if (!useStall) {
    gba->cpu->cycles += 45 + cpu->memory.activeNonseqCycles16 /* 8 bit load for SWI # */;
    // Return cycles
    if (gba->cpu->executionMode == MODE_ARM) {
      gba->cpu->cycles += cpu->memory.activeNonseqCycles32 + cpu->memory.activeSeqCycles32;
    } else {
      gba->cpu->cycles += cpu->memory.activeNonseqCycles16 + cpu->memory.activeSeqCycles16;
    }
  }
  gba->memory.biosPrefetch = 0xE3A02004;
}

void GBASwi32(struct ARMCore* cpu, int immediate) {
  GBASwi16(cpu, immediate >> 16);
}

uint32_t GBAChecksum(uint32_t* memory, size_t size) {
  size_t i;
  uint32_t sum = 0;
  for (i = 0; i < size; i += 4) {
    sum += memory[i >> 2];
  }
  return sum;
}

static void _unLz77(struct GBA* gba, int width) {
  struct ARMCore* cpu = gba->cpu;
  uint32_t source = cpu->gprs[0];
  uint32_t dest = cpu->gprs[1];
  int cycles = 20;
  enum mMemoryAccessSource oldAccess = cpu->memory.accessSource;
  cpu->memory.accessSource = mACCESS_DECOMPRESS;
  int remaining = (cpu->memory.load32(cpu, source, &cycles) & 0xFFFFFF00) >> 8;
  // We assume the signature byte (0x10) is correct
  int blockheader = 0; // Some compilers warn if this isn't set, even though it's trivially provably always set
  source += 4;
  int blocksRemaining = 0;
  uint32_t disp;
  int bytes;
  int byte;
  int halfword = 0;
  while (remaining > 0) {
    cycles += 14;
    if (blocksRemaining) {
      cycles += 18;
      if (blockheader & 0x80) {
        // Compressed
        int block = cpu->memory.load8(cpu, source + 1, &cycles) | (cpu->memory.load8(cpu, source, &cycles) << 8);
        source += 2;
        disp = dest - (block & 0x0FFF) - 1;
        bytes = (block >> 12) + 3;
        while (bytes--) {
          cycles += 10;
          if (remaining) {
            --remaining;
          } else {
            mLOG(GBA_BIOS, GAME_ERROR, "Improperly compressed LZ77 data at %08X. "
                 "This will lead to a buffer overrun at %08X and may crash on hardware.",
                 cpu->gprs[0], cpu->gprs[1]);
            if (gba->vbaBugCompat) {
              break;
            }
          }
          if (width == 2) {
            byte = (int16_t) cpu->memory.load16(cpu, disp & ~1, &cycles);
            if (dest & 1) {
              byte >>= (disp & 1) * 8;
              halfword |= byte << 8;
              cpu->memory.store16(cpu, dest ^ 1, halfword, &cycles);
            } else {
              byte >>= (disp & 1) * 8;
              halfword = byte & 0xFF;
            }
            cycles += 4;
          } else {
            byte = cpu->memory.load8(cpu, disp, &cycles);
            cpu->memory.store8(cpu, dest, byte, &cycles);
          }
          ++disp;
          ++dest;
        }
      } else {
        // Uncompressed
        byte = cpu->memory.load8(cpu, source, &cycles);
        ++source;
        if (width == 2) {
          if (dest & 1) {
            halfword |= byte << 8;
            cpu->memory.store16(cpu, dest ^ 1, halfword, &cycles);
          } else {
            halfword = byte;
          }
        } else {
          cpu->memory.store8(cpu, dest, byte, &cycles);
        }
        ++dest;
        --remaining;
      }
      blockheader <<= 1;
      --blocksRemaining;
    } else {
      blockheader = cpu->memory.load8(cpu, source, &cycles);
      ++source;
      blocksRemaining = 8;
    }
  }
  cpu->memory.accessSource = oldAccess;
  cpu->gprs[0] = source;
  cpu->gprs[1] = dest;
  cpu->gprs[3] = 0;
  gba->biosStall = cycles;
}

DECL_BITFIELD(HuffmanNode, uint8_t);
DECL_BITS(HuffmanNode, Offset, 0, 6);
DECL_BIT(HuffmanNode, RTerm, 6);
DECL_BIT(HuffmanNode, LTerm, 7);

static void _unHuffman(struct GBA* gba) {
  struct ARMCore* cpu = gba->cpu;
  uint32_t source = cpu->gprs[0] & 0xFFFFFFFC;
  uint32_t dest = cpu->gprs[1];
  enum mMemoryAccessSource oldAccess = cpu->memory.accessSource;
  cpu->memory.accessSource = mACCESS_DECOMPRESS;
  uint32_t header = cpu->memory.load32(cpu, source, 0);
  int remaining = header >> 8;
  unsigned bits = header & 0xF;
  if (bits == 0) {
    mLOG(GBA_BIOS, GAME_ERROR, "Invalid Huffman bits");
    bits = 8;
  }
  if (32 % bits || bits == 1) {
    mLOG(GBA_BIOS, STUB, "Unimplemented unaligned Huffman");
    cpu->memory.accessSource = oldAccess;
    return;
  }
  // We assume the signature byte (0x20) is correct
  int treesize = (cpu->memory.load8(cpu, source + 4, 0) << 1) + 1;
  int block = 0;
  uint32_t treeBase = source + 5;
  source += 5 + treesize;
  uint32_t nPointer = treeBase;
  HuffmanNode node;
  int bitsRemaining;
  int readBits;
  int bitsSeen = 0;
  node = cpu->memory.load8(cpu, nPointer, 0);
  while (remaining > 0) {
    uint32_t bitstream = cpu->memory.load32(cpu, source, 0);
    source += 4;
    for (bitsRemaining = 32; bitsRemaining > 0 && remaining > 0; --bitsRemaining, bitstream <<= 1) {
      uint32_t next = (nPointer & ~1) + HuffmanNodeGetOffset(node) * 2 + 2;
      if (bitstream & 0x80000000) {
        // Go right
        if (HuffmanNodeIsRTerm(node)) {
          readBits = cpu->memory.load8(cpu, next + 1, 0);
        } else {
          nPointer = next + 1;
          node = cpu->memory.load8(cpu, nPointer, 0);
          continue;
        }
      } else {
        // Go left
        if (HuffmanNodeIsLTerm(node)) {
          readBits = cpu->memory.load8(cpu, next, 0);
        } else {
          nPointer = next;
          node = cpu->memory.load8(cpu, nPointer, 0);
          continue;
        }
      }

      block |= (readBits & ((1 << bits) - 1)) << bitsSeen;
      bitsSeen += bits;
      nPointer = treeBase;
      node = cpu->memory.load8(cpu, nPointer, 0);
      if (bitsSeen == 32) {
        bitsSeen = 0;
        cpu->memory.store32(cpu, dest, block, 0);
        dest += 4;
        remaining -= 4;
        block = 0;
      }
    }
  }
  cpu->memory.accessSource = oldAccess;
  cpu->gprs[0] = source;
  cpu->gprs[1] = dest;
}

static void _unRl(struct GBA* gba, int width) {
  struct ARMCore* cpu = gba->cpu;
  uint32_t source = cpu->gprs[0];
  enum mMemoryAccessSource oldAccess = cpu->memory.accessSource;
  cpu->memory.accessSource = mACCESS_DECOMPRESS;
  int remaining = (cpu->memory.load32(cpu, source & 0xFFFFFFFC, 0) & 0xFFFFFF00) >> 8;
  int padding = (4 - remaining) & 0x3;
  // We assume the signature byte (0x30) is correct
  int blockheader;
  int block;
  source += 4;
  uint32_t dest = cpu->gprs[1];
  int halfword = 0;
  while (remaining > 0) {
    blockheader = cpu->memory.load8(cpu, source, 0);
    ++source;
    if (blockheader & 0x80) {
      // Compressed
      blockheader &= 0x7F;
      blockheader += 3;
      block = cpu->memory.load8(cpu, source, 0);
      ++source;
      while (blockheader-- && remaining) {
        --remaining;
        if (width == 2) {
          if (dest & 1) {
            halfword |= block << 8;
            cpu->memory.store16(cpu, dest ^ 1, halfword, 0);
          } else {
            halfword = block;
          }
        } else {
          cpu->memory.store8(cpu, dest, block, 0);
        }
        ++dest;
      }
    } else {
      // Uncompressed
      blockheader++;
      while (blockheader-- && remaining) {
        --remaining;
        int byte = cpu->memory.load8(cpu, source, 0);
        ++source;
        if (width == 2) {
          if (dest & 1) {
            halfword |= byte << 8;
            cpu->memory.store16(cpu, dest ^ 1, halfword, 0);
          } else {
            halfword = byte;
          }
        } else {
          cpu->memory.store8(cpu, dest, byte, 0);
        }
        ++dest;
      }
    }
  }
  if (width == 2) {
    if (dest & 1) {
      --padding;
      ++dest;
    }
    for (; padding > 0; padding -= 2, dest += 2) {
      cpu->memory.store16(cpu, dest, 0, 0);
    }
  } else {
    while (padding--) {
      cpu->memory.store8(cpu, dest, 0, 0);
      ++dest;
    }
  }
  cpu->memory.accessSource = oldAccess;
  cpu->gprs[0] = source;
  cpu->gprs[1] = dest;
}

static void _unFilter(struct GBA* gba, int inwidth, int outwidth) {
  struct ARMCore* cpu = gba->cpu;
  uint32_t source = cpu->gprs[0] & 0xFFFFFFFC;
  uint32_t dest = cpu->gprs[1];
  enum mMemoryAccessSource oldAccess = cpu->memory.accessSource;
  cpu->memory.accessSource = mACCESS_DECOMPRESS;
  uint32_t header = cpu->memory.load32(cpu, source, 0);
  int remaining = header >> 8;
  // We assume the signature nybble (0x8) is correct
  uint16_t halfword = 0;
  uint16_t old = 0;
  source += 4;
  while (remaining > 0) {
    uint16_t new;
    if (inwidth == 1) {
      new = cpu->memory.load8(cpu, source, 0);
    } else {
      new = cpu->memory.load16(cpu, source, 0);
    }
    new += old;
    if (outwidth > inwidth) {
      halfword >>= 8;
      halfword |= (new << 8);
      if (source & 1) {
        cpu->memory.store16(cpu, dest, halfword, 0);
        dest += outwidth;
        remaining -= outwidth;
      }
    } else if (outwidth == 1) {
      cpu->memory.store8(cpu, dest, new, 0);
      dest += outwidth;
      remaining -= outwidth;
    } else {
      cpu->memory.store16(cpu, dest, new, 0);
      dest += outwidth;
      remaining -= outwidth;
    }
    old = new;
    source += inwidth;
  }
  cpu->memory.accessSource = oldAccess;
  cpu->gprs[0] = source;
  cpu->gprs[1] = dest;
}

static void _unBitPack(struct GBA* gba) {
  struct ARMCore* cpu = gba->cpu;
  uint32_t source = cpu->gprs[0];
  uint32_t dest = cpu->gprs[1];
  uint32_t info = cpu->gprs[2];
  enum mMemoryAccessSource oldAccess = cpu->memory.accessSource;
  cpu->memory.accessSource = mACCESS_DECOMPRESS;
  unsigned sourceLen = cpu->memory.load16(cpu, info, 0);
  unsigned sourceWidth = cpu->memory.load8(cpu, info + 2, 0);
  unsigned destWidth = cpu->memory.load8(cpu, info + 3, 0);
  switch (sourceWidth) {
  case 1:
  case 2:
  case 4:
  case 8:
    break;
  default:
    mLOG(GBA_BIOS, GAME_ERROR, "Bad BitUnPack source width: %u", sourceWidth);
    cpu->memory.accessSource = oldAccess;
    return;
  }
  switch (destWidth) {
  case 1:
  case 2:
  case 4:
  case 8:
  case 16:
  case 32:
    break;
  default:
    mLOG(GBA_BIOS, GAME_ERROR, "Bad BitUnPack destination width: %u", destWidth);
    cpu->memory.accessSource = oldAccess;
    return;
  }
  uint32_t bias = cpu->memory.load32(cpu, info + 4, 0);
  uint8_t in = 0;
  uint32_t out = 0;
  int bitsRemaining = 0;
  int bitsEaten = 0;
  while (sourceLen > 0 || bitsRemaining) {
    if (!bitsRemaining) {
      in = cpu->memory.load8(cpu, source, 0);
      bitsRemaining = 8;
      ++source;
      --sourceLen;
    }
    unsigned scaled = in & ((1 << sourceWidth) - 1);
    in >>= sourceWidth;
    if (scaled || bias & 0x80000000) {
      scaled += bias & 0x7FFFFFFF;
    }
    bitsRemaining -= sourceWidth;
    out |= scaled << bitsEaten;
    bitsEaten += destWidth;
    if (bitsEaten == 32) {
      cpu->memory.store32(cpu, dest, out, 0);
      bitsEaten = 0;
      out = 0;
      dest += 4;
    }
  }
  cpu->memory.accessSource = oldAccess;
  cpu->gprs[0] = source;
  cpu->gprs[1] = dest;
}
// ---- END rewritten from reference implementation/bios.c ----
#if defined(__cplusplus)
}  // extern "C"
#endif
