import sys
import re

path = "src/core/gba_core_modules/memory_bus.mm"
with open(path, "r") as f:
    full_content = f.read()

# 1. Helpers for mirroring and wrapping
helpers = """inline uint32_t MirrorOffset(uint32_t addr, uint32_t base, uint32_t mask) {
  return (addr - base) & mask;
}

inline uint32_t VramOffset(uint32_t addr) {
  uint32_t off = (addr - 0x06000000u) & 0x1FFFFu;
  if (off >= 0x18000u) off -= 0x8000u;
  return off;
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
}"""

# 2. UpdateOpenBus: Strict lane updates
update_open_bus = """void GBACore::UpdateOpenBus(uint32_t addr, uint32_t val, int size) const {
  if (addr < 0x02000000u) return; // BIOS/Protected or invalid

  if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u && addr <= 0x0DFFFFFFu) {
    open_bus_latch_ = (open_bus_latch_ & ~1u) | (val & 1u);
    return;
  }

  if (size == 4) {
    open_bus_latch_ = val;
  } else if (size == 2) {
    const uint32_t shift = (addr & 2u) * 8u;
    const uint32_t mask = 0xFFFFu << shift;
    open_bus_latch_ = (open_bus_latch_ & ~mask) | (val & mask);
  } else if (size == 1) {
    const uint32_t shift = (addr & 3u) * 8u;
    const uint32_t mask = 0xFFu << shift;
    open_bus_latch_ = (open_bus_latch_ & ~mask) | (val & mask);
  }
}"""

