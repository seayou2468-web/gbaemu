#include "../gba_core.h"
#include <algorithm>

namespace gba {
namespace {

inline uint32_t Read32Wrap(const uint8_t* buf, uint32_t off, size_t size) {
  if (off + 3u >= size) return 0;
  return static_cast<uint32_t>(buf[off]) |
         (static_cast<uint32_t>(buf[off + 1u]) << 8) |
         (static_cast<uint32_t>(buf[off + 2u]) << 16) |
         (static_cast<uint32_t>(buf[off + 3u]) << 24);
}
inline uint16_t Read16Wrap(const uint8_t* buf, uint32_t off, size_t size) {
  if (off + 1u >= size) return 0;
  return static_cast<uint16_t>(buf[off]) |
         (static_cast<uint16_t>(buf[off + 1u]) << 8);
}
inline void Write32Wrap(uint8_t* buf, uint32_t off, size_t size, uint32_t v) {
  if (off + 3u >= size) return;
  buf[off] = static_cast<uint8_t>(v & 0xFFu);
  buf[off+1] = static_cast<uint8_t>((v >> 8) & 0xFFu);
  buf[off+2] = static_cast<uint8_t>((v >> 16) & 0xFFu);
  buf[off+3] = static_cast<uint8_t>((v >> 24) & 0xFFu);
}
inline void Write16Wrap(uint8_t* buf, uint32_t off, size_t size, uint16_t v) {
  if (off + 1u >= size) return;
  buf[off] = static_cast<uint8_t>(v & 0xFFu);
  buf[off+1] = static_cast<uint8_t>((v >> 8) & 0xFFu);
}

inline uint32_t VramOffset(uint32_t addr) {
  uint32_t off = addr & 0x1FFFFu;
  if (off >= 0x18000u) off -= 0x8000u;
  return off;
}
inline uint32_t Read32Vram(const std::array<uint8_t, 96 * 1024>& vram, uint32_t addr) {
  return static_cast<uint32_t>(vram[VramOffset(addr)]) |
         (static_cast<uint32_t>(vram[VramOffset(addr + 1u)]) << 8) |
         (static_cast<uint32_t>(vram[VramOffset(addr + 2u)]) << 16) |
         (static_cast<uint32_t>(vram[VramOffset(addr + 3u)]) << 24);
}
inline void Write32Vram(std::array<uint8_t, 96 * 1024>& vram, uint32_t addr, uint32_t v) {
  vram[VramOffset(addr)] = static_cast<uint8_t>(v & 0xFFu);
  vram[VramOffset(addr + 1u)] = static_cast<uint8_t>((v >> 8) & 0xFFu);
  vram[VramOffset(addr + 2u)] = static_cast<uint8_t>((v >> 16) & 0xFFu);
  vram[VramOffset(addr + 3u)] = static_cast<uint8_t>((v >> 24) & 0xFFu);
}

uint32_t GamePakWaitstateSlot(uint32_t addr) {
  if (addr >= 0x08000000u && addr <= 0x09FFFFFFu) return 0;
  if (addr >= 0x0A000000u && addr <= 0x0BFFFFFFu) return 1;
  if (addr >= 0x0C000000u && addr <= 0x0DFFFFFFu) return 2;
  return 0xFFFFFFFFu;
}

}  // namespace

void GBACore::AddWaitstates(uint32_t addr, int size, bool is_write) const {
  const uint32_t region = (addr >> 24) & 0xFu;
  uint32_t aligned_addr = addr;
  if (size == 4) aligned_addr &= ~3u;
  else if (size == 2) aligned_addr &= ~1u;

  const bool seq = last_access_valid_ && (aligned_addr == (last_access_addr_ + last_access_size_));
  int cycles = 0;

  if (size == 4) cycles = seq ? ws_s32_[region] : ws_n32_[region];
  else cycles = seq ? ws_s16_[region] : ws_n16_[region];

  if (!is_write && gamepak_prefetch_enabled_ && region >= 0x08 && region <= 0x0D) {
    if (seq) {
      if (prefetch_wait_ > 0) {
        if (cycles > prefetch_wait_) { cycles -= prefetch_wait_; prefetch_wait_ = 0; }
        else { prefetch_wait_ -= cycles; cycles = 0; }
      }
    } else prefetch_wait_ = 0;
  }

  last_access_addr_ = aligned_addr;
  last_access_size_ = static_cast<uint8_t>(size);
  last_access_valid_ = true;
  last_access_seq_ = seq;
  waitstates_accum_ += static_cast<uint64_t>(cycles);
}

void GBACore::RebuildGamePakWaitstateTables(uint16_t waitcnt) {
  static const uint8_t GBA_BASE_WAITSTATES[16] = { 0, 0, 3, 1, 0, 1, 1, 1, 4, 4, 4, 4, 4, 4, 4, 1 };
  static const uint8_t GBA_BASE_WAITSTATES_32[16] = { 0, 0, 6, 1, 0, 2, 2, 1, 7, 7, 9, 9, 13, 13, 9, 1 };
  static const uint8_t GBA_BASE_WAITSTATES_SEQ[16] = { 0, 0, 3, 1, 0, 1, 1, 1, 2, 2, 4, 4, 8, 8, 4, 1 };
  static const uint8_t GBA_BASE_WAITSTATES_SEQ_32[16] = { 0, 0, 6, 1, 0, 1, 1, 1, 5, 5, 9, 9, 17, 17, 9, 1 };

  for (int i = 0; i < 16; ++i) {
    ws_n16_[i] = GBA_BASE_WAITSTATES[i];
    ws_s16_[i] = GBA_BASE_WAITSTATES_SEQ[i];
    ws_n32_[i] = GBA_BASE_WAITSTATES_32[i];
    ws_s32_[i] = GBA_BASE_WAITSTATES_SEQ_32[i];
  }

  static const uint8_t GBA_ROM_WAITSTATES[] = { 4, 3, 2, 8 };
  static const uint8_t GBA_ROM_WAITSTATES_SEQ0[] = { 2, 1 };
  static const uint8_t GBA_ROM_WAITSTATES_SEQ1[] = { 4, 1 };
  static const uint8_t GBA_ROM_WAITSTATES_SEQ2[] = { 8, 1 };

  const uint8_t n0 = GBA_ROM_WAITSTATES[(waitcnt >> 2) & 3];
  const uint8_t n1 = GBA_ROM_WAITSTATES[(waitcnt >> 5) & 3];
  const uint8_t n2 = GBA_ROM_WAITSTATES[(waitcnt >> 8) & 3];
  const uint8_t s0 = GBA_ROM_WAITSTATES_SEQ0[(waitcnt >> 4) & 1];
  const uint8_t s1 = GBA_ROM_WAITSTATES_SEQ1[(waitcnt >> 7) & 1];
  const uint8_t s2 = GBA_ROM_WAITSTATES_SEQ2[(waitcnt >> 10) & 1];

  ws_n16_[0x08] = ws_n16_[0x09] = n0;
  ws_n16_[0x0A] = ws_n16_[0x0B] = n1;
  ws_n16_[0x0C] = ws_n16_[0x0D] = n2;
  ws_s16_[0x08] = ws_s16_[0x09] = s0;
  ws_s16_[0x0A] = ws_s16_[0x0B] = s1;
  ws_s16_[0x0C] = ws_s16_[0x0D] = s2;
  ws_n32_[0x08] = ws_n32_[0x09] = (uint8_t)(n0 + s0);
  ws_n32_[0x0A] = ws_n32_[0x0B] = (uint8_t)(n1 + s1);
  ws_n32_[0x0C] = ws_n32_[0x0D] = (uint8_t)(n2 + s2);
  ws_s32_[0x08] = ws_s32_[0x09] = (uint8_t)(s0 * 2);
  ws_s32_[0x0A] = ws_s32_[0x0B] = (uint8_t)(s1 * 2);
  ws_s32_[0x0C] = ws_s32_[0x0D] = (uint8_t)(s2 * 2);

  gamepak_prefetch_enabled_ = (waitcnt & (1u << 14)) != 0u;
}

void GBACore::UpdateOpenBus(uint32_t addr, uint32_t val, int size) const {
  if (addr < 0x02000000u) return;
  if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u && addr <= 0x0DFFFFFFu) {
    open_bus_latch_ = (open_bus_latch_ & ~1u) | (val & 1u);
    return;
  }
  if (size == 4) { open_bus_latch_ = val; }
  else if (size == 2) {
    const uint32_t sh = (addr & 2u) * 8u, m = 0xFFFFu << sh;
    open_bus_latch_ = (open_bus_latch_ & ~m) | ((val << sh) & m);
  } else {
    const uint32_t sh = (addr & 3u) * 8u, m = 0xFFu << sh;
    open_bus_latch_ = (open_bus_latch_ & ~m) | ((val << sh) & m);
  }
}

