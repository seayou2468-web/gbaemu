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

// ---- BEGIN rewritten from reference implementation/io.c ----
const char* const GBAIORegisterNames[] = {
  // Video
  [GBA_REG(DISPCNT)] = "DISPCNT",
  [GBA_REG(DISPSTAT)] = "DISPSTAT",
  [GBA_REG(VCOUNT)] = "VCOUNT",
  [GBA_REG(BG0CNT)] = "BG0CNT",
  [GBA_REG(BG1CNT)] = "BG1CNT",
  [GBA_REG(BG2CNT)] = "BG2CNT",
  [GBA_REG(BG3CNT)] = "BG3CNT",
  [GBA_REG(BG0HOFS)] = "BG0HOFS",
  [GBA_REG(BG0VOFS)] = "BG0VOFS",
  [GBA_REG(BG1HOFS)] = "BG1HOFS",
  [GBA_REG(BG1VOFS)] = "BG1VOFS",
  [GBA_REG(BG2HOFS)] = "BG2HOFS",
  [GBA_REG(BG2VOFS)] = "BG2VOFS",
  [GBA_REG(BG3HOFS)] = "BG3HOFS",
  [GBA_REG(BG3VOFS)] = "BG3VOFS",
  [GBA_REG(BG2PA)] = "BG2PA",
  [GBA_REG(BG2PB)] = "BG2PB",
  [GBA_REG(BG2PC)] = "BG2PC",
  [GBA_REG(BG2PD)] = "BG2PD",
  [GBA_REG(BG2X_LO)] = "BG2X_LO",
  [GBA_REG(BG2X_HI)] = "BG2X_HI",
  [GBA_REG(BG2Y_LO)] = "BG2Y_LO",
  [GBA_REG(BG2Y_HI)] = "BG2Y_HI",
  [GBA_REG(BG3PA)] = "BG3PA",
  [GBA_REG(BG3PB)] = "BG3PB",
  [GBA_REG(BG3PC)] = "BG3PC",
  [GBA_REG(BG3PD)] = "BG3PD",
  [GBA_REG(BG3X_LO)] = "BG3X_LO",
  [GBA_REG(BG3X_HI)] = "BG3X_HI",
  [GBA_REG(BG3Y_LO)] = "BG3Y_LO",
  [GBA_REG(BG3Y_HI)] = "BG3Y_HI",
  [GBA_REG(WIN0H)] = "WIN0H",
  [GBA_REG(WIN1H)] = "WIN1H",
  [GBA_REG(WIN0V)] = "WIN0V",
  [GBA_REG(WIN1V)] = "WIN1V",
  [GBA_REG(WININ)] = "WININ",
  [GBA_REG(WINOUT)] = "WINOUT",
  [GBA_REG(MOSAIC)] = "MOSAIC",
  [GBA_REG(BLDCNT)] = "BLDCNT",
  [GBA_REG(BLDALPHA)] = "BLDALPHA",
  [GBA_REG(BLDY)] = "BLDY",

  // Sound
  [GBA_REG(SOUND1CNT_LO)] = "SOUND1CNT_LO",
  [GBA_REG(SOUND1CNT_HI)] = "SOUND1CNT_HI",
  [GBA_REG(SOUND1CNT_X)] = "SOUND1CNT_X",
  [GBA_REG(SOUND2CNT_LO)] = "SOUND2CNT_LO",
  [GBA_REG(SOUND2CNT_HI)] = "SOUND2CNT_HI",
  [GBA_REG(SOUND3CNT_LO)] = "SOUND3CNT_LO",
  [GBA_REG(SOUND3CNT_HI)] = "SOUND3CNT_HI",
  [GBA_REG(SOUND3CNT_X)] = "SOUND3CNT_X",
  [GBA_REG(SOUND4CNT_LO)] = "SOUND4CNT_LO",
  [GBA_REG(SOUND4CNT_HI)] = "SOUND4CNT_HI",
  [GBA_REG(SOUNDCNT_LO)] = "SOUNDCNT_LO",
  [GBA_REG(SOUNDCNT_HI)] = "SOUNDCNT_HI",
  [GBA_REG(SOUNDCNT_X)] = "SOUNDCNT_X",
  [GBA_REG(SOUNDBIAS)] = "SOUNDBIAS",
  [GBA_REG(WAVE_RAM0_LO)] = "WAVE_RAM0_LO",
  [GBA_REG(WAVE_RAM0_HI)] = "WAVE_RAM0_HI",
  [GBA_REG(WAVE_RAM1_LO)] = "WAVE_RAM1_LO",
  [GBA_REG(WAVE_RAM1_HI)] = "WAVE_RAM1_HI",
  [GBA_REG(WAVE_RAM2_LO)] = "WAVE_RAM2_LO",
  [GBA_REG(WAVE_RAM2_HI)] = "WAVE_RAM2_HI",
  [GBA_REG(WAVE_RAM3_LO)] = "WAVE_RAM3_LO",
  [GBA_REG(WAVE_RAM3_HI)] = "WAVE_RAM3_HI",
  [GBA_REG(FIFO_A_LO)] = "FIFO_A_LO",
  [GBA_REG(FIFO_A_HI)] = "FIFO_A_HI",
  [GBA_REG(FIFO_B_LO)] = "FIFO_B_LO",
  [GBA_REG(FIFO_B_HI)] = "FIFO_B_HI",

  // DMA
  [GBA_REG(DMA0SAD_LO)] = "DMA0SAD_LO",
  [GBA_REG(DMA0SAD_HI)] = "DMA0SAD_HI",
  [GBA_REG(DMA0DAD_LO)] = "DMA0DAD_LO",
  [GBA_REG(DMA0DAD_HI)] = "DMA0DAD_HI",
  [GBA_REG(DMA0CNT_LO)] = "DMA0CNT_LO",
  [GBA_REG(DMA0CNT_HI)] = "DMA0CNT_HI",
  [GBA_REG(DMA1SAD_LO)] = "DMA1SAD_LO",
  [GBA_REG(DMA1SAD_HI)] = "DMA1SAD_HI",
  [GBA_REG(DMA1DAD_LO)] = "DMA1DAD_LO",
  [GBA_REG(DMA1DAD_HI)] = "DMA1DAD_HI",
  [GBA_REG(DMA1CNT_LO)] = "DMA1CNT_LO",
  [GBA_REG(DMA1CNT_HI)] = "DMA1CNT_HI",
  [GBA_REG(DMA2SAD_LO)] = "DMA2SAD_LO",
  [GBA_REG(DMA2SAD_HI)] = "DMA2SAD_HI",
  [GBA_REG(DMA2DAD_LO)] = "DMA2DAD_LO",
  [GBA_REG(DMA2DAD_HI)] = "DMA2DAD_HI",
  [GBA_REG(DMA2CNT_LO)] = "DMA2CNT_LO",
  [GBA_REG(DMA2CNT_HI)] = "DMA2CNT_HI",
  [GBA_REG(DMA3SAD_LO)] = "DMA3SAD_LO",
  [GBA_REG(DMA3SAD_HI)] = "DMA3SAD_HI",
  [GBA_REG(DMA3DAD_LO)] = "DMA3DAD_LO",
  [GBA_REG(DMA3DAD_HI)] = "DMA3DAD_HI",
  [GBA_REG(DMA3CNT_LO)] = "DMA3CNT_LO",
  [GBA_REG(DMA3CNT_HI)] = "DMA3CNT_HI",

  // Timers
  [GBA_REG(TM0CNT_LO)] = "TM0CNT_LO",
  [GBA_REG(TM0CNT_HI)] = "TM0CNT_HI",
  [GBA_REG(TM1CNT_LO)] = "TM1CNT_LO",
  [GBA_REG(TM1CNT_HI)] = "TM1CNT_HI",
  [GBA_REG(TM2CNT_LO)] = "TM2CNT_LO",
  [GBA_REG(TM2CNT_HI)] = "TM2CNT_HI",
  [GBA_REG(TM3CNT_LO)] = "TM3CNT_LO",
  [GBA_REG(TM3CNT_HI)] = "TM3CNT_HI",

  // SIO
  [GBA_REG(SIOMULTI0)] = "SIOMULTI0",
  [GBA_REG(SIOMULTI1)] = "SIOMULTI1",
  [GBA_REG(SIOMULTI2)] = "SIOMULTI2",
  [GBA_REG(SIOMULTI3)] = "SIOMULTI3",
  [GBA_REG(SIOCNT)] = "SIOCNT",
  [GBA_REG(SIOMLT_SEND)] = "SIOMLT_SEND",
  [GBA_REG(KEYINPUT)] = "KEYINPUT",
  [GBA_REG(KEYCNT)] = "KEYCNT",
  [GBA_REG(RCNT)] = "RCNT",
  [GBA_REG(JOYCNT)] = "JOYCNT",
  [GBA_REG(JOY_RECV_LO)] = "JOY_RECV_LO",
  [GBA_REG(JOY_RECV_HI)] = "JOY_RECV_HI",
  [GBA_REG(JOY_TRANS_LO)] = "JOY_TRANS_LO",
  [GBA_REG(JOY_TRANS_HI)] = "JOY_TRANS_HI",
  [GBA_REG(JOYSTAT)] = "JOYSTAT",

  // Interrupts, etc
  [GBA_REG(IE)] = "IE",
  [GBA_REG(IF)] = "IF",
  [GBA_REG(WAITCNT)] = "WAITCNT",
  [GBA_REG(IME)] = "IME",
};

static const int _isValidRegister[GBA_REG(INTERNAL_MAX)] = {
  /*      0  2  4  6  8  A  C  E */
  /*    Video */
  /* 00 */ 1, 0, 1, 1, 1, 1, 1, 1,
  /* 01 */ 1, 1, 1, 1, 1, 1, 1, 1,
  /* 02 */ 1, 1, 1, 1, 1, 1, 1, 1,
  /* 03 */ 1, 1, 1, 1, 1, 1, 1, 1,
  /* 04 */ 1, 1, 1, 1, 1, 1, 1, 0,
  /* 05 */ 1, 1, 1, 0, 0, 0, 0, 0,
  /*    Audio */
  /* 06 */ 1, 1, 1, 0, 1, 0, 1, 0,
  /* 07 */ 1, 1, 1, 0, 1, 0, 1, 0,
  /* 08 */ 1, 1, 1, 0, 1, 0, 0, 0,
  /* 09 */ 1, 1, 1, 1, 1, 1, 1, 1,
  /* 0A */ 1, 1, 1, 1, 0, 0, 0, 0,
  /*    DMA */
  /* 0B */ 1, 1, 1, 1, 1, 1, 1, 1,
  /* 0C */ 1, 1, 1, 1, 1, 1, 1, 1,
  /* 0D */ 1, 1, 1, 1, 1, 1, 1, 1,
  /* 0E */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 0F */ 0, 0, 0, 0, 0, 0, 0, 0,
  /*   Timers */
  /* 10 */ 1, 1, 1, 1, 1, 1, 1, 1,
  /* 11 */ 0, 0, 0, 0, 0, 0, 0, 0,
  /*    SIO */
  /* 12 */ 1, 1, 1, 1, 1, 0, 0, 0,
  /* 13 */ 1, 1, 1, 0, 0, 0, 0, 0,
  /* 14 */ 1, 0, 0, 0, 0, 0, 0, 0,
  /* 15 */ 1, 1, 1, 1, 1, 0, 0, 0,
  /* 16 */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 17 */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 18 */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 19 */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 1A */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 1B */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 1C */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 1D */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 1E */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 1F */ 0, 0, 0, 0, 0, 0, 0, 0,
  /*    Interrupts */
  /* 20 */ 1, 1, 1, 0, 1, 0, 0, 0,
  // Internal registers
  1, 1
};

