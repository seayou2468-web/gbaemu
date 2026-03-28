// ---- BEGIN gba_core_memory.cpp ----
#include "../gba_core.h"

namespace gba {
namespace {
inline uint32_t MirrorOffset(uint32_t addr, uint32_t base, uint32_t mask) {
  return (addr - base) & mask;
}

inline uint16_t Read16Wrap(const uint8_t* buf, uint32_t off, uint32_t mask) {
  const uint32_t o0 = off & mask;
  const uint32_t o1 = (off + 1u) & mask;
  return static_cast<uint16_t>(buf[o0]) |
         static_cast<uint16_t>(buf[o1] << 8);
}

inline uint32_t Read32Wrap(const uint8_t* buf, uint32_t off, uint32_t mask) {
  const uint32_t o0 = off & mask;
  const uint32_t o1 = (off + 1u) & mask;
  const uint32_t o2 = (off + 2u) & mask;
  const uint32_t o3 = (off + 3u) & mask;
  return static_cast<uint32_t>(buf[o0]) |
         (static_cast<uint32_t>(buf[o1]) << 8) |
         (static_cast<uint32_t>(buf[o2]) << 16) |
         (static_cast<uint32_t>(buf[o3]) << 24);
}

inline void Write16Wrap(uint8_t* buf, uint32_t off, uint32_t mask, uint16_t value) {
  const uint32_t o0 = off & mask;
  const uint32_t o1 = (off + 1u) & mask;
  buf[o0] = static_cast<uint8_t>(value & 0xFFu);
  buf[o1] = static_cast<uint8_t>((value >> 8) & 0xFFu);
}

inline void Write32Wrap(uint8_t* buf, uint32_t off, uint32_t mask, uint32_t value) {
  const uint32_t o0 = off & mask;
  const uint32_t o1 = (off + 1u) & mask;
  const uint32_t o2 = (off + 2u) & mask;
  const uint32_t o3 = (off + 3u) & mask;
  buf[o0] = static_cast<uint8_t>(value & 0xFFu);
  buf[o1] = static_cast<uint8_t>((value >> 8) & 0xFFu);
  buf[o2] = static_cast<uint8_t>((value >> 16) & 0xFFu);
  buf[o3] = static_cast<uint8_t>((value >> 24) & 0xFFu);
}

inline uint32_t VramOffset(uint32_t addr) {
  uint32_t off32 = MirrorOffset(addr, 0x06000000u, 0x1FFFFu);
  if (off32 >= 0x18000u) off32 -= 0x8000u;
  return off32;
}
}  // namespace

uint32_t GBACore::ReadBus32(uint32_t a) const {
  // a is already aligned to 4 bytes here

  // 1. BIOS (Internal Bus)
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
    // Protected: return open_bus_latch_ as per latest instruction
    return open_bus_latch_;
  }

  // 2. System Bus Regions
  uint32_t val = open_bus_latch_;

