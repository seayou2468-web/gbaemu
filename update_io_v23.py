import sys
import re

path = "src/core/gba_core_modules/memory_bus.mm"
with open(path, "r") as f:
    content = f.read()

# Unified I/O side effects for all registers
write_io16_body = """void GBACore::WriteIO16(uint32_t addr, uint16_t value) {
  if (addr < 0x04000000u || addr > 0x040003FEu) return;
  const size_t off = static_cast<size_t>(addr - 0x04000000u);
  if (off + 1 >= io_regs_.size()) return;

  // 1. Bitmasks and Read-only constraints
  switch(addr) {
    case 0x04000000u: value &= ~0x0008u; break; // DISPCNT: bit3 read-only 0
    case 0x04000004u: { // DISPSTAT
      const uint16_t old = ReadIO16(addr);
      value = (value & 0xFFB8u) | (old & 0x0007u); // Bits 0-2 status, bits 3-5/8-15 writable
      break;
    }
    case 0x04000006u: return; // VCOUNT is read-only
    case 0x04000130u: return; // KEYINPUT is read-only
    case 0x04000202u: { // IF: write-1-to-clear
      const uint16_t old = ReadIO16(addr);
      value = old & ~value;
      break;
    }
    case 0x04000204u: value &= 0x5FFFu; break; // WAITCNT
    case 0x04000208u: value &= 0x0001u; break; // IME
    case 0x04000050u: value &= 0x3FFFu; break; // BLDCNT
    case 0x04000084u: { // SOUNDCNT_X: master enable side effect
      const uint16_t old = ReadIO16(addr);
      const uint16_t ro_bits = old & 0x000Fu;
      value = (value & 0x0080u) | ro_bits;
      if ((old & 0x0080u) && !(value & 0x0080u)) {
        // Master disable clears channels
        for (size_t i = 0x60; i <= 0x81; ++i) io_regs_[i] = 0;
        apu_ch1_active_ = apu_ch2_active_ = apu_ch3_active_ = apu_ch4_active_ = false;
      }
      break;
    }
    case 0x04000082u: { // SOUNDCNT_H: FIFO reset bits
      if (value & (1u << 11)) { fifo_a_.clear(); fifo_a_last_sample_ = 0; value &= ~(1u << 11); }
      if (value & (1u << 15)) { fifo_b_.clear(); fifo_b_last_sample_ = 0; value &= ~(1u << 15); }
      break;
    }
  }

  // 2. BG/Window constraints
  if (addr >= 0x04000008u && addr <= 0x0400000Eu && (addr & 1) == 0) {
    if ((addr - 0x04000008u) / 2 < 2) value &= ~(1u << 13); // BG0/1 no wraparound
  }
  if (addr >= 0x04000040u && addr <= 0x04000046u && (addr & 1) == 0) value &= 0xFFFFu; // Window boundary

  // 3. DMA Constraints
  if (addr >= 0x040000B0u && addr <= 0x040000DEu) {
    const uint32_t rel = addr - 0x040000B0u;
    const uint32_t ch = rel / 12u;
    const uint32_t reg = rel % 12u;
    if (reg == 8u && ch < 3u) value &= 0x3FFFu; // DMACNT_L (count)
    if (reg == 10u) {
       uint16_t mask = (ch == 3u) ? 0xFFE0u : 0xF7E0u;
       value &= mask;
       if (((value >> 12) & 0x3) == 3 && ch == 0) value &= ~(0x3u << 12); // DMA0 no timing=3
    }
  }

  // 4. Timer Side Effects
  if (addr >= 0x04000100u && addr <= 0x0400010Eu) {
    const uint32_t tidx = (addr - 0x04000100u) / 4u;
    const bool is_hi = (addr & 2) != 0;
    if (tidx < 4) {
      if (is_hi) {
        const uint16_t old = ReadIO16(addr);
        value &= 0x00C7u; if (tidx == 0) value &= ~0x0004u; // No count-up for T0
        timers_[tidx].control = value;
        if (!(old & 0x80u) && (value & 0x80u)) { // Enable
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
  }

  io_regs_[off] = static_cast<uint8_t>(value & 0xFFu);
  io_regs_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFFu);
}"""

# Update WriteIO16 in the content
pattern = r"void GBACore::WriteIO16\(uint32_t addr, uint16_t value\) \{.*?^\}"
content = re.sub(pattern, write_io16_body, content, flags=re.DOTALL | re.MULTILINE)

with open(path, "w") as f:
    f.write(content)
