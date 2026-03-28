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

# 1. ReadBus32: Correct BIOS protection (Open Bus based), PPU guards, and Mirroring
readbus32_body = """uint32_t GBACore::ReadBus32(uint32_t a) const {
  a &= ~3u;
  // BIOS Region
  if (a < 0x00004000u) {
    if (cpu_.regs[15] < 0x00004000u) {
      if (bios_loaded_ && a < bios_.size()) {
        const size_t off = static_cast<size_t>(a);
        const uint32_t val = static_cast<uint32_t>(bios_[off]) |
                             (static_cast<uint32_t>(bios_[off + 1]) << 8) |
                             (static_cast<uint32_t>(bios_[off + 2]) << 16) |
                             (static_cast<uint32_t>(bios_[off + 3]) << 24);
        if (a == (cpu_.regs[15] & ~3u)) bios_fetch_latch_ = val;
        else bios_data_latch_ = val;
        return val;
      }
    }
    // BIOS Protection: return open_bus_latch_
    return open_bus_latch_;
  }

  // EWRAM
  if (a >= 0x02000000u && a <= 0x02FFFFFFu) {
    return Read32Wrap(ewram_.data(), a & 0x3FFFFu, 0x3FFFFu);
  }
  // IWRAM
  if (a >= 0x03000000u && a <= 0x03FFFFFFu) {
    return Read32Wrap(iwram_.data(), a & 0x7FFFu, 0x7FFFu);
  }
  // I/O
  if (a >= 0x04000000u && a <= 0x040003FCu) {
    return static_cast<uint32_t>(ReadIO16(a)) | (static_cast<uint32_t>(ReadIO16(a + 2u)) << 16);
  }
  // PPU
  if (a >= 0x05000000u && a <= 0x07FFFFFFu) {
    const uint16_t dispstat = ReadIO16(0x04000004u);
    const bool vblank = (dispstat & 1);
    const bool hblank = (dispstat & 2);

    if (a >= 0x07000000u) { // OAM
      if (!vblank) return open_bus_latch_;
      return Read32Wrap(oam_.data(), a & 0x3FFu, 0x3FFu);
    }
    // Palette or VRAM: allowed if VBlank OR HBlank
    if (!vblank && !hblank) return open_bus_latch_;

    if (a >= 0x06000000u) { // VRAM
      return Read32Wrap(vram_.data(), VramOffset(a), 0x1FFFFu);
    }
    // Palette
    return Read32Wrap(palette_ram_.data(), a & 0x3FFu, 0x3FFu);
  }
  // ROM / EEPROM
  if (a >= 0x08000000u && a <= 0x0DFFFFFFu) {
    if (backup_type_ == BackupType::kEEPROM && a >= 0x0D000000u) {
      return (open_bus_latch_ & ~1u) | (ReadBackup8(a) & 1u);
    }
    if (!rom_.empty()) {
      const size_t base = static_cast<size_t>(a - 0x08000000u) & 0x01FFFFFFu;
      auto rb = [&](size_t off) {
        return (off < rom_.size()) ? rom_[off] : ((open_bus_latch_ >> ((off & 3)*8)) & 0xFF);
      };
      return rb(base) | (rb(base+1) << 8) | (rb(base+2) << 16) | (rb(base+3) << 24);
    }
  }
  // Backup
  if (a >= 0x0E000000u) {
    return static_cast<uint32_t>(ReadBackup8(a)) |
           (static_cast<uint32_t>(ReadBackup8(a + 1)) << 8) |
           (static_cast<uint32_t>(ReadBackup8(a + 2)) << 16) |
           (static_cast<uint32_t>(ReadBackup8(a + 3)) << 24);
  }

  return open_bus_latch_;
}"""

# 2. Read accessors with partial latch updates
read32_body = """uint32_t GBACore::Read32(uint32_t addr) const {
  const uint32_t val = ReadBus32(addr);
  if (addr >= 0x02000000u) open_bus_latch_ = val;
  const uint32_t rot = (addr & 3u) * 8u;
  return (rot == 0) ? val : RotateRight(val, rot);
}"""

