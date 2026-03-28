import sys
import re

path = "src/core/gba_core_modules/memory_bus.mm"
with open(path, "r") as f:
    full_content = f.read()

# 1. Define Helper functions
helpers = """inline uint32_t MirrorOffset(uint32_t addr, uint32_t base, uint32_t mask) {
  return (addr - base) & mask;
}

inline uint32_t Read32Wrap(const uint8_t* buf, uint32_t off, uint32_t mask, size_t size) {
  return static_cast<uint32_t>(buf[off % size]) |
         (static_cast<uint32_t>(buf[(off + 1) % size]) << 8) |
         (static_cast<uint32_t>(buf[(off + 2) % size]) << 16) |
         (static_cast<uint32_t>(buf[(off + 3) % size]) << 24);
}

inline void Write16Wrap(uint8_t* buf, uint32_t off, uint32_t mask, size_t size, uint16_t value) {
  buf[off % size] = static_cast<uint8_t>(value & 0xFFu);
  buf[(off + 1) % size] = static_cast<uint8_t>((value >> 8) & 0xFFu);
}

inline void Write32Wrap(uint8_t* buf, uint32_t off, uint32_t mask, size_t size, uint32_t value) {
  buf[off % size] = static_cast<uint8_t>(value & 0xFFu);
  buf[(off + 1) % size] = static_cast<uint8_t>((value >> 8) & 0xFFu);
  buf[(off + 2) % size] = static_cast<uint8_t>((value >> 16) & 0xFFu);
  buf[(off + 3) % size] = static_cast<uint8_t>((value >> 24) & 0xFFu);
}

inline uint32_t VramOffset(uint32_t addr) {
  uint32_t off32 = MirrorOffset(addr, 0x06000000u, 0x1FFFFu);
  if (off32 >= 0x18000u) off32 -= 0x8000u;
  return off32;
}"""

# 2. GBACore methods
readbus32 = """uint32_t GBACore::ReadBus32(uint32_t a) const {
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
    return open_bus_latch_;
  }

  uint32_t val = open_bus_latch_;
  bool mapped = false;

  if (a >= 0x02000000u && a <= 0x02FFFFFFu) {
    val = Read32Wrap(ewram_.data(), a & 0x3FFFFu, 0x3FFFFu, ewram_.size());
    mapped = true;
  } else if (a >= 0x03000000u && a <= 0x03FFFFFFu) {
    val = Read32Wrap(iwram_.data(), a & 0x7FFFu, 0x7FFFu, iwram_.size());
    mapped = true;
  } else if (a >= 0x04000000u && a <= 0x040003FCu) {
    val = static_cast<uint32_t>(ReadIO16(a)) | (static_cast<uint32_t>(ReadIO16(a + 2u)) << 16);
    mapped = true;
  } else if (a >= 0x05000000u && a <= 0x07FFFFFFu) {
    const uint16_t dispstat = ReadIO16(0x04000004u);
    const bool vblank = (dispstat & 1);
    const bool hblank = (dispstat & 2);
    if (a >= 0x07000000u) {
      if (vblank) {
        val = Read32Wrap(oam_.data(), a & 0x3FFu, 0x3FFu, oam_.size());
        mapped = true;
      }
    } else {
      if (vblank || hblank) {
        if (a >= 0x06000000u) val = Read32Wrap(vram_.data(), VramOffset(a), 0x1FFFFu, vram_.size());
        else val = Read32Wrap(palette_ram_.data(), a & 0x3FFu, 0x3FFu, palette_ram_.size());
        mapped = true;
      }
    }
  } else if (a >= 0x08000000u && a <= 0x0DFFFFFFu) {
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
  } else if (a >= 0x0E000000u) {
    val = static_cast<uint32_t>(ReadBackup8(a)) |
          (static_cast<uint32_t>(ReadBackup8(a + 1)) << 8) |
          (static_cast<uint32_t>(ReadBackup8(a + 2)) << 16) |
          (static_cast<uint32_t>(ReadBackup8(a + 3)) << 24);
    mapped = true;
  }

  if (mapped) open_bus_latch_ = val;
  return val;
}"""

read32 = """uint32_t GBACore::Read32(uint32_t addr) const {
  const uint32_t val = ReadBus32(addr);
  const uint32_t rot = (addr & 3u) * 8u;
  return (rot == 0) ? val : RotateRight(val, rot);
}"""

