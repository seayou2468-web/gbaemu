import sys
import re

path = "src/core/gba_core_modules/memory_bus.mm"
with open(path, "r") as f:
    content = f.read()

def replace_func(c, name, body):
    pattern = rf"(uint\d+_t|void) GBACore::{name}\(uint32_t addr(?:, (?:uint\d+_t|uint16_t|uint8_t) value)?\) (?:const )?\{{.*?^}}"
    return re.sub(pattern, body, c, flags=re.DOTALL | re.MULTILINE)

# 1. AddWaitstates helper
# Rules:
# BIOS: 1 cycle
# EWRAM: 3 cycles (16-bit) -> 3+3=6 for 32-bit
# IWRAM: 1 cycle
# IO: 1 cycle
# Palette: 1 cycle (16-bit) -> 1+1=2 for 32-bit
# VRAM: 1 cycle (16-bit) -> 1+1=2 for 32-bit
# OAM: 1 cycle
# ROM: N+S (N=Non-seq, S=Seq)
add_waitstates = """void GBACore::AddWaitstates(uint32_t addr, int size) const {
  uint32_t region = addr >> 24;
  bool seq = ((addr & ~3u) == (last_access_addr_ & ~3u)) && (addr >= last_access_addr_);
  last_access_addr_ = addr;

  int cycles = 1;
  switch (region) {
    case 0x00: cycles = 1; break;
    case 0x02: cycles = (size == 4) ? 6 : 3; break;
    case 0x03: cycles = 1; break;
    case 0x04: cycles = 1; break;
    case 0x05:
    case 0x06: cycles = (size == 4) ? 2 : 1; break;
    case 0x07: cycles = 1; break;
    case 0x08:
    case 0x09:
    case 0x0A:
    case 0x0B:
    case 0x0C:
    case 0x0D: {
      // ROM Waitstates (N=4, S=2 default)
      uint16_t waitcnt = ReadIO16(0x04000204u);
      int n_clks[4] = {4, 3, 2, 8};
      int s_clks[2] = {2, 1};
      int n = n_clks[(waitcnt >> 2) & 3];
      int s = s_clks[(waitcnt >> 4) & 1];
      cycles = seq ? s : n;
      if (size == 4) cycles += s;
      break;
    }
    case 0x0E:
    case 0x0F: cycles = (size == 4) ? 4 : (size == 2 ? 2 : 1); break;
  }
  waitstates_accum_ += cycles;
}"""

# Inject into file
content = content.replace("void GBACore::UpdateOpenBus", add_waitstates + "\n\nvoid GBACore::UpdateOpenBus")

# Update Read32/16/8 to call AddWaitstates
read32 = """uint32_t GBACore::Read32(uint32_t addr) const {
  AddWaitstates(addr, 4);
  if (addr < 0x00004000u && cpu_.regs[15] >= 0x00004000u) return open_bus_latch_;
  const uint32_t val = ReadBus32(addr);
  UpdateOpenBus(addr, val, 4);
  const uint32_t rot = (addr & 3u) * 8u;
  return (rot == 0) ? val : RotateRight(val, rot);
}"""

read16 = """uint16_t GBACore::Read16(uint32_t addr) const {
  AddWaitstates(addr, 2);
  if (addr < 0x00004000u && cpu_.regs[15] >= 0x00004000u) return static_cast<uint16_t>(open_bus_latch_ >> ((addr & 2u) * 8u));
  const uint32_t val = ReadBus32(addr);
  UpdateOpenBus(addr, val, 2);
  const uint32_t shift = (addr & 2u) * 8u;
  uint16_t res = static_cast<uint16_t>(val >> shift);
  if (addr & 1u) res = (res >> 8) | (res << 8);
  return res;
}"""

read8 = """uint8_t GBACore::Read8(uint32_t addr) const {
  AddWaitstates(addr, 1);
  if (addr < 0x00004000u && cpu_.regs[15] >= 0x00004000u) return static_cast<uint8_t>(open_bus_latch_ >> ((addr & 3u) * 8u));
  const uint32_t val = ReadBus32(addr);
  UpdateOpenBus(addr, val, 1);
  return static_cast<uint8_t>(val >> ((addr & 3u) * 8u));
}"""

# Update Write32/16/8 as well
write32 = """void GBACore::Write32(uint32_t addr, uint32_t value) {
  AddWaitstates(addr, 4);
  if (addr == 0x040000A0u || addr == 0x040000A4u) { PushAudioFifo(addr == 0x040000A0u, value); return; }
  UpdateOpenBus(addr, value, 4);
  Write16(addr, static_cast<uint16_t>(value));
  Write16(addr + 2u, static_cast<uint16_t>(value >> 16));
}"""

write16 = """void GBACore::Write16(uint32_t addr, uint16_t value) {
  AddWaitstates(addr, 2);
  UpdateOpenBus(addr, value, 2);
  const uint32_t a = addr;
  if (a >= 0x04000000u && a <= 0x040003FEu) { WriteIO16(a & ~1u, value); return; }
  if (a >= 0x05000000u && a <= 0x07FFFFFFu) {
    const uint16_t dispstat = ReadIO16(0x04000004u);
    const bool vblank = (dispstat & 1);
    const bool hblank = (dispstat & 2);
    const uint32_t aligned = a & ~1u;
    if (aligned >= 0x07000000u) { if (vblank) Write16Wrap(oam_.data(), aligned & 0x3FFu, 0x3FFu, oam_.size(), value); }
    else if (vblank || hblank) {
       if (aligned >= 0x06000000u) Write16Wrap(vram_.data(), VramOffset(aligned), 0x1FFFFu, vram_.size(), value);
       else Write16Wrap(palette_ram_.data(), aligned & 0x3FFu, 0x3FFu, palette_ram_.size(), value);
    }
    return;
  }
  Write8(a, static_cast<uint8_t>(value));
  Write8(a + 1u, static_cast<uint8_t>(value >> 8));
}"""

write8 = """void GBACore::Write8(uint32_t addr, uint8_t value) {
  AddWaitstates(addr, 1);
  UpdateOpenBus(addr, value, 1);
  if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    const uint16_t dispstat = ReadIO16(0x04000004u);
    if ((dispstat & 1) || (dispstat & 2)) {
      const uint32_t aligned = addr & ~1u;
      const uint16_t v16 = value | (static_cast<uint16_t>(value) << 8);
      Write16Wrap(palette_ram_.data(), aligned & 0x3FFu, 0x3FFu, palette_ram_.size(), v16);
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

content = replace_func(content, "Read32", read32)
content = replace_func(content, "Read16", read16)
content = replace_func(content, "Read8", read8)
content = replace_func(content, "Write32", write32)
content = replace_func(content, "Write16", write16)
content = replace_func(content, "Write8", write8)

with open(path, "w") as f:
    f.write(content)

# Update header
header_path = "src/core/gba_core.h"
with open(header_path, "r") as f:
    h_content = f.read()
if "AddWaitstates" not in h_content:
    h_content = h_content.replace("void UpdateOpenBus(uint32_t addr, uint32_t val, int size) const;",
                                  "void UpdateOpenBus(uint32_t addr, uint32_t val, int size) const;\\n  void AddWaitstates(uint32_t addr, int size) const;")
with open(header_path, "w") as f:
    f.write(h_content.replace("\\n", "\n"))
