import sys
import re

bus_path = "src/core/gba_core_modules/memory_bus.mm"
with open(bus_path, "r") as f:
    content = f.read()

def replace_func(c, name, body):
    pattern = rf"(uint\d+_t|void) GBACore::{name}\(uint32_t addr(?:, (?:uint\d+_t|uint16_t|uint8_t) value)?\) (?:const )?\{{.*?^}}"
    return re.sub(pattern, body, c, flags=re.DOTALL | re.MULTILINE)

# 1. ReadBus32: Raw 32-bit source from physical memory.
# Note: BIOS access here is the *actual* internal bus fetch, but the callers
# (Read32/16/8) handle protection logic based on PC.
readbus32_body = """uint32_t GBACore::ReadBus32(uint32_t a) const {
  // a is ALWAYS aligned to 4 bytes
  if (a < 0x00004000u) {
    if (bios_loaded_ && a < bios_.size()) {
      const size_t off = static_cast<size_t>(a);
      return static_cast<uint32_t>(bios_[off]) |
             (static_cast<uint32_t>(bios_[off + 1]) << 8) |
             (static_cast<uint32_t>(bios_[off + 2]) << 16) |
             (static_cast<uint32_t>(bios_[off + 3]) << 24);
    }
    return bios_fetch_latch_;
  }

  uint32_t val = open_bus_latch_;
  if (a >= 0x02000000u && a <= 0x02FFFFFFu) {
    val = Read32Wrap(ewram_.data(), MirrorOffset(a, 0x02000000u, 0x3FFFFu), 0x3FFFFu);
  } else if (a >= 0x03000000u && a <= 0x03FFFFFFu) {
    val = Read32Wrap(iwram_.data(), MirrorOffset(a, 0x03000000u, 0x7FFFu), 0x7FFFu);
  } else if (a >= 0x04000000u && a <= 0x040003FCu) {
    val = static_cast<uint32_t>(ReadIO16(a)) | (static_cast<uint32_t>(ReadIO16(a + 2u)) << 16);
    // Real GBA IO: undefined bits in registers return open bus bits.
    // This is a simplified merge.
    if (val == 0) val = open_bus_latch_;
  } else if (a >= 0x05000000u && a <= 0x07FFFFFFu) {
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
    }
  } else if (a >= 0x08000000u && a <= 0x0DFFFFFFu) {
    if (backup_type_ == BackupType::kEEPROM && a >= 0x0D000000u) {
      val = (open_bus_latch_ & ~1u) | (ReadBackup8(a) & 1u);
    } else if (!rom_.empty()) {
      const size_t base = static_cast<size_t>(a - 0x08000000u) & 0x01FFFFFFu;
      val = static_cast<uint32_t>(rom_[base % rom_.size()]) |
            (static_cast<uint32_t>(rom_[(base+1) % rom_.size()]) << 8) |
            (static_cast<uint32_t>(rom_[(base+2) % rom_.size()]) << 16) |
            (static_cast<uint32_t>(rom_[(base+3) % rom_.size()]) << 24);
    }
  } else if (a >= 0x0E000000u) {
    if (backup_type_ == BackupType::kSRAM) {
      val = static_cast<uint32_t>(ReadBackup8(a)) |
            (static_cast<uint32_t>(ReadBackup8(a + 1)) << 8) |
            (static_cast<uint32_t>(ReadBackup8(a + 2)) << 16) |
            (static_cast<uint32_t>(ReadBackup8(a + 3)) << 24);
    }
  }
  return val;
}"""

# 2. Read32: ARM unaligned rotation + BIOS protection + Partial Latch Update.
read32_body = """uint32_t GBACore::Read32(uint32_t addr) const {
  const uint32_t aligned = addr & ~3u;
  // BIOS Protection
  if (aligned < 0x00004000u) {
    if (cpu_.regs[15] >= 0x00004000u) return bios_fetch_latch_;
    const uint32_t val = ReadBus32(aligned);
    if (cpu_.regs[15] == aligned) bios_fetch_latch_ = val;
    else bios_data_latch_ = val;
    // BIOS read does NOT update system open_bus_latch_.
    return val;
  }

  const uint32_t val = ReadBus32(aligned);
  open_bus_latch_ = val; // Full 32-bit update for 32-bit access.

  const uint32_t rot = (addr & 3u) * 8u;
  return (rot == 0) ? val : RotateRight(val, rot);
}"""

# 3. Read16: MISALIGNED -> 2x Read8 combined.
read16_body = """uint16_t GBACore::Read16(uint32_t addr) const {
  if (addr & 1u) {
    // Misaligned Read16: sequential Read8s.
    return static_cast<uint16_t>(Read8(addr)) | (static_cast<uint16_t>(Read8(addr + 1)) << 8);
  }

  const uint32_t aligned = addr & ~3u;
  if (aligned < 0x00004000u) {
    if (cpu_.regs[15] >= 0x00004000u) return static_cast<uint16_t>((bios_fetch_latch_ >> ((addr & 2u) * 8u)) & 0xFFFFu);
    const uint32_t val = ReadBus32(aligned);
    // BIOS read does NOT update system open_bus_latch_.
    return static_cast<uint16_t>((val >> ((addr & 2u) * 8u)) & 0xFFFFu);
  }

  const uint32_t val = ReadBus32(aligned);
  // Partial latch update: 16-bit lane.
  const uint32_t shift = (addr & 2u) * 8u;
  const uint32_t mask = 0xFFFFu << shift;
  open_bus_latch_ = (open_bus_latch_ & ~mask) | (val & mask);

  return static_cast<uint16_t>((val >> shift) & 0xFFFFu);
}"""