read16 = """uint16_t GBACore::Read16(uint32_t addr) const {
  if (addr & 1u) return static_cast<uint16_t>(Read8(addr)) | (static_cast<uint16_t>(Read8(addr + 1)) << 8);
  const uint32_t val = ReadBus32(addr);
  const uint32_t shift = (addr & 2u) * 8u;
  const uint16_t res = static_cast<uint16_t>(val >> shift);
  if (addr >= 0x02000000u) {
    if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u && addr <= 0x0DFFFFFFu) {
      open_bus_latch_ = (open_bus_latch_ & ~1u) | (val & 1u);
    } else {
      const uint32_t mask = 0xFFFFu << shift;
      open_bus_latch_ = (open_bus_latch_ & ~mask) | (static_cast<uint32_t>(res) << shift);
    }
  }
  return res;
}"""

read8 = """uint8_t GBACore::Read8(uint32_t addr) const {
  const uint32_t val = ReadBus32(addr);
  const uint32_t shift = (addr & 3u) * 8u;
  const uint8_t res = static_cast<uint8_t>(val >> shift);
  if (addr >= 0x02000000u) {
    if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u && addr <= 0x0DFFFFFFu) {
      open_bus_latch_ = (open_bus_latch_ & ~1u) | (val & 1u);
    } else {
      const uint32_t mask = 0xFFu << shift;
      open_bus_latch_ = (open_bus_latch_ & ~mask) | (static_cast<uint32_t>(res) << shift);
    }
  }
  return res;
}"""

write32 = """void GBACore::Write32(uint32_t addr, uint32_t value) {
  open_bus_latch_ = value;
  if (addr == 0x040000A0u || addr == 0x040000A4u) { PushAudioFifo(addr == 0x040000A0u, value); return; }
  Write16(addr, static_cast<uint16_t>(value));
  Write16(addr + 2u, static_cast<uint16_t>(value >> 16));
}"""

write16 = """void GBACore::Write16(uint32_t addr, uint16_t value) {
  open_bus_latch_ = (value | (static_cast<uint32_t>(value) << 16));
  if (addr >= 0x04000000u && addr <= 0x040003FEu) { WriteIO16(addr, value); return; }
  if (addr >= 0x05000000u && addr <= 0x07FFFFFFu) {
    const uint16_t dispstat = ReadIO16(0x04000004u);
    const bool vblank = (dispstat & 1);
    const bool hblank = (dispstat & 2);
    if (addr >= 0x07000000u) {
      if (vblank) Write16Wrap(oam_.data(), addr & 0x3FFu, 0x3FFu, oam_.size(), value);
    } else if (vblank || hblank) {
      if (addr >= 0x06000000u) Write16Wrap(vram_.data(), VramOffset(addr), 0x1FFFFu, vram_.size(), value);
      else Write16Wrap(palette_ram_.data(), addr & 0x3FFu, 0x3FFu, palette_ram_.size(), value);
    }
    return;
  }
  Write8(addr, static_cast<uint8_t>(value));
  Write8(addr + 1u, static_cast<uint8_t>(value >> 8));
}"""

write8 = """void GBACore::Write8(uint32_t addr, uint8_t value) {
  open_bus_latch_ = (value | (value << 8) | (value << 16) | (value << 24));
  if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    const uint32_t a = addr & ~1u;
    const uint16_t v = value | (static_cast<uint16_t>(value) << 8);
    Write16Wrap(palette_ram_.data(), a & 0x3FFu, 0x3FFu, palette_ram_.size(), v);
    return;
  }
  if (addr >= 0x06000000u && addr <= 0x07FFFFFFu) return;
  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) { ewram_[addr & 0x3FFFFu] = value; }
  else if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) { iwram_[addr & 0x7FFFu] = value; }
  else if (addr >= 0x04000000u && addr <= 0x040003FFu) {
    const uint16_t old = ReadIO16(addr & ~1u);
    if (addr & 1u) WriteIO16(addr & ~1u, (old & 0xFFu) | (static_cast<uint16_t>(value) << 8));
    else WriteIO16(addr & ~1u, (old & 0xFF00u) | value);
  } else if (addr >= 0x0E000000u) { WriteBackup8(addr, value); }
}"""

# 3. Handle ReadIO16 and WriteIO16
# Find them in full_content and keep their structure
readio16 = re.findall(r"uint16_t GBACore::ReadIO16\(uint32_t addr\) const \{.*?^\}", full_content, flags=re.DOTALL | re.MULTILINE)[0]
writeio16 = re.findall(r"void GBACore::WriteIO16\(uint32_t addr, uint16_t value\) \{.*?^\}", full_content, flags=re.DOTALL | re.MULTILINE)[0]

# Construct file
new_file = f"""// ---- BEGIN gba_core_memory.cpp ----
#include "../gba_core.h"

namespace gba {{
namespace {{
{helpers}
}}  // namespace

{readbus32}

{read32}

{read16}

{read8}

{write32}

{write16}

{write8}

{readio16}

{writeio16}

}}  // namespace gba
"""

with open(path, "w") as f:
    f.write(new_file)
