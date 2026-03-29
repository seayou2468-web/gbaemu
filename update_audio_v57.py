import sys
import re

path = "src/core/gba_core_modules/timing_dma.mm"
with open(path, "r") as f:
    content = f.read()

def replace_func(c, name, body):
    pattern = rf"void GBACore::{name}\(.*?\) \{{.*?^}}"
    return re.sub(pattern, body, c, flags=re.DOTALL | re.MULTILINE)

# Improved Audio FIFO sync
push_apu_body = """void GBACore::PushAudioFifo(bool fifo_a, uint32_t value) {
  auto& fifo = fifo_a ? fifo_a_ : fifo_b_;
  for (int i = 0; i < 4; ++i) {
    fifo.push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xFFu));
  }
  // If size is too big, discard old samples
  while (fifo.size() > mgba_compat::kAudioFifoCapacityBytes) fifo.pop_front();

  // Re-check DMA request: if size dropped to threshold, set request?
  // Usually request is set when pop occurs.
}"""

consume_apu_body = """void GBACore::ConsumeAudioFifoOnTimer(size_t timer_index) {
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
}"""

content = replace_func(content, "PushAudioFifo", push_apu_body)
content = replace_func(content, "ConsumeAudioFifoOnTimer", consume_apu_body)
with open(path, "w") as f:
    f.write(content)