static const int _isRSpecialRegister[GBA_REG(INTERNAL_MAX)] = {
  /*      0  2  4  6  8  A  C  E */
  /*    Video */
  /* 00 */ 0, 0, 1, 1, 0, 0, 0, 0,
  /* 01 */ 1, 1, 1, 1, 1, 1, 1, 1,
  /* 02 */ 1, 1, 1, 1, 1, 1, 1, 1,
  /* 03 */ 1, 1, 1, 1, 1, 1, 1, 1,
  /* 04 */ 1, 1, 1, 1, 1, 1, 1, 1,
  /* 05 */ 1, 1, 1, 1, 1, 1, 1, 1,
  /*    Audio */
  /* 06 */ 0, 0, 1, 0, 0, 0, 1, 0,
  /* 07 */ 0, 0, 1, 0, 0, 0, 1, 0,
  /* 08 */ 0, 0, 0, 0, 1, 0, 0, 0,
  /* 09 */ 1, 1, 1, 1, 1, 1, 1, 1,
  /* 0A */ 1, 1, 1, 1, 0, 0, 0, 0,
  /*    DMA */
  /* 0B */ 1, 1, 1, 1, 1, 1, 1, 1,
  /* 0C */ 1, 1, 1, 1, 1, 1, 1, 1,
  /* 0D */ 1, 1, 1, 1, 1, 1, 1, 1,
  /* 0E */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 0F */ 0, 0, 0, 0, 0, 0, 0, 0,
  /*    Timers */
  /* 10 */ 1, 1, 1, 1, 1, 1, 1, 1,
  /* 11 */ 0, 0, 0, 0, 0, 0, 0, 0,
  /*    SIO */
  /* 12 */ 1, 1, 1, 1, 0, 0, 0, 0,
  /* 13 */ 1, 1, 0, 0, 0, 0, 0, 0,
  /* 14 */ 1, 0, 0, 0, 0, 0, 0, 0,
  /* 15 */ 1, 1, 1, 1, 1, 0, 0, 0,
  /* 16 */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 17 */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 18 */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 19 */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 1A */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 1B */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 1C */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 1D */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 1E */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 1F */ 0, 0, 0, 0, 0, 0, 0, 0,
  /*    Interrupts */
  /* 20 */ 0, 0, 0, 0, 0, 0, 0, 0,
  // Internal registers
  1, 1
};

static const int _isWSpecialRegister[GBA_REG(INTERNAL_MAX)] = {
  /*      0  2  4  6  8  A  C  E */
  /*    Video */
  /* 00 */ 0, 0, 1, 1, 0, 0, 0, 0,
  /* 01 */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 02 */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 03 */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 04 */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 05 */ 0, 0, 0, 0, 0, 0, 0, 0,
  /*    Audio */
  /* 06 */ 0, 0, 1, 0, 0, 0, 1, 0,
  /* 07 */ 0, 0, 1, 0, 0, 0, 1, 0,
  /* 08 */ 0, 0, 1, 0, 0, 0, 0, 0,
  /* 09 */ 1, 1, 1, 1, 1, 1, 1, 1,
  /* 0A */ 1, 1, 1, 1, 0, 0, 0, 0,
  /*    DMA */
  /* 0B */ 0, 0, 0, 0, 0, 1, 0, 0,
  /* 0C */ 0, 0, 0, 1, 0, 0, 0, 0,
  /* 0D */ 0, 1, 0, 0, 0, 0, 0, 1,
  /* 0E */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 0F */ 0, 0, 0, 0, 0, 0, 0, 0,
  /*    Timers */
  /* 10 */ 1, 1, 1, 1, 1, 1, 1, 1,
  /* 11 */ 0, 0, 0, 0, 0, 0, 0, 0,
  /*    SIO */
  /* 12 */ 1, 1, 1, 1, 1, 0, 0, 0,
  /* 13 */ 1, 1, 1, 0, 0, 0, 0, 0,
  /* 14 */ 1, 0, 0, 0, 0, 0, 0, 0,
  /* 15 */ 1, 1, 1, 1, 1, 0, 0, 0,
  /* 16 */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 17 */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 18 */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 19 */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 1A */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 1B */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 1C */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 1D */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 1E */ 0, 0, 0, 0, 0, 0, 0, 0,
  /* 1F */ 0, 0, 0, 0, 0, 0, 0, 0,
  /*    Interrupts */
  /* 20 */ 1, 1, 0, 0, 1, 0, 0, 0,
  // Internal registers
  1, 1
};

void GBAIOInit(struct GBA* gba) {
  gba->memory.io[GBA_REG(DISPCNT)] = 0x0080;
  gba->memory.io[GBA_REG(RCNT)] = RCNT_INITIAL;
  gba->memory.io[GBA_REG(KEYINPUT)] = 0x3FF;
  gba->memory.io[GBA_REG(SOUNDBIAS)] = 0x200;
  gba->memory.io[GBA_REG(BG2PA)] = 0x100;
  gba->memory.io[GBA_REG(BG2PD)] = 0x100;
  gba->memory.io[GBA_REG(BG3PA)] = 0x100;
  gba->memory.io[GBA_REG(BG3PD)] = 0x100;
  gba->memory.io[GBA_REG(INTERNAL_EXWAITCNT_LO)] = 0x20;
  gba->memory.io[GBA_REG(INTERNAL_EXWAITCNT_HI)] = 0xD00;

  if (!gba->biosVf) {
    gba->memory.io[GBA_REG(VCOUNT)] = 0x7E;
    gba->memory.io[GBA_REG(POSTFLG)] = 1;
  }
}

void GBAIOWrite(struct GBA* gba, uint32_t address, uint16_t value) {
  if (address < GBA_REG_SOUND1CNT_LO && (address > GBA_REG_VCOUNT || address < GBA_REG_DISPSTAT)) {
    gba->memory.io[address >> 1] = gba->video.renderer->writeVideoRegister(gba->video.renderer, address, value);
    return;
  }

  if (address >= GBA_REG_SOUND1CNT_LO && address <= GBA_REG_SOUNDCNT_LO && !gba->audio.enable) {
    // Ignore writes to most audio registers if the hardware is off.
    return;
  }

  switch (address) {
  // Video
  case GBA_REG_DISPSTAT:
    value = GBAVideoWriteDISPSTAT(&gba->video, value);
    break;

  case GBA_REG_VCOUNT:
    mLOG(GBA_IO, GAME_ERROR, "Write to read-only I/O register: %03X", address);
    return;

  // Audio
  case GBA_REG_SOUND1CNT_LO:
    GBAAudioWriteSOUND1CNT_LO(&gba->audio, value);
    value &= 0x007F;
    break;
  case GBA_REG_SOUND1CNT_HI:
    GBAAudioWriteSOUND1CNT_HI(&gba->audio, value);
    value &= 0xFFC0;
    break;
  case GBA_REG_SOUND1CNT_X:
    GBAAudioWriteSOUND1CNT_X(&gba->audio, value);
    value &= 0x4000;
    break;
  case GBA_REG_SOUND2CNT_LO:
    GBAAudioWriteSOUND2CNT_LO(&gba->audio, value);
    value &= 0xFFC0;
    break;
  case GBA_REG_SOUND2CNT_HI:
    GBAAudioWriteSOUND2CNT_HI(&gba->audio, value);
    value &= 0x4000;
    break;
  case GBA_REG_SOUND3CNT_LO:
    GBAAudioWriteSOUND3CNT_LO(&gba->audio, value);
    value &= 0x00E0;
    break;
  case GBA_REG_SOUND3CNT_HI:
    GBAAudioWriteSOUND3CNT_HI(&gba->audio, value);
    value &= 0xE000;
    break;
  case GBA_REG_SOUND3CNT_X:
    GBAAudioWriteSOUND3CNT_X(&gba->audio, value);
    value &= 0x4000;
    break;
  case GBA_REG_SOUND4CNT_LO:
    GBAAudioWriteSOUND4CNT_LO(&gba->audio, value);
    value &= 0xFF00;
    break;
  case GBA_REG_SOUND4CNT_HI:
    GBAAudioWriteSOUND4CNT_HI(&gba->audio, value);
    value &= 0x40FF;
    break;
  case GBA_REG_SOUNDCNT_LO:
    GBAAudioWriteSOUNDCNT_LO(&gba->audio, value);
    value &= 0xFF77;
    break;
  case GBA_REG_SOUNDCNT_HI:
    GBAAudioWriteSOUNDCNT_HI(&gba->audio, value);
    value &= 0x770F;
    break;
  case GBA_REG_SOUNDCNT_X:
    GBAAudioWriteSOUNDCNT_X(&gba->audio, value);
    value &= 0x0080;
    value |= gba->memory.io[GBA_REG(SOUNDCNT_X)] & 0xF;
    break;
  case GBA_REG_SOUNDBIAS:
    value &= 0xC3FE;
    GBAAudioWriteSOUNDBIAS(&gba->audio, value);
    break;

  case GBA_REG_WAVE_RAM0_LO:
  case GBA_REG_WAVE_RAM1_LO:
  case GBA_REG_WAVE_RAM2_LO:
  case GBA_REG_WAVE_RAM3_LO:
    GBAIOWrite32(gba, address, (gba->memory.io[(address >> 1) + 1] << 16) | value);
    break;

  case GBA_REG_WAVE_RAM0_HI:
  case GBA_REG_WAVE_RAM1_HI:
  case GBA_REG_WAVE_RAM2_HI:
  case GBA_REG_WAVE_RAM3_HI:
    GBAIOWrite32(gba, address - 2, gba->memory.io[(address >> 1) - 1] | (value << 16));
    break;

  case GBA_REG_FIFO_A_LO:
  case GBA_REG_FIFO_B_LO:
    GBAIOWrite32(gba, address, (gba->memory.io[(address >> 1) + 1] << 16) | value);
    return;

  case GBA_REG_FIFO_A_HI:
  case GBA_REG_FIFO_B_HI:
    GBAIOWrite32(gba, address - 2, gba->memory.io[(address >> 1) - 1] | (value << 16));
    return;

  // DMA
  case GBA_REG_DMA0SAD_LO:
  case GBA_REG_DMA0DAD_LO:
  case GBA_REG_DMA1SAD_LO:
  case GBA_REG_DMA1DAD_LO:
  case GBA_REG_DMA2SAD_LO:
  case GBA_REG_DMA2DAD_LO:
  case GBA_REG_DMA3SAD_LO:
  case GBA_REG_DMA3DAD_LO:
    GBAIOWrite32(gba, address, (gba->memory.io[(address >> 1) + 1] << 16) | value);
    break;

  case GBA_REG_DMA0SAD_HI:
  case GBA_REG_DMA0DAD_HI:
  case GBA_REG_DMA1SAD_HI:
  case GBA_REG_DMA1DAD_HI:
  case GBA_REG_DMA2SAD_HI:
  case GBA_REG_DMA2DAD_HI:
  case GBA_REG_DMA3SAD_HI:
  case GBA_REG_DMA3DAD_HI:
    GBAIOWrite32(gba, address - 2, gba->memory.io[(address >> 1) - 1] | (value << 16));
    break;

  case GBA_REG_DMA0CNT_LO:
    GBADMAWriteCNT_LO(gba, 0, value & 0x3FFF);
    break;
  case GBA_REG_DMA0CNT_HI:
    value = GBADMAWriteCNT_HI(gba, 0, value);
    break;
  case GBA_REG_DMA1CNT_LO:
    GBADMAWriteCNT_LO(gba, 1, value & 0x3FFF);
    break;
  case GBA_REG_DMA1CNT_HI:
    value = GBADMAWriteCNT_HI(gba, 1, value);
    break;
  case GBA_REG_DMA2CNT_LO:
    GBADMAWriteCNT_LO(gba, 2, value & 0x3FFF);
    break;
  case GBA_REG_DMA2CNT_HI:
    value = GBADMAWriteCNT_HI(gba, 2, value);
    break;
  case GBA_REG_DMA3CNT_LO:
    GBADMAWriteCNT_LO(gba, 3, value);
    break;
  case GBA_REG_DMA3CNT_HI:
    value = GBADMAWriteCNT_HI(gba, 3, value);
    break;

  // Timers
  case GBA_REG_TM0CNT_LO:
    GBATimerWriteTMCNT_LO(gba, 0, value);
    return;
  case GBA_REG_TM1CNT_LO:
    GBATimerWriteTMCNT_LO(gba, 1, value);
    return;
  case GBA_REG_TM2CNT_LO:
    GBATimerWriteTMCNT_LO(gba, 2, value);
    return;
  case GBA_REG_TM3CNT_LO:
    GBATimerWriteTMCNT_LO(gba, 3, value);
    return;

  case GBA_REG_TM0CNT_HI:
    value &= 0x00C7;
    GBATimerWriteTMCNT_HI(gba, 0, value);
    break;
  case GBA_REG_TM1CNT_HI:
    value &= 0x00C7;
    GBATimerWriteTMCNT_HI(gba, 1, value);
    break;
  case GBA_REG_TM2CNT_HI:
    value &= 0x00C7;
    GBATimerWriteTMCNT_HI(gba, 2, value);
    break;
  case GBA_REG_TM3CNT_HI:
    value &= 0x00C7;
    GBATimerWriteTMCNT_HI(gba, 3, value);
    break;

  // SIO
  case GBA_REG_SIOCNT:
    value &= 0x7FFF;
    GBASIOWriteSIOCNT(&gba->sio, value);
    break;
  case GBA_REG_RCNT:
    value &= 0xC1FF;
    GBASIOWriteRCNT(&gba->sio, value);
    break;
  case GBA_REG_JOY_TRANS_LO:
  case GBA_REG_JOY_TRANS_HI:
    gba->memory.io[GBA_REG(JOYSTAT)] |= JOYSTAT_TRANS;
    // Fall through
  case GBA_REG_SIODATA32_LO:
  case GBA_REG_SIODATA32_HI:
  case GBA_REG_SIOMLT_SEND:
  case GBA_REG_JOYCNT:
  case GBA_REG_JOYSTAT:
  case GBA_REG_JOY_RECV_LO:
  case GBA_REG_JOY_RECV_HI:
    value = GBASIOWriteRegister(&gba->sio, address, value);
    break;

  // Interrupts and misc
  case GBA_REG_KEYCNT:
    value &= 0xC3FF;
    if (gba->keysLast < 0x400) {
      gba->keysLast &= gba->memory.io[address >> 1] | ~value;
    }
    gba->memory.io[address >> 1] = value;
    GBATestKeypadIRQ(gba);
    return;
  case GBA_REG_WAITCNT:
    value &= 0x5FFF;
    GBAAdjustWaitstates(gba, value);
    break;
  case GBA_REG_IE:
    gba->memory.io[GBA_REG(IE)] = value;
    GBATestIRQ(gba, 1);
    return;
  case GBA_REG_IF:
    value = gba->memory.io[GBA_REG(IF)] & ~value;
    gba->memory.io[GBA_REG(IF)] = value;
    GBATestIRQ(gba, 1);
    return;
  case GBA_REG_IME:
    gba->memory.io[GBA_REG(IME)] = value & 1;
    GBATestIRQ(gba, 1);
    return;
  case GBA_REG_MAX:
    // Some bad interrupt libraries will write to this
    break;
  case GBA_REG_POSTFLG:
    if (gba->memory.activeRegion == GBA_REGION_BIOS) {
      if (gba->memory.io[address >> 1]) {
        if (value & 0x8000) {
          GBAStop(gba);
        } else {
          GBAHalt(gba);
        }
      }
      value &= ~0x8000;
    } else {
      mLOG(GBA_IO, GAME_ERROR, "Write to BIOS-only I/O register: %03X", address);
      return;
    }
    break;
  case GBA_REG_EXWAITCNT_HI:
    // This register sits outside of the normal I/O block, so we need to stash it somewhere unused
    address = GBA_REG_INTERNAL_EXWAITCNT_HI;
    value &= 0xFF00;
    GBAAdjustEWRAMWaitstates(gba, value);
    break;
  case GBA_REG_DEBUG_ENABLE:
    gba->debug = value == 0xC0DE;
    return;
  case GBA_REG_DEBUG_FLAGS:
    if (gba->debug) {
      GBADebug(gba, value);

      return;
    }
    // Fall through
  default:
    if (address >= GBA_REG_DEBUG_STRING && address - GBA_REG_DEBUG_STRING < sizeof(gba->debugString)) {
      STORE_16LE(value, address - GBA_REG_DEBUG_STRING, gba->debugString);
      return;
    }
    mLOG(GBA_IO, STUB, "Stub I/O register write: %03X", address);
    if (address >= GBA_REG_MAX) {
      mLOG(GBA_IO, GAME_ERROR, "Write to unused I/O register: %03X", address);
      return;
    }
    break;
  }
  gba->memory.io[address >> 1] = value;
}

