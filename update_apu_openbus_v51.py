import sys
import re

path = "src/core/gba_core_modules/timing_dma.mm"
with open(path, "r") as f:
    content = f.read()

# Refine ConsumeAudioFifoOnTimer to better handle empty FIFO behavior
# Real GBA hardware behavior when FIFO is empty: returns the last popped sample.
consume_apu_body = """void GBACore::ConsumeAudioFifoOnTimer(size_t timer_index) {
  const uint16_t soundcnt_h = ReadIO16(0x04000082u);
  const bool fifo_a_timer1 = (soundcnt_h & (1u << 10)) != 0;
  const bool fifo_b_timer1 = (soundcnt_h & (1u << 14)) != 0;
  auto pop_fifo = [&](std::deque<uint8_t>* fifo, int16_t* last_sample) {
    if (!fifo->empty()) {
      const int8_t sample = static_cast<int8_t>(fifo->front());
      fifo->pop_front();
      *last_sample = static_cast<int16_t>(sample);
    }
    // Else: keep the last_sample value as is (hardware behavior)
  };
  if ((timer_index == 0u && !fifo_a_timer1) || (timer_index == 1u && fifo_a_timer1)) {
    pop_fifo(&fifo_a_, &fifo_a_last_sample_);
    if (fifo_a_.size() <= mgba_compat::kAudioFifoDmaRequestThreshold) dma_fifo_a_request_ = true;
  }
  if ((timer_index == 0u && !fifo_b_timer1) || (timer_index == 1u && fifo_b_timer1)) {
    pop_fifo(&fifo_b_, &fifo_b_last_sample_);
    if (fifo_b_.size() <= mgba_compat::kAudioFifoDmaRequestThreshold) dma_fifo_b_request_ = true;
  }
}"""

content = re.sub(r"void GBACore::ConsumeAudioFifoOnTimer\(size_t timer_index\) \{.*?^\}", consume_apu_body, content, flags=re.DOTALL | re.MULTILINE)
with open(path, "w") as f:
    f.write(content)
