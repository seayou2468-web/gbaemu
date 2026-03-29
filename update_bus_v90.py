import sys
import re

path = "src/core/gba_core_modules/memory_bus.mm"
with open(path, "r") as f:
    content = f.read()

# Update Write8 for VRAM/OAM/Palette to handle 8-bit writes correctly (hardware replication)
# Also fix the Write16Wrap call for OAM in Write16

write8_body = """void GBACore::Write8(uint32_t addr, uint8_t value) {
  AddWaitstates(addr, 1);
  UpdateOpenBus(addr, (static_cast<uint32_t>(value) * 0x01010101u), 1);

  if (addr >= 0x05000000u && addr <= 0x07FFFFFFu) {
    const uint32_t a = addr & ~1u;
    const uint16_t v16 = static_cast<uint16_t>(value) | (static_cast<uint16_t>(value) << 8);
    const uint16_t dispstat = ReadIO16(0x04000004u);
    if (a >= 0x07000000u) {
      if (dispstat & 1) Write16Wrap(oam_.data(), a & 0x3FFu, 0x3FFu, oam_.size(), v16);
    } else if ((dispstat & 1) || (dispstat & 2)) {
      if (a >= 0x06000000u) Write16Wrap(vram_.data(), VramOffset(a), 0x1FFFFu, vram_.size(), v16);
      else Write16Wrap(palette_ram_.data(), a & 0x3FFu, 0x3FFu, palette_ram_.size(), v16);
    }
    return;
  }

  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) { ewram_[addr & 0x3FFFFu] = value; }
  else if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) { iwram_[addr & 0x7FFFu] = value; }
  else if (addr >= 0x04000000u && addr <= 0x040003FFu) {
    const uint16_t old = ReadIO16(addr & ~1u);
    if (addr & 1u) WriteIO16(addr & ~1u, (old & 0xFFu) | (static_cast<uint16_t>(value) << 8));
    else WriteIO16(addr & ~1u, (old & 0xFF00u) | value);
  }
  else if (addr >= 0x0E000000u) { WriteBackup8(addr, value); }
}"""

content = re.sub(r"void GBACore::Write8\(uint32_t addr, uint8_t value\) \{.*?^\}", write8_body, content, flags=re.DOTALL | re.MULTILINE)

# Ensure Write16/Write32 use same logic
write16_body = """void GBACore::Write16(uint32_t addr, uint16_t value) {
  AddWaitstates(addr, 2);
  UpdateOpenBus(addr, (static_cast<uint32_t>(value) | (static_cast<uint32_t>(value) << 16)), 2);
  const uint32_t a = addr & ~1u;
  if (a >= 0x04000000u && a <= 0x040003FEu) { WriteIO16(a, value); return; }
  if (a >= 0x05000000u && a <= 0x07FFFFFFu) {
    const uint16_t dispstat = ReadIO16(0x04000004u);
    if (a >= 0x07000000u) {
      if (dispstat & 1) Write16Wrap(oam_.data(), a & 0x3FFu, 0x3FFu, oam_.size(), value);
    } else if ((dispstat & 1) || (dispstat & 2)) {
      if (a >= 0x06000000u) Write16Wrap(vram_.data(), VramOffset(a), 0x1FFFFu, vram_.size(), value);
      else Write16Wrap(palette_ram_.data(), a & 0x3FFu, 0x3FFu, palette_ram_.size(), value);
    }
    return;
  }
  Write8(a, static_cast<uint8_t>(value));
  Write8(a + 1u, static_cast<uint8_t>(value >> 8));
}"""

content = re.sub(r"void GBACore::Write16\(uint32_t addr, uint16_t value\) \{.*?^\}", write16_body, content, flags=re.DOTALL | re.MULTILINE)

with open(path, "w") as f:
    f.write(content)