void GBAIOWrite8(struct GBA* gba, uint32_t address, uint8_t value) {
  if (address >= GBA_REG_DEBUG_STRING && address - GBA_REG_DEBUG_STRING < sizeof(gba->debugString)) {
    gba->debugString[address - GBA_REG_DEBUG_STRING] = value;
    return;
  }
  if (address > GBA_SIZE_IO) {
    return;
  }
  uint16_t value16;

  switch (address) {
  case GBA_REG_SOUND1CNT_HI:
    GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
    GBAudioWriteNR11(&gba->audio.psg, value);
    gba->memory.io[GBA_REG(SOUND1CNT_HI)] &= 0xFF00;
    gba->memory.io[GBA_REG(SOUND1CNT_HI)] |= value & 0xC0;
    break;
  case GBA_REG_SOUND1CNT_HI + 1:
    GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
    GBAudioWriteNR12(&gba->audio.psg, value);
    gba->memory.io[GBA_REG(SOUND1CNT_HI)] &= 0x00C0;
    gba->memory.io[GBA_REG(SOUND1CNT_HI)] |= value << 8;
    break;
  case GBA_REG_SOUND1CNT_X:
    GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
    GBAudioWriteNR13(&gba->audio.psg, value);
    break;
  case GBA_REG_SOUND1CNT_X + 1:
    GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
    GBAudioWriteNR14(&gba->audio.psg, value);
    gba->memory.io[GBA_REG(SOUND1CNT_X)] = (value & 0x40) << 8;
    break;
  case GBA_REG_SOUND2CNT_LO:
    GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
    GBAudioWriteNR21(&gba->audio.psg, value);
    gba->memory.io[GBA_REG(SOUND2CNT_LO)] &= 0xFF00;
    gba->memory.io[GBA_REG(SOUND2CNT_LO)] |= value & 0xC0;
    break;
  case GBA_REG_SOUND2CNT_LO + 1:
    GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
    GBAudioWriteNR22(&gba->audio.psg, value);
    gba->memory.io[GBA_REG(SOUND2CNT_LO)] &= 0x00C0;
    gba->memory.io[GBA_REG(SOUND2CNT_LO)] |= value << 8;
    break;
  case GBA_REG_SOUND2CNT_HI:
    GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
    GBAudioWriteNR23(&gba->audio.psg, value);
    break;
  case GBA_REG_SOUND2CNT_HI + 1:
    GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
    GBAudioWriteNR24(&gba->audio.psg, value);
    gba->memory.io[GBA_REG(SOUND2CNT_HI)] = (value & 0x40) << 8;
    break;
  case GBA_REG_SOUND3CNT_HI:
    GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
    GBAudioWriteNR31(&gba->audio.psg, value);
    break;
  case GBA_REG_SOUND3CNT_HI + 1:
    GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
    gba->audio.psg.ch3.volume = GBAudioRegisterBankVolumeGetVolumeGBA(value);
    gba->memory.io[GBA_REG(SOUND3CNT_HI)] = (value & 0xE0) << 8;
    break;
  case GBA_REG_SOUND3CNT_X:
    GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
    GBAudioWriteNR33(&gba->audio.psg, value);
    break;
  case GBA_REG_SOUND3CNT_X + 1:
    GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
    GBAudioWriteNR34(&gba->audio.psg, value);
    gba->memory.io[GBA_REG(SOUND3CNT_X)] = (value & 0x40) << 8;
    break;
  case GBA_REG_SOUND4CNT_LO:
    GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
    GBAudioWriteNR41(&gba->audio.psg, value);
    break;
  case GBA_REG_SOUND4CNT_LO + 1:
    GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
    GBAudioWriteNR42(&gba->audio.psg, value);
    gba->memory.io[GBA_REG(SOUND4CNT_LO)] = value << 8;
    break;
  case GBA_REG_SOUND4CNT_HI:
    GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
    GBAudioWriteNR43(&gba->audio.psg, value);
    gba->memory.io[GBA_REG(SOUND4CNT_HI)] &= 0x4000;
    gba->memory.io[GBA_REG(SOUND4CNT_HI)] |= value;
    break;
  case GBA_REG_SOUND4CNT_HI + 1:
    GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
    GBAudioWriteNR44(&gba->audio.psg, value);
    gba->memory.io[GBA_REG(SOUND4CNT_HI)] &= 0x00FF;
    gba->memory.io[GBA_REG(SOUND4CNT_HI)] |= (value & 0x40) << 8;
    break;
  default:
    value16 = value << (8 * (address & 1));
    value16 |= (gba->memory.io[(address & (GBA_SIZE_IO - 1)) >> 1]) & ~(0xFF << (8 * (address & 1)));
    GBAIOWrite(gba, address & 0xFFFFFFFE, value16);
    break;
  }
}

void GBAIOWrite32(struct GBA* gba, uint32_t address, uint32_t value) {
  switch (address) {
  // Wave RAM can be written and read even if the audio hardware is disabled.
  // However, it is not possible to switch between the two banks because it
  // isn't possible to write to register SOUND3CNT_LO.
  case GBA_REG_WAVE_RAM0_LO:
    GBAAudioWriteWaveRAM(&gba->audio, 0, value);
    break;
  case GBA_REG_WAVE_RAM1_LO:
    GBAAudioWriteWaveRAM(&gba->audio, 1, value);
    break;
  case GBA_REG_WAVE_RAM2_LO:
    GBAAudioWriteWaveRAM(&gba->audio, 2, value);
    break;
  case GBA_REG_WAVE_RAM3_LO:
    GBAAudioWriteWaveRAM(&gba->audio, 3, value);
    break;
  case GBA_REG_FIFO_A_LO:
  case GBA_REG_FIFO_B_LO:
    value = GBAAudioWriteFIFO(&gba->audio, address, value);
    break;
  case GBA_REG_DMA0SAD_LO:
    value = GBADMAWriteSAD(gba, 0, value);
    break;
  case GBA_REG_DMA0DAD_LO:
    value = GBADMAWriteDAD(gba, 0, value);
    break;
  case GBA_REG_DMA1SAD_LO:
    value = GBADMAWriteSAD(gba, 1, value);
    break;
  case GBA_REG_DMA1DAD_LO:
    value = GBADMAWriteDAD(gba, 1, value);
    break;
  case GBA_REG_DMA2SAD_LO:
    value = GBADMAWriteSAD(gba, 2, value);
    break;
  case GBA_REG_DMA2DAD_LO:
    value = GBADMAWriteDAD(gba, 2, value);
    break;
  case GBA_REG_DMA3SAD_LO:
    value = GBADMAWriteSAD(gba, 3, value);
    break;
  case GBA_REG_DMA3DAD_LO:
    value = GBADMAWriteDAD(gba, 3, value);
    break;
  default:
    if (address >= GBA_REG_DEBUG_STRING && address - GBA_REG_DEBUG_STRING < sizeof(gba->debugString)) {
      STORE_32LE(value, address - GBA_REG_DEBUG_STRING, gba->debugString);
      return;
    }
    GBAIOWrite(gba, address, value & 0xFFFF);
    GBAIOWrite(gba, address | 2, value >> 16);
    return;
  }
  gba->memory.io[address >> 1] = value;
  gba->memory.io[(address >> 1) + 1] = value >> 16;
}

bool GBAIOIsReadConstant(uint32_t address) {
  switch (address) {
  default:
    return false;
  case GBA_REG_BG0CNT:
  case GBA_REG_BG1CNT:
  case GBA_REG_BG2CNT:
  case GBA_REG_BG3CNT:
  case GBA_REG_WININ:
  case GBA_REG_WINOUT:
  case GBA_REG_BLDCNT:
  case GBA_REG_BLDALPHA:
  case GBA_REG_SOUND1CNT_LO:
  case GBA_REG_SOUND1CNT_HI:
  case GBA_REG_SOUND1CNT_X:
  case GBA_REG_SOUND2CNT_LO:
  case GBA_REG_SOUND2CNT_HI:
  case GBA_REG_SOUND3CNT_LO:
  case GBA_REG_SOUND3CNT_HI:
  case GBA_REG_SOUND3CNT_X:
  case GBA_REG_SOUND4CNT_LO:
  case GBA_REG_SOUND4CNT_HI:
  case GBA_REG_SOUNDCNT_LO:
  case GBA_REG_SOUNDCNT_HI:
  case GBA_REG_TM0CNT_HI:
  case GBA_REG_TM1CNT_HI:
  case GBA_REG_TM2CNT_HI:
  case GBA_REG_TM3CNT_HI:
  case GBA_REG_KEYINPUT:
  case GBA_REG_KEYCNT:
  case GBA_REG_IE:
    return true;
  }
}

