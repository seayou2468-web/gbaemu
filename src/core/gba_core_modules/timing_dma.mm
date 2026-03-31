#include "../gba_core.h"
#include <algorithm>

namespace gba {

void GBACore::StepPpu(uint32_t cycles) {
  constexpr uint32_t kHD = 1006;
  constexpr uint32_t kSL = 1232;
  constexpr uint32_t kVIS = 160;
  constexpr uint32_t kTOT = 228;

  auto rd16 = [&](size_t off) -> uint16_t {
    return static_cast<uint16_t>(io_regs_[off]) |
           (static_cast<uint16_t>(io_regs_[off + 1u]) << 8);
  };
  auto wr16 = [&](size_t off, uint16_t v) {
    io_regs_[off] = static_cast<uint8_t>(v & 0xFFu);
    io_regs_[off + 1u] = static_cast<uint8_t>((v >> 8) & 0xFFu);
  };
  auto rd28 = [&](size_t off) -> int32_t {
    uint32_t raw = static_cast<uint32_t>(io_regs_[off]) |
                   (static_cast<uint32_t>(io_regs_[off + 1u]) << 8) |
                   (static_cast<uint32_t>(io_regs_[off + 2u]) << 16) |
                   (static_cast<uint32_t>(io_regs_[off + 3u]) << 24);
    raw &= 0x0FFFFFFFu;
    return static_cast<int32_t>(raw << 4) >> 4;
  };

  constexpr size_t kDispstatOff = 0x0004u;
  constexpr size_t kVcountOff = 0x0006u;
  uint32_t rem = cycles;
  while (rem > 0u) {
    uint16_t dispstat = rd16(kDispstatOff);
    const bool in_hblank = (dispstat & 0x0002u) != 0u;
    const uint32_t next_edge = in_hblank ? kSL : kHD;
    const uint32_t dist = (ppu_cycle_accum_ < next_edge) ? (next_edge - ppu_cycle_accum_) : 1u;
    const uint32_t step = std::min(rem, dist);
    ppu_cycle_accum_ += step;
    rem -= step;

    if (!in_hblank && ppu_cycle_accum_ >= kHD) {
      dispstat |= 0x0002u;
      wr16(kDispstatOff, dispstat);
      if (dispstat & (1u << 4)) RaiseInterrupt(1u << 1);
      const uint16_t vcount = rd16(kVcountOff);
      if (vcount < kVIS) StepDmaHBlank();
    }

    if (ppu_cycle_accum_ < kSL) continue;

    ppu_cycle_accum_ = 0;
    const uint16_t prev_vcount = rd16(kVcountOff);
    const uint16_t nvc = static_cast<uint16_t>((prev_vcount + 1u) % kTOT);
    wr16(kVcountOff, nvc);

    dispstat = rd16(kDispstatOff);
    dispstat &= static_cast<uint16_t>(~0x0002u);  // leave HBlank
    const bool was_vblank = (dispstat & 0x0001u) != 0u;
    const bool now_vblank = (nvc >= kVIS && nvc < (kTOT - 1u));
    if (now_vblank) {
      dispstat |= 0x0001u;
      if (!was_vblank) {
        RenderDebugFrame();
        frame_rendered_in_vblank_ = true;
        if (dispstat & (1u << 3)) RaiseInterrupt(1u << 0);
        wr16(kDispstatOff, dispstat);
        StepDmaVBlank();
      }
    } else {
      dispstat &= static_cast<uint16_t>(~0x0001u);
    }

    const uint16_t lyc = static_cast<uint16_t>((dispstat >> 8) & 0xFFu);
    if (nvc == lyc) {
      if ((dispstat & 0x0004u) == 0u && (dispstat & (1u << 5))) RaiseInterrupt(1u << 2);
      dispstat |= 0x0004u;
    } else {
      dispstat &= static_cast<uint16_t>(~0x0004u);
    }
    wr16(kDispstatOff, dispstat);

    if (nvc == 0u) {
      bg2_refx_internal_ = rd28(0x0028u);
      bg2_refy_internal_ = rd28(0x002Cu);
      bg3_refx_internal_ = rd28(0x0038u);
      bg3_refy_internal_ = rd28(0x003Cu);
    } else {
      bg2_refx_internal_ += static_cast<int16_t>(rd16(0x0022u));
      bg2_refy_internal_ += static_cast<int16_t>(rd16(0x0026u));
      bg3_refx_internal_ += static_cast<int16_t>(rd16(0x0032u));
      bg3_refy_internal_ += static_cast<int16_t>(rd16(0x0036u));
    }

    bg2_refx_line_[nvc] = bg2_refx_internal_;
    bg2_refy_line_[nvc] = bg2_refy_internal_;
    bg3_refx_line_[nvc] = bg3_refx_internal_;
    bg3_refy_line_[nvc] = bg3_refy_internal_;
    for (int bg = 0; bg < 4; ++bg) {
      const size_t cnt_off = 0x0008u + static_cast<size_t>(bg) * 2u;
      const size_t hofs_off = 0x0010u + static_cast<size_t>(bg) * 4u;
      const size_t vofs_off = 0x0012u + static_cast<size_t>(bg) * 4u;
      bg_cnt_line_[nvc][bg] = rd16(cnt_off);
      bg_hofs_line_[nvc][bg] = rd16(hofs_off);
      bg_vofs_line_[nvc][bg] = rd16(vofs_off);
    }
    bg2_affine_line_[nvc].pa = static_cast<int16_t>(rd16(0x0020u));
    bg2_affine_line_[nvc].pb = static_cast<int16_t>(rd16(0x0022u));
    bg2_affine_line_[nvc].pc = static_cast<int16_t>(rd16(0x0024u));
    bg2_affine_line_[nvc].pd = static_cast<int16_t>(rd16(0x0026u));
    bg3_affine_line_[nvc].pa = static_cast<int16_t>(rd16(0x0030u));
    bg3_affine_line_[nvc].pb = static_cast<int16_t>(rd16(0x0032u));
    bg3_affine_line_[nvc].pc = static_cast<int16_t>(rd16(0x0034u));
    bg3_affine_line_[nvc].pd = static_cast<int16_t>(rd16(0x0036u));

    if (nvc < kVIS) {
      affine_line_captured_[nvc] = 1;
      affine_line_refs_valid_ = true;
      bg_scroll_line_valid_ = true;
      bg_affine_params_line_valid_ = true;
    }
  }
}

void GBACore::StepTimers(uint32_t cycles){
  static constexpr uint32_t kPS[4] = {1, 64, 256, 1024};
  auto wt=[&](size_t i,uint16_t v){
    size_t o=0x100+i*4;
    if(o+1<io_regs_.size()){io_regs_[o]=v&0xFF;io_regs_[o+1]=(v>>8)&0xFF;}
  };
  auto advance_counter = [&](TimerState& t, uint32_t ticks) -> uint32_t {
    if (ticks == 0u) return 0u;
    uint32_t overflows = 0u;
    uint32_t counter = t.counter;
    if (counter + ticks < 0x10000u) {
      t.counter = static_cast<uint16_t>(counter + ticks);
      return 0u;
    }

    uint32_t remaining = ticks - (0x10000u - counter);
    overflows = 1u;
    const uint32_t period = 0x10000u - static_cast<uint32_t>(t.reload);
    if (period != 0u) {
      overflows += remaining / period;
      remaining %= period;
    } else {
      // reload == 0x0000 => full 16-bit period
      overflows += (remaining >> 16);
      remaining &= 0xFFFFu;
    }
    t.counter = static_cast<uint16_t>(static_cast<uint32_t>(t.reload) + remaining);
    return overflows;
  };

  uint32_t prev_overflows = 0u;
  for (int i = 0; i < 4; ++i) {
    TimerState& t = timers_[i];
    if ((t.control & 0x80u) == 0u) {
      prev_overflows = 0u;
      continue;
    }

    uint32_t ticks = 0u;
    if (i > 0 && (t.control & 0x4u) != 0u) {
      ticks = prev_overflows;
    } else {
      const uint32_t prescale = kPS[t.control & 0x3u];
      const uint32_t total = t.prescaler_accum + cycles;
      ticks = total / prescale;
      t.prescaler_accum = total % prescale;
    }

    const uint32_t overflows = advance_counter(t, ticks);
    if (overflows != 0u) {
      if (t.control & 0x40u) RaiseInterrupt(1u << (3 + i));
      for (uint32_t n = 0; n < overflows; ++n) {
        ConsumeAudioFifoOnTimer(static_cast<size_t>(i));
      }
    }
    wt(static_cast<size_t>(i), t.counter);
    prev_overflows = overflows;
  }
}

void GBACore::UpdateSioMode() {
  const uint16_t siocnt = ReadIO16(0x04000128u);
  const uint16_t rcnt = ReadIO16(0x04000134u);
  sio_.rcnt = rcnt;
  if ((rcnt & 0x8000u) == 0u) {
    const uint16_t mode = siocnt & 0x0003u;
    switch (mode) {
      case 0: sio_.mode = SioMode::kNormal8; break;
      case 1: sio_.mode = SioMode::kNormal32; break;
      case 2: sio_.mode = SioMode::kMulti; break;
      default: sio_.mode = SioMode::kUart; break;
    }
  } else {
    sio_.mode = (siocnt & 0x3000u) ? SioMode::kJoybus : SioMode::kGpio;
  }
}

uint32_t GBACore::EstimateSioTransferCycles(uint16_t siocnt) const {
  switch (sio_.mode) {
    case SioMode::kNormal8:
      return ((siocnt & 0x0002u) != 0u) ? 128u : 1024u;
    case SioMode::kNormal32:
      return ((siocnt & 0x0002u) != 0u) ? 512u : 4096u;
    case SioMode::kMulti: {
      static constexpr uint32_t kBaudCycles[4] = { 960u, 320u, 128u, 32u };
      return kBaudCycles[(siocnt >> 0) & 0x3u];
    }
    default:
      return 0u;
  }
}

void GBACore::StartSioTransfer(uint16_t siocnt) {
  const uint32_t cycles = EstimateSioTransferCycles(siocnt);
  if (cycles == 0u) return;
  sio_.transfer_active = true;
  sio_.transfer_cycles_remaining = cycles;
}

void GBACore::CompleteSioTransfer() {
  sio_.transfer_active = false;
  sio_.transfer_cycles_remaining = 0;

  const size_t siocnt_off = static_cast<size_t>(0x04000128u - 0x04000000u);
  uint16_t siocnt = static_cast<uint16_t>(io_regs_[siocnt_off]) |
                    (static_cast<uint16_t>(io_regs_[siocnt_off + 1u]) << 8);

  switch (sio_.mode) {
    case SioMode::kMulti: {
      const uint16_t send = ReadIO16(0x0400012Au);
      WriteIO16(0x04000120u, send);
      WriteIO16(0x04000122u, 0xFFFFu);
      WriteIO16(0x04000124u, 0xFFFFu);
      WriteIO16(0x04000126u, 0xFFFFu);
      siocnt &= static_cast<uint16_t>(~0x0080u);  // busy clear
      break;
    }
    case SioMode::kNormal8:
      siocnt &= static_cast<uint16_t>(~0x0080u);  // start clear
      break;
    case SioMode::kNormal32:
      siocnt &= static_cast<uint16_t>(~0x0080u);  // start clear
      break;
    default:
      return;
  }

  io_regs_[siocnt_off] = static_cast<uint8_t>(siocnt & 0xFFu);
  io_regs_[siocnt_off + 1u] = static_cast<uint8_t>((siocnt >> 8) & 0xFFu);
  if ((siocnt & 0x4000u) != 0u) {
    RaiseInterrupt(1u << 7);  // Serial
  }
}

void GBACore::StepSio(uint32_t cycles) {
  if (!sio_.transfer_active || cycles == 0u) return;
  if (cycles >= sio_.transfer_cycles_remaining) {
    CompleteSioTransfer();
    return;
  }
  sio_.transfer_cycles_remaining -= cycles;
}

// DMAシャドウ初期化 (inline)
#define INIT_DMA_SHADOW(ch_val) do { \
  const uint32_t _base = 0x040000B0u + (uint32_t)(ch_val) * 12u; \
  const size_t _boff = (size_t)(_base - 0x04000000u); \
  auto _r32 = [&](size_t o) -> uint32_t { \
    if (o+3>=io_regs_.size()) return 0; \
    return (uint32_t)io_regs_[o]|((uint32_t)io_regs_[o+1]<<8)|((uint32_t)io_regs_[o+2]<<16)|((uint32_t)io_regs_[o+3]<<24); \
  }; \
  dma_shadows_[ch_val].sad = _r32(_boff); \
  dma_shadows_[ch_val].initial_dad = _r32(_boff+4); \
  dma_shadows_[ch_val].dad = dma_shadows_[ch_val].initial_dad; \
  uint32_t _c = (uint32_t)io_regs_[_boff+8]|((uint32_t)io_regs_[_boff+9]<<8); \
  if (_c==0) _c = ((ch_val)==3) ? 0x10000u : 0x4000u; \
  dma_shadows_[ch_val].initial_count = _c; \
  dma_shadows_[ch_val].count = _c; \
  dma_shadows_[ch_val].active = true; \
  dma_shadows_[ch_val].pending = false; \
  dma_shadows_[ch_val].startup_delay = 0; \
  dma_shadows_[ch_val].in_progress = false; \
  dma_shadows_[ch_val].wait_cycles = 0; \
  dma_shadows_[ch_val].last_value = open_bus_latch_; \
  dma_shadows_[ch_val].seq_access = false; \
  dma_shadows_[ch_val].prev_src_addr = dma_shadows_[ch_val].sad; \
  dma_shadows_[ch_val].prev_dst_addr = dma_shadows_[ch_val].dad; \
} while(0)

