#include "../gba_core.h"

namespace gba {

void GBACore::StepPpu(uint32_t cycles) {
  constexpr uint32_t kHBlankStartCycle = mgba_compat::kVideoHDrawCycles;
  auto read_affine_ref28 = [&](uint32_t addr) -> int32_t {
    const uint32_t v = static_cast<uint32_t>(Read8(addr)) |
                       (static_cast<uint32_t>(Read8(addr + 1u)) << 8) |
                       (static_cast<uint32_t>(Read8(addr + 2u)) << 16) |
                       (static_cast<uint32_t>(Read8(addr + 3u)) << 24);
    uint32_t raw28 = v & 0x0FFFFFFFu;
    if ((raw28 & 0x08000000u) != 0) raw28 |= 0xF0000000u;
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
    const uint16_t vcount_compare = static_cast<uint16_t>((*dispstat >> 8) & 0x00FFu);
    const bool had_match = (*dispstat & 0x0004u) != 0;
    const bool match = (vcount == vcount_compare);
    if (match) {
      *dispstat = static_cast<uint16_t>(*dispstat | 0x0004u);
      if (!had_match && (*dispstat & (1u << 5))) {
        RaiseInterrupt(1u << 2);  // VCount IRQ
      }
    } else {
      *dispstat = static_cast<uint16_t>(*dispstat & ~0x0004u);
    }
  };
  auto write_io_raw16 = [&](uint32_t addr, uint16_t value) {
    const size_t off = static_cast<size_t>(addr - 0x04000000u);
    if (off + 1 >= io_regs_.size()) return;
    io_regs_[off] = static_cast<uint8_t>(value & 0xFFu);
    io_regs_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFFu);
  };
  uint32_t remaining = cycles;
  while (remaining > 0) {
    uint16_t dispstat = ReadIO16(0x04000004u);
    const uint16_t cur_vcount = ReadIO16(0x04000006u);
    capture_affine_refs_for_line(cur_vcount);
    const uint16_t dispstat_before_match = dispstat;
    update_vcount_match(&dispstat, cur_vcount);
    if (dispstat != dispstat_before_match) {
      write_io_raw16(0x04000004u, dispstat);
    }
    const bool in_hblank = (dispstat & 0x0002u) != 0;
    const uint32_t next_hblank = in_hblank ? kCyclesPerScanline : kHBlankStartCycle;
    const uint32_t until_boundary = (ppu_cycle_accum_ < next_hblank) ? (next_hblank - ppu_cycle_accum_) : 1u;
    const uint32_t advance = std::min<uint32_t>(remaining, until_boundary);
    ppu_cycle_accum_ += advance;
    remaining -= advance;

    // HBlank edge
    if (!in_hblank && ppu_cycle_accum_ >= kHBlankStartCycle) {
      dispstat = static_cast<uint16_t>(dispstat | 0x0002u);
      if (dispstat & (1u << 4)) {
        RaiseInterrupt(1u << 1);  // HBlank IRQ
      }
      write_io_raw16(0x04000004u, dispstat);
    }

    // End-of-scanline edge
    if (ppu_cycle_accum_ >= kCyclesPerScanline) {
      ppu_cycle_accum_ -= kCyclesPerScanline;

      uint16_t vcount = ReadIO16(0x04000006u);
      vcount = static_cast<uint16_t>((vcount + 1u) % mgba_compat::kVideoTotalLines);
      if (vcount == 0u) {
        affine_line_captured_.fill(0u);
      }
      write_io_raw16(0x04000006u, vcount);
      capture_affine_refs_for_line(vcount);

      dispstat = ReadIO16(0x04000004u);
      const bool was_vblank = (dispstat & 0x0001u) != 0;
      const bool now_vblank = vcount >= mgba_compat::kVideoVisibleLines;
      if (now_vblank) {
        dispstat = static_cast<uint16_t>(dispstat | 0x0001u);
        if (!was_vblank && (dispstat & (1u << 3))) {
          RaiseInterrupt(0x0001u);  // VBlank IRQ
        }
      } else {
        dispstat = static_cast<uint16_t>(dispstat & ~0x0001u);
      }
      update_vcount_match(&dispstat, vcount);

      // New scanline starts outside HBlank.
      dispstat = static_cast<uint16_t>(dispstat & ~0x0002u);
      write_io_raw16(0x04000004u, dispstat);
    }
  }
}

void GBACore::StepTimers(uint32_t cycles) {
  static constexpr uint32_t kPrescalerLut[4] = {1, 64, 256, 1024};
  auto write_timer_counter_raw = [&](size_t i, uint16_t counter) {
    const size_t off = 0x100u + i * 4u;
    if (off + 1u >= io_regs_.size()) return;
    io_regs_[off] = static_cast<uint8_t>(counter & 0xFFu);
    io_regs_[off + 1u] = static_cast<uint8_t>((counter >> 8) & 0xFFu);
  };
  uint32_t overflow_count[4] = {0u, 0u, 0u, 0u};
  for (size_t i = 0; i < timers_.size(); ++i) {
    TimerState& t = timers_[i];
    const uint16_t cnt_h = ReadIO16(static_cast<uint32_t>(0x04000102u + i * 4u));
    t.control = cnt_h;
    if ((cnt_h & 0x0080u) == 0) continue;  // disabled
    const bool count_up = (cnt_h & 0x0004u) != 0;

    auto tick_once = [&]() {
      t.counter = static_cast<uint16_t>(t.counter + 1u);
      if (t.counter == 0u) {
        t.counter = t.reload;
        ConsumeAudioFifoOnTimer(i);
        if (cnt_h & 0x0040u) {
          RaiseInterrupt(static_cast<uint16_t>(1u << static_cast<uint16_t>(3u + i)));
        }
        ++overflow_count[i];
      }
    };

    if (count_up && i > 0) {
      const uint32_t ticks = overflow_count[i - 1];
      for (uint32_t n = 0; n < ticks; ++n) {
        tick_once();
      }
      write_timer_counter_raw(i, t.counter);
      continue;
    }

    const uint32_t prescaler = kPrescalerLut[cnt_h & 0x3u];
    t.prescaler_accum += cycles;
    while (t.prescaler_accum >= prescaler) {
      t.prescaler_accum -= prescaler;
      tick_once();
    }
    write_timer_counter_raw(i, t.counter);
  }
}

