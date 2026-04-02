#include "../gba_core.h"

namespace gba {

void GBACore::BuildObjWindowMask() {}
void GBACore::RenderSprites() {}
void GBACore::ApplyColorEffects() {}

namespace {
constexpr uint32_t kVideoHBlankCycles =
    mgba_compat::kVideoScanlineCycles - mgba_compat::kVideoHDrawCycles;
}  // namespace

void GBACore::StepPpu(uint32_t cycles) {
  ppu_cycle_accum_ += cycles;

  while (true) {
    uint16_t dispstat = ReadIO16(0x04000004u);
    const bool in_hblank = (dispstat & 0x2u) != 0;
    const uint32_t phase_cycles = in_hblank ? kVideoHBlankCycles : mgba_compat::kVideoHDrawCycles;
    if (ppu_cycle_accum_ < phase_cycles) {
      break;
    }
    ppu_cycle_accum_ -= phase_cycles;

    if (!in_hblank) {
      // HBlank開始
      dispstat = static_cast<uint16_t>(dispstat | 0x2u);
      WriteIO16(0x04000004u, dispstat);
      if (dispstat & (1u << 4)) RaiseInterrupt(1u << 1);  // HBlank IRQ

      const uint16_t vcount = ReadIO16(0x04000006u);
      if (vcount < mgba_compat::kVideoVisibleLines) {
        StepDmaHBlank(kVideoHBlankCycles);
      }
      continue;
    }

    // HDraw開始（次ライン）
    dispstat = static_cast<uint16_t>(dispstat & ~0x2u);
    uint16_t vcount = static_cast<uint16_t>((ReadIO16(0x04000006u) + 1) % mgba_compat::kVideoTotalLines);
    WriteIO16(0x04000006u, vcount);

    if (vcount == mgba_compat::kVideoVisibleLines) {
      dispstat = static_cast<uint16_t>(dispstat | 0x1u);
      StepDmaVBlank(mgba_compat::kVideoHDrawCycles);
      if (dispstat & (1u << 3)) RaiseInterrupt(1u << 0);  // VBlank IRQ
      const uint16_t dispcnt = ReadIO16(0x04000000u);
      switch (dispcnt & 0x7u) {
        case 0: RenderMode0Frame(); break;
        case 1: RenderMode1Frame(); break;
        case 2: RenderMode2Frame(); break;
        case 3: RenderMode3Frame(); break;
        case 4: RenderMode4Frame(); break;
        case 5: RenderMode5Frame(); break;
        default: RenderDebugFrame(); break;
      }
      frame_rendered_in_vblank_ = true;
    } else if (vcount == 0) {
      dispstat = static_cast<uint16_t>(dispstat & ~0x1u);
      frame_rendered_in_vblank_ = false;
      ++frame_count_;
    }

    const uint16_t lyc = static_cast<uint16_t>((dispstat >> 8) & 0xFFu);
    if (vcount == lyc) {
      dispstat = static_cast<uint16_t>(dispstat | 0x4u);
      if (dispstat & (1u << 5)) RaiseInterrupt(1u << 2);  // VCounter IRQ
    } else {
      dispstat = static_cast<uint16_t>(dispstat & ~0x4u);
    }

    WriteIO16(0x04000004u, dispstat);
  }
}

}  // namespace gba