uint32_t GBACore::ReadBus32(uint32_t a) const {
  a &= ~3u;
  if (a < 0x00004000u) {
    if (bios_loaded_ && cpu_.regs[15] < 0x00004000u) {
      if (a + 3u < bios_.size()) {
          const uint32_t val = static_cast<uint32_t>(bios_[a]) | (static_cast<uint32_t>(bios_[a+1]) << 8) | (static_cast<uint32_t>(bios_[a+2]) << 16) | (static_cast<uint32_t>(bios_[a+3]) << 24);
          bios_fetch_latch_ = val; bios_data_latch_ = val; return val;
      }
    }
    return bios_fetch_latch_;
  }
  if (a >= 0x02000000u && a <= 0x02FFFFFFu) return Read32Wrap(ewram_.data(), a & 0x3FFFFu, ewram_.size());
  if (a >= 0x03000000u && a <= 0x03FFFFFFu) return Read32Wrap(iwram_.data(), a & 0x7FFFu, iwram_.size());
  if (a >= 0x04000000u && a <= 0x040003FCu) {
    return static_cast<uint32_t>(ReadIO16(a)) | (static_cast<uint32_t>(ReadIO16(a + 2u)) << 16);
  }
  if (a >= 0x05000000u && a <= 0x05FFFFFFu) return Read32Wrap(palette_ram_.data(), a & 0x3FFu, palette_ram_.size());
  if (a >= 0x06000000u && a <= 0x06FFFFFFu) return Read32Vram(vram_, a);
  if (a >= 0x07000000u && a <= 0x07FFFFFFu) return Read32Wrap(oam_.data(), a & 0x3FFu, oam_.size());
  if (a >= 0x08000000u && a <= 0x0DFFFFFFu) {
    const size_t base = static_cast<size_t>((a - 0x08000000u) & 0x01FFFFFFu);
    auto rb = [&](size_t o) -> uint8_t { return (o < rom_.size()) ? rom_[o] : 0u; };
    return rb(base)|(static_cast<uint32_t>(rb(base+1))<<8)|(static_cast<uint32_t>(rb(base+2))<<16)|(static_cast<uint32_t>(rb(base+3))<<24);
  }
  if (a >= 0x0E000000u) return static_cast<uint32_t>(ReadBackup8(a)) | (static_cast<uint32_t>(ReadBackup8(a+1u))<<8) | (static_cast<uint32_t>(ReadBackup8(a+2u))<<16) | (static_cast<uint32_t>(ReadBackup8(a+3u))<<24);
  return open_bus_latch_;
}

