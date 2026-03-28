// ---- BEGIN gba_core_memory.cpp ----
#include "../gba_core.h"

namespace gba {

namespace {
inline uint32_t MirrorOffset(uint32_t addr, uint32_t base, uint32_t mask) {
  return (addr - base) & mask;
}

inline uint16_t Read16Wrap(const uint8_t* buf, uint32_t off, uint32_t mask) {
  const uint32_t o0 = off & mask;
  const uint32_t o1 = (off + 1u) & mask;
  return static_cast<uint16_t>(buf[o0]) |
         static_cast<uint16_t>(buf[o1] << 8);
}

inline uint32_t Read32Wrap(const uint8_t* buf, uint32_t off, uint32_t mask) {
  const uint32_t o0 = off & mask;
  const uint32_t o1 = (off + 1u) & mask;
  const uint32_t o2 = (off + 2u) & mask;
  const uint32_t o3 = (off + 3u) & mask;
  return static_cast<uint32_t>(buf[o0]) |
         (static_cast<uint32_t>(buf[o1]) << 8) |
         (static_cast<uint32_t>(buf[o2]) << 16) |
         (static_cast<uint32_t>(buf[o3]) << 24);
}

inline void Write16Wrap(uint8_t* buf, uint32_t off, uint32_t mask, uint16_t value) {
  const uint32_t o0 = off & mask;
  const uint32_t o1 = (off + 1u) & mask;
  buf[o0] = static_cast<uint8_t>(value & 0xFFu);
  buf[o1] = static_cast<uint8_t>((value >> 8) & 0xFFu);
}

inline void Write32Wrap(uint8_t* buf, uint32_t off, uint32_t mask, uint32_t value) {
  const uint32_t o0 = off & mask;
  const uint32_t o1 = (off + 1u) & mask;
  const uint32_t o2 = (off + 2u) & mask;
  const uint32_t o3 = (off + 3u) & mask;
  buf[o0] = static_cast<uint8_t>(value & 0xFFu);
  buf[o1] = static_cast<uint8_t>((value >> 8) & 0xFFu);
  buf[o2] = static_cast<uint8_t>((value >> 16) & 0xFFu);
  buf[o3] = static_cast<uint8_t>((value >> 24) & 0xFFu);
}

inline uint32_t VramOffset(uint32_t addr) {
  uint32_t off32 = MirrorOffset(addr, 0x06000000u, 0x1FFFFu);
  if (off32 >= 0x18000u) off32 -= 0x8000u;
  return off32;
}
}  // namespace

uint32_t GBACore::ReadBus32(uint32_t a) const {
  // a is ALWAYS aligned to 4 bytes

  // 1. BIOS Region (Internal Bus)
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
    // Protected BIOS Read: return the fetch latch. No open bus update.
    return bios_fetch_latch_;
  }

  // 2. System Bus Regions
  uint32_t val = open_bus_latch_;

  if (a >= 0x02000000u && a <= 0x02FFFFFFu) { // EWRAM
    val = Read32Wrap(ewram_.data(), MirrorOffset(a, 0x02000000u, 0x3FFFFu), 0x3FFFFu);
  } else if (a >= 0x03000000u && a <= 0x03FFFFFFu) { // IWRAM
    val = Read32Wrap(iwram_.data(), MirrorOffset(a, 0x03000000u, 0x7FFFu), 0x7FFFu);
  } else if (a >= 0x04000000u && a <= 0x040003FCu) { // IO
    const uint16_t lo = ReadIO16(a);
    const uint16_t hi = ReadIO16(a + 2u);
    val = static_cast<uint32_t>(lo) | (static_cast<uint32_t>(hi) << 16);
  } else if (a >= 0x05000000u && a <= 0x07FFFFFFu) { // PPU
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
    } else {
      // Disallowed PPU access returns current latch without updating it
      return open_bus_latch_;
    }
  } else if (a >= 0x08000000u && a <= 0x0DFFFFFFu) { // ROM / EEPROM
    if (backup_type_ == BackupType::kEEPROM && a >= 0x0D000000u) {
      val = (open_bus_latch_ & ~1u) | (ReadBackup8(a) & 1u);
    } else if (!rom_.empty()) {
      const size_t base = static_cast<size_t>(a - 0x08000000u) & 0x01FFFFFFu;
      auto rb = [&](size_t off) {
        return (off < rom_.size()) ? rom_[off] : ((open_bus_latch_ >> ((off & 3)*8)) & 0xFF);
      };
      val = rb(base) | (rb(base+1) << 8) | (rb(base+2) << 16) | (rb(base+3) << 24);
    }
  } else if (a >= 0x0E000000u) { // Backup (SRAM/Flash)
    val = static_cast<uint32_t>(ReadBackup8(a)) |
          (static_cast<uint32_t>(ReadBackup8(a + 1)) << 8) |
          (static_cast<uint32_t>(ReadBackup8(a + 2)) << 16) |
          (static_cast<uint32_t>(ReadBackup8(a + 3)) << 24);
  }

  // System bus regions update open_bus_latch_
  if (a >= 0x02000000u) {
    open_bus_latch_ = val;
  }

  return val;
}