  if (a >= 0x02000000u && a <= 0x02FFFFFFu) { // EWRAM
    val = Read32Wrap(ewram_.data(), MirrorOffset(a, 0x02000000u, 0x3FFFFu), 0x3FFFFu);
  } else if (a >= 0x03000000u && a <= 0x03FFFFFFu) { // IWRAM
    val = Read32Wrap(iwram_.data(), MirrorOffset(a, 0x03000000u, 0x7FFFu), 0x7FFFu);
  } else if (a >= 0x04000000u && a <= 0x040003FCu) { // IO
    // IO undefined bits are open bus. ReadIO16 should return bits that are NOT open bus.
    // For simplicity, we assume if ReadIO16 returns 0 for a region, it might be open bus.
    // Real GBA IO is complex, but "fallback to open bus" is the rule.
    const uint16_t lo = ReadIO16(a);
    const uint16_t hi = ReadIO16(a + 2u);
    val = static_cast<uint32_t>(lo) | (static_cast<uint32_t>(hi) << 16);
    // If both are 0, it might be fully undefined -> return open_bus_latch_
    if (val == 0) val = open_bus_latch_;
  } else if (a >= 0x05000000u && a <= 0x07FFFFFFu) { // PPU
    // Strict PPU access control
    const uint16_t dispcnt = ReadIO16(0x04000000u);
    const uint16_t dispstat = ReadIO16(0x04000004u);
    const int mode = dispcnt & 7;
    const bool vblank = (dispstat & 1);
    const bool hblank = (dispstat & 2);

    bool blocked = false;
    if (a >= 0x07000000u) { // OAM
      if (!vblank && !hblank) blocked = true; // Blocked during H-Draw
    } else if (a >= 0x05000000u && a <= 0x05FFFFFFu) { // Palette
      if (!vblank && !hblank) blocked = true;
    } else { // VRAM
      if (!vblank && !hblank && (mode >= 3)) blocked = true; // Simplified
    }

    if (!blocked) {
       if (a >= 0x05000000u && a <= 0x05FFFFFFu)
         val = Read32Wrap(palette_ram_.data(), MirrorOffset(a, 0x05000000u, 0x3FFu), 0x3FFu);
       else if (a >= 0x06000000u && a <= 0x06FFFFFFu)
         val = Read32Wrap(vram_.data(), VramOffset(a), 0x1FFFFu);
       else if (a >= 0x07000000u)
         val = Read32Wrap(oam_.data(), MirrorOffset(a, 0x07000000u, 0x3FFu), 0x3FFu);
    }
  } else if (a >= 0x08000000u && a <= 0x0DFFFFFFu) { // ROM
    if (backup_type_ == BackupType::kEEPROM && a >= 0x0D000000u) {
      val = (open_bus_latch_ & ~1u) | (ReadBackup8(a) & 1u);
    } else if (!rom_.empty()) {
      const size_t base = static_cast<size_t>((a - 0x08000000u) & 0x01FFFFFFu);
      val = static_cast<uint32_t>(rom_[base % rom_.size()]) |
            (static_cast<uint32_t>(rom_[(base+1) % rom_.size()]) << 8) |
            (static_cast<uint32_t>(rom_[(base+2) % rom_.size()]) << 16) |
            (static_cast<uint32_t>(rom_[(base+3) % rom_.size()]) << 24);
    }
  } else if (a >= 0x0E000000u) { // SRAM
    if (backup_type_ == BackupType::kSRAM) {
      const uint8_t v8 = ReadBackup8(a);
      val = v8 | (v8 << 8) | (v8 << 16) | (v8 << 24);
    }
  }

  return val;
}

uint32_t GBACore::Read32(uint32_t addr) const {
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
}

uint16_t GBACore::Read16(uint32_t addr) const {
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
}

uint8_t GBACore::Read8(uint32_t addr) const {
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
}

void GBACore::Write32(uint32_t addr, uint32_t value) {
  open_bus_latch_ = value;
  if (addr == 0x040000A0u || addr == 0x040000A4u) {
    PushAudioFifo(addr == 0x040000A0u, value);
    return;
  }
  const uint32_t a = addr;
  if (a >= 0x02000000u && a <= 0x02FFFFFFu) {
    Write32Wrap(ewram_.data(), MirrorOffset(a, 0x02000000u, 0x3FFFFu), 0x3FFFFu, value);
  } else if (a >= 0x03000000u && a <= 0x03FFFFFFu) {
    Write32Wrap(iwram_.data(), MirrorOffset(a, 0x03000000u, 0x7FFFu), 0x7FFFu, value);
  } else if (a >= 0x04000000u && a <= 0x040003FCu) {
    WriteIO16(a & ~1u, static_cast<uint16_t>(value & 0xFFFFu));
    WriteIO16((a + 2u) & ~1u, static_cast<uint16_t>((value >> 16) & 0xFFFFu));
  } else if (a >= 0x05000000u && a <= 0x05FFFFFFu) {
    Write32Wrap(palette_ram_.data(), MirrorOffset(a & ~1u, 0x05000000u, 0x3FFu), 0x3FFu, value);
  } else if (a >= 0x06000000u && a <= 0x06FFFFFFu) {
    Write32Wrap(vram_.data(), VramOffset(a & ~1u), 0x1FFFFu, value);
  } else if (a >= 0x07000000u && a <= 0x07FFFFFFu) {
    Write32Wrap(oam_.data(), MirrorOffset(a & ~1u, 0x07000000u, 0x3FFu), 0x3FFu, value);
  } else if (a >= 0x0E000000u) {
    WriteBackup8(a, static_cast<uint8_t>(value & 0xFFu));
    WriteBackup8(a+1, static_cast<uint8_t>((value >> 8) & 0xFFu));
    WriteBackup8(a+2, static_cast<uint8_t>((value >> 16) & 0xFFu));
    WriteBackup8(a+3, static_cast<uint8_t>((value >> 24) & 0xFFu));
  }
}

