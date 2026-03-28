import sys
import re

path = "src/core/gba_core_modules/memory_bus.mm"
with open(path, "r") as f:
    full_content = f.read()

# Helper to replace functions
def replace_func(c, name, body):
    pattern = rf"(uint\d+_t|void) GBACore::{name}\(uint32_t addr(?:, (?:uint\d+_t|uint16_t|uint8_t) value)?\) (?:const )?\{{.*?^}}"
    if re.search(pattern, c, flags=re.DOTALL | re.MULTILINE):
        return re.sub(pattern, body, c, flags=re.DOTALL | re.MULTILINE)
    return c

# 1. ReadBus32: Centralized Aligned 32-bit Access with BIOS Protection and Mirroring
readbus32_body = """uint32_t GBACore::ReadBus32(uint32_t a) const {
  // a MUST be aligned to 4 bytes for this raw source.

  // BIOS Region (0x00xxxxxx)
  if (a < 0x04000000u) {
    if (a < 0x00004000u) {
      // BIOS Protection: Unauthorized read returns bios_fetch_latch_
      if (cpu_.regs[15] >= 0x00004000u) return bios_fetch_latch_;

      if (bios_loaded_ && a < bios_.size()) {
        const size_t off = static_cast<size_t>(a);
        const uint32_t val = static_cast<uint32_t>(bios_[off]) |
                             (static_cast<uint32_t>(bios_[off + 1]) << 8) |
                             (static_cast<uint32_t>(bios_[off + 2]) << 16) |
                             (static_cast<uint32_t>(bios_[off + 3]) << 24);
        // Internal bus updates latches
        if (a == (cpu_.regs[15] & ~3u)) bios_fetch_latch_ = val;
        else bios_data_latch_ = val;
        return val;
      }
      return bios_fetch_latch_;
    }
    // Unmapped in [0x00004000, 0x03FFFFFF] returns open bus
    // except for IWRAM/EWRAM which are handled below.
  }

  uint32_t val = open_bus_latch_;
  bool mapped = false;

  // EWRAM (0x02xxxxxx) - 256KB
  if (a >= 0x02000000u && a <= 0x02FFFFFFu) {
    val = Read32Wrap(ewram_.data(), MirrorOffset(a, 0x02000000u, 0x3FFFFu), 0x3FFFFu);
    mapped = true;
  }
  // IWRAM (0x03xxxxxx) - 32KB
  else if (a >= 0x03000000u && a <= 0x03FFFFFFu) {
    val = Read32Wrap(iwram_.data(), MirrorOffset(a, 0x03000000u, 0x7FFFu), 0x7FFFu);
    mapped = true;
  }
  // I/O (0x04xxxxxx)
  else if (a >= 0x04000000u && a <= 0x040003FCu) {
    val = static_cast<uint32_t>(ReadIO16(a)) | (static_cast<uint32_t>(ReadIO16(a + 2u)) << 16);
    mapped = true; // IO reads always update open bus, even for undefined bits.
  }
  // Palette / VRAM / OAM (0x05-0x07xxxxxx)
  else if (a >= 0x05000000u && a <= 0x07FFFFFFu) {
    const uint16_t dispstat = ReadIO16(0x04000004u);
    const bool vblank = (dispstat & 1);
    const bool hblank = (dispstat & 2);
    bool allowed = true;
    if (a >= 0x07000000u) { if (!vblank) allowed = false; }
    else if (a >= 0x05000000u && a <= 0x05FFFFFFu) { if (!vblank && !hblank) allowed = false; }

    if (allowed) {
      if (a >= 0x05000000u && a <= 0x05FFFFFFu)
        val = Read32Wrap(palette_ram_.data(), MirrorOffset(a, 0x05000000u, 0x3FFu), 0x3FFu);
      else if (a >= 0x06000000u && a <= 0x06FFFFFFu)
        val = Read32Wrap(vram_.data(), VramOffset(a), 0x1FFFFu);
      else if (a >= 0x07000000u)
        val = Read32Wrap(oam_.data(), MirrorOffset(a, 0x07000000u, 0x3FFu), 0x3FFu);
      mapped = true;
    } else {
      // Disallowed access returns open bus and does NOT update latch
      return open_bus_latch_;
    }
  }
  // ROM / EEPROM (0x08-0x0Dxxxxxx)
  else if (a >= 0x08000000u && a <= 0x0DFFFFFFu) {
    if (backup_type_ == BackupType::kEEPROM && a >= 0x0D000000u) {
      val = (open_bus_latch_ & ~1u) | (ReadBackup8(a) & 1u);
    } else if (!rom_.empty()) {
      const size_t base = static_cast<size_t>(a - 0x08000000u) & 0x01FFFFFFu;
      auto rb = [&](size_t off) { return (off < rom_.size()) ? rom_[off] : ((open_bus_latch_ >> ((off & 3)*8)) & 0xFF); };
      val = rb(base) | (rb(base+1) << 8) | (rb(base+2) << 16) | (rb(base+3) << 24);
    }
    mapped = true;
  }
  // SRAM / Flash (0x0E-0x0Fxxxxxx)
  else if (a >= 0x0E000000u) {
    val = static_cast<uint32_t>(ReadBackup8(a)) |
          (static_cast<uint32_t>(ReadBackup8(a + 1)) << 8) |
          (static_cast<uint32_t>(ReadBackup8(a + 2)) << 16) |
          (static_cast<uint32_t>(ReadBackup8(a + 3)) << 24);
    mapped = true;
  }

  if (mapped) open_bus_latch_ = val;
  return val;
}"""

# 2. Read32: Fully Aligned to Hardware Logic
read32_body = """uint32_t GBACore::Read32(uint32_t addr) const {
  const uint32_t aligned = addr & ~3u;
  const uint32_t val = ReadBus32(aligned);
  const uint32_t rot = (addr & 3u) * 8u;
  return (rot == 0) ? val : RotateRight(val, rot);
}"""

# 3. Read16: Correct Sequential Fetch for Misaligned
read16_body = """uint16_t GBACore::Read16(uint32_t addr) const {
  if (addr & 1u) {
    // Hardware unaligned Read16 returns bytes combined.
    // This is essentially equivalent to two 8-bit reads.
    return static_cast<uint16_t>(Read8(addr)) | (static_cast<uint16_t>(Read8(addr + 1)) << 8);
  }
  const uint32_t aligned = addr & ~3u;
  const uint32_t val = ReadBus32(aligned);
  return static_cast<uint16_t>((val >> ((addr & 2u) * 8u)) & 0xFFFFu);
}"""

# 4. Read8: Proper 32-bit Fetch and Mask
read8_body = """uint8_t GBACore::Read8(uint32_t addr) const {
  const uint32_t aligned = addr & ~3u;
  const uint32_t val = ReadBus32(aligned);
  return static_cast<uint8_t>((val >> ((addr & 3u) * 8u)) & 0xFFu);
}"""

content = replace_func(full_content, "ReadBus32", readbus32_body)
content = replace_func(content, "Read32", read32_body)
content = replace_func(content, "Read16", read16_body)
content = replace_func(content, "Read8", read8_body)

with open(path, "w") as f:
    f.write(content)