uint32_t GBACore::EstimateDmaStartupDelay(int ch, uint16_t cnt_h) const {
  const bool w32 = ((cnt_h & 0x0400u) != 0u) || ((((cnt_h >> 12) & 3u) == 3u) && (ch == 1 || ch == 2));
  const uint32_t src = dma_shadows_[ch].sad;
  const uint32_t region = (src >> 24) & 0xFu;
  uint32_t src_nonseq = 1u;
  if (region >= 0x08u && region <= 0x0Du) {
    const uint32_t ws = std::min(((src >> 25) & 3u), 2u);
    src_nonseq = w32 ? ws_nonseq_32_[ws] : ws_nonseq_16_[ws];
  } else if (region == 0x02u) {
    src_nonseq = w32 ? 6u : 3u;
  } else if (region == 0x05u || region == 0x06u) {
    src_nonseq = w32 ? 2u : 1u;
  }
  return 2u + src_nonseq;
}

void GBACore::ScheduleDmaStart(int ch, uint16_t cnt_h, uint32_t delay_cycles_override) {
  if (ch < 0 || ch >= 4) return;
  if (!dma_shadows_[ch].active) {
    INIT_DMA_SHADOW(ch);
  }
  if (!dma_shadows_[ch].active) return;
  const uint32_t st = (cnt_h >> 12) & 3u;
  const bool fifo_dma = (st == 3u) && (ch == 1 || ch == 2);
  if (!IsDmaAddressValid(ch, dma_shadows_[ch].sad, dma_shadows_[ch].dad, fifo_dma)) {
    dma_shadows_[ch].active = false;
    dma_shadows_[ch].pending = false;
    return;
  }
  dma_shadows_[ch].pending = true;
  dma_shadows_[ch].in_progress = false;
  dma_shadows_[ch].wait_cycles = 0;
  dma_shadows_[ch].seq_access = false;
  dma_shadows_[ch].prev_src_addr = dma_shadows_[ch].sad;
  dma_shadows_[ch].prev_dst_addr = dma_shadows_[ch].dad;
  dma_shadows_[ch].startup_delay =
      (delay_cycles_override == 0xFFFFFFFFu) ? EstimateDmaStartupDelay(ch, cnt_h) : delay_cycles_override;
}

