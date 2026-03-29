import sys
import re

path = "src/core/gba_core_modules/timing_dma.mm"
with open(path, "r") as f:
    content = f.read()

def replace_func(c, name, body):
    pattern = rf"void GBACore::{name}\(uint32_t cycles\) \{{.*?^}}"
    return re.sub(pattern, body, c, flags=re.DOTALL | re.MULTILINE)

# 1. Event-based StepPpu
step_ppu_body = """void GBACore::StepPpu(uint32_t cycles) {
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
    const uint32_t distance = (ppu_cycle_accum_ < next_event) ? (next_event - ppu_cycle_accum_) : 1u;
    const uint32_t step = std::min(remaining, distance);

    ppu_cycle_accum_ += step;
    remaining -= step;

    if (ppu_cycle_accum_ >= kHDrawCycles && !in_hblank) {
      // Entering HBlank
      dispstat |= 0x0002u;
      if (dispstat & (1u << 4)) RaiseInterrupt(1u << 1);
      write_io_raw16(0x04000004u, dispstat);
      StepDma(); // DMA HBlank trigger
    }

    if (ppu_cycle_accum_ >= kScanlineCycles) {
      // End of scanline
      ppu_cycle_accum_ -= kScanlineCycles;
      const uint16_t next_vcount = (vcount + 1u) % mgba_compat::kVideoTotalLines;
      write_io_raw16(0x04000006u, next_vcount);

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

      // VCOUNT Compare
      const uint16_t vcount_compare = (dispstat >> 8) & 0x00FFu;
      if (next_vcount == vcount_compare) {
        if (!(dispstat & 0x0004u) && (dispstat & (1u << 5))) RaiseInterrupt(1u << 2);
        dispstat |= 0x0004u;
      } else {
        dispstat &= ~0x0004u;
      }

      write_io_raw16(0x04000004u, dispstat);
      // Capture affine refs for new scanline
      if (next_vcount < mgba_compat::kVideoTotalLines) {
        auto rb28 = [&](uint32_t addr) {
          uint32_t r = Read32(addr) & 0x0FFFFFFFu;
          if (r & 0x08000000u) r |= 0xF0000000u;
          return static_cast<int32_t>(r);
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

# 2. Optimized StepTimers with Sequential Overflows
step_timers_body = """void GBACore::StepTimers(uint32_t cycles) {
  static constexpr uint32_t kPrescalerLut[4] = {1, 64, 256, 1024};
  auto write_timer_raw = [&](size_t i, uint16_t val) {
    const size_t off = 0x100u + i * 4u;
    if (off + 1 < io_regs_.size()) {
      io_regs_[off] = val & 0xFF;
      io_regs_[off + 1] = (val >> 8) & 0xFF;
    }
  };

  uint32_t remaining = cycles;
  while (remaining > 0) {
    // Determine the step to next interesting event (prescaler tick or end of chunk)
    uint32_t step = remaining;
    for (int i = 0; i < 4; ++i) {
      if (!(timers_[i].control & 0x80u) || (i > 0 && (timers_[i].control & 4))) continue;
      const uint32_t prescaler = kPrescalerLut[timers_[i].control & 3];
      const uint32_t to_next = prescaler - (timers_[i].prescaler_accum % prescaler);
      if (to_next < step) step = to_next;
    }

    remaining -= step;
    bool overflowed[4] = {false, false, false, false};

    for (int i = 0; i < 4; ++i) {
      TimerState& t = timers_[i];
      if (!(t.control & 0x80u)) continue;

      if (i > 0 && (t.control & 4)) { // Count-up mode
        if (overflowed[i - 1]) {
          t.counter++;
          if (t.counter == 0) {
            t.counter = t.reload;
            overflowed[i] = true;
            if (t.control & 0x40u) RaiseInterrupt(1u << (3 + i));
            ConsumeAudioFifoOnTimer(i);
          }
          write_timer_raw(i, t.counter);
        }
      } else {
        const uint32_t prescaler = kPrescalerLut[t.control & 3];
        t.prescaler_accum += step;
        while (t.prescaler_accum >= prescaler) {
          t.prescaler_accum -= prescaler;
          t.counter++;
          if (t.counter == 0) {
            t.counter = t.reload;
            overflowed[i] = true;
            if (t.control & 0x40u) RaiseInterrupt(1u << (3 + i));
            ConsumeAudioFifoOnTimer(i);
          }
          write_timer_raw(i, t.counter);
        }
      }
    }
  }
}"""

content = replace_func(content, "StepPpu", step_ppu_body)
content = replace_func(content, "StepTimers", step_timers_body)
with open(path, "w") as f:
    f.write(content)
