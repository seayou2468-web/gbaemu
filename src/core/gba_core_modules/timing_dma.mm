#include "../gba_core.h"

namespace gba {

void GBACore::StepPpu(uint32_t cycles) {
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
    const uint32_t dist = (ppu_cycle_accum_ < next_event) ? (next_event - ppu_cycle_accum_) : 1u;
    const uint32_t step = std::min(remaining, dist);
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
      }

      const uint16_t vcount_compare = (dispstat >> 8) & 0x00FFu;
      if (next_vcount == vcount_compare) {
        if (!(dispstat & 0x0004u) && (dispstat & (1u << 5))) RaiseInterrupt(1u << 2);
        dispstat |= 0x0004u;
      } else {
        dispstat &= ~0x0004u;
      }
      write_io_raw16(0x04000004u, dispstat);

      if (next_vcount == 0) {
        // Frame start: reload internal affine refs
        auto rb28 = [&](uint32_t addr) {
          uint32_t r = Read32(addr) & 0x0FFFFFFFu;
          return static_cast<int32_t>(r << 4) >> 4;
        };
        bg2_refx_internal_ = rb28(0x04000028u);
        bg2_refy_internal_ = rb28(0x0400002Cu);
        bg3_refx_internal_ = rb28(0x04000038u);
        bg3_refy_internal_ = rb28(0x0400003Cu);
      } else {
        // End of line: advance internal affine refs
        bg2_refx_internal_ += (int16_t)ReadIO16(0x04000022u); // PB
        bg2_refy_internal_ += (int16_t)ReadIO16(0x04000026u); // PD
        bg3_refx_internal_ += (int16_t)ReadIO16(0x04000032u); // PB
        bg3_refy_internal_ += (int16_t)ReadIO16(0x04000036u); // PD
      }

      if (next_vcount < mgba_compat::kVideoTotalLines) {
        bg2_refx_line_[next_vcount] = bg2_refx_internal_;
        bg2_refy_line_[next_vcount] = bg2_refy_internal_;
        bg3_refx_line_[next_vcount] = bg3_refx_internal_;
        bg3_refy_line_[next_vcount] = bg3_refy_internal_;
        affine_line_captured_[next_vcount] = 1;
        affine_line_refs_valid_ = true;
      }
    }
  }
}

