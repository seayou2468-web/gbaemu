#include "../gba_core.h"
#include <algorithm>
#include <cstring>

namespace gba {

void GBACore::StepTimers(uint32_t cycles) {
  for (int i = 0; i < 4; ++i) {
    TimerState& t = timers_[i];
    uint16_t cnt_h = ReadIO16(0x04000102 + i * 4);
    if (cnt_h & (1 << 7)) { // Timer enabled
      if (!(cnt_h & (1 << 2))) { // Not Cascade mode
        static constexpr uint16_t prescaler_masks[] = {0, 6, 8, 10};
        uint16_t mask = prescaler_masks[cnt_h & 3];
        t.prescaler_accum += cycles;
        while (t.prescaler_accum >= (1 << mask)) {
          t.prescaler_accum -= (1 << mask);
          t.counter++;
          if (t.counter == 0) { // Overflow
            t.counter = t.reload;
            if (cnt_h & (1 << 6)) RaiseInterrupt(1 << (3 + i)); // Timer IRQ
            if (i < 3 && (ReadIO16(0x04000102 + (i + 1) * 4) & (1 << 2))) { // Cascade next timer
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
    uint16_t cnt_h = ReadIO16(0x040000BA + i * 12);
    if ((cnt_h & (1 << 15)) && ((cnt_h >> 12) & 3) == 0) { // Immediate start
      ExecuteDmaTransfer(i, cnt_h);
    }
  }
}

void GBACore::StepDmaVBlank() {
  for (int i = 0; i < 4; ++i) {
    uint16_t cnt_h = ReadIO16(0x040000BA + i * 12);
    if ((cnt_h & (1 << 15)) && ((cnt_h >> 12) & 3) == 1) { // VBlank start
      ExecuteDmaTransfer(i, cnt_h);
    }
  }
}

void GBACore::StepDmaHBlank() {
  for (int i = 0; i < 4; ++i) {
    uint16_t cnt_h = ReadIO16(0x040000BA + i * 12);
    if ((cnt_h & (1 << 15)) && ((cnt_h >> 12) & 3) == 2) { // HBlank start
      ExecuteDmaTransfer(i, cnt_h);
    }
  }
}

void GBACore::ExecuteDmaTransfer(int ch, uint16_t cnt_h) {
  uint32_t src = *reinterpret_cast<const uint32_t*>(&io_regs_[0x0B0 + ch * 12]);
  uint32_t dst = *reinterpret_cast<const uint32_t*>(&io_regs_[0x0B4 + ch * 12]);
  uint16_t count = *reinterpret_cast<const uint16_t*>(&io_regs_[0x0B8 + ch * 12]);
  if (count == 0) count = (ch == 3) ? 0x4000 : 0x10000;

  bool bit32 = (cnt_h >> 10) & 1;
  int step_src = (cnt_h >> 7) & 3; // 0=inc, 1=dec, 2=fixed, 3=forbidden
  int step_dst = (cnt_h >> 5) & 3; // 0=inc, 1=dec, 2=fixed, 3=inc/reload

  uint32_t unit = bit32 ? 4 : 2;

  for (int i = 0; i < count; ++i) {
    if (bit32) Write32(dst, Read32(src));
    else Write16(dst, Read16(src));

    if (step_src == 0) src += unit; else if (step_src == 1) src -= unit;
    if (step_dst == 0 || step_dst == 3) dst += unit; else if (step_dst == 1) dst -= unit;
  }

  if (!(cnt_h & (1 << 9))) { // Repeat off
    WriteIO16(0x040000BA + ch * 12, cnt_h & ~(1 << 15)); // Disable DMA
  }
  if (cnt_h & (1 << 14)) RaiseInterrupt(1 << (8 + ch)); // DMA IRQ
}

} // namespace gba
