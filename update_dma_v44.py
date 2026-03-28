import sys
import re

path = "src/core/gba_core_modules/timing_dma.mm"
with open(path, "r") as f:
    content = f.read()

# Refined StepDma with priority and correct behavior
# GBA DMA Priority: 0 > 1 > 2 > 3.
# If a higher priority DMA is triggered while a lower one is running,
# the higher one takes over.
step_dma_body = """void GBACore::StepDma() {
  const uint16_t dispstat = ReadIO16(0x04000004u);
  const bool in_vblank = (dispstat & 0x0001u) != 0;
  const bool in_hblank = (dispstat & 0x0002u) != 0;
  const bool vblank_rising = in_vblank && !dma_was_in_vblank_;
  const bool hblank_rising = in_hblank && !dma_was_in_hblank_;
  dma_was_in_vblank_ = in_vblank;
  dma_was_in_hblank_ = in_hblank;

  for (int ch = 0; ch < 4; ++ch) {
    const uint32_t base = 0x040000B0u + ch * 12u;
    const uint16_t cnt_h = ReadIO16(base + 10u);
    if (!(cnt_h & 0x8000u)) continue;

    const uint16_t start_timing = (cnt_h >> 12) & 0x3u;
    bool fire = false;
    if (start_timing == 0) fire = true; // Immediate
    else if (start_timing == 1 && vblank_rising) fire = true;
    else if (start_timing == 2 && hblank_rising) fire = true;
    else if (start_timing == 3) {
      if (ch == 1 || ch == 2) { // Sound FIFO
        fire = (ch == 1) ? dma_fifo_a_request_ : dma_fifo_b_request_;
      } else if (ch == 3) { // Video Capture
        // CONCEPTUAL: fire on specific scanlines
      }
    }

    if (!fire) continue;

    // Reset request flags
    if (start_timing == 3) {
      if (ch == 1) dma_fifo_a_request_ = false;
      if (ch == 2) dma_fifo_b_request_ = false;
    }

    uint32_t src = Read32(base + 0);
    uint32_t dst = Read32(base + 4);
    uint32_t count = ReadIO16(base + 8);
    if (count == 0) count = (ch == 3) ? 0x10000u : 0x4000u;

    if (start_timing == 3 && (ch == 1 || ch == 2)) count = 4; // Sound FIFO always 4 words

    bool word32 = (cnt_h & 0x0400u) != 0;
    const uint32_t addr_mask = (ch == 0) ? 0x07FFFFFFu : 0x0FFFFFFFu;

    int src_ctl = (cnt_h >> 7) & 0x3;
    int dst_ctl = (cnt_h >> 5) & 0x3;
    if (src_ctl == 3) src_ctl = 0; // Increment

    const int step = word32 ? 4 : 2;
    auto apply_step = [&](uint32_t addr, int ctl) {
      if (ctl == 0) return addr + step;
      if (ctl == 1) return addr - step;
      if (ctl == 2) return addr;
      return addr + step; // Reload handled below
    };

    for (uint32_t n = 0; n < count; ++n) {
      if (word32) Write32(dst & ~3u, Read32(src & ~3u));
      else Write16(dst & ~1u, Read16(src & ~1u));

      src = apply_step(src, src_ctl) & addr_mask;
      dst = apply_step(dst, dst_ctl) & addr_mask;
    }

    // Update registers
    Write32(base + 0, src);
    const bool repeat = (cnt_h & 0x0200u) != 0;
    if (repeat && start_timing != 0) {
      if (dst_ctl == 3) dst = Read32(base + 4); // Conceptually reload initial dest
      Write32(base + 4, dst);
    } else {
      Write32(base + 4, dst);
      // Disable DMA
      WriteIO16(base + 10, cnt_h & ~0x8000u);
    }

    if (cnt_h & 0x4000u) RaiseInterrupt(1u << (8 + ch));

    // Higher priority DMA executed. Stop for this slice?
    // In GBA, DMA stalls CPU. We'll just continue to next channel.
  }
}"""

content = re.sub(r"void GBACore::StepDma\(\) \{.*?^\}", step_dma_body, content, flags=re.DOTALL | re.MULTILINE)

with open(path, "w") as f:
    f.write(content)