uint16_t GBAIORead(struct GBA* gba, uint32_t address) {
  if (!GBAIOIsReadConstant(address)) {
    // Most IO reads need to disable idle removal
    gba->haltPending = false;
  }

  switch (address) {
  // Reading this takes two cycles (1N+1I), so let's remove them preemptively
  case GBA_REG_TM0CNT_LO:
    GBATimerUpdateRegister(gba, 0, 2);
    break;
  case GBA_REG_TM1CNT_LO:
    GBATimerUpdateRegister(gba, 1, 2);
    break;
  case GBA_REG_TM2CNT_LO:
    GBATimerUpdateRegister(gba, 2, 2);
    break;
  case GBA_REG_TM3CNT_LO:
    GBATimerUpdateRegister(gba, 3, 2);
    break;

  case GBA_REG_KEYINPUT: {
      size_t c;
      for (c = 0; c < mCoreCallbacksListSize(&gba->coreCallbacks); ++c) {
        struct mCoreCallbacks* callbacks = mCoreCallbacksListGetPointer(&gba->coreCallbacks, c);
        if (callbacks->keysRead) {
          callbacks->keysRead(callbacks->context);
        }
      }
      bool allowOpposingDirections = gba->allowOpposingDirections;
      if (gba->keyCallback) {
        gba->keysActive = gba->keyCallback->readKeys(gba->keyCallback);
        if (!allowOpposingDirections) {
          allowOpposingDirections = gba->keyCallback->requireOpposingDirections;
        }
      }
      uint16_t input = gba->keysActive;
      if (!allowOpposingDirections) {
        unsigned rl = input & 0x030;
        unsigned ud = input & 0x0C0;
        input &= 0x30F;
        if (rl != 0x030) {
          input |= rl;
        }
        if (ud != 0x0C0) {
          input |= ud;
        }
      }
      gba->memory.io[address >> 1] = 0x3FF ^ input;
    }
    break;
  case GBA_REG_SIOCNT:
    return gba->sio.siocnt;
  case GBA_REG_RCNT:
    return gba->sio.rcnt;

  case GBA_REG_BG0HOFS:
  case GBA_REG_BG0VOFS:
  case GBA_REG_BG1HOFS:
  case GBA_REG_BG1VOFS:
  case GBA_REG_BG2HOFS:
  case GBA_REG_BG2VOFS:
  case GBA_REG_BG3HOFS:
  case GBA_REG_BG3VOFS:
  case GBA_REG_BG2PA:
  case GBA_REG_BG2PB:
  case GBA_REG_BG2PC:
  case GBA_REG_BG2PD:
  case GBA_REG_BG2X_LO:
  case GBA_REG_BG2X_HI:
  case GBA_REG_BG2Y_LO:
  case GBA_REG_BG2Y_HI:
  case GBA_REG_BG3PA:
  case GBA_REG_BG3PB:
  case GBA_REG_BG3PC:
  case GBA_REG_BG3PD:
  case GBA_REG_BG3X_LO:
  case GBA_REG_BG3X_HI:
  case GBA_REG_BG3Y_LO:
  case GBA_REG_BG3Y_HI:
  case GBA_REG_WIN0H:
  case GBA_REG_WIN1H:
  case GBA_REG_WIN0V:
  case GBA_REG_WIN1V:
  case GBA_REG_MOSAIC:
  case GBA_REG_BLDY:
  case GBA_REG_FIFO_A_LO:
  case GBA_REG_FIFO_A_HI:
  case GBA_REG_FIFO_B_LO:
  case GBA_REG_FIFO_B_HI:
  case GBA_REG_DMA0SAD_LO:
  case GBA_REG_DMA0SAD_HI:
  case GBA_REG_DMA0DAD_LO:
  case GBA_REG_DMA0DAD_HI:
  case GBA_REG_DMA1SAD_LO:
  case GBA_REG_DMA1SAD_HI:
  case GBA_REG_DMA1DAD_LO:
  case GBA_REG_DMA1DAD_HI:
  case GBA_REG_DMA2SAD_LO:
  case GBA_REG_DMA2SAD_HI:
  case GBA_REG_DMA2DAD_LO:
  case GBA_REG_DMA2DAD_HI:
  case GBA_REG_DMA3SAD_LO:
  case GBA_REG_DMA3SAD_HI:
  case GBA_REG_DMA3DAD_LO:
  case GBA_REG_DMA3DAD_HI:
    // Write-only register
    mLOG(GBA_IO, GAME_ERROR, "Read from write-only I/O register: %03X", address);
    return GBALoadBad(gba->cpu);

  case GBA_REG_DMA0CNT_LO:
  case GBA_REG_DMA1CNT_LO:
  case GBA_REG_DMA2CNT_LO:
  case GBA_REG_DMA3CNT_LO:
    // Many, many things read from the DMA register
  case GBA_REG_MAX:
    // Some bad interrupt libraries will read from this
    // (Silent) write-only register
    return 0;

  case GBA_REG_JOY_RECV_LO:
  case GBA_REG_JOY_RECV_HI:
    gba->memory.io[GBA_REG(JOYSTAT)] &= ~JOYSTAT_RECV;
    break;

  // Wave RAM can be written and read even if the audio hardware is disabled.
  // However, it is not possible to switch between the two banks because it
  // isn't possible to write to register SOUND3CNT_LO.
  case GBA_REG_WAVE_RAM0_LO:
    return GBAAudioReadWaveRAM(&gba->audio, 0) & 0xFFFF;
  case GBA_REG_WAVE_RAM0_HI:
    return GBAAudioReadWaveRAM(&gba->audio, 0) >> 16;
  case GBA_REG_WAVE_RAM1_LO:
    return GBAAudioReadWaveRAM(&gba->audio, 1) & 0xFFFF;
  case GBA_REG_WAVE_RAM1_HI:
    return GBAAudioReadWaveRAM(&gba->audio, 1) >> 16;
  case GBA_REG_WAVE_RAM2_LO:
    return GBAAudioReadWaveRAM(&gba->audio, 2) & 0xFFFF;
  case GBA_REG_WAVE_RAM2_HI:
    return GBAAudioReadWaveRAM(&gba->audio, 2) >> 16;
  case GBA_REG_WAVE_RAM3_LO:
    return GBAAudioReadWaveRAM(&gba->audio, 3) & 0xFFFF;
  case GBA_REG_WAVE_RAM3_HI:
    return GBAAudioReadWaveRAM(&gba->audio, 3) >> 16;

  case GBA_REG_SOUND1CNT_LO:
  case GBA_REG_SOUND1CNT_HI:
  case GBA_REG_SOUND1CNT_X:
  case GBA_REG_SOUND2CNT_LO:
  case GBA_REG_SOUND2CNT_HI:
  case GBA_REG_SOUND3CNT_LO:
  case GBA_REG_SOUND3CNT_HI:
  case GBA_REG_SOUND3CNT_X:
  case GBA_REG_SOUND4CNT_LO:
  case GBA_REG_SOUND4CNT_HI:
  case GBA_REG_SOUNDCNT_LO:
    if (!GBAudioEnableIsEnable(gba->memory.io[GBA_REG(SOUNDCNT_X)])) {
      // TODO: Is writing allowed when the circuit is disabled?
      return 0;
    }
    // Fall through
  case GBA_REG_DISPCNT:
  case GBA_REG_STEREOCNT:
  case GBA_REG_DISPSTAT:
  case GBA_REG_VCOUNT:
  case GBA_REG_BG0CNT:
  case GBA_REG_BG1CNT:
  case GBA_REG_BG2CNT:
  case GBA_REG_BG3CNT:
  case GBA_REG_WININ:
  case GBA_REG_WINOUT:
  case GBA_REG_BLDCNT:
  case GBA_REG_BLDALPHA:
  case GBA_REG_SOUNDCNT_HI:
  case GBA_REG_SOUNDCNT_X:
  case GBA_REG_SOUNDBIAS:
  case GBA_REG_DMA0CNT_HI:
  case GBA_REG_DMA1CNT_HI:
  case GBA_REG_DMA2CNT_HI:
  case GBA_REG_DMA3CNT_HI:
  case GBA_REG_TM0CNT_HI:
  case GBA_REG_TM1CNT_HI:
  case GBA_REG_TM2CNT_HI:
  case GBA_REG_TM3CNT_HI:
  case GBA_REG_KEYCNT:
  case GBA_REG_SIOMULTI0:
  case GBA_REG_SIOMULTI1:
  case GBA_REG_SIOMULTI2:
  case GBA_REG_SIOMULTI3:
  case GBA_REG_SIOMLT_SEND:
  case GBA_REG_JOYCNT:
  case GBA_REG_JOY_TRANS_LO:
  case GBA_REG_JOY_TRANS_HI:
  case GBA_REG_JOYSTAT:
  case GBA_REG_IE:
  case GBA_REG_IF:
  case GBA_REG_WAITCNT:
  case GBA_REG_IME:
  case GBA_REG_POSTFLG:
    // Handled transparently by registers
    break;
  case 0x066:
  case 0x06A:
  case 0x06E:
  case 0x076:
  case 0x07A:
  case 0x07E:
  case 0x086:
  case 0x08A:
  case 0x136:
  case 0x142:
  case 0x15A:
  case 0x206:
  case 0x302:
    mLOG(GBA_IO, GAME_ERROR, "Read from unused I/O register: %03X", address);
    return 0;
  // These registers sit outside of the normal I/O block, so we need to stash them somewhere unused
  case GBA_REG_EXWAITCNT_LO:
  case GBA_REG_EXWAITCNT_HI:
    address += GBA_REG_INTERNAL_EXWAITCNT_LO - GBA_REG_EXWAITCNT_LO;
    break;
  case GBA_REG_DEBUG_ENABLE:
    if (gba->debug) {
      return 0x1DEA;
    }
    // Fall through
  default:
    mLOG(GBA_IO, GAME_ERROR, "Read from unused I/O register: %03X", address);
    return GBALoadBad(gba->cpu);
  }
  return gba->memory.io[address >> 1];
}

void GBAIOSerialize(struct GBA* gba, struct GBASerializedState* state) {
  int i;
  for (i = 0; i < GBA_REG_INTERNAL_MAX; i += 2) {
    if (_isRSpecialRegister[i >> 1]) {
      STORE_16(gba->memory.io[i >> 1], i, state->io);
    } else if (_isValidRegister[i >> 1]) {
      uint16_t reg = GBAIORead(gba, i);
      STORE_16(reg, i, state->io);
    }
  }

  for (i = 0; i < 4; ++i) {
    STORE_16(gba->memory.io[(GBA_REG_DMA0CNT_LO + i * 12) >> 1], (GBA_REG_DMA0CNT_LO + i * 12), state->io);
    STORE_16(gba->timers[i].reload, 0, &state->timers[i].reload);
    STORE_32(gba->timers[i].lastEvent - mTimingCurrentTime(&gba->timing), 0, &state->timers[i].lastEvent);
    STORE_32(gba->timers[i].event.when - mTimingCurrentTime(&gba->timing), 0, &state->timers[i].nextEvent);
    STORE_32(gba->timers[i].flags, 0, &state->timers[i].flags);
  }
  STORE_32(gba->bus, 0, &state->bus);

  GBADMASerialize(gba, state);
  GBAHardwareSerialize(&gba->memory.hw, state);
}

void GBAIODeserialize(struct GBA* gba, const struct GBASerializedState* state) {
  LOAD_16(gba->memory.io[GBA_REG(SOUNDCNT_X)], GBA_REG_SOUNDCNT_X, state->io);
  GBAAudioWriteSOUNDCNT_X(&gba->audio, gba->memory.io[GBA_REG(SOUNDCNT_X)]);

  int i;
  for (i = 0; i < GBA_REG_MAX; i += 2) {
    if (_isWSpecialRegister[i >> 1]) {
      LOAD_16(gba->memory.io[i >> 1], i, state->io);
    } else if (_isValidRegister[i >> 1]) {
      uint16_t reg;
      LOAD_16(reg, i, state->io);
      GBAIOWrite(gba, i, reg);
    }
  }
  if (state->versionMagic >= 0x01000006) {
    GBAIOWrite(gba, GBA_REG_EXWAITCNT_HI, gba->memory.io[GBA_REG(INTERNAL_EXWAITCNT_HI)]);
  }

  uint32_t when;
  for (i = 0; i < 4; ++i) {
    LOAD_16(gba->timers[i].reload, 0, &state->timers[i].reload);
    LOAD_32(gba->timers[i].flags, 0, &state->timers[i].flags);
    LOAD_32(when, 0, &state->timers[i].lastEvent);
    gba->timers[i].lastEvent = when + mTimingCurrentTime(&gba->timing);
    LOAD_32(when, 0, &state->timers[i].nextEvent);
    if ((i < 1 || !GBATimerFlagsIsCountUp(gba->timers[i].flags)) && GBATimerFlagsIsEnable(gba->timers[i].flags)) {
      mTimingSchedule(&gba->timing, &gba->timers[i].event, when);
    } else {
      gba->timers[i].event.when = when + mTimingCurrentTime(&gba->timing);
    }
  }
  gba->sio.siocnt = gba->memory.io[GBA_REG(SIOCNT)];
  GBASIOWriteRCNT(&gba->sio, gba->memory.io[GBA_REG(RCNT)]);

  LOAD_32(gba->bus, 0, &state->bus);
  GBADMADeserialize(gba, state);
  GBAHardwareDeserialize(&gba->memory.hw, state);
}
// ---- END rewritten from reference implementation/io.c ----

// ---- BEGIN rewritten from reference implementation/lockstep.c ----


#define DRIVER_ID 0x6B636F4C
#define DRIVER_STATE_VERSION 1
#define LOCKSTEP_INTERVAL 4096
#define UNLOCKED_INTERVAL 4096
#define HARD_SYNC_INTERVAL 0x80000
#define TARGET(P) (1 << (P))
#define TARGET_ALL 0xF
#define TARGET_PRIMARY 0x1
#define TARGET_SECONDARY ((TARGET_ALL) & ~(TARGET_PRIMARY))