void GBACore::StepDma() {
  const uint16_t dispstat = ReadIO16(0x04000004u);
  const bool in_vblank = (dispstat & 0x0001u) != 0;
  const bool in_hblank = (dispstat & 0x0002u) != 0;
  const bool vblank_rising = in_vblank && !dma_was_in_vblank_;
  const bool hblank_rising = in_hblank && !dma_was_in_hblank_;
  dma_was_in_vblank_ = in_vblank;
  dma_was_in_hblank_ = in_hblank;

  for (int ch = 0; ch < 4; ++ch) {
    const uint32_t base = 0x040000B0u + ch * 12u;
    const uint16_t cnt_h = ReadIO16(base + 10u);
    if (!(cnt_h & 0x8000u)) continue;

    const uint16_t start_timing = (cnt_h >> 12) & 0x3u;
    bool fire = false;
    if (start_timing == 0) fire = true; // Immediate
    else if (start_timing == 1 && vblank_rising) fire = true;
    else if (start_timing == 2 && hblank_rising) fire = true;
    else if (start_timing == 3) {
      if (ch == 1 || ch == 2) fire = (ch == 1) ? dma_fifo_a_request_ : dma_fifo_b_request_;
      else if (ch == 3) fire = hblank_rising; // Simplified Video Capture trigger
    }

    if (!fire) continue;
    if (start_timing == 3) {
      if (ch == 1) dma_fifo_a_request_ = false;
      if (ch == 2) dma_fifo_b_request_ = false;
    }

    uint32_t src = Read32(base + 0);
    uint32_t dst = Read32(base + 4);
    uint32_t count = ReadIO16(base + 8);
    if (count == 0) count = (ch == 3) ? 0x10000u : 0x4000u;
    if (start_timing == 3 && (ch == 1 || ch == 2)) count = 4;

    const bool word32 = (cnt_h & 0x0400u) != 0;
    const uint32_t addr_mask = (ch == 0) ? 0x07FFFFFFu : 0x0FFFFFFFu;
    const int src_ctl = (cnt_h >> 7) & 0x3;
    const int dst_ctl = (cnt_h >> 5) & 0x3;
    const int step = word32 ? 4 : 2;

    for (uint32_t n = 0; n < count; ++n) {
      if (word32) Write32(dst & ~3u, Read32(src & ~3u));
      else Write16(dst & ~1u, Read16(src & ~1u));

      if (src_ctl == 0) src += step; else if (src_ctl == 1) src -= step;
      if (dst_ctl == 0 || dst_ctl == 3) dst += step; else if (dst_ctl == 1) dst -= step;
      src &= addr_mask;
      dst &= addr_mask;
    }

    // Shadow register logic: reload destination only if repeat and NOT immediate
    const bool repeat = (cnt_h & 0x0200u) != 0;
    Write32(base + 0, src);
    if (repeat && start_timing != 0) {
      if (dst_ctl == 3) {
        // Conceptually reload initial DAD.
        // We'll use the value from WriteIO16's original write if we had shadow regs.
        // For now, we update the register with the current 'dst' unless it's reload type.
      } else {
        Write32(base + 4, dst);
      }
    } else {
      Write32(base + 4, dst);
      WriteIO16(base + 10, cnt_h & ~0x8000u); // Auto-disable
    }

    if (cnt_h & 0x4000u) RaiseInterrupt(1u << (8 + ch));
  }
}

void GBACore::PushAudioFifo(bool fifo_a, uint32_t value) {
  auto& fifo = fifo_a ? fifo_a_ : fifo_b_;
  for (int i = 0; i < 4; ++i) {
    fifo.push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xFFu));
  }
  while (fifo.size() > mgba_compat::kAudioFifoCapacityBytes) fifo.pop_front();
}

void GBACore::ConsumeAudioFifoOnTimer(size_t timer_index) {
  const uint16_t soundcnt_h = ReadIO16(0x04000082u);
  const bool fifo_a_timer1 = (soundcnt_h & (1u << 10)) != 0;
  const bool fifo_b_timer1 = (soundcnt_h & (1u << 14)) != 0;
  auto pop_fifo = [&](std::deque<uint8_t>* fifo, int16_t* last_sample) {
    if (!fifo->empty()) {
      const int8_t sample = static_cast<int8_t>(fifo->front());
      fifo->pop_front();
      *last_sample = static_cast<int16_t>(sample);
    } else {
      *last_sample = 0;
    }
  };
  if ((timer_index == 0u && !fifo_a_timer1) || (timer_index == 1u && fifo_a_timer1)) {
    pop_fifo(&fifo_a_, &fifo_a_last_sample_);
    if (fifo_a_.size() <= mgba_compat::kAudioFifoDmaRequestThreshold) dma_fifo_a_request_ = true;
  }
  if ((timer_index == 0u && !fifo_b_timer1) || (timer_index == 1u && fifo_b_timer1)) {
    pop_fifo(&fifo_b_, &fifo_b_last_sample_);
    if (fifo_b_.size() <= mgba_compat::kAudioFifoDmaRequestThreshold) dma_fifo_b_request_ = true;
  }
}

}  // namespace gba
