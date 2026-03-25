#include "gba_core.h"

namespace gba {
namespace {
inline uint32_t MirrorOffset(uint32_t addr, uint32_t base, uint32_t mask) {
  return (addr - base) & mask;
}
}  // namespace

uint32_t GBACore::Read32(uint32_t addr) const {
  // 0x00000000-0x00003FFF: BIOS
  if (bios_loaded_ && addr < 0x00004000u) {
    if (cpu_.regs[15] < 0x00004000u) {
      const uint32_t off32 = addr & 0x3FFFu;
      if (off32 <= bios_.size() - 4) {
        const size_t off = static_cast<size_t>(off32);
        bios_latch_ = static_cast<uint32_t>(bios_[off]) |
                      (static_cast<uint32_t>(bios_[off + 1]) << 8) |
                      (static_cast<uint32_t>(bios_[off + 2]) << 16) |
                      (static_cast<uint32_t>(bios_[off + 3]) << 24);
        return bios_latch_;
      }
    }
    return bios_latch_;
  }
  // 0x02000000-0x02FFFFFF: EWRAM mirror (256KB)
  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x02000000u, 0x3FFFFu);
    if (off32 <= ewram_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint32_t>(ewram_[off]) |
             (static_cast<uint32_t>(ewram_[off + 1]) << 8) |
             (static_cast<uint32_t>(ewram_[off + 2]) << 16) |
             (static_cast<uint32_t>(ewram_[off + 3]) << 24);
    }
  }
  // 0x03000000-0x03FFFFFF: IWRAM mirror (32KB)
  if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x03000000u, 0x7FFFu);
    if (off32 <= iwram_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint32_t>(iwram_[off]) |
             (static_cast<uint32_t>(iwram_[off + 1]) << 8) |
             (static_cast<uint32_t>(iwram_[off + 2]) << 16) |
             (static_cast<uint32_t>(iwram_[off + 3]) << 24);
    }
  }
  // 0x04000000-0x040003FF: IO
  if (addr >= 0x04000000u) {
    const uint32_t off32 = addr - 0x04000000u;
    if (off32 <= io_regs_.size() - 4) {
      const uint16_t lo = ReadIO16(addr);
      const uint16_t hi = ReadIO16(addr + 2);
      return static_cast<uint32_t>(lo) | (static_cast<uint32_t>(hi) << 16);
    }
  }
  // 0x05000000-0x050003FF: Palette RAM
  if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x05000000u, 0x3FFu);
    if (off32 <= palette_ram_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint32_t>(palette_ram_[off]) |
             (static_cast<uint32_t>(palette_ram_[off + 1]) << 8) |
             (static_cast<uint32_t>(palette_ram_[off + 2]) << 16) |
             (static_cast<uint32_t>(palette_ram_[off + 3]) << 24);
    }
  }
  // 0x06000000-0x06017FFF: VRAM
  if (addr >= 0x06000000u && addr <= 0x06FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x06000000u, 0x17FFFu);
    if (off32 <= vram_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint32_t>(vram_[off]) |
             (static_cast<uint32_t>(vram_[off + 1]) << 8) |
             (static_cast<uint32_t>(vram_[off + 2]) << 16) |
             (static_cast<uint32_t>(vram_[off + 3]) << 24);
    }
  }
  // 0x07000000-0x070003FF: OAM
  if (addr >= 0x07000000u && addr <= 0x07FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x07000000u, 0x3FFu);
    if (off32 <= oam_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint32_t>(oam_[off]) |
             (static_cast<uint32_t>(oam_[off + 1]) << 8) |
             (static_cast<uint32_t>(oam_[off + 2]) << 16) |
             (static_cast<uint32_t>(oam_[off + 3]) << 24);
    }
  }
  // 0x0E000000-0x0E00FFFF: SRAM/Flash window (modeled as SRAM)
  if (addr >= 0x0E000000u) {
    return static_cast<uint32_t>(ReadBackup8(addr)) |
           (static_cast<uint32_t>(ReadBackup8(addr + 1)) << 8) |
           (static_cast<uint32_t>(ReadBackup8(addr + 2)) << 16) |
           (static_cast<uint32_t>(ReadBackup8(addr + 3)) << 24);
  }
  // 0x08000000-0x0DFFFFFF: ROM mirror (32MB window)
  if (addr >= 0x08000000u && addr <= 0x0DFFFFFFu) {
    if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u) {
      return static_cast<uint32_t>(ReadBackup8(addr)) |
             (static_cast<uint32_t>(ReadBackup8(addr + 1u)) << 8) |
             (static_cast<uint32_t>(ReadBackup8(addr + 2u)) << 16) |
             (static_cast<uint32_t>(ReadBackup8(addr + 3u)) << 24);
    }
    if (!rom_.empty()) {
      const size_t base = static_cast<size_t>((addr - 0x08000000u) & 0x01FFFFFFu);
      const size_t off0 = base % rom_.size();
      const size_t off1 = (base + 1u) % rom_.size();
      const size_t off2 = (base + 2u) % rom_.size();
      const size_t off3 = (base + 3u) % rom_.size();
      return static_cast<uint32_t>(rom_[off0]) |
             (static_cast<uint32_t>(rom_[off1]) << 8) |
             (static_cast<uint32_t>(rom_[off2]) << 16) |
             (static_cast<uint32_t>(rom_[off3]) << 24);
    }
  }
  return 0;
}