uint32_t GBACore::Read32(uint32_t addr) const {
  AddWaitstates(addr, 4, false);
  const uint32_t pc = cpu_.regs[15];
  if (addr < 0x00004000u && pc >= 0x00004000u) {
    const uint32_t rot = (addr & 3u) * 8u;
    const uint32_t v = rot ? ((bios_fetch_latch_ >> rot) | (bios_fetch_latch_ << (32u - rot))) : bios_fetch_latch_;
    UpdateOpenBus(addr, v, 4); return v;
  }
  uint32_t v = ReadBus32(addr & ~3u);
  const uint32_t rot = (addr & 3u) * 8u;
  if (rot) v = (v >> rot) | (v << (32u - rot));
  UpdateOpenBus(addr, v, 4); return v;
}

uint16_t GBACore::Read16(uint32_t addr) const {
  AddWaitstates(addr, 2, false);
  const uint32_t pc = cpu_.regs[15];
  if (addr < 0x00004000u && pc >= 0x00004000u) {
    const uint16_t val = static_cast<uint16_t>(bios_fetch_latch_ >> ((addr & 2u) * 8u));
    UpdateOpenBus(addr, val, 2); return val;
  }
  const uint32_t a2 = addr & ~1u;
  const uint32_t v32 = ReadBus32(a2 & ~2u);
  uint16_t val = static_cast<uint16_t>(v32 >> ((a2 & 2u)*8u));
  UpdateOpenBus(addr, val, 2);
  if (addr & 1u) val = (val >> 8) | (val << 8);
  return val;
}

