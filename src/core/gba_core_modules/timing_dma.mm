#include "../gba_core.h"
#include <algorithm>

namespace gba {

void GBACore::StepPpu(uint32_t cycles) {
  constexpr uint32_t kHD=1006,kSL=1232,kVIS=160,kTOT=228;
  auto poke=[&](uint32_t a,uint16_t v){size_t o=a-0x04000000u;if(o+1<io_regs_.size()){io_regs_[o]=v&0xFF;io_regs_[o+1]=(v>>8)&0xFF;}};
  auto peek=[&](uint32_t a)->uint16_t{size_t o=a-0x04000000u;if(o+1>=io_regs_.size())return 0;return(uint16_t)io_regs_[o]|((uint16_t)io_regs_[o+1]<<8);};
  uint32_t rem=cycles;
  while(rem>0){
    bool in_hb=(peek(0x04000004u)&2)!=0;
    uint32_t dist=in_hb?(ppu_cycle_accum_<kSL?kSL-ppu_cycle_accum_:1u):(ppu_cycle_accum_<kHD?kHD-ppu_cycle_accum_:1u);
    uint32_t step=std::min(rem,dist);
    ppu_cycle_accum_+=step; rem-=step;
    if(!in_hb&&ppu_cycle_accum_>=kHD){
      uint16_t ds=peek(0x04000004u); ds|=2; poke(0x04000004u,ds);
      if(ds&(1u<<4))RaiseInterrupt(1u<<1);
      if(peek(0x04000006u)<kVIS)StepDmaHBlank();
    }
    if(ppu_cycle_accum_>=kSL){
      ppu_cycle_accum_=0;
      uint16_t nvc=(uint16_t)((peek(0x04000006u)+1)%kTOT);
      poke(0x04000006u,nvc);
      uint16_t ds=peek(0x04000004u)&~2u;
      bool was_vb=(ds&1)!=0, now_vb=(nvc>=kVIS&&nvc<kTOT-1);
      if(now_vb){ds|=1;if(!was_vb){if(ds&(1u<<3))RaiseInterrupt(1u<<0);poke(0x04000004u,ds);StepDmaVBlank();}}
      else ds&=~1u;
      uint16_t lyc=(ds>>8)&0xFF;
      if(nvc==lyc){if(!(ds&4)&&(ds&(1u<<5)))RaiseInterrupt(1u<<2);ds|=4;}else ds&=~4u;
      poke(0x04000004u,ds);
      if(nvc==0){
        auto rb28=[&](uint32_t a)->int32_t{
          size_t o=a-0x04000000u;
          uint32_t r=(uint32_t)io_regs_[o]|((uint32_t)io_regs_[o+1]<<8)|((uint32_t)io_regs_[o+2]<<16)|((uint32_t)io_regs_[o+3]<<24);
          r&=0x0FFFFFFFu;return (int32_t)(r<<4)>>4;
        };
        bg2_refx_internal_=rb28(0x04000028u);bg2_refy_internal_=rb28(0x0400002Cu);
        bg3_refx_internal_=rb28(0x04000038u);bg3_refy_internal_=rb28(0x0400003Cu);
      } else {
        bg2_refx_internal_+=(int16_t)peek(0x04000022u); bg2_refy_internal_+=(int16_t)peek(0x04000026u);
        bg3_refx_internal_+=(int16_t)peek(0x04000032u); bg3_refy_internal_+=(int16_t)peek(0x04000036u);
      }
      if(nvc<kTOT){
        bg2_refx_line_[nvc]=bg2_refx_internal_;bg2_refy_line_[nvc]=bg2_refy_internal_;
        bg3_refx_line_[nvc]=bg3_refx_internal_;bg3_refy_line_[nvc]=bg3_refy_internal_;
        if(nvc<kVIS){affine_line_captured_[nvc]=1;affine_line_refs_valid_=true;}
      }
    }
  }
}

void GBACore::StepTimers(uint32_t cycles){
  static constexpr uint32_t kPS[4]={1,64,256,1024};
  auto wt=[&](size_t i,uint16_t v){size_t o=0x100+i*4;if(o+1<io_regs_.size()){io_regs_[o]=v&0xFF;io_regs_[o+1]=(v>>8)&0xFF;}};
  for(uint32_t c=0;c<cycles;++c){
    bool ov[4]={};
    for(int i=0;i<4;++i){
      TimerState&t=timers_[i];if(!(t.control&0x80u))continue;
      bool tick=false;
      if(i>0&&(t.control&4)){if(ov[i-1])tick=true;}
      else{if(++t.prescaler_accum>=kPS[t.control&3u]){t.prescaler_accum=0;tick=true;}}
      if(tick){if(++t.counter==0){t.counter=t.reload;ov[i]=true;if(t.control&0x40u)RaiseInterrupt(1u<<(3+i));ConsumeAudioFifoOnTimer((size_t)i);}wt((size_t)i,t.counter);}
    }
  }
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
} while(0)

void GBACore::ExecuteDmaTransfer(int ch, uint16_t cnt_h){
  const uint32_t st=(cnt_h>>12)&3u;
  const bool w32=(cnt_h&0x400u)!=0,rep=(cnt_h&0x200u)!=0;
  const int dc=(cnt_h>>5)&3,sc=(cnt_h>>7)&3;
  const int unit=w32?4:2;
  const uint32_t src_mask=(ch==0)?0x07FFFFFEu:0x0FFFFFFEu;
  const uint32_t dst_mask=(ch==3)?0x0FFFFFFEu:0x07FFFFFEu;
  uint32_t cnt=dma_shadows_[ch].count;
  if(st==3&&(ch==1||ch==2))cnt=4;
  uint32_t src=dma_shadows_[ch].sad&src_mask,dst=dma_shadows_[ch].dad&dst_mask;
  src&=w32?~3u:~1u;
  dst&=w32?~3u:~1u;
  for(uint32_t n=0;n<cnt;++n){
    if(w32)Write32(dst,Read32(src));else Write16(dst,Read16(src));
    const bool src_in_rom=src>=0x08000000u&&src<0x0E000000u;
    if(src_in_rom||sc==0)src=(src+unit)&src_mask;else if(sc==1)src=(src-unit)&src_mask;
    if(!(st==3&&(ch==1||ch==2))){
      if(dc==0||dc==3)dst=(dst+unit)&dst_mask;else if(dc==1)dst=(dst-unit)&dst_mask;
    }
  }
  dma_shadows_[ch].sad=src;
  const uint32_t base=0x040000B0u+(uint32_t)ch*12u;
  const size_t coff=(size_t)(base+10-0x04000000u);
  if(rep&&st!=0){
    uint32_t c=(uint32_t)io_regs_[(size_t)(base-0x04000000u)+8]|((uint32_t)io_regs_[(size_t)(base-0x04000000u)+9]<<8);
    if(c==0)c=(ch==3)?0x10000u:0x4000u;
    dma_shadows_[ch].count=c;
    if(dc==3)dma_shadows_[ch].dad=dma_shadows_[ch].initial_dad;else dma_shadows_[ch].dad=dst;
    dma_shadows_[ch].active=true;
  } else {
    dma_shadows_[ch].dad=dst;dma_shadows_[ch].active=false;
    if(!rep){uint16_t nc=(uint16_t)((uint16_t)io_regs_[coff]|((uint16_t)io_regs_[coff+1]<<8))&~0x8000u;io_regs_[coff]=nc&0xFF;io_regs_[coff+1]=(nc>>8)&0xFF;}
  }
  if(cnt_h&0x4000u)RaiseInterrupt(1u<<(8+ch));
}

void GBACore::StepDma(){
  for(int ch=0;ch<4;++ch){
    const uint32_t base=0x040000B0u+(uint32_t)ch*12u;
    const uint16_t cnt_h=(uint16_t)io_regs_[base-0x04000000u+10]|((uint16_t)io_regs_[base-0x04000000u+11]<<8);
    if(!(cnt_h&0x8000u)){dma_shadows_[ch].active=false;continue;}
    if(((cnt_h>>12)&3u)!=0)continue;
    if(!dma_shadows_[ch].active){INIT_DMA_SHADOW(ch);}
    if(dma_shadows_[ch].active)ExecuteDmaTransfer(ch,cnt_h);
  }
}
void GBACore::StepDmaVBlank(){
  for(int ch=0;ch<4;++ch){
    const uint32_t base=0x040000B0u+(uint32_t)ch*12u;
    const uint16_t cnt_h=(uint16_t)io_regs_[base-0x04000000u+10]|((uint16_t)io_regs_[base-0x04000000u+11]<<8);
    if(!(cnt_h&0x8000u))continue;
    if(((cnt_h>>12)&3u)!=1)continue;
    if(!dma_shadows_[ch].active){INIT_DMA_SHADOW(ch);}
    if(dma_shadows_[ch].active)ExecuteDmaTransfer(ch,cnt_h);
  }
}
void GBACore::StepDmaHBlank(){
  for(int ch=0;ch<4;++ch){
    const uint32_t base=0x040000B0u+(uint32_t)ch*12u;
    const uint16_t cnt_h=(uint16_t)io_regs_[base-0x04000000u+10]|((uint16_t)io_regs_[base-0x04000000u+11]<<8);
    if(!(cnt_h&0x8000u))continue;
    if(((cnt_h>>12)&3u)!=2)continue;
    if(!dma_shadows_[ch].active){INIT_DMA_SHADOW(ch);}
    if(dma_shadows_[ch].active)ExecuteDmaTransfer(ch,cnt_h);
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
    if(dma_fifo_a_request_){dma_fifo_a_request_=false;const uint16_t c=ReadIO16(0x040000C6u);if((c&0x8000u)&&((c>>12)&3u)==3u)ExecuteDmaTransfer(1,c);}
  }
  if((!bt1&&ti==0)||(bt1&&ti==1)){
    pop(&fifo_b_,&fifo_b_last_sample_,&dma_fifo_b_request_);
    if(dma_fifo_b_request_){dma_fifo_b_request_=false;const uint16_t c=ReadIO16(0x040000D2u);if((c&0x8000u)&&((c>>12)&3u)==3u)ExecuteDmaTransfer(2,c);}
  }
}
#undef INIT_DMA_SHADOW
} // namespace gba