uint32_t GBACore::Read32(uint32_t addr) const {
  const uint32_t aligned = addr & ~3u;
  const uint32_t val = ReadBus32(aligned);
  const uint32_t rot = (addr & 3u) * 8u;
  return (rot == 0) ? val : RotateRight(val, rot);
}

uint16_t GBACore::Read16(uint32_t addr) const {
  if (addr & 1u) {
    // Unaligned Read16: sequential Read8s
    return static_cast<uint16_t>(Read8(addr)) | (static_cast<uint16_t>(Read8(addr + 1)) << 8);
  }
  const uint32_t aligned = addr & ~3u;
  const uint32_t val = ReadBus32(aligned);
  const uint32_t shift = (addr & 2u) * 8u;
  const uint16_t res = static_cast<uint16_t>((val >> shift) & 0xFFFFu);

  if (addr >= 0x02000000u) {
    // Partial update of open_bus_latch_ as per hardware behavior for 16-bit access
    const uint32_t mask = 0xFFFFu << shift;
    open_bus_latch_ = (open_bus_latch_ & ~mask) | (static_cast<uint32_t>(res) << shift);
  }
  return res;
}

uint8_t GBACore::Read8(uint32_t addr) const {
  const uint32_t aligned = addr & ~3u;
  const uint32_t val = ReadBus32(aligned);
  const uint32_t shift = (addr & 3u) * 8u;
  const uint8_t res = static_cast<uint8_t>((val >> shift) & 0xFFu);

  if (addr >= 0x02000000u) {
    // Partial update of open_bus_latch_ as per hardware behavior for 8-bit access
    const uint32_t mask = 0xFFu << shift;
    open_bus_latch_ = (open_bus_latch_ & ~mask) | (static_cast<uint32_t>(res) << shift);
  }
  return res;
}

void GBACore::Write32(uint32_t addr, uint32_t value) {
  open_bus_latch_ = value;
  if (addr == 0x040000A0u || addr == 0x040000A4u) {
    PushAudioFifo(addr == 0x040000A0u, value);
    return;
  }
  // PPU Regions: decompose to aligned Write16
  if (addr >= 0x05000000u && addr <= 0x07FFFFFFu) {
    Write16(addr, static_cast<uint16_t>(value & 0xFFFFu));
    Write16(addr + 2u, static_cast<uint16_t>((value >> 16) & 0xFFFFu));
    return;
  }

  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) {
    Write32Wrap(ewram_.data(), MirrorOffset(addr, 0x02000000u, 0x3FFFFu), 0x3FFFFu, value);
  } else if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) {
    Write32Wrap(iwram_.data(), MirrorOffset(addr, 0x03000000u, 0x7FFFu), 0x7FFFu, value);
  } else if (addr >= 0x04000000u && addr <= 0x040003FCu) {
    WriteIO16(addr & ~1u, static_cast<uint16_t>(value & 0xFFFFu));
    WriteIO16((addr + 2u) & ~1u, static_cast<uint16_t>((value >> 16) & 0xFFFFu));
  } else if (addr >= 0x0E000000u) {
    for (int i = 0; i < 4; ++i) WriteBackup8(addr + i, static_cast<uint8_t>((value >> (i * 8)) & 0xFFu));
  }
}

void GBACore::Write16(uint32_t addr, uint16_t value) {
  open_bus_latch_ = (value | (static_cast<uint32_t>(value) << 16));
  if (addr >= 0x05000000u && addr <= 0x07FFFFFFu) {
    const uint32_t aligned = addr & ~1u;
    if (aligned >= 0x05000000u && aligned <= 0x05FFFFFFu) Write16Wrap(palette_ram_.data(), MirrorOffset(aligned, 0x05000000u, 0x3FFu), 0x3FFu, value);
    else if (aligned >= 0x06000000u && aligned <= 0x06FFFFFFu) Write16Wrap(vram_.data(), VramOffset(aligned), 0x1FFFFu, value);
    else if (aligned >= 0x07000000u) Write16Wrap(oam_.data(), MirrorOffset(aligned, 0x07000000u, 0x3FFu), 0x3FFu, value);
    return;
  }
  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) {
    Write16Wrap(ewram_.data(), MirrorOffset(addr, 0x02000000u, 0x3FFFFu), 0x3FFFFu, value);
  } else if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) {
    Write16Wrap(iwram_.data(), MirrorOffset(addr, 0x03000000u, 0x7FFFu), 0x7FFFu, value);
  } else if (addr >= 0x04000000u && addr <= 0x040003FEu) {
    WriteIO16(addr & ~1u, value);
  } else if (addr >= 0x0E000000u) {
    for (int i = 0; i < 2; ++i) WriteBackup8(addr + i, static_cast<uint8_t>((value >> (i * 8)) & 0xFFu));
  }
}

