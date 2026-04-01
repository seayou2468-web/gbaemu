// iOS-focused translation-unit optimization hints (no behavior change).
#if defined(__APPLE__) && defined(__clang__)
#pragma clang optimize on
#endif

#include "./module_includes.h"

// Rebuilt Objective-C++ module from reference implementation sources.
// NOTE: Source bodies are embedded and adapted here (no direct include of reference files).
#if defined(__cplusplus)
extern "C" {
#endif

// ---- BEGIN rewritten from reference implementation/video.c ----
mLOG_DEFINE_CATEGORY(GBA_VIDEO, "GBA Video", "gba.video");

static void GBAVideoDummyRendererInit(struct GBAVideoRenderer* renderer);
static void GBAVideoDummyRendererReset(struct GBAVideoRenderer* renderer);
static void GBAVideoDummyRendererDeinit(struct GBAVideoRenderer* renderer);
static uint16_t GBAVideoDummyRendererWriteVideoRegister(struct GBAVideoRenderer* renderer, uint32_t address, uint16_t value);
static void GBAVideoDummyRendererWriteVRAM(struct GBAVideoRenderer* renderer, uint32_t address);
static void GBAVideoDummyRendererWritePalette(struct GBAVideoRenderer* renderer, uint32_t address, uint16_t value);
static void GBAVideoDummyRendererWriteOAM(struct GBAVideoRenderer* renderer, uint32_t oam);
static void GBAVideoDummyRendererDrawScanline(struct GBAVideoRenderer* renderer, int y);
static void GBAVideoDummyRendererFinishFrame(struct GBAVideoRenderer* renderer);
static void GBAVideoDummyRendererGetPixels(struct GBAVideoRenderer* renderer, size_t* stride, const void** pixels);
static void GBAVideoDummyRendererPutPixels(struct GBAVideoRenderer* renderer, size_t stride, const void* pixels);

static void _startHblank(struct mTiming*, void* context, uint32_t cyclesLate);
static void _startHdraw(struct mTiming*, void* context, uint32_t cyclesLate);
static unsigned _calculateStallMask(struct GBA* gba, unsigned dispcnt);

MGBA_EXPORT const int GBAVideoObjSizes[16][2] = {
  { 8, 8 },
  { 16, 16 },
  { 32, 32 },
  { 64, 64 },
  { 16, 8 },
  { 32, 8 },
  { 32, 16 },
  { 64, 32 },
  { 8, 16 },
  { 8, 32 },
  { 16, 32 },
  { 32, 64 },
  { 0, 0 },
  { 0, 0 },
  { 0, 0 },
  { 0, 0 },
};

void GBAVideoInit(struct GBAVideo* video) {
  video->renderer = NULL;
  video->vram = anonymousMemoryMap(GBA_SIZE_VRAM);
  video->frameskip = 0;
  video->event.name = "GBA Video";
  video->event.callback = NULL;
  video->event.context = video;
  video->event.priority = 8;
}

void GBAVideoReset(struct GBAVideo* video) {
  int32_t nextEvent = VIDEO_HDRAW_LENGTH;
  if (video->p->memory.fullBios) {
    video->vcount = 0;
  } else {
    // TODO: Verify exact scanline on hardware
    video->vcount = 0x7E;
    nextEvent = 120;
  }
  video->p->memory.io[GBA_REG(VCOUNT)] = video->vcount;

  video->event.callback = _startHblank;
  mTimingSchedule(&video->p->timing, &video->event, nextEvent);

  video->frameCounter = 0;
  video->frameskipCounter = 0;
  video->stallMask = 0;

  memset(video->palette, 0, sizeof(video->palette));
  memset(video->oam.raw, 0, sizeof(video->oam.raw));
  memset(video->vram, 0, GBA_SIZE_VRAM);

  if (!video->renderer) {
    mLOG(GBA_VIDEO, FATAL, "No renderer associated");
    return;
  }
  video->renderer->vram = video->vram;
  video->renderer->reset(video->renderer);
}

void GBAVideoDeinit(struct GBAVideo* video) {
  video->renderer->deinit(video->renderer);
  mappedMemoryFree(video->vram, GBA_SIZE_VRAM);
}

void GBAVideoDummyRendererCreate(struct GBAVideoRenderer* renderer) {
  static const struct GBAVideoRenderer dummyRenderer = {
    .init = GBAVideoDummyRendererInit,
    .reset = GBAVideoDummyRendererReset,
    .deinit = GBAVideoDummyRendererDeinit,
    .writeVideoRegister = GBAVideoDummyRendererWriteVideoRegister,
    .writeVRAM = GBAVideoDummyRendererWriteVRAM,
    .writePalette = GBAVideoDummyRendererWritePalette,
    .writeOAM = GBAVideoDummyRendererWriteOAM,
    .drawScanline = GBAVideoDummyRendererDrawScanline,
    .finishFrame = GBAVideoDummyRendererFinishFrame,
    .getPixels = GBAVideoDummyRendererGetPixels,
    .putPixels = GBAVideoDummyRendererPutPixels,
  };
  memcpy(renderer, &dummyRenderer, sizeof(*renderer));
}

void GBAVideoAssociateRenderer(struct GBAVideo* video, struct GBAVideoRenderer* renderer) {
  if (video->renderer) {
    video->renderer->deinit(video->renderer);
    renderer->cache = video->renderer->cache;
  } else {
    renderer->cache = NULL;
  }
  video->renderer = renderer;
  renderer->palette = video->palette;
  renderer->vram = video->vram;
  renderer->oam = &video->oam;
  video->renderer->init(video->renderer);
  video->renderer->reset(video->renderer);
  renderer->writeVideoRegister(renderer, GBA_REG_DISPCNT, video->p->memory.io[GBA_REG(DISPCNT)]);
  renderer->writeVideoRegister(renderer, GBA_REG_STEREOCNT, video->p->memory.io[GBA_REG(STEREOCNT)]);
  int address;
  for (address = GBA_REG_BG0CNT; address < 0x56; address += 2) {
    if (address == 0x4E) {
      continue;
    }
    renderer->writeVideoRegister(renderer, address, video->p->memory.io[address >> 1]);
  }
}

void _startHdraw(struct mTiming* timing, void* context, uint32_t cyclesLate) {
  struct GBAVideo* video = context;
  video->event.callback = _startHblank;
  mTimingSchedule(timing, &video->event, VIDEO_HDRAW_LENGTH - cyclesLate);

  ++video->vcount;
  if (video->vcount == VIDEO_VERTICAL_TOTAL_PIXELS) {
    video->vcount = 0;
  }
  video->p->memory.io[GBA_REG(VCOUNT)] = video->vcount;

  if (video->vcount < GBA_VIDEO_VERTICAL_PIXELS) {
    unsigned dispcnt = video->p->memory.io[GBA_REG(DISPCNT)];
    video->stallMask = _calculateStallMask(video->p, dispcnt);
  }

  GBARegisterDISPSTAT dispstat = video->p->memory.io[GBA_REG(DISPSTAT)];
  dispstat = GBARegisterDISPSTATClearInHblank(dispstat);
  if (video->vcount == GBARegisterDISPSTATGetVcountSetting(dispstat)) {
    dispstat = GBARegisterDISPSTATFillVcounter(dispstat);
    if (GBARegisterDISPSTATIsVcounterIRQ(dispstat)) {
      GBARaiseIRQ(video->p, GBA_IRQ_VCOUNTER, cyclesLate);
    }
  } else {
    dispstat = GBARegisterDISPSTATClearVcounter(dispstat);
  }
  video->p->memory.io[GBA_REG(DISPSTAT)] = dispstat;

  // Note: state may be recorded during callbacks, so ensure it is consistent!
  switch (video->vcount) {
  case 0:
    GBAFrameStarted(video->p);
    break;
  case GBA_VIDEO_VERTICAL_PIXELS:
    video->p->memory.io[GBA_REG(DISPSTAT)] = GBARegisterDISPSTATFillInVblank(dispstat);
    if (video->frameskipCounter <= 0) {
      video->renderer->finishFrame(video->renderer);
    }
    GBADMARunVblank(video->p, -cyclesLate);
    if (GBARegisterDISPSTATIsVblankIRQ(dispstat)) {
      GBARaiseIRQ(video->p, GBA_IRQ_VBLANK, cyclesLate);
    }
    GBAFrameEnded(video->p);
    mCoreSyncPostFrame(video->p->sync);
    --video->frameskipCounter;
    if (video->frameskipCounter < 0) {
      video->frameskipCounter = video->frameskip;
    }
    ++video->frameCounter;
    GBAInterrupt(video->p);
    break;
  case VIDEO_VERTICAL_TOTAL_PIXELS - 1:
    video->p->memory.io[GBA_REG(DISPSTAT)] = GBARegisterDISPSTATClearInVblank(dispstat);
    break;
  }
}

void _startHblank(struct mTiming* timing, void* context, uint32_t cyclesLate) {
  struct GBAVideo* video = context;
  video->event.callback = _startHdraw;
  mTimingSchedule(timing, &video->event, VIDEO_HBLANK_LENGTH - cyclesLate);

  // Begin Hblank
  GBARegisterDISPSTAT dispstat = video->p->memory.io[GBA_REG(DISPSTAT)];
  dispstat = GBARegisterDISPSTATFillInHblank(dispstat);
  if (video->vcount < GBA_VIDEO_VERTICAL_PIXELS && video->frameskipCounter <= 0) {
    video->renderer->drawScanline(video->renderer, video->vcount);
  }

  if (video->vcount < GBA_VIDEO_VERTICAL_PIXELS) {
    GBADMARunHblank(video->p, -cyclesLate);
  }
  if (video->vcount >= 2 && video->vcount < GBA_VIDEO_VERTICAL_PIXELS + 2) {
    GBADMARunDisplayStart(video->p, -cyclesLate);
  }
  if (GBARegisterDISPSTATIsHblankIRQ(dispstat)) {
    GBARaiseIRQ(video->p, GBA_IRQ_HBLANK, cyclesLate - 6); // TODO: Where does this fudge factor come from?
  }
  video->stallMask = 0;
  video->p->memory.io[GBA_REG(DISPSTAT)] = dispstat;
}

uint16_t GBAVideoWriteDISPSTAT(struct GBAVideo* video, uint16_t value) {
  GBARegisterDISPSTAT dispstat = video->p->memory.io[GBA_REG(DISPSTAT)] & 0x7;
  dispstat |= value & 0xFFF8;

  if (video->vcount == GBARegisterDISPSTATGetVcountSetting(dispstat)) {
    // Edge trigger only
    if (GBARegisterDISPSTATIsVcounterIRQ(dispstat) && !GBARegisterDISPSTATIsVcounter(dispstat)) {
      GBARaiseIRQ(video->p, GBA_IRQ_VCOUNTER, 0);
    }
    dispstat = GBARegisterDISPSTATFillVcounter(dispstat);
  } else {
    dispstat = GBARegisterDISPSTATClearVcounter(dispstat);
  }
  return dispstat;
}

static unsigned _calculateStallMask(struct GBA* gba, unsigned dispcnt) {
  unsigned mask = 0;

  if (GBARegisterDISPCNTIsForcedBlank(dispcnt)) {
    return 0;
  }

  switch (GBARegisterDISPCNTGetMode(dispcnt)) {
  case 0:
    if (GBARegisterDISPCNTIsBg0Enable(dispcnt)) {
      if (GBARegisterBGCNTIs256Color(gba->memory.io[GBA_REG(BG0CNT)])) {
        mask |= GBA_VSTALL_T8(0);
      } else {
        mask |= GBA_VSTALL_T4(0);
      }
    }
    if (GBARegisterDISPCNTIsBg1Enable(dispcnt)) {
      if (GBARegisterBGCNTIs256Color(gba->memory.io[GBA_REG(BG1CNT)])) {
        mask |= GBA_VSTALL_T8(1);
      } else {
        mask |= GBA_VSTALL_T4(1);
      }
    }
    if (GBARegisterDISPCNTIsBg2Enable(dispcnt)) {
      if (GBARegisterBGCNTIs256Color(gba->memory.io[GBA_REG(BG2CNT)])) {
        mask |= GBA_VSTALL_T8(2);
      } else {
        mask |= GBA_VSTALL_T4(2);
      }
    }
    if (GBARegisterDISPCNTIsBg3Enable(dispcnt)) {
      if (GBARegisterBGCNTIs256Color(gba->memory.io[GBA_REG(BG3CNT)])) {
        mask |= GBA_VSTALL_T8(3);
      } else {
        mask |= GBA_VSTALL_T4(3);
      }
    }
    break;
  case 1:
    if (GBARegisterDISPCNTIsBg0Enable(dispcnt)) {
      if (GBARegisterBGCNTIs256Color(gba->memory.io[GBA_REG(BG0CNT)])) {
        mask |= GBA_VSTALL_T8(0);
      } else {
        mask |= GBA_VSTALL_T4(0);
      }
    }
    if (GBARegisterDISPCNTIsBg1Enable(dispcnt)) {
      if (GBARegisterBGCNTIs256Color(gba->memory.io[GBA_REG(BG1CNT)])) {
        mask |= GBA_VSTALL_T8(1);
      } else {
        mask |= GBA_VSTALL_T4(1);
      }
    }
    if (GBARegisterDISPCNTIsBg2Enable(dispcnt)) {
      mask |= GBA_VSTALL_A2;
    }
    break;
  case 2:
    if (GBARegisterDISPCNTIsBg2Enable(dispcnt)) {
      mask |= GBA_VSTALL_A2;
    }
    if (GBARegisterDISPCNTIsBg3Enable(dispcnt)) {
      mask |= GBA_VSTALL_A3;
    }
    break;
  case 3:
  case 4:
  case 5:
    if (GBARegisterDISPCNTIsBg2Enable(dispcnt)) {
      mask |= GBA_VSTALL_B;
    }
    break;
  default:
    break;
  }
  return mask;
}

static void GBAVideoDummyRendererInit(struct GBAVideoRenderer* renderer) {
  UNUSED(renderer);
  // Nothing to do
}

static void GBAVideoDummyRendererReset(struct GBAVideoRenderer* renderer) {
  UNUSED(renderer);
  // Nothing to do
}

static void GBAVideoDummyRendererDeinit(struct GBAVideoRenderer* renderer) {
  UNUSED(renderer);
  // Nothing to do
}

static uint16_t GBAVideoDummyRendererWriteVideoRegister(struct GBAVideoRenderer* renderer, uint32_t address, uint16_t value) {
  if (renderer->cache) {
    GBAVideoCacheWriteVideoRegister(renderer->cache, address, value);
  }
  switch (address) {
  case GBA_REG_DISPCNT:
    value &= 0xFFF7;
    break;
  case GBA_REG_BG0CNT:
  case GBA_REG_BG1CNT:
    value &= 0xDFFF;
    break;
  case GBA_REG_BG2CNT:
  case GBA_REG_BG3CNT:
    value &= 0xFFFF;
    break;
  case GBA_REG_BG0HOFS:
  case GBA_REG_BG0VOFS:
  case GBA_REG_BG1HOFS:
  case GBA_REG_BG1VOFS:
  case GBA_REG_BG2HOFS:
  case GBA_REG_BG2VOFS:
  case GBA_REG_BG3HOFS:
  case GBA_REG_BG3VOFS:
    value &= 0x01FF;
    break;
  case GBA_REG_BLDCNT:
    value &= 0x3FFF;
    break;
  case GBA_REG_BLDALPHA:
    value &= 0x1F1F;
    break;
  case GBA_REG_WININ:
  case GBA_REG_WINOUT:
    value &= 0x3F3F;
    break;
  default:
    break;
  }
  return value;
}

static void GBAVideoDummyRendererWriteVRAM(struct GBAVideoRenderer* renderer, uint32_t address) {
  if (renderer->cache) {
    mCacheSetWriteVRAM(renderer->cache, address);
  }
}

static void GBAVideoDummyRendererWritePalette(struct GBAVideoRenderer* renderer, uint32_t address, uint16_t value) {
  if (renderer->cache) {
    mCacheSetWritePalette(renderer->cache, address >> 1, mColorFrom555(value));
  }
}

static void GBAVideoDummyRendererWriteOAM(struct GBAVideoRenderer* renderer, uint32_t oam) {
  UNUSED(renderer);
  UNUSED(oam);
  // Nothing to do
}

static void GBAVideoDummyRendererDrawScanline(struct GBAVideoRenderer* renderer, int y) {
  UNUSED(renderer);
  UNUSED(y);
  // Nothing to do
}

static void GBAVideoDummyRendererFinishFrame(struct GBAVideoRenderer* renderer) {
  UNUSED(renderer);
  // Nothing to do
}

static void GBAVideoDummyRendererGetPixels(struct GBAVideoRenderer* renderer, size_t* stride, const void** pixels) {
  UNUSED(renderer);
  UNUSED(stride);
  UNUSED(pixels);
  // Nothing to do
}

static void GBAVideoDummyRendererPutPixels(struct GBAVideoRenderer* renderer, size_t stride, const void* pixels) {
  UNUSED(renderer);
  UNUSED(stride);
  UNUSED(pixels);
  // Nothing to do
}

void GBAVideoSerialize(const struct GBAVideo* video, struct GBASerializedState* state) {
  memcpy(state->vram, video->vram, GBA_SIZE_VRAM);
  memcpy(state->oam, video->oam.raw, GBA_SIZE_OAM);
  memcpy(state->pram, video->palette, GBA_SIZE_PALETTE_RAM);
  STORE_32(video->event.when - mTimingCurrentTime(&video->p->timing), 0, &state->video.nextEvent);
  int32_t flags = 0;
  if (video->event.callback == _startHdraw) {
    flags = GBASerializedVideoFlagsSetMode(flags, 1);
  } else if (video->event.callback == _startHblank) {
    flags = GBASerializedVideoFlagsSetMode(flags, 2);
  }
  STORE_32(flags, 0, &state->video.flags);
  STORE_32(video->frameCounter, 0, &state->video.frameCounter);
}

void GBAVideoDeserialize(struct GBAVideo* video, const struct GBASerializedState* state) {
  memcpy(video->vram, state->vram, GBA_SIZE_VRAM);
  uint16_t value;
  int i;
  for (i = 0; i < GBA_SIZE_OAM; i += 2) {
    LOAD_16(value, i, state->oam);
    GBAStore16(video->p->cpu, GBA_BASE_OAM | i, value, 0);
  }
  for (i = 0; i < GBA_SIZE_PALETTE_RAM; i += 2) {
    LOAD_16(value, i, state->pram);
    GBAStore16(video->p->cpu, GBA_BASE_PALETTE_RAM | i, value, 0);
  }
  LOAD_32(video->frameCounter, 0, &state->video.frameCounter);

  video->stallMask = 0;
  int32_t flags;
  LOAD_32(flags, 0, &state->video.flags);
  GBARegisterDISPSTAT dispstat = state->io[GBA_REG(DISPSTAT)];
  switch (GBASerializedVideoFlagsGetMode(flags)) {
  case 0:
    if (GBARegisterDISPSTATIsInHblank(dispstat)) {
      video->event.callback = _startHdraw;
    } else {
      video->event.callback = _startHblank;
    }
    break;
  case 1:
    video->event.callback = _startHdraw;
    break;
  case 2:
    video->event.callback = _startHblank;
    video->stallMask = _calculateStallMask(video->p, state->io[GBA_REG(DISPCNT)]);
    break;
  case 3:
    video->event.callback = _startHdraw;
    break;
  }
  uint32_t when;
  if (state->versionMagic < 0x01000007) {
    // This field was moved in v7
    LOAD_32(when, 0, &state->audio.lastSample);
  } else {
    LOAD_32(when, 0, &state->video.nextEvent);
  }
  mTimingSchedule(&video->p->timing, &video->event, when);

  LOAD_16(video->vcount, GBA_REG_VCOUNT, state->io);
  video->renderer->reset(video->renderer);
}
// ---- END rewritten from reference implementation/video.c ----

// ---- BEGIN rewritten from reference implementation/overwrides.c ----
static const struct GBACartridgeOverride _overrides[] = {
  // Advance Wars
  { "AWRE", GBA_SAVEDATA_FLASH512, HW_NONE, 0x8038810 },
  { "AWRP", GBA_SAVEDATA_FLASH512, HW_NONE, 0x8038810 },

  // Advance Wars 2: Black Hole Rising
  { "AW2E", GBA_SAVEDATA_FLASH512, HW_NONE, 0x8036E08 },
  { "AW2P", GBA_SAVEDATA_FLASH512, HW_NONE, 0x803719C },

  // Boktai: The Sun is in Your Hand
  { "U3IJ", GBA_SAVEDATA_EEPROM, HW_RTC | HW_LIGHT_SENSOR, GBA_IDLE_LOOP_NONE },
  { "U3IE", GBA_SAVEDATA_EEPROM, HW_RTC | HW_LIGHT_SENSOR, GBA_IDLE_LOOP_NONE },
  { "U3IP", GBA_SAVEDATA_EEPROM, HW_RTC | HW_LIGHT_SENSOR, GBA_IDLE_LOOP_NONE },

  // Boktai 2: Solar Boy Django
  { "U32J", GBA_SAVEDATA_EEPROM, HW_RTC | HW_LIGHT_SENSOR, GBA_IDLE_LOOP_NONE },
  { "U32E", GBA_SAVEDATA_EEPROM, HW_RTC | HW_LIGHT_SENSOR, GBA_IDLE_LOOP_NONE },
  { "U32P", GBA_SAVEDATA_EEPROM, HW_RTC | HW_LIGHT_SENSOR, GBA_IDLE_LOOP_NONE },

  // Crash Bandicoot 2 - N-Tranced
  { "AC8J", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },
  { "AC8E", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },
  { "AC8P", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },

  // DigiCommunication Nyo - Datou! Black Gemagema Dan
  { "BDKJ", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },

  // Dragon Ball Z - The Legacy of Goku
  { "ALGP", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },

  // Dragon Ball Z - The Legacy of Goku II
  { "ALFJ", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },
  { "ALFE", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },
  { "ALFP", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },

  // Dragon Ball Z - Taiketsu
  { "BDBE", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },
  { "BDBP", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },

  // Drill Dozer
  { "V49J", GBA_SAVEDATA_SRAM, HW_RUMBLE, GBA_IDLE_LOOP_NONE },
  { "V49E", GBA_SAVEDATA_SRAM, HW_RUMBLE, GBA_IDLE_LOOP_NONE },
  { "V49P", GBA_SAVEDATA_SRAM, HW_RUMBLE, GBA_IDLE_LOOP_NONE },

  // e-Reader
  { "PEAJ", GBA_SAVEDATA_FLASH1M, HW_EREADER, GBA_IDLE_LOOP_NONE },
  { "PSAJ", GBA_SAVEDATA_FLASH1M, HW_EREADER, GBA_IDLE_LOOP_NONE },
  { "PSAE", GBA_SAVEDATA_FLASH1M, HW_EREADER, GBA_IDLE_LOOP_NONE },

  // Final Fantasy Tactics Advance
  { "AFXE", GBA_SAVEDATA_FLASH512, HW_NONE, 0x8000428 },

  // F-Zero - Climax
  { "BFTJ", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },

  // Goodboy Galaxy
  { "2GBP", GBA_SAVEDATA_SRAM, HW_RUMBLE, GBA_IDLE_LOOP_NONE },

  // Iridion II
  { "AI2E", GBA_SAVEDATA_FORCE_NONE, HW_NONE, GBA_IDLE_LOOP_NONE },
  { "AI2P", GBA_SAVEDATA_FORCE_NONE, HW_NONE, GBA_IDLE_LOOP_NONE },

  // Game Boy Wars Advance 1+2
  { "BGWJ", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },

  // Golden Sun: The Lost Age
  { "AGFE", GBA_SAVEDATA_FLASH512, HW_NONE, 0x801353A },

  // Koro Koro Puzzle - Happy Panechu!
  { "KHPJ", GBA_SAVEDATA_EEPROM, HW_TILT, GBA_IDLE_LOOP_NONE },

  // Legendz - Yomigaeru Shiren no Shima
  { "BLJJ", GBA_SAVEDATA_FLASH512, HW_RTC, GBA_IDLE_LOOP_NONE },
  { "BLJK", GBA_SAVEDATA_FLASH512, HW_RTC, GBA_IDLE_LOOP_NONE },

  // Legendz - Sign of Nekuromu
  { "BLVJ", GBA_SAVEDATA_FLASH512, HW_RTC, GBA_IDLE_LOOP_NONE },

  // Mega Man Battle Network
  { "AREE", GBA_SAVEDATA_SRAM, HW_NONE, 0x800032E },

  // Mega Man Zero
  { "AZCE", GBA_SAVEDATA_SRAM, HW_NONE, 0x80004E8 },

  // Metal Slug Advance
  { "BSME", GBA_SAVEDATA_EEPROM, HW_NONE, 0x8000290 },

  // Pokemon Ruby
  { "AXVJ", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
  { "AXVE", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
  { "AXVP", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
  { "AXVI", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
  { "AXVS", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
  { "AXVD", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
  { "AXVF", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },

  // Pokemon Sapphire
  { "AXPJ", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
  { "AXPE", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
  { "AXPP", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
  { "AXPI", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
  { "AXPS", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
  { "AXPD", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
  { "AXPF", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },

  // Pokemon Emerald
  { "BPEJ", GBA_SAVEDATA_FLASH1M, HW_RTC, 0x80008C6 },
  { "BPEE", GBA_SAVEDATA_FLASH1M, HW_RTC, 0x80008C6 },
  { "BPEP", GBA_SAVEDATA_FLASH1M, HW_RTC, 0x80008C6 },
  { "BPEI", GBA_SAVEDATA_FLASH1M, HW_RTC, 0x80008C6 },
  { "BPES", GBA_SAVEDATA_FLASH1M, HW_RTC, 0x80008C6 },
  { "BPED", GBA_SAVEDATA_FLASH1M, HW_RTC, 0x80008C6 },
  { "BPEF", GBA_SAVEDATA_FLASH1M, HW_RTC, 0x80008C6 },

  // Pokemon Mystery Dungeon
  { "B24E", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
  { "B24P", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },

  // Pokemon FireRed
  { "BPRJ", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
  { "BPRE", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
  { "BPRP", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
  { "BPRI", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
  { "BPRS", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
  { "BPRD", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
  { "BPRF", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },

  // Pokemon LeafGreen
  { "BPGJ", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
  { "BPGE", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
  { "BPGP", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
  { "BPGI", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
  { "BPGS", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
  { "BPGD", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
  { "BPGF", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },

  // RockMan EXE 4.5 - Real Operation
  { "BR4J", GBA_SAVEDATA_FLASH512, HW_RTC, GBA_IDLE_LOOP_NONE },

  // Rocky
  { "AR8E", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },
  { "AROP", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },

  // Sennen Kazoku
  { "BKAJ", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },

  // Shin Bokura no Taiyou: Gyakushuu no Sabata
  { "U33J", GBA_SAVEDATA_EEPROM, HW_RTC | HW_LIGHT_SENSOR, GBA_IDLE_LOOP_NONE },

  // Stuart Little 2
  { "ASLE", GBA_SAVEDATA_FORCE_NONE, HW_NONE, GBA_IDLE_LOOP_NONE },
  { "ASLF", GBA_SAVEDATA_FORCE_NONE, HW_NONE, GBA_IDLE_LOOP_NONE },

  // Super Mario Advance 2
  { "AA2J", GBA_SAVEDATA_EEPROM, HW_NONE, 0x800052E },
  { "AA2E", GBA_SAVEDATA_EEPROM, HW_NONE, 0x800052E },
  { "AA2P", GBA_SAVEDATA_AUTODETECT, HW_NONE, 0x800052E },

  // Super Mario Advance 3
  { "A3AJ", GBA_SAVEDATA_EEPROM, HW_NONE, 0x8002B9C },
  { "A3AE", GBA_SAVEDATA_EEPROM, HW_NONE, 0x8002B9C },
  { "A3AP", GBA_SAVEDATA_EEPROM, HW_NONE, 0x8002B9C },

  // Super Mario Advance 4
  { "AX4J", GBA_SAVEDATA_FLASH1M, HW_NONE, 0x800072A },
  { "AX4E", GBA_SAVEDATA_FLASH1M, HW_NONE, 0x800072A },
  { "AX4P", GBA_SAVEDATA_FLASH1M, HW_NONE, 0x800072A },

  // Super Monkey Ball Jr.
  { "ALUE", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },
  { "ALUP", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },

  // Top Gun - Combat Zones
  { "A2YE", GBA_SAVEDATA_FORCE_NONE, HW_NONE, GBA_IDLE_LOOP_NONE },

  // Ueki no Housoku - Jingi Sakuretsu! Nouryokusha Battle
  { "BUHJ", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },

  // Wario Ware Twisted
  { "RZWJ", GBA_SAVEDATA_SRAM, HW_RUMBLE | HW_GYRO, GBA_IDLE_LOOP_NONE },
  { "RZWE", GBA_SAVEDATA_SRAM, HW_RUMBLE | HW_GYRO, GBA_IDLE_LOOP_NONE },
  { "RZWP", GBA_SAVEDATA_SRAM, HW_RUMBLE | HW_GYRO, GBA_IDLE_LOOP_NONE },

  // Yoshi's Universal Gravitation
  { "KYGJ", GBA_SAVEDATA_EEPROM, HW_TILT, GBA_IDLE_LOOP_NONE },
  { "KYGE", GBA_SAVEDATA_EEPROM, HW_TILT, GBA_IDLE_LOOP_NONE },
  { "KYGP", GBA_SAVEDATA_EEPROM, HW_TILT, GBA_IDLE_LOOP_NONE },

  // Aging cartridge
  { "TCHK", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE, },

  { { 0, 0, 0, 0 }, 0, 0, GBA_IDLE_LOOP_NONE, false }
};

bool GBAOverrideFindConfig(const struct Configuration* config, struct GBACartridgeOverride* override) {
  bool found = false;
  if (config) {
    char sectionName[16];
    snprintf(sectionName, sizeof(sectionName), "override.%c%c%c%c", override->id[0], override->id[1], override->id[2], override->id[3]);
    const char* savetype = ConfigurationGetValue(config, sectionName, "savetype");
    const char* hardware = ConfigurationGetValue(config, sectionName, "hardware");
    const char* idleLoop = ConfigurationGetValue(config, sectionName, "idleLoop");

    if (savetype) {
      if (strcasecmp(savetype, "SRAM") == 0) {
        found = true;
        override->savetype = GBA_SAVEDATA_SRAM;
      } else if (strcasecmp(savetype, "SRAM512") == 0) {
        found = true;
        override->savetype = GBA_SAVEDATA_SRAM512;
      } else if (strcasecmp(savetype, "EEPROM") == 0) {
        found = true;
        override->savetype = GBA_SAVEDATA_EEPROM;
      } else if (strcasecmp(savetype, "EEPROM512") == 0) {
        found = true;
        override->savetype = GBA_SAVEDATA_EEPROM512;
      } else if (strcasecmp(savetype, "FLASH512") == 0) {
        found = true;
        override->savetype = GBA_SAVEDATA_FLASH512;
      } else if (strcasecmp(savetype, "FLASH1M") == 0) {
        found = true;
        override->savetype = GBA_SAVEDATA_FLASH1M;
      } else if (strcasecmp(savetype, "NONE") == 0) {
        found = true;
        override->savetype = GBA_SAVEDATA_FORCE_NONE;
      }
    }

    if (hardware) {
      char* end;
      long type = strtoul(hardware, &end, 0);
      if (end && !*end) {
        override->hardware = type & ~HW_NO_OVERRIDE;
        found = true;
      }
    }

    if (idleLoop) {
      char* end;
      uint32_t address = strtoul(idleLoop, &end, 16);
      if (end && !*end) {
        override->idleLoop = address;
        found = true;
      }
    }
  }
  return found;
}

bool GBAOverrideFind(const struct Configuration* config, struct GBACartridgeOverride* override) {
  override->savetype = GBA_SAVEDATA_AUTODETECT;
  override->hardware = HW_NO_OVERRIDE;
  override->idleLoop = GBA_IDLE_LOOP_NONE;
  override->vbaBugCompat = false;
  bool found = false;

  int i;
  for (i = 0; _overrides[i].id[0]; ++i) {
    if (memcmp(override->id, _overrides[i].id, sizeof(override->id)) == 0) {
      *override = _overrides[i];
      found = true;
      break;
    }
  }
  if (!found && override->id[0] == 'F') {
    // Classic NES Series
    override->savetype = GBA_SAVEDATA_EEPROM;
    found = true;
  }

  if (config) {
    found = GBAOverrideFindConfig(config, override) || found;
  }
  return found;
}

void GBAOverrideSave(struct Configuration* config, const struct GBACartridgeOverride* override) {
  char sectionName[16];
  snprintf(sectionName, sizeof(sectionName), "override.%c%c%c%c", override->id[0], override->id[1], override->id[2], override->id[3]);
  const char* savetype = 0;
  switch (override->savetype) {
  case GBA_SAVEDATA_SRAM:
    savetype = "SRAM";
    break;
  case GBA_SAVEDATA_SRAM512:
    savetype = "SRAM512";
    break;
  case GBA_SAVEDATA_EEPROM:
    savetype = "EEPROM";
    break;
  case GBA_SAVEDATA_EEPROM512:
    savetype = "EEPROM512";
    break;
  case GBA_SAVEDATA_FLASH512:
    savetype = "FLASH512";
    break;
  case GBA_SAVEDATA_FLASH1M:
    savetype = "FLASH1M";
    break;
  case GBA_SAVEDATA_FORCE_NONE:
    savetype = "NONE";
    break;
  case GBA_SAVEDATA_AUTODETECT:
    break;
  }
  ConfigurationSetValue(config, sectionName, "savetype", savetype);

  if (override->hardware != HW_NO_OVERRIDE) {
    ConfigurationSetIntValue(config, sectionName, "hardware", override->hardware);
  } else {
    ConfigurationClearValue(config, sectionName, "hardware");
  }

  if (override->idleLoop != GBA_IDLE_LOOP_NONE) {
    ConfigurationSetUIntValue(config, sectionName, "idleLoop", override->idleLoop);
  } else {
    ConfigurationClearValue(config, sectionName, "idleLoop");
  }
}

void GBAOverrideApply(struct GBA* gba, const struct GBACartridgeOverride* override) {
  if (override->savetype != GBA_SAVEDATA_AUTODETECT) {
    GBASavedataForceType(&gba->memory.savedata, override->savetype);
  }

  gba->vbaBugCompat = override->vbaBugCompat;

  if (override->hardware != HW_NO_OVERRIDE) {
    GBAHardwareClear(&gba->memory.hw);
    gba->memory.hw.devices &= ~HW_NO_OVERRIDE;

    if (override->hardware & HW_RTC) {
      GBAHardwareInitRTC(&gba->memory.hw);
      GBASavedataRTCRead(&gba->memory.savedata);
    }

    if (override->hardware & HW_GYRO) {
      GBAHardwareInitGyro(&gba->memory.hw);
    }

    if (override->hardware & HW_RUMBLE) {
      GBAHardwareInitRumble(&gba->memory.hw);
    }

    if (override->hardware & HW_LIGHT_SENSOR) {
      GBAHardwareInitLight(&gba->memory.hw);
    }

    if (override->hardware & HW_TILT) {
      GBAHardwareInitTilt(&gba->memory.hw);
    }

    if (override->hardware & HW_EREADER) {
      GBACartEReaderInit(&gba->memory.ereader);
    }

    if (override->hardware & HW_GB_PLAYER_DETECTION) {
      gba->memory.hw.devices |= HW_GB_PLAYER_DETECTION;
    } else {
      gba->memory.hw.devices &= ~HW_GB_PLAYER_DETECTION;
    }
  }

  if (override->idleLoop != GBA_IDLE_LOOP_NONE) {
    gba->idleLoop = override->idleLoop;
    if (gba->idleOptimization == IDLE_LOOP_DETECT) {
      gba->idleOptimization = IDLE_LOOP_REMOVE;
    }
  }
}

void GBAOverrideApplyDefaults(struct GBA* gba, const struct Configuration* overrides) {
  struct GBACartridgeOverride override = { .idleLoop = GBA_IDLE_LOOP_NONE };
  const struct GBACartridge* cart = (const struct GBACartridge*) gba->memory.rom;
  if (cart) {
    if (gba->memory.unl.type == GBA_UNL_CART_MULTICART) {
      override.savetype = GBA_SAVEDATA_SRAM;
      GBAOverrideApply(gba, &override);
      return;
    }

    memcpy(override.id, &cart->id, sizeof(override.id));

    static const uint32_t pokemonTable[] = {
      // Emerald
      0x4881F3F8, // BPEJ
      0x8C4D3108, // BPES
      0x1F1C08FB, // BPEE
      0x34C9DF89, // BPED
      0xA3FDCCB1, // BPEF
      0xA0AEC80A, // BPEI

      // FireRed
      0x1A81EEDF, // BPRD
      0x3B2056E9, // BPRJ
      0x5DC668F6, // BPRF
      0x73A72167, // BPRI
      0x84EE4776, // BPRE rev 1
      0x9F08064E, // BPRS
      0xBB640DF7, // BPRJ rev 1
      0xDD88761C, // BPRE

      // Ruby
      0x61641576, // AXVE rev 1
      0xAEAC73E6, // AXVE rev 2
      0xF0815EE7, // AXVE
    };

    bool isPokemon = false;
    isPokemon = isPokemon || !strncmp("pokemon red version", &((const char*) gba->memory.rom)[0x108], 20);
    isPokemon = isPokemon || !strncmp("pokemon emerald version", &((const char*) gba->memory.rom)[0x108], 24);
    isPokemon = isPokemon || !strncmp("AXVE", &((const char*) gba->memory.rom)[0xAC], 4);
    bool isKnownPokemon = false;
    if (isPokemon) {
      size_t i;
      for (i = 0; !isKnownPokemon && i < sizeof(pokemonTable) / sizeof(*pokemonTable); ++i) {
        isKnownPokemon = gba->romCrc32 == pokemonTable[i];
      }
    }

    if (isPokemon && !isKnownPokemon) {
      // Enable FLASH1M and RTC on PokÃ©mon ROM hacks
      override.savetype = GBA_SAVEDATA_FLASH1M;
      override.hardware = HW_RTC;
      override.vbaBugCompat = true;
      // Allow overrides from config file but not from defaults
      GBAOverrideFindConfig(overrides, &override);
      GBAOverrideApply(gba, &override);
    } else if (GBAOverrideFind(overrides, &override)) {
      GBAOverrideApply(gba, &override);
    }
  }
}
// ---- END rewritten from reference implementation/overwrides.c ----
#if defined(__cplusplus)
}  // extern "C"
#endif