uint8_t GBACore::Read8(uint32_t addr) const {
  AddWaitstates(addr, 1, false);
  const uint32_t pc = cpu_.regs[15];
  if (addr < 0x00004000u && pc >= 0x00004000u) {
    const uint8_t val = static_cast<uint8_t>(bios_fetch_latch_ >> ((addr & 3u) * 8u));
    UpdateOpenBus(addr, val, 1); return val;
  }
  const uint32_t v32 = ReadBus32(addr & ~3u);
  const uint8_t val = static_cast<uint8_t>(v32 >> ((addr & 3u)*8u));
  UpdateOpenBus(addr, val, 1); return val;
}

void GBACore::Write32(uint32_t addr, uint32_t value) {
  AddWaitstates(addr, 4, true);
  if (addr == 0x040000A0u) { PushAudioFifo(true,  value); return; }
  if (addr == 0x040000A4u) { PushAudioFifo(false, value); return; }
  UpdateOpenBus(addr, value, 4);
  const uint32_t a = addr & ~3u;
  if (a >= 0x02000000u && a <= 0x02FFFFFFu) { Write32Wrap(ewram_.data(), a & 0x3FFFFu, ewram_.size(), value); return; }
  if (a >= 0x03000000u && a <= 0x03FFFFFFu) { Write32Wrap(iwram_.data(), a & 0x7FFFu, iwram_.size(), value); return; }
  if (a >= 0x05000000u && a <= 0x05FFFFFFu) { Write32Wrap(palette_ram_.data(), a & 0x3FFu, palette_ram_.size(), value); return; }
  if (a >= 0x06000000u && a <= 0x06FFFFFFu) { Write32Vram(vram_, a, value); return; }
  if (a >= 0x07000000u && a <= 0x07FFFFFFu) { Write32Wrap(oam_.data(), a & 0x3FFu, oam_.size(), value); return; }
  if (a >= 0x0E000000u) { WriteBackup8(a, (uint8_t)(value & 0xFF)); WriteBackup8(a+1, (uint8_t)((value>>8)&0xFF)); WriteBackup8(a+2, (uint8_t)((value>>16)&0xFF)); WriteBackup8(a+3, (uint8_t)((value>>24)&0xFF)); }
}

