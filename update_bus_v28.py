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

# 1. ReadBus32: Consolidated and Fixed
readbus32_body = """uint32_t GBACore::ReadBus32(uint32_t a) const {
  a &= ~3u;

  // 1. BIOS Region (0x00xxxxxx)
  if (a < 0x04000000u) {
    if (a < 0x00004000u) {
      const bool in_bios = (cpu_.regs[15] < 0x00004000u);
      if (in_bios) {
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
        return bios_fetch_latch_;
      } else {
        // Protected BIOS access: Use last open bus latch as per user directive
        return open_bus_latch_;
      }
    }
    // Addresses 0x00004000 - 0x01FFFFFF are typically open bus on GBA
    // unless mapped to EWRAM/IWRAM which are handled below.
  }

  uint32_t val = open_bus_latch_;
  bool mapped = false;

  // EWRAM
  if (a >= 0x02000000u && a <= 0x02FFFFFFu) {
    val = Read32Wrap(ewram_.data(), a & 0x3FFFFu, 0x3FFFFu);
    mapped = true;
  }
  // IWRAM
  else if (a >= 0x03000000u && a <= 0x03FFFFFFu) {
    val = Read32Wrap(iwram_.data(), a & 0x7FFFu, 0x7FFFu);
    mapped = true;
  }
  // I/O
  else if (a >= 0x04000000u && a <= 0x040003FCu) {
    val = static_cast<uint32_t>(ReadIO16(a)) | (static_cast<uint32_t>(ReadIO16(a + 2u)) << 16);
    mapped = true;
  }
  // PPU
  else if (a >= 0x05000000u && a <= 0x07FFFFFFu) {
    const uint16_t dispstat = ReadIO16(0x04000004u);
    const bool vblank = (dispstat & 1);
    const bool hblank = (dispstat & 2);

    if (a >= 0x07000000u) { // OAM
      if (vblank) {
        val = Read32Wrap(oam_.data(), a & 0x3FFu, 0x3FFu);
        mapped = true;
      }
    } else {
      if (vblank || hblank) {
        if (a >= 0x06000000u) { // VRAM
          val = Read32Wrap(vram_.data(), VramOffset(a), 0x1FFFFu);
        } else { // Palette
          val = Read32Wrap(palette_ram_.data(), a & 0x3FFu, 0x3FFu);
        }
        mapped = true;
      }
    }
  }
  // ROM / EEPROM
  else if (a >= 0x08000000u && a <= 0x0DFFFFFFu) {
    if (backup_type_ == BackupType::kEEPROM && a >= 0x0D000000u) {
      val = (open_bus_latch_ & ~1u) | (ReadBackup8(a) & 1u);
    } else if (!rom_.empty()) {
      const size_t base = static_cast<size_t>(a - 0x08000000u) & 0x01FFFFFFu;
      auto rb = [&](size_t off) {
        return (off < rom_.size()) ? rom_[off] : ((open_bus_latch_ >> ((off & 3)*8)) & 0xFF);
      };
      val = rb(base) | (rb(base+1) << 8) | (rb(base+2) << 16) | (rb(base+3) << 24);
    }
    mapped = true;
  }
  // Backup
  else if (a >= 0x0E000000u) {
    val = static_cast<uint32_t>(ReadBackup8(a)) |
          (static_cast<uint32_t>(ReadBackup8(a + 1)) << 8) |
          (static_cast<uint32_t>(ReadBackup8(a + 2)) << 16) |
          (static_cast<uint32_t>(ReadBackup8(a + 3)) << 24);
    mapped = true;
  }

  if (mapped) {
    open_bus_latch_ = val;
  }
  return val;
}"""

# 2. Read accessors with precise latch updates
# EEPROM update is 1-bit only
read32_body = """uint32_t GBACore::Read32(uint32_t addr) const {
  const uint32_t val = ReadBus32(addr);
  const uint32_t rot = (addr & 3u) * 8u;
  return (rot == 0) ? val : RotateRight(val, rot);
}"""

read16_body = """uint16_t GBACore::Read16(uint32_t addr) const {
  if (addr & 1u) {
    return static_cast<uint16_t>(Read8(addr)) | (static_cast<uint16_t>(Read8(addr + 1)) << 8);
  }
  const uint32_t val = ReadBus32(addr);
  const uint32_t shift = (addr & 2u) * 8u;
  const uint16_t res = static_cast<uint16_t>(val >> shift);

  if (addr >= 0x08000000u && addr <= 0x0DFFFFFFu && backup_type_ == BackupType::kEEPROM) {
    // ReadBus32 already updated latch for EEPROM
  } else if (addr >= 0x02000000u) {
    const uint32_t mask = 0xFFFFu << shift;
    open_bus_latch_ = (open_bus_latch_ & ~mask) | (static_cast<uint32_t>(res) << shift);
  }
  return res;
}"""

read8_body = """uint8_t GBACore::Read8(uint32_t addr) const {
  const uint32_t val = ReadBus32(addr);
  const uint32_t shift = (addr & 3u) * 8u;
  const uint8_t res = static_cast<uint8_t>(val >> shift);

  if (addr >= 0x08000000u && addr <= 0x0DFFFFFFu && backup_type_ == BackupType::kEEPROM) {
    // ReadBus32 already updated latch
  } else if (addr >= 0x02000000u) {
    const uint32_t mask = 0xFFu << shift;
    open_bus_latch_ = (open_bus_latch_ & ~mask) | (static_cast<uint32_t>(res) << shift);
  }
  return res;
}"""

content = replace_func(full_content, "ReadBus32", readbus32_body)
content = replace_func(content, "Read32", read32_body)
content = replace_func(content, "Read16", read16_body)
content = replace_func(content, "Read8", read8_body)

with open(path, "w") as f:
    f.write(content)