# 3. ReadBus32: Pure aligned source, handling protection and mapping ONLY
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

  if (a >= 0x02000000u && a <= 0x02FFFFFFu) return Read32Wrap(ewram_.data(), a & 0x3FFFFu, 0x3FFFFu, ewram_.size());
  if (a >= 0x03000000u && a <= 0x03FFFFFFu) return Read32Wrap(iwram_.data(), a & 0x7FFFu, 0x7FFFu, iwram_.size());
  if (a >= 0x04000000u && a <= 0x040003FCu) return static_cast<uint32_t>(ReadIO16(a)) | (static_cast<uint32_t>(ReadIO16(a + 2u)) << 16);
  if (a >= 0x05000000u && a <= 0x07FFFFFFu) {
    const uint16_t dispstat = ReadIO16(0x04000004u);
    const bool vblank = (dispstat & 1);
    const bool hblank = (dispstat & 2);
    if (a >= 0x07000000u) {
      if (vblank) return Read32Wrap(oam_.data(), a & 0x3FFu, 0x3FFu, oam_.size());
    } else if (vblank || hblank) {
      if (a >= 0x06000000u) return Read32Wrap(vram_.data(), VramOffset(a), 0x1FFFFu, vram_.size());
      return Read32Wrap(palette_ram_.data(), a & 0x3FFu, 0x3FFu, palette_ram_.size());
    }
    return open_bus_latch_;
  }
  if (a >= 0x08000000u && a <= 0x0DFFFFFFu) {
    if (backup_type_ == BackupType::kEEPROM && a >= 0x0D000000u) return (open_bus_latch_ & ~1u) | (ReadBackup8(a) & 1u);
    if (!rom_.empty()) {
      const size_t base = static_cast<size_t>(a - 0x08000000u) & 0x01FFFFFFu;
      auto rb = [&](size_t off) { return (off < rom_.size()) ? rom_[off] : ((open_bus_latch_ >> ((off & 3)*8)) & 0xFF); };
      return rb(base) | (rb(base+1) << 8) | (rb(base+2) << 16) | (rb(base+3) << 24);
    }
  }
  if (a >= 0x0E000000u) {
    return static_cast<uint32_t>(ReadBackup8(a)) | (static_cast<uint32_t>(ReadBackup8(a + 1)) << 8) |
           (static_cast<uint32_t>(ReadBackup8(a + 2)) << 16) | (static_cast<uint32_t>(ReadBackup8(a + 3)) << 24);
  }
  return open_bus_latch_;
}"""

# 4. Read Wrappers: Systematic latch and shift
read32 = """uint32_t GBACore::Read32(uint32_t addr) const {
  const uint32_t val = ReadBus32(addr);
  UpdateOpenBus(addr & ~3u, val, 4);
  const uint32_t rot = (addr & 3u) * 8u;
  return (rot == 0) ? val : RotateRight(val, rot);
}"""

read16 = """uint16_t GBACore::Read16(uint32_t addr) const {
  const uint32_t val = ReadBus32(addr);
  const uint32_t shift = (addr & 2u) * 8u;
  uint16_t res = static_cast<uint16_t>(val >> shift);
  if (addr & 1u) res = (res >> 8) | (res << 8); // Unaligned rotation
  UpdateOpenBus(addr & ~1u, val >> shift, 2);
  return res;
}"""

read8 = """uint8_t GBACore::Read8(uint32_t addr) const {
  const uint32_t val = ReadBus32(addr);
  const uint32_t shift = (addr & 3u) * 8u;
  const uint8_t res = static_cast<uint8_t>(val >> shift);
  UpdateOpenBus(addr, res, 1);
  return res;
}"""

# 5. Write Wrappers: Mirroring and Aligned decomposition
write32 = """void GBACore::Write32(uint32_t addr, uint32_t value) {
  open_bus_latch_ = value;
  if (addr == 0x040000A0u || addr == 0x040000A4u) { PushAudioFifo(addr == 0x040000A0u, value); return; }
  Write16(addr, static_cast<uint16_t>(value));
  Write16(addr + 2u, static_cast<uint16_t>(value >> 16));
}"""

write16 = """void GBACore::Write16(uint32_t addr, uint16_t value) {
  open_bus_latch_ = (value | (static_cast<uint32_t>(value) << 16));
  const uint32_t a = addr;
  if (a >= 0x04000000u && a <= 0x040003FEu) { WriteIO16(a & ~1u, value); return; }
  if (a >= 0x05000000u && a <= 0x07FFFFFFu) {
    if (a & 1u) return; // Misaligned PPU write usually ignored or weird
    const uint16_t dispstat = ReadIO16(0x04000004u);
    const bool vblank = (dispstat & 1);
    const bool hblank = (dispstat & 2);
    if (a >= 0x07000000u) { if (vblank) Write16Wrap(oam_.data(), a & 0x3FFu, 0x3FFu, oam_.size(), value); }
    else if (vblank || hblank) {
       if (a >= 0x06000000u) Write16Wrap(vram_.data(), VramOffset(a), 0x1FFFFu, vram_.size(), value);
       else Write16Wrap(palette_ram_.data(), a & 0x3FFu, 0x3FFu, palette_ram_.size(), value);
    }
    return;
  }
  Write8(a, static_cast<uint8_t>(value));
  Write8(a + 1u, static_cast<uint8_t>(value >> 8));
}"""

write8 = """void GBACore::Write8(uint32_t addr, uint8_t value) {
  open_bus_latch_ = (value | (value << 8) | (value << 16) | (value << 24));
  if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    // Palette RAM duplicated 8-bit write
    const uint16_t dispstat = ReadIO16(0x04000004u);
    if ((dispstat & 1) || (dispstat & 2)) {
      const uint16_t v16 = value | (static_cast<uint16_t>(value) << 8);
      Write16Wrap(palette_ram_.data(), addr & 0x3FFu, 0x3FFu, palette_ram_.size(), v16);
    }
    return;
  }
  if (addr >= 0x06000000u && addr <= 0x07FFFFFFu) return;
  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) { ewram_[addr & 0x3FFFFu] = value; }
  else if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) { iwram_[addr & 0x7FFFu] = value; }
  else if (addr >= 0x04000000u && addr <= 0x040003FFu) {
    const uint16_t old = ReadIO16(addr & ~1u);
    if (addr & 1u) WriteIO16(addr & ~1u, (old & 0xFFu) | (static_cast<uint16_t>(value) << 8));
    else WriteIO16(addr & ~1u, (old & 0xFF00u) | value);
  }
  else if (addr >= 0x0E000000u) { WriteBackup8(addr, value); }
}"""

# 6. ReadIO16 with Open Bus merging
readio16 = """uint16_t GBACore::ReadIO16(uint32_t addr) const {
  addr &= ~1u;
  if (addr < 0x04000000u || addr > 0x040003FEu) return 0;
  const size_t off = static_cast<size_t>(addr - 0x04000000u);
  if (off + 1 >= io_regs_.size()) return 0;
  uint16_t val = static_cast<uint16_t>(io_regs_[off]) | static_cast<uint16_t>(io_regs_[off + 1] << 8);

  uint16_t mask = 0xFFFFu;
  switch(addr) {
    case 0x04000004u: mask = 0xFFBFu; break;
    case 0x04000006u: mask = 0x00FFu; break;
    case 0x04000084u: mask = 0x008Fu; break;
  }
  if (mask != 0xFFFFu) {
    const uint16_t open = static_cast<uint16_t>(open_bus_latch_ >> ((addr & 2) * 8));
    val = (val & mask) | (open & ~mask);
  }
  return val;
}"""

# 7. WriteIO16 with full masking
# Extract previous version to keep side effects, but apply masking structure
writeio16_match = re.search(r"void GBACore::WriteIO16\(uint32_t addr, uint16_t value\) \{(.*?)\n\}", full_content, flags=re.DOTALL | re.MULTILINE)
writeio16_inner = writeio16_match.group(1) if writeio16_match else ""
# (Already has switch-based side effects from v36, keep them)
writeio16 = "void GBACore::WriteIO16(uint32_t addr, uint16_t value) {" + writeio16_inner + "\n}"

# Construct file
new_file = f"""// ---- BEGIN gba_core_memory.cpp ----
#include "../gba_core.h"

namespace gba {{
namespace {{
{helpers}
}}  // namespace

{update_open_bus}

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

# Headers needed in GBACore
header_path = "src/core/gba_core.h"
with open(header_path, "r") as f:
    h_content = f.read()

if "UpdateOpenBus" not in h_content:
    h_content = h_content.replace("uint32_t ReadBus32(uint32_t a) const;", "uint32_t ReadBus32(uint32_t a) const;\\n  void UpdateOpenBus(uint32_t addr, uint32_t val, int size) const;")

with open(header_path, "w") as f:
    f.write(h_content.replace("\\n", "\n"))

with open(path, "w") as f:
    f.write(new_file)