DECL_BITFIELD(GBASIOLockstepSerializedFlags, uint32_t);
DECL_BITS(GBASIOLockstepSerializedFlags, DriverMode, 0, 3);
DECL_BITS(GBASIOLockstepSerializedFlags, NumEvents, 3, 4);
DECL_BIT(GBASIOLockstepSerializedFlags, Asleep, 7);
DECL_BIT(GBASIOLockstepSerializedFlags, DataReceived, 8);
DECL_BIT(GBASIOLockstepSerializedFlags, EventScheduled, 9);
DECL_BITS(GBASIOLockstepSerializedFlags, Player0Mode, 10, 3);
DECL_BITS(GBASIOLockstepSerializedFlags, Player1Mode, 13, 3);
DECL_BITS(GBASIOLockstepSerializedFlags, Player2Mode, 16, 3);
DECL_BITS(GBASIOLockstepSerializedFlags, Player3Mode, 19, 3);
DECL_BITS(GBASIOLockstepSerializedFlags, TransferMode, 28, 3);
DECL_BIT(GBASIOLockstepSerializedFlags, TransferActive, 31);

DECL_BITFIELD(GBASIOLockstepSerializedEventFlags, uint32_t);
DECL_BITS(GBASIOLockstepSerializedEventFlags, Type, 0, 3);

struct GBASIOLockstepSerializedEvent {
  int32_t timestamp;
  int32_t playerId;
  GBASIOLockstepSerializedEventFlags flags;
  int32_t reserved[5];
  union {
    int32_t mode;
    int32_t finishCycle;
    int32_t padding[4];
  };
};
static_assert(sizeof(struct GBASIOLockstepSerializedEvent) == 0x30, "GBA lockstep event savestate struct sized wrong");

struct GBASIOLockstepSerializedState {
  uint32_t version;
  GBASIOLockstepSerializedFlags flags;
  uint32_t reserved[2];

  struct {
    int32_t nextEvent;
    uint32_t reservedDriver[7];
  } driver;

  struct {
    int32_t playerId;
    int32_t cycleOffset;
    uint32_t reservedPlayer[2];
    struct GBASIOLockstepSerializedEvent events[MAX_LOCKSTEP_EVENTS];
  } player;

  // playerId 0 only
  struct {
    int32_t cycle;
    uint32_t waiting;
    int32_t nextHardSync;
    uint32_t reservedCoordinator[3];
    uint16_t multiData[4];
    uint32_t normalData[4];
  } coordinator;
};
static_assert(offsetof(struct GBASIOLockstepSerializedState, driver) == 0x10, "GBA lockstep savestate driver offset wrong");
static_assert(offsetof(struct GBASIOLockstepSerializedState, player) == 0x30, "GBA lockstep savestate player offset wrong");
static_assert(offsetof(struct GBASIOLockstepSerializedState, coordinator) == 0x1C0, "GBA lockstep savestate coordinator offset wrong");
static_assert(sizeof(struct GBASIOLockstepSerializedState) == 0x1F0, "GBA lockstep savestate struct sized wrong");

static bool GBASIOLockstepDriverInit(struct GBASIODriver* driver);
static void GBASIOLockstepDriverDeinit(struct GBASIODriver* driver);
static void GBASIOLockstepDriverReset(struct GBASIODriver* driver);
static uint32_t GBASIOLockstepDriverId(const struct GBASIODriver* driver);
static bool GBASIOLockstepDriverLoadState(struct GBASIODriver* driver, const void* state, size_t size);
static void GBASIOLockstepDriverSaveState(struct GBASIODriver* driver, void** state, size_t* size);
static void GBASIOLockstepDriverSetMode(struct GBASIODriver* driver, enum GBASIOMode mode);
static bool GBASIOLockstepDriverHandlesMode(struct GBASIODriver* driver, enum GBASIOMode mode);
static int GBASIOLockstepDriverConnectedDevices(struct GBASIODriver* driver);
static int GBASIOLockstepDriverDeviceId(struct GBASIODriver* driver);
static uint16_t GBASIOLockstepDriverWriteSIOCNT(struct GBASIODriver* driver, uint16_t value);
static uint16_t GBASIOLockstepDriverWriteRCNT(struct GBASIODriver* driver, uint16_t value);
static bool GBASIOLockstepDriverStart(struct GBASIODriver* driver);
static void GBASIOLockstepDriverFinishMultiplayer(struct GBASIODriver* driver, uint16_t data[4]);
static uint8_t GBASIOLockstepDriverFinishNormal8(struct GBASIODriver* driver);
static uint32_t GBASIOLockstepDriverFinishNormal32(struct GBASIODriver* driver);

static void GBASIOLockstepCoordinatorWaitOnPlayers(struct GBASIOLockstepCoordinator*, struct GBASIOLockstepPlayer*);
static void GBASIOLockstepCoordinatorAckPlayer(struct GBASIOLockstepCoordinator*, struct GBASIOLockstepPlayer*);
static void GBASIOLockstepCoordinatorWakePlayers(struct GBASIOLockstepCoordinator*);

static int32_t GBASIOLockstepTime(struct GBASIOLockstepPlayer*);
static void GBASIOLockstepPlayerWake(struct GBASIOLockstepPlayer*);
static void GBASIOLockstepPlayerSleep(struct GBASIOLockstepPlayer*);

static void _advanceCycle(struct GBASIOLockstepCoordinator*, struct GBASIOLockstepPlayer*);
static void _removePlayer(struct GBASIOLockstepCoordinator*, struct GBASIOLockstepPlayer*);
static void _reconfigPlayers(struct GBASIOLockstepCoordinator*);
static int32_t _untilNextSync(struct GBASIOLockstepCoordinator*, struct GBASIOLockstepPlayer*);
static void _enqueueEvent(struct GBASIOLockstepCoordinator*, const struct GBASIOLockstepEvent*, uint32_t target);
static void _setData(struct GBASIOLockstepCoordinator*, uint32_t id, struct GBASIO* sio);
static void _setReady(struct GBASIOLockstepCoordinator*, struct GBASIOLockstepPlayer* activePlayer, int playerId, enum GBASIOMode mode);
static void _hardSync(struct GBASIOLockstepCoordinator*, struct GBASIOLockstepPlayer*);

static void _lockstepEvent(struct mTiming*, void* context, uint32_t cyclesLate);

static void _verifyAwake(struct GBASIOLockstepCoordinator* coordinator) {
#ifdef NDEBUG
  UNUSED(coordinator);
#else
  int i;
  int asleep = 0;
  for (i = 0; i < coordinator->nAttached; ++i) {
    if (!coordinator->attachedPlayers[i]) {
      continue;
    }
    struct GBASIOLockstepPlayer* player = TableLookup(&coordinator->players, coordinator->attachedPlayers[i]);
    asleep += player->asleep;
  }
  mASSERT_DEBUG(!asleep || asleep < coordinator->nAttached);
#endif
}

static void _abortTransfer(struct GBASIOLockstepCoordinator* coordinator, struct GBASIOLockstepPlayer* player) {
  mLOG(GBA_SIO, DEBUG, "Aborting in-progress transfer");
  // TODO: Do we need to clean this up better?
  coordinator->transferActive = false;
  coordinator->waiting = 0;

  if (player->playerId != 0) {
    struct GBASIOLockstepPlayer* runner = TableLookup(&coordinator->players, coordinator->attachedPlayers[0]);
    if (runner) {
      GBASIOLockstepPlayerWake(runner);
    }
  } else {
    GBASIOLockstepCoordinatorWakePlayers(coordinator);
  }
}

void GBASIOLockstepDriverCreate(struct GBASIOLockstepDriver* driver, struct mLockstepUser* user) {
  memset(driver, 0, sizeof(*driver));
  driver->d.init = GBASIOLockstepDriverInit;
  driver->d.deinit = GBASIOLockstepDriverDeinit;
  driver->d.reset = GBASIOLockstepDriverReset;
  driver->d.driverId = GBASIOLockstepDriverId;
  driver->d.loadState = GBASIOLockstepDriverLoadState;
  driver->d.saveState = GBASIOLockstepDriverSaveState;
  driver->d.setMode = GBASIOLockstepDriverSetMode;
  driver->d.handlesMode = GBASIOLockstepDriverHandlesMode;
  driver->d.deviceId = GBASIOLockstepDriverDeviceId;
  driver->d.connectedDevices = GBASIOLockstepDriverConnectedDevices;
  driver->d.writeSIOCNT = GBASIOLockstepDriverWriteSIOCNT;
  driver->d.writeRCNT = GBASIOLockstepDriverWriteRCNT;
  driver->d.start = GBASIOLockstepDriverStart;
  driver->d.finishMultiplayer = GBASIOLockstepDriverFinishMultiplayer;
  driver->d.finishNormal8 = GBASIOLockstepDriverFinishNormal8;
  driver->d.finishNormal32 = GBASIOLockstepDriverFinishNormal32;
  driver->event.context = driver;
  driver->event.callback = _lockstepEvent;
  driver->event.name = "GBA SIO Lockstep";
  driver->event.priority = 0x80;
  driver->user = user;
}

static bool GBASIOLockstepDriverInit(struct GBASIODriver* driver) {
  GBASIOLockstepDriverReset(driver);
  return true;
}

static void GBASIOLockstepDriverDeinit(struct GBASIODriver* driver) {
  struct GBASIOLockstepDriver* lockstep = (struct GBASIOLockstepDriver*) driver;
  struct GBASIOLockstepCoordinator* coordinator = lockstep->coordinator;
  MutexLock(&coordinator->mutex);
  struct GBASIOLockstepPlayer* player = TableLookup(&coordinator->players, lockstep->lockstepId);
  if (player) {
    _removePlayer(coordinator, player);
  }
  MutexUnlock(&coordinator->mutex);
  mTimingDeschedule(&lockstep->d.p->p->timing, &lockstep->event);
  lockstep->lockstepId = 0;
}

static void GBASIOLockstepDriverReset(struct GBASIODriver* driver) {
  struct GBASIOLockstepDriver* lockstep = (struct GBASIOLockstepDriver*) driver;
  struct GBASIOLockstepCoordinator* coordinator = lockstep->coordinator;
  struct GBASIOLockstepPlayer* player;
  if (!lockstep->lockstepId) {
    unsigned id;
    player = calloc(1, sizeof(*player));
    player->driver = lockstep;
    player->mode = driver->p->mode;
    player->playerId = -1;

    int i;
    for (i = 0; i < MAX_LOCKSTEP_EVENTS - 1; ++i) {
      player->buffer[i].next = &player->buffer[i + 1];
    }
    player->freeList = &player->buffer[0];

    MutexLock(&coordinator->mutex);
    while (true) {
      if (coordinator->nextId == UINT_MAX) {
        coordinator->nextId = 0;
      }
      ++coordinator->nextId;
      id = coordinator->nextId;
      if (!TableLookup(&coordinator->players, id)) {
        TableInsert(&coordinator->players, id, player);
        lockstep->lockstepId = id;
        break;
      }
    }
    _reconfigPlayers(coordinator);
    player->cycleOffset = mTimingCurrentTime(&driver->p->p->timing) - coordinator->cycle;
    if (player->playerId != 0) {
      struct GBASIOLockstepEvent event = {
        .type = SIO_EV_ATTACH,
        .playerId = player->playerId,
        .timestamp = GBASIOLockstepTime(player),
      };
      _enqueueEvent(coordinator, &event, TARGET_ALL & ~TARGET(player->playerId));
    }
  } else {
    MutexLock(&coordinator->mutex);
    player = TableLookup(&coordinator->players, lockstep->lockstepId);
    player->cycleOffset = mTimingCurrentTime(&driver->p->p->timing) - coordinator->cycle;
  }

  if (coordinator->transferActive) {
    _abortTransfer(coordinator, player);
    player->asleep = false;
  }
  if (player->playerId == 0 && coordinator->nAttached > 1) {
    coordinator->waiting = 0;
    // We will immediately go back to sleep when the initial mode gets set,
    // so we need to clear this here to avoid triggering an assert later.
    player->asleep = false;
    GBASIOLockstepCoordinatorWakePlayers(coordinator);
  }

  if (mTimingIsScheduled(&lockstep->d.p->p->timing, &lockstep->event)) {
    MutexUnlock(&coordinator->mutex);
    return;
  }

  int32_t nextEvent;
  _setReady(coordinator, player, player->playerId, player->mode);
  if (TableSize(&coordinator->players) == 1) {
    coordinator->cycle = mTimingCurrentTime(&lockstep->d.p->p->timing);
    nextEvent = LOCKSTEP_INTERVAL;
  } else {
    _setReady(coordinator, player, 0, coordinator->transferMode);
    nextEvent = _untilNextSync(lockstep->coordinator, player);
  }
  MutexUnlock(&coordinator->mutex);
  mTimingSchedule(&lockstep->d.p->p->timing, &lockstep->event, nextEvent);
}

