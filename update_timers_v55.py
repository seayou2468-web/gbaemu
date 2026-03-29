import sys
import re

path = "src/core/gba_core_modules/timing_dma.mm"
with open(path, "r") as f:
    content = f.read()

def replace_func(c, name, body):
    pattern = rf"void GBACore::{name}\(uint32_t cycles\) \{{.*?^}}"
    return re.sub(pattern, body, c, flags=re.DOTALL | re.MULTILINE)

# 2. Clock-accurate sequential StepTimers
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
}"""

content = replace_func(content, "StepTimers", step_timers_body)
with open(path, "w") as f:
    f.write(content)