uint16_t GBACore::Read16(uint32_t addr) const {
  if (bios_loaded_ && addr < 0x00004000u) {
    if (cpu_.regs[15] < 0x00004000u) {
      const uint32_t off32 = addr & 0x3FFFu;
      if (off32 <= bios_.size() - 2) {
        const size_t off = static_cast<size_t>(off32);
        const uint16_t value = static_cast<uint16_t>(bios_[off]) |
                               static_cast<uint16_t>(bios_[off + 1] << 8);
        const uint32_t shift = (addr & 2u) * 8u;
        bios_latch_ = (bios_latch_ & ~(0xFFFFu << shift)) | (static_cast<uint32_t>(value) << shift);
        return value;
      }
    }
    return static_cast<uint16_t>((bios_latch_ >> ((addr & 2u) * 8u)) & 0xFFFFu);
  }
  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x02000000u, 0x3FFFFu);
    if (off32 <= ewram_.size() - 2) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint16_t>(ewram_[off]) |
             static_cast<uint16_t>(ewram_[off + 1] << 8);
    }
  }
  if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x03000000u, 0x7FFFu);
    if (off32 <= iwram_.size() - 2) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint16_t>(iwram_[off]) |
             static_cast<uint16_t>(iwram_[off + 1] << 8);
    }
  }
  if (addr >= 0x08000000u && addr <= 0x0DFFFFFFu) {
    if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u) {
      return static_cast<uint16_t>(ReadBackup8(addr)) |
             static_cast<uint16_t>(ReadBackup8(addr + 1u) << 8);
    }
    if (!rom_.empty()) {
      const size_t base = static_cast<size_t>((addr - 0x08000000u) & 0x01FFFFFFu);
      const size_t off0 = base % rom_.size();
      const size_t off1 = (base + 1u) % rom_.size();
      return static_cast<uint16_t>(rom_[off0]) |
             static_cast<uint16_t>(rom_[off1] << 8);
    }
  }
  if (addr >= 0x04000000u) {
    const uint32_t off32 = addr - 0x04000000u;
    if (off32 <= io_regs_.size() - 2) {
      return ReadIO16(addr & ~1u);
    }
  }
  if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x05000000u, 0x3FFu);
    if (off32 <= palette_ram_.size() - 2) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint16_t>(palette_ram_[off]) |
             static_cast<uint16_t>(palette_ram_[off + 1] << 8);
    }
  }
  if (addr >= 0x06000000u && addr <= 0x06FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x06000000u, 0x17FFFu);
    if (off32 <= vram_.size() - 2) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint16_t>(vram_[off]) |
             static_cast<uint16_t>(vram_[off + 1] << 8);
    }
  }
  if (addr >= 0x07000000u && addr <= 0x07FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x07000000u, 0x3FFu);
    if (off32 <= oam_.size() - 2) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint16_t>(oam_[off]) |
             static_cast<uint16_t>(oam_[off + 1] << 8);
    }
  }
  if (addr >= 0x0E000000u) {
    return static_cast<uint16_t>(ReadBackup8(addr)) |
           static_cast<uint16_t>(ReadBackup8(addr + 1) << 8);
  }
  return 0;
}

