// memory_bus.mm - GBA Memory Bus Complete Implementation
#include "../gba_core.h"

namespace gba {
namespace {

// VRAMアドレスミラーリング: 0x18000以上は0x10000-0x17FFFへミラー
inline uint32_t VramOffset(uint32_t addr) {
  uint32_t off = (addr - 0x06000000u) & 0x1FFFFu;
  if (off >= 0x18000u) off -= 0x8000u;
  return off;
}

inline uint32_t Read32Wrap(const uint8_t* buf, uint32_t off, uint32_t /*mask*/, size_t size) {
  const size_t s = size;
  const size_t o = static_cast<size_t>(off) % s;
  return static_cast<uint32_t>(buf[o]) |
         (static_cast<uint32_t>(buf[(o+1)%s]) << 8) |
         (static_cast<uint32_t>(buf[(o+2)%s]) << 16) |
         (static_cast<uint32_t>(buf[(o+3)%s]) << 24);
}

inline void Write16Wrap(uint8_t* buf, uint32_t off, uint32_t /*mask*/, size_t size, uint16_t v) {
  const size_t s = size;
  const size_t o = static_cast<size_t>(off) % s;
  buf[o]       = static_cast<uint8_t>(v & 0xFFu);
  buf[(o+1)%s] = static_cast<uint8_t>((v >> 8) & 0xFFu);
}

}  // namespace

// ==========================================================================
// ウェイトステート (GBATek準拠)
// ==========================================================================
void GBACore::AddWaitstates(uint32_t addr, int size) const {
  const uint32_t region = addr >> 24;
  const bool seq = ((addr & ~3u) == (last_access_addr_ & ~3u)) && (addr >= last_access_addr_);
  last_access_addr_ = addr;
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
      const uint16_t wc = ReadIO16(0x04000204u);
      const int ws_idx = ((addr >> 25) & 1u) + ((addr >> 24) & 1u) * 2;  // 0=WS0,1=WS1,2=WS2
      static const int kN[3][4] = {{4,3,2,8},{4,3,2,8},{4,3,2,8}};
      static const int kS[3][2] = {{2,1},{4,1},{8,1}};
      int ni = 0, si = 0;
      if ((addr & 0x1E000000u) == 0x08000000u || (addr & 0x1E000000u) == 0x0A000000u) {
        // WS0
        ni = (wc >> 2) & 3; si = (wc >> 4) & 1;
        cycles = seq ? kS[0][si] : kN[0][ni];
      } else if ((addr & 0x1E000000u) == 0x0C000000u) {
        // WS1
        ni = (wc >> 5) & 3; si = (wc >> 7) & 1;
        cycles = seq ? kS[1][si] : kN[1][ni];
      } else {
        // WS2 (0x0D000000)
        ni = (wc >> 8) & 3; si = (wc >> 10) & 1;
        cycles = seq ? kS[2][si] : kN[2][ni];
      }
      if (size == 4) cycles += (seq ? kS[0][si] : kN[0][ni]);
      break;
    }
    case 0x0E: case 0x0F: cycles = (size == 4) ? 4 : (size == 2 ? 2 : 5); break;
    default: cycles = 1; break;
  }
  waitstates_accum_ += static_cast<uint64_t>(cycles);
}

// ==========================================================================
// Open Bus ラッチ更新
// ==========================================================================
void GBACore::UpdateOpenBus(uint32_t addr, uint32_t val, int size) const {
  if (addr < 0x02000000u) return;
  if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u && addr <= 0x0DFFFFFFu) {
    open_bus_latch_ = (open_bus_latch_ & ~1u) | (val & 1u);
    return;
  }
  if (size == 4) {
    open_bus_latch_ = val;
  } else if (size == 2) {
    const uint32_t sh = (addr & 2u) * 8u;
    const uint32_t m  = 0xFFFFu << sh;
    open_bus_latch_ = (open_bus_latch_ & ~m) | ((val << sh) & m);
  } else {
    const uint32_t sh = (addr & 3u) * 8u;
    const uint32_t m  = 0xFFu << sh;
    open_bus_latch_ = (open_bus_latch_ & ~m) | ((val << sh) & m);
  }
}

