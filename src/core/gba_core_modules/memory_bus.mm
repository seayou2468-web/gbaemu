#include "../gba_core.h"

#include <array>

namespace gba {

namespace {
constexpr uint32_t kRegionMask = 0x0F000000u;
constexpr uint32_t kAddrMask28 = 0x0FFFFFFFu;

constexpr std::array<uint8_t, 16> kBaseNonSeq16 = {0, 0, 2, 0, 0, 0, 0, 0, 4, 4, 4, 4, 4, 4, 4, 0};
constexpr std::array<uint8_t, 16> kBaseSeq16 = {0, 0, 2, 0, 0, 0, 0, 0, 2, 2, 4, 4, 8, 8, 4, 0};
constexpr std::array<uint8_t, 16> kBaseNonSeq32 = {0, 0, 5, 0, 0, 1, 1, 0, 7, 7, 9, 9, 13, 13, 9, 0};
constexpr std::array<uint8_t, 16> kBaseSeq32 = {0, 0, 5, 0, 0, 1, 1, 0, 5, 5, 9, 9, 17, 17, 9, 0};

inline uint8_t ReadArr(const std::array<uint8_t, 1024>& io, uint32_t o) { return io[o & 0x3FFu]; }
inline uint32_t MapVramOffset(uint32_t addr) {
  // GBA VRAM address decode:
  // 0x00000-0x17FFF: linear 96KB
  // 0x18000-0x1FFFF: mirrors 0x10000-0x17FFF (upper 32KB window)
  uint32_t off = addr & 0x1FFFFu;
  if (off >= 0x18000u) off = 0x10000u + (off & 0x7FFFu);
  return off;
}
inline bool IsInvalidVramBitmapWindow(uint32_t addr, uint8_t dispcnt_mode) {
  // mGBA/reference behavior: in bitmap modes (3/4/5), 0x06018000-0x0601BFFF
  // is treated as invalid VRAM window.
  const uint32_t off = addr & 0x1FFFFu;
  return dispcnt_mode >= 3u && off >= 0x18000u && off < 0x1C000u;
}
}

void GBACore::UpdateOpenBus(uint32_t addr, uint32_t val, int size) const {
  last_access_addr_ = addr;
  last_access_size_ = static_cast<uint8_t>(size);
  last_access_valid_ = true;
  open_bus_latch_ = val;
}

void GBACore::AddWaitstates(uint32_t addr, int size, bool is_write) const {
  const uint32_t region = (addr >> 24) & 0xFu;
  const bool seq = last_access_valid_ && (((last_access_addr_ + static_cast<uint32_t>(last_access_size_)) & ~1u) == (addr & ~1u));
  if (region >= 0x8u && region <= 0xDu) {
    const size_t ws = (region - 0x8u) >> 1u;
    uint32_t cost = size == 4 ? (seq ? ws_seq_32_[ws] : ws_nonseq_32_[ws])
                              : (seq ? ws_seq_16_[ws] : ws_nonseq_16_[ws]);
    if (!is_write && gamepak_prefetch_enabled_ && seq && cost > 1u) {
      // 簡易近似: prefetch有効時の連続読み出しは1サイクル短縮
      --cost;
    }
    waitstates_accum_ += cost;
    return;
  }
  if (size == 4) {
    waitstates_accum_ += seq ? kBaseSeq32[region] : kBaseNonSeq32[region];
  } else {
    waitstates_accum_ += seq ? kBaseSeq16[region] : kBaseNonSeq16[region];
  }
}

void GBACore::RebuildGamePakWaitstateTables(uint16_t waitcnt) {
  static constexpr std::array<uint8_t, 4> kNonSeq = {4, 3, 2, 8};
  static constexpr std::array<uint8_t, 2> kSeq01 = {2, 1};
  static constexpr std::array<uint8_t, 2> kSeq2 = {8, 1};

  ws_nonseq_16_[0] = kNonSeq[(waitcnt >> 2) & 0x3];
  ws_nonseq_16_[1] = kNonSeq[(waitcnt >> 5) & 0x3];
  ws_nonseq_16_[2] = kNonSeq[(waitcnt >> 8) & 0x3];
  ws_seq_16_[0] = kSeq01[(waitcnt >> 4) & 1];
  ws_seq_16_[1] = kSeq01[(waitcnt >> 7) & 1];
  ws_seq_16_[2] = kSeq2[(waitcnt >> 10) & 1];

  for (size_t i = 0; i < 3; ++i) {
    ws_nonseq_32_[i] = static_cast<uint8_t>(ws_nonseq_16_[i] + ws_seq_16_[i]);
    ws_seq_32_[i] = static_cast<uint8_t>(ws_seq_16_[i] * 2);
  }
  gamepak_prefetch_enabled_ = (waitcnt & (1u << 14)) != 0;
}

uint16_t GBACore::ReadIO16(uint32_t addr) const {
  const uint32_t o = addr & 0x3FFu;
  return static_cast<uint16_t>(ReadArr(io_regs_, o) | (ReadArr(io_regs_, o + 1) << 8));
}

void GBACore::WriteIO8(uint32_t addr, uint8_t value) {
  const uint32_t o = addr & 0x3FFu;
  // Read-only bytes
  if (o == 0x006 || o == 0x007 || o == 0x130 || o == 0x131) return;

  // IF: write-1-to-clear per written byte.
  if (o == 0x202 || o == 0x203) {
    uint16_t cur = ReadIO16(0x04000202u);
    const uint16_t clr = (o & 1u) ? static_cast<uint16_t>(value << 8) : value;
    cur = static_cast<uint16_t>(cur & ~clr);
    io_regs_[0x202] = static_cast<uint8_t>(cur & 0xFFu);
    io_regs_[0x203] = static_cast<uint8_t>(cur >> 8);
    return;
  }

  // IME: only low byte bit0 is writable.
  if (o == 0x209) return;
  if (o == 0x208) {
    WriteIO16(0x04000208u, static_cast<uint16_t>(value & 1u));
    return;
  }

  // Byte masks for partially writable upper bytes.
  if (o == 0x201) value &= 0x3Fu;  // IE high: IRQ bits 8..13
  if (o == 0x205) value &= 0x7Fu;  // WAITCNT high: bit15 unused

  // DISPSTAT low byte preserves status bits 0-2.
  if (o == 0x004) {
    const uint16_t cur = ReadIO16(0x04000004u);
    const uint8_t merged = static_cast<uint8_t>((value & 0xF8u) | (cur & 0x07u));
    const uint16_t next = static_cast<uint16_t>((cur & 0xFF00u) | merged);
    WriteIO16(0x04000004u, next);
    return;
  }

  const uint32_t ioa = o & ~1u;
  uint16_t cur = ReadIO16(0x04000000u + ioa);
  uint16_t next = cur;
  if (o & 1u) next = static_cast<uint16_t>((cur & 0x00FFu) | (static_cast<uint16_t>(value) << 8));
  else next = static_cast<uint16_t>((cur & 0xFF00u) | value);
  WriteIO16(0x04000000u + ioa, next);
}

void GBACore::WriteIO16(uint32_t addr, uint16_t value) {
  const uint32_t o = addr & 0x3FFu;

  // Read-only registers
  if (o == 0x006 || o == 0x130) {
    return;
  }

  // DISPSTAT: status flags (bits 0-2) are read-only.
  if (o == 0x004) {
    const uint16_t cur = ReadIO16(0x04000004u);
    value = static_cast<uint16_t>((value & 0xFFF8u) | (cur & 0x0007u));
  }
  // IE: 14-bit interrupt mask
  if (o == 0x200) value &= 0x3FFFu;
  // WAITCNT: bit15 is unused
  if (o == 0x204) value &= 0xDFFFu;
  // IME: only bit0 is writable
  if (o == 0x208) value &= 0x0001u;
  // DISPCNT: bit3 (CGB mode) is read-only/unused on GBA.
  if (o == 0x000) value &= 0xFFF7u;
  // BG0/BG1CNT: bit13 (overflow) is not used.
  if (o == 0x008 || o == 0x00A) value &= 0xDFFFu;
  // MOSAIC: each size field is 4-bit.
  if (o == 0x04C) value &= 0x0F0Fu;
  // WININ/WINOUT: each window nibble uses lower 6 bits.
  if (o == 0x048 || o == 0x04A) value &= 0x3F3Fu;
  // BG2/BG3 reference point high halves are 12-bit signed fragments.
  if (o == 0x02A || o == 0x02E || o == 0x03A || o == 0x03E) value &= 0x0FFFu;
  // BLDCNT: bits14-15 unused.
  if (o == 0x050) value &= 0x3FFFu;
  // BLDALPHA: EVA/EVB are 5-bit each.
  if (o == 0x052) value &= 0x1F1Fu;
  // BLDY: EVY is 5-bit.
  if (o == 0x054) value &= 0x001Fu;
  // SOUNDBIAS: bias level (10-bit) + amplitude resolution (2-bit).
  if (o == 0x088) value &= 0xC3FFu;
  // SOUNDCNT_X/NR52: only master enable bit is writable; status bits are read-only.
  if (o == 0x084) {
    const uint16_t cur = ReadIO16(0x04000084u);
    value = static_cast<uint16_t>((cur & 0x000Fu) | (value & 0x0080u));
  }
  // Timer control high registers: only start/irq/countup/prescaler bits are meaningful.
  if ((o == 0x102) || (o == 0x106) || (o == 0x10A) || (o == 0x10E)) value &= 0x00C7u;
  // KEYCNT: key bits (0-9) + IRQ control bits (14-15).
  if (o == 0x132) value &= 0xC3FFu;
  // RCNT: only serial/gpio control bits are meaningful.
  if (o == 0x134) value &= 0xC1FFu;
  // DMA control high masks (ch0-2: no gamepak DRQ bit, ch3: include DRQ).
  if (o == 0x0BA || o == 0x0C6 || o == 0x0D2) value &= 0xF7E0u;
  if (o == 0x0DE) value &= 0xFFE0u;

  // IF: write-1-to-clear
  if (o == 0x202) {
    uint16_t cur = ReadIO16(0x04000202u);
    cur = static_cast<uint16_t>(cur & ~value);
    io_regs_[0x202] = static_cast<uint8_t>(cur & 0xFFu);
    io_regs_[0x203] = static_cast<uint8_t>(cur >> 8);
    return;
  }

  io_regs_[o] = static_cast<uint8_t>(value & 0xFFu);
  io_regs_[(o + 1) & 0x3FFu] = static_cast<uint8_t>(value >> 8);

  // DMA source/destination address register masks.
  if (o >= 0x0B0 && o <= 0x0DE) {
    const uint32_t base = 0x0B0u + ((o - 0x0B0u) / 12u) * 12u;
    const uint32_t reg_off = (o - base) & ~1u;
    auto read32io = [&](uint32_t off) -> uint32_t {
      return static_cast<uint32_t>(io_regs_[off & 0x3FFu]) |
             (static_cast<uint32_t>(io_regs_[(off + 1) & 0x3FFu]) << 8) |
             (static_cast<uint32_t>(io_regs_[(off + 2) & 0x3FFu]) << 16) |
             (static_cast<uint32_t>(io_regs_[(off + 3) & 0x3FFu]) << 24);
    };
    auto write32io = [&](uint32_t off, uint32_t v) {
      io_regs_[off & 0x3FFu] = static_cast<uint8_t>(v & 0xFFu);
      io_regs_[(off + 1) & 0x3FFu] = static_cast<uint8_t>((v >> 8) & 0xFFu);
      io_regs_[(off + 2) & 0x3FFu] = static_cast<uint8_t>((v >> 16) & 0xFFu);
      io_regs_[(off + 3) & 0x3FFu] = static_cast<uint8_t>(v >> 24);
    };
    const int ch = static_cast<int>((base - 0x0B0u) / 12u);
    if (reg_off < 4u) {
      uint32_t sad = read32io(base);
      const uint32_t src_mask = (ch == 0) ? 0x07FFFFFFu : 0x0FFFFFFFu;
      sad &= src_mask;
      write32io(base, sad);
    } else if (reg_off < 8u) {
      uint32_t dad = read32io(base + 4u);
      const uint32_t dst_mask = (ch <= 2) ? 0x07FFFFFFu : 0x0FFFFFFFu;
      dad &= dst_mask;
      write32io(base + 4u, dad);
    }
  }

  if (o == 0x204) RebuildGamePakWaitstateTables(value);

  // DMA enable edge: shadow capture
  if (o >= 0xBA && o <= 0xDE && ((o - 0xBA) % 12u) == 0) {
    const int ch = static_cast<int>((o - 0xBA) / 12u);
    if (value & 0x8000u) {
      const uint32_t base = 0xB0u + static_cast<uint32_t>(ch) * 12u;
      const uint32_t sad = (ReadIO16(0x04000000u + base) | (ReadIO16(0x04000000u + base + 2u) << 16));
      const uint32_t dad = (ReadIO16(0x04000000u + base + 4u) | (ReadIO16(0x04000000u + base + 6u) << 16));
      const uint16_t cnt = ReadIO16(0x04000000u + base + 8u);
      dma_shadows_[ch].sad = sad;
      dma_shadows_[ch].dad = dad;
      dma_shadows_[ch].count = cnt ? cnt : (ch == 3 ? 0x10000u : 0x4000u);
      dma_shadows_[ch].initial_dad = dma_shadows_[ch].dad;
      dma_shadows_[ch].initial_count = dma_shadows_[ch].count;
      ScheduleDmaStart(ch, value);
    }
  }

  // Timer reload/control shadowing
  if (o >= 0x100 && o <= 0x10E) {
    const int timer = static_cast<int>((o - 0x100) / 4u);
    if (((o - 0x100) % 4u) == 0) {
      timers_[timer].reload = value;
    } else {
      const bool was_enable = (timers_[timer].control & 0x0080u) != 0;
      timers_[timer].control = static_cast<uint16_t>(value & 0x00C7u);
      if (!was_enable && (timers_[timer].control & 0x0080u)) {
        timers_[timer].counter = timers_[timer].reload;
        timers_[timer].prescaler_accum = 0;
      }
    }
  }
}

uint32_t GBACore::ReadBus32(uint32_t a) const { return Read32(a); }

uint8_t GBACore::Read8(uint32_t addr) const {
  addr &= kAddrMask28;
  uint8_t v = static_cast<uint8_t>(open_bus_latch_ & 0xFFu);
  const uint32_t region = addr & kRegionMask;

  switch (region) {
    case 0x00000000u:
      if (addr < 0x4000u) {
        if (cpu_.regs[15] < 0x4000u || bios_loaded_) {
          v = bios_[addr & 0x3FFFu];
          bios_data_latch_ = (bios_data_latch_ & 0xFFFFFF00u) | v;
          if ((addr & ~3u) == (cpu_.regs[15] & ~3u)) {
            const uint32_t a = addr & ~3u;
            bios_fetch_latch_ = static_cast<uint32_t>(bios_[a & 0x3FFFu]) |
                                (static_cast<uint32_t>(bios_[(a + 1) & 0x3FFFu]) << 8) |
                                (static_cast<uint32_t>(bios_[(a + 2) & 0x3FFFu]) << 16) |
                                (static_cast<uint32_t>(bios_[(a + 3) & 0x3FFFu]) << 24);
          }
        } else {
          v = static_cast<uint8_t>((bios_fetch_latch_ >> ((addr & 3u) * 8u)) & 0xFFu);
        }
      }
      break;
    case 0x02000000u: v = ewram_[addr & 0x3FFFFu]; break;
    case 0x03000000u: v = iwram_[addr & 0x7FFFu]; break;
    case 0x04000000u: v = io_regs_[addr & 0x3FFu]; break;
    case 0x05000000u: v = palette_ram_[addr & 0x3FFu]; break;
    case 0x06000000u: {
      const uint8_t mode = io_regs_[0] & 0x7u;
      if (!IsInvalidVramBitmapWindow(addr, mode)) {
        v = vram_[MapVramOffset(addr) % vram_.size()];
      }
      break;
    }
    case 0x07000000u: v = oam_[addr & 0x3FFu]; break;
    case 0x08000000u:
    case 0x09000000u:
    case 0x0A000000u:
    case 0x0B000000u:
    case 0x0C000000u:
    case 0x0D000000u:
      if (!rom_.empty()) v = rom_[addr % rom_.size()];
      break;
    case 0x0E000000u: v = ReadBackup8(addr); break;
    default: break;
  }

  UpdateOpenBus(addr, v, 1);
  AddWaitstates(addr, 1, false);
  return v;
}

uint16_t GBACore::Read16(uint32_t addr) const {
  const uint32_t aligned = addr & ~1u;
  const uint32_t region = aligned & kRegionMask;
  uint16_t v = static_cast<uint16_t>(open_bus_latch_ & 0xFFFFu);
  switch (region) {
    case 0x00000000u:
      if (aligned < 0x4000u) {
        if (cpu_.regs[15] < 0x4000u || bios_loaded_) {
          v = static_cast<uint16_t>(bios_[aligned & 0x3FFFu] | (bios_[(aligned + 1) & 0x3FFFu] << 8));
          bios_data_latch_ = (bios_data_latch_ & 0xFFFF0000u) | v;
          if ((aligned & ~3u) == (cpu_.regs[15] & ~3u)) {
            const uint32_t a = aligned & ~3u;
            bios_fetch_latch_ = static_cast<uint32_t>(bios_[a & 0x3FFFu]) |
                                (static_cast<uint32_t>(bios_[(a + 1) & 0x3FFFu]) << 8) |
                                (static_cast<uint32_t>(bios_[(a + 2) & 0x3FFFu]) << 16) |
                                (static_cast<uint32_t>(bios_[(a + 3) & 0x3FFFu]) << 24);
          }
        } else {
          v = static_cast<uint16_t>((bios_fetch_latch_ >> ((aligned & 2u) * 8u)) & 0xFFFFu);
        }
      }
      break;
    case 0x02000000u: v = static_cast<uint16_t>(ewram_[aligned & 0x3FFFFu] | (ewram_[(aligned + 1) & 0x3FFFFu] << 8)); break;
    case 0x03000000u: v = static_cast<uint16_t>(iwram_[aligned & 0x7FFFu] | (iwram_[(aligned + 1) & 0x7FFFu] << 8)); break;
    case 0x04000000u: v = ReadIO16(aligned); break;
    case 0x05000000u: v = static_cast<uint16_t>(palette_ram_[aligned & 0x3FFu] | (palette_ram_[(aligned + 1) & 0x3FFu] << 8)); break;
    case 0x06000000u: {
      const uint8_t mode = io_regs_[0] & 0x7u;
      if (!IsInvalidVramBitmapWindow(aligned, mode)) {
        const uint32_t vo = MapVramOffset(aligned) % vram_.size();
        const uint32_t vo1 = MapVramOffset(aligned + 1u) % vram_.size();
        v = static_cast<uint16_t>(vram_[vo] | (vram_[vo1] << 8));
      }
      break;
    }
    case 0x07000000u: v = static_cast<uint16_t>(oam_[aligned & 0x3FFu] | (oam_[(aligned + 1) & 0x3FFu] << 8)); break;
    case 0x08000000u:
    case 0x09000000u:
    case 0x0A000000u:
    case 0x0B000000u:
    case 0x0C000000u:
    case 0x0D000000u:
      if (!rom_.empty()) v = static_cast<uint16_t>(rom_[aligned % rom_.size()] | (rom_[(aligned + 1) % rom_.size()] << 8));
      break;
    case 0x0E000000u: v = static_cast<uint16_t>(ReadBackup8(aligned) | (ReadBackup8(aligned + 1) << 8)); break;
    default: break;
  }
  AddWaitstates(aligned, 2, false);
  UpdateOpenBus(aligned, v, 2);
  return v;
}

uint32_t GBACore::Read32(uint32_t addr) const {
  const uint32_t aligned = addr & ~3u;
  const uint32_t region = aligned & kRegionMask;
  uint32_t raw = open_bus_latch_;
  switch (region) {
    case 0x00000000u:
      if (aligned < 0x4000u) {
        if (cpu_.regs[15] < 0x4000u || bios_loaded_) {
          raw = static_cast<uint32_t>(bios_[aligned & 0x3FFFu]) |
              (static_cast<uint32_t>(bios_[(aligned + 1) & 0x3FFFu]) << 8) |
              (static_cast<uint32_t>(bios_[(aligned + 2) & 0x3FFFu]) << 16) |
              (static_cast<uint32_t>(bios_[(aligned + 3) & 0x3FFFu]) << 24);
          bios_data_latch_ = raw;
          if (aligned == (cpu_.regs[15] & ~3u)) {
            bios_fetch_latch_ = raw;
          }
        } else {
          raw = bios_fetch_latch_;
        }
      }
      break;
    case 0x02000000u:
      raw = static_cast<uint32_t>(ewram_[aligned & 0x3FFFFu]) |
          (static_cast<uint32_t>(ewram_[(aligned + 1) & 0x3FFFFu]) << 8) |
          (static_cast<uint32_t>(ewram_[(aligned + 2) & 0x3FFFFu]) << 16) |
          (static_cast<uint32_t>(ewram_[(aligned + 3) & 0x3FFFFu]) << 24);
      break;
    case 0x03000000u:
      raw = static_cast<uint32_t>(iwram_[aligned & 0x7FFFu]) |
          (static_cast<uint32_t>(iwram_[(aligned + 1) & 0x7FFFu]) << 8) |
          (static_cast<uint32_t>(iwram_[(aligned + 2) & 0x7FFFu]) << 16) |
          (static_cast<uint32_t>(iwram_[(aligned + 3) & 0x7FFFu]) << 24);
      break;
    case 0x04000000u:
      raw = static_cast<uint32_t>(ReadIO16(aligned)) | (static_cast<uint32_t>(ReadIO16(aligned + 2u)) << 16);
      break;
    case 0x05000000u:
      raw = static_cast<uint32_t>(palette_ram_[aligned & 0x3FFu]) |
          (static_cast<uint32_t>(palette_ram_[(aligned + 1) & 0x3FFu]) << 8) |
          (static_cast<uint32_t>(palette_ram_[(aligned + 2) & 0x3FFu]) << 16) |
          (static_cast<uint32_t>(palette_ram_[(aligned + 3) & 0x3FFu]) << 24);
      break;
    case 0x06000000u: {
      const uint8_t mode = io_regs_[0] & 0x7u;
      if (!IsInvalidVramBitmapWindow(aligned, mode)) {
        const uint32_t vo0 = MapVramOffset(aligned) % vram_.size();
        const uint32_t vo1 = MapVramOffset(aligned + 1u) % vram_.size();
        const uint32_t vo2 = MapVramOffset(aligned + 2u) % vram_.size();
        const uint32_t vo3 = MapVramOffset(aligned + 3u) % vram_.size();
        raw = static_cast<uint32_t>(vram_[vo0]) |
            (static_cast<uint32_t>(vram_[vo1]) << 8) |
            (static_cast<uint32_t>(vram_[vo2]) << 16) |
            (static_cast<uint32_t>(vram_[vo3]) << 24);
      }
      break;
    }
    case 0x07000000u:
      raw = static_cast<uint32_t>(oam_[aligned & 0x3FFu]) |
          (static_cast<uint32_t>(oam_[(aligned + 1) & 0x3FFu]) << 8) |
          (static_cast<uint32_t>(oam_[(aligned + 2) & 0x3FFu]) << 16) |
          (static_cast<uint32_t>(oam_[(aligned + 3) & 0x3FFu]) << 24);
      break;
    case 0x08000000u:
    case 0x09000000u:
    case 0x0A000000u:
    case 0x0B000000u:
    case 0x0C000000u:
    case 0x0D000000u:
      if (!rom_.empty()) {
        raw = static_cast<uint32_t>(rom_[aligned % rom_.size()]) |
            (static_cast<uint32_t>(rom_[(aligned + 1) % rom_.size()]) << 8) |
            (static_cast<uint32_t>(rom_[(aligned + 2) % rom_.size()]) << 16) |
            (static_cast<uint32_t>(rom_[(aligned + 3) % rom_.size()]) << 24);
      }
      break;
    case 0x0E000000u:
      raw = static_cast<uint32_t>(ReadBackup8(aligned)) |
          (static_cast<uint32_t>(ReadBackup8(aligned + 1u)) << 8) |
          (static_cast<uint32_t>(ReadBackup8(aligned + 2u)) << 16) |
          (static_cast<uint32_t>(ReadBackup8(aligned + 3u)) << 24);
      break;
    default: break;
  }
  uint32_t v = raw;
  if (addr & 3u) {
    v = RotateRight(raw, (addr & 3u) * 8u);
  }
  AddWaitstates(aligned, 4, false);
  UpdateOpenBus(aligned, raw, 4);
  return v;
}

void GBACore::Write8(uint32_t addr, uint8_t value) {
  addr &= kAddrMask28;
  const uint32_t region = addr & kRegionMask;

  switch (region) {
    case 0x02000000u: ewram_[addr & 0x3FFFFu] = value; break;
    case 0x03000000u: iwram_[addr & 0x7FFFu] = value; break;
    case 0x04000000u: WriteIO8(addr, value); break;
    case 0x05000000u:
      // Palette RAM is 16-bit; byte stores replicate to both bytes.
      Write16(addr & ~1u, static_cast<uint16_t>(value) * 0x0101u);
      return;
    case 0x06000000u:
      // VRAM is effectively 16-bit on GBA; byte stores replicate across the halfword.
      Write16(addr & ~1u, static_cast<uint16_t>(value) * 0x0101u);
      return;
    case 0x07000000u:
      // OAM does not support byte writes on GBA.
      break;
    case 0x0E000000u: WriteBackup8(addr, value); break;
    default: break;
  }

  UpdateOpenBus(addr, value, 1);
  AddWaitstates(addr, 1, true);
}

void GBACore::Write16(uint32_t addr, uint16_t value) {
  const uint32_t aligned = addr & ~1u;
  const uint32_t region = aligned & kRegionMask;
  switch (region) {
    case 0x02000000u:
      ewram_[aligned & 0x3FFFFu] = static_cast<uint8_t>(value & 0xFFu);
      ewram_[(aligned + 1) & 0x3FFFFu] = static_cast<uint8_t>(value >> 8);
      break;
    case 0x03000000u:
      iwram_[aligned & 0x7FFFu] = static_cast<uint8_t>(value & 0xFFu);
      iwram_[(aligned + 1) & 0x7FFFu] = static_cast<uint8_t>(value >> 8);
      break;
    case 0x04000000u: WriteIO16(aligned, value); break;
    case 0x05000000u:
      palette_ram_[aligned & 0x3FFu] = static_cast<uint8_t>(value & 0xFFu);
      palette_ram_[(aligned + 1) & 0x3FFu] = static_cast<uint8_t>(value >> 8);
      break;
    case 0x06000000u: {
      const uint8_t mode = io_regs_[0] & 0x7u;
      if (!IsInvalidVramBitmapWindow(aligned, mode)) {
        const uint32_t vo = MapVramOffset(aligned) % vram_.size();
        const uint32_t vo1 = MapVramOffset(aligned + 1u) % vram_.size();
        vram_[vo] = static_cast<uint8_t>(value & 0xFFu);
        vram_[vo1] = static_cast<uint8_t>(value >> 8);
      }
      break;
    }
    case 0x07000000u:
      oam_[aligned & 0x3FFu] = static_cast<uint8_t>(value & 0xFFu);
      oam_[(aligned + 1) & 0x3FFu] = static_cast<uint8_t>(value >> 8);
      break;
    case 0x0E000000u:
      WriteBackup8(aligned, static_cast<uint8_t>(value & 0xFFu));
      WriteBackup8(aligned + 1, static_cast<uint8_t>(value >> 8));
      break;
    default: break;
  }
  AddWaitstates(aligned, 2, true);
  UpdateOpenBus(aligned, value, 2);
}

void GBACore::Write32(uint32_t addr, uint32_t value) {
  const uint32_t aligned = addr & ~3u;
  const uint32_t region = aligned & kRegionMask;
  switch (region) {
    case 0x02000000u:
      ewram_[aligned & 0x3FFFFu] = static_cast<uint8_t>(value & 0xFFu);
      ewram_[(aligned + 1) & 0x3FFFFu] = static_cast<uint8_t>((value >> 8) & 0xFFu);
      ewram_[(aligned + 2) & 0x3FFFFu] = static_cast<uint8_t>((value >> 16) & 0xFFu);
      ewram_[(aligned + 3) & 0x3FFFFu] = static_cast<uint8_t>(value >> 24);
      break;
    case 0x03000000u:
      iwram_[aligned & 0x7FFFu] = static_cast<uint8_t>(value & 0xFFu);
      iwram_[(aligned + 1) & 0x7FFFu] = static_cast<uint8_t>((value >> 8) & 0xFFu);
      iwram_[(aligned + 2) & 0x7FFFu] = static_cast<uint8_t>((value >> 16) & 0xFFu);
      iwram_[(aligned + 3) & 0x7FFFu] = static_cast<uint8_t>(value >> 24);
      break;
    case 0x04000000u:
      WriteIO16(aligned, static_cast<uint16_t>(value & 0xFFFFu));
      WriteIO16(aligned + 2u, static_cast<uint16_t>((value >> 16) & 0xFFFFu));
      break;
    case 0x05000000u:
      palette_ram_[aligned & 0x3FFu] = static_cast<uint8_t>(value & 0xFFu);
      palette_ram_[(aligned + 1) & 0x3FFu] = static_cast<uint8_t>((value >> 8) & 0xFFu);
      palette_ram_[(aligned + 2) & 0x3FFu] = static_cast<uint8_t>((value >> 16) & 0xFFu);
      palette_ram_[(aligned + 3) & 0x3FFu] = static_cast<uint8_t>(value >> 24);
      break;
    case 0x06000000u: {
      const uint8_t mode = io_regs_[0] & 0x7u;
      if (!IsInvalidVramBitmapWindow(aligned, mode)) {
        const uint32_t vo0 = MapVramOffset(aligned) % vram_.size();
        const uint32_t vo1 = MapVramOffset(aligned + 1u) % vram_.size();
        const uint32_t vo2 = MapVramOffset(aligned + 2u) % vram_.size();
        const uint32_t vo3 = MapVramOffset(aligned + 3u) % vram_.size();
        vram_[vo0] = static_cast<uint8_t>(value & 0xFFu);
        vram_[vo1] = static_cast<uint8_t>((value >> 8) & 0xFFu);
        vram_[vo2] = static_cast<uint8_t>((value >> 16) & 0xFFu);
        vram_[vo3] = static_cast<uint8_t>(value >> 24);
      }
      break;
    }
    case 0x07000000u:
      oam_[aligned & 0x3FFu] = static_cast<uint8_t>(value & 0xFFu);
      oam_[(aligned + 1) & 0x3FFu] = static_cast<uint8_t>((value >> 8) & 0xFFu);
      oam_[(aligned + 2) & 0x3FFu] = static_cast<uint8_t>((value >> 16) & 0xFFu);
      oam_[(aligned + 3) & 0x3FFu] = static_cast<uint8_t>(value >> 24);
      break;
    case 0x0E000000u:
      WriteBackup8(aligned, static_cast<uint8_t>(value & 0xFFu));
      WriteBackup8(aligned + 1u, static_cast<uint8_t>((value >> 8) & 0xFFu));
      WriteBackup8(aligned + 2u, static_cast<uint8_t>((value >> 16) & 0xFFu));
      WriteBackup8(aligned + 3u, static_cast<uint8_t>(value >> 24));
      break;
    default: break;
  }
  AddWaitstates(aligned, 4, true);
  UpdateOpenBus(aligned, value, 4);
}

}  // namespace gba