uint8_t GBACore::Read8(uint32_t addr) const {
  if (bios_loaded_ && addr < 0x00004000u) {
    if (cpu_.regs[15] < 0x00004000u) {
      const uint8_t value = bios_[static_cast<size_t>(addr & 0x3FFFu)];
      const uint32_t shift = (addr & 3u) * 8u;
      bios_latch_ = (bios_latch_ & ~(0xFFu << shift)) | (static_cast<uint32_t>(value) << shift);
      return value;
    }
    return static_cast<uint8_t>((bios_latch_ >> ((addr & 3u) * 8u)) & 0xFFu);
  }
  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x02000000u, 0x3FFFFu);
    if (off32 < ewram_.size()) {
      return ewram_[static_cast<size_t>(off32)];
    }
  }
  if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x03000000u, 0x7FFFu);
    if (off32 < iwram_.size()) {
      return iwram_[static_cast<size_t>(off32)];
    }
  }
  if (addr >= 0x08000000u && addr <= 0x0DFFFFFFu) {
    if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u) {
      return ReadBackup8(addr);
    }
    if (!rom_.empty()) {
      const size_t off = static_cast<size_t>((addr - 0x08000000u) & 0x01FFFFFFu) % rom_.size();
      return rom_[off];
    }
  }
  if (addr >= 0x04000000u) {
    const uint32_t off32 = addr - 0x04000000u;
    if (off32 < io_regs_.size()) {
      const uint16_t half = ReadIO16(addr & ~1u);
      return static_cast<uint8_t>((addr & 1u) ? ((half >> 8) & 0xFFu) : (half & 0xFFu));
    }
  }
  if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x05000000u, 0x3FFu);
    if (off32 < palette_ram_.size()) return palette_ram_[static_cast<size_t>(off32)];
  }
  if (addr >= 0x06000000u && addr <= 0x06FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x06000000u, 0x17FFFu);
    if (off32 < vram_.size()) return vram_[static_cast<size_t>(off32)];
  }
  if (addr >= 0x07000000u && addr <= 0x07FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x07000000u, 0x3FFu);
    if (off32 < oam_.size()) return oam_[static_cast<size_t>(off32)];
  }
  if (addr >= 0x0E000000u) {
    return ReadBackup8(addr);
  }
  return 0;
}