void GBACore::Write16(uint32_t addr, uint16_t value) {
  AddWaitstates(addr, 2, true);
  UpdateOpenBus(addr, static_cast<uint32_t>(value)*0x00010001u, 2);
  const uint32_t a = addr & ~1u;
  if (a >= 0x04000000u && a <= 0x040003FEu) { WriteIO16(a, value); return; }
  if (a >= 0x05000000u && a <= 0x05FFFFFFu) { Write16Wrap(palette_ram_.data(), a & 0x3FFu, palette_ram_.size(), value); return; }
  if (a >= 0x06000000u && a <= 0x06FFFFFFu) {
      uint32_t voff = VramOffset(a);
      vram_[voff] = (uint8_t)(value & 0xFF); vram_[voff+1] = (uint8_t)((value>>8)&0xFF);
      return;
  }
  if (a >= 0x07000000u && a <= 0x07FFFFFFu) { Write16Wrap(oam_.data(), a & 0x3FFu, oam_.size(), value); return; }
  if (a >= 0x02000000u && a <= 0x02FFFFFFu) { Write16Wrap(ewram_.data(), a & 0x3FFFFu, ewram_.size(), value); return; }
  if (a >= 0x03000000u && a <= 0x03FFFFFFu) { Write16Wrap(iwram_.data(), a & 0x7FFFu, iwram_.size(), value); return; }
  if (a >= 0x0E000000u) { WriteBackup8(a, (uint8_t)(value & 0xFF)); WriteBackup8(a+1u, (uint8_t)((value>>8) & 0xFFu)); }
}

void GBACore::Write8(uint32_t addr, uint8_t value) {
  AddWaitstates(addr, 1, true);
  UpdateOpenBus(addr, static_cast<uint32_t>(value)*0x01010101u, 1);
  if (addr == 0x04000301u) {
    const size_t postflg_off = static_cast<size_t>(0x04000300u - 0x04000000u);
    if (postflg_off < io_regs_.size() && io_regs_[postflg_off] != 0u) { if ((value & 0x80u) == 0u) cpu_.halted = true; }
    return;
  }
  if (addr >= 0x04000000u && addr <= 0x040003FFu) {
    const uint32_t a16 = addr & ~1u; const size_t off = static_cast<size_t>(a16 - 0x04000000u);
    const uint16_t old = static_cast<uint16_t>(io_regs_[off]) | (static_cast<uint16_t>(io_regs_[off + 1u]) << 8);
    if (addr & 1u) WriteIO16(a16, (old & 0x00FFu)|(static_cast<uint16_t>(value)<<8));
    else WriteIO16(a16, (old & 0xFF00u)|value);
    return;
  }
  if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    const uint16_t v16 = (uint16_t)value | ((uint16_t)value << 8);
    Write16Wrap(palette_ram_.data(), (addr & ~1u) & 0x3FFu, palette_ram_.size(), v16); return;
  }
  if (addr >= 0x06000000u && addr <= 0x06FFFFFFu) {
    const uint32_t a16 = addr & ~1u; const uint32_t voff = VramOffset(a16);
    const uint16_t dispcnt = ReadIO16(0x04000000u);
    const uint8_t bg_mode = dispcnt & 7;
    uint32_t limit = (bg_mode >= 3) ? 0x14000u : 0x10000u;
    if (voff < limit) {
      const uint16_t v16 = (uint16_t)value | ((uint16_t)value << 8);
      vram_[voff] = (uint8_t)(v16 & 0xFF); vram_[voff+1] = (uint8_t)(v16 >> 8);
    }
    return;
  }
  if (addr >= 0x07000000u && addr <= 0x07FFFFFFu) return;
  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) { ewram_[(addr & 0x3FFFFu) % ewram_.size()] = value; return; }
  if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) { iwram_[(addr & 0x7FFFu) % iwram_.size()] = value; return; }
  if (addr >= 0x0E000000u) { WriteBackup8(addr, value); return; }
}

uint16_t GBACore::ReadIO16(uint32_t addr) const {
  addr &= ~1u; if (addr < 0x04000000u || addr > 0x040003FEu) return 0;
  const size_t off = static_cast<size_t>(addr - 0x04000000u);
  if (off + 1u >= io_regs_.size()) return 0;
  uint16_t val = (uint16_t)io_regs_[off] | ((uint16_t)io_regs_[off+1] << 8);
  switch (addr) {
    case 0x04000006u: val &= 0x00FFu; break;
    case 0x04000130u: val |= 0xFC00u; break;
    case 0x04000136u: val &= 0xC1FFu; break;
    case 0x04000208u: val &= 0x0001u; break;
    case 0x04000084u: val &= 0x008Fu; break;
    case 0x040000A0u: case 0x040000A2u: case 0x040000A4u: case 0x040000A6u: return 0;
    default: break;
  }
  return val;
}

