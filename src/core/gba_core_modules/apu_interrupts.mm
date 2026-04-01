#include "../gba_core.h"

namespace gba {

void GBACore::PushAudioFifo(bool fifo_a, uint32_t value) {
  auto& fifo = fifo_a ? fifo_a_ : fifo_b_;
  for (int i = 0; i < 4; ++i) {
    fifo.push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xFF));
  }
  while (fifo.size() > mgba_compat::kAudioFifoCapacityBytes) fifo.pop_front();
}

void GBACore::ConsumeAudioFifoOnTimer(size_t timer_index) {
  auto consumeOne = [&](bool is_a) {
    auto& fifo = is_a ? fifo_a_ : fifo_b_;
    int16_t& last = is_a ? fifo_a_last_sample_ : fifo_b_last_sample_;
    if (fifo.empty()) {
      last = 0;
      return;
    }
    last = static_cast<int8_t>(fifo.front()) << 8;
    fifo.pop_front();

    if (fifo.size() <= mgba_compat::kAudioFifoDmaRequestThreshold) {
      if (is_a) {
        dma_fifo_a_request_ = true;
      } else {
        dma_fifo_b_request_ = true;
      }
    }
  };

  const uint16_t soundcnt_hi = static_cast<uint16_t>(io_regs_[0x82] | (io_regs_[0x83] << 8));
  const bool ch_a_timer1 = (soundcnt_hi & (1u << 10)) != 0;
  const bool ch_b_timer1 = (soundcnt_hi & (1u << 14)) != 0;
  if ((ch_a_timer1 ? 1u : 0u) == timer_index) consumeOne(true);
  if ((ch_b_timer1 ? 1u : 0u) == timer_index) consumeOne(false);
}

void GBACore::RaiseInterrupt(uint16_t mask) {
  uint16_t iff = static_cast<uint16_t>(io_regs_[0x202] | (io_regs_[0x203] << 8));
  iff = static_cast<uint16_t>(iff | mask);
  io_regs_[0x202] = static_cast<uint8_t>(iff & 0xFF);
  io_regs_[0x203] = static_cast<uint8_t>((iff >> 8) & 0xFF);
}

void GBACore::ServiceInterruptIfNeeded() {
  const bool ime = (io_regs_[0x208] & 1u) != 0;
  const bool i_masked = (cpu_.cpsr & (1u << 7)) != 0;
  const uint16_t ie = static_cast<uint16_t>(io_regs_[0x200] | (io_regs_[0x201] << 8));
  const uint16_t iff = static_cast<uint16_t>(io_regs_[0x202] | (io_regs_[0x203] << 8));
  if (!ime || i_masked || (ie & iff) == 0) return;

  EnterException(0x18u, 0x12u, true, false);
}

void GBACore::StepApu(uint32_t cycles) {
  apu_frame_seq_cycles_ += cycles;
  while (apu_frame_seq_cycles_ >= 512) {
    apu_frame_seq_cycles_ -= 512;
    apu_phase_sq1_ = (apu_phase_sq1_ + 1) & 7u;
    apu_phase_sq2_ = (apu_phase_sq2_ + 1) & 7u;
    apu_phase_wave_ = (apu_phase_wave_ + 1) & 31u;

    // 15-bit LFSR
    const uint16_t lsb = apu_noise_lfsr_ & 1u;
    apu_noise_lfsr_ >>= 1;
    if (lsb) apu_noise_lfsr_ ^= 0x6000u;
  }
}

}  // namespace gba
