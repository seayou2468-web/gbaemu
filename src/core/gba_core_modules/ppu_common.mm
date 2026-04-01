#include "../gba_core.h"
#include <algorithm>
#include <cstring>
#include <vector>

namespace gba {

void GBACore::StepPpu(uint32_t cycles) {
  ppu_cycle_accum_ += cycles;

  uint16_t dispstat = ReadIO16(0x04000004);
  uint16_t vcount = ReadIO16(0x04000006);

  while (ppu_cycle_accum_ >= kCyclesPerScanline) {
    ppu_cycle_accum_ -= kCyclesPerScanline;
    vcount++;
    if (vcount >= kTotalScanlines) vcount = 0;

    // Update dispstat based on vcount
    if (vcount < kVisibleScanlines) {
      dispstat &= ~(1 << 0); // VBlank = 0
    } else {
      dispstat |= (1 << 0); // VBlank = 1
      if (vcount == kVisibleScanlines) {
        RaiseInterrupt(1 << 0); // VBlank IRQ
        StepDmaVBlank();
      }
    }

    // HBlank handling inside loop or before?
    // Simplified: Always HBlank IRQ at end of scanline
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

    if (vcount < kVisibleScanlines) {
      // Render the scanline if possible
    }

    if (vcount == kVisibleScanlines) {
      // End of frame, buffer is ready
    }
  }
}

} // namespace gba
