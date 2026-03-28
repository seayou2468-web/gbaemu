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

# 1. UpdateOpenBus: Accurate latch behavior
update_open_bus = """void GBACore::UpdateOpenBus(uint32_t addr, uint32_t val, int size) const {
  if (addr < 0x02000000u) return;

  if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u && addr <= 0x0DFFFFFFu) {
    open_bus_latch_ = (open_bus_latch_ & ~1u) | (val & 1u);
    return;
  }

  if (size == 4) {
    open_bus_latch_ = val;
  } else if (size == 2) {
    // 16-bit write/read: latch is updated with halfword replicated or lane-specific?
    // GBA behavior: 16-bit on 32-bit bus usually puts it on both half-lanes.
    open_bus_latch_ = (val & 0xFFFFu) | (static_cast<uint32_t>(val & 0xFFFFu) << 16);
  } else if (size == 1) {
    // 8-bit write/read: latch is updated with byte replicated across all lanes.
    open_bus_latch_ = (val & 0xFFu) * 0x01010101u;
  }
}"""

# 2. Read wrappers: Correct BIOS protection and Unaligned logic
read32 = """uint32_t GBACore::Read32(uint32_t addr) const {
  // BIOS Protection
  if (addr < 0x00004000u && cpu_.regs[15] >= 0x00004000u) {
    return open_bus_latch_;
  }

  const uint32_t val = ReadBus32(addr);
  UpdateOpenBus(addr, val, 4);
  const uint32_t rot = (addr & 3u) * 8u;
  return (rot == 0) ? val : RotateRight(val, rot);
}"""

read16 = """uint16_t GBACore::Read16(uint32_t addr) const {
  if (addr < 0x00004000u && cpu_.regs[15] >= 0x00004000u) {
    return static_cast<uint16_t>(open_bus_latch_ >> ((addr & 2u) * 8u));
  }

  const uint32_t val = ReadBus32(addr);
  const uint32_t shift = (addr & 2u) * 8u;
  uint16_t res = static_cast<uint16_t>(val >> shift);
  if (addr & 1u) res = (res >> 8) | (res << 8); // Unaligned rotation
  UpdateOpenBus(addr, res, 2);
  return res;
}"""

read8 = """uint8_t GBACore::Read8(uint32_t addr) const {
  if (addr < 0x00004000u && cpu_.regs[15] >= 0x00004000u) {
    return static_cast<uint8_t>(open_bus_latch_ >> ((addr & 3u) * 8u));
  }

  const uint32_t val = ReadBus32(addr);
  const uint32_t shift = (addr & 3u) * 8u;
  uint8_t res = static_cast<uint8_t>(val >> shift);
  UpdateOpenBus(addr, res, 1);
  return res;
}"""

# 3. Write wrappers: Decompose and handle PPU alignment
write32 = """void GBACore::Write32(uint32_t addr, uint32_t value) {
  if (addr == 0x040000A0u || addr == 0x040000A4u) { PushAudioFifo(addr == 0x040000A0u, value); return; }

  // Update latch with word
  UpdateOpenBus(addr, value, 4);

  // Decomposition
  Write16(addr, static_cast<uint16_t>(value));
  Write16(addr + 2u, static_cast<uint16_t>(value >> 16));
}"""

write16 = """void GBACore::Write16(uint32_t addr, uint16_t value) {
  UpdateOpenBus(addr, value, 2);

  const uint32_t a = addr;
  if (a >= 0x04000000u && a <= 0x040003FEu) { WriteIO16(a & ~1u, value); return; }

  if (a >= 0x05000000u && a <= 0x07FFFFFFu) {
    const uint16_t dispstat = ReadIO16(0x04000004u);
    const bool vblank = (dispstat & 1);
    const bool hblank = (dispstat & 2);

    // Aligned write check
    const uint32_t aligned = a & ~1u;

    if (aligned >= 0x07000000u) { // OAM
      if (vblank) Write16Wrap(oam_.data(), aligned & 0x3FFu, 0x3FFu, oam_.size(), value);
    } else { // Palette or VRAM
      if (vblank || hblank) {
        if (aligned >= 0x06000000u) Write16Wrap(vram_.data(), VramOffset(aligned), 0x1FFFFu, vram_.size(), value);
        else Write16Wrap(palette_ram_.data(), aligned & 0x3FFu, 0x3FFu, palette_ram_.size(), value);
      }
    }
    return;
  }

  Write8(a, static_cast<uint8_t>(value));
  Write8(a + 1u, static_cast<uint8_t>(value >> 8));
}"""

write8 = """void GBACore::Write8(uint32_t addr, uint8_t value) {
  UpdateOpenBus(addr, value, 1);

  if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    // Palette RAM: 8-bit write duplicated to 16-bit
    const uint16_t dispstat = ReadIO16(0x04000004u);
    if ((dispstat & 1) || (dispstat & 2)) {
      const uint32_t aligned = addr & ~1u;
      const uint16_t v16 = value | (static_cast<uint16_t>(value) << 8);
      Write16Wrap(palette_ram_.data(), aligned & 0x3FFu, 0x3FFu, palette_ram_.size(), v16);
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

content = replace_func(content, "UpdateOpenBus", update_open_bus)
content = replace_func(content, "Read32", read32)
content = replace_func(content, "Read16", read16)
content = replace_func(content, "Read8", read8)
content = replace_func(content, "Write32", write32)
content = replace_func(content, "Write16", write16)
content = replace_func(content, "Write8", write8)

with open(path, "w") as f:
    f.write(content)