bool GBACore::IsDmaAddressValid(int ch, uint32_t src, uint32_t dst, bool fifo_dma) const {
  const bool src_valid = (src >= 0x02000000u);
  if (!src_valid) return false;
  if (fifo_dma) return true;
  if (ch != 3 && dst >= 0x08000000u) return false;
  return true;
}

void GBACore::ExecuteDmaTransfer(int ch, uint16_t cnt_h){
  while (dma_shadows_[ch].in_progress && dma_shadows_[ch].count > 0u) {
    if (!ServiceDmaChannelUnit(ch, cnt_h)) break;
  }
}

bool GBACore::ServiceDmaChannelUnit(int ch, uint16_t cnt_h) {
  const uint32_t st=(cnt_h>>12)&3u;
  const bool fifo_dma = (st==3u && (ch==1 || ch==2));
  const bool w32=fifo_dma ? true : ((cnt_h&0x400u)!=0),rep=(cnt_h&0x200u)!=0;
  const int dc=(cnt_h>>5)&3,sc=(cnt_h>>7)&3;
  const int unit=w32?4:2;
  const uint32_t src_mask=(ch==0)?0x07FFFFFEu:0x0FFFFFFEu;
  const uint32_t dst_mask=(ch==3)?0x0FFFFFFEu:0x07FFFFFEu;
  uint32_t src=dma_shadows_[ch].sad&src_mask,dst=dma_shadows_[ch].dad&dst_mask;
  if (!IsDmaAddressValid(ch, src, dst, fifo_dma)) {
    dma_shadows_[ch].active = false;
    dma_shadows_[ch].pending = false;
    dma_shadows_[ch].in_progress = false;
    return false;
  }
  src&=w32?~3u:~1u;
  dst&=w32?~3u:~1u;
  const uint32_t src_step = static_cast<uint32_t>(unit);
  const uint32_t dst_step = static_cast<uint32_t>(unit);
  const bool src_dec = (sc == 1);
  const bool src_fix = (sc == 2);
  const bool dst_dec = (dc == 1);
  const bool dst_fix = fifo_dma || (dc == 2);
  if (fifo_dma) {
    dst = (ch == 1) ? 0x040000A0u : 0x040000A4u;
  }
  uint32_t value = dma_shadows_[ch].last_value;
  if (w32) {
    if (src >= 0x02000000u) {
      value = Read32(src);
    }
    Write32(dst, value);
  } else {
    if (src >= 0x02000000u) {
      const uint16_t v16 = Read16(src);
      value = static_cast<uint32_t>(v16) | (static_cast<uint32_t>(v16) << 16);
    }
    Write16(dst, static_cast<uint16_t>(value & 0xFFFFu));
  }
  dma_shadows_[ch].last_value = value;
  // DMA drives the data bus directly. Open-bus should latch the transferred bus
  // value itself (not destination-address lane masking).
  open_bus_latch_ = w32 ? value : ((value & 0xFFFFu) * 0x00010001u);
  if (!src_fix) src = src_dec ? ((src - src_step) & src_mask) : ((src + src_step) & src_mask);
  if (!dst_fix) dst = dst_dec ? ((dst - dst_step) & dst_mask) : ((dst + dst_step) & dst_mask);
  dma_shadows_[ch].sad=src;
  dma_shadows_[ch].dad=dst;
  if (dma_shadows_[ch].count > 0u) dma_shadows_[ch].count -= 1u;
  if (dma_shadows_[ch].count > 0u) return true;

  dma_shadows_[ch].pending = false;
  dma_shadows_[ch].startup_delay = 0;
  dma_shadows_[ch].in_progress = false;
  dma_shadows_[ch].wait_cycles = 0;
  dma_shadows_[ch].seq_access = false;
  dma_shadows_[ch].prev_src_addr = dma_shadows_[ch].sad;
  dma_shadows_[ch].prev_dst_addr = dma_shadows_[ch].dad;
  const uint32_t base=0x040000B0u+(uint32_t)ch*12u;
  const size_t coff=(size_t)(base+10-0x04000000u);
  if(rep&&st!=0){
    uint32_t c=(uint32_t)io_regs_[(size_t)(base-0x04000000u)+8]|((uint32_t)io_regs_[(size_t)(base-0x04000000u)+9]<<8);
    if(c==0)c=(ch==3)?0x10000u:0x4000u;
    dma_shadows_[ch].count=c;
    if(dc==3)dma_shadows_[ch].dad=dma_shadows_[ch].initial_dad;
    dma_shadows_[ch].active=true;
  } else {
    dma_shadows_[ch].active=false;
    if(!rep){uint16_t nc=(uint16_t)((uint16_t)io_regs_[coff]|((uint16_t)io_regs_[coff+1]<<8))&~0x8000u;io_regs_[coff]=nc&0xFF;io_regs_[coff+1]=(nc>>8)&0xFF;}
  }
  if(cnt_h&0x4000u)RaiseInterrupt(1u<<(8+ch));
  return true;
}

