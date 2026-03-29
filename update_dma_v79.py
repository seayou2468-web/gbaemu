import sys
import re

path = "src/core/gba_core_modules/timing_dma.mm"
with open(path, "r") as f:
    content = f.read()

# Refined StepDma with correct shadowing, repeat, and FIFO burst behavior.
# Priority: 0 > 1 > 2 > 3.
# Sound FIFO (1,2) always 4 words, fixed DAD.
step_dma_body = """void GBACore::StepDma() {
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

    // Check for trigger conditions
    if (start_timing == 0) {
      // Immediate fires only if active was false (triggered by WriteIO16)
      // or if repeat is on? No, immediate doesn't repeat in hardware sense.
      // But we handle immediate firing in WriteIO16 directly to be safe.
      // Here we check if it was just activated.
      if (dma_shadows_[ch].active && dma_shadows_[ch].count > 0) {
         // In our model, WriteIO16 sets active=true and calls StepDma.
         // So if we are here and active=true, it might be an immediate fire.
         // However, hardware immediate doesn't really "poll".
      }
    } else if (start_timing == 1 && vblank_rising) fire = true;
    else if (start_timing == 2 && hblank_rising) fire = true;
    else if (start_timing == 3) {
      if (ch == 1 || ch == 2) fire = (ch == 1) ? dma_fifo_a_request_ : dma_fifo_b_request_;
      else if (ch == 3) { /* Video Capture conceptual */ }
    }

    if (!fire) continue;
    if (start_timing == 3 && (ch == 1 || ch == 2)) {
      if (ch == 1) dma_fifo_a_request_ = false;
      else dma_fifo_b_request_ = false;
    }

    uint32_t src = dma_shadows_[ch].sad;
    uint32_t dst = dma_shadows_[ch].dad;
    uint32_t count = dma_shadows_[ch].count;

    // Special behavior for Sound FIFO
    if (start_timing == 3 && (ch == 1 || ch == 2)) {
      count = 4; // Always 4 words
    }

    const bool word32 = (cnt_h & 0x0400u) != 0;
    const uint32_t addr_mask = (ch == 0) ? 0x07FFFFFFu : 0x0FFFFFFFu;
    const int src_ctl = (cnt_h >> 7) & 0x3;
    const int dst_ctl = (cnt_h >> 5) & 0x3;
    const int step = (word32 || (start_timing == 3 && (ch == 1 || ch == 2))) ? 4 : 2;

    for (uint32_t n = 0; n < count; ++n) {
      if (step == 4) Write32(dst & ~3u, Read32(src & ~3u));
      else Write16(dst & ~1u, Read16(src & ~1u));

      if (src_ctl == 0) src += step; else if (src_ctl == 1) src -= step;
      if (dst_ctl == 0 || dst_ctl == 3) dst += step; else if (dst_ctl == 1) dst -= step;
      src &= addr_mask;
      dst &= addr_mask;
    }

    dma_shadows_[ch].sad = src;
    const bool repeat = (cnt_h & 0x0200u) != 0;
    if (repeat && start_timing != 0) {
      // Reload for next trigger
      if (dst_ctl == 3) dma_shadows_[ch].dad = dma_shadows_[ch].initial_dad;
      else dma_shadows_[ch].dad = dst;
      dma_shadows_[ch].count = dma_shadows_[ch].initial_count;
    } else {
      dma_shadows_[ch].dad = dst;
      dma_shadows_[ch].active = false;
      // Auto-disable
      uint16_t next_cnt = ReadIO16(base + 10) & ~0x8000u;
      const size_t off = static_cast<size_t>((base + 10) - 0x04000000u);
      io_regs_[off] = next_cnt & 0xFF;
      io_regs_[off + 1] = (next_cnt >> 8) & 0xFF;
    }

    if (cnt_h & 0x4000u) RaiseInterrupt(1u << (8 + ch));
  }
}"""

content = re.sub(r"void GBACore::StepDma\(\) \{.*?^\}", step_dma_body, content, flags=re.DOTALL | re.MULTILINE)
with open(path, "w") as f:
    f.write(content)
