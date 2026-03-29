import sys
import re

path = "src/core/gba_core_modules/memory_bus.mm"
with open(path, "r") as f:
    content = f.read()

def replace_func(c, name, body):
    pattern = rf"(uint\d+_t|void) GBACore::{name}\(uint32_t addr(?:, (?:uint\d+_t|uint16_t|uint8_t) value)?\) (?:const )?\{{.*?^}}"
    if re.search(pattern, c, flags=re.DOTALL | re.MULTILINE):
        return re.sub(pattern, body, c, flags=re.DOTALL | re.MULTILINE)
    return c

# Implement Latch-on-Enable in WriteIO16 for DMA
# When DMAxCNT_H bit 15 transitions 0->1, latch SAD, DAD, and CNT.

write_io16_body = """void GBACore::WriteIO16(uint32_t addr, uint16_t value) {
  addr &= ~1u;
  if (addr < 0x04000000u || addr > 0x040003FEu) return;
  const size_t off = static_cast<size_t>(addr - 0x04000000u);
  if (off + 1 >= io_regs_.size()) return;

  switch(addr) {
    case 0x04000000u: value &= 0xFF7Fu; break;
    case 0x04000004u: {
      const uint16_t old = ReadIO16(addr);
      const uint16_t vcount = ReadIO16(0x04000006u);
      const uint16_t lyc = (value >> 8) & 0xFF;
      value = (value & 0xFFB8u) | (old & 0x0007u);
      if (vcount == lyc) value |= 0x0004u; else value &= ~0x0004u;
      break;
    }
    case 0x04000006u: return;
    case 0x04000202u: {
      const uint16_t old = ReadIO16(addr);
      value = old & ~value;
      break;
    }
    case 0x04000130u: return;

    // DMA Control Registers
    case 0x040000B8u: // DMA0CNT_H
    case 0x040000C4u: // DMA1CNT_H
    case 0x040000D0u: // DMA2CNT_H
    case 0x040000DCu: { // DMA3CNT_H
      const int ch = (addr - 0x040000B8u) / 12 + ((addr == 0x040000B8u) ? 0 : 0); // Wait, offset is fixed
      int actual_ch = 0;
      if (addr == 0x040000B8u) actual_ch = 0;
      else if (addr == 0x040000C4u) actual_ch = 1;
      else if (addr == 0x040000D0u) actual_ch = 2;
      else actual_ch = 3;

      const uint16_t old = ReadIO16(addr);
      uint16_t mask = (actual_ch == 3) ? 0xFFE0u : 0xF7E0u;
      value &= mask;
      if (((value >> 12) & 3) == 3 && actual_ch == 0) value &= ~(3u << 12);

      if (!(old & 0x8000u) && (value & 0x8000u)) {
        // Latch SAD/DAD/CNT into shadows on enable transition
        const uint32_t base = 0x040000B0u + actual_ch * 12u;
        dma_shadows_[actual_ch].sad = Read32(base);
        dma_shadows_[actual_ch].initial_dad = Read32(base + 4);
        dma_shadows_[actual_ch].dad = dma_shadows_[actual_ch].initial_dad;
        uint32_t c = ReadIO16(base + 8);
        if (c == 0) c = (actual_ch == 3) ? 0x10000u : 0x4000u;
        dma_shadows_[actual_ch].initial_count = c;
        dma_shadows_[actual_ch].count = c;
        dma_shadows_[actual_ch].active = true;
      }
      break;
    }
  }

  if (addr >= 0x04000100u && addr <= 0x0400010Eu) {
    const uint32_t tidx = (addr - 0x04000100u) / 4u;
    if (addr & 2) {
      const uint16_t old = ReadIO16(addr);
      timers_[tidx].control = value;
      if (!(old & 0x80u) && (value & 0x80u)) {
        timers_[tidx].counter = timers_[tidx].reload;
        timers_[tidx].prescaler_accum = 0;
        io_regs_[0x100u + tidx*4] = timers_[tidx].reload & 0xFF;
        io_regs_[0x101u + tidx*4] = (timers_[tidx].reload >> 8) & 0xFF;
      }
    } else {
      timers_[tidx].reload = value;
      if (!(timers_[tidx].control & 0x80u)) timers_[tidx].counter = value;
    }
  }

  io_regs_[off] = static_cast<uint8_t>(value & 0xFFu);
  io_regs_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFFu);

  // Trigger immediate DMA
  if (addr == 0x040000B8u || addr == 0x040000C4u || addr == 0x040000D0u || addr == 0x040000DCu) {
    if ((value & 0x8000u) && ((value >> 12) & 3) == 0) StepDma();
  }
}"""

content = replace_func(content, "WriteIO16", write_io16_body)
with open(path, "w") as f:
    f.write(content)
