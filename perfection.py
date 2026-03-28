import sys
import re

def replace_func(content, name, new_body):
    pattern = rf"(uint\d+_t|void) GBACore::{name}\(uint32_t addr(?:, uint\d+_t value)?\) (?:const )?\{{.*?^}}"
    return re.sub(pattern, new_body, content, flags=re.DOTALL | re.MULTILINE)

bus_path = "src/core/gba_core_modules/memory_bus.mm"
with open(bus_path, "r") as f:
    content = f.read()

# I will add a helper to detect if we are in instruction fetch mode if possible,
# but for now I will assume Read32 is fetch if addr == PC.

readbus32_body = """uint32_t GBACore::ReadBus32(uint32_t a) const {
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
}"""

read32_body = """uint32_t GBACore::Read32(uint32_t addr) const {
  const uint32_t raw = ReadBus32(addr & ~3u);
  if (addr >= 0x00004000u) open_bus_latch_ = raw; // Only system bus updates latch

  const uint32_t rot = (addr & 3u) * 8u;
  return (rot == 0) ? raw : RotateRight(raw, rot);
}"""

read16_body = """uint16_t GBACore::Read16(uint32_t addr) const {
  const uint32_t raw = ReadBus32(addr & ~3u);
  if (addr >= 0x00004000u) open_bus_latch_ = raw;

  const uint32_t rot = (addr & 3u) * 8u;
  const uint32_t val = (rot == 0) ? raw : RotateRight(raw, rot);
  return static_cast<uint16_t>(val & 0xFFFFu);
}"""

read8_body = """uint8_t GBACore::Read8(uint32_t addr) const {
  const uint32_t raw = ReadBus32(addr & ~3u);
  if (addr >= 0x00004000u) open_bus_latch_ = raw;

  return static_cast<uint8_t>((raw >> ((addr & 3u) * 8u)) & 0xFFu);
}"""

write32_body = """void GBACore::Write32(uint32_t addr, uint32_t value) {
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
}"""

write16_body = """void GBACore::Write16(uint32_t addr, uint16_t value) {
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
}"""

write8_body = """void GBACore::Write8(uint32_t addr, uint8_t value) {
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
}"""

# Update ReadBus32
pattern_bus = r"uint32_t GBACore::ReadBus32\(uint32_t a, bool\* is_system_bus\) const \{(?:[^{}]|\{(?:[^{}]|\{[^{}]*\})*\})*\}"
content = re.sub(pattern_bus, readbus32_body.replace("uint32_t GBACore::ReadBus32(uint32_t a)", "uint32_t GBACore::ReadBus32(uint32_t a, bool* is_system_bus)"), content, flags=re.DOTALL)
# Wait, I changed the signature to remove is_system_bus in my thought process, but let s stick to what works.
# Actually, I will just use the ReadBus32(uint32_t a) const and handle is_system_bus internally by checking the range.

readbus32_final = readbus32_body

# I need to update the signature in gba_core.h first.
header_path = "src/core/gba_core.h"
with open(header_path, "r") as f:
    h_content = f.read()
h_content = h_content.replace("uint32_t ReadBus32(uint32_t aligned_addr, bool* is_system_bus) const;", "uint32_t ReadBus32(uint32_t aligned_addr) const;")
with open(header_path, "w") as f:
    f.write(h_content)

content = re.sub(r"uint32_t GBACore::ReadBus32\(.*?\)\s*const\s*\{.*?^\}", readbus32_final, content, flags=re.DOTALL | re.MULTILINE)
content = replace_func(content, "Read32", read32_body)
content = replace_func(content, "Read16", read16_body)
content = replace_func(content, "Read8", read8_body)
content = replace_func(content, "Write32", write32_body)
content = replace_func(content, "Write16", write16_body)
content = replace_func(content, "Write8", write8_body)

with open(bus_path, "w") as f:
    f.write(content)