void GBACore::Write8(uint32_t addr, uint8_t value) {
  open_bus_latch_ = (value | (value << 8) | (value << 16) | (value << 24));
  if (addr >= 0x05000000u && addr <= 0x07FFFFFFu) return; // Write8 ignored on PPU
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
}

uint16_t GBACore::ReadIO16(uint32_t addr) const {
  if (addr < 0x04000000u || addr > 0x040003FEu) return 0;
  const size_t off = static_cast<size_t>(addr - 0x04000000u);
  if (off + 1 >= io_regs_.size()) return 0;
  return static_cast<uint16_t>(io_regs_[off]) |
         static_cast<uint16_t>(io_regs_[off + 1] << 8);
}

void GBACore::WriteIO16(uint32_t addr, uint16_t value) {
  if (addr < 0x04000000u || addr > 0x040003FEu) return;
  const size_t off = static_cast<size_t>(addr - 0x04000000u);
  if (off + 1 >= io_regs_.size()) return;

  switch(addr) {
    case 0x04000000u: value &= ~0x0008u; break; // DISPCNT
    case 0x04000004u: { // DISPSTAT
      const uint16_t old = ReadIO16(addr);
      value = (value & 0xFFB8u) | (old & 0x0007u);
      break;
    }
    case 0x04000006u: return; // VCOUNT RO
    case 0x04000130u: return; // KEYINPUT RO
    case 0x04000202u: { // IF W1C
      const uint16_t old = ReadIO16(addr);
      value = old & ~value;
      break;
    }
    case 0x04000204u: value &= 0x5FFFu; break; // WAITCNT
    case 0x04000208u: value &= 0x0001u; break; // IME
    case 0x04000050u: value &= 0x3FFFu; break; // BLDCNT
    case 0x04000084u: { // SOUNDCNT_X
      const uint16_t old = ReadIO16(addr);
      value = (value & 0x0080u) | (old & 0x000Fu);
      if ((old & 0x0080u) && !(value & 0x0080u)) {
        for (size_t i = 0x60; i <= 0x81; ++i) io_regs_[i] = 0;
        apu_ch1_active_ = apu_ch2_active_ = apu_ch3_active_ = apu_ch4_active_ = false;
      }
      break;
    }
    case 0x04000082u: { // SOUNDCNT_H
      if (value & (1u << 11)) { fifo_a_.clear(); fifo_a_last_sample_ = 0; value &= ~(1u << 11); }
      if (value & (1u << 15)) { fifo_b_.clear(); fifo_b_last_sample_ = 0; value &= ~(1u << 15); }
      break;
    }
  }

  if (addr >= 0x04000008u && addr <= 0x0400000Eu && (addr & 1) == 0) {
    if ((addr - 0x04000008u) / 2 < 2) value &= ~(1u << 13);
  }

  if (addr >= 0x040000B0u && addr <= 0x040000DEu) {
    const uint32_t ch = (addr - 0x040000B0u) / 12u;
    const uint32_t reg = (addr - 0x040000B0u) % 12u;
    if (reg == 8u && ch < 3u) value &= 0x3FFFu;
    if (reg == 10u) {
       uint16_t mask = (ch == 3u) ? 0xFFE0u : 0xF7E0u;
       value &= mask;
       if (((value >> 12) & 0x3) == 3 && ch == 0) value &= ~(0x3u << 12);
    }
  }

  if (addr >= 0x04000100u && addr <= 0x0400010Eu) {
    const uint32_t tidx = (addr - 0x04000100u) / 4u;
    if (tidx < 4) {
      if (addr & 2) {
        const uint16_t old = ReadIO16(addr);
        value &= 0x00C7u; if (tidx == 0) value &= ~0x0004u;
        timers_[tidx].control = value;
        if (!(old & 0x80u) && (value & 0x80u)) {
          timers_[tidx].counter = timers_[tidx].reload;
          timers_[tidx].prescaler_accum = 0;
          io_regs_[0x100u + tidx*4] = timers_[tidx].reload & 0xFF;
          io_regs_[0x101u + tidx*4] = (timers_[tidx].reload >> 8) & 0xFF;
        }
      } else {
        timers_[tidx].reload = value;
        if (!(timers_[tidx].control & 0x80u)) timers_[tidx].counter = value;
      }
    }
  }

  io_regs_[off] = static_cast<uint8_t>(value & 0xFFu);
  io_regs_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFFu);
}

}  // namespace gba