static uint32_t DmaRegionWait(const std::array<uint8_t, 3>& ws_nonseq,
                              const std::array<uint8_t, 3>& ws_seq,
                              uint32_t addr, bool seq, bool w32) {
  const uint32_t region = (addr >> 24) & 0xFu;
  if (region >= 0x08u && region <= 0x0Du) {
    const uint32_t ws = std::min(((addr >> 25) & 3u), 2u);
    return seq ? ws_seq[ws] : ws_nonseq[ws];
  }
  if (region == 0x02u) { // EWRAM
    if (w32) return seq ? 3u : 6u;
    return seq ? 2u : 3u;
  }
  if (region == 0x03u) return 1u;            // IWRAM
  if (region == 0x05u || region == 0x06u) { // PAL/VRAM
    return seq ? 1u : (w32 ? 2u : 1u);
  }
  if (region == 0x07u) return 1u;            // OAM
  if (region == 0x04u) return 1u;            // IO
  return 1u;
}

static uint32_t EstimateDmaTransferCycles(uint32_t sad, uint32_t dad, bool seq_access,
                                          const std::array<uint8_t, 3>& ws_nonseq_16,
                                          const std::array<uint8_t, 3>& ws_seq_16,
                                          const std::array<uint8_t, 3>& ws_nonseq_32,
                                          const std::array<uint8_t, 3>& ws_seq_32,
                                          int ch, uint16_t cnt_h) {
  const uint32_t st = (cnt_h >> 12) & 3u;
  const bool fifo_dma = (st == 3u) && (ch == 1 || ch == 2);
  const bool w32 = fifo_dma || ((cnt_h & 0x0400u) != 0u);
  const uint32_t src_region = (sad >> 24) & 0xFu;
  const uint32_t dst_region = (dad >> 24) & 0xFu;
  const auto& ns = w32 ? ws_nonseq_32 : ws_nonseq_16;
  const auto& sq = w32 ? ws_seq_32 : ws_seq_16;
  const uint32_t src_ws = DmaRegionWait(ns, sq, sad, seq_access, w32);
  uint32_t dst_ws = DmaRegionWait(ns, sq, dad, seq_access, w32);
  if (fifo_dma) dst_ws = 1u;  // FIFO write port is always an IO sink.

  const bool src_rom = (src_region >= 0x08u && src_region <= 0x0Du);
  const bool dst_rom = (dst_region >= 0x08u && dst_region <= 0x0Du);
  const bool either_rom = src_rom || dst_rom;
  const bool dst_io = (dst_region == 0x04u);
  const bool ewram_to_vram = (src_region == 0x02u && dst_region == 0x06u);
  const uint32_t dominant_ws = std::max(src_ws, dst_ws);
  const uint32_t secondary_ws = std::min(src_ws, dst_ws);

  uint32_t base = seq_access ? 1u : 2u;  // bus turn-around/non-seq penalty
  if (fifo_dma) {
    return base + src_ws;
  }
  if (dst_io) {
    return base + dominant_ws + 1u;      // register sink write settle
  }
  if (either_rom) {
    // Gamepak-side accesses are mostly dominated by the slower edge, with a
    // partial contribution from the other side on non-sequential beats.
    return base + dominant_ws + (seq_access ? 0u : (secondary_ws >> 1));
  }
  if (ewram_to_vram && !seq_access) {
    return base + dominant_ws + 1u;      // conservative first-beat penalty
  }
  return base + dominant_ws;
}

