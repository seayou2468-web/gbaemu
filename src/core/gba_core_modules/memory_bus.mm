#include "../gba_core.h"

namespace gba {
namespace {

// VRAMミラーリング: 96KB空間の0x18000以上は0x10000-0x17FFFへミラー
inline uint32_t VramOffset(uint32_t addr) {
  uint32_t off = (addr - 0x06000000u) & 0x1FFFFu;
  if (off >= 0x18000u) off -= 0x8000u;
  return off;
}

inline uint32_t Read32Wrap(const uint8_t* buf, uint32_t off, size_t size) {
  const size_t o = static_cast<size_t>(off) % size;
  return static_cast<uint32_t>(buf[o]) |
         (static_cast<uint32_t>(buf[(o+1)%size]) << 8) |
         (static_cast<uint32_t>(buf[(o+2)%size]) << 16) |
         (static_cast<uint32_t>(buf[(o+3)%size]) << 24);
}

inline void Write16Wrap(uint8_t* buf, uint32_t off, size_t size, uint16_t v) {
  const size_t o = static_cast<size_t>(off) % size;
  buf[o]         = static_cast<uint8_t>(v & 0xFFu);
  buf[(o+1)%size] = static_cast<uint8_t>((v >> 8) & 0xFFu);
}

inline void Write32Wrap(uint8_t* buf, uint32_t off, size_t size, uint32_t v) {
  const size_t o = static_cast<size_t>(off) % size;
  buf[o]         = static_cast<uint8_t>(v & 0xFFu);
  buf[(o+1)%size] = static_cast<uint8_t>((v >> 8) & 0xFFu);
  buf[(o+2)%size] = static_cast<uint8_t>((v >> 16) & 0xFFu);
  buf[(o+3)%size] = static_cast<uint8_t>((v >> 24) & 0xFFu);
}

inline uint32_t Read32Vram(const std::array<uint8_t, 96 * 1024>& vram, uint32_t addr) {
  return static_cast<uint32_t>(vram[VramOffset(addr)]) |
         (static_cast<uint32_t>(vram[VramOffset(addr + 1u)]) << 8) |
         (static_cast<uint32_t>(vram[VramOffset(addr + 2u)]) << 16) |
         (static_cast<uint32_t>(vram[VramOffset(addr + 3u)]) << 24);
}

inline void Write16Vram(std::array<uint8_t, 96 * 1024>& vram, uint32_t addr, uint16_t v) {
  vram[VramOffset(addr)] = static_cast<uint8_t>(v & 0xFFu);
  vram[VramOffset(addr + 1u)] = static_cast<uint8_t>((v >> 8) & 0xFFu);
}

inline void Write32Vram(std::array<uint8_t, 96 * 1024>& vram, uint32_t addr, uint32_t v) {
  vram[VramOffset(addr)] = static_cast<uint8_t>(v & 0xFFu);
  vram[VramOffset(addr + 1u)] = static_cast<uint8_t>((v >> 8) & 0xFFu);
  vram[VramOffset(addr + 2u)] = static_cast<uint8_t>((v >> 16) & 0xFFu);
  vram[VramOffset(addr + 3u)] = static_cast<uint8_t>((v >> 24) & 0xFFu);
}

inline bool IsWriteOnlyIo16(uint32_t addr) {
  addr &= ~1u;
  // BG scroll/affine parameters and refs (write-only)
  if (addr >= 0x04000010u && addr <= 0x0400001Eu) return true;
  if (addr >= 0x04000020u && addr <= 0x0400003Eu) return true;
  // MOSAIC
  if (addr == 0x0400004Cu) return true;
  // Sound FIFO write ports
  if (addr == 0x040000A0u || addr == 0x040000A2u ||
      addr == 0x040000A4u || addr == 0x040000A6u) return true;
  // DMA SAD/DAD/CNT_L are write-only. CNT_H is readable.
  if (addr >= 0x040000B0u && addr <= 0x040000DEu) {
    if (addr == 0x040000BAu || addr == 0x040000C6u ||
        addr == 0x040000D2u || addr == 0x040000DEu) {
      return false;  // DMAxCNT_H
    }
    return true;
  }
  return false;
}

}  // namespace

// =========================================================================
// ウェイトステート (GBATek準拠)
// =========================================================================
void GBACore::AddWaitstates(uint32_t addr, int size, bool is_write) const {
  const uint32_t region = addr >> 24;
  const uint32_t aligned_addr = (size == 4) ? (addr & ~3u) : (addr & ~1u);
  const bool seq =
  last_access_valid_ &&
  (region >= 0x08 && region <= 0x0D) &&
  ((last_access_addr_ >> 24) == region) &&
  (aligned_addr == (last_access_addr_ + last_access_size_));
  last_access_addr_ = aligned_addr;
  last_access_size_ = static_cast<uint8_t>(size);
  last_access_valid_ = true;
  int cycles = 1;
  switch (region) {
    case 0x00: cycles = 1; break;
    case 0x02: cycles = (size == 4) ? 6 : 3; break;
    case 0x03: cycles = 1; break;
    case 0x04: cycles = 1; break;
    case 0x05: cycles = (size == 4) ? 2 : 1; break;
    case 0x06: cycles = (size == 4) ? 2 : 1; break;
    case 0x07: cycles = 1; break;
    case 0x08: case 0x09: case 0x0A: case 0x0B: case 0x0C: case 0x0D: {
      const uint32_t ws_sel = std::min(((addr >> 25) & 3u), 2u); // 0=WS0,1=WS1,2=WS2
      if (size == 4) {
        cycles = seq ? ws_seq_32_[ws_sel] : ws_nonseq_32_[ws_sel];
      } else {
        cycles = seq ? ws_seq_16_[ws_sel] : ws_nonseq_16_[ws_sel];
      }
      if (!is_write && gamepak_prefetch_enabled_ && seq && cycles > 1) {
        --cycles;
      }
      break;
    }
    case 0x0E: case 0x0F: cycles = 5; break;
    default: cycles = 1; break;
  }
  waitstates_accum_ += static_cast<uint64_t>(cycles);
}

void GBACore::RebuildGamePakWaitstateTables(uint16_t waitcnt) {
  static constexpr uint8_t kNonSeq[4] = {4, 3, 2, 8};
  static constexpr uint8_t kSeq0[2] = {2, 1};
  static constexpr uint8_t kSeq1[2] = {4, 1};
  static constexpr uint8_t kSeq2[2] = {8, 1};

  const uint8_t n0 = kNonSeq[(waitcnt >> 2) & 0x3u];
  const uint8_t n1 = kNonSeq[(waitcnt >> 5) & 0x3u];
  const uint8_t n2 = kNonSeq[(waitcnt >> 8) & 0x3u];
  const uint8_t s0 = kSeq0[(waitcnt >> 4) & 0x1u];
  const uint8_t s1 = kSeq1[(waitcnt >> 7) & 0x1u];
  const uint8_t s2 = kSeq2[(waitcnt >> 10) & 0x1u];

  ws_nonseq_16_[0] = n0;
  ws_nonseq_16_[1] = n1;
  ws_nonseq_16_[2] = n2;
  ws_seq_16_[0] = s0;
  ws_seq_16_[1] = s1;
  ws_seq_16_[2] = s2;

  ws_nonseq_32_[0] = static_cast<uint8_t>(n0 + s0);
  ws_nonseq_32_[1] = static_cast<uint8_t>(n1 + s1);
  ws_nonseq_32_[2] = static_cast<uint8_t>(n2 + s2);
  ws_seq_32_[0] = static_cast<uint8_t>(s0 * 2u);
  ws_seq_32_[1] = static_cast<uint8_t>(s1 * 2u);
  ws_seq_32_[2] = static_cast<uint8_t>(s2 * 2u);
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

// =========================================================================
// 低レベルバス読み取り (4byteアライメント済み)
// =========================================================================
uint32_t GBACore::ReadBus32(uint32_t a) const {
  a &= ~3u;

  // BIOS
  if (a < 0x00004000u) {
    if (bios_loaded_ && cpu_.regs[15] < 0x00004000u && a + 3u < bios_.size()) {
      const uint32_t val = static_cast<uint32_t>(bios_[a]) |
          (static_cast<uint32_t>(bios_[a+1])<<8) |
          (static_cast<uint32_t>(bios_[a+2])<<16) |
          (static_cast<uint32_t>(bios_[a+3])<<24);
      bios_fetch_latch_ = val;
      bios_data_latch_  = val;
      return val;
    }
    return bios_fetch_latch_;
  }

  if (a >= 0x02000000u && a <= 0x02FFFFFFu)
    return Read32Wrap(ewram_.data(), a & 0x3FFFFu, ewram_.size());
  if (a >= 0x03000000u && a <= 0x03FFFFFFu)
    return Read32Wrap(iwram_.data(), a & 0x7FFFu, iwram_.size());
  if (a >= 0x04000000u && a <= 0x040003FCu)
    {
      auto read_io_cpu = [&](uint32_t ra) -> uint16_t {
        const uint16_t v = ReadIO16(ra);
        if (!IsWriteOnlyIo16(ra)) return v;
        const uint32_t sh = (ra & 2u) ? 16u : 0u;
        return static_cast<uint16_t>((open_bus_latch_ >> sh) & 0xFFFFu);
      };
      return static_cast<uint32_t>(read_io_cpu(a)) |
             (static_cast<uint32_t>(read_io_cpu(a+2u))<<16);
    }
  if (a >= 0x04000400u && a < 0x05000000u) return open_bus_latch_;

  // Palette / VRAM / OAM : 常時アクセス可能 (GBATek仕様)
  if (a >= 0x05000000u && a <= 0x05FFFFFFu)
    return Read32Wrap(palette_ram_.data(), a & 0x3FFu, palette_ram_.size());
  if (a >= 0x06000000u && a <= 0x06FFFFFFu)
    return Read32Vram(vram_, a);
  if (a >= 0x07000000u && a <= 0x07FFFFFFu)
    return Read32Wrap(oam_.data(), a & 0x3FFu, oam_.size());

  if (a >= 0x08000000u && a <= 0x0DFFFFFFu) {
    if (backup_type_ == BackupType::kEEPROM && a >= 0x0D000000u)
      return (open_bus_latch_ & ~1u) | (ReadBackup8(a) & 1u);
    if (!rom_.empty()) {
      const size_t base = static_cast<size_t>((a - 0x08000000u) & 0x01FFFFFFu);
      auto rb = [&](size_t o) -> uint8_t { return (o < rom_.size()) ? rom_[o] : 0u; };
      return rb(base)|(static_cast<uint32_t>(rb(base+1))<<8)|
             (static_cast<uint32_t>(rb(base+2))<<16)|(static_cast<uint32_t>(rb(base+3))<<24);
    }
    return open_bus_latch_;
  }
  if (a >= 0x0E000000u)
    return static_cast<uint32_t>(ReadBackup8(a)) | (static_cast<uint32_t>(ReadBackup8(a+1u))<<8) |
           (static_cast<uint32_t>(ReadBackup8(a+2u))<<16) | (static_cast<uint32_t>(ReadBackup8(a+3u))<<24);

  return open_bus_latch_;
}

uint32_t GBACore::Read32(uint32_t addr) const {
  AddWaitstates(addr, 4, false);
  if (addr < 0x00004000u && cpu_.regs[15] >= 0x00004000u) {
    const uint32_t rot = (addr & 3u) * 8u;
    const uint32_t v = rot ? ((bios_fetch_latch_ >> rot) | (bios_fetch_latch_ << (32u - rot)))
                           : bios_fetch_latch_;
    UpdateOpenBus(addr, v, 4);
    return v;
  }
  const uint32_t aligned = ReadBus32(addr & ~3u);
const uint32_t rot = (addr & 3u) * 8u;
const uint32_t v = rot ? ((aligned >> rot) | (aligned << (32u - rot))) : aligned;

UpdateOpenBus(addr, v, 4);
return v;
}

uint16_t GBACore::Read16(uint32_t addr) const {
  AddWaitstates(addr, 2, false);
  if (addr < 0x00004000u && cpu_.regs[15] >= 0x00004000u) {
    const uint16_t val = static_cast<uint16_t>(bios_fetch_latch_ >> ((addr & 2u) * 8u));
    UpdateOpenBus(addr, val, 2);
    return val;
  }
  const uint32_t a2 = addr & ~1u;
  const uint32_t v32 = ReadBus32(a2 & ~2u);
  const uint16_t val = static_cast<uint16_t>(v32 >> ((a2 & 2u)*8u));
  UpdateOpenBus(addr, val, 2);
  if (addr & 1u) return static_cast<uint16_t>((val>>8)|(val<<8));
  return val;
}

uint8_t GBACore::Read8(uint32_t addr) const {
  AddWaitstates(addr, 1, false);
  if (addr < 0x00004000u && cpu_.regs[15] >= 0x00004000u) {
    const uint8_t val = static_cast<uint8_t>(bios_fetch_latch_ >> ((addr & 3u) * 8u));
    UpdateOpenBus(addr, val, 1);
    return val;
  }
  const uint32_t v32 = ReadBus32(addr & ~3u);
  const uint8_t val = static_cast<uint8_t>(v32 >> ((addr & 3u)*8u));
UpdateOpenBus(addr, val, 1);
return val;
}

// =========================================================================
// 書き込み
// =========================================================================
void GBACore::Write32(uint32_t addr, uint32_t value) {
  AddWaitstates(addr, 4, true);
  if (addr == 0x040000A0u) { PushAudioFifo(true,  value); return; }
  if (addr == 0x040000A4u) { PushAudioFifo(false, value); return; }
  UpdateOpenBus(addr, value, 4);
  const uint32_t a = addr & ~3u;
  if (a >= 0x02000000u && a <= 0x02FFFFFFu) {
    Write32Wrap(ewram_.data(), a & 0x3FFFFu, ewram_.size(), value); return;
  }
  if (a >= 0x03000000u && a <= 0x03FFFFFFu) {
    Write32Wrap(iwram_.data(), a & 0x7FFFu, iwram_.size(), value); return;
  }
  if (a >= 0x05000000u && a <= 0x05FFFFFFu) {
    Write32Wrap(palette_ram_.data(), a & 0x3FFu, palette_ram_.size(), value); return;
  }
  if (a >= 0x06000000u && a <= 0x06FFFFFFu) {
    Write32Vram(vram_, a, value); return;
  }
  if (a >= 0x07000000u && a <= 0x07FFFFFFu) {
    Write32Wrap(oam_.data(), a & 0x3FFu, oam_.size(), value); return;
  }
  if (a >= 0x0E000000u) {
    WriteBackup8(a, static_cast<uint8_t>(value & 0xFFu));
    WriteBackup8(a + 1u, static_cast<uint8_t>((value >> 8) & 0xFFu));
    WriteBackup8(a + 2u, static_cast<uint8_t>((value >> 16) & 0xFFu));
    WriteBackup8(a + 3u, static_cast<uint8_t>((value >> 24) & 0xFFu));
    return;
  }
  Write16(a,      static_cast<uint16_t>(value & 0xFFFFu));
  Write16(a + 2u, static_cast<uint16_t>(value >> 16));
}

void GBACore::Write16(uint32_t addr, uint16_t value) {
  AddWaitstates(addr, 2, true);
  UpdateOpenBus(addr, static_cast<uint32_t>(value)|(static_cast<uint32_t>(value)<<16), 2);
  const uint32_t a = addr & ~1u;
  if (a >= 0x04000000u && a <= 0x040003FEu) { WriteIO16(a, value); return; }
  // Palette / VRAM / OAM 常時書き込み可能
  if (a >= 0x05000000u && a <= 0x05FFFFFFu) {
    Write16Wrap(palette_ram_.data(), a & 0x3FFu, palette_ram_.size(), value); return;
  }
  if (a >= 0x06000000u && a <= 0x06FFFFFFu) {
    Write16Vram(vram_, a, value); return;
  }
  if (a >= 0x07000000u && a <= 0x07FFFFFFu) {
    Write16Wrap(oam_.data(), a & 0x3FFu, oam_.size(), value); return;
  }
  if (a >= 0x02000000u && a <= 0x02FFFFFFu) {
    Write16Wrap(ewram_.data(), a & 0x3FFFFu, ewram_.size(), value); return;
  }
  if (a >= 0x03000000u && a <= 0x03FFFFFFu) {
    Write16Wrap(iwram_.data(), a & 0x7FFFu, iwram_.size(), value); return;
  }
  if (a >= 0x0E000000u) {
    WriteBackup8(a, static_cast<uint8_t>(value & 0xFFu));
    WriteBackup8(a+1u, static_cast<uint8_t>((value>>8) & 0xFFu));
    return;
  }
}

void GBACore::Write8(uint32_t addr, uint8_t value) {
  AddWaitstates(addr, 1, true);
  UpdateOpenBus(addr, static_cast<uint32_t>(value)*0x01010101u, 1);
  if (addr == 0x04000301u) {
    const size_t postflg_off = static_cast<size_t>(0x04000300u - 0x04000000u);
    if (postflg_off < io_regs_.size() && io_regs_[postflg_off] != 0u) {
      if ((value & 0x80u) == 0u) {
        cpu_.halted = true;
      }
    }
    return;
  }
  if (addr >= 0x04000000u && addr <= 0x040003FFu) {
    const uint32_t a16 = addr & ~1u;
    const size_t off = static_cast<size_t>(a16 - 0x04000000u);
    const uint16_t old = static_cast<uint16_t>(io_regs_[off]) |
                         (static_cast<uint16_t>(io_regs_[off + 1u]) << 8);
    if (addr & 1u) WriteIO16(a16, (old & 0x00FFu)|(static_cast<uint16_t>(value)<<8));
    else            WriteIO16(a16, (old & 0xFF00u)|value);
    return;
  }
  // Palette 8bit: 両バイト同値 (GBATek)
  if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    const uint16_t v16 = static_cast<uint16_t>(value)|(static_cast<uint16_t>(value)<<8);
    Write16Wrap(palette_ram_.data(), (addr & ~1u) & 0x3FFu, palette_ram_.size(), v16);
    return;
  }
  // VRAM 8bit: BGエリア(~0xFFFF)のみ有効
  if (addr >= 0x06000000u && addr <= 0x06FFFFFFu) {
    const uint32_t a16 = addr & ~1u;
    const uint32_t voff = VramOffset(a16);
    const uint16_t dispcnt = ReadIO16(0x04000000u);
    const uint8_t bg_mode = static_cast<uint8_t>(dispcnt & 0x7u);
    // In bitmap modes 3-5, BG bitmap area extends to 0x13FFF.
    uint32_t bg_byte_limit;
if (bg_mode >= 3 && bg_mode <= 5) {
  bg_byte_limit = 0x14000u;
} else {
  bg_byte_limit = 0x10000u;
}
    if (voff < bg_byte_limit) {
      // VRAM byte writes behave as mirrored halfword writes.
      const uint16_t v16 = static_cast<uint16_t>(value) |
                           (static_cast<uint16_t>(value) << 8);
      Write16Vram(vram_, a16, v16);
    }
    // OBJエリアへの8bit書き込みは無視
    return;
  }
  // OAM 8bit: 無視 (GBATek: OAMは16/32bitのみ)
  if (addr >= 0x07000000u && addr <= 0x07FFFFFFu) return;
  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) { ewram_[addr & 0x3FFFFu] = value; return; }
  if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) { iwram_[addr & 0x7FFFu]  = value; return; }
  if (addr >= 0x0E000000u) { WriteBackup8(addr, value); return; }
}