// ==========================================================================
// 低レベル32bitバス読み取り (4バイトアライメント済み)
// ==========================================================================
uint32_t GBACore::ReadBus32(uint32_t a) const {
  a &= ~3u;

  // BIOS (0x00000000-0x00003FFF)
  if (a < 0x00004000u) {
    if (bios_loaded_ && cpu_.regs[15] < 0x00004000u && a + 3u < bios_.size()) {
      const uint32_t val = static_cast<uint32_t>(bios_[a]) |
                           (static_cast<uint32_t>(bios_[a+1]) << 8) |
                           (static_cast<uint32_t>(bios_[a+2]) << 16) |
                           (static_cast<uint32_t>(bios_[a+3]) << 24);
      if (a == (cpu_.regs[15] & ~3u)) bios_fetch_latch_ = val;
      bios_data_latch_ = val;
      return val;
    }
    // PCがBIOS外: BIOSフェッチラッチを返す
    return bios_fetch_latch_;
  }

  // EWRAM (0x02000000-0x02FFFFFF)
  if (a >= 0x02000000u && a <= 0x02FFFFFFu)
    return Read32Wrap(ewram_.data(), a & 0x3FFFFu, 0x3FFFFu, ewram_.size());

  // IWRAM (0x03000000-0x03FFFFFF)
  if (a >= 0x03000000u && a <= 0x03FFFFFFu)
    return Read32Wrap(iwram_.data(), a & 0x7FFFu, 0x7FFFu, iwram_.size());

  // I/O Registers (0x04000000-0x040003FF)
  if (a >= 0x04000000u && a <= 0x040003FCu)
    return static_cast<uint32_t>(ReadIO16(a)) | (static_cast<uint32_t>(ReadIO16(a+2u)) << 16);
  if (a >= 0x04000400u && a < 0x05000000u)
    return open_bus_latch_;

  // Palette RAM (0x05000000-0x05FFFFFF) - 常に読み取り可能
  if (a >= 0x05000000u && a <= 0x05FFFFFFu)
    return Read32Wrap(palette_ram_.data(), a & 0x3FFu, 0x3FFu, palette_ram_.size());

  // VRAM (0x06000000-0x06FFFFFF) - 常に読み取り可能
  if (a >= 0x06000000u && a <= 0x06FFFFFFu)
    return Read32Wrap(vram_.data(), VramOffset(a), 0x1FFFFu, vram_.size());

  // OAM (0x07000000-0x07FFFFFF) - 常に読み取り可能
  if (a >= 0x07000000u && a <= 0x07FFFFFFu)
    return Read32Wrap(oam_.data(), a & 0x3FFu, 0x3FFu, oam_.size());

  // ROM / GamePak (0x08000000-0x0DFFFFFF)
  if (a >= 0x08000000u && a <= 0x0DFFFFFFu) {
    if (backup_type_ == BackupType::kEEPROM && a >= 0x0D000000u)
      return (open_bus_latch_ & ~1u) | (ReadBackup8(a) & 1u);
    if (!rom_.empty()) {
      const size_t base = static_cast<size_t>((a - 0x08000000u) & 0x01FFFFFFu);
      auto rb = [&](size_t o) -> uint8_t {
        return (o < rom_.size()) ? rom_[o] : 0u;
      };
      return rb(base) | (static_cast<uint32_t>(rb(base+1)) << 8) |
             (static_cast<uint32_t>(rb(base+2)) << 16) | (static_cast<uint32_t>(rb(base+3)) << 24);
    }
    return open_bus_latch_;
  }

  // SRAM / Flash (0x0E000000+)
  if (a >= 0x0E000000u) {
    return static_cast<uint32_t>(ReadBackup8(a)) |
           (static_cast<uint32_t>(ReadBackup8(a+1u)) << 8) |
           (static_cast<uint32_t>(ReadBackup8(a+2u)) << 16) |
           (static_cast<uint32_t>(ReadBackup8(a+3u)) << 24);
  }

  return open_bus_latch_;
}