void GBACore::StepTimers(uint32_t cycles) {
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
    // Step by step for accuracy across cascaded timers
    remaining--;
    bool overflowed[4] = {false, false, false, false};

    for (int i = 0; i < 4; ++i) {
      TimerState& t = timers_[i];
      if (!(t.control & 0x80u)) continue;

      bool tick = false;
      if (i > 0 && (t.control & 4)) {
        if (overflowed[i - 1]) tick = true;
      } else {
        const uint32_t prescaler = kPrescalerLut[t.control & 3];
        t.prescaler_accum++;
        if (t.prescaler_accum >= prescaler) {
          t.prescaler_accum = 0;
          tick = true;
        }
      }

      if (tick) {
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

void GBACore::StepDma() {
  const uint16_t dispstat = ReadIO16(0x04000004u);
  const bool vblank_rising = (dispstat & 1) && !dma_was_in_vblank_;
  const bool hblank_rising = (dispstat & 2) && !dma_was_in_hblank_;
  dma_was_in_vblank_ = (dispstat & 1);
  dma_was_in_hblank_ = (dispstat & 2);

  for (int ch = 0; ch < 4; ++ch) {
    const uint32_t base = 0x040000B0u + ch * 12u;
    const uint16_t cnt_h = ReadIO16(base + 10u);
    if (!(cnt_h & 0x8000u)) {
      dma_shadows_[ch].active = false;
      continue;
    }

    const uint16_t start_timing = (cnt_h >> 12) & 0x3u;
    bool fire = false;
    if (!dma_shadows_[ch].active) {
      // First enable: reload all shadows from I/O regs
      dma_shadows_[ch].sad = Read32(base + 0);
      dma_shadows_[ch].dad = Read32(base + 4);
      uint32_t c = ReadIO16(base + 8);
      // Correct default counts for GBA
      if (c == 0) c = (ch == 3) ? 0x10000u : 0x4000u;
      dma_shadows_[ch].count = c;
      dma_shadows_[ch].active = true;
      if (start_timing == 0) fire = true; // Immediate trigger on enable
    } else {
      if (start_timing == 1 && vblank_rising) fire = true;
      else if (start_timing == 2 && hblank_rising) fire = true;
      else if (start_timing == 3) {
        if (ch == 1 || ch == 2) fire = (ch == 1) ? dma_fifo_a_request_ : dma_fifo_b_request_;
      }
    }

    if (!fire) continue;
    if (start_timing == 3) {
      if (ch == 1) dma_fifo_a_request_ = false;
      if (ch == 2) dma_fifo_b_request_ = false;
    }

    uint32_t src = dma_shadows_[ch].sad;
    uint32_t dst = dma_shadows_[ch].dad;
    uint32_t count = dma_shadows_[ch].count;
    if (start_timing == 3 && (ch == 1 || ch == 2)) count = 4; // Sound FIFO always 4

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

    dma_shadows_[ch].sad = src;
    const bool repeat = (cnt_h & 0x0200u) != 0;
    if (repeat && start_timing != 0) {
      if (dst_ctl == 3) {
        // Correct reload: DAD shadow is reloaded from DAD I/O
        dma_shadows_[ch].dad = Read32(base + 4);
      } else {
        dma_shadows_[ch].dad = dst;
      }
      // Re-load count for next trigger
      uint32_t c = ReadIO16(base + 8);
      if (c == 0) c = (ch == 3) ? 0x10000u : 0x4000u;
      dma_shadows_[ch].count = c;
    } else {
      dma_shadows_[ch].dad = dst;
      dma_shadows_[ch].active = false;
      // Auto-disable DMA in I/O register
      uint16_t next_cnt = ReadIO16(base + 10) & ~0x8000u;
      const size_t off = static_cast<size_t>((base + 10) - 0x04000000u);
      io_regs_[off] = next_cnt & 0xFF;
      io_regs_[off+1] = (next_cnt >> 8) & 0xFF;
    }

    // Interrupt fires ONLY after full transfer
    if (cnt_h & 0x4000u) RaiseInterrupt(1u << (8 + ch));
  }
}

void GBACore::PushAudioFifo(bool fifo_a, uint32_t value) {
  auto& fifo = fifo_a ? fifo_a_ : fifo_b_;
  for (int i = 0; i < 4; ++i) {
    fifo.push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xFFu));
  }
  // If size is too big, discard old samples
  while (fifo.size() > mgba_compat::kAudioFifoCapacityBytes) fifo.pop_front();

  // Re-check DMA request: if size dropped to threshold, set request?
  // Usually request is set when pop occurs.
}

void GBACore::ConsumeAudioFifoOnTimer(size_t timer_index) {
  const uint16_t soundcnt_h = ReadIO16(0x04000082u);
  const bool fifo_a_timer1 = (soundcnt_h & (1u << 10)) != 0;
  const bool fifo_b_timer1 = (soundcnt_h & (1u << 14)) != 0;

  auto pop_fifo = [&](std::deque<uint8_t>* fifo, int16_t* last_sample, bool* dma_req) {
    if (!fifo->empty()) {
      const int8_t sample = static_cast<int8_t>(fifo->front());
      fifo->pop_front();
      *last_sample = static_cast<int16_t>(sample);
    }
    // Set DMA request if size falls to threshold (16 bytes)
    if (fifo->size() <= mgba_compat::kAudioFifoDmaRequestThreshold) {
      *dma_req = true;
    }
  };

  if ((timer_index == 0u && !fifo_a_timer1) || (timer_index == 1u && fifo_a_timer1)) {
    pop_fifo(&fifo_a_, &fifo_a_last_sample_, &dma_fifo_a_request_);
  }
  if ((timer_index == 0u && !fifo_b_timer1) || (timer_index == 1u && fifo_b_timer1)) {
    pop_fifo(&fifo_b_, &fifo_b_last_sample_, &dma_fifo_b_request_);
  }
}

}  // namespace gba