read16_body = """uint16_t GBACore::Read16(uint32_t addr) const {
  if (addr & 1u) return static_cast<uint16_t>(Read8(addr)) | (static_cast<uint16_t>(Read8(addr + 1)) << 8);
  const uint32_t val = ReadBus32(addr);
  const uint32_t shift = (addr & 2u) * 8u;
  const uint16_t res = static_cast<uint16_t>(val >> shift);
  if (addr >= 0x02000000u) {
    if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u && addr <= 0x0DFFFFFFu) {
      open_bus_latch_ = (open_bus_latch_ & ~1u) | (val & 1u);
    } else {
      const uint32_t mask = 0xFFFFu << shift;
      open_bus_latch_ = (open_bus_latch_ & ~mask) | (static_cast<uint32_t>(res) << shift);
    }
  }
  return res;
}"""

read8_body = """uint8_t GBACore::Read8(uint32_t addr) const {
  const uint32_t val = ReadBus32(addr);
  const uint32_t shift = (addr & 3u) * 8u;
  const uint8_t res = static_cast<uint8_t>(val >> shift);
  if (addr >= 0x02000000u) {
    if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u && addr <= 0x0DFFFFFFu) {
      open_bus_latch_ = (open_bus_latch_ & ~1u) | (val & 1u);
    } else {
      const uint32_t mask = 0xFFu << shift;
      open_bus_latch_ = (open_bus_latch_ & ~mask) | (static_cast<uint32_t>(res) << shift);
    }
  }
  return res;
}"""

# 3. Write decomposition
write32_body = """void GBACore::Write32(uint32_t addr, uint32_t value) {
  open_bus_latch_ = value;
  if (addr == 0x040000A0u || addr == 0x040000A4u) { PushAudioFifo(addr == 0x040000A0u, value); return; }
  Write16(addr, static_cast<uint16_t>(value));
  Write16(addr + 2u, static_cast<uint16_t>(value >> 16));
}"""

write16_body = """void GBACore::Write16(uint32_t addr, uint16_t value) {
  open_bus_latch_ = (value | (static_cast<uint32_t>(value) << 16));
  if (addr >= 0x04000000u && addr <= 0x040003FEu) { WriteIO16(addr, value); return; }
  if (addr >= 0x05000000u && addr <= 0x07FFFFFFu) {
    if (addr & 1u) return;
    const uint16_t dispstat = ReadIO16(0x04000004u);
    const bool vblank = (dispstat & 1);
    const bool hblank = (dispstat & 2);
    if (addr >= 0x07000000u) {
      if (!vblank) return;
      Write16Wrap(oam_.data(), addr & 0x3FFu, 0x3FFu, value);
    } else if (!vblank && !hblank) {
      return;
    } else if (addr >= 0x06000000u) {
      Write16Wrap(vram_.data(), VramOffset(addr), 0x1FFFFu, value);
    } else {
      Write16Wrap(palette_ram_.data(), addr & 0x3FFu, 0x3FFu, value);
    }
    return;
  }
  Write8(addr, static_cast<uint8_t>(value));
  Write8(addr + 1u, static_cast<uint8_t>(value >> 8));
}"""

write8_body = """void GBACore::Write8(uint32_t addr, uint8_t value) {
  open_bus_latch_ = (value | (value << 8) | (value << 16) | (value << 24));
  if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    const uint32_t a = addr & ~1u;
    const uint16_t v = value | (static_cast<uint16_t>(value) << 8);
    Write16Wrap(palette_ram_.data(), a & 0x3FFu, 0x3FFu, v);
    return;
  }
  if (addr >= 0x06000000u && addr <= 0x07FFFFFFu) return;
  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) { ewram_[addr & 0x3FFFFu] = value; }
  else if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) { iwram_[addr & 0x7FFFu] = value; }
  else if (addr >= 0x04000000u && addr <= 0x040003FFu) {
    const uint16_t old = ReadIO16(addr & ~1u);
    if (addr & 1u) WriteIO16(addr & ~1u, (old & 0xFFu) | (static_cast<uint16_t>(value) << 8));
    else WriteIO16(addr & ~1u, (old & 0xFF00u) | value);
  }
  else if (addr >= 0x0E000000u) { WriteBackup8(addr, value); }
}"""

content = replace_func(full_content, "ReadBus32", readbus32_body)
content = replace_func(content, "Read32", read32_body)
content = replace_func(content, "Read16", read16_body)
content = replace_func(content, "Read8", read8_body)
content = replace_func(content, "Write32", write32_body)
content = replace_func(content, "Write16", write16_body)
content = replace_func(content, "Write8", write8_body)

with open(path, "w") as f:
    f.write(content)
