import sys
import re

bus_path = "src/core/gba_core_modules/memory_bus.mm"
with open(bus_path, "r") as f:
    content = f.read()

def replace_func(c, name, body):
    pattern = rf"(uint\d+_t|void) GBACore::{name}\(uint32_t addr(?:, (?:uint\d+_t|uint8_t) value)?\) (?:const )?\{{.*?^}}"
    return re.sub(pattern, body, c, flags=re.DOTALL | re.MULTILINE)

# New Byte-Level Helpers
read_raw8_impl = """uint8_t GBACore::ReadRaw8(uint32_t addr, bool is_fetch) const {
  const uint32_t shift = (addr & 3u) * 8u;

  // 1. BIOS Region (Internal Bus)
  if (addr < 0x00004000u) {
    if (cpu_.regs[15] < 0x00004000u) {
      if (bios_loaded_) {
        const uint8_t val = bios_[addr & 0x3FFFu];
        // Heuristic latching: 32-bit fetch updates fetch latch
        // Since we are ReadRaw8, we don t easily know if it s part of a 32-bit fetch here
        // but let s update the byte lane of the data latch at least.
        bios_data_latch_ = (bios_data_latch_ & ~(0xFFu << shift)) | (static_cast<uint32_t>(val) << shift);
        return val;
      }
    }
    // Protected: Return last fetch from internal path
    return static_cast<uint8_t>((bios_fetch_latch_ >> shift) & 0xFFu);
  }

  // 2. System Bus Regions
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

  if (updated) {
    open_bus_latch_ = (open_bus_latch_ & ~(0xFFu << shift)) | (static_cast<uint32_t>(val) << shift);
  }
  return val;
}
"""

write_raw8_impl = """void GBACore::WriteRaw8(uint32_t addr, uint8_t value) {
  const uint32_t shift = (addr & 3u) * 8u;
  // System bus update
  open_bus_latch_ = (open_bus_latch_ & ~(0xFFu << shift)) | (static_cast<uint32_t>(value) << shift);

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
  } else if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u && addr <= 0x0DFFFFFFu) {
    WriteBackup8(addr, static_cast<uint8_t>(value & 1u));
  }
}
"""

# Refactored Accessors
read32_body = """uint32_t GBACore::Read32(uint32_t addr) const {
  const uint32_t b0 = ReadRaw8(addr, false);
  const uint32_t b1 = ReadRaw8(addr + 1, false);
  const uint32_t b2 = ReadRaw8(addr + 2, false);
  const uint32_t b3 = ReadRaw8(addr + 3, false);
  const uint32_t val = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);

  // ARM7TDMI misaligned word read behavior: Rotation
  const uint32_t rot = (addr & 3u) * 8u;
  return (rot == 0) ? val : RotateRight(val, rot);
}"""

read16_body = """uint16_t GBACore::Read16(uint32_t addr) const {
  const uint16_t b0 = ReadRaw8(addr, false);
  const uint16_t b1 = ReadRaw8(addr + 1, false);
  return b0 | (b1 << 8);
}"""

read8_body = """uint8_t GBACore::Read8(uint32_t addr) const {
  return ReadRaw8(addr, false);
}"""

write32_body = """void GBACore::Write32(uint32_t addr, uint32_t value) {
  if (addr == 0x040000A0u || addr == 0x040000A4u) {
    PushAudioFifo(addr == 0x040000A0u, value);
    open_bus_latch_ = value;
    return;
  }
  WriteRaw8(addr, static_cast<uint8_t>(value & 0xFFu));
  WriteRaw8(addr + 1, static_cast<uint8_t>((value >> 8) & 0xFFu));
  WriteRaw8(addr + 2, static_cast<uint8_t>((value >> 16) & 0xFFu));
  WriteRaw8(addr + 3, static_cast<uint8_t>((value >> 24) & 0xFFu));
}"""

write16_body = """void GBACore::Write16(uint32_t addr, uint16_t value) {
  WriteRaw8(addr, static_cast<uint8_t>(value & 0xFFu));
  WriteRaw8(addr + 1, static_cast<uint8_t>((value >> 8) & 0xFFu));
}"""

write8_body = """void GBACore::Write8(uint32_t addr, uint8_t value) {
  WriteRaw8(addr, value);
}"""

# Insert helpers
content = content.replace("uint32_t GBACore::Read32", read_raw8_impl + "\\n" + write_raw8_impl + "\\nuint32_t GBACore::Read32")

content = replace_func(content, "Read32", read32_body)
content = replace_func(content, "Read16", read16_body)
content = replace_func(content, "Read8", read8_body)
content = replace_func(content, "Write32", write32_body)
content = replace_func(content, "Write16", write16_body)
content = replace_func(content, "Write8", write8_body)

with open(bus_path, "w") as f:
    f.write(content.replace("\\n", "\n"))
