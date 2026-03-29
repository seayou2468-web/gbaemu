// ---- BEGIN gba_core_memory.cpp ----
#include "../gba_core.h"

namespace gba {
namespace {
inline uint32_t MirrorOffset(uint32_t addr, uint32_t base, uint32_t mask) {
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
}

}  // namespace

void GBACore::AddWaitstates(uint32_t addr, int size) const {
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
}

void GBACore::UpdateOpenBus(uint32_t addr, uint32_t val, int size) const {
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
}

uint32_t GBACore::ReadBus32(uint32_t a) const {
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
    if (a >= 0x07000000u) {
      return Read32Wrap(oam_.data(), a & 0x3FFu, 0x3FFu, oam_.size());
    }
    if (a >= 0x06000000u) return Read32Wrap(vram_.data(), VramOffset(a), 0x1FFFFu, vram_.size());
    return Read32Wrap(palette_ram_.data(), a & 0x3FFu, 0x3FFu, palette_ram_.size());
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
}

uint32_t GBACore::Read32(uint32_t addr) const {
  AddWaitstates(addr, 4);
  if (addr < 0x00004000u && cpu_.regs[15] >= 0x00004000u) return open_bus_latch_;
  const uint32_t val = ReadBus32(addr);
  UpdateOpenBus(addr, val, 4);
  const uint32_t rot = (addr & 3u) * 8u;
  return (rot == 0) ? val : RotateRight(val, rot);
}

uint16_t GBACore::Read16(uint32_t addr) const {
  AddWaitstates(addr, 2);
  if (addr < 0x00004000u && cpu_.regs[15] >= 0x00004000u) return static_cast<uint16_t>(open_bus_latch_ >> ((addr & 2u) * 8u));
  const uint32_t val = ReadBus32(addr);
  UpdateOpenBus(addr, val, 2);
  const uint32_t shift = (addr & 2u) * 8u;
  uint16_t res = static_cast<uint16_t>(val >> shift);
  if (addr & 1u) res = (res >> 8) | (res << 8);
  return res;
}

uint8_t GBACore::Read8(uint32_t addr) const {
  AddWaitstates(addr, 1);
  if (addr < 0x00004000u && cpu_.regs[15] >= 0x00004000u) return static_cast<uint8_t>(open_bus_latch_ >> ((addr & 3u) * 8u));
  const uint32_t val = ReadBus32(addr);
  UpdateOpenBus(addr, val, 1);
  return static_cast<uint8_t>(val >> ((addr & 3u) * 8u));
}

void GBACore::Write32(uint32_t addr, uint32_t value) {
  AddWaitstates(addr, 4);
  if (addr == 0x040000A0u || addr == 0x040000A4u) { PushAudioFifo(addr == 0x040000A0u, value); return; }
  UpdateOpenBus(addr, value, 4);
  Write16(addr, static_cast<uint16_t>(value));
  Write16(addr + 2u, static_cast<uint16_t>(value >> 16));
}

void GBACore::Write16(uint32_t addr, uint16_t value) {
  AddWaitstates(addr, 2);
  UpdateOpenBus(addr, (static_cast<uint32_t>(value) | (static_cast<uint32_t>(value) << 16)), 2);
  const uint32_t a = addr & ~1u;
  if (a >= 0x04000000u && a <= 0x040003FEu) { WriteIO16(a, value); return; }
  if (a >= 0x05000000u && a <= 0x07FFFFFFu) {
    if (a >= 0x07000000u) {
      Write16Wrap(oam_.data(), a & 0x3FFu, 0x3FFu, oam_.size(), value);
    } else {
      if (a >= 0x06000000u) Write16Wrap(vram_.data(), VramOffset(a), 0x1FFFFu, vram_.size(), value);
      else Write16Wrap(palette_ram_.data(), a & 0x3FFu, 0x3FFu, palette_ram_.size(), value);
    }
    return;
  }
  Write8(a, static_cast<uint8_t>(value));
  Write8(a + 1u, static_cast<uint8_t>(value >> 8));
}

void GBACore::Write8(uint32_t addr, uint8_t value) {
  AddWaitstates(addr, 1);
  UpdateOpenBus(addr, (static_cast<uint32_t>(value) * 0x01010101u), 1);

  if (addr >= 0x05000000u && addr <= 0x07FFFFFFu) {
    const uint32_t a = addr & ~1u;
    const uint16_t v16 = static_cast<uint16_t>(value) | (static_cast<uint16_t>(value) << 8);
    if (a >= 0x07000000u) {
      Write16Wrap(oam_.data(), a & 0x3FFu, 0x3FFu, oam_.size(), v16);
    } else {
      if (a >= 0x06000000u) Write16Wrap(vram_.data(), VramOffset(a), 0x1FFFFu, vram_.size(), v16);
      else Write16Wrap(palette_ram_.data(), a & 0x3FFu, 0x3FFu, palette_ram_.size(), v16);
    }
    return;
  }

  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) { ewram_[addr & 0x3FFFFu] = value; }
  else if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) { iwram_[addr & 0x7FFFu] = value; }
  else if (addr >= 0x04000000u && addr <= 0x040003FFu) {
    const uint16_t old = ReadIO16(addr & ~1u);
    if (addr & 1u) WriteIO16(addr & ~1u, (old & 0xFFu) | (static_cast<uint16_t>(value) << 8));
    else WriteIO16(addr & ~1u, (old & 0xFF00u) | value);
  }
  else if (addr >= 0x0E000000u) { WriteBackup8(addr, value); }
}

