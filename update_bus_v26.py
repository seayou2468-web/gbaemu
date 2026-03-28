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

# 1. ReadBus32 refinements
readbus32_body = """uint32_t GBACore::ReadBus32(uint32_t a) const {
  // a is ALWAYS aligned to 4 bytes.

  if (a < 0x04000000u) {
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
      return open_bus_latch_;
    }
    // Unmapped [0x00004000, 0x03FFFFFF] is handled by specific checks below
  }

  // System Bus Regions
  if (a >= 0x02000000u && a <= 0x02FFFFFFu) { // EWRAM
    return Read32Wrap(ewram_.data(), MirrorOffset(a, 0x02000000u, 0x3FFFFu), 0x3FFFFu);
  }
  if (a >= 0x03000000u && a <= 0x03FFFFFFu) { // IWRAM
    return Read32Wrap(iwram_.data(), MirrorOffset(a, 0x03000000u, 0x7FFFu), 0x7FFFu);
  }
  if (a >= 0x04000000u && a <= 0x040003FCu) { // IO
    return static_cast<uint32_t>(ReadIO16(a)) | (static_cast<uint32_t>(ReadIO16(a + 2u)) << 16);
  }
  if (a >= 0x05000000u && a <= 0x07FFFFFFu) { // PPU
    const uint16_t dispstat = ReadIO16(0x04000004u);
    const bool vblank = (dispstat & 1);
    const bool hblank = (dispstat & 2);

    if (a >= 0x07000000u) { // OAM
      if (!vblank) return open_bus_latch_;
      return Read32Wrap(oam_.data(), MirrorOffset(a, 0x07000000u, 0x3FFu), 0x3FFu);
    }
    if (!vblank && !hblank) return open_bus_latch_;

    if (a >= 0x06000000u) { // VRAM
      return Read32Wrap(vram_.data(), VramOffset(a), 0x1FFFFu);
    }
    // Palette
    return Read32Wrap(palette_ram_.data(), MirrorOffset(a, 0x05000000u, 0x3FFu), 0x3FFu);
  }
  if (a >= 0x08000000u && a <= 0x0DFFFFFFu) { // ROM / EEPROM
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
  if (a >= 0x0E000000u) { // Backup
    return static_cast<uint32_t>(ReadBackup8(a)) |
           (static_cast<uint32_t>(ReadBackup8(a + 1)) << 8) |
           (static_cast<uint32_t>(ReadBackup8(a + 2)) << 16) |
           (static_cast<uint32_t>(ReadBackup8(a + 3)) << 24);
  }

  return open_bus_latch_;
}"""

# 2. Write32/16 decomposition
write32_body = """void GBACore::Write32(uint32_t addr, uint32_t value) {
  open_bus_latch_ = value;
  if (addr == 0x040000A0u || addr == 0x040000A4u) {
    PushAudioFifo(addr == 0x040000A0u, value);
    return;
  }
  if (addr >= 0x04000000u && addr <= 0x07FFFFFFu) {
    // PPU/IO: Decompose into two aligned 16-bit writes
    Write16(addr & ~3u, static_cast<uint16_t>(value & 0xFFFFu));
    Write16((addr & ~3u) + 2u, static_cast<uint16_t>((value >> 16) & 0xFFFFu));
    return;
  }
  for (int i = 0; i < 4; ++i) {
    Write8(addr + i, static_cast<uint8_t>((value >> (i * 8)) & 0xFFu));
  }
}"""

write16_body = """void GBACore::Write16(uint32_t addr, uint16_t value) {
  open_bus_latch_ = (value | (static_cast<uint32_t>(value) << 16));
  if (addr >= 0x04000000u && addr <= 0x07FFFFFFu) {
    // PPU/IO: Force aligned write
    const uint32_t aligned = addr & ~1u;
    if (aligned >= 0x04000000u && aligned <= 0x040003FEu) {
      WriteIO16(aligned, value);
    } else if (aligned >= 0x05000000u && aligned <= 0x05FFFFFFu) {
      Write16Wrap(palette_ram_.data(), MirrorOffset(aligned, 0x05000000u, 0x3FFu), 0x3FFu, value);
    } else if (aligned >= 0x06000000u && aligned <= 0x06FFFFFFu) {
      Write16Wrap(vram_.data(), VramOffset(aligned), 0x1FFFFu, value);
    } else if (aligned >= 0x07000000u) {
      Write16Wrap(oam_.data(), MirrorOffset(aligned, 0x07000000u, 0x3FFu), 0x3FFu, value);
    }
    return;
  }
  for (int i = 0; i < 2; ++i) {
    Write8(addr + i, static_cast<uint8_t>((value >> (i * 8)) & 0xFFu));
  }
}"""

# 3. Write8: Palette RAM duplication and VRAM/OAM ignore
write8_body = """void GBACore::Write8(uint32_t addr, uint8_t value) {
  open_bus_latch_ = (value | (value << 8) | (value << 16) | (value << 24));
  if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    // Palette RAM: 8-bit write duplicated to 16-bit
    const uint32_t aligned = addr & ~1u;
    const uint16_t v16 = value | (static_cast<uint16_t>(value) << 8);
    Write16Wrap(palette_ram_.data(), MirrorOffset(aligned, 0x05000000u, 0x3FFu), 0x3FFu, v16);
    return;
  }
  if (addr >= 0x06000000u && addr <= 0x07FFFFFFu) {
    // VRAM/OAM: 8-bit writes ignored
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

# 4. ReadIO16/WriteIO16 alignment
readio16_body = """uint16_t GBACore::ReadIO16(uint32_t addr) const {
  addr &= ~1u;
  if (addr < 0x04000000u || addr > 0x040003FEu) return 0;
  const size_t off = static_cast<size_t>(addr - 0x04000000u);
  if (off + 1 >= io_regs_.size()) return 0;
  return static_cast<uint16_t>(io_regs_[off]) |
         static_cast<uint16_t>(io_regs_[off + 1] << 8);
}"""

# Extract current WriteIO16 content to modify it
writeio16_match = re.search(r"void GBACore::WriteIO16\(uint32_t addr, uint16_t value\) \{(.*?)\n\}", full_content, flags=re.DOTALL | re.MULTILINE)
writeio16_inner = writeio16_match.group(1) if writeio16_match else ""
# Force addr &= ~1u at start
if "addr &= ~1u;" not in writeio16_inner:
    writeio16_inner = "\n  addr &= ~1u;" + writeio16_inner
writeio16_body = "void GBACore::WriteIO16(uint32_t addr, uint16_t value) {" + writeio16_inner + "\n}"

content = replace_func(full_content, "ReadBus32", readbus32_body)
content = replace_func(content, "Write32", write32_body)
content = replace_func(content, "Write16", write16_body)
content = replace_func(content, "Write8", write8_body)
content = replace_func(content, "ReadIO16", readio16_body)
content = replace_func(content, "WriteIO16", writeio16_body)

with open(path, "w") as f:
    f.write(content)