void GBACore::Write16(uint32_t addr, uint16_t value) {
  open_bus_latch_ = (value | (static_cast<uint32_t>(value) << 16));
  const uint32_t a = addr;
  if (a >= 0x02000000u && a <= 0x02FFFFFFu) {
    Write16Wrap(ewram_.data(), MirrorOffset(a, 0x02000000u, 0x3FFFFu), 0x3FFFFu, value);
  } else if (a >= 0x03000000u && a <= 0x03FFFFFFu) {
    Write16Wrap(iwram_.data(), MirrorOffset(a, 0x03000000u, 0x7FFFu), 0x7FFFu, value);
  } else if (a >= 0x04000000u && a <= 0x040003FEu) {
    WriteIO16(a & ~1u, value);
  } else if (a >= 0x05000000u && a <= 0x05FFFFFFu) {
    Write16Wrap(palette_ram_.data(), MirrorOffset(a & ~1u, 0x05000000u, 0x3FFu), 0x3FFu, value);
  } else if (a >= 0x06000000u && a <= 0x06FFFFFFu) {
    Write16Wrap(vram_.data(), VramOffset(a & ~1u), 0x1FFFFu, value);
  } else if (a >= 0x07000000u && a <= 0x07FFFFFFu) {
    Write16Wrap(oam_.data(), MirrorOffset(a & ~1u, 0x07000000u, 0x3FFu), 0x3FFu, value);
  } else if (a >= 0x0E000000u) {
    WriteBackup8(a, static_cast<uint8_t>(value & 0xFFu));
    WriteBackup8(a+1, static_cast<uint8_t>((value >> 8) & 0xFFu));
  }
}

void GBACore::Write8(uint32_t addr, uint8_t value) {
  open_bus_latch_ = (value | (value << 8) | (value << 16) | (value << 24));
  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) {
    ewram_[MirrorOffset(addr, 0x02000000u, 0x3FFFFu)] = value;
  } else if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) {
    iwram_[MirrorOffset(addr, 0x03000000u, 0x7FFFu)] = value;
  } else if (addr >= 0x04000000u && addr <= 0x040003FFu) {
    const uint16_t old = ReadIO16(addr & ~1u);
    if (addr & 1u) WriteIO16(addr & ~1u, (old & 0xFFu) | (static_cast<uint16_t>(value) << 8));
    else WriteIO16(addr & ~1u, (old & 0xFF00u) | value);
  } else if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    const uint32_t off = MirrorOffset(addr & ~1u, 0x05000000u, 0x3FFu);
    palette_ram_[off] = value;
    palette_ram_[off + 1] = value;
  } else if (addr >= 0x0E000000u) {
    WriteBackup8(addr, value);
  }
}

