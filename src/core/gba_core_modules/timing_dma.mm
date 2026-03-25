#include "../gba_core.h"

namespace gba {

void GBACore::StepPpu(uint32_t cycles) {
  constexpr uint32_t kHBlankStartCycle = mgba_compat::kVideoHDrawCycles;
  auto write_io_raw16 = [&](uint32_t addr, uint16_t value) {
    const size_t off = static_cast<size_t>(addr - 0x04000000u);
    if (off + 1 >= io_regs_.size()) return;
    io_regs_[off] = static_cast<uint8_t>(value & 0xFFu);
    io_regs_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFFu);
  };
  uint32_t remaining = cycles;
  while (remaining > 0) {
    uint16_t dispstat = ReadIO16(0x04000004u);
    const bool in_hblank = (dispstat & 0x0002u) != 0;
    const uint32_t boundary = in_hblank ? kCyclesPerScanline : kHBlankStartCycle;
    const uint32_t until_boundary = (ppu_cycle_accum_ < boundary) ? (boundary - ppu_cycle_accum_) : 0u;
    const uint32_t advance = std::min<uint32_t>(remaining, std::max<uint32_t>(1u, until_boundary));
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
      write_io_raw16(0x04000006u, vcount);

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

      const uint16_t vcount_compare = static_cast<uint16_t>((dispstat >> 8) & 0x00FFu);
      const bool vcount_match = (vcount == vcount_compare);
      if (vcount_match) {
        if ((dispstat & 0x0004u) == 0u && (dispstat & (1u << 5))) {
          RaiseInterrupt(1u << 2);  // VCount IRQ
        }
        dispstat = static_cast<uint16_t>(dispstat | 0x0004u);
      } else {
        dispstat = static_cast<uint16_t>(dispstat & ~0x0004u);
      }

      // New scanline starts outside HBlank.
      dispstat = static_cast<uint16_t>(dispstat & ~0x0002u);
      write_io_raw16(0x04000004u, dispstat);
    }
  }
}