void GBACore::StepDma(){
  dma_bus_taken_ = false;
  for (int ch = 0; ch < 4; ++ch) {
    const uint32_t base=0x040000B0u+(uint32_t)ch*12u;
    const uint16_t cnt_h=(uint16_t)io_regs_[base-0x04000000u+10]|((uint16_t)io_regs_[base-0x04000000u+11]<<8);
    if(!(cnt_h&0x8000u)){dma_shadows_[ch].active=false; dma_shadows_[ch].pending=false; dma_shadows_[ch].in_progress=false; dma_shadows_[ch].wait_cycles=0; dma_shadows_[ch].seq_access=false; continue;}
    if (((cnt_h >> 12) & 3u) == 0u && dma_shadows_[ch].active && !dma_shadows_[ch].pending && !dma_shadows_[ch].in_progress) {
      ScheduleDmaStart(ch, cnt_h);
    }
  }
  for(int ch=0;ch<4;++ch){
    const uint32_t base=0x040000B0u+(uint32_t)ch*12u;
    const uint16_t cnt_h=(uint16_t)io_regs_[base-0x04000000u+10]|((uint16_t)io_regs_[base-0x04000000u+11]<<8);
    if(!(cnt_h&0x8000u)) continue;
    if (dma_shadows_[ch].pending && dma_shadows_[ch].startup_delay > 0u) {
      --dma_shadows_[ch].startup_delay;
    }
    if (dma_shadows_[ch].pending && dma_shadows_[ch].startup_delay == 0u) {
      dma_shadows_[ch].pending = false;
      dma_shadows_[ch].in_progress = true;
      dma_shadows_[ch].wait_cycles = EstimateDmaTransferCycles(
          dma_shadows_[ch].sad, dma_shadows_[ch].dad, false,
          ws_nonseq_16_, ws_seq_16_, ws_nonseq_32_, ws_seq_32_, ch, cnt_h);
      dma_shadows_[ch].seq_access = false;
      dma_shadows_[ch].prev_src_addr = dma_shadows_[ch].sad;
    }
  }
  for (int ch = 0; ch < 4; ++ch) {
    const uint32_t base=0x040000B0u+(uint32_t)ch*12u;
    const uint16_t cnt_h=(uint16_t)io_regs_[base-0x04000000u+10]|((uint16_t)io_regs_[base-0x04000000u+11]<<8);
    if (!(cnt_h & 0x8000u) || !dma_shadows_[ch].in_progress) continue;
    if (dma_shadows_[ch].wait_cycles > 0u) {
      --dma_shadows_[ch].wait_cycles;
      dma_bus_taken_ = true;
      break;
    }
    ServiceDmaChannelUnit(ch, cnt_h);
    if (dma_shadows_[ch].in_progress) {
      const bool w32 = ((cnt_h & 0x0400u) != 0u) || ((((cnt_h >> 12) & 3u) == 3u) && (ch == 1 || ch == 2));
      const uint32_t step = w32 ? 4u : 2u;
      const bool src_seq = (dma_shadows_[ch].sad == (dma_shadows_[ch].prev_src_addr + step));
      dma_shadows_[ch].seq_access = src_seq;
      dma_shadows_[ch].prev_src_addr = dma_shadows_[ch].sad;
      dma_shadows_[ch].wait_cycles = EstimateDmaTransferCycles(
          dma_shadows_[ch].sad, dma_shadows_[ch].dad, dma_shadows_[ch].seq_access,
          ws_nonseq_16_, ws_seq_16_, ws_nonseq_32_, ws_seq_32_, ch, cnt_h);
    }
    dma_bus_taken_ = true;
    break;  // DMA blocks CPU bus: one channel beat per scheduler step.
  }
  for (int ch = 0; ch < 4; ++ch) {
    const uint32_t base=0x040000B0u+(uint32_t)ch*12u;
    const uint16_t cnt_h=(uint16_t)io_regs_[base-0x04000000u+10]|((uint16_t)io_regs_[base-0x04000000u+11]<<8);
    if (!(cnt_h & 0x8000u)) continue;
    if ((((cnt_h >> 12) & 3u) == 0u) && dma_shadows_[ch].active &&
        !dma_shadows_[ch].pending && !dma_shadows_[ch].in_progress) {
      ScheduleDmaStart(ch, cnt_h);
    }
  }
}
void GBACore::StepDmaVBlank(){
  for(int ch=0;ch<4;++ch){
    const uint32_t base=0x040000B0u+(uint32_t)ch*12u;
    const uint16_t cnt_h=(uint16_t)io_regs_[base-0x04000000u+10]|((uint16_t)io_regs_[base-0x04000000u+11]<<8);
    if(!(cnt_h&0x8000u))continue;
    if(((cnt_h>>12)&3u)!=1)continue;
    if (!dma_shadows_[ch].pending && !dma_shadows_[ch].in_progress) ScheduleDmaStart(ch, cnt_h);
  }
}
void GBACore::StepDmaHBlank(){
  for(int ch=0;ch<4;++ch){
    const uint32_t base=0x040000B0u+(uint32_t)ch*12u;
    const uint16_t cnt_h=(uint16_t)io_regs_[base-0x04000000u+10]|((uint16_t)io_regs_[base-0x04000000u+11]<<8);
    if(!(cnt_h&0x8000u))continue;
    if(((cnt_h>>12)&3u)!=2)continue;
    if (!dma_shadows_[ch].pending && !dma_shadows_[ch].in_progress) ScheduleDmaStart(ch, cnt_h);
  }
}