uint16_t GBACore::ReadIO16(uint32_t addr) const {
  if (addr < 0x04000000u || addr > 0x040003FEu) return 0; // Bus logic handles Open Bus fallback
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
  // WAITCNT writable bits.
  if (addr == 0x04000204u) {
    value = static_cast<uint16_t>(value & 0x5FFFu);
  }
  // DISPSTAT: bits 0-2 are status (read-only), bits 3-5/8-15 writable.
  if (addr == 0x04000004u) {
    const uint16_t old = ReadIO16(addr);
    value = static_cast<uint16_t>((value & 0xFF38u) | (old & 0x0003u));
    const uint16_t vcount = ReadIO16(0x04000006u);
    const uint16_t lyc = static_cast<uint16_t>((value >> 8) & 0x00FFu);
    const bool old_match = (old & 0x0004u) != 0;
    const bool now_match = (vcount == lyc);
    if (now_match) {
      value = static_cast<uint16_t>(value | 0x0004u);
      if (!old_match && (value & (1u << 5))) {
        RaiseInterrupt(1u << 2);  // VCount IRQ
      }
    } else {
      value = static_cast<uint16_t>(value & ~0x0004u);
    }
    io_regs_[off] = static_cast<uint8_t>(value & 0xFFu);
    io_regs_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFFu);
    return;
  }
  // VCOUNT is read-only.
  if (addr == 0x04000006u) {
    return;
  }
  // DISPCNT: CGB mode bit (3) is read-only 0 on GBA.
  if (addr == 0x04000000u) {
    value = static_cast<uint16_t>(value & ~0x0008u);
  }
  // BGxCNT masks.
  if (addr >= 0x04000008u && addr <= 0x0400000Eu && (addr & 1u) == 0u) {
    const uint32_t bg = (addr - 0x04000008u) / 2u;
    value = static_cast<uint16_t>(value & 0xDFFFu);  // bit13 handled below.
    if (bg < 2u) {
      // BG0/BG1 do not use wraparound bit13.
      value = static_cast<uint16_t>(value & ~(1u << 13));
    }
  }
  // BGxHOFS/BGxVOFS are 9-bit.
  if (addr >= 0x04000010u && addr <= 0x0400001Eu && (addr & 1u) == 0u) {
    value = static_cast<uint16_t>(value & 0x01FFu);
  }
  // BG2/3 affine parameters (PA/PB/PC/PD) are signed 16-bit: full writable.
  // BG2X/BG2Y/BG3X/BG3Y reference points are 28-bit signed over 32-bit regs.
  if ((addr >= 0x04000028u && addr <= 0x0400003Eu)) {
    const uint32_t rel = addr - 0x04000028u;
    const uint32_t lane = rel % 8u;
    if (lane == 2u || lane == 6u) {
      // High halfword only uses low 12 bits (bits 16..27 overall).
      value = static_cast<uint16_t>(value & 0x0FFFu);
    }
  }
  // Window coordinates are 8-bit start/end fields.
  if (addr >= 0x04000040u && addr <= 0x04000046u && (addr & 1u) == 0u) {
    const uint16_t lo = static_cast<uint16_t>(value & 0x00FFu);
    const uint16_t hi = static_cast<uint16_t>((value >> 8) & 0x00FFu);
    value = static_cast<uint16_t>(lo | (hi << 8));
  }
  // WININ/WINOUT: only lower 6 bits of each byte are used.
  if (addr == 0x04000048u || addr == 0x0400004Au) {
    const uint16_t lo = static_cast<uint16_t>(value & 0x003Fu);
    const uint16_t hi = static_cast<uint16_t>((value >> 8) & 0x003Fu);
    value = static_cast<uint16_t>(lo | (hi << 8));
  }
  // MOSAIC: each nibble is 4-bit size field.
  if (addr == 0x0400004Cu) {
    value = static_cast<uint16_t>(value & 0xFFFFu);
  }
  // BLDCNT: valid bits are 0-5, 6-7(mode), 8-13.
  if (addr == 0x04000050u) {
    value = static_cast<uint16_t>(value & 0x3FFFu);
  }
  // BLDALPHA: EVA/EVB are 5-bit.
  if (addr == 0x04000052u) {
    const uint16_t eva = static_cast<uint16_t>(value & 0x001Fu);
    const uint16_t evb = static_cast<uint16_t>((value >> 8) & 0x001Fu);
    value = static_cast<uint16_t>(eva | (evb << 8));
  }
  // BLDY: EVY is 5-bit.
  if (addr == 0x04000054u) {
    value = static_cast<uint16_t>(value & 0x001Fu);
  }
  // SOUNDCNT_X: only bit7 is writable; bits0-3 are read-only channel-active flags.
  if (addr == 0x04000084u) {
    const uint16_t old = ReadIO16(addr);
    const uint16_t ro_status = static_cast<uint16_t>(old & 0x000Fu);
    value = static_cast<uint16_t>((value & 0x0080u) | ro_status);
    const bool master_was_on = (old & 0x0080u) != 0;
    const bool master_now_on = (value & 0x0080u) != 0;
    if (master_was_on && !master_now_on) {
      for (size_t i = 0x60u; i <= 0x81u && i < io_regs_.size(); ++i) io_regs_[i] = 0;
      apu_ch1_active_ = apu_ch2_active_ = apu_ch3_active_ = apu_ch4_active_ = false;
      apu_prev_trig_ch1_ = apu_prev_trig_ch2_ = apu_prev_trig_ch3_ = apu_prev_trig_ch4_ = false;
      audio_mix_level_ = 0;
      fifo_a_.clear();
      fifo_b_.clear();
      fifo_a_last_sample_ = 0;
      fifo_b_last_sample_ = 0;
    }
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
  // Timer registers side effects.
  if (addr >= 0x04000100u && addr <= 0x0400010Eu) {
    const uint32_t rel = addr - 0x04000100u;
    const uint32_t tidx = rel / 4u;
    const bool is_low = (rel % 4u) == 0u;
    const bool is_high = (rel % 4u) == 2u;
    if (tidx < timers_.size()) {
      if (is_high) {
        const uint16_t old = ReadIO16(addr);
        // Timer control uses bits 0-2,6-7.
        value = static_cast<uint16_t>(value & 0x00C7u);
        if (tidx == 0u) {
          // Timer0 cannot use count-up mode.
          value = static_cast<uint16_t>(value & ~0x0004u);
        }
        io_regs_[off] = static_cast<uint8_t>(value & 0xFF);
        io_regs_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
        const bool was_enable = (old & 0x0080u) != 0;
        const bool now_enable = (value & 0x0080u) != 0;
        const bool prescaler_changed = ((old ^ value) & 0x0003u) != 0u;
        timers_[tidx].control = value;
        if (!was_enable && now_enable) {
          // Enabling a timer reloads counter from TMxCNT_L and resets prescaler.
          const uint16_t reload = timers_[tidx].reload;
          timers_[tidx].counter = reload;
          timers_[tidx].prescaler_accum = 0;
          io_regs_[0x100u + tidx * 4u] = static_cast<uint8_t>(reload & 0xFFu);
          io_regs_[0x101u + tidx * 4u] = static_cast<uint8_t>((reload >> 8) & 0xFFu);
        } else if (was_enable && !now_enable) {
          // Disabling timer clears accumulated prescaler phase.
          timers_[tidx].prescaler_accum = 0;
        } else if (now_enable && prescaler_changed) {
          // Changing prescaler while enabled restarts divider phase.
          timers_[tidx].prescaler_accum = 0;
        }
        return;
      }
      if (is_low) {
        timers_[tidx].reload = value;
        const uint16_t ctrl = ReadIO16(static_cast<uint32_t>(0x04000102u + tidx * 4u));
        if ((ctrl & 0x0080u) == 0) {
          // When timer is stopped, writes to reload are reflected in current count.
          timers_[tidx].counter = value;
          io_regs_[off] = static_cast<uint8_t>(value & 0xFFu);
          io_regs_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFFu);
        } else {
          // While running, TMxCNT_L keeps exposing the live counter.
          const uint16_t counter = timers_[tidx].counter;
          io_regs_[off] = static_cast<uint8_t>(counter & 0xFFu);
          io_regs_[off + 1] = static_cast<uint8_t>((counter >> 8) & 0xFFu);
        }
        return;
      }
    }
  }
  // DMA register writable masks.
  if (addr >= 0x040000B0u && addr <= 0x040000DEu) {
    const uint32_t rel = addr - 0x040000B0u;
    const uint32_t ch = rel / 12u;
    const uint32_t reg = rel % 12u;
    if (ch < 4u) {
      // DMACNT_L: 14-bit for DMA0-2, 16-bit for DMA3.
      if (reg == 8u) {
        if (ch < 3u) value = static_cast<uint16_t>(value & 0x3FFFu);
      }
      // DMACNT_H: writable control bits only.
      if (reg == 10u) {
        uint16_t mask = 0xF7E0u;  // bits 5-15 (bit 11 unused for ch0-2)
        if (ch == 3u) {
          mask = 0xFFE0u;  // include gamepak DRQ bit11 on DMA3.
        }
        value = static_cast<uint16_t>(value & mask);
        // DMA0 doesn't support start timing=3 (special).
        if (ch == 0u && ((value >> 12) & 0x3u) == 3u) {
          value = static_cast<uint16_t>(value & ~(0x3u << 12));
        }
        // Prohibited source addr control=3 behaves like increment.
        if (((value >> 7) & 0x3u) == 3u) {
          value = static_cast<uint16_t>(value & ~(0x3u << 7));
        }
        // Dest addr control=3 is only valid on DMA3; normalize others.
        if (ch < 3u && ((value >> 5) & 0x3u) == 3u) {
          value = static_cast<uint16_t>(value & ~(0x3u << 5));
        }
      }
      // Source/Destination high halfword address masks.
      if (reg == 2u || reg == 6u) {
        // Valid address bits are within 0x0FFFFFFF for DMA1-3 and
        // 0x07FFFFFF for DMA0.
        const uint16_t high_mask = (ch == 0u) ? 0x07FFu : 0x0FFFu;
        value = static_cast<uint16_t>(value & high_mask);
      }
    }
  }
  io_regs_[off] = static_cast<uint8_t>(value & 0xFF);
  io_regs_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
}


}  // namespace gba

// ---- END gba_core_memory.cpp ----
