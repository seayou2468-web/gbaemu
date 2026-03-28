import sys
import re

path = "src/core/gba_core_modules/memory_bus.mm"
with open(path, "r") as f:
    full_content = f.read()

# 1. Define all methods
readbus32 = """uint32_t GBACore::ReadBus32(uint32_t a) const {
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

  uint32_t val = open_bus_latch_;
  if (a >= 0x02000000u && a <= 0x02FFFFFFu) {
    val = Read32Wrap(ewram_.data(), MirrorOffset(a, 0x02000000u, 0x3FFFFu), 0x3FFFFu);
  } else if (a >= 0x03000000u && a <= 0x03FFFFFFu) {
    val = Read32Wrap(iwram_.data(), MirrorOffset(a, 0x03000000u, 0x7FFFu), 0x7FFFu);
  } else if (a >= 0x04000000u && a <= 0x040003FCu) {
    val = static_cast<uint32_t>(ReadIO16(a)) | (static_cast<uint32_t>(ReadIO16(a + 2u)) << 16);
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
      auto read_rom_byte = [&](size_t addr) -> uint32_t {
        if (addr >= rom_.size()) return (open_bus_latch_ >> ((addr & 3) * 8)) & 0xFF;
        return rom_[addr];
      };
      val = read_rom_byte(base) | (read_rom_byte(base + 1) << 8) |
            (read_rom_byte(base + 2) << 16) | (read_rom_byte(base + 3) << 24);
    }
  } else if (a >= 0x0E000000u) {
    val = static_cast<uint32_t>(ReadBackup8(a)) |
          (static_cast<uint32_t>(ReadBackup8(a + 1)) << 8) |
          (static_cast<uint32_t>(ReadBackup8(a + 2)) << 16) |
          (static_cast<uint32_t>(ReadBackup8(a + 3)) << 24);
  }
  return val;
}"""

read32 = """uint32_t GBACore::Read32(uint32_t addr) const {
  const uint32_t aligned = addr & ~3u;
  const uint32_t val = ReadBus32(aligned);
  if (addr >= 0x00004000u) open_bus_latch_ = val;
  const uint32_t rot = (addr & 3u) * 8u;
  return (rot == 0) ? val : RotateRight(val, rot);
}"""

read16 = """uint16_t GBACore::Read16(uint32_t addr) const {
  if (addr & 1u) return static_cast<uint16_t>(Read8(addr)) | (static_cast<uint16_t>(Read8(addr + 1)) << 8);
  const uint32_t aligned = addr & ~3u;
  const uint32_t val = ReadBus32(aligned);
  const uint32_t shift = (addr & 2u) * 8u;
  const uint16_t res = static_cast<uint16_t>((val >> shift) & 0xFFFFu);
  if (addr >= 0x00004000u) {
    const uint32_t mask = 0xFFFFu << shift;
    open_bus_latch_ = (open_bus_latch_ & ~mask) | (static_cast<uint32_t>(res) << shift);
  }
  return res;
}"""

read8 = """uint8_t GBACore::Read8(uint32_t addr) const {
  const uint32_t aligned = addr & ~3u;
  const uint32_t val = ReadBus32(aligned);
  const uint32_t shift = (addr & 3u) * 8u;
  const uint8_t res = static_cast<uint8_t>((val >> shift) & 0xFFu);
  if (addr >= 0x00004000u) {
    const uint32_t mask = 0xFFu << shift;
    open_bus_latch_ = (open_bus_latch_ & ~mask) | (static_cast<uint32_t>(res) << shift);
  }
  return res;
}"""

# Extract helpers and existing methods
readio16 = re.findall(r"uint16_t GBACore::ReadIO16\(uint32_t addr\) const \{.*?^\}", full_content, flags=re.DOTALL | re.MULTILINE)[0]
writeio16 = re.findall(r"void GBACore::WriteIO16\(uint32_t addr, uint16_t value\) \{.*?^\}", full_content, flags=re.DOTALL | re.MULTILINE)[0]
write32 = re.findall(r"void GBACore::Write32\(uint32_t addr, uint32_t value\) \{.*?^\}", full_content, flags=re.DOTALL | re.MULTILINE)[0]
write16 = re.findall(r"void GBACore::Write16\(uint32_t addr, uint16_t value\) \{.*?^\}", full_content, flags=re.DOTALL | re.MULTILINE)[0]
write8 = re.findall(r"void GBACore::Write8\(uint32_t addr, uint8_t value\) \{.*?^\}", full_content, flags=re.DOTALL | re.MULTILINE)[0]
helpers = re.findall(r"namespace \{\s*(.*?)\s*\}  // namespace", full_content, flags=re.DOTALL | re.MULTILINE)[0]

new_file = """// ---- BEGIN gba_core_memory.cpp ----
#include "../gba_core.h"

namespace gba {
namespace {
""" + helpers + """
}  // namespace

""" + readbus32 + "\n\n" + read32 + "\n\n" + read16 + "\n\n" + read8 + "\n\n" + write32 + "\n\n" + write16 + "\n\n" + write8 + "\n\n" + readio16 + "\n\n" + writeio16 + "\n\n}  // namespace gba\n"

with open(path, "w") as f:
    f.write(new_file)