void GBACore::PushAudioFifo(bool fa,uint32_t v){
  auto&f=fa?fifo_a_:fifo_b_;
  for(int i=0;i<4;++i)f.push_back((uint8_t)((v>>(i*8))&0xFF));
  while(f.size()>mgba_compat::kAudioFifoCapacityBytes)f.pop_front();
}
void GBACore::ConsumeAudioFifoOnTimer(size_t ti){
  const uint16_t sh=ReadIO16(0x04000082u);
  const bool at1=(sh&(1u<<10))!=0,bt1=(sh&(1u<<14))!=0;
  auto pop=[&](std::deque<uint8_t>*f,int16_t*last,bool*req){
    if(!f->empty()){*last=(int16_t)(int8_t)f->front();f->pop_front();}
    if(f->size()<=mgba_compat::kAudioFifoDmaRequestThreshold)*req=true;
  };
  if((!at1&&ti==0)||(at1&&ti==1)){
    pop(&fifo_a_,&fifo_a_last_sample_,&dma_fifo_a_request_);
    if(dma_fifo_a_request_){dma_fifo_a_request_=false;const uint16_t c=ReadIO16(0x040000C6u);if((c&0x8000u)&&((c>>12)&3u)==3u)ScheduleDmaStart(1,c,0u);}
  }
  if((!bt1&&ti==0)||(bt1&&ti==1)){
    pop(&fifo_b_,&fifo_b_last_sample_,&dma_fifo_b_request_);
    if(dma_fifo_b_request_){dma_fifo_b_request_=false;const uint16_t c=ReadIO16(0x040000D2u);if((c&0x8000u)&&((c>>12)&3u)==3u)ScheduleDmaStart(2,c,0u);}
  }
}
#undef INIT_DMA_SHADOW
} // namespace gba