uint16_t GBACore::ReadIO16(uint32_t addr) const {
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
}

void GBACore::WriteIO16(uint32_t addr, uint16_t value) {
  addr &= ~1u;
  if (addr < 0x04000000u || addr > 0x040003FEu) return;
  const size_t off = static_cast<size_t>(addr - 0x04000000u);
  if (off + 1 >= io_regs_.size()) return;

  switch(addr) {
    case 0x04000000u:
      // Bit3 is CGB mode (read-only on GBA). Keep all other writable bits,
      // including bit7 Forced Blank.
      value &= static_cast<uint16_t>(~0x0008u);
      break;
    case 0x04000004u: {
      const uint16_t old = ReadIO16(addr);
      const uint16_t vcount = ReadIO16(0x04000006u);
      const uint16_t lyc = (value >> 8) & 0xFF;
      value = (value & 0xFFB8u) | (old & 0x0007u);
      if (vcount == lyc) value |= 0x0004u; else value &= ~0x0004u;
      break;
    }
    case 0x04000006u: return;
    case 0x04000202u: {
      const uint16_t old = ReadIO16(addr);
      value = old & ~value;
      break;
    }
    case 0x04000130u: return;

    // DMA Control Registers
    case 0x040000B8u: // DMA0CNT_H
    case 0x040000C4u: // DMA1CNT_H
    case 0x040000D0u: // DMA2CNT_H
    case 0x040000DCu: { // DMA3CNT_H
      const int ch = (addr - 0x040000B8u) / 12 + ((addr == 0x040000B8u) ? 0 : 0); // Wait, offset is fixed
      int actual_ch = 0;
      if (addr == 0x040000B8u) actual_ch = 0;
      else if (addr == 0x040000C4u) actual_ch = 1;
      else if (addr == 0x040000D0u) actual_ch = 2;
      else actual_ch = 3;

      const uint16_t old = ReadIO16(addr);
      uint16_t mask = (actual_ch == 3) ? 0xFFE0u : 0xF7E0u;
      value &= mask;
      if (((value >> 12) & 3) == 3 && actual_ch == 0) value &= ~(3u << 12);

      if (!(old & 0x8000u) && (value & 0x8000u)) {
        // Latch SAD/DAD/CNT into shadows on enable transition
        const uint32_t base = 0x040000B0u + actual_ch * 12u;
        dma_shadows_[actual_ch].sad = Read32(base);
        dma_shadows_[actual_ch].initial_dad = Read32(base + 4);
        dma_shadows_[actual_ch].dad = dma_shadows_[actual_ch].initial_dad;
        uint32_t c = ReadIO16(base + 8);
        if (c == 0) c = (actual_ch == 3) ? 0x10000u : 0x4000u;
        dma_shadows_[actual_ch].initial_count = c;
        dma_shadows_[actual_ch].count = c;
        dma_shadows_[actual_ch].active = true;
      }
      break;
    }
  }

  if (addr >= 0x04000100u && addr <= 0x0400010Eu) {
    const uint32_t tidx = (addr - 0x04000100u) / 4u;
    if (addr & 2) {
      const uint16_t old = ReadIO16(addr);
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

  io_regs_[off] = static_cast<uint8_t>(value & 0xFFu);
  io_regs_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFFu);

  // Trigger immediate DMA
  if (addr == 0x040000B8u || addr == 0x040000C4u || addr == 0x040000D0u || addr == 0x040000DCu) {
    if ((value & 0x8000u) && ((value >> 12) & 3) == 0) StepDma();
  }
}

}  // namespace gba
