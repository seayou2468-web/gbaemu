#include "../gba_core.h"

namespace gba {

namespace {
constexpr int kDmaOffsetLut[4] = {1, -1, 0, 1};
constexpr uint32_t kDmaSrcMask[4] = {0x07FFFFFEu, 0x0FFFFFFEu, 0x0FFFFFFEu, 0x0FFFFFFEu};
constexpr uint32_t kDmaDstMask[4] = {0x07FFFFFEu, 0x07FFFFFEu, 0x07FFFFFEu, 0x0FFFFFFEu};
constexpr uint32_t kTimerPrescale[4] = {1u, 64u, 256u, 1024u};
}

void GBACore::StepTimers(uint32_t cycles) {
  for (size_t i = 0; i < timers_.size(); ++i) {
    auto& t = timers_[i];
    if ((t.control & 0x0080u) == 0) continue;

    const bool count_up = (i > 0) && ((t.control & 0x0004u) != 0);
    if (count_up) continue;

    t.prescaler_accum += cycles;
    const uint32_t div = kTimerPrescale[t.control & 0x3u];
    while (t.prescaler_accum >= div) {
      t.prescaler_accum -= div;
      ++t.counter;
      if (t.counter == 0) {
        t.counter = t.reload;

        if ((t.control & 0x0040u) != 0) {
          RaiseInterrupt(static_cast<uint16_t>(1u << (3 + i)));
        }

        if (i < 2) ConsumeAudioFifoOnTimer(i);

        if (i < 3) {
          auto& next = timers_[i + 1];
          if ((next.control & 0x0084u) == 0x0084u) {
            ++next.counter;
            if (next.counter == 0) {
              next.counter = next.reload;
              if (next.control & 0x0040u) {
                RaiseInterrupt(static_cast<uint16_t>(1u << (4 + i)));
              }
            }
          }
        }
      }
    }

    const uint32_t base = 0x100u + static_cast<uint32_t>(i) * 4u;
    io_regs_[base] = static_cast<uint8_t>(t.counter & 0xFFu);
    io_regs_[base + 1] = static_cast<uint8_t>(t.counter >> 8);
  }
}

void GBACore::ScheduleDmaStart(int ch, uint16_t cnt_h, uint32_t delay_cycles_override) {
  if (ch < 0 || ch >= 4) return;
  auto& d = dma_shadows_[ch];
  d.pending = true;
  d.active = true;
  d.startup_delay = (delay_cycles_override == 0xFFFFFFFFu) ? EstimateDmaStartupDelay(ch, cnt_h) : delay_cycles_override;
}

bool GBACore::IsDmaAddressValid(int ch, uint32_t src, uint32_t dst, bool fifo_dma) const {
  if (fifo_dma) return dst == 0x040000A0u || dst == 0x040000A4u;
  if (ch == 0 && src >= 0x08000000u && src < 0x0E000000u) return false;
  if (ch != 3 && dst >= 0x08000000u) return false;
  return src >= 0x02000000u;
}

uint32_t GBACore::EstimateDmaStartupDelay(int ch, uint16_t cnt_h) const {
  (void)ch;
  const uint32_t timing = (cnt_h >> 12) & 0x3u;
  return timing == 0 ? 3u : 1u;
}

bool GBACore::ServiceDmaChannelUnit(int ch, uint16_t cnt_h) {
  if (ch < 0 || ch >= 4) return false;
  auto& d = dma_shadows_[ch];
  if (!d.in_progress) {
    d.in_progress = true;
    d.seq_access = false;
    d.last_value = 0;
  }
  if (!d.seq_access) {
    // First DMA beat should start as non-sequential on the memory bus.
    last_access_valid_ = false;
  }

  const bool is_32 = (cnt_h & (1u << 10)) != 0;
  const uint32_t width = is_32 ? 4u : 2u;
  const bool fifo_dma = (((cnt_h >> 12) & 0x3u) == 3u) && (ch == 1 || ch == 2);
  uint32_t src = d.sad & kDmaSrcMask[ch];
  uint32_t dst = d.dad & kDmaDstMask[ch];
  if (!IsDmaAddressValid(ch, src, dst, fifo_dma)) {
    d.count = 0;
    return false;
  }

  const uint64_t ws_before = waitstates_accum_;
  if (is_32) {
    d.last_value = Read32(src);
    Write32(dst, d.last_value);
  } else {
    d.last_value = Read16(src);
    Write16(dst, static_cast<uint16_t>(d.last_value));
  }

  const int src_ctl = (cnt_h >> 7) & 0x3;
  const int dst_ctl = (cnt_h >> 5) & 0x3;
  const int src_off = ((src >= 0x08000000u && src < 0x0E000000u) ? 1 : kDmaOffsetLut[src_ctl]) * static_cast<int>(width);
  const int dst_off = kDmaOffsetLut[dst_ctl] * static_cast<int>(width);

  d.sad = static_cast<uint32_t>(static_cast<int32_t>(src) + src_off) & kDmaSrcMask[ch];
  if (!fifo_dma) {
    d.dad = static_cast<uint32_t>(static_cast<int32_t>(dst) + dst_off) & kDmaDstMask[ch];
  }

  if (d.count > 0) --d.count;
  const uint32_t ws_spent = static_cast<uint32_t>(waitstates_accum_ - ws_before);
  d.wait_cycles += ws_spent ? ws_spent : 2u;
  d.seq_access = true;
  return d.count != 0;
}

void GBACore::ExecuteDmaTransfer(int ch, uint16_t cnt_h) {
  auto& d = dma_shadows_[ch];
  if (d.count == 0) {
    d.count = d.initial_count ? d.initial_count : (ch == 3 ? 0x10000u : 0x4000u);
  }

  while (d.count != 0) {
    if (!ServiceDmaChannelUnit(ch, cnt_h)) break;
  }

  const bool repeat = (cnt_h & (1u << 9)) != 0;
  const bool now_timing = (((cnt_h >> 12) & 0x3u) == 0);
  if (!repeat || now_timing) {
    cnt_h = static_cast<uint16_t>(cnt_h & ~0x8000u);
    const uint32_t reg = 0xBAu + static_cast<uint32_t>(ch) * 12u;
    io_regs_[reg] = static_cast<uint8_t>(cnt_h & 0xFFu);
    io_regs_[reg + 1] = static_cast<uint8_t>(cnt_h >> 8);
  } else {
    d.count = d.initial_count;
    if (((cnt_h >> 5) & 0x3u) == 3u) d.dad = d.initial_dad;
  }

  if (cnt_h & (1u << 14)) {
    RaiseInterrupt(static_cast<uint16_t>(1u << (8 + ch)));
  }

  d.pending = false;
  d.active = false;
  d.in_progress = false;
}

void GBACore::StepDma(uint32_t cycles) {
  auto finalize_channel = [&](int i, uint16_t cnt_h) {
    auto& d = dma_shadows_[i];
    const bool repeat = (cnt_h & (1u << 9)) != 0;
    const bool now_timing = (((cnt_h >> 12) & 0x3u) == 0);
    if (!repeat || now_timing) {
      cnt_h = static_cast<uint16_t>(cnt_h & ~0x8000u);
      const uint32_t reg = 0xBAu + static_cast<uint32_t>(i) * 12u;
      io_regs_[reg] = static_cast<uint8_t>(cnt_h & 0xFFu);
      io_regs_[reg + 1] = static_cast<uint8_t>(cnt_h >> 8);
    } else {
      d.count = d.initial_count;
      if (((cnt_h >> 5) & 0x3u) == 3u) d.dad = d.initial_dad;
    }
    if (cnt_h & (1u << 14)) RaiseInterrupt(static_cast<uint16_t>(1u << (8 + i)));
    d.pending = false;
    d.active = false;
    d.in_progress = false;
    d.wait_cycles = 0;
  };

  for (int i = 0; i < 4; ++i) {
    auto& d = dma_shadows_[i];
    if (!d.pending) continue;
    uint32_t budget = cycles ? cycles : 1u;

    while (budget > 0 && d.pending) {
      if (d.startup_delay > 0) {
        const uint32_t dec = d.startup_delay > budget ? budget : d.startup_delay;
        d.startup_delay -= dec;
        budget -= dec;
        if (d.startup_delay > 0) break;
      }

      if (d.wait_cycles > 0) {
        const uint32_t dec = d.wait_cycles > budget ? budget : d.wait_cycles;
        d.wait_cycles -= dec;
        budget -= dec;
        if (d.wait_cycles > 0) break;
      }

      const uint32_t reg = 0xBAu + static_cast<uint32_t>(i) * 12u;
      const uint16_t cnt_h = static_cast<uint16_t>(io_regs_[reg] | (io_regs_[reg + 1] << 8));
      if ((cnt_h & 0x8000u) == 0) {
        d.pending = false;
        d.active = false;
        d.in_progress = false;
        d.wait_cycles = 0;
        break;
      }

      if (d.count == 0) {
        d.count = d.initial_count ? d.initial_count : (i == 3 ? 0x10000u : 0x4000u);
      }
      const bool cont = ServiceDmaChannelUnit(i, cnt_h);
      if (!cont) {
        finalize_channel(i, cnt_h);
      }
    }
  }
}

void GBACore::StepDmaVBlank(uint32_t cycles) {
  for (int i = 0; i < 4; ++i) {
    const uint32_t reg = 0xBAu + static_cast<uint32_t>(i) * 12u;
    const uint16_t cnt_h = static_cast<uint16_t>(io_regs_[reg] | (io_regs_[reg + 1] << 8));
    if ((cnt_h & 0x8000u) && (((cnt_h >> 12) & 0x3u) == 1u)) {
      ScheduleDmaStart(i, cnt_h, 3u);
    }
  }
  StepDma(cycles);
}

void GBACore::StepDmaHBlank(uint32_t cycles) {
  for (int i = 0; i < 4; ++i) {
    const uint32_t reg = 0xBAu + static_cast<uint32_t>(i) * 12u;
    const uint16_t cnt_h = static_cast<uint16_t>(io_regs_[reg] | (io_regs_[reg + 1] << 8));
    if ((cnt_h & 0x8000u) && (((cnt_h >> 12) & 0x3u) == 2u)) {
      ScheduleDmaStart(i, cnt_h, 3u);
    }
  }
  StepDma(cycles);
}

void GBACore::StepSio(uint32_t cycles) {
  if (!sio_.transfer_active) return;
  if (sio_.transfer_cycles_remaining <= cycles) {
    sio_.transfer_cycles_remaining = 0;
    CompleteSioTransfer();
  } else {
    sio_.transfer_cycles_remaining -= cycles;
  }
}

void GBACore::UpdateSioMode() {
  const uint16_t rcnt = static_cast<uint16_t>(io_regs_[0x134] | (io_regs_[0x135] << 8));
  sio_.rcnt = rcnt;
}

void GBACore::StartSioTransfer(uint16_t siocnt) {
  sio_.transfer_active = true;
  sio_.transfer_cycles_remaining = EstimateSioTransferCycles(siocnt);
}

uint32_t GBACore::EstimateSioTransferCycles(uint16_t siocnt) const {
  const bool fast = (siocnt & 0x0002u) != 0;
  return fast ? 512u : 8192u;
}

void GBACore::CompleteSioTransfer() {
  sio_.transfer_active = false;
  RaiseInterrupt(1u << 7);
}

}  // namespace gba
