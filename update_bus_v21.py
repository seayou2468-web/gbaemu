import sys
import re

path = "src/core/gba_core_modules/memory_bus.mm"
with open(path, "r") as f:
    content = f.read()

def replace_func(c, name, body):
    pattern = rf"(uint\d+_t|void) GBACore::{name}\(uint32_t addr(?:, (?:uint\d+_t|uint16_t|uint8_t) value)?\) (?:const )?\{{.*?^}}"
    if re.search(pattern, c, flags=re.DOTALL | re.MULTILINE):
        return re.sub(pattern, body, c, flags=re.DOTALL | re.MULTILINE)
    return c + "\n\n" + body

# 1. ReadBus32: Strict Raw Aligned 32-bit Source
readbus32_body = """uint32_t GBACore::ReadBus32(uint32_t a) const {
  // a is ALWAYS aligned to 4 bytes

  // 1. BIOS Region
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
    // Protected BIOS access: return the fetch latch.
    // GBA hardware logic: unauthorized BIOS read returns the most recent BIOS fetch.
    return bios_fetch_latch_;
  }

  // 2. System Bus Regions
  uint32_t val = open_bus_latch_;

  if (a >= 0x02000000u && a <= 0x02FFFFFFu) { // EWRAM
    val = Read32Wrap(ewram_.data(), MirrorOffset(a, 0x02000000u, 0x3FFFFu), 0x3FFFFu);
  } else if (a >= 0x03000000u && a <= 0x03FFFFFFu) { // IWRAM
    val = Read32Wrap(iwram_.data(), MirrorOffset(a, 0x03000000u, 0x7FFFu), 0x7FFFu);
  } else if (a >= 0x04000000u && a <= 0x040003FCu) { // IO
    // IO registers return open bus bits for undefined/unreadable bits.
    // We fetch 16-bit at a time.
    uint32_t lo = ReadIO16(a);
    uint32_t hi = ReadIO16(a + 2u);
    val = lo | (hi << 16);
    // Note: A more precise IO read would merge with open_bus_latch_ per-register.
  } else if (a >= 0x05000000u && a <= 0x07FFFFFFu) { // PPU
    const uint16_t dispstat = ReadIO16(0x04000004u);
    const bool vblank = (dispstat & 1);
    const bool hblank = (dispstat & 2);
    bool allowed = true;
    if (a >= 0x07000000u) { if (!vblank) allowed = false; } // OAM
    else if (a >= 0x05000000u && a <= 0x05FFFFFFu) { if (!vblank && !hblank) allowed = false; } // Palette
    // VRAM is generally accessible but may have waitstates or access patterns.

    if (allowed) {
      if (a >= 0x05000000u && a <= 0x05FFFFFFu)
        val = Read32Wrap(palette_ram_.data(), MirrorOffset(a, 0x05000000u, 0x3FFu), 0x3FFu);
      else if (a >= 0x06000000u && a <= 0x06FFFFFFu)
        val = Read32Wrap(vram_.data(), VramOffset(a), 0x1FFFFu);
      else if (a >= 0x07000000u)
        val = Read32Wrap(oam_.data(), MirrorOffset(a, 0x07000000u, 0x3FFu), 0x3FFu);
    }
  } else if (a >= 0x08000000u && a <= 0x0DFFFFFFu) { // ROM / EEPROM
    if (backup_type_ == BackupType::kEEPROM && a >= 0x0D000000u) {
      val = (open_bus_latch_ & ~1u) | (ReadBackup8(a) & 1u);
    } else if (!rom_.empty()) {
      const size_t base = static_cast<size_t>(a - 0x08000000u) & 0x01FFFFFFu;
      // Handle ROM mirroring if size is not power of 2
      auto read_rom_byte = [&](size_t addr) -> uint32_t {
        if (addr >= rom_.size()) return (open_bus_latch_ >> ((addr & 3) * 8)) & 0xFF;
        return rom_[addr];
      };
      val = read_rom_byte(base) | (read_rom_byte(base + 1) << 8) |
            (read_rom_byte(base + 2) << 16) | (read_rom_byte(base + 3) << 24);
    }
  } else if (a >= 0x0E000000u) { // Backup (SRAM/Flash)
    // Sequential 4-byte read for 32-bit access
    val = static_cast<uint32_t>(ReadBackup8(a)) |
          (static_cast<uint32_t>(ReadBackup8(a + 1)) << 8) |
          (static_cast<uint32_t>(ReadBackup8(a + 2)) << 16) |
          (static_cast<uint32_t>(ReadBackup8(a + 3)) << 24);
  }

  return val;
}"""

# 2. Read32: Rotated 32-bit access
read32_body = """uint32_t GBACore::Read32(uint32_t addr) const {
  const uint32_t aligned = addr & ~3u;
  const uint32_t val = ReadBus32(aligned);

  // Update open bus latch if not in BIOS protection
  if (addr >= 0x00004000u) {
    open_bus_latch_ = val;
  }

  const uint32_t rot = (addr & 3u) * 8u;
  return (rot == 0) ? val : RotateRight(val, rot);
}"""

# 3. Read16: Sequential 8-bit for unaligned, partial latch update for aligned
read16_body = """uint16_t GBACore::Read16(uint32_t addr) const {
  if (addr & 1u) {
    // Unaligned Read16 is two sequential Read8s
    return static_cast<uint16_t>(Read8(addr)) | (static_cast<uint16_t>(Read8(addr + 1)) << 8);
  }

  const uint32_t aligned = addr & ~3u;
  const uint32_t val = ReadBus32(aligned);
  const uint32_t shift = (addr & 2u) * 8u;
  const uint16_t result = static_cast<uint16_t>((val >> shift) & 0xFFFFu);

  if (addr >= 0x00004000u) {
    // Partial update of open_bus_latch_
    const uint32_t mask = 0xFFFFu << shift;
    open_bus_latch_ = (open_bus_latch_ & ~mask) | (static_cast<uint32_t>(result) << shift);
  }

  return result;
}"""

# 4. Read8: Partial latch update
read8_body = """uint8_t GBACore::Read8(uint32_t addr) const {
  const uint32_t aligned = addr & ~3u;
  const uint32_t val = ReadBus32(aligned);
  const uint32_t shift = (addr & 3u) * 8u;
  const uint8_t result = static_cast<uint8_t>((val >> shift) & 0xFFu);

  if (addr >= 0x00004000u) {
    // Partial update of open_bus_latch_
    const uint32_t mask = 0xFFu << shift;
    open_bus_latch_ = (open_bus_latch_ & ~mask) | (static_cast<uint32_t>(result) << shift);
  }

  return result;
}"""

content = replace_func(content, "ReadBus32", readbus32_body)
content = replace_func(content, "Read32", read32_body)
content = replace_func(content, "Read16", read16_body)
content = replace_func(content, "Read8", read8_body)

with open(path, "w") as f:
    f.write(content)
