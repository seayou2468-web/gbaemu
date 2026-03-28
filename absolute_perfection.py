import sys
import re

def replace_func(content, name, new_body):
    pattern = rf"(uint\d+_t|void) GBACore::{name}\(uint32_t addr(?:, uint\d+_t value)?\) (?:const )?\{{.*?^}}"
    return re.sub(pattern, new_body, content, flags=re.DOTALL | re.MULTILINE)

bus_path = "src/core/gba_core_modules/memory_bus.mm"
with open(bus_path, "r") as f:
    content = f.read()

read32_body = """uint32_t GBACore::Read32(uint32_t addr) const {
  const uint32_t a = addr & ~3u;

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
    return bios_fetch_latch_;
  }

  // 2. System Bus
  uint32_t val = open_bus_latch_;
  bool updated = false;

  if (a >= 0x02000000u && a <= 0x02FFFFFFu) { // EWRAM
    val = Read32Wrap(ewram_.data(), MirrorOffset(a, 0x02000000u, 0x3FFFFu), 0x3FFFFu);
    updated = true;
  } else if (a >= 0x03000000u && a <= 0x03FFFFFFu) { // IWRAM
    val = Read32Wrap(iwram_.data(), MirrorOffset(a, 0x03000000u, 0x7FFFu), 0x7FFFu);
    updated = true;
  } else if (a >= 0x04000000u && a <= 0x040003FCu) { // IO
    val = static_cast<uint32_t>(ReadIO16(a)) | (static_cast<uint32_t>(ReadIO16(a + 2u)) << 16);
    if (val == 0) val = open_bus_latch_;
    updated = true;
  } else if (a >= 0x05000000u && a <= 0x07FFFFFFu) { // GPU
    const uint16_t dispstat = ReadIO16(0x04000004u);
    const bool vblank = (dispstat & 1);
    const bool hblank = (dispstat & 2);
    if (vblank || hblank) {
       if (a >= 0x05000000u && a <= 0x05FFFFFFu) val = Read32Wrap(palette_ram_.data(), MirrorOffset(a, 0x05000000u, 0x3FFu), 0x3FFu);
       else if (a >= 0x06000000u && a <= 0x06FFFFFFu) val = Read32Wrap(vram_.data(), VramOffset(a), 0x1FFFFu);
       else if (a >= 0x07000000u) val = Read32Wrap(oam_.data(), MirrorOffset(a, 0x07000000u, 0x3FFu), 0x3FFu);
       updated = true;
    }
  } else if (a >= 0x08000000u && a <= 0x0DFFFFFFu) { // ROM
    if (backup_type_ == BackupType::kEEPROM && a >= 0x0D000000u) {
      val = (open_bus_latch_ & ~1u) | (ReadBackup8(a) & 1u);
      updated = true;
    } else if (!rom_.empty()) {
      const size_t base = static_cast<size_t>((a - 0x08000000u) & 0x01FFFFFFu);
      val = static_cast<uint32_t>(rom_[base % rom_.size()]) |
            (static_cast<uint32_t>(rom_[(base+1) % rom_.size()]) << 8) |
            (static_cast<uint32_t>(rom_[(base+2) % rom_.size()]) << 16) |
            (static_cast<uint32_t>(rom_[(base+3) % rom_.size()]) << 24);
      updated = true;
    }
  } else if (a >= 0x0E000000u) { // SRAM
    if (backup_type_ == BackupType::kSRAM) {
      const uint8_t v8 = ReadBackup8(a);
      val = v8 | (v8 << 8) | (v8 << 16) | (v8 << 24);
      updated = true;
    }
  }

  if (updated) open_bus_latch_ = val;
  const uint32_t rot = (addr & 3u) * 8u;
  return (rot == 0) ? val : RotateRight(val, rot);
}"""

