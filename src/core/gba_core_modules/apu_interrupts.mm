#include "../gba_core.h"
#include <algorithm>
#include <cstring>

namespace gba {

void GBACore::StepApu(uint32_t cycles) {
  apu_frame_seq_cycles_ += cycles;
  if (apu_frame_seq_cycles_ >= 8192) { // 512Hz
    apu_frame_seq_cycles_ -= 8192;
    apu_frame_seq_step_ = (apu_frame_seq_step_ + 1) & 7;

    // Length (steps 0, 2, 4, 6)
    // Sweep (steps 2, 6)
    // Volume (step 7)
  }

  // Sound 1-4 synthesis and FIFO mixing
}

void GBACore::PushAudioFifo(bool fifo_a, uint32_t value) {
  std::deque<uint8_t>& fifo = fifo_a ? fifo_a_ : fifo_b_;
  for (int i = 0; i < 4; ++i) {
    if (fifo.size() < 32) fifo.push_back((value >> (i * 8)) & 0xFF);
  }

  if (fifo.size() >= 16) {
    // DMA Request logic if enabled
  }
}

void GBACore::ConsumeAudioFifoOnTimer(size_t timer_index) {
  uint16_t soundcnt_h = ReadIO16(0x04000082);
  bool timer_a = (soundcnt_h >> 10) & 1;
  bool timer_b = (soundcnt_h >> 14) & 1;

  if (timer_a && timer_index == 0) { if (!fifo_a_.empty()) fifo_a_.pop_front(); }
  if (timer_b && timer_index == 1) { if (!fifo_b_.empty()) fifo_b_.pop_front(); }
}

void GBACore::RaiseInterrupt(uint16_t mask) {
  uint16_t IF = ReadIO16(0x04000202);
  IF |= mask;
  WriteIO16(0x04000202, IF);
  ServiceInterruptIfNeeded();
}

void GBACore::ServiceInterruptIfNeeded() {
  uint16_t IE = ReadIO16(0x04000200);
  uint16_t IF = ReadIO16(0x04000202);
  uint16_t IME = ReadIO16(0x04000208) & 1;

  if (IME && (IE & IF)) {
    // PC + 4 or 8 depending on exception
    EnterException(0x00000018, 0x12, true, false); // IRQ mode, ARM state
    cpu_.halted = false;
  }
}

} // namespace gba