// ==========================================================================
// パブリック読み取り
// ==========================================================================
uint32_t GBACore::Read32(uint32_t addr) const {
  AddWaitstates(addr, 4);
  if (addr < 0x00004000u && cpu_.regs[15] >= 0x00004000u)
    return bios_fetch_latch_;
  const uint32_t aligned = addr & ~3u;
  const uint32_t val = ReadBus32(aligned);
  UpdateOpenBus(aligned, val, 4);
  const uint32_t rot = (addr & 3u) * 8u;
  if (rot == 0) return val;
  return (val >> rot) | (val << (32u - rot));
}

uint16_t GBACore::Read16(uint32_t addr) const {
  AddWaitstates(addr, 2);
  if (addr < 0x00004000u && cpu_.regs[15] >= 0x00004000u)
    return static_cast<uint16_t>(bios_fetch_latch_ >> ((addr & 2u) * 8u));
  const uint32_t a2 = addr & ~1u;
  const uint32_t v32 = ReadBus32(a2 & ~2u);  // 4byte aligned
  const uint32_t sh  = (a2 & 2u) * 8u;
  const uint16_t val = static_cast<uint16_t>(v32 >> sh);
  UpdateOpenBus(a2, v32, 2);
  if (addr & 1u) return static_cast<uint16_t>((val >> 8) | (val << 8));
  return val;
}

uint8_t GBACore::Read8(uint32_t addr) const {
  AddWaitstates(addr, 1);
  if (addr < 0x00004000u && cpu_.regs[15] >= 0x00004000u)
    return static_cast<uint8_t>(bios_fetch_latch_ >> ((addr & 3u) * 8u));
  const uint32_t v32 = ReadBus32(addr & ~3u);
  UpdateOpenBus(addr & ~3u, v32, 1);
  return static_cast<uint8_t>(v32 >> ((addr & 3u) * 8u));
}

// ==========================================================================
// パブリック書き込み
// ==========================================================================
void GBACore::Write32(uint32_t addr, uint32_t value) {
  AddWaitstates(addr, 4);
  // Audio FIFO (特殊: 32bit書き込みで4バイトpush)
  if (addr == 0x040000A0u) { PushAudioFifo(true,  value); return; }
  if (addr == 0x040000A4u) { PushAudioFifo(false, value); return; }
  UpdateOpenBus(addr, value, 4);
  const uint32_t a = addr & ~3u;
  Write16(a,     static_cast<uint16_t>(value & 0xFFFFu));
  Write16(a + 2u, static_cast<uint16_t>(value >> 16));
}

void GBACore::Write16(uint32_t addr, uint16_t value) {
  AddWaitstates(addr, 2);
  UpdateOpenBus(addr, static_cast<uint32_t>(value) | (static_cast<uint32_t>(value) << 16), 2);
  const uint32_t a = addr & ~1u;

  if (a >= 0x04000000u && a <= 0x040003FEu) { WriteIO16(a, value); return; }

  // Palette RAM - 常に書き込み可能
  if (a >= 0x05000000u && a <= 0x05FFFFFFu) {
    Write16Wrap(palette_ram_.data(), a & 0x3FFu, 0x3FFu, palette_ram_.size(), value);
    return;
  }

  // VRAM - 常に書き込み可能
  if (a >= 0x06000000u && a <= 0x06FFFFFFu) {
    Write16Wrap(vram_.data(), VramOffset(a), 0x1FFFFu, vram_.size(), value);
    return;
  }

  // OAM - 常に書き込み可能
  if (a >= 0x07000000u && a <= 0x07FFFFFFu) {
    Write16Wrap(oam_.data(), a & 0x3FFu, 0x3FFu, oam_.size(), value);
    return;
  }

  // EWRAM
  if (a >= 0x02000000u && a <= 0x02FFFFFFu) {
    const size_t o = static_cast<size_t>(a & 0x3FFFFu);
    ewram_[o] = static_cast<uint8_t>(value & 0xFFu);
    ewram_[o+1] = static_cast<uint8_t>((value >> 8) & 0xFFu);
    return;
  }

  // IWRAM
  if (a >= 0x03000000u && a <= 0x03FFFFFFu) {
    const size_t o = static_cast<size_t>(a & 0x7FFFu);
    iwram_[o] = static_cast<uint8_t>(value & 0xFFu);
    iwram_[o+1] = static_cast<uint8_t>((value >> 8) & 0xFFu);
    return;
  }

  // SRAM / Flash
  if (a >= 0x0E000000u) {
    WriteBackup8(a,     static_cast<uint8_t>(value & 0xFFu));
    WriteBackup8(a + 1u, static_cast<uint8_t>((value >> 8) & 0xFFu));
    return;
  }
}

