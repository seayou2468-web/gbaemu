#include "../gba_core.h"
#include <algorithm>

namespace gba {

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
      const uint64_t total = static_cast<uint64_t>(t.prescaler_accum) + static_cast<uint64_t>(cycles);
      ticks = static_cast<uint32_t>(total / prescale);
      t.prescaler_accum = static_cast<uint32_t>(total % prescale);
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
      case 3: sio_.mode = SioMode::kUart; break;
    }
  } else {
    sio_.mode = ((rcnt & 0x4000u) == 0u) ? SioMode::kGpio : SioMode::kJoybus;
  }
}

uint32_t GBACore::EstimateSioTransferCycles(uint16_t siocnt) const {
  switch (sio_.mode) {
    case SioMode::kNormal8: return ((siocnt & 0x0002u) != 0u) ? 128u : 1024u;
    case SioMode::kNormal32: return ((siocnt & 0x0002u) != 0u) ? 512u : 4096u;
    case SioMode::kMulti: {
      static constexpr uint32_t kBaudCycles[4] = { 960u, 320u, 128u, 32u };
      return kBaudCycles[(siocnt >> 0) & 0x3u];
    }
    default: return 0u;
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
  uint16_t siocnt = static_cast<uint16_t>(io_regs_[siocnt_off]) | (static_cast<uint16_t>(io_regs_[siocnt_off + 1u]) << 8);
  switch (sio_.mode) {
    case SioMode::kMulti: {
      WriteIO16(0x04000120u, ReadIO16(0x0400012Au));
      WriteIO16(0x04000122u, 0xFFFFu); WriteIO16(0x04000124u, 0xFFFFu); WriteIO16(0x04000126u, 0xFFFFu);
      siocnt &= static_cast<uint16_t>(~0x0080u); break;
    }
    case SioMode::kNormal8: case SioMode::kNormal32: siocnt &= static_cast<uint16_t>(~0x0080u); break;
    default: return;
  }
  io_regs_[siocnt_off] = static_cast<uint8_t>(siocnt & 0xFFu);
  io_regs_[siocnt_off + 1u] = static_cast<uint8_t>((siocnt >> 8) & 0xFFu);
  if ((siocnt & 0x4000u) != 0u) RaiseInterrupt(1u << 7);
}

void GBACore::StepSio(uint32_t cycles) {
  if (!sio_.transfer_active) return;
  if (sio_.transfer_cycles_remaining > cycles) {
    sio_.transfer_cycles_remaining -= cycles;
  } else {
    CompleteSioTransfer();
  }
}

void GBACore::ScheduleDmaStart(int ch, uint16_t cnt_h, uint32_t delay_cycles_override) {
  if (ch < 0 || ch >= 4) return;
  const uint32_t base_io = 0x040000B0u + (uint32_t)ch * 12u;
  const uint16_t actual_cnt_h = ReadIO16(base_io + 10);
  if (!(actual_cnt_h & 0x8000u)) return;
  if (!dma_shadows_[ch].active) {
      dma_shadows_[ch].sad = Read32(base_io);
      dma_shadows_[ch].initial_dad = Read32(base_io + 4);
      dma_shadows_[ch].dad = dma_shadows_[ch].initial_dad;
      uint32_t c = ReadIO16(base_io + 8);
      if (c == 0) c = (ch == 3) ? 0x10000u : 0x4000u;
      dma_shadows_[ch].count = c;
      dma_shadows_[ch].active = true;
  }
  dma_shadows_[ch].pending = true;
  dma_shadows_[ch].in_progress = false;
  dma_shadows_[ch].startup_delay = (delay_cycles_override == 0xFFFFFFFFu) ? 2u : delay_cycles_override;
}

bool GBACore::IsDmaAddressValid(int ch, uint32_t src, uint32_t dst, bool fifo_dma) const {
  if (src < 0x02000000u) return false;
  if (fifo_dma) return true;
  if (ch != 3 && dst >= 0x08000000u) return false;
  return true;
}

bool GBACore::ServiceDmaChannelUnit(int ch, uint16_t cnt_h) {
  const uint32_t st=(cnt_h>>12)&3u;
  const bool fifo_dma = (st==3u && (ch==1 || ch==2));
  const bool w32=fifo_dma ? true : ((cnt_h&0x400u)!=0);
  const int dc=(cnt_h>>5)&3, sc=(cnt_h>>7)&3;
  const uint32_t src_mask=(ch==0)?0x07FFFFFEu:0x0FFFFFFEu;
  const uint32_t dst_mask=(ch==3)?0x0FFFFFFEu:0x07FFFFFEu;
  uint32_t src=dma_shadows_[ch].sad&src_mask, dst=dma_shadows_[ch].dad&dst_mask;
  if (fifo_dma) dst = (ch == 1) ? 0x040000A0u : 0x040000A4u;
  uint32_t val = w32 ? Read32(src & ~3u) : Read16(src & ~1u);
  if (w32) Write32(dst & ~3u, val); else Write16(dst & ~1u, (uint16_t)val);
  dma_shadows_[ch].last_value = val;
  const uint32_t step = w32 ? 4u : 2u;
  if (sc != 2) dma_shadows_[ch].sad = (sc == 1) ? (src - step) : (src + step);
  if (!fifo_dma && dc != 2) dma_shadows_[ch].dad = (dc == 1) ? (dst - step) : (dst + step);
  if (dma_shadows_[ch].count > 0u) dma_shadows_[ch].count--;
  if (dma_shadows_[ch].count > 0u) return true;
  dma_shadows_[ch].in_progress = dma_shadows_[ch].pending = dma_shadows_[ch].active = false;
  if (cnt_h & 0x200u && st != 0) { // Repeat
      dma_shadows_[ch].active = true;
      uint32_t c = ReadIO16(0x040000B0u + ch * 12 + 8);
      if (c == 0) c = (ch == 3) ? 0x10000u : 0x4000u;
      dma_shadows_[ch].count = c;
      if (dc == 3) dma_shadows_[ch].dad = dma_shadows_[ch].initial_dad;
  } else {
      uint32_t addr = 0x040000B0u + ch * 12 + 10;
      WriteIO16(addr, ReadIO16(addr) & ~0x8000u);
  }
  if (cnt_h & 0x4000u) RaiseInterrupt(1u << (8 + ch));
  return false;
}

void GBACore::StepDma(){
  dma_bus_taken_ = false;
  for (int ch = 0; ch < 4; ++ch) {
    const uint32_t base=0x040000B0u+(uint32_t)ch*12u;
    const uint16_t cnt_h=ReadIO16(base + 10);
    if(!(cnt_h&0x8000u)) { dma_shadows_[ch].in_progress = dma_shadows_[ch].pending = false; continue; }
    if (dma_shadows_[ch].pending && dma_shadows_[ch].startup_delay > 0) {
        dma_shadows_[ch].startup_delay--;
        if (dma_shadows_[ch].startup_delay == 0) { dma_shadows_[ch].pending = false; dma_shadows_[ch].in_progress = true; }
    }
    if (dma_shadows_[ch].in_progress) {
        dma_bus_taken_ = true;
        if (gamepak_prefetch_enabled_ && prefetch_wait_ > 0) prefetch_wait_--;
        ServiceDmaChannelUnit(ch, cnt_h);
        break;
    }
  }
}

void GBACore::StepDmaVBlank(){
  for(int ch=0;ch<4;++ch){
    const uint16_t cnt_h=ReadIO16(0x040000B0u + ch*12 + 10);
    if((cnt_h&0x8000u) && ((cnt_h>>12)&3u)==1) ScheduleDmaStart(ch, cnt_h);
  }
}
void GBACore::StepDmaHBlank(){
  for(int ch=0;ch<4;++ch){
    const uint16_t cnt_h=ReadIO16(0x040000B0u + ch*12 + 10);
    if((cnt_h&0x8000u) && ((cnt_h>>12)&3u)==2) ScheduleDmaStart(ch, cnt_h);
  }
}

void GBACore::PushAudioFifo(bool fa,uint32_t v){
  auto&f=fa?fifo_a_:fifo_b_;
  for(int i=0;i<4;++i)f.push_back((uint8_t)((v>>(i*8))&0xFF));
  while(f.size()>mgba_compat::kAudioFifoCapacityBytes)f.pop_front();
}
void GBACore::ConsumeAudioFifoOnTimer(size_t ti){
  const uint16_t sh=ReadIO16(0x04000082u);
  const bool at1=(sh&(1u<<10))!=0, bt1=(sh&(1u<<14))!=0;
  auto pop=[&](std::deque<uint8_t>*f,int16_t*last,bool*req, int ch){
    if(!f->empty()){*last=(int16_t)(int8_t)f->front(); f->pop_front();}
    if(f->size()<=mgba_compat::kAudioFifoDmaRequestThreshold){
        const uint16_t c=ReadIO16(0x040000B0u + ch*12 + 10);
        if((c&0x8000u)&&((c>>12)&3u)==3u) ScheduleDmaStart(ch, c, 0u);
    }
  };
  if((!at1&&ti==0)||(at1&&ti==1)) pop(&fifo_a_,&fifo_a_last_sample_,&dma_fifo_a_request_, 1);
  if((!bt1&&ti==0)||(bt1&&ti==1)) pop(&fifo_b_,&fifo_b_last_sample_,&dma_fifo_b_request_, 2);
}

void GBACore::StepPpu(uint32_t cycles) {
  for (uint32_t i = 0; i < cycles; ++i) StepPpuSingleCycle();
}

} // namespace gba
