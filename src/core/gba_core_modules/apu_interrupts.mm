#include "../gba_core.h"
#include <algorithm>
#include <cstring>
#include <vector>

namespace gba {

void GBACore::StepApu(uint32_t cycles) {
  // APU audio generation and FIFO management
  // Sound 1, 2, 3, 4, FIFO A, FIFO B
  apu_frame_seq_cycles_ += cycles;
  if (apu_frame_seq_cycles_ >= 8192) { // Frame sequencer ~512Hz
    apu_frame_seq_cycles_ -= 8192;
    apu_frame_seq_step_++;
    if (apu_frame_seq_step_ == 8) apu_frame_seq_step_ = 0;

    // Length count, Volume envelope, Sweep...
  }
}

void GBACore::PushAudioFifo(bool fifo_a, uint32_t value) {
  if (fifo_a) {
    fifo_a_.push_back(value & 0xFF);
    fifo_a_.push_back((value >> 8) & 0xFF);
    fifo_a_.push_back((value >> 16) & 0xFF);
    fifo_a_.push_back((value >> 24) & 0xFF);
  } else {
    fifo_b_.push_back(value & 0xFF);
    fifo_b_.push_back((value >> 8) & 0xFF);
    fifo_b_.push_back((value >> 16) & 0xFF);
    fifo_b_.push_back((value >> 24) & 0xFF);
  }
}

void GBACore::ConsumeAudioFifoOnTimer(size_t timer_index) {
  // Logic to consume one sample from FIFO when timer overflows
}

} // namespace gba