void GBACore::Write8(uint32_t addr, uint8_t value) {
  AddWaitstates(addr, 1);
  UpdateOpenBus(addr, static_cast<uint32_t>(value) * 0x01010101u, 1);

  // I/O (8bitはマージして16bit書き込み)
  if (addr >= 0x04000000u && addr <= 0x040003FFu) {
    const uint32_t a16 = addr & ~1u;
    const uint16_t old = ReadIO16(a16);
    if (addr & 1u) WriteIO16(a16, (old & 0x00FFu) | (static_cast<uint16_t>(value) << 8));
    else           WriteIO16(a16, (old & 0xFF00u) | value);
    return;
  }

  // Palette RAM: 8bit書き込みは両バイト同値 (GBATek 2.4.3)
  if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    const uint16_t v16 = static_cast<uint16_t>(value) | (static_cast<uint16_t>(value) << 8);
    Write16Wrap(palette_ram_.data(), (addr & ~1u) & 0x3FFu, 0x3FFu, palette_ram_.size(), v16);
    return;
  }

  // VRAM: BGエリア(0-0xFFFF)のみ8bit書き込み有効。両バイト同値
  // OBJエリア(0x10000-0x17FFF)への8bit書き込みは無視 (GBATek)
  if (addr >= 0x06000000u && addr <= 0x06FFFFFFu) {
    const uint32_t voff = VramOffset(addr);
    if (voff < 0x10000u) {  // BGエリアのみ
      const uint16_t v16 = static_cast<uint16_t>(value) | (static_cast<uint16_t>(value) << 8);
      Write16Wrap(vram_.data(), voff & ~1u, 0x1FFFFu, vram_.size(), v16);
    }
    return;
  }

  // OAM: 8bit書き込みは無視 (GBATek: OAMは16/32bitのみ)
  if (addr >= 0x07000000u && addr <= 0x07FFFFFFu) return;

  // EWRAM
  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) {
    ewram_[addr & 0x3FFFFu] = value;
    return;
  }

  // IWRAM
  if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) {
    iwram_[addr & 0x7FFFu] = value;
    return;
  }

  // SRAM / Flash
  if (addr >= 0x0E000000u) {
    WriteBackup8(addr, value);
    return;
  }
}

// ==========================================================================
// I/O レジスタ読み取り
// ==========================================================================
uint16_t GBACore::ReadIO16(uint32_t addr) const {
  addr &= ~1u;
  if (addr < 0x04000000u || addr > 0x040003FEu) return 0;
  const size_t off = static_cast<size_t>(addr - 0x04000000u);
  if (off + 1u >= io_regs_.size()) return 0;
  uint16_t val = static_cast<uint16_t>(io_regs_[off]) |
                 (static_cast<uint16_t>(io_regs_[off+1]) << 8);

  // 特殊レジスタマスク
  switch (addr) {
    case 0x04000004u: val &= 0xFFBFu; break;  // DISPSTATのbit6はRead-Only=0
    case 0x04000006u: val &= 0x00FFu; break;  // VCOUNT: 0-227
    case 0x04000130u: val |= 0xFC00u; break;  // KEYINPUT: 未使用ビット=1
    case 0x04000084u: val &= 0x008Fu; break;  // SOUNDCNT_X
    // 書き込み専用レジスタ
    case 0x040000A0u: case 0x040000A2u:
    case 0x040000A4u: case 0x040000A6u: return 0;
    default: break;
  }
  return val;
}