void GBACore::Write32(uint32_t addr, uint32_t value) {
  if (addr == 0x040000A0u || addr == 0x040000A4u) {
    PushAudioFifo(addr == 0x040000A0u, value);
    return;
  }
  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x02000000u, 0x3FFFFu);
    if (off32 <= ewram_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      ewram_[off] = static_cast<uint8_t>(value & 0xFF);
      ewram_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
      ewram_[off + 2] = static_cast<uint8_t>((value >> 16) & 0xFF);
      ewram_[off + 3] = static_cast<uint8_t>((value >> 24) & 0xFF);
      return;
    }
  }
  if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x03000000u, 0x7FFFu);
    if (off32 <= iwram_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      iwram_[off] = static_cast<uint8_t>(value & 0xFF);
      iwram_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
      iwram_[off + 2] = static_cast<uint8_t>((value >> 16) & 0xFF);
      iwram_[off + 3] = static_cast<uint8_t>((value >> 24) & 0xFF);
      return;
    }
  }
  if (addr >= 0x04000000u) {
    const uint32_t off32 = addr - 0x04000000u;
    if (off32 <= io_regs_.size() - 4) {
      WriteIO16(addr, static_cast<uint16_t>(value & 0xFFFFu));
      WriteIO16(addr + 2, static_cast<uint16_t>((value >> 16) & 0xFFFFu));
      return;
    }
  }
  if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x05000000u, 0x3FFu);
    if (off32 <= palette_ram_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      palette_ram_[off] = static_cast<uint8_t>(value & 0xFF);
      palette_ram_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
      palette_ram_[off + 2] = static_cast<uint8_t>((value >> 16) & 0xFF);
      palette_ram_[off + 3] = static_cast<uint8_t>((value >> 24) & 0xFF);
      return;
    }
  }
  if (addr >= 0x06000000u && addr <= 0x06FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x06000000u, 0x17FFFu);
    if (off32 <= vram_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      vram_[off] = static_cast<uint8_t>(value & 0xFF);
      vram_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
      vram_[off + 2] = static_cast<uint8_t>((value >> 16) & 0xFF);
      vram_[off + 3] = static_cast<uint8_t>((value >> 24) & 0xFF);
      return;
    }
  }
  if (addr >= 0x07000000u && addr <= 0x07FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x07000000u, 0x3FFu);
    if (off32 <= oam_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      oam_[off] = static_cast<uint8_t>(value & 0xFF);
      oam_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
      oam_[off + 2] = static_cast<uint8_t>((value >> 16) & 0xFF);
      oam_[off + 3] = static_cast<uint8_t>((value >> 24) & 0xFF);
      return;
    }
  }
  if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u && addr <= 0x0DFFFFFFu) {
    WriteBackup8(addr, static_cast<uint8_t>(value & 0x1u));
    WriteBackup8(addr + 1u, static_cast<uint8_t>((value >> 8) & 0x1u));
    WriteBackup8(addr + 2u, static_cast<uint8_t>((value >> 16) & 0x1u));
    WriteBackup8(addr + 3u, static_cast<uint8_t>((value >> 24) & 0x1u));
    return;
  }
  if (addr >= 0x0E000000u) {
    WriteBackup8(addr, static_cast<uint8_t>(value & 0xFFu));
    WriteBackup8(addr + 1, static_cast<uint8_t>((value >> 8) & 0xFFu));
    WriteBackup8(addr + 2, static_cast<uint8_t>((value >> 16) & 0xFFu));
    WriteBackup8(addr + 3, static_cast<uint8_t>((value >> 24) & 0xFFu));
    return;
  }
}

void GBACore::Write16(uint32_t addr, uint16_t value) {
  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x02000000u, 0x3FFFFu);
    if (off32 <= ewram_.size() - 2) {
      const size_t off = static_cast<size_t>(off32);
      ewram_[off] = static_cast<uint8_t>(value & 0xFF);
      ewram_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
      return;
    }
  }
  if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x03000000u, 0x7FFFu);
    if (off32 <= iwram_.size() - 2) {
      const size_t off = static_cast<size_t>(off32);
      iwram_[off] = static_cast<uint8_t>(value & 0xFF);
      iwram_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
      return;
    }
  }
  if (addr >= 0x04000000u) {
    const uint32_t off32 = addr - 0x04000000u;
    if (off32 <= io_regs_.size() - 2) {
      WriteIO16(addr & ~1u, value);
      return;
    }
  }
  if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x05000000u, 0x3FFu);
    if (off32 <= palette_ram_.size() - 2) {
      const size_t off = static_cast<size_t>(off32);
      palette_ram_[off] = static_cast<uint8_t>(value & 0xFF);
      palette_ram_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
      return;
    }
  }
  if (addr >= 0x06000000u && addr <= 0x06FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x06000000u, 0x17FFFu);
    if (off32 <= vram_.size() - 2) {
      const size_t off = static_cast<size_t>(off32);
      vram_[off] = static_cast<uint8_t>(value & 0xFF);
      vram_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
      return;
    }
  }
  if (addr >= 0x07000000u && addr <= 0x07FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x07000000u, 0x3FFu);
    if (off32 <= oam_.size() - 2) {
      const size_t off = static_cast<size_t>(off32);
      oam_[off] = static_cast<uint8_t>(value & 0xFF);
      oam_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
      return;
    }
  }
  if (addr >= 0x0E000000u) {
    WriteBackup8(addr, static_cast<uint8_t>(value & 0xFFu));
    WriteBackup8(addr + 1, static_cast<uint8_t>((value >> 8) & 0xFFu));
    return;
  }
  if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u && addr <= 0x0DFFFFFFu) {
    WriteBackup8(addr, static_cast<uint8_t>(value & 0x1u));
    WriteBackup8(addr + 1u, static_cast<uint8_t>((value >> 8) & 0x1u));
    return;
  }
}

