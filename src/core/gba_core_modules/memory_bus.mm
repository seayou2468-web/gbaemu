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
}

void GBACore::UpdateOpenBus(uint32_t addr, uint32_t val, int size) const {
  last_access_addr_ = addr;
  last_access_size_ = static_cast<uint8_t>(size);
  last_access_valid_ = true;
  open_bus_latch_ = val;
}

void GBACore::AddWaitstates(uint32_t addr, int size, bool is_write) const {
  (void)is_write;
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

void GBACore::WriteIO16(uint32_t addr, uint16_t value) {
  const uint32_t o = addr & 0x3FFu;

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
        } else {
          v = static_cast<uint8_t>(bios_data_latch_ & 0xFFu);
        }
      }
      break;
    case 0x02000000u: v = ewram_[addr & 0x3FFFFu]; break;
    case 0x03000000u: v = iwram_[addr & 0x7FFFu]; break;
    case 0x04000000u: v = io_regs_[addr & 0x3FFu]; break;
    case 0x05000000u: v = palette_ram_[addr & 0x3FFu]; break;
    case 0x06000000u: v = vram_[addr % vram_.size()]; break;
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
        } else {
          v = static_cast<uint16_t>(bios_data_latch_ & 0xFFFFu);
        }
      }
      break;
    case 0x02000000u: v = static_cast<uint16_t>(ewram_[aligned & 0x3FFFFu] | (ewram_[(aligned + 1) & 0x3FFFFu] << 8)); break;
    case 0x03000000u: v = static_cast<uint16_t>(iwram_[aligned & 0x7FFFu] | (iwram_[(aligned + 1) & 0x7FFFu] << 8)); break;
    case 0x04000000u: v = ReadIO16(aligned); break;
    case 0x05000000u: v = static_cast<uint16_t>(palette_ram_[aligned & 0x3FFu] | (palette_ram_[(aligned + 1) & 0x3FFu] << 8)); break;
    case 0x06000000u: v = static_cast<uint16_t>(vram_[aligned % vram_.size()] | (vram_[(aligned + 1) % vram_.size()] << 8)); break;
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
  const uint32_t lo = Read16(aligned);
  const uint32_t hi = Read16(aligned + 2);
  uint32_t v = lo | (hi << 16);
  if (addr & 3u) {
    v = RotateRight(v, (addr & 3u) * 8u);
  }
  UpdateOpenBus(aligned, v, 4);
  return v;
}

void GBACore::Write8(uint32_t addr, uint8_t value) {
  addr &= kAddrMask28;
  const uint32_t region = addr & kRegionMask;

  switch (region) {
    case 0x02000000u: ewram_[addr & 0x3FFFFu] = value; break;
    case 0x03000000u: iwram_[addr & 0x7FFFu] = value; break;
    case 0x04000000u: io_regs_[addr & 0x3FFu] = value; break;
    case 0x05000000u: palette_ram_[addr & 0x3FFu] = value; break;
    case 0x06000000u: vram_[addr % vram_.size()] = value; break;
    case 0x07000000u: oam_[addr & 0x3FFu] = value; break;
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
    case 0x06000000u:
      vram_[aligned % vram_.size()] = static_cast<uint8_t>(value & 0xFFu);
      vram_[(aligned + 1) % vram_.size()] = static_cast<uint8_t>(value >> 8);
      break;
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
  Write16(aligned, static_cast<uint16_t>(value & 0xFFFFu));
  Write16(aligned + 2, static_cast<uint16_t>(value >> 16));
  UpdateOpenBus(aligned, value, 4);
}

}  // namespace gba