// =========================================================================
// I/O Read
// =========================================================================
uint16_t GBACore::ReadIO16(uint32_t addr) const {
  addr &= ~1u;
  if (addr < 0x04000000u || addr > 0x040003FEu) return 0;
  const size_t off = static_cast<size_t>(addr - 0x04000000u);
  if (off + 1u >= io_regs_.size()) return 0;
  uint16_t val = static_cast<uint16_t>(io_regs_[off]) |
                 (static_cast<uint16_t>(io_regs_[off+1]) << 8);
  switch (addr) {
    case 0x04000006u: val &= 0x00FFu; break;
    case 0x04000130u: val |= 0xFC00u; break;
    case 0x04000136u: val &= 0xC1FFu; break;  // RCNT
    case 0x04000208u: val &= 0x0001u; break;  // IME
    case 0x04000084u: val &= 0x008Fu; break;
    // 書き込み専用
    case 0x040000A0u: case 0x040000A2u:
    case 0x040000A4u: case 0x040000A6u: return 0;
    default: break;
  }
  return val;
}

// =========================================================================
// I/O Write (DMA CNT_H アドレス修正済み)
// =========================================================================
void GBACore::WriteIO16(uint32_t addr, uint16_t value) {
  addr &= ~1u;
  if (addr < 0x04000000u || addr > 0x040003FEu) return;
  const size_t off = static_cast<size_t>(addr - 0x04000000u);
  if (off + 1u >= io_regs_.size()) return;

  switch (addr) {
    case 0x04000000u: value &= 0xFFF7u; break; // DISPCNT

    case 0x04000004u: { // DISPSTAT
      const uint16_t ro = static_cast<uint16_t>(io_regs_[off] & 0x07u);
      value = (value & 0xFF38u) | ro;
      const uint16_t lyc = (value >> 8) & 0xFFu;
      const uint16_t vc  = ReadIO16(0x04000006u);
      if (vc == lyc) value |= 0x0004u; else value &= ~0x0004u;
      break;
    }
    case 0x04000006u: return; // VCOUNT R/O
    case 0x04000128u: { // SIOCNT
      value &= 0x7FFFu;
      const uint16_t old = ReadIO16(0x04000128u);
      UpdateSioMode();
      io_regs_[off] = static_cast<uint8_t>(value & 0xFFu);
      io_regs_[off+1] = static_cast<uint8_t>((value >> 8) & 0xFFu);
      UpdateSioMode();
      const bool start_edge = ((old & 0x0080u) == 0u) && ((value & 0x0080u) != 0u);
      if (start_edge) StartSioTransfer(value);
      return;
    }
    case 0x04000134u: // RCNT
      value &= 0xC1FFu;
      sio_.transfer_active = false;
      sio_.transfer_cycles_remaining = 0;
      break;
    case 0x04000140u: // JOYCNT
      value &= 0x004Fu;
      break;
    case 0x04000158u: { // JOYSTAT (partial writable bits)
      const uint16_t old = ReadIO16(0x04000158u);
      value = static_cast<uint16_t>((old & ~0x0030u) | (value & 0x0030u));
      break;
    }

    case 0x04000202u: { // IF: ビット書き込みでクリア
      const uint16_t old = static_cast<uint16_t>(io_regs_[off]) |
                           (static_cast<uint16_t>(io_regs_[off+1]) << 8);
      value = old & ~value;
      break;
    }
    case 0x04000200u: // IE
      value &= 0x3FFFu;
      break;
    case 0x04000208u: // IME
      value &= 0x0001u;
      break;
    case 0x04000130u: return; // KEYINPUT R/O
    case 0x04000132u: value &= 0xC3FFu; break; // KEYCNT

    // ----------------------------------------------------------------
    // DMA CNT_H レジスタ (正しいアドレス: BA/C6/D2/DE)
    // ----------------------------------------------------------------
    case 0x040000BAu: // DMA0CNT_H
    case 0x040000C6u: // DMA1CNT_H
    case 0x040000D2u: // DMA2CNT_H
    case 0x040000DEu: { // DMA3CNT_H
      int ch;
      if      (addr == 0x040000BAu) ch = 0;
      else if (addr == 0x040000C6u) ch = 1;
      else if (addr == 0x040000D2u) ch = 2;
      else                           ch = 3;

      const uint16_t old_cnt = static_cast<uint16_t>(io_regs_[off]) |
                               (static_cast<uint16_t>(io_regs_[off+1]) << 8);
      // ビットマスク (DMA0は送信元DEC禁止など)
      uint16_t mask = (ch == 3) ? 0xFFE0u : 0xF7E0u;
      value &= mask;
      if (ch == 0 && ((value >> 12) & 3u) == 3u) value &= ~(3u << 12);

      // 0→1遷移: シャドウレジスタ初期化
      if (!(old_cnt & 0x8000u) && (value & 0x8000u)) {
        // DMAレジスタベース (SAD/DAD/CNT_L は前に配置)
        // DMA0: B0=SAD, B4=DAD, B8=CNT_L, BA=CNT_H
        // DMA1: BC=SAD, C0=DAD, C4=CNT_L, C6=CNT_H
        uint32_t dma_base;
switch (ch) {
  case 0: dma_base = 0x040000B0u; break;
  case 1: dma_base = 0x040000BCu; break;
  case 2: dma_base = 0x040000C8u; break;
  case 3: dma_base = 0x040000D4u; break;
} // CNT_H - 10 = SAD
        const size_t boff = static_cast<size_t>(dma_base - 0x04000000u);
        auto read_raw32 = [&](size_t o) -> uint32_t {
          if (o + 3u >= io_regs_.size()) return 0;
          return static_cast<uint32_t>(io_regs_[o]) |
                 (static_cast<uint32_t>(io_regs_[o+1])<<8) |
                 (static_cast<uint32_t>(io_regs_[o+2])<<16) |
                 (static_cast<uint32_t>(io_regs_[o+3])<<24);
        };
        dma_shadows_[ch].sad          = read_raw32(boff);
        dma_shadows_[ch].initial_dad  = read_raw32(boff + 4u);
        dma_shadows_[ch].dad          = dma_shadows_[ch].initial_dad;
        uint32_t c = static_cast<uint32_t>(io_regs_[boff+8u]) |
                     (static_cast<uint32_t>(io_regs_[boff+9u]) << 8);
        if (c == 0) c = (ch == 3) ? 0x10000u : 0x4000u;
        dma_shadows_[ch].initial_count = c;
        dma_shadows_[ch].count         = c;
        dma_shadows_[ch].active        = true;
        dma_shadows_[ch].pending       = false;
        dma_shadows_[ch].startup_delay = 0;
        dma_shadows_[ch].in_progress   = false;
      } else if ((old_cnt & 0x8000u) && !(value & 0x8000u)) {
        dma_shadows_[ch].active        = false;
        dma_shadows_[ch].pending       = false;
        dma_shadows_[ch].startup_delay = 0;
        dma_shadows_[ch].in_progress   = false;
      }
      break;
    }

    // タイマーリロード値 (CNT_L)
    case 0x04000100u: timers_[0].reload=value; if(!(timers_[0].control&0x80u)){timers_[0].counter=value;io_regs_[0x100]=value&0xFF;io_regs_[0x101]=(value>>8)&0xFF;} break;
    case 0x04000104u: timers_[1].reload=value; if(!(timers_[1].control&0x80u)){timers_[1].counter=value;io_regs_[0x104]=value&0xFF;io_regs_[0x105]=(value>>8)&0xFF;} break;
    case 0x04000108u: timers_[2].reload=value; if(!(timers_[2].control&0x80u)){timers_[2].counter=value;io_regs_[0x108]=value&0xFF;io_regs_[0x109]=(value>>8)&0xFF;} break;
    case 0x0400010Cu: timers_[3].reload=value; if(!(timers_[3].control&0x80u)){timers_[3].counter=value;io_regs_[0x10C]=value&0xFF;io_regs_[0x10D]=(value>>8)&0xFF;} break;

    // タイマー制御 (CNT_H)
    case 0x04000102u: { const uint16_t old=timers_[0].control; timers_[0].control=value&0x00C7u; if(!(old&0x80u)&&(value&0x80u)){timers_[0].counter=timers_[0].reload;timers_[0].prescaler_accum=0;io_regs_[0x100]=timers_[0].reload&0xFF;io_regs_[0x101]=(timers_[0].reload>>8)&0xFF;} io_regs_[off]=timers_[0].control&0xFF;io_regs_[off+1]=(timers_[0].control>>8)&0xFF;return; }
    case 0x04000106u: { const uint16_t old=timers_[1].control; timers_[1].control=value&0x00C7u; if(!(old&0x80u)&&(value&0x80u)){timers_[1].counter=timers_[1].reload;timers_[1].prescaler_accum=0;io_regs_[0x104]=timers_[1].reload&0xFF;io_regs_[0x105]=(timers_[1].reload>>8)&0xFF;} io_regs_[off]=timers_[1].control&0xFF;io_regs_[off+1]=(timers_[1].control>>8)&0xFF;return; }
    case 0x0400010Au: { const uint16_t old=timers_[2].control; timers_[2].control=value&0x00C7u; if(!(old&0x80u)&&(value&0x80u)){timers_[2].counter=timers_[2].reload;timers_[2].prescaler_accum=0;io_regs_[0x108]=timers_[2].reload&0xFF;io_regs_[0x109]=(timers_[2].reload>>8)&0xFF;} io_regs_[off]=timers_[2].control&0xFF;io_regs_[off+1]=(timers_[2].control>>8)&0xFF;return; }
    case 0x0400010Eu: { const uint16_t old=timers_[3].control; timers_[3].control=value&0x00C7u; if(!(old&0x80u)&&(value&0x80u)){timers_[3].counter=timers_[3].reload;timers_[3].prescaler_accum=0;io_regs_[0x10C]=timers_[3].reload&0xFF;io_regs_[0x10D]=(timers_[3].reload>>8)&0xFF;} io_regs_[off]=timers_[3].control&0xFF;io_regs_[off+1]=(timers_[3].control>>8)&0xFF;return; }

    case 0x04000204u:
      value &= 0x5FFFu;
      RebuildGamePakWaitstateTables(value);
      break; // WAITCNT
    case 0x04000088u: value &= 0xC3FEu; break; // SOUNDBIAS
    // FIFO書き込みはWrite32で処理
    case 0x040000A0u: case 0x040000A2u: return;
    case 0x040000A4u: case 0x040000A6u: return;
    default: break;
  }

  io_regs_[off]   = static_cast<uint8_t>(value & 0xFFu);
  io_regs_[off+1] = static_cast<uint8_t>((value >> 8) & 0xFFu);

  if (addr == 0x04000134u) {
    UpdateSioMode();
  }

  // Tonc/GBATek: BG2/3X,Y reference registers written outside VBlank are
  // immediately reflected to the internal affine origin of the current line.
  if (addr >= 0x04000028u && addr <= 0x0400003Eu) {
    const bool is_affine_ref_reg =
        addr == 0x04000028u || addr == 0x0400002Au ||
        addr == 0x0400002Cu || addr == 0x0400002Eu ||
        addr == 0x04000038u || addr == 0x0400003Au ||
        addr == 0x0400003Cu || addr == 0x0400003Eu;
    if (is_affine_ref_reg) {
      auto read_ref28 = [&](uint32_t base) -> int32_t {
        const size_t ro = static_cast<size_t>(base - 0x04000000u);
        uint32_t raw = static_cast<uint32_t>(io_regs_[ro]) |
                       (static_cast<uint32_t>(io_regs_[ro + 1u]) << 8) |
                       (static_cast<uint32_t>(io_regs_[ro + 2u]) << 16) |
                       (static_cast<uint32_t>(io_regs_[ro + 3u]) << 24);
        raw &= 0x0FFFFFFFu;
        return static_cast<int32_t>(raw << 4) >> 4;
      };
      const uint16_t vcount = ReadIO16(0x04000006u);
      const bool in_vblank = (vcount >= 160u);
      if (!in_vblank) {
        bg2_refx_internal_ = read_ref28(0x04000028u);
        bg2_refy_internal_ = read_ref28(0x0400002Cu);
        bg3_refx_internal_ = read_ref28(0x04000038u);
        bg3_refy_internal_ = read_ref28(0x0400003Cu);
      }
    }
  }

  // DMA即時起動 (start_timing=0)
  if ((addr==0x040000BAu||addr==0x040000C6u||addr==0x040000D2u||addr==0x040000DEu)
      && (value & 0x8000u) && ((value >> 12) & 3u) == 0u) {
    int ch = static_cast<int>((addr - 0x040000BAu) / 0x0Cu);
    ScheduleDmaStart(ch, value);
  }
}

}  // namespace gba
