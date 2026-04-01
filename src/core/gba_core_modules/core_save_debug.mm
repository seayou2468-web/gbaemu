// iOS-focused translation-unit optimization hints (no behavior change).
#if defined(__APPLE__) && defined(__clang__)
#pragma clang optimize on
#endif
// Rebuilt Objective-C++ module from reference implementation sources.
// NOTE: Source bodies are embedded and adapted here (no direct include of reference files).
#if defined(__cplusplus)
extern "C" {
#endif

// ---- BEGIN rewritten from reference implementation/dma.c ----
mLOG_DEFINE_CATEGORY(GBA_DMA, "GBA DMA", "gba.dma");

static void _dmaEvent(struct mTiming* timing, void* context, uint32_t cyclesLate);

static void GBADMAService(struct GBA* gba, int number, struct GBADMA* info);

static const int DMA_OFFSET[] = { 1, -1, 0, 1 };

static const uint32_t DMA_SRC_MASK[] = {
  0x07FFFFFE,
  0x0FFFFFFE,
  0x0FFFFFFE,
  0x0FFFFFFE,
};

static const uint32_t DMA_DST_MASK[] = {
  0x07FFFFFE,
  0x07FFFFFE,
  0x07FFFFFE,
  0x0FFFFFFE,
};

void GBADMAInit(struct GBA* gba) {
  gba->memory.dmaEvent.name = "GBA DMA";
  gba->memory.dmaEvent.callback = _dmaEvent;
  gba->memory.dmaEvent.context = gba;
  gba->memory.dmaEvent.priority = 0x40;
}

void GBADMAReset(struct GBA* gba) {
  memset(gba->memory.dma, 0, sizeof(gba->memory.dma));
  int i;
  for (i = 0; i < 4; ++i) {
    gba->memory.dma[i].count = 0x4000;
    gba->memory.dma[i].latch = 0;
  }
  gba->memory.dma[3].count = 0x10000;
  gba->memory.activeDMA = -1;
}
static bool _isValidDMASAD(int dma, uint32_t address) {
  if (dma == 0 && address >= GBA_BASE_ROM0 && address < GBA_BASE_SRAM) {
    return false;
  }
  return address >= GBA_BASE_EWRAM;
}

static bool _isValidDMADAD(int dma, uint32_t address) {
  return dma == 3 || address < GBA_BASE_ROM0;
}

uint32_t GBADMAWriteSAD(struct GBA* gba, int dma, uint32_t address) {
  struct GBAMemory* memory = &gba->memory;
  if (!_isValidDMASAD(dma, address)) {
    mLOG(GBA_DMA, GAME_ERROR, "Invalid DMA source address: 0x%08X", address);
  }
  memory->dma[dma].source = address & DMA_SRC_MASK[dma];
  return memory->dma[dma].source;
}

uint32_t GBADMAWriteDAD(struct GBA* gba, int dma, uint32_t address) {
  struct GBAMemory* memory = &gba->memory;
  if (!_isValidDMADAD(dma, address)) {
    mLOG(GBA_DMA, GAME_ERROR, "Invalid DMA destination address: 0x%08X", address);
  }
  memory->dma[dma].dest = address & DMA_DST_MASK[dma];
  return memory->dma[dma].dest;
}

void GBADMAWriteCNT_LO(struct GBA* gba, int dma, uint16_t count) {
  struct GBAMemory* memory = &gba->memory;
  memory->dma[dma].count = count ? count : (dma == 3 ? 0x10000 : 0x4000);
}

uint16_t GBADMAWriteCNT_HI(struct GBA* gba, int dma, uint16_t control) {
  struct GBAMemory* memory = &gba->memory;
  struct GBADMA* currentDma = &memory->dma[dma];
  int wasEnabled = GBADMARegisterIsEnable(currentDma->reg);
  if (dma < 3) {
    control &= 0xF7E0;
  } else {
    control &= 0xFFE0;
  }
  currentDma->reg = control;

  uint32_t width = 2 << GBADMARegisterGetWidth(currentDma->reg);
  if (currentDma->source >= GBA_BASE_ROM0 && currentDma->source < GBA_BASE_SRAM) {
    currentDma->sourceOffset = width;
  } else {
    currentDma->sourceOffset = DMA_OFFSET[GBADMARegisterGetSrcControl(currentDma->reg)] * width;
  }
  currentDma->destOffset = DMA_OFFSET[GBADMARegisterGetDestControl(currentDma->reg)] * width;

  if (GBADMARegisterIsDRQ(currentDma->reg)) {
    mLOG(GBA_DMA, STUB, "DRQ not implemented");
  }

  if (!wasEnabled && GBADMARegisterIsEnable(currentDma->reg)) {
    currentDma->nextSource = currentDma->source;
    currentDma->nextDest = currentDma->dest;

    if (currentDma->nextSource & (width - 1)) {
      mLOG(GBA_DMA, GAME_ERROR, "Misaligned DMA source address: 0x%08X", currentDma->nextSource);
    }
    if (currentDma->nextDest & (width - 1)) {
      mLOG(GBA_DMA, GAME_ERROR, "Misaligned DMA destination address: 0x%08X", currentDma->nextDest);
    }
    mLOG(GBA_DMA, INFO, "Starting DMA %i 0x%08X -> 0x%08X (%04X:%04X)", dma,
         currentDma->nextSource, currentDma->nextDest,
         currentDma->reg, currentDma->count & 0xFFFF);

    currentDma->nextSource &= -width;
    currentDma->nextDest &= -width;

    GBADMASchedule(gba, dma, currentDma);
  }
  // If the DMA has already occurred, this value might have changed since the function started
  return currentDma->reg;
};

void GBADMASchedule(struct GBA* gba, int number, struct GBADMA* info) {
  switch (GBADMARegisterGetTiming(info->reg)) {
  case GBA_DMA_TIMING_NOW:
    info->when = mTimingCurrentTime(&gba->timing) + 3; // DMAs take 3 cycles to start
    info->nextCount = info->count;
    break;
  case GBA_DMA_TIMING_HBLANK:
  case GBA_DMA_TIMING_VBLANK:
    // Handled implicitly
    return;
  case GBA_DMA_TIMING_CUSTOM:
    switch (number) {
    case 0:
      mLOG(GBA_DMA, WARN, "Discarding invalid DMA0 scheduling");
      return;
    case 1:
    case 2:
      GBAAudioScheduleFifoDma(&gba->audio, number, info);
      break;
    case 3:
      // Handled implicitly
      break;
    }
  }
  GBADMAUpdate(gba);
}

void GBADMARunHblank(struct GBA* gba, int32_t cycles) {
  struct GBAMemory* memory = &gba->memory;
  struct GBADMA* dma;
  bool found = false;
  int i;
  for (i = 0; i < 4; ++i) {
    dma = &memory->dma[i];
    if (GBADMARegisterIsEnable(dma->reg) && GBADMARegisterGetTiming(dma->reg) == GBA_DMA_TIMING_HBLANK && !dma->nextCount) {
      dma->when = mTimingCurrentTime(&gba->timing) + 3 + cycles;
      dma->nextCount = dma->count;
      found = true;
    }
  }
  if (found) {
    GBADMAUpdate(gba);
  }
}

void GBADMARunVblank(struct GBA* gba, int32_t cycles) {
  struct GBAMemory* memory = &gba->memory;
  struct GBADMA* dma;
  bool found = false;
  int i;
  for (i = 0; i < 4; ++i) {
    dma = &memory->dma[i];
    if (GBADMARegisterIsEnable(dma->reg) && GBADMARegisterGetTiming(dma->reg) == GBA_DMA_TIMING_VBLANK && !dma->nextCount) {
      dma->when = mTimingCurrentTime(&gba->timing) + 3 + cycles;
      dma->nextCount = dma->count;
      found = true;
    }
  }
  if (found) {
    GBADMAUpdate(gba);
  }
}

void GBADMARunDisplayStart(struct GBA* gba, int32_t cycles) {
  struct GBAMemory* memory = &gba->memory;
  struct GBADMA* dma = &memory->dma[3];
  if (GBADMARegisterIsEnable(dma->reg) && GBADMARegisterGetTiming(dma->reg) == GBA_DMA_TIMING_CUSTOM && !dma->nextCount) {
    dma->when = mTimingCurrentTime(&gba->timing) + 3 + cycles;
    dma->nextCount = dma->count;
    GBADMAUpdate(gba);
  }
}

void _dmaEvent(struct mTiming* timing, void* context, uint32_t cyclesLate) {
  UNUSED(timing);
  UNUSED(cyclesLate);
  struct GBA* gba = context;
  struct GBAMemory* memory = &gba->memory;
  struct GBADMA* dma = &memory->dma[memory->activeDMA];
  if (dma->nextCount == dma->count) {
    dma->when = mTimingCurrentTime(&gba->timing);
  }
  if (dma->nextCount & 0xFFFFF) {
    GBADMAService(gba, memory->activeDMA, dma);
  } else {
    dma->nextCount = 0;
    bool noRepeat = !GBADMARegisterIsRepeat(dma->reg);
    noRepeat |= GBADMARegisterGetTiming(dma->reg) == GBA_DMA_TIMING_NOW;
    noRepeat |= memory->activeDMA == 3 && GBADMARegisterGetTiming(dma->reg) == GBA_DMA_TIMING_CUSTOM && gba->video.vcount == GBA_VIDEO_VERTICAL_PIXELS + 1;
    if (noRepeat) {
      dma->reg = GBADMARegisterClearEnable(dma->reg);

      // Clear the enable bit in memory
      memory->io[(GBA_REG_DMA0CNT_HI + memory->activeDMA * (GBA_REG_DMA1CNT_HI - GBA_REG_DMA0CNT_HI)) >> 1] &= 0x7FE0;
    }
    if (GBADMARegisterGetDestControl(dma->reg) == GBA_DMA_INCREMENT_RELOAD) {
      dma->nextDest = dma->dest;
    }
    if (GBADMARegisterIsDoIRQ(dma->reg)) {
      GBARaiseIRQ(gba, GBA_IRQ_DMA0 + memory->activeDMA, cyclesLate);
    }
    GBADMAUpdate(gba);
  }
}

void GBADMAUpdate(struct GBA* gba) {
  int i;
  struct GBAMemory* memory = &gba->memory;
  uint32_t currentTime = mTimingCurrentTime(&gba->timing);
  int32_t leastTime = INT_MAX;
  memory->activeDMA = -1;
  for (i = 0; i < 4; ++i) {
    struct GBADMA* dma = &memory->dma[i];
    if (GBADMARegisterIsEnable(dma->reg) && dma->nextCount) {
      int32_t time = dma->when - currentTime;
      if (memory->activeDMA == -1 || time < leastTime) {
        leastTime = time;
        memory->activeDMA = i;
      }
    }
  }

  if (memory->activeDMA >= 0) {
    gba->dmaPC = gba->cpu->gprs[ARM_PC];
    mTimingDeschedule(&gba->timing, &memory->dmaEvent);
    mTimingSchedule(&gba->timing, &memory->dmaEvent, memory->dma[memory->activeDMA].when - currentTime);
  } else {
    gba->cpuBlocked = false;
  }
}

void GBADMAService(struct GBA* gba, int number, struct GBADMA* info) {
  struct GBAMemory* memory = &gba->memory;
  struct ARMCore* cpu = gba->cpu;
  uint32_t width = 2 << GBADMARegisterGetWidth(info->reg);
  uint32_t source = info->nextSource;
  uint32_t dest = info->nextDest;
  uint32_t sourceRegion = source >> BASE_OFFSET;
  uint32_t destRegion = dest >> BASE_OFFSET;
  enum mMemoryAccessSource oldAccess = cpu->memory.accessSource;
  int32_t cycles = 2;

  gba->cpuBlocked = true;
  gba->performingDMA = 1 | (number << 1);
  cpu->memory.accessSource = mACCESS_DMA;

  if (info->count == info->nextCount) {
    if (width == 4) {
      cycles += memory->waitstatesNonseq32[sourceRegion] + memory->waitstatesNonseq32[destRegion];
      info->cycles = memory->waitstatesSeq32[sourceRegion] + memory->waitstatesSeq32[destRegion];
    } else {
      if (source >= GBA_BASE_EWRAM) {
        info->latch = cpu->memory.load32(cpu, source, 0);
      }
      cycles += memory->waitstatesNonseq16[sourceRegion] + memory->waitstatesNonseq16[destRegion];
      info->cycles = memory->waitstatesSeq16[sourceRegion] + memory->waitstatesSeq16[destRegion];
    }
  } else {
    cycles += info->cycles;
  }
  info->when += cycles;

  if (width == 4) {
    if (source >= GBA_BASE_EWRAM) {
      info->latch = cpu->memory.load32(cpu, source, 0);
    }
    cpu->memory.store32(cpu, dest, info->latch, 0);
    gba->bus = info->latch;
  } else {
    if (sourceRegion == GBA_REGION_ROM2_EX && (memory->savedata.type == GBA_SAVEDATA_EEPROM || memory->savedata.type == GBA_SAVEDATA_EEPROM512)) {
      info->latch = GBASavedataReadEEPROM(&memory->savedata);
      info->latch |= info->latch << 16;
    } else if (source >= GBA_BASE_EWRAM) {
      info->latch = cpu->memory.load16(cpu, source, 0);
      info->latch |= info->latch << 16;
    }
    if (UNLIKELY(destRegion == GBA_REGION_ROM2_EX)) {
      if (memory->savedata.type == GBA_SAVEDATA_AUTODETECT) {
        mLOG(GBA_MEM, INFO, "Detected EEPROM savegame");
        GBASavedataInitEEPROM(&memory->savedata);
      }
      if (memory->savedata.type == GBA_SAVEDATA_EEPROM512 || memory->savedata.type == GBA_SAVEDATA_EEPROM) {
        GBASavedataWriteEEPROM(&memory->savedata, info->latch, info->nextCount);
      }
    } else {
      cpu->memory.store16(cpu, dest, info->latch >> (8 * (dest & 2)), 0);
    }
    gba->bus = (info->latch & 0xFFFF) | (info->latch << 16);
  }

  info->nextSource += info->sourceOffset;
  info->nextDest += info->destOffset;
  if (UNLIKELY(sourceRegion != info->nextSource >> BASE_OFFSET) || UNLIKELY(destRegion != info->nextDest >> BASE_OFFSET)) {
    // Crossed region boundary
    if (info->nextSource >= GBA_BASE_ROM0 && info->nextSource < GBA_BASE_SRAM) {
      info->sourceOffset = width;
    } else {
      info->sourceOffset = DMA_OFFSET[GBADMARegisterGetSrcControl(info->reg)] * width;
    }

    // Recalculate cached cycles
    if (width == 4) {
      info->cycles = memory->waitstatesSeq32[info->nextSource >> BASE_OFFSET] + memory->waitstatesSeq32[info->nextDest >> BASE_OFFSET];
    } else {
      info->cycles = memory->waitstatesSeq16[info->nextSource >> BASE_OFFSET] + memory->waitstatesSeq16[info->nextDest >> BASE_OFFSET];
    }
  }
  --info->nextCount;

  gba->performingDMA = 0;
  cpu->memory.accessSource = oldAccess;

  int i;
  for (i = 0; i < 4; ++i) {
    struct GBADMA* dma = &memory->dma[i];
    if (GBADMARegisterIsEnable(dma->reg) && dma->nextCount) {
      int32_t time = dma->when - info->when;
      if (time < 0) {
        dma->when = info->when;
      }
    }
  }

  if (!info->nextCount) {
    info->nextCount |= 0x80000000;
    if (sourceRegion < GBA_REGION_ROM0 || destRegion < GBA_REGION_ROM0) {
      info->when += 2;
    }
  }
  GBADMAUpdate(gba);
}

void GBADMARecalculateCycles(struct GBA* gba) {
  int i;
  for (i = 0; i < 4; ++i) {
    struct GBADMA* dma = &gba->memory.dma[i];
    if (!GBADMARegisterIsEnable(dma->reg)) {
      continue;
    }

    uint32_t width = GBADMARegisterGetWidth(dma->reg);
    uint32_t sourceRegion = dma->nextSource >> BASE_OFFSET;
    uint32_t destRegion = dma->nextDest >> BASE_OFFSET;
    if (width) {
      dma->cycles = gba->memory.waitstatesSeq32[sourceRegion] + gba->memory.waitstatesSeq32[destRegion];
    } else {
      dma->cycles = gba->memory.waitstatesSeq16[sourceRegion] + gba->memory.waitstatesSeq16[destRegion];
    }
  }
}

void GBADMASerialize(const struct GBA* gba, struct GBASerializedState* state) {
  int i;
  for (i = 0; i < 4; ++i) {
    STORE_32(gba->memory.dma[i].nextSource, 0, &state->dma[i].nextSource);
    STORE_32(gba->memory.dma[i].nextDest, 0, &state->dma[i].nextDest);
    STORE_32(gba->memory.dma[i].nextCount, 0, &state->dma[i].nextCount);
    STORE_32(gba->memory.dma[i].when, 0, &state->dma[i].when);
  }

  STORE_32(gba->memory.dma[0].latch, 0, &state->dmaTransferRegister);
  STORE_32(gba->memory.dma[1].latch, 0, &state->dmaLatch[0]);
  STORE_32(gba->memory.dma[2].latch, 0, &state->dmaLatch[1]);
  STORE_32(gba->memory.dma[3].latch, 0, &state->dmaLatch[2]);
  STORE_32(gba->dmaPC, 0, &state->dmaBlockPC);
}

void GBADMADeserialize(struct GBA* gba, const struct GBASerializedState* state) {
  int i;
  for (i = 0; i < 4; ++i) {
    LOAD_16(gba->memory.dma[i].reg, (GBA_REG_DMA0CNT_HI + i * 12), state->io);
    LOAD_32(gba->memory.dma[i].nextSource, 0, &state->dma[i].nextSource);
    LOAD_32(gba->memory.dma[i].nextDest, 0, &state->dma[i].nextDest);
    LOAD_32(gba->memory.dma[i].nextCount, 0, &state->dma[i].nextCount);
    LOAD_32(gba->memory.dma[i].when, 0, &state->dma[i].when);

    uint32_t width = 2 << GBADMARegisterGetWidth(gba->memory.dma[i].reg);
    if (gba->memory.dma[i].source >= GBA_BASE_ROM0 && gba->memory.dma[i].source < GBA_BASE_SRAM) {
      gba->memory.dma[i].sourceOffset = width;
    } else {
      gba->memory.dma[i].sourceOffset = DMA_OFFSET[GBADMARegisterGetSrcControl(gba->memory.dma[i].reg)] * width;
    }
    gba->memory.dma[i].destOffset = DMA_OFFSET[GBADMARegisterGetDestControl(gba->memory.dma[i].reg)] * width;
  }
  uint32_t version;
  LOAD_32(version, 0, &state->versionMagic);
  LOAD_32(gba->memory.dma[0].latch, 0, &state->dmaTransferRegister);
  if (version >= GBASavestateMagic + 0xA) {
    LOAD_32(gba->memory.dma[1].latch, 0, &state->dmaLatch[0]);
    LOAD_32(gba->memory.dma[2].latch, 0, &state->dmaLatch[1]);
    LOAD_32(gba->memory.dma[3].latch, 0, &state->dmaLatch[2]);
  } else {
    gba->memory.dma[1].latch = gba->memory.dma[0].latch;
    gba->memory.dma[2].latch = gba->memory.dma[0].latch;
    gba->memory.dma[3].latch = gba->memory.dma[0].latch;
  }
  LOAD_32(gba->dmaPC, 0, &state->dmaBlockPC);

  GBADMARecalculateCycles(gba);
  GBADMAUpdate(gba);
}
// ---- END rewritten from reference implementation/dma.c ----

// ---- BEGIN rewritten from reference implementation/dolphin.c ----
#define BITS_PER_SECOND 115200 // This is wrong, but we need to maintain compat for the time being
#define CYCLES_PER_BIT (GBA_ARM7TDMI_FREQUENCY / BITS_PER_SECOND)
#define CLOCK_GRAIN (CYCLES_PER_BIT * 8)
#define CLOCK_WAIT 500

const uint16_t DOLPHIN_CLOCK_PORT = 49420;
const uint16_t DOLPHIN_DATA_PORT = 54970;

enum {
  WAIT_FOR_FIRST_CLOCK = 0,
  WAIT_FOR_CLOCK,
  WAIT_FOR_COMMAND,
};

static bool GBASIODolphinInit(struct GBASIODriver* driver);
static void GBASIODolphinReset(struct GBASIODriver* driver);
static void GBASIODolphinSetMode(struct GBASIODriver* driver, enum GBASIOMode mode);
static bool GBASIODolphinHandlesMode(struct GBASIODriver* driver, enum GBASIOMode mode);
static int GBASIODolphinConnectedDevices(struct GBASIODriver* driver);
static void GBASIODolphinProcessEvents(struct mTiming* timing, void* context, uint32_t cyclesLate);

static int32_t _processCommand(struct GBASIODolphin* dol, uint32_t cyclesLate);
static void _flush(struct GBASIODolphin* dol);

void GBASIODolphinCreate(struct GBASIODolphin* dol) {
  memset(&dol->d, 0, sizeof(dol->d));
  dol->d.init = GBASIODolphinInit;
  dol->d.reset = GBASIODolphinReset;
  dol->d.setMode = GBASIODolphinSetMode;
  dol->d.handlesMode = GBASIODolphinHandlesMode;
  dol->d.connectedDevices = GBASIODolphinConnectedDevices;
  dol->event.context = dol;
  dol->event.name = "GB SIO Lockstep";
  dol->event.callback = GBASIODolphinProcessEvents;
  dol->event.priority = 0x80;

  dol->data = INVALID_SOCKET;
  dol->clock = INVALID_SOCKET;
  dol->active = false;
}

void GBASIODolphinDestroy(struct GBASIODolphin* dol) {
  if (!SOCKET_FAILED(dol->data)) {
    SocketClose(dol->data);
    dol->data = INVALID_SOCKET;
  }

  if (!SOCKET_FAILED(dol->clock)) {
    SocketClose(dol->clock);
    dol->clock = INVALID_SOCKET;
  }
}

bool GBASIODolphinConnect(struct GBASIODolphin* dol, const struct Address* address, short dataPort, short clockPort) {
  if (!SOCKET_FAILED(dol->data)) {
    SocketClose(dol->data);
    dol->data = INVALID_SOCKET;
  }
  if (!dataPort) {
    dataPort = DOLPHIN_DATA_PORT;
  }

  if (!SOCKET_FAILED(dol->clock)) {
    SocketClose(dol->clock);
    dol->clock = INVALID_SOCKET;
  }
  if (!clockPort) {
    clockPort = DOLPHIN_CLOCK_PORT;
  }

  dol->data = SocketConnectTCP(dataPort, address);
  if (SOCKET_FAILED(dol->data)) {
    return false;
  }

  dol->clock = SocketConnectTCP(clockPort, address);
  if (SOCKET_FAILED(dol->clock)) {
    SocketClose(dol->data);
    dol->data = INVALID_SOCKET;
    return false;
  }

  SocketSetBlocking(dol->data, false);
  SocketSetBlocking(dol->clock, false);
  SocketSetTCPPush(dol->data, true);
  return true;
}

static bool GBASIODolphinInit(struct GBASIODriver* driver) {
  struct GBASIODolphin* dol = (struct GBASIODolphin*) driver;
  dol->clockSlice = 0;
  dol->state = WAIT_FOR_FIRST_CLOCK;
  GBASIODolphinReset(driver);
  return true;
}

static void GBASIODolphinReset(struct GBASIODriver* driver) {
  struct GBASIODolphin* dol = (struct GBASIODolphin*) driver;
  dol->active = false;
  _flush(dol);
  mTimingDeschedule(&dol->d.p->p->timing, &dol->event);
  mTimingSchedule(&dol->d.p->p->timing, &dol->event, 0);
}

static void GBASIODolphinSetMode(struct GBASIODriver* driver, enum GBASIOMode mode) {
  struct GBASIODolphin* dol = (struct GBASIODolphin*) driver;
  dol->active = mode == GBA_SIO_JOYBUS;
}

static bool GBASIODolphinHandlesMode(struct GBASIODriver* driver, enum GBASIOMode mode) {
  UNUSED(driver);
  return mode == GBA_SIO_JOYBUS;
}

static int GBASIODolphinConnectedDevices(struct GBASIODriver* driver) {
  UNUSED(driver);
  return 1;
}

void GBASIODolphinProcessEvents(struct mTiming* timing, void* context, uint32_t cyclesLate) {
  struct GBASIODolphin* dol = context;
  if (SOCKET_FAILED(dol->data)) {
    return;
  }

  dol->clockSlice -= cyclesLate;

  int32_t clockSlice;

  int32_t nextEvent = CLOCK_GRAIN;
  switch (dol->state) {
  case WAIT_FOR_FIRST_CLOCK:
    dol->clockSlice = 0;
    // Fall through
  case WAIT_FOR_CLOCK:
    if (dol->clockSlice < 0) {
      Socket r = dol->clock;
      SocketPoll(1, &r, 0, 0, CLOCK_WAIT);
    }
    if (SocketRecv(dol->clock, &clockSlice, 4) == 4) {
      clockSlice = ntohl(clockSlice);
      dol->clockSlice += clockSlice;
      dol->state = WAIT_FOR_COMMAND;
      nextEvent = 0;
    }
    // Fall through
  case WAIT_FOR_COMMAND:
    if (dol->clockSlice < -VIDEO_TOTAL_LENGTH * 4) {
      Socket r = dol->data;
      SocketPoll(1, &r, 0, 0, CLOCK_WAIT);
    }
    if (_processCommand(dol, cyclesLate) >= 0) {
      dol->state = WAIT_FOR_CLOCK;
      nextEvent = CLOCK_GRAIN;
    }
    break;
  }

  dol->clockSlice -= nextEvent;
  mTimingSchedule(timing, &dol->event, nextEvent);
}

void _flush(struct GBASIODolphin* dol) {
  uint8_t buffer[32];
  while (SocketRecv(dol->clock, buffer, sizeof(buffer)) == sizeof(buffer));
  while (SocketRecv(dol->data, buffer, sizeof(buffer)) == sizeof(buffer));
}

int32_t _processCommand(struct GBASIODolphin* dol, uint32_t cyclesLate) {
  // This does not include the stop bits due to compatibility reasons
  int bitsOnLine = 8;
  uint8_t buffer[6];
  int gotten = SocketRecv(dol->data, buffer, 1);
  if (gotten < 1) {
    return -1;
  }

  switch (buffer[0]) {
  case JOY_RESET:
  case JOY_POLL:
    bitsOnLine += 24;
    break;
  case JOY_RECV:
    gotten = SocketRecv(dol->data, &buffer[1], 4);
    if (gotten < 4) {
      return -1;
    }
    mLOG(GBA_SIO, DEBUG, "DOL recv: %02X%02X%02X%02X", buffer[1], buffer[2], buffer[3], buffer[4]);
    // Fall through
  case JOY_TRANS:
    bitsOnLine += 40;
    break;
  }

  if (!dol->active) {
    return 0;
  }

  int sent = GBASIOJOYSendCommand(&dol->d, buffer[0], &buffer[1]);
  SocketSend(dol->data, &buffer[1], sent);

  return bitsOnLine * CYCLES_PER_BIT - cyclesLate;
}

bool GBASIODolphinIsConnected(struct GBASIODolphin* dol) {
  return dol->data != INVALID_SOCKET;
}
// ---- END rewritten from reference implementation/dolphin.c ----
#if defined(__cplusplus)
}  // extern "C"
#endif
