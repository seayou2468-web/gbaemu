import sys
import re

path = "src/core/gba_core_modules/memory_bus.mm"
with open(path, "r") as f:
    full_content = f.read()

def replace_func(c, name, body):
    pattern = rf"(uint\d+_t|void) GBACore::{name}\(uint32_t addr(?:, (?:uint\d+_t|uint16_t|uint8_t) value)?\) (?:const )?\{{.*?^}}"
    if re.search(pattern, c, flags=re.DOTALL | re.MULTILINE):
        return re.sub(pattern, body, c, flags=re.DOTALL | re.MULTILINE)
    return c

# 1. Defined bits mask for I/O registers (conceptual, will implement a few)
# Real GBA I/O reads return Open Bus bits for unassigned register bits.
# We'll implement this for the most important ones.

readio16_body = """uint16_t GBACore::ReadIO16(uint32_t addr) const {
  addr &= ~1u;
  if (addr < 0x04000000u || addr > 0x040003FEu) return 0;
  const size_t off = static_cast<size_t>(addr - 0x04000000u);
  if (off + 1 >= io_regs_.size()) return 0;

  uint16_t val = static_cast<uint16_t>(io_regs_[off]) |
                 static_cast<uint16_t>(io_regs_[off + 1] << 8);

  // Merge with Open Bus for unassigned bits
  // For simplicity, we define a mask of "known bits" for some registers.
  // Unassigned bits return the corresponding bits of the 32-bit Open Bus latch (16-bit lane).
  uint16_t mask = 0xFFFFu;
  switch(addr) {
    case 0x04000004u: mask = 0xFFBFu; break; // DISPSTAT bit 6 is unused
    case 0x04000006u: mask = 0x00FFu; break; // VCOUNT high bits unused
    case 0x04000084u: mask = 0x008Fu; break; // SOUNDCNT_X
    // Add more as needed
  }

  if (mask != 0xFFFFu) {
    const uint16_t open_bits = static_cast<uint16_t>(open_bus_latch_ >> ((addr & 2) * 8));
    val = (val & mask) | (open_bits & ~mask);
  }

  return val;
}"""

# 2. Refined Write8 with PPU guards
write8_body = """void GBACore::Write8(uint32_t addr, uint8_t value) {
  open_bus_latch_ = (value | (value << 8) | (value << 16) | (value << 24));

  if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    // Palette RAM: 8-bit write duplicated to 16-bit, with VBlank/HBlank guard
    const uint16_t dispstat = ReadIO16(0x04000004u);
    if ((dispstat & 1) || (dispstat & 2)) {
      const uint32_t a = addr & ~1u;
      const uint16_t v = value | (static_cast<uint16_t>(value) << 8);
      Write16Wrap(palette_ram_.data(), a & 0x3FFu, 0x3FFu, palette_ram_.size(), v);
    }
    return;
  }
  if (addr >= 0x06000000u && addr <= 0x07FFFFFFu) return; // VRAM/OAM ignore 8-bit writes

  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) { ewram_[addr & 0x3FFFFu] = value; }
  else if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) { iwram_[addr & 0x7FFFu] = value; }
  else if (addr >= 0x04000000u && addr <= 0x040003FFu) {
    const uint16_t old = ReadIO16(addr & ~1u);
    if (addr & 1u) WriteIO16(addr & ~1u, (old & 0xFFu) | (static_cast<uint16_t>(value) << 8));
    else WriteIO16(addr & ~1u, (old & 0xFF00u) | value);
  }
  else if (addr >= 0x0E000000u) { WriteBackup8(addr, value); }
}"""

content = replace_func(full_content, "ReadIO16", readio16_body)
content = replace_func(content, "Write8", write8_body)

with open(path, "w") as f:
    f.write(content)