static uint32_t GBASIOLockstepDriverId(const struct GBASIODriver* driver) {
  UNUSED(driver);
  return DRIVER_ID;
}

static unsigned _modeEnumToInt(enum GBASIOMode mode) {
  switch ((int) mode) {
  case -1:
  default:
    return 0;
  case GBA_SIO_MULTI:
    return 1;
  case GBA_SIO_NORMAL_8:
    return 2;
  case GBA_SIO_NORMAL_32:
    return 3;
  case GBA_SIO_GPIO:
    return 4;
  case GBA_SIO_UART:
    return 5;
  case GBA_SIO_JOYBUS:
    return 6;
  }
}

static enum GBASIOMode _modeIntToEnum(unsigned mode) {
  const enum GBASIOMode modes[8] = {
    -1, GBA_SIO_MULTI, GBA_SIO_NORMAL_8, GBA_SIO_NORMAL_32, GBA_SIO_GPIO, GBA_SIO_UART, GBA_SIO_JOYBUS, -1
  };
  return modes[mode & 7];
}

static bool GBASIOLockstepDriverLoadState(struct GBASIODriver* driver, const void* data, size_t size) {
  struct GBASIOLockstepDriver* lockstep = (struct GBASIOLockstepDriver*) driver;
  struct GBASIOLockstepCoordinator* coordinator = lockstep->coordinator;
  if (size != sizeof(struct GBASIOLockstepSerializedState)) {
    mLOG(GBA_SIO, WARN, "Incorrect state size: expected %" PRIz "X, got %" PRIz "X", sizeof(struct GBASIOLockstepSerializedState), size);
    return false;
  }
  const struct GBASIOLockstepSerializedState* state = data;
  bool error = false;
  uint32_t ucheck;
  int32_t check;
  LOAD_32LE(ucheck, 0, &state->version);
  if (ucheck > DRIVER_STATE_VERSION) {
    mLOG(GBA_SIO, WARN, "Invalid or too new save state: expected %u, got %u", DRIVER_STATE_VERSION, ucheck);
    return false;
  }

  MutexLock(&coordinator->mutex);
  struct GBASIOLockstepPlayer* player = TableLookup(&coordinator->players, lockstep->lockstepId);
  LOAD_32LE(check, 0, &state->player.playerId);
  if (check != player->playerId) {
    mLOG(GBA_SIO, WARN, "State is for different player: expected %d, got %d", player->playerId, check);
    error = true;
    goto out;
  }

  GBASIOLockstepSerializedFlags flags = 0;
  LOAD_32LE(flags, 0, &state->flags);
  LOAD_32LE(player->cycleOffset, 0, &state->player.cycleOffset);
  player->dataReceived = GBASIOLockstepSerializedFlagsGetDataReceived(flags);
  player->mode = _modeIntToEnum(GBASIOLockstepSerializedFlagsGetDriverMode(flags));

  player->otherModes[0] = _modeIntToEnum(GBASIOLockstepSerializedFlagsGetPlayer0Mode(flags));
  player->otherModes[1] = _modeIntToEnum(GBASIOLockstepSerializedFlagsGetPlayer1Mode(flags));
  player->otherModes[2] = _modeIntToEnum(GBASIOLockstepSerializedFlagsGetPlayer2Mode(flags));
  player->otherModes[3] = _modeIntToEnum(GBASIOLockstepSerializedFlagsGetPlayer3Mode(flags));

  if (GBASIOLockstepSerializedFlagsGetEventScheduled(flags)) {
    int32_t when;
    LOAD_32LE(when, 0, &state->driver.nextEvent);
    mTimingSchedule(&driver->p->p->timing, &lockstep->event, when);
  }

  if (GBASIOLockstepSerializedFlagsGetAsleep(flags)) {
    if (!player->asleep && player->driver->user->sleep) {
      player->driver->user->sleep(player->driver->user);
    }
    player->asleep = true;
  } else {
    if (player->asleep && player->driver->user->wake) {
      player->driver->user->wake(player->driver->user);
    }
    player->asleep = false;
  }

  unsigned i;
  for (i = 0; i < MAX_LOCKSTEP_EVENTS - 1; ++i) {
    player->buffer[i].next = &player->buffer[i + 1];
  }
  player->freeList = &player->buffer[0];
  player->queue = NULL;

  struct GBASIOLockstepEvent** lastEvent = &player->queue;
  for (i = 0; i < GBASIOLockstepSerializedFlagsGetNumEvents(flags) && i < MAX_LOCKSTEP_EVENTS; ++i) {
    struct GBASIOLockstepEvent* event = player->freeList;
    const struct GBASIOLockstepSerializedEvent* stateEvent = &state->player.events[i];
    player->freeList = player->freeList->next;
    *lastEvent = event;
    lastEvent = &event->next;

    GBASIOLockstepSerializedEventFlags flags;
    LOAD_32LE(flags, 0, &stateEvent->flags);
    LOAD_32LE(event->timestamp, 0, &stateEvent->timestamp);
    LOAD_32LE(event->playerId, 0, &stateEvent->playerId);
    event->type = GBASIOLockstepSerializedEventFlagsGetType(flags);
    switch (event->type) {
    case SIO_EV_ATTACH:
    case SIO_EV_DETACH:
    case SIO_EV_HARD_SYNC:
      break;
    case SIO_EV_MODE_SET:
      LOAD_32LE(event->mode, 0, &stateEvent->mode);
      break;
    case SIO_EV_TRANSFER_START:
      LOAD_32LE(event->finishCycle, 0, &stateEvent->finishCycle);
      break;
    }
  }

  if (player->playerId == 0) {
    LOAD_32LE(coordinator->cycle, 0, &state->coordinator.cycle);
    LOAD_32LE(coordinator->waiting, 0, &state->coordinator.waiting);
    LOAD_32LE(coordinator->nextHardSync, 0, &state->coordinator.nextHardSync);
    for (i = 0; i < 4; ++i) {
      LOAD_16LE(coordinator->multiData[i], 0, &state->coordinator.multiData[i]);
      LOAD_32LE(coordinator->normalData[i], 0, &state->coordinator.normalData[i]);
    }
    coordinator->transferMode = _modeIntToEnum(GBASIOLockstepSerializedFlagsGetTransferMode(flags));
    coordinator->transferActive = GBASIOLockstepSerializedFlagsGetTransferActive(flags);
  }
out:
  MutexUnlock(&coordinator->mutex);
  if (!error) {
    mTimingInterrupt(&driver->p->p->timing);
  }
  return !error;
}

static void GBASIOLockstepDriverSaveState(struct GBASIODriver* driver, void** stateOut, size_t* size) {
  struct GBASIOLockstepDriver* lockstep = (struct GBASIOLockstepDriver*) driver;
  struct GBASIOLockstepCoordinator* coordinator = lockstep->coordinator;
  struct GBASIOLockstepSerializedState* state = calloc(1, sizeof(*state));

  STORE_32LE(DRIVER_STATE_VERSION, 0, &state->version);

  STORE_32LE(lockstep->event.when - mTimingCurrentTime(&driver->p->p->timing), 0, &state->driver.nextEvent);

  MutexLock(&coordinator->mutex);
  struct GBASIOLockstepPlayer* player = TableLookup(&coordinator->players, lockstep->lockstepId);
  GBASIOLockstepSerializedFlags flags = 0;
  STORE_32LE(player->playerId, 0, &state->player.playerId);
  STORE_32LE(player->cycleOffset, 0, &state->player.cycleOffset);
  flags = GBASIOLockstepSerializedFlagsSetAsleep(flags, player->asleep);
  flags = GBASIOLockstepSerializedFlagsSetDataReceived(flags, player->dataReceived);
  flags = GBASIOLockstepSerializedFlagsSetDriverMode(flags, _modeEnumToInt(player->mode));
  flags = GBASIOLockstepSerializedFlagsSetEventScheduled(flags, mTimingIsScheduled(&driver->p->p->timing, &lockstep->event));

  flags = GBASIOLockstepSerializedFlagsSetPlayer0Mode(flags, _modeEnumToInt(player->otherModes[0]));
  flags = GBASIOLockstepSerializedFlagsSetPlayer1Mode(flags, _modeEnumToInt(player->otherModes[1]));
  flags = GBASIOLockstepSerializedFlagsSetPlayer2Mode(flags, _modeEnumToInt(player->otherModes[2]));
  flags = GBASIOLockstepSerializedFlagsSetPlayer3Mode(flags, _modeEnumToInt(player->otherModes[3]));

  struct GBASIOLockstepEvent* event = player->queue;
  size_t i;
  for (i = 0; i < MAX_LOCKSTEP_EVENTS && event; ++i, event = event->next) {
    struct GBASIOLockstepSerializedEvent* stateEvent = &state->player.events[i];
    GBASIOLockstepSerializedEventFlags flags = GBASIOLockstepSerializedEventFlagsSetType(0, event->type);
    STORE_32LE(event->timestamp, 0, &stateEvent->timestamp);
    STORE_32LE(event->playerId, 0, &stateEvent->playerId);
    switch (event->type) {
    case SIO_EV_ATTACH:
    case SIO_EV_DETACH:
    case SIO_EV_HARD_SYNC:
      break;
    case SIO_EV_MODE_SET:
      STORE_32LE(event->mode, 0, &stateEvent->mode);
      break;
    case SIO_EV_TRANSFER_START:
      STORE_32LE(event->finishCycle, 0, &stateEvent->finishCycle);
      break;
    }
    STORE_32LE(flags, 0, &stateEvent->flags);
  }
  flags = GBASIOLockstepSerializedFlagsSetNumEvents(flags, i);

  if (player->playerId == 0) {
    STORE_32LE(coordinator->cycle, 0, &state->coordinator.cycle);
    STORE_32LE(coordinator->waiting, 0, &state->coordinator.waiting);
    STORE_32LE(coordinator->nextHardSync, 0, &state->coordinator.nextHardSync);
    for (i = 0; i < 4; ++i) {
      STORE_16LE(coordinator->multiData[i], 0, &state->coordinator.multiData[i]);
      STORE_32LE(coordinator->normalData[i], 0, &state->coordinator.normalData[i]);
    }
    flags = GBASIOLockstepSerializedFlagsSetTransferMode(flags, _modeEnumToInt(coordinator->transferMode));
    flags = GBASIOLockstepSerializedFlagsSetTransferActive(flags, coordinator->transferActive);
  }
  MutexUnlock(&lockstep->coordinator->mutex);

  STORE_32LE(flags, 0, &state->flags);
  *stateOut = state;
  *size = sizeof(*state);
}

static void GBASIOLockstepDriverSetMode(struct GBASIODriver* driver, enum GBASIOMode mode) {
  struct GBASIOLockstepDriver* lockstep = (struct GBASIOLockstepDriver*) driver;
  struct GBASIOLockstepCoordinator* coordinator = lockstep->coordinator;
  MutexLock(&coordinator->mutex);
  struct GBASIOLockstepPlayer* player = TableLookup(&coordinator->players, lockstep->lockstepId);
  if (mode != player->mode) {
    mLOG(GBA_SIO, DEBUG, "Switching mode from %d to %d", player->mode, mode);
    player->mode = mode;
    struct GBASIOLockstepEvent event = {
      .type = SIO_EV_MODE_SET,
      .playerId = player->playerId,
      .timestamp = GBASIOLockstepTime(player),
      .mode = mode,
    };
    if (player->playerId == 0) {
      coordinator->transferMode = mode;
      GBASIOLockstepCoordinatorWaitOnPlayers(coordinator, player);
    }
    _setReady(coordinator, player, player->playerId, mode);
    _enqueueEvent(coordinator, &event, TARGET_ALL & ~TARGET(player->playerId));
  }
  MutexUnlock(&coordinator->mutex);
}

static bool GBASIOLockstepDriverHandlesMode(struct GBASIODriver* driver, enum GBASIOMode mode) {
  UNUSED(driver);
  UNUSED(mode);
  return true;
}

static int GBASIOLockstepDriverConnectedDevices(struct GBASIODriver* driver) {
  struct GBASIOLockstepDriver* lockstep = (struct GBASIOLockstepDriver*) driver;
  struct GBASIOLockstepCoordinator* coordinator = lockstep->coordinator;
  if (!lockstep->lockstepId) {
    return 0;
  }
  MutexLock(&coordinator->mutex);
  int attached = coordinator->nAttached - 1;
  MutexUnlock(&coordinator->mutex);
  return attached;
}

