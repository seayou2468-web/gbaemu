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

# 1. ReadBus32: Correct BIOS protection, PPU guards, and Mirroring
# We ensure DISPSTAT is up to date before checking guards
readbus32_body = """uint32_t GBACore::ReadBus32(uint32_t a) const {
  a &= ~3u;

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
    return open_bus_latch_;
  }

  // 2. EWRAM
  if (a >= 0x02000000u && a <= 0x02FFFFFFu) {
    return Read32Wrap(ewram_.data(), a & 0x3FFFFu, 0x3FFFFu, ewram_.size());
  }
  // 3. IWRAM
  if (a >= 0x03000000u && a <= 0x03FFFFFFu) {
    return Read32Wrap(iwram_.data(), a & 0x7FFFu, 0x7FFFu, iwram_.size());
  }
  // 4. I/O
  if (a >= 0x04000000u && a <= 0x040003FCu) {
    return static_cast<uint32_t>(ReadIO16(a)) | (static_cast<uint32_t>(ReadIO16(a + 2u)) << 16);
  }
  // 5. PPU
  if (a >= 0x05000000u && a <= 0x07FFFFFFu) {
    const uint16_t dispstat = ReadIO16(0x04000004u);
    const bool vblank = (dispstat & 1);
    const bool hblank = (dispstat & 2);

    if (a >= 0x07000000u) { // OAM
      if (vblank) return Read32Wrap(oam_.data(), a & 0x3FFu, 0x3FFu, oam_.size());
      return open_bus_latch_;
    }
    // Palette or VRAM: allowed if VBlank OR HBlank
    if (vblank || hblank) {
      if (a >= 0x06000000u) return Read32Wrap(vram_.data(), VramOffset(a), 0x1FFFFu, vram_.size());
      return Read32Wrap(palette_ram_.data(), a & 0x3FFu, 0x3FFu, palette_ram_.size());
    }
    return open_bus_latch_;
  }
  // 6. ROM / EEPROM
  if (a >= 0x08000000u && a <= 0x0DFFFFFFu) {
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
  // 7. Backup
  if (a >= 0x0E000000u) {
    return static_cast<uint32_t>(ReadBackup8(a)) |
           (static_cast<uint32_t>(ReadBackup8(a + 1)) << 8) |
           (static_cast<uint32_t>(ReadBackup8(a + 2)) << 16) |
           (static_cast<uint32_t>(ReadBackup8(a + 3)) << 24);
  }

  return open_bus_latch_;
}"""

content = replace_func(full_content, "ReadBus32", readbus32_body)

with open(path, "w") as f:
    f.write(content)