read16_body = """uint16_t GBACore::Read16(uint32_t addr) const {
  if (addr & 1u) {
    // Hardware accurate non-aligned halfword read: 2x Read8
    return static_cast<uint16_t>(Read8(addr)) | (static_cast<uint16_t>(Read8(addr + 1u)) << 8);
  }
  const uint32_t a = addr & ~1u;
  const uint32_t shift = (a & 2u) * 8u;

  // 1. BIOS (Internal Bus)
  if (a < 0x00004000u) {
    return static_cast<uint16_t>((bios_fetch_latch_ >> shift) & 0xFFFFu);
  }

  // 2. System Bus
  uint16_t val = static_cast<uint16_t>((open_bus_latch_ >> shift) & 0xFFFFu);
  bool updated = false;

  if (a >= 0x02000000u && a <= 0x02FFFFFFu) {
    val = Read16Wrap(ewram_.data(), MirrorOffset(a, 0x02000000u, 0x3FFFFu), 0x3FFFFu);
    updated = true;
  } else if (a >= 0x03000000u && a <= 0x03FFFFFFu) {
    val = Read16Wrap(iwram_.data(), MirrorOffset(a, 0x03000000u, 0x7FFFu), 0x7FFFu);
    updated = true;
  } else if (a >= 0x04000000u && a <= 0x040003FEu) {
    val = ReadIO16(a);
    updated = true;
  } else if (a >= 0x05000000u && a <= 0x07FFFFFFu) {
    const uint16_t dispstat = ReadIO16(0x04000004u);
    if ((dispstat & 1) || (dispstat & 2)) {
      if (a >= 0x05000000u && a <= 0x05FFFFFFu) val = Read16Wrap(palette_ram_.data(), MirrorOffset(a, 0x05000000u, 0x3FFu), 0x3FFu);
      else if (a >= 0x06000000u && a <= 0x06FFFFFFu) val = Read16Wrap(vram_.data(), VramOffset(a), 0x1FFFFu);
      else if (a >= 0x07000000u) val = Read16Wrap(oam_.data(), MirrorOffset(a, 0x07000000u, 0x3FFu), 0x3FFu);
      updated = true;
    }
  } else if (a >= 0x08000000u && a <= 0x0DFFFFFFu) {
    if (backup_type_ == BackupType::kEEPROM && a >= 0x0D000000u) {
      val = (val & ~1u) | (ReadBackup8(a) & 1u);
      updated = true;
    } else if (!rom_.empty()) {
      const size_t base = static_cast<size_t>((a - 0x08000000u) & 0x01FFFFFFu);
      val = static_cast<uint16_t>(rom_[base % rom_.size()]) |
            (static_cast<uint16_t>(rom_[(base+1) % rom_.size()]) << 8);
      updated = true;
    }
  } else if (a >= 0x0E000000u) {
    if (backup_type_ == BackupType::kSRAM) {
      const uint8_t v8 = ReadBackup8(a);
      val = v8 | (v8 << 8);
      updated = true;
    }
  }

  if (updated) open_bus_latch_ = (open_bus_latch_ & ~(0xFFFFu << shift)) | (static_cast<uint32_t>(val) << shift);
  return val;
}"""

read8_body = """uint8_t GBACore::Read8(uint32_t addr) const {
  const uint32_t shift = (addr & 3u) * 8u;

  // 1. BIOS (Internal Bus)
  if (addr < 0x00004000u) {
    return static_cast<uint8_t>((bios_fetch_latch_ >> shift) & 0xFFu);
  }

  // 2. System Bus
  uint8_t val = static_cast<uint8_t>((open_bus_latch_ >> shift) & 0xFFu);
  bool updated = false;

  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) {
    val = ewram_[MirrorOffset(addr, 0x02000000u, 0x3FFFFu)];
    updated = true;
  } else if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) {
    val = iwram_[MirrorOffset(addr, 0x03000000u, 0x7FFFu)];
    updated = true;
  } else if (addr >= 0x04000000u && addr <= 0x040003FFu) {
    const uint16_t v16 = ReadIO16(addr & ~1u);
    val = static_cast<uint8_t>((v16 >> ((addr & 1u) * 8u)) & 0xFFu);
    updated = true;
  } else if (addr >= 0x05000000u && addr <= 0x07FFFFFFu) {
    const uint16_t dispstat = ReadIO16(0x04000004u);
    if ((dispstat & 1) || (dispstat & 2)) {
      if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) val = palette_ram_[MirrorOffset(addr, 0x05000000u, 0x3FFu)];
      else if (addr >= 0x06000000u && addr <= 0x06FFFFFFu) val = vram_[VramOffset(addr)];
      else if (addr >= 0x07000000u) val = oam_[MirrorOffset(addr, 0x07000000u, 0x3FFu)];
      updated = true;
    }
  } else if (addr >= 0x08000000u && addr <= 0x0DFFFFFFu) {
    if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u) {
      val = (val & ~1u) | (ReadBackup8(addr) & 1u);
      updated = true;
    } else if (!rom_.empty()) {
      val = rom_[(addr - 0x08000000u) % rom_.size()];
      updated = true;
    }
  } else if (addr >= 0x0E000000u) {
    val = ReadBackup8(addr);
    updated = true;
  }

  if (updated) open_bus_latch_ = (open_bus_latch_ & ~(0xFFu << shift)) | (static_cast<uint32_t>(val) << shift);
  return val;
}"""

content = replace_func(content, "Read32", read32_body)
content = replace_func(content, "Read16", read16_body)
content = replace_func(content, "Read8", read8_body)

with open(bus_path, "w") as f:
    f.write(content)
