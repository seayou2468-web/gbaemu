#include "../gba_core.h"
#include <algorithm>
#include <cstring>

namespace gba {

void GBACore::StepPpu(uint32_t cycles) {
  ppu_cycle_accum_ += cycles;

  uint16_t dispstat = ReadIO16(0x04000004);
  uint16_t vcount = ReadIO16(0x04000006);

  while (ppu_cycle_accum_ >= kCyclesPerScanline) {
    ppu_cycle_accum_ -= kCyclesPerScanline;
    vcount++;
    if (vcount >= kTotalScanlines) vcount = 0;

    // HBlank = 0 at start of scanline
    dispstat &= ~(1 << 1);

    // Update dispstat based on vcount
    if (vcount < kVisibleScanlines) {
      dispstat &= ~(1 << 0); // VBlank = 0
      // Draw scanline if needed
      // (Renderer calls would be here)
    } else {
      dispstat |= (1 << 0); // VBlank = 1
      if (vcount == kVisibleScanlines) {
        RaiseInterrupt(1 << 0); // VBlank IRQ
        StepDmaVBlank();
      }
    }

    // HBlank starts later in scanline, but simplified here
    // In GBA: HDRAW (1006 cycles), HBLANK (226 cycles)
    // For now, trigger HBlank IRQ / DMA at start of scanline for simplicity
    RaiseInterrupt(1 << 1);
    StepDmaHBlank();

    // VCount Match
    uint16_t vcount_setting = (dispstat >> 8) & 0xFF;
    if (vcount == vcount_setting) {
      dispstat |= (1 << 2);
      if (dispstat & (1 << 5)) RaiseInterrupt(1 << 2);
    } else {
      dispstat &= ~(1 << 2);
    }

    WriteIO16(0x04000006, vcount);
    WriteIO16(0x04000004, dispstat);

    // Mode specific frame rendering at start of VBlank
    if (vcount == kVisibleScanlines) {
        uint16_t dispcnt = ReadIO16(0x04000000);
        uint8_t mode = dispcnt & 7;
        switch (mode) {
            case 0: RenderMode0Frame(); break;
            case 1: RenderMode1Frame(); break;
            case 2: RenderMode2Frame(); break;
            case 3: RenderMode3Frame(); break;
            case 4: RenderMode4Frame(); break;
            case 5: RenderMode5Frame(); break;
            default: break;
        }
    }
  }
}

} // namespace gba