void GBACore::WriteIO16(uint32_t addr, uint16_t value) {
  addr &= ~1u; if (addr < 0x04000000u || addr > 0x040003FEu) return;
  const size_t off = static_cast<size_t>(addr - 0x04000000u);
  if (off + 1u >= io_regs_.size()) return;
  switch (addr) {
    case 0x04000000u: value &= 0xFFF7u; break;
    case 0x04000004u: { uint16_t ro = (uint16_t)io_regs_[off] & 0x07u; value = (value & 0xFF38u) | ro; uint16_t lyc = (value >> 8) & 0xFFu, vc = ReadIO16(0x04000006u); if (vc == lyc) value |= 0x0004u; else value &= ~0x0004u; break; }
    case 0x04000006u: return;
    case 0x04000128u: { value &= 0x7FFFu; uint16_t old = ReadIO16(0x04000128u); UpdateSioMode(); io_regs_[off] = (uint8_t)(value & 0xFF); io_regs_[off+1] = (uint8_t)(value >> 8); UpdateSioMode(); if (!(old & 0x0080u) && (value & 0x0080u)) StartSioTransfer(value); return; }
    case 0x04000134u: value &= 0xC1FFu; sio_.transfer_active = false; sio_.transfer_cycles_remaining = 0; break;
    case 0x04000140u: value &= 0x004Fu; break;
    case 0x04000158u: { uint16_t old = ReadIO16(0x04000158u); value = (uint16_t)((old & ~0x0030u) | (value & 0x0030u)); break; }
    case 0x04000202u: { uint16_t old = (uint16_t)io_regs_[off] | ((uint16_t)io_regs_[off+1] << 8); value = old & ~value; break; }
    case 0x04000200u: value &= 0x3FFFu; break;
    case 0x04000208u: value &= 0x0001u; break;
    case 0x04000130u: return;
    case 0x04000132u: value &= 0xC3FFu; break;
    case 0x040000BAu: case 0x040000C6u: case 0x040000D2u: case 0x040000DEu: { int ch = (addr == 0x040000BAu) ? 0 : (addr == 0x040000C6u) ? 1 : (addr == 0x040000D2u) ? 2 : 3; uint16_t old = (uint16_t)io_regs_[off] | ((uint16_t)io_regs_[off+1] << 8); value &= (ch == 3) ? 0xFFE0u : 0xF7E0u; if (!(old & 0x8000u) && (value & 0x8000u)) ScheduleDmaStart(ch, value); break; }
    case 0x04000100u: case 0x04000104u: case 0x04000108u: case 0x0400010Cu: { int i = (addr-0x100)/4; timers_[i].reload=value; if(!(timers_[i].control&0x80u)){timers_[i].counter=value; io_regs_[off]=value&0xFF; io_regs_[off+1]=value>>8;} break; }
    case 0x04000102u: case 0x04000106u: case 0x0400010Au: case 0x0400010Eu: { int i = (addr-0x102)/4; uint16_t old=timers_[i].control; timers_[i].control=value&0x00C7u; if(!(old&0x80u)&&(value&0x80u)){timers_[i].counter=timers_[i].reload;timers_[i].prescaler_accum=0;} break; }
    case 0x04000204u: value &= 0x5FFFu; RebuildGamePakWaitstateTables(value); break;
    case 0x04000088u: value &= 0xC3FEu; break;
    case 0x040000A0u: case 0x040000A2u: case 0x040000A4u: case 0x040000A6u: return;
    default: break;
  }
  io_regs_[off] = (uint8_t)(value & 0xFF); io_regs_[off+1] = (uint8_t)(value >> 8);
  if (addr == 0x04000134u) UpdateSioMode();
}

}  // namespace gba
