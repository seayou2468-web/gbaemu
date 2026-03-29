import sys
import re

path = "src/core/gba_core_modules/timing_dma.mm"
with open(path, "r") as f:
    content = f.read()

# Current StepPpu might be advancing ppu_cycle_accum_ too much without updating DISPSTAT
# for polling loops. Let's make it more granular.

step_ppu_granular = """void GBACore::StepPpu(uint32_t cycles) {
  constexpr uint32_t kHDrawCycles = mgba_compat::kVideoHDrawCycles;
  constexpr uint32_t kScanlineCycles = mgba_compat::kVideoScanlineCycles;

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

    const bool in_hblank = (dispstat & 2) != 0;
    const uint32_t next_event = in_hblank ? kScanlineCycles : kHDrawCycles;

    // Crucial: Step must NOT be larger than remaining cycles to maintain sync with CPU polling
    uint32_t dist = (ppu_cycle_accum_ < next_event) ? (next_event - ppu_cycle_accum_) : 1u;
    uint32_t step = std::min(remaining, dist);

    ppu_cycle_accum_ += step;
    remaining -= step;

    if (ppu_cycle_accum_ >= kHDrawCycles && !in_hblank) {
      dispstat |= 0x0002u;
      if (dispstat & (1u << 4)) RaiseInterrupt(1u << 1);
      write_io_raw16(0x04000004u, dispstat);
      StepDma();
    }

    if (ppu_cycle_accum_ >= kScanlineCycles) {
      ppu_cycle_accum_ = 0;
      const uint16_t next_vcount = (vcount + 1u) % mgba_compat::kVideoTotalLines;
      write_io_raw16(0x04000006u, next_vcount);

      dispstat &= ~0x0002u;
      const bool was_vblank = (dispstat & 1) != 0;
      const bool now_vblank = (next_vcount >= 160 && next_vcount < 227);

      if (now_vblank) {
        dispstat |= 0x0001u;
        if (!was_vblank && (dispstat & (1u << 3))) RaiseInterrupt(1u << 0);
        write_io_raw16(0x04000004u, dispstat);
        if (!was_vblank) StepDma();
      } else {
        dispstat &= ~0x0001u;
        write_io_raw16(0x04000004u, dispstat);
      }

      const uint16_t vcount_compare = (dispstat >> 8) & 0x00FFu;
      if (next_vcount == vcount_compare) {
        if (!(dispstat & 0x0004u) && (dispstat & (1u << 5))) RaiseInterrupt(1u << 2);
        dispstat |= 0x0004u;
      } else {
        dispstat &= ~0x0004u;
      }
      write_io_raw16(0x04000004u, dispstat);

      if (next_vcount < mgba_compat::kVideoTotalLines) {
        auto rb28 = [&](uint32_t addr) {
          uint32_t r = Read32(addr) & 0x0FFFFFFFu;
          return static_cast<int32_t>(r << 4) >> 4;
        };
        bg2_refx_line_[next_vcount] = rb28(0x04000028u);
        bg2_refy_line_[next_vcount] = rb28(0x0400002Cu);
        bg3_refx_line_[next_vcount] = rb28(0x04000038u);
        bg3_refy_line_[next_vcount] = rb28(0x0400003Cu);
        affine_line_captured_[next_vcount] = 1;
        affine_line_refs_valid_ = true;
      }
    }
  }
}"""

content = re.sub(r"void GBACore::StepPpu\(uint32_t cycles\) \{.*?^\}", step_ppu_granular, content, flags=re.DOTALL | re.MULTILINE)
with open(path, "w") as f:
    f.write(content)
