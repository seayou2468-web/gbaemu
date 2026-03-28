import sys
import re

def replace_func(content, name, new_body):
    pattern = rf"(uint\d+_t|void) GBACore::{name}\(uint32_t addr(?:, uint\d+_t value)?\) (?:const )?\{{.*?^}}"
    return re.sub(pattern, new_body, content, flags=re.DOTALL | re.MULTILINE)

bus_path = "src/core/gba_core_modules/memory_bus.mm"
with open(bus_path, "r") as f:
    content = f.read()

# 1. Read32: Single implementation
read32_body = """uint32_t GBACore::Read32(uint32_t addr) const {
  const uint32_t a = addr & ~3u;

  // BIOS Protection
  if (a < 0x00004000u) {
    if (cpu_.regs[15] >= 0x00004000u) return open_bus_latch_;
    if (bios_loaded_ && a < bios_.size()) {
      const size_t off = static_cast<size_t>(a);
      const uint32_t val = static_cast<uint32_t>(bios_[off]) |
                           (static_cast<uint32_t>(bios_[off + 1]) << 8) |
                           (static_cast<uint32_t>(bios_[off + 2]) << 16) |
                           (static_cast<uint32_t>(bios_[off + 3]) << 24);
      if (a == (cpu_.regs[15] & ~3u)) bios_fetch_latch_ = val;
      else bios_data_latch_ = val;
      // BIOS reads do not update system open_bus_latch_
      return val;
    }
    return bios_fetch_latch_;
  }

  uint32_t val = open_bus_latch_;
  bool mapped = false;

  if (a >= 0x02000000u && a <= 0x02FFFFFFu) {
    val = Read32Wrap(ewram_.data(), MirrorOffset(a, 0x02000000u, 0x3FFFFu), 0x3FFFFu);
    mapped = true;
  } else if (a >= 0x03000000u && a <= 0x03FFFFFFu) {
    val = Read32Wrap(iwram_.data(), MirrorOffset(a, 0x03000000u, 0x7FFFu), 0x7FFFu);
    mapped = true;
  } else if (a >= 0x04000000u && a <= 0x040003FCu) {
    val = static_cast<uint32_t>(ReadIO16(a)) | (static_cast<uint32_t>(ReadIO16(a + 2u)) << 16);
    mapped = true;
  } else if (a >= 0x05000000u && a <= 0x07FFFFFFu) {
    val = Read32Wrap(palette_ram_.data(), MirrorOffset(a, 0x05000000u, 0x3FFu), 0x3FFu);
    if (a >= 0x06000000u && a <= 0x06FFFFFFu) val = Read32Wrap(vram_.data(), VramOffset(a), 0x1FFFFu);
    else if (a >= 0x07000000u) val = Read32Wrap(oam_.data(), MirrorOffset(a, 0x07000000u, 0x3FFu), 0x3FFu);
    mapped = true;
  } else if (a >= 0x08000000u && a <= 0x0DFFFFFFu) {
    if (backup_type_ == BackupType::kEEPROM && a >= 0x0D000000u) {
      val = (open_bus_latch_ & ~1u) | (ReadBackup8(a) & 1u);
    } else if (!rom_.empty()) {
      const size_t base = static_cast<size_t>((a - 0x08000000u) & 0x01FFFFFFu);
      val = static_cast<uint32_t>(rom_[base % rom_.size()]) |
            (static_cast<uint32_t>(rom_[(base + 1) % rom_.size()]) << 8) |
            (static_cast<uint32_t>(rom_[(base + 2) % rom_.size()]) << 16) |
            (static_cast<uint32_t>(rom_[(base + 3) % rom_.size()]) << 24);
    }
    mapped = true;
  } else if (a >= 0x0E000000u) {
    if (backup_type_ == BackupType::kSRAM) {
      const uint8_t v8 = ReadBackup8(a);
      val = v8 | (v8 << 8) | (v8 << 16) | (v8 << 24);
      mapped = true;
    }
  }

  if (mapped) open_bus_latch_ = val;
  const uint32_t rot = (addr & 3u) * 8u;
  return (rot == 0) ? val : RotateRight(val, rot);
}"""

