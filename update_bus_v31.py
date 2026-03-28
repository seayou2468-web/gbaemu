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

# 1. ReadBus32: Fix BIOS protection (fetch latch vs open bus)
readbus32_body = """uint32_t GBACore::ReadBus32(uint32_t a) const {
  a &= ~3u;

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
    // Protected BIOS access returns fetch latch
    return bios_fetch_latch_;
  }

  uint32_t val = open_bus_latch_;
  bool mapped = false;

  if (a >= 0x02000000u && a <= 0x02FFFFFFu) {
    val = Read32Wrap(ewram_.data(), a & 0x3FFFFu, 0x3FFFFu);
    mapped = true;
  }
  else if (a >= 0x03000000u && a <= 0x03FFFFFFu) {
    val = Read32Wrap(iwram_.data(), a & 0x7FFFu, 0x7FFFu);
    mapped = true;
  }
  else if (a >= 0x04000000u && a <= 0x040003FCu) {
    val = static_cast<uint32_t>(ReadIO16(a)) | (static_cast<uint32_t>(ReadIO16(a + 2u)) << 16);
    mapped = true;
  }
  else if (a >= 0x05000000u && a <= 0x07FFFFFFu) {
    const uint16_t dispstat = ReadIO16(0x04000004u);
    const bool vblank = (dispstat & 1);
    const bool hblank = (dispstat & 2);
    if (a >= 0x07000000u) {
      if (vblank) {
        val = Read32Wrap(oam_.data(), a & 0x3FFu, 0x3FFu);
        mapped = true;
      }
    } else {
      if (vblank || hblank) {
        if (a >= 0x06000000u) val = Read32Wrap(vram_.data(), VramOffset(a), 0x1FFFFu);
        else val = Read32Wrap(palette_ram_.data(), a & 0x3FFu, 0x3FFu);
        mapped = true;
      }
    }
  }
  else if (a >= 0x08000000u && a <= 0x0DFFFFFFu) {
    if (backup_type_ == BackupType::kEEPROM && a >= 0x0D000000u) {
      val = (open_bus_latch_ & ~1u) | (ReadBackup8(a) & 1u);
    } else if (!rom_.empty()) {
      const size_t base = static_cast<size_t>(a - 0x08000000u) & 0x01FFFFFFu;
      auto rb = [&](size_t off) {
        return (off < rom_.size()) ? rom_[off] : ((open_bus_latch_ >> ((off & 3)*8)) & 0xFF);
      };
      val = rb(base) | (rb(base+1) << 8) | (rb(base+2) << 16) | (rb(base+3) << 24);
    }
    mapped = true;
  }
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

content = replace_func(full_content, "ReadBus32", readbus32_body)

with open(path, "w") as f:
    f.write(content)
