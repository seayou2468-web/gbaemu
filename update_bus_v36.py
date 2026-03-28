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

# 1. Exhaustive I/O Masking and side effects
write_io16_body = """void GBACore::WriteIO16(uint32_t addr, uint16_t value) {
  addr &= ~1u;
  if (addr < 0x04000000u || addr > 0x040003FEu) return;
  const size_t off = static_cast<size_t>(addr - 0x04000000u);
  if (off + 1 >= io_regs_.size()) return;

  switch(addr) {
    case 0x04000000u: value &= 0xFF7Fu; break; // DISPCNT (bit 7 reserved, bit 3 RO 0)
    case 0x04000004u: { // DISPSTAT
      const uint16_t old = ReadIO16(addr);
      value = (value & 0xFFB8u) | (old & 0x0007u); // Bits 0-2 RO, bits 3-5/8-15 RW
      break;
    }
    case 0x04000006u: return; // VCOUNT RO
    case 0x04000008u: // BG0CNT
    case 0x0400000Au: // BG1CNT
      value &= 0xDFFFu; break; // BG0/1 no wrap bit
    case 0x0400000Cu: // BG2CNT
    case 0x0400000Eu: // BG3CNT
      value &= 0xFFFFu; break;
    case 0x04000050u: value &= 0x3FFFu; break; // BLDCNT
    case 0x04000052u: value &= 0x1F1Fu; break; // BLDALPHA
    case 0x04000054u: value &= 0x001Fu; break; // BLDY
    case 0x04000082u: { // SOUNDCNT_H
      if (value & (1u << 11)) { fifo_a_.clear(); fifo_a_last_sample_ = 0; value &= ~(1u << 11); }
      if (value & (1u << 15)) { fifo_b_.clear(); fifo_b_last_sample_ = 0; value &= ~(1u << 15); }
      value &= 0x770Fu; // approximate mask
      break;
    }
    case 0x04000084u: { // SOUNDCNT_X
      const uint16_t old = ReadIO16(addr);
      value = (value & 0x0080u) | (old & 0x000Fu);
      if ((old & 0x0080u) && !(value & 0x0080u)) {
        for (size_t i = 0x60; i <= 0x81; ++i) io_regs_[i] = 0;
        apu_ch1_active_ = apu_ch2_active_ = apu_ch3_active_ = apu_ch4_active_ = false;
      }
      break;
    }
    case 0x040000B8u: // DMA0CNT_H
    case 0x040000C4u: // DMA1CNT_H
    case 0x040000D0u: // DMA2CNT_H
      value &= 0xF7E0u;
      if (((value >> 12) & 3) == 3) value &= ~(3u << 12); // Timing 3 invalid for 0-2
      break;
    case 0x040000DCu: // DMA3CNT_H
      value &= 0xFFE0u; break;
    case 0x04000102u: // TM0CNT_H
      value &= 0x00C3u; break; // No count-up for T0
    case 0x04000106u: // TM1CNT_H
    case 0x0400010Au: // TM2CNT_H
    case 0x0400010Eu: // TM3CNT_H
      value &= 0x00C7u; break;
    case 0x04000130u: return; // KEYINPUT RO
    case 0x04000132u: value &= 0x03FFu; break; // KEYCNT
    case 0x04000200u: value &= 0x3FFFu; break; // IE
    case 0x04000202u: { // IF W1C
      const uint16_t old = ReadIO16(addr);
      value = old & ~value;
      break;
    }
    case 0x04000204u: value &= 0x5FFFu; break; // WAITCNT
    case 0x04000208u: value &= 0x0001u; break; // IME
  }

  // Timer Start side effect
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
}"""

content = replace_func(content, "WriteIO16", write_io16_body)

with open(path, "w") as f:
    f.write(content)