# 2. Read16: Independent
read16_body = """uint16_t GBACore::Read16(uint32_t addr) const {
  if (addr & 1u) {
    return static_cast<uint16_t>(Read8(addr)) | (static_cast<uint16_t>(Read8(addr + 1u)) << 8);
  }
  const uint32_t a = addr & ~1u;
  if (a < 0x00004000u) {
    if (cpu_.regs[15] >= 0x00004000u) return static_cast<uint16_t>((open_bus_latch_ >> ((addr & 2u) * 8u)) & 0xFFFFu);
    return static_cast<uint16_t>((bios_fetch_latch_ >> ((addr & 2u) * 8u)) & 0xFFFFu);
  }

  uint32_t full = open_bus_latch_;
  bool mapped = false;
  if (a >= 0x02000000u && a <= 0x02FFFFFFu) {
    full = Read32Wrap(ewram_.data(), MirrorOffset(a & ~3u, 0x02000000u, 0x3FFFFu), 0x3FFFFu);
    mapped = true;
  } else if (a >= 0x03000000u && a <= 0x03FFFFFFu) {
    full = Read32Wrap(iwram_.data(), MirrorOffset(a & ~3u, 0x03000000u, 0x7FFFu), 0x7FFFu);
    mapped = true;
  } else if (a >= 0x04000000u && a <= 0x040003FEu) {
    full = static_cast<uint32_t>(ReadIO16(a & ~3u)) | (static_cast<uint32_t>(ReadIO16((a & ~3u) + 2u)) << 16);
    mapped = true;
  } else if (a >= 0x05000000u && a <= 0x07FFFFFFu) {
    full = Read32Wrap(palette_ram_.data(), MirrorOffset(a & ~3u, 0x05000000u, 0x3FFu), 0x3FFu);
    if (a >= 0x06000000u && a <= 0x06FFFFFFu) full = Read32Wrap(vram_.data(), VramOffset(a & ~3u), 0x1FFFFu);
    else if (a >= 0x07000000u) full = Read32Wrap(oam_.data(), MirrorOffset(a & ~3u, 0x07000000u, 0x3FFu), 0x3FFu);
    mapped = true;
  } else if (a >= 0x08000000u && a <= 0x0DFFFFFFu) {
    if (backup_type_ == BackupType::kEEPROM && a >= 0x0D000000u) {
      full = (open_bus_latch_ & ~1u) | (ReadBackup8(a) & 1u);
    } else if (!rom_.empty()) {
      const size_t base = static_cast<size_t>((a & ~3u) - 0x08000000u) & 0x01FFFFFFu;
      full = static_cast<uint32_t>(rom_[base % rom_.size()]) |
             (static_cast<uint32_t>(rom_[(base + 1) % rom_.size()]) << 8) |
             (static_cast<uint32_t>(rom_[(base + 2) % rom_.size()]) << 16) |
             (static_cast<uint32_t>(rom_[(base + 3) % rom_.size()]) << 24);
    }
    mapped = true;
  } else if (a >= 0x0E000000u) {
    if (backup_type_ == BackupType::kSRAM) {
      const uint8_t v8 = ReadBackup8(a);
      full = v8 | (v8 << 8) | (v8 << 16) | (v8 << 24);
      mapped = true;
    }
  }

  if (mapped) open_bus_latch_ = full;
  return static_cast<uint16_t>((open_bus_latch_ >> ((addr & 2u) * 8u)) & 0xFFFFu);
}"""

# 3. Read8: Independent
read8_body = """uint8_t GBACore::Read8(uint32_t addr) const {
  if (addr < 0x00004000u) {
    if (cpu_.regs[15] >= 0x00004000u) return static_cast<uint8_t>((open_bus_latch_ >> ((addr & 3u) * 8u)) & 0xFFu);
    return static_cast<uint8_t>((bios_fetch_latch_ >> ((addr & 3u) * 8u)) & 0xFFu);
  }

  uint32_t full = open_bus_latch_;
  bool mapped = false;
  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) {
    full = Read32Wrap(ewram_.data(), MirrorOffset(addr & ~3u, 0x02000000u, 0x3FFFFu), 0x3FFFFu);
    mapped = true;
  } else if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) {
    full = Read32Wrap(iwram_.data(), MirrorOffset(addr & ~3u, 0x03000000u, 0x7FFFu), 0x7FFFu);
    mapped = true;
  } else if (addr >= 0x04000000u && addr <= 0x040003FFu) {
    full = static_cast<uint32_t>(ReadIO16(addr & ~3u)) | (static_cast<uint32_t>(ReadIO16((addr & ~3u) + 2u)) << 16);
    mapped = true;
  } else if (addr >= 0x05000000u && addr <= 0x07FFFFFFu) {
    full = Read32Wrap(palette_ram_.data(), MirrorOffset(addr & ~3u, 0x05000000u, 0x3FFu), 0x3FFu);
    if (addr >= 0x06000000u && addr <= 0x06FFFFFFu) full = Read32Wrap(vram_.data(), VramOffset(addr & ~3u), 0x1FFFFu);
    else if (addr >= 0x07000000u) full = Read32Wrap(oam_.data(), MirrorOffset(addr & ~3u, 0x07000000u, 0x3FFu), 0x3FFu);
    mapped = true;
  } else if (addr >= 0x08000000u && addr <= 0x0DFFFFFFu) {
    if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u) {
      full = (open_bus_latch_ & ~1u) | (ReadBackup8(addr) & 1u);
    } else if (!rom_.empty()) {
      const size_t base = static_cast<size_t>((addr & ~3u) - 0x08000000u) & 0x01FFFFFFu;
      full = static_cast<uint32_t>(rom_[base % rom_.size()]) |
             (static_cast<uint32_t>(rom_[(base + 1) % rom_.size()]) << 8) |
             (static_cast<uint32_t>(rom_[(base + 2) % rom_.size()]) << 16) |
             (static_cast<uint32_t>(rom_[(base + 3) % rom_.size()]) << 24);
    }
    mapped = true;
  } else if (addr >= 0x0E000000u) {
    if (backup_type_ == BackupType::kSRAM) {
      const uint8_t v8 = ReadBackup8(addr);
      full = v8 | (v8 << 8) | (v8 << 16) | (v8 << 24);
      mapped = true;
    }
  }

  if (mapped) open_bus_latch_ = full;
  return static_cast<uint8_t>((open_bus_latch_ >> ((addr & 3u) * 8u)) & 0xFFu);
}"""

content = replace_func(content, "Read32", read32_body)
content = replace_func(content, "Read16", read16_body)
content = replace_func(content, "Read8", read8_body)

with open(bus_path, "w") as f:
    f.write(content)
