#include "../gba_core.h"
#include <algorithm>
#include <cstring>
#include <vector>

namespace gba {

void GBACore::StepTimers(uint32_t cycles) {
  for (int i = 0; i < 4; ++i) {
    TimerState& t = timers_[i];
    if (t.control & (1 << 7)) { // Timer enabled
      if (!(t.control & (1 << 2))) { // Not Cascade mode
        static constexpr uint16_t prescaler_masks[] = {0, 6, 8, 10}; // 1, 64, 256, 1024
        uint16_t mask = prescaler_masks[t.control & 3];
        t.prescaler_accum += cycles;
        while (t.prescaler_accum >= (1 << mask)) {
          t.prescaler_accum -= (1 << mask);
          t.counter++;
          if (t.counter == 0) { // Overflow
            t.counter = t.reload;
            if (t.control & (1 << 6)) RaiseInterrupt(1 << (3 + i)); // Timer IRQ
            if (i < 3 && (timers_[i + 1].control & (1 << 2))) { // Cascade next timer
              timers_[i+1].counter++;
              if (timers_[i+1].counter == 0) timers_[i+1].counter = timers_[i+1].reload;
            }
          }
        }
      }
    }
  }
}

void GBACore::StepDma() {
  for (int i = 0; i < 4; ++i) {
    DmaState& d = dma_shadows_[i];
    uint16_t cnt_h = ReadIO16(0x040000B2 + i * 12 + 8);
    if (d.active && (cnt_h >> 14) == 0) { // Immediate start
      ExecuteDmaTransfer(i, cnt_h);
    }
  }
}

void GBACore::StepDmaVBlank() {
  for (int i = 0; i < 4; ++i) {
    uint16_t cnt_h = ReadIO16(0x040000B2 + i * 12 + 8);
    if ((cnt_h & (1 << 15)) && ((cnt_h >> 12) & 3) == 1) { // VBlank start
      ExecuteDmaTransfer(i, cnt_h);
    }
  }
}

void GBACore::StepDmaHBlank() {
  for (int i = 0; i < 4; ++i) {
    uint16_t cnt_h = ReadIO16(0x040000B2 + i * 12 + 8);
    if ((cnt_h & (1 << 15)) && ((cnt_h >> 12) & 3) == 2) { // HBlank start
      ExecuteDmaTransfer(i, cnt_h);
    }
  }
}

void GBACore::ExecuteDmaTransfer(int ch, uint16_t cnt_h) {
  // Transfer logic (Source, Dest, Count, Unit Size)
  uint32_t src = Read32(0x040000B0 + ch * 12);
  uint32_t dst = Read32(0x040000B4 + ch * 12);
  uint16_t count = ReadIO16(0x040000B8 + ch * 12);
  if (count == 0) count = (ch == 3) ? 0x4000 : 0x10000;

  bool bit32 = (cnt_h >> 10) & 1;
  int unit = bit32 ? 4 : 2;

  for (int i = 0; i < count; ++i) {
    if (bit32) Write32(dst, Read32(src));
    else Write16(dst, Read16(src));

    // Address increment/decrement logic (cnt_h bits 7-8 and 5-6)
    // ...
    src += unit;
    dst += unit;
  }

  if (!(cnt_h & (1 << 9))) { // Repeat off
    WriteIO16(0x040000BA + ch * 12, cnt_h & ~(1 << 15)); // Disable DMA
  }
  if (cnt_h & (1 << 14)) RaiseInterrupt(1 << (8 + ch)); // DMA IRQ
}

} // namespace gba
