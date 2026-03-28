import sys
import re

path = "src/core/gba_core_modules/timing_dma.mm"
with open(path, "r") as f:
    content = f.read()

# Robust DMA implementation covering priority and repeat reload
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
      if (ch == 1 || ch == 2) fire = (ch == 1) ? dma_fifo_a_request_ : dma_fifo_b_request_;
      else if (ch == 3) fire = hblank_rising; // Simplified Video Capture trigger
    }

    if (!fire) continue;
    if (start_timing == 3) {
      if (ch == 1) dma_fifo_a_request_ = false;
      if (ch == 2) dma_fifo_b_request_ = false;
    }

    uint32_t src = Read32(base + 0);
    uint32_t dst = Read32(base + 4);
    uint32_t count = ReadIO16(base + 8);
    if (count == 0) count = (ch == 3) ? 0x10000u : 0x4000u;
    if (start_timing == 3 && (ch == 1 || ch == 2)) count = 4;

    const bool word32 = (cnt_h & 0x0400u) != 0;
    const uint32_t addr_mask = (ch == 0) ? 0x07FFFFFFu : 0x0FFFFFFFu;
    const int src_ctl = (cnt_h >> 7) & 0x3;
    const int dst_ctl = (cnt_h >> 5) & 0x3;
    const int step = word32 ? 4 : 2;

    for (uint32_t n = 0; n < count; ++n) {
      if (word32) Write32(dst & ~3u, Read32(src & ~3u));
      else Write16(dst & ~1u, Read16(src & ~1u));

      if (src_ctl == 0) src += step; else if (src_ctl == 1) src -= step;
      if (dst_ctl == 0 || dst_ctl == 3) dst += step; else if (dst_ctl == 1) dst -= step;
      src &= addr_mask;
      dst &= addr_mask;
    }

    // Shadow register logic: reload destination only if repeat and NOT immediate
    const bool repeat = (cnt_h & 0x0200u) != 0;
    Write32(base + 0, src);
    if (repeat && start_timing != 0) {
      if (dst_ctl == 3) {
        // Conceptually reload initial DAD.
        // We'll use the value from WriteIO16's original write if we had shadow regs.
        // For now, we update the register with the current 'dst' unless it's reload type.
      } else {
        Write32(base + 4, dst);
      }
    } else {
      Write32(base + 4, dst);
      WriteIO16(base + 10, cnt_h & ~0x8000u); // Auto-disable
    }

    if (cnt_h & 0x4000u) RaiseInterrupt(1u << (8 + ch));
  }
}"""

content = re.sub(r"void GBACore::StepDma\(\) \{.*?^\}", step_dma_body, content, flags=re.DOTALL | re.MULTILINE)

with open(path, "w") as f:
    f.write(content)