// ==========================================================================
// I/O レジスタ書き込み
// ==========================================================================
void GBACore::WriteIO16(uint32_t addr, uint16_t value) {
  addr &= ~1u;
  if (addr < 0x04000000u || addr > 0x040003FEu) return;
  const size_t off = static_cast<size_t>(addr - 0x04000000u);
  if (off + 1u >= io_regs_.size()) return;

  switch (addr) {
    case 0x04000000u:  // DISPCNT
      value &= 0xFFF7u;
      break;

    case 0x04000004u: {  // DISPSTAT
      // bit0/1/2はR/Oなので書き込み禁止 (bit3/4/5/8-15はR/W)
      const uint16_t ro = static_cast<uint16_t>(io_regs_[off] & 0x07u);
      value = (value & 0xFF38u) | ro;
      // VCountCompareビットを更新
      const uint16_t vcount = ReadIO16(0x04000006u);
      const uint16_t lyc    = (value >> 8) & 0xFFu;
      if (vcount == lyc) value |= 0x0004u; else value &= ~0x0004u;
      break;
    }

    case 0x04000006u:  // VCOUNT: 書き込み無効
      return;

    case 0x04000202u: {  // IF: 書いたビットをクリア
      const uint16_t old = static_cast<uint16_t>(io_regs_[off]) |
                           (static_cast<uint16_t>(io_regs_[off+1]) << 8);
      value = old & ~value;
      break;
    }

    case 0x04000130u:  // KEYINPUT: R/O
      return;

    // DMA制御
    case 0x040000B8u: case 0x040000C4u:
    case 0x040000D0u: case 0x040000DCu: {
      int ch;
      if      (addr == 0x040000B8u) ch = 0;
      else if (addr == 0x040000C4u) ch = 1;
      else if (addr == 0x040000D0u) ch = 2;
      else                          ch = 3;
      const uint16_t old_cnt = static_cast<uint16_t>(io_regs_[off]) |
                               (static_cast<uint16_t>(io_regs_[off+1]) << 8);
      const uint16_t mask = (ch == 3) ? 0xFFE0u : 0xF7E0u;
      value &= mask;
      if (ch == 0 && ((value >> 12) & 3u) == 3u) value &= ~(3u << 12);

      if (!(old_cnt & 0x8000u) && (value & 0x8000u)) {
        // DMA有効化: シャドウレジスタへラッチ
        auto read_io32 = [&](size_t o) -> uint32_t {
          if (o + 3 >= io_regs_.size()) return 0;
          return static_cast<uint32_t>(io_regs_[o]) |
                 (static_cast<uint32_t>(io_regs_[o+1]) << 8) |
                 (static_cast<uint32_t>(io_regs_[o+2]) << 16) |
                 (static_cast<uint32_t>(io_regs_[o+3]) << 24);
        };
        const size_t boff = static_cast<size_t>(0x040000B0u + ch*12 - 0x04000000u);
        dma_shadows_[ch].sad = read_io32(boff);
        dma_shadows_[ch].initial_dad = read_io32(boff + 4u);
        dma_shadows_[ch].dad = dma_shadows_[ch].initial_dad;
        uint32_t c = static_cast<uint32_t>(io_regs_[boff+8u]) |
                     (static_cast<uint32_t>(io_regs_[boff+9u]) << 8);
        if (c == 0) c = (ch == 3) ? 0x10000u : 0x4000u;
        dma_shadows_[ch].initial_count = c;
        dma_shadows_[ch].count = c;
        dma_shadows_[ch].active = true;
      }
      break;
    }

    // タイマーリロード値
    case 0x04000100u: timers_[0].reload = value; if (!(timers_[0].control & 0x80u)) { timers_[0].counter = value; io_regs_[0x100]=value&0xFF; io_regs_[0x101]=(value>>8)&0xFF; } break;
    case 0x04000104u: timers_[1].reload = value; if (!(timers_[1].control & 0x80u)) { timers_[1].counter = value; io_regs_[0x104]=value&0xFF; io_regs_[0x105]=(value>>8)&0xFF; } break;
    case 0x04000108u: timers_[2].reload = value; if (!(timers_[2].control & 0x80u)) { timers_[2].counter = value; io_regs_[0x108]=value&0xFF; io_regs_[0x109]=(value>>8)&0xFF; } break;
    case 0x0400010Cu: timers_[3].reload = value; if (!(timers_[3].control & 0x80u)) { timers_[3].counter = value; io_regs_[0x10C]=value&0xFF; io_regs_[0x10D]=(value>>8)&0xFF; } break;

    // タイマー制御
    case 0x04000102u: {
      const uint16_t old = timers_[0].control;
      timers_[0].control = value & 0x00C7u;
      if (!(old & 0x80u) && (value & 0x80u)) { timers_[0].counter = timers_[0].reload; timers_[0].prescaler_accum = 0; io_regs_[0x100]=timers_[0].reload&0xFF; io_regs_[0x101]=(timers_[0].reload>>8)&0xFF; }
      io_regs_[off]=timers_[0].control&0xFF; io_regs_[off+1]=(timers_[0].control>>8)&0xFF; return;
    }
    case 0x04000106u: {
      const uint16_t old = timers_[1].control;
      timers_[1].control = value & 0x00C7u;
      if (!(old & 0x80u) && (value & 0x80u)) { timers_[1].counter = timers_[1].reload; timers_[1].prescaler_accum = 0; io_regs_[0x104]=timers_[1].reload&0xFF; io_regs_[0x105]=(timers_[1].reload>>8)&0xFF; }
      io_regs_[off]=timers_[1].control&0xFF; io_regs_[off+1]=(timers_[1].control>>8)&0xFF; return;
    }
    case 0x0400010Au: {
      const uint16_t old = timers_[2].control;
      timers_[2].control = value & 0x00C7u;
      if (!(old & 0x80u) && (value & 0x80u)) { timers_[2].counter = timers_[2].reload; timers_[2].prescaler_accum = 0; io_regs_[0x108]=timers_[2].reload&0xFF; io_regs_[0x109]=(timers_[2].reload>>8)&0xFF; }
      io_regs_[off]=timers_[2].control&0xFF; io_regs_[off+1]=(timers_[2].control>>8)&0xFF; return;
    }
    case 0x0400010Eu: {
      const uint16_t old = timers_[3].control;
      timers_[3].control = value & 0x00C7u;
      if (!(old & 0x80u) && (value & 0x80u)) { timers_[3].counter = timers_[3].reload; timers_[3].prescaler_accum = 0; io_regs_[0x10C]=timers_[3].reload&0xFF; io_regs_[0x10D]=(timers_[3].reload>>8)&0xFF; }
      io_regs_[off]=timers_[3].control&0xFF; io_regs_[off+1]=(timers_[3].control>>8)&0xFF; return;
    }

    case 0x04000204u: value &= 0x5FFFu; break;  // WAITCNT
    case 0x04000088u: value &= 0xC3FEu; break;  // SOUNDBIAS

    // FIFO書き込み (Write32経由で別ハンドル)
    case 0x040000A0u: case 0x040000A2u: return;
    case 0x040000A4u: case 0x040000A6u: return;

    default: break;
  }

  io_regs_[off]   = static_cast<uint8_t>(value & 0xFFu);
  io_regs_[off+1] = static_cast<uint8_t>((value >> 8) & 0xFFu);

  // DMA即時起動 (start_timing=0)
  if ((addr==0x040000B8u||addr==0x040000C4u||addr==0x040000D0u||addr==0x040000DCu)
      && (value & 0x8000u) && ((value >> 12) & 3u) == 0u) {
    StepDma();
  }
}

}  // namespace gba