void GBACore::StepTimers(uint32_t cycles) {
  static constexpr uint32_t kPrescalerLut[4] = {1, 64, 256, 1024};
  bool overflowed[4] = {false, false, false, false};
  for (size_t i = 0; i < timers_.size(); ++i) {
    TimerState& t = timers_[i];
    const uint16_t cnt_h = ReadIO16(static_cast<uint32_t>(0x04000102u + i * 4u));
    t.control = cnt_h;
    if ((cnt_h & 0x0080u) == 0) continue;  // disabled
    const bool count_up = (cnt_h & 0x0004u) != 0;

    auto tick_once = [&](bool* ov) {
      const uint16_t old = t.counter;
      t.counter = static_cast<uint16_t>(t.counter + 1u);
      if (t.counter == 0) {
        t.counter = ReadIO16(static_cast<uint32_t>(0x04000100u + i * 4u));
        ConsumeAudioFifoOnTimer(i);
        if (cnt_h & 0x0040u) {
          RaiseInterrupt(static_cast<uint16_t>(1u << static_cast<uint16_t>(3u + i)));
        }
        *ov = true;
      }
      if (old == 0xFFFFu) return;
    };

    if (count_up && i > 0) {
      if (overflowed[i - 1]) {
        tick_once(&overflowed[i]);
      }
      WriteIO16(static_cast<uint32_t>(0x04000100u + i * 4u), t.counter);
      continue;
    }

    const uint32_t prescaler = kPrescalerLut[cnt_h & 0x3u];
    t.prescaler_accum += cycles;
    while (t.prescaler_accum >= prescaler) {
      t.prescaler_accum -= prescaler;
      tick_once(&overflowed[i]);
    }
    WriteIO16(static_cast<uint32_t>(0x04000100u + i * 4u), t.counter);
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
    const uint32_t base = static_cast<uint32_t>(0x040000B0u + ch * 12u);
    const uint32_t src = Read32(base + 0u);
    const uint32_t dst = Read32(base + 4u);
    const uint16_t cnt_l = ReadIO16(base + 8u);
    const uint16_t cnt_h = ReadIO16(base + 10u);
    if ((cnt_h & 0x8000u) == 0) continue;
    const uint16_t start_timing = static_cast<uint16_t>((cnt_h >> 12) & 0x3u);
    bool fire_now = false;
    if (start_timing == 0u) fire_now = true;                      // Immediate
    if (start_timing == 1u && vblank_rising) fire_now = true;     // VBlank edge
    if (start_timing == 2u && hblank_rising) fire_now = true;     // HBlank edge
    if (start_timing == 3u) {
      // Sound FIFO DMA (DMA1/DMA2) request timing.
      if (ch != 1 && ch != 2) continue;
      const uint32_t fifo_addr = dst & ~3u;
      const bool is_fifo_a = fifo_addr == 0x040000A0u;
      const bool is_fifo_b = fifo_addr == 0x040000A4u;
      if (!is_fifo_a && !is_fifo_b) continue;
      fire_now = is_fifo_a ? dma_fifo_a_request_ : dma_fifo_b_request_;
      if (!fire_now) continue;
      if (is_fifo_a) dma_fifo_a_request_ = false;
      if (is_fifo_b) dma_fifo_b_request_ = false;
    }
    if (!fire_now) continue;

    bool word32 = (cnt_h & (1u << 10)) != 0;
    uint32_t count = cnt_l;
    if (count == 0) count = (ch == 3) ? 0x10000u : 0x4000u;
    if (start_timing == 3u) {
      // FIFO DMA always transfers 4 words and keeps destination fixed.
      word32 = true;
      count = mgba_compat::kAudioFifoDmaWordsPerBurst;
    }

    int dst_ctl = (cnt_h >> 5) & 0x3;
    const int src_ctl = (cnt_h >> 7) & 0x3;
    if (start_timing == 3u) dst_ctl = 2;  // fixed destination (FIFO register)
    const int step = word32 ? 4 : 2;
    int dst_step = step;
    int src_step = step;
    if (dst_ctl == 1) dst_step = -step;
    if (dst_ctl == 2) dst_step = 0;
    if (src_ctl == 1) src_step = -step;
    if (src_ctl == 2) src_step = 0;

    uint32_t src_cur = src;
    uint32_t dst_cur = dst;
    for (uint32_t n = 0; n < count; ++n) {
      if (word32) {
        Write32(dst_cur, Read32(src_cur));
      } else {
        Write16(dst_cur, Read16(src_cur));
      }
      src_cur = static_cast<uint32_t>(static_cast<int64_t>(src_cur) + src_step);
      dst_cur = static_cast<uint32_t>(static_cast<int64_t>(dst_cur) + dst_step);
    }

    Write32(base + 0u, src_cur);
    Write32(base + 4u, (dst_ctl == 3) ? dst : dst_cur);
    const bool repeat = (cnt_h & (1u << 9)) != 0;
    uint16_t next_cnt_h = cnt_h;
    if (!(repeat && start_timing != 0u)) {
      next_cnt_h = static_cast<uint16_t>(cnt_h & ~0x8000u);
    }
    WriteIO16(base + 10u, next_cnt_h);
    if (cnt_h & (1u << 14)) {
      RaiseInterrupt(static_cast<uint16_t>(1u << static_cast<uint16_t>(8u + ch)));
    }
  }
}

void GBACore::PushAudioFifo(bool fifo_a, uint32_t value) {
  auto& fifo = fifo_a ? fifo_a_ : fifo_b_;
  for (int i = 0; i < 4; ++i) {
    fifo.push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xFFu));
  }
  if (fifo.size() > mgba_compat::kAudioFifoCapacityBytes) {
    fifo.erase(fifo.begin(), fifo.begin() + static_cast<std::ptrdiff_t>(
      fifo.size() - mgba_compat::kAudioFifoCapacityBytes));
  }
}

void GBACore::ConsumeAudioFifoOnTimer(size_t timer_index) {
  const uint16_t soundcnt_h = ReadIO16(0x04000082u);
  const bool fifo_a_timer1 = (soundcnt_h & (1u << 10)) != 0;
  const bool fifo_b_timer1 = (soundcnt_h & (1u << 14)) != 0;
  auto pop_fifo = [&](std::vector<uint8_t>* fifo, int16_t* last_sample) {
    if (!fifo->empty()) {
      const int8_t sample = static_cast<int8_t>(fifo->front());
      fifo->erase(fifo->begin());
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