static int GBASIOLockstepDriverDeviceId(struct GBASIODriver* driver) {
  struct GBASIOLockstepDriver* lockstep = (struct GBASIOLockstepDriver*) driver;
  struct GBASIOLockstepCoordinator* coordinator = lockstep->coordinator;
  int playerId = 0;
  MutexLock(&coordinator->mutex);
  struct GBASIOLockstepPlayer* player = TableLookup(&coordinator->players, lockstep->lockstepId);
  if (player && player->playerId >= 0) {
    playerId = player->playerId;
  }
  MutexUnlock(&coordinator->mutex);
  return playerId;
}

static uint16_t GBASIOLockstepDriverWriteSIOCNT(struct GBASIODriver* driver, uint16_t value) {
  UNUSED(driver);
  mLOG(GBA_SIO, DEBUG, "Lockstep: SIOCNT <- %04X", value);
  return value;
}

static uint16_t GBASIOLockstepDriverWriteRCNT(struct GBASIODriver* driver, uint16_t value) {
  UNUSED(driver);
  mLOG(GBA_SIO, DEBUG, "Lockstep: RCNT <- %04X", value);
  return value;
}

static bool GBASIOLockstepDriverStart(struct GBASIODriver* driver) {
  struct GBASIOLockstepDriver* lockstep = (struct GBASIOLockstepDriver*) driver;
  struct GBASIOLockstepCoordinator* coordinator = lockstep->coordinator;
  bool ret = false;
  MutexLock(&coordinator->mutex);
  if (coordinator->transferActive) {
    mLOG(GBA_SIO, GAME_ERROR, "Transfer restarted unexpectedly");
    goto out;
  }
  if (coordinator->nAttached < 2) {
    mLOG(GBA_SIO, DEBUG, "Attempted to start transfer with no secondary players");
    goto out;
  }
  struct GBASIOLockstepPlayer* player = TableLookup(&coordinator->players, lockstep->lockstepId);
  if (player->playerId != 0) {
    mLOG(GBA_SIO, DEBUG, "Secondary player attempted to start transfer");
    goto out;
  }
  mLOG(GBA_SIO, DEBUG, "Transfer starting at %08X", coordinator->cycle);
  memset(coordinator->multiData, 0xFF, sizeof(coordinator->multiData));
  _setData(coordinator, 0, player->driver->d.p);

  int32_t timestamp = GBASIOLockstepTime(player);
  struct GBASIOLockstepEvent event = {
    .type = SIO_EV_TRANSFER_START,
    .timestamp = timestamp,
    .finishCycle = timestamp + GBASIOTransferCycles(player->mode, player->driver->d.p->siocnt, coordinator->nAttached - 1),
  };
  _enqueueEvent(coordinator, &event, TARGET_SECONDARY);
  GBASIOLockstepCoordinatorWaitOnPlayers(coordinator, player);
  coordinator->transferActive = true;
  ret = true;
out:
  MutexUnlock(&coordinator->mutex);
  return ret;
}

static void GBASIOLockstepDriverFinishMultiplayer(struct GBASIODriver* driver, uint16_t data[4]) {
  struct GBASIOLockstepDriver* lockstep = (struct GBASIOLockstepDriver*) driver;
  struct GBASIOLockstepCoordinator* coordinator = lockstep->coordinator;
  MutexLock(&coordinator->mutex);
  if (coordinator->transferMode == GBA_SIO_MULTI) {
    struct GBASIOLockstepPlayer* player = TableLookup(&coordinator->players, lockstep->lockstepId);
    if (!player->dataReceived) {
      mLOG(GBA_SIO, WARN, "MULTI did not receive data. Are we running behind?");
      memset(data, 0xFF, sizeof(uint16_t) * 4);
    } else {
      mLOG(GBA_SIO, DEBUG, "MULTI transfer finished: %04X %04X %04X %04X",
           coordinator->multiData[0],
           coordinator->multiData[1],
           coordinator->multiData[2],
           coordinator->multiData[3]);
      memcpy(data, coordinator->multiData, sizeof(uint16_t) * 4);
    }
    player->dataReceived = false;
    if (player->playerId == 0) {
      _hardSync(coordinator, player);
    }
  }
  MutexUnlock(&coordinator->mutex);
}

static uint8_t GBASIOLockstepDriverFinishNormal8(struct GBASIODriver* driver) {
  struct GBASIOLockstepDriver* lockstep = (struct GBASIOLockstepDriver*) driver;
  struct GBASIOLockstepCoordinator* coordinator = lockstep->coordinator;
  uint8_t data = 0xFF;
  MutexLock(&coordinator->mutex);
  if (coordinator->transferMode == GBA_SIO_NORMAL_8) {
    struct GBASIOLockstepPlayer* player = TableLookup(&coordinator->players, lockstep->lockstepId);
    if (player->playerId > 0) {
      if (!player->dataReceived) {
        mLOG(GBA_SIO, WARN, "NORMAL did not receive data. Are we running behind?");
      } else {
        data = coordinator->normalData[player->playerId - 1];
        mLOG(GBA_SIO, DEBUG, "NORMAL8 transfer finished: %02X", data);
      }
    }
    player->dataReceived = false;
    if (player->playerId == 0) {
      _hardSync(coordinator, player);
    }
  }
  MutexUnlock(&coordinator->mutex);
  return data;
}

static uint32_t GBASIOLockstepDriverFinishNormal32(struct GBASIODriver* driver) {
  struct GBASIOLockstepDriver* lockstep = (struct GBASIOLockstepDriver*) driver;
  struct GBASIOLockstepCoordinator* coordinator = lockstep->coordinator;
  uint32_t data = 0xFFFFFFFF;
  MutexLock(&coordinator->mutex);
  if (coordinator->transferMode == GBA_SIO_NORMAL_32) {
    struct GBASIOLockstepPlayer* player = TableLookup(&coordinator->players, lockstep->lockstepId);
    if (player->playerId > 0) {
      if (!player->dataReceived) {
        mLOG(GBA_SIO, WARN, "Did not receive data. Are we running behind?");
      } else {
        data = coordinator->normalData[player->playerId - 1];
        mLOG(GBA_SIO, DEBUG, "NORMAL32 transfer finished: %08X", data);
      }
    }
    player->dataReceived = false;
    if (player->playerId == 0) {
      _hardSync(coordinator, player);
    }
  }
  MutexUnlock(&coordinator->mutex);
  return data;
}

void GBASIOLockstepCoordinatorInit(struct GBASIOLockstepCoordinator* coordinator) {
  memset(coordinator, 0, sizeof(*coordinator));
  MutexInit(&coordinator->mutex);
  TableInit(&coordinator->players, 8, free);
}

void GBASIOLockstepCoordinatorDeinit(struct GBASIOLockstepCoordinator* coordinator) {
  MutexDeinit(&coordinator->mutex);
  TableDeinit(&coordinator->players);
}

void GBASIOLockstepCoordinatorAttach(struct GBASIOLockstepCoordinator* coordinator, struct GBASIOLockstepDriver* driver) {
  if (driver->coordinator && driver->coordinator != coordinator) {
    // TODO
    abort();
  }
  driver->coordinator = coordinator;
}

void GBASIOLockstepCoordinatorDetach(struct GBASIOLockstepCoordinator* coordinator, struct GBASIOLockstepDriver* driver) {
  if (driver->coordinator != coordinator) {
    // TODO
    abort();
    return;
  }
  MutexLock(&coordinator->mutex);
  struct GBASIOLockstepPlayer* player = TableLookup(&coordinator->players, driver->lockstepId);
  if (player) {
    _removePlayer(coordinator, player);
  }
  MutexUnlock(&coordinator->mutex);
  driver->coordinator = NULL;
}

int32_t _untilNextSync(struct GBASIOLockstepCoordinator* coordinator, struct GBASIOLockstepPlayer* player) {
  int32_t cycle = coordinator->cycle - GBASIOLockstepTime(player);
  if (player->playerId == 0) {
    if (coordinator->nAttached < 2) {
      cycle += UNLOCKED_INTERVAL;
    } else {
      cycle += LOCKSTEP_INTERVAL;
    }
  }
  return cycle;
}

void _advanceCycle(struct GBASIOLockstepCoordinator* coordinator, struct GBASIOLockstepPlayer* player) {
  int32_t newCycle = GBASIOLockstepTime(player);
  mASSERT_DEBUG(newCycle - coordinator->cycle >= 0);
  coordinator->nextHardSync -= newCycle - coordinator->cycle;
  coordinator->cycle = newCycle;
}

void _removePlayer(struct GBASIOLockstepCoordinator* coordinator, struct GBASIOLockstepPlayer* player) {
  struct GBASIOLockstepEvent event = {
    .type = SIO_EV_DETACH,
    .playerId = player->playerId,
    .timestamp = GBASIOLockstepTime(player),
  };
  _enqueueEvent(coordinator, &event, TARGET_ALL & ~TARGET(player->playerId));

  coordinator->waiting = 0;
  coordinator->transferActive = false;

  TableRemove(&coordinator->players, player->driver->lockstepId);
  _reconfigPlayers(coordinator);

  struct GBASIOLockstepPlayer* runner = TableLookup(&coordinator->players, coordinator->attachedPlayers[0]);
  if (runner) {
    GBASIOLockstepPlayerWake(runner);
  }
  _verifyAwake(coordinator);
}

void _reconfigPlayers(struct GBASIOLockstepCoordinator* coordinator) {
  size_t players = TableSize(&coordinator->players);
  memset(coordinator->attachedPlayers, 0, sizeof(coordinator->attachedPlayers));
  if (players == 0) {
    mLOG(GBA_SIO, WARN, "Reconfiguring player IDs with no players attached somehow?");
  } else if (players == 1) {
    struct TableIterator iter;
    mASSERT_LOG(GBA_SIO, TableIteratorStart(&coordinator->players, &iter), "Trying to reconfigure 1 player with empty player list");
    unsigned p0 = TableIteratorGetKey(&coordinator->players, &iter);
    coordinator->attachedPlayers[0] = p0;

    struct GBASIOLockstepPlayer* player = TableIteratorGetValue(&coordinator->players, &iter);
    coordinator->cycle = mTimingCurrentTime(&player->driver->d.p->p->timing);
    coordinator->nextHardSync = HARD_SYNC_INTERVAL;

    if (player->playerId != 0) {
      player->playerId = 0;
      if (player->driver->user->playerIdChanged) {
        player->driver->user->playerIdChanged(player->driver->user, player->playerId);
      }
    }

    if (!coordinator->transferActive) {
      coordinator->transferMode = player->mode;
    }
  } else {
    struct UIntList playerPreferences[MAX_GBAS];

    int i;
    for (i = 0; i < MAX_GBAS; ++i) {
      UIntListInit(&playerPreferences[i], 4);
    }

    // Collect the first four players' requested player IDs so we can sort through them later
    int seen = 0;
    struct TableIterator iter;
    mASSERT_LOG(GBA_SIO, TableIteratorStart(&coordinator->players, &iter), "Trying to reconfigure %" PRIz "u players with empty player list", players);
    do {
      unsigned pid = TableIteratorGetKey(&coordinator->players, &iter);
      struct GBASIOLockstepPlayer* player = TableIteratorGetValue(&coordinator->players, &iter);
      int requested = MAX_GBAS - 1;
      if (player->driver->user->requestedId) {
        requested = player->driver->user->requestedId(player->driver->user);
      }
      if (requested < 0) {
        continue;
      }
      if (requested >= MAX_GBAS) {
        requested = MAX_GBAS - 1;
      }

      *UIntListAppend(&playerPreferences[requested]) = pid;
      ++seen;
    } while (TableIteratorNext(&coordinator->players, &iter) && seen < MAX_GBAS);

    // Now sort each requested player ID to figure out who gets which ID
    seen = 0;
    for (i = 0; i < MAX_GBAS; ++i) {
      int j;
      for (j = 0; j <= i; ++j) {
        while (UIntListSize(&playerPreferences[j]) && seen < MAX_GBAS) {
          unsigned pid = *UIntListGetPointer(&playerPreferences[j], 0);
          UIntListShift(&playerPreferences[j], 0, 1);
          struct GBASIOLockstepPlayer* player = TableLookup(&coordinator->players, pid);
          if (!player) {
            mLOG(GBA_SIO, ERROR, "Player list appears to have changed unexpectedly. PID %u missing.", pid);
            continue;
          }
          coordinator->attachedPlayers[seen] = pid;
          if (player->playerId != seen) {
            player->playerId = seen;
            if (player->driver->user->playerIdChanged) {
              player->driver->user->playerIdChanged(player->driver->user, player->playerId);
            }
          }
          ++seen;
        }
      }
    }

    for (i = 0; i < MAX_GBAS; ++i) {
      UIntListDeinit(&playerPreferences[i]);
    }
  }

  int nAttached = 0;
  size_t i;
  for (i = 0; i < MAX_GBAS; ++i) {
    unsigned pid = coordinator->attachedPlayers[i];
    if (!pid) {
      continue;
    }
    struct GBASIOLockstepPlayer* player = TableLookup(&coordinator->players, pid);
    if (!player) {
      coordinator->attachedPlayers[i] = 0;
    } else {
      ++nAttached;
    }
  }
  coordinator->nAttached = nAttached;
}