# 4. Read8: Partial Latch Update.
read8_body = """uint8_t GBACore::Read8(uint32_t addr) const {
  const uint32_t aligned = addr & ~3u;
  if (aligned < 0x00004000u) {
    if (cpu_.regs[15] >= 0x00004000u) return static_cast<uint8_t>((bios_fetch_latch_ >> ((addr & 3u) * 8u)) & 0xFFu);
    const uint32_t val = ReadBus32(aligned);
    return static_cast<uint8_t>((val >> ((addr & 3u) * 8u)) & 0xFFu);
  }

  const uint32_t val = ReadBus32(aligned);
  // Partial latch update: 8-bit lane.
  const uint32_t shift = (addr & 3u) * 8u;
  const uint32_t mask = 0xFFu << shift;
  open_bus_latch_ = (open_bus_latch_ & ~mask) | (val & mask);

  return static_cast<uint8_t>((val >> shift) & 0xFFu);
}"""

# 5. Write32/16/8: PPU alignment and 8-bit prohibition.
write32_body = """void GBACore::Write32(uint32_t addr, uint32_t value) {
  open_bus_latch_ = value;
  if (addr == 0x040000A0u || addr == 0x040000A4u) {
    PushAudioFifo(addr == 0x040000A0u, value);
    return;
  }
  const uint32_t a = addr;
  if (a >= 0x05000000u && a <= 0x07FFFFFFu) {
    // PPU region: decompose to aligned Write16.
    Write16(a, static_cast<uint16_t>(value & 0xFFFFu));
    Write16(a + 2u, static_cast<uint16_t>((value >> 16) & 0xFFFFu));
    return;
  }
  if (a >= 0x02000000u && a <= 0x02FFFFFFu) {
    Write32Wrap(ewram_.data(), MirrorOffset(a, 0x02000000u, 0x3FFFFu), 0x3FFFFu, value);
  } else if (a >= 0x03000000u && a <= 0x03FFFFFFu) {
    Write32Wrap(iwram_.data(), MirrorOffset(a, 0x03000000u, 0x7FFFu), 0x7FFFu, value);
  } else if (a >= 0x04000000u && a <= 0x040003FCu) {
    WriteIO16(a & ~1u, static_cast<uint16_t>(value & 0xFFFFu));
    WriteIO16((a + 2u) & ~1u, static_cast<uint16_t>((value >> 16) & 0xFFFFu));
  } else if (a >= 0x0E000000u) {
    for (int i = 0; i < 4; ++i) WriteBackup8(a + i, static_cast<uint8_t>((value >> (i * 8)) & 0xFFu));
  }
}"""

write16_body = """void GBACore::Write16(uint32_t addr, uint16_t value) {
  open_bus_latch_ = (value | (static_cast<uint32_t>(value) << 16));
  const uint32_t a = addr;
  if (a >= 0x05000000u && a <= 0x07FFFFFFu) {
    // PPU region: ensure 16-bit alignment.
    const uint32_t aligned = a & ~1u;
    if (aligned >= 0x05000000u && aligned <= 0x05FFFFFFu) Write16Wrap(palette_ram_.data(), MirrorOffset(aligned, 0x05000000u, 0x3FFu), 0x3FFu, value);
    else if (aligned >= 0x06000000u && aligned <= 0x06FFFFFFu) Write16Wrap(vram_.data(), VramOffset(aligned), 0x1FFFFu, value);
    else if (aligned >= 0x07000000u) Write16Wrap(oam_.data(), MirrorOffset(aligned, 0x07000000u, 0x3FFu), 0x3FFu, value);
    return;
  }
  if (a >= 0x02000000u && a <= 0x02FFFFFFu) {
    Write16Wrap(ewram_.data(), MirrorOffset(a, 0x02000000u, 0x3FFFFu), 0x3FFFFu, value);
  } else if (a >= 0x03000000u && a <= 0x03FFFFFFu) {
    Write16Wrap(iwram_.data(), MirrorOffset(a, 0x03000000u, 0x7FFFu), 0x7FFFu, value);
  } else if (a >= 0x04000000u && a <= 0x040003FEu) {
    WriteIO16(a & ~1u, value);
  } else if (a >= 0x0E000000u) {
    for (int i = 0; i < 2; ++i) WriteBackup8(a + i, static_cast<uint8_t>((value >> (i * 8)) & 0xFFu));
  }
}"""

write8_body = """void GBACore::Write8(uint32_t addr, uint8_t value) {
  open_bus_latch_ = (value | (value << 8) | (value << 16) | (value << 24));
  if (addr >= 0x05000000u && addr <= 0x07FFFFFFu) {
    // PPU region: Write8 is ignored on real GBA (except Palette RAM sometimes, but here we ignore).
    return;
  }
  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) {
    ewram_[MirrorOffset(addr, 0x02000000u, 0x3FFFFu)] = value;
  } else if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) {
    iwram_[MirrorOffset(addr, 0x03000000u, 0x7FFFu)] = value;
  } else if (addr >= 0x04000000u && addr <= 0x040003FFu) {
    const uint16_t old = ReadIO16(addr & ~1u);
    if (addr & 1u) WriteIO16(addr & ~1u, (old & 0xFFu) | (static_cast<uint16_t>(value) << 8));
    else WriteIO16(addr & ~1u, (old & 0xFF00u) | value);
  } else if (addr >= 0x0E000000u) {
    WriteBackup8(addr, value);
  }
}"""

content = replace_func(content, "ReadBus32", readbus32_body)
content = replace_func(content, "Read32", read32_body)
content = replace_func(content, "Read16", read16_body)
content = replace_func(content, "Read8", read8_body)
content = replace_func(content, "Write32", write32_body)
content = replace_func(content, "Write16", write16_body)
content = replace_func(content, "Write8", write8_body)

with open(bus_path, "w") as f:
    f.write(content)