void GBACore::Write8(uint32_t addr, uint8_t value) {
  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x02000000u, 0x3FFFFu);
    if (off32 < ewram_.size()) {
      ewram_[static_cast<size_t>(off32)] = value;
      return;
    }
  }
  if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x03000000u, 0x7FFFu);
    if (off32 < iwram_.size()) {
      iwram_[static_cast<size_t>(off32)] = value;
      return;
    }
  }
  if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr & ~1u, 0x05000000u, 0x3FFu);
    if (off32 + 1u < palette_ram_.size()) {
      const size_t off = static_cast<size_t>(off32);
      palette_ram_[off] = value;
      palette_ram_[off + 1] = value;
      return;
    }
  }
  if (addr >= 0x06000000u && addr <= 0x06FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr & ~1u, 0x06000000u, 0x17FFFu);
    if (off32 + 1u < vram_.size()) {
      const size_t off = static_cast<size_t>(off32);
      vram_[off] = value;
      vram_[off + 1] = value;
      return;
    }
  }
  if (addr >= 0x07000000u && addr <= 0x07FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr & ~1u, 0x07000000u, 0x3FFu);
    if (off32 + 1u < oam_.size()) {
      const size_t off = static_cast<size_t>(off32);
      oam_[off] = value;
      oam_[off + 1] = value;
      return;
    }
  }
  if (addr >= 0x0E000000u) {
    WriteBackup8(addr, value);
    return;
  }
  if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u && addr <= 0x0DFFFFFFu) {
    WriteBackup8(addr, static_cast<uint8_t>(value & 0x1u));
    return;
  }
  if (addr >= 0x04000000u) {
    const uint32_t off32 = addr - 0x04000000u;
    if (off32 < io_regs_.size()) {
      const uint16_t old = ReadIO16(addr & ~1u);
      if (addr & 1u) {
        WriteIO16(addr & ~1u, static_cast<uint16_t>((old & 0x00FFu) | (static_cast<uint16_t>(value) << 8)));
      } else {
        WriteIO16(addr & ~1u, static_cast<uint16_t>((old & 0xFF00u) | value));
      }
    }
  }
}

uint16_t GBACore::ReadIO16(uint32_t addr) const {
  if (addr < 0x04000000u || addr > 0x040003FEu) return 0;
  const size_t off = static_cast<size_t>(addr - 0x04000000u);
  if (off + 1 >= io_regs_.size()) return 0;
  return static_cast<uint16_t>(io_regs_[off]) |
         static_cast<uint16_t>(io_regs_[off + 1] << 8);
}

void GBACore::WriteIO16(uint32_t addr, uint16_t value) {
  if (addr < 0x04000000u || addr > 0x040003FEu) return;
  const size_t off = static_cast<size_t>(addr - 0x04000000u);
  if (off + 1 >= io_regs_.size()) return;
  // KEYINPUT is read-only from CPU side in this model (updated from SetKeys).
  if (addr == 0x04000130u) return;
  // IF: write-1-to-clear bits
  if (addr == 0x04000202u) {
    const uint16_t old = ReadIO16(addr);
    const uint16_t next = static_cast<uint16_t>(old & ~value);
    io_regs_[off] = static_cast<uint8_t>(next & 0xFF);
    io_regs_[off + 1] = static_cast<uint8_t>((next >> 8) & 0xFF);
    return;
  }
  // IME only bit0 is used.
  if (addr == 0x04000208u) {
    value &= 0x0001u;
  }
  // SOUNDCNT_H FIFO reset bits.
  if (addr == 0x04000082u) {
    if (value & (1u << 11)) {
      fifo_a_.clear();
      fifo_a_last_sample_ = 0;
      value = static_cast<uint16_t>(value & ~(1u << 11));
    }
    if (value & (1u << 15)) {
      fifo_b_.clear();
      fifo_b_last_sample_ = 0;
      value = static_cast<uint16_t>(value & ~(1u << 15));
    }
  }
  io_regs_[off] = static_cast<uint8_t>(value & 0xFF);
  io_regs_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
}


}  // namespace gba