static void _setData(struct GBASIOLockstepCoordinator* coordinator, uint32_t id, struct GBASIO* sio) {
  switch (coordinator->transferMode) {
  case GBA_SIO_MULTI:
    coordinator->multiData[id] = sio->p->memory.io[GBA_REG(SIOMLT_SEND)];
    break;
  case GBA_SIO_NORMAL_8:
    coordinator->normalData[id] = sio->p->memory.io[GBA_REG(SIODATA8)];
    break;
  case GBA_SIO_NORMAL_32:
    coordinator->normalData[id] = sio->p->memory.io[GBA_REG(SIODATA32_LO)];
    coordinator->normalData[id] |= sio->p->memory.io[GBA_REG(SIODATA32_HI)] << 16;
    break;
  case GBA_SIO_UART:
  case GBA_SIO_GPIO:
  case GBA_SIO_JOYBUS:
    mLOG(GBA_SIO, WARN, "Unsupported mode %i in lockstep", coordinator->transferMode);
    // TODO: Should we handle this or just abort?
    break;
  }
}

void _setReady(struct GBASIOLockstepCoordinator* coordinator, struct GBASIOLockstepPlayer* activePlayer, int playerId, enum GBASIOMode mode) {
  activePlayer->otherModes[playerId] = mode;
  bool ready = true;
  int i;
  for (i = 0; ready && i < coordinator->nAttached; ++i) {
    ready = activePlayer->otherModes[i] == activePlayer->mode;
  }
  if (activePlayer->mode == GBA_SIO_MULTI) {
    struct GBASIO* sio = activePlayer->driver->d.p;
    sio->siocnt = GBASIOMultiplayerSetReady(sio->siocnt, ready);
    sio->rcnt = GBASIORegisterRCNTSetSd(sio->rcnt, ready);
  }
}

void _hardSync(struct GBASIOLockstepCoordinator* coordinator, struct GBASIOLockstepPlayer* player) {
  mASSERT_DEBUG(player->playerId == 0);
  struct GBASIOLockstepEvent event = {
    .type = SIO_EV_HARD_SYNC,
    .playerId = 0,
    .timestamp = GBASIOLockstepTime(player),
  };
  _enqueueEvent(coordinator, &event, TARGET_SECONDARY);
  GBASIOLockstepCoordinatorWaitOnPlayers(coordinator, player);
}

void _enqueueEvent(struct GBASIOLockstepCoordinator* coordinator, const struct GBASIOLockstepEvent* event, uint32_t target) {
  mLOG(GBA_SIO, DEBUG, "Enqueuing event of type %X from %i for target %X at timestamp %X",
                        event->type, event->playerId, target, event->timestamp);

  int i;
  for (i = 0; i < coordinator->nAttached; ++i) {
    if (!(target & TARGET(i))) {
      continue;
    }
    struct GBASIOLockstepPlayer* player = TableLookup(&coordinator->players, coordinator->attachedPlayers[i]);
    mASSERT_LOG(GBA_SIO, player->freeList, "No free events");
    struct GBASIOLockstepEvent* newEvent = player->freeList;
    player->freeList = newEvent->next;

    memcpy(newEvent, event, sizeof(*event));
    struct GBASIOLockstepEvent** previous = &player->queue;
    struct GBASIOLockstepEvent* next = player->queue;
    while (next) {
      int32_t until = newEvent->timestamp - next->timestamp;
      if (until < 0) {
        break;
      }
      previous = &next->next;
      next = next->next;
    }
    newEvent->next = next;
    *previous = newEvent;
  }
}

void _lockstepEvent(struct mTiming* timing, void* context, uint32_t cyclesLate) {
  struct GBASIOLockstepDriver* lockstep = context;
  struct GBASIOLockstepCoordinator* coordinator = lockstep->coordinator;
  MutexLock(&coordinator->mutex);
  struct GBASIOLockstepPlayer* player = TableLookup(&coordinator->players, lockstep->lockstepId);
  struct GBASIO* sio = player->driver->d.p;
  mASSERT_LOG(GBA_SIO, player->playerId >= 0 && player->playerId < 4, "Invalid multiplayer ID %i", player->playerId);

  bool wasDetach = false;
  if (player->queue && player->queue->type == SIO_EV_DETACH) {
    mLOG(GBA_SIO, DEBUG, "Player %i detached at timestamp %X, picking up the pieces",
                          player->queue->playerId, player->queue->timestamp);
    wasDetach = true;
  }
  if (player->playerId == 0 && GBASIOLockstepTime(player) - coordinator->cycle >= 0) {
    // We are the clock owner; advance the shared clock. However, if we just became
    // the clock owner (by the previous one disconnecting) we might be slightly
    // behind the shared clock. We should wait a bit if needed in that case.
    _advanceCycle(coordinator, player);
    if (!coordinator->transferActive) {
      GBASIOLockstepCoordinatorWakePlayers(coordinator);
    }
    if (coordinator->nextHardSync < 0) {
      if (!coordinator->waiting) {
        _hardSync(coordinator, player);
      }
      coordinator->nextHardSync += HARD_SYNC_INTERVAL;
    }
  }

  int32_t nextEvent = _untilNextSync(coordinator, player);
  while (true) {
    struct GBASIOLockstepEvent* event = player->queue;
    if (!event) {
      break;
    }
    if (event->timestamp > GBASIOLockstepTime(player)) {
      break;
    }
    player->queue = event->next;
    struct GBASIOLockstepEvent reply = {
      .playerId = player->playerId,
      .timestamp = GBASIOLockstepTime(player),
    };
    mLOG(GBA_SIO, DEBUG, "Got event of type %X from %i at timestamp %X",
                          event->type, event->playerId, event->timestamp);
    switch (event->type) {
    case SIO_EV_ATTACH:
      _setReady(coordinator, player, event->playerId, -1);
      if (player->playerId == 0) {
        struct GBASIO* sio = player->driver->d.p;
        sio->siocnt = GBASIOMultiplayerClearSlave(sio->siocnt);
      }
      reply.mode = player->mode;
      reply.type = SIO_EV_MODE_SET;
      _enqueueEvent(coordinator, &reply, TARGET(event->playerId));
      break;
    case SIO_EV_HARD_SYNC:
      GBASIOLockstepCoordinatorAckPlayer(coordinator, player);
      break;
    case SIO_EV_TRANSFER_START:
      _setData(coordinator, player->playerId, sio);
      nextEvent = event->finishCycle - GBASIOLockstepTime(player) - cyclesLate;
      player->driver->d.p->siocnt |= 0x80;
      mTimingDeschedule(&sio->p->timing, &sio->completeEvent);
      mTimingSchedule(&sio->p->timing, &sio->completeEvent, nextEvent);
      GBASIOLockstepCoordinatorAckPlayer(coordinator, player);
      break;
    case SIO_EV_MODE_SET:
      if (coordinator->transferActive && player->mode != event->mode) {
        mLOG(GBA_SIO, DEBUG, "Switching modes while transfer is active");
        _abortTransfer(coordinator, player);
      }
      _setReady(coordinator, player, event->playerId, event->mode);
      if (event->playerId == 0) {
        GBASIOLockstepCoordinatorAckPlayer(coordinator, player);
      }
      break;
    case SIO_EV_DETACH:
      _setReady(coordinator, player, event->playerId, -1);
      _setReady(coordinator, player, player->playerId, player->mode);
      reply.mode = player->mode;
      reply.type = SIO_EV_MODE_SET;
      _enqueueEvent(coordinator, &reply, ~TARGET(event->playerId));
      if (player->mode == GBA_SIO_MULTI) {
        sio->siocnt = GBASIOMultiplayerSetId(sio->siocnt, player->playerId);
        sio->siocnt = GBASIOMultiplayerSetSlave(sio->siocnt, player->playerId || coordinator->nAttached < 2);
      }
      wasDetach = true;
      break;
    }
    event->next = player->freeList;
    player->freeList = event;
  }
  if (player->queue && player->queue->timestamp - GBASIOLockstepTime(player) < nextEvent) {
    nextEvent = player->queue->timestamp - GBASIOLockstepTime(player);
  }

  if (player->playerId != 0 && nextEvent <= LOCKSTEP_INTERVAL) {
    if (!player->queue || wasDetach) {
      GBASIOLockstepPlayerSleep(player);
      // XXX: Is there a better way to gain sync lock at the beginning?
      if (nextEvent < 4) {
        nextEvent = 4;
      }
      _verifyAwake(coordinator);
    }
  }
  MutexUnlock(&coordinator->mutex);

  mASSERT_DEBUG(nextEvent > 0);
  mTimingSchedule(timing, &lockstep->event, nextEvent);
}

int32_t GBASIOLockstepTime(struct GBASIOLockstepPlayer* player) {
  return mTimingCurrentTime(&player->driver->d.p->p->timing) - player->cycleOffset;
}

void GBASIOLockstepCoordinatorWaitOnPlayers(struct GBASIOLockstepCoordinator* coordinator, struct GBASIOLockstepPlayer* player) {
  mASSERT_LOG(GBA_SIO, !coordinator->waiting, "Multiplayer desynchronized: coordinator still waiting");
  mASSERT_LOG(GBA_SIO, !player->asleep, "Multiplayer desynchronized: player asleep");
  mASSERT_LOG(GBA_SIO, player->playerId == 0, "Multiplayer desynchronized: invalid player %i attempting to coordinate", player->playerId);
  if (coordinator->nAttached < 2) {
    return;
  }

  _advanceCycle(coordinator, player);
  mLOG(GBA_SIO, DEBUG, "Primary waiting for players to ack");
  coordinator->waiting = ((1 << coordinator->nAttached) - 1) & ~TARGET(player->playerId);
  GBASIOLockstepPlayerSleep(player);
  GBASIOLockstepCoordinatorWakePlayers(coordinator);

  _verifyAwake(coordinator);
}

void GBASIOLockstepCoordinatorWakePlayers(struct GBASIOLockstepCoordinator* coordinator) {
  int i;
  for (i = 1; i < coordinator->nAttached; ++i) {
    if (!coordinator->attachedPlayers[i]) {
      continue;
    }
    struct GBASIOLockstepPlayer* player = TableLookup(&coordinator->players, coordinator->attachedPlayers[i]);
    GBASIOLockstepPlayerWake(player);
  }
}

void GBASIOLockstepPlayerWake(struct GBASIOLockstepPlayer* player) {
  if (!player->asleep) {
    return;
  }
  player->asleep = false;
  player->driver->user->wake(player->driver->user);
}

void GBASIOLockstepCoordinatorAckPlayer(struct GBASIOLockstepCoordinator* coordinator, struct GBASIOLockstepPlayer* player) {
  if (player->playerId == 0) {
    return;
  }
  coordinator->waiting &= ~TARGET(player->playerId);
  if (!coordinator->waiting) {
    mLOG(GBA_SIO, DEBUG, "All players acked, waking primary");
    if (coordinator->transferActive) {
      int i;
      for (i = 0; i < coordinator->nAttached; ++i) {
        if (!coordinator->attachedPlayers[i]) {
          continue;
        }
        struct GBASIOLockstepPlayer* player = TableLookup(&coordinator->players, coordinator->attachedPlayers[i]);
        player->dataReceived = true;
      }

      coordinator->transferActive = false;
    }

    struct GBASIOLockstepPlayer* runner = TableLookup(&coordinator->players, coordinator->attachedPlayers[0]);
    GBASIOLockstepPlayerWake(runner);
  }
  GBASIOLockstepPlayerSleep(player);
}

void GBASIOLockstepPlayerSleep(struct GBASIOLockstepPlayer* player) {
  if (player->asleep) {
    return;
  }
  player->asleep = true;
  player->driver->user->sleep(player->driver->user);
  player->driver->d.p->p->cpu->nextEvent = 0;
  GBAInterrupt(player->driver->d.p->p);
}

size_t GBASIOLockstepCoordinatorAttached(struct GBASIOLockstepCoordinator* coordinator) {
  size_t count;
  MutexLock(&coordinator->mutex);
  count = TableSize(&coordinator->players);
  MutexUnlock(&coordinator->mutex);
  return count;
}
// ---- END rewritten from reference implementation/lockstep.c ----
#if defined(__cplusplus)
}  // extern "C"
#endif
