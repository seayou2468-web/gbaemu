import sys
import re

path = "src/core/gba_core_modules/timing_dma.mm"
with open(path, "r") as f:
    content = f.read()

def replace_func(c, name, body):
    pattern = rf"void GBACore::{name}\(uint32_t cycles\) \{{.*?^}}"
    return re.sub(pattern, body, c, flags=re.DOTALL | re.MULTILINE)

# 1. Refined StepPpu with cycle-precise IRQ and correct sign extension
step_ppu_body = """void GBACore::StepPpu(uint32_t cycles) {
  constexpr uint32_t kHBlankStartCycle = mgba_compat::kVideoHDrawCycles;
  auto read_affine_ref28 = [&](uint32_t addr) -> int32_t {
    // Correct 28-bit sign extension
    const uint32_t v = Read32(addr);
    uint32_t raw28 = v & 0x0FFFFFFFu;
    if (raw28 & 0x08000000u) raw28 |= 0xF0000000u;
    return static_cast<int32_t>(raw28);
  };
  auto capture_affine_refs_for_line = [&](uint16_t vcount) {
    if (vcount >= mgba_compat::kVideoTotalLines) return;
    const size_t li = static_cast<size_t>(vcount);
    if (affine_line_captured_[li] != 0u) return;
    bg2_refx_line_[li] = read_affine_ref28(0x04000028u);
    bg2_refy_line_[li] = read_affine_ref28(0x0400002Cu);
    bg3_refx_line_[li] = read_affine_ref28(0x04000038u);
    bg3_refy_line_[li] = read_affine_ref28(0x0400003Cu);
    affine_line_captured_[li] = 1u;
    affine_line_refs_valid_ = true;
  };
  auto update_vcount_match = [&](uint16_t* dispstat, uint16_t vcount) {
    const uint16_t vcount_compare = (*dispstat >> 8) & 0x00FFu;
    const bool had_match = (*dispstat & 0x0004u) != 0;
    const bool match = (vcount == vcount_compare);
    if (match) {
      *dispstat |= 0x0004u;
      if (!had_match && (*dispstat & (1u << 5))) {
        RaiseInterrupt(1u << 2);
      }
    } else {
      *dispstat &= ~0x0004u;
    }
  };
  auto write_io_raw16 = [&](uint32_t addr, uint16_t value) {
    const size_t off = static_cast<size_t>(addr - 0x04000000u);
    if (off + 1 < io_regs_.size()) {
      io_regs_[off] = value & 0xFF;
      io_regs_[off + 1] = (value >> 8) & 0xFF;
    }
  };

  uint32_t remaining = cycles;
  while (remaining > 0) {
    uint16_t dispstat = ReadIO16(0x04000004u);
    const uint16_t vcount = ReadIO16(0x04000006u);

    // Determine next interesting cycle boundary
    const bool in_hblank = (dispstat & 2) != 0;
    const uint32_t next_event = in_hblank ? mgba_compat::kVideoScanlineCycles : kHBlankStartCycle;
    const uint32_t dist = (ppu_cycle_accum_ < next_event) ? (next_event - ppu_cycle_accum_) : 1u;
    const uint32_t step = std::min(remaining, dist);

    ppu_cycle_accum_ += step;
    remaining -= step;

    if (ppu_cycle_accum_ >= kHBlankStartCycle && !in_hblank) {
      // Entering HBlank
      dispstat |= 0x0002u;
      if (dispstat & (1u << 4)) RaiseInterrupt(1u << 1);
      write_io_raw16(0x04000004u, dispstat);
      StepDma(); // DMA HBlank trigger
    }

    if (ppu_cycle_accum_ >= mgba_compat::kVideoScanlineCycles) {
      // End of scanline
      ppu_cycle_accum_ = 0;
      const uint16_t next_vcount = (vcount + 1u) % mgba_compat::kVideoTotalLines;
      write_io_raw16(0x04000006u, next_vcount);

      // Update VBlank status
      dispstat &= ~0x0002u; // Exit HBlank
      const bool was_vblank = (dispstat & 1) != 0;
      const bool now_vblank = (next_vcount >= 160 && next_vcount < 227);
      if (now_vblank) {
        dispstat |= 0x0001u;
        if (!was_vblank && (dispstat & (1u << 3))) RaiseInterrupt(1u << 0);
        if (!was_vblank) StepDma(); // DMA VBlank trigger
      } else {
        dispstat &= ~0x0001u;
      }

      update_vcount_match(&dispstat, next_vcount);
      write_io_raw16(0x04000004u, dispstat);
      capture_affine_refs_for_line(next_vcount);
    }
  }
}"""

content = replace_func(content, "StepPpu", step_ppu_body)
with open(path, "w") as f:
    f.write(content)
