#include "../gba_core.h"
#include "./ppu_common.mm"
#include <cstdio>
#include <cstdlib>

namespace gba {
namespace {
inline bool CpuExceptionTraceEnabled() {
  static const bool enabled = (std::getenv("GBA_CPU_TRACE") != nullptr);
  return enabled;
}
}  // namespace

void GBACore::StepApu(uint32_t cycles) {
  // Lightweight APU model: PSG + FIFO mix.
  uint16_t soundcnt_x = ReadIO16(0x04000084u);
  const uint16_t soundcnt_l = ReadIO16(0x04000080u);
  const uint16_t soundcnt_h = ReadIO16(0x04000082u);
  const uint16_t master = (soundcnt_x & 0x0080u) ? 1u : 0u;
  if (!master) {
    audio_mix_level_ = 0;
    apu_ch1_active_ = apu_ch2_active_ = apu_ch3_active_ = apu_ch4_active_ = false;
    io_regs_[0x84] = 0;
    io_regs_[0x85] = 0;
    return;
  }

  // Handle trigger edges (bit7 write events latched by register shadow).
  const uint8_t nr14 = Read8(0x04000065u);
  const uint8_t nr24 = Read8(0x0400006Du);
  const uint8_t nr34 = Read8(0x04000075u);
  const uint8_t nr44 = Read8(0x0400007Du);
  const bool trig_ch1 = (nr14 & 0x80u) != 0;
  const bool trig_ch2 = (nr24 & 0x80u) != 0;
  const bool trig_ch3 = (nr34 & 0x80u) != 0;
  const bool trig_ch4 = (nr44 & 0x80u) != 0;
  if (trig_ch1) Write8(0x04000065u, static_cast<uint8_t>(nr14 & 0x7Fu));
  if (trig_ch2) Write8(0x0400006Du, static_cast<uint8_t>(nr24 & 0x7Fu));
  if (trig_ch3) Write8(0x04000075u, static_cast<uint8_t>(nr34 & 0x7Fu));
  if (trig_ch4) Write8(0x0400007Du, static_cast<uint8_t>(nr44 & 0x7Fu));
  apu_prev_trig_ch1_ = trig_ch1;
  apu_prev_trig_ch2_ = trig_ch2;
  apu_prev_trig_ch3_ = trig_ch3;
  apu_prev_trig_ch4_ = trig_ch4;

  if (trig_ch1) {
    apu_ch1_active_ = true;
    apu_len_ch1_ = static_cast<uint8_t>(64u - (Read8(0x04000062u) & 0x3Fu));
    apu_env_ch1_ = static_cast<uint8_t>((Read8(0x04000063u) >> 4) & 0xFu);
    apu_env_timer_ch1_ = static_cast<uint8_t>(Read8(0x04000063u) & 0x7u);
    apu_ch1_sweep_freq_ = static_cast<uint16_t>((Read8(0x04000064u)) |
                                                ((Read8(0x04000065u) & 0x7u) << 8));
    const uint8_t nr10 = Read8(0x04000060u);
    apu_ch1_sweep_timer_ = static_cast<uint8_t>((nr10 >> 4) & 0x7u);
    apu_ch1_sweep_enabled_ = (nr10 & 0x7u) != 0 || apu_ch1_sweep_timer_ != 0;
    const uint8_t shift = nr10 & 0x7u;
    if (apu_ch1_sweep_enabled_ && shift != 0u && (nr10 & 0x8u) == 0) {
      const uint16_t delta = static_cast<uint16_t>(apu_ch1_sweep_freq_ >> shift);
      if (apu_ch1_sweep_freq_ + delta > 2047u) {
        apu_ch1_active_ = false;
      }
    }
  }
  if (trig_ch2) {
    apu_ch2_active_ = true;
    apu_len_ch2_ = static_cast<uint8_t>(64u - (Read8(0x04000068u) & 0x3Fu));
    apu_env_ch2_ = static_cast<uint8_t>((Read8(0x04000069u) >> 4) & 0xFu);
    apu_env_timer_ch2_ = static_cast<uint8_t>(Read8(0x04000069u) & 0x7u);
  }
  if (trig_ch3) {
    apu_ch3_active_ = true;
    apu_len_ch3_ = static_cast<uint16_t>(256u - Read8(0x04000071u));
  }
  if (trig_ch4) {
    apu_ch4_active_ = true;
    apu_len_ch4_ = static_cast<uint8_t>(64u - (Read8(0x04000079u) & 0x3Fu));
    apu_env_ch4_ = static_cast<uint8_t>((Read8(0x04000077u) >> 4) & 0xFu);
    apu_env_timer_ch4_ = static_cast<uint8_t>(Read8(0x04000077u) & 0x7u);
  }

  // 512Hz frame sequencer (16777216 / 512 = 32768 cycles).
  apu_frame_seq_cycles_ += cycles;
  while (apu_frame_seq_cycles_ >= 32768u) {
    apu_frame_seq_cycles_ -= 32768u;
    apu_frame_seq_step_ = static_cast<uint8_t>((apu_frame_seq_step_ + 1u) & 7u);
    const bool length_tick = (apu_frame_seq_step_ % 2u) == 0u;
    const bool sweep_tick = (apu_frame_seq_step_ == 2u || apu_frame_seq_step_ == 6u);
    const bool envelope_tick = apu_frame_seq_step_ == 7u;

    if (length_tick) {
      if ((Read8(0x04000065u) & 0x40u) && apu_ch1_active_ && apu_len_ch1_ > 0 && --apu_len_ch1_ == 0) apu_ch1_active_ = false;
      if ((Read8(0x0400006Du) & 0x40u) && apu_ch2_active_ && apu_len_ch2_ > 0 && --apu_len_ch2_ == 0) apu_ch2_active_ = false;
      if ((Read8(0x04000075u) & 0x40u) && apu_ch3_active_ && apu_len_ch3_ > 0 && --apu_len_ch3_ == 0) apu_ch3_active_ = false;
      if ((Read8(0x0400007Du) & 0x40u) && apu_ch4_active_ && apu_len_ch4_ > 0 && --apu_len_ch4_ == 0) apu_ch4_active_ = false;
    }
    if (envelope_tick) {
      auto step_env = [](uint8_t* vol, uint8_t* timer, uint8_t reg) {
        const uint8_t period = reg & 0x7u;
        if (period == 0) return;
        if (*timer == 0) *timer = period;
        if (--(*timer) != 0) return;
        *timer = period;
        const bool inc = (reg & 0x8u) != 0;
        if (inc) {
          if (*vol < 15u) ++(*vol);
        } else {
          if (*vol > 0u) --(*vol);
        }
      };
      if (apu_ch1_active_) step_env(&apu_env_ch1_, &apu_env_timer_ch1_, Read8(0x04000063u));
      if (apu_ch2_active_) step_env(&apu_env_ch2_, &apu_env_timer_ch2_, Read8(0x04000069u));
      if (apu_ch4_active_) step_env(&apu_env_ch4_, &apu_env_timer_ch4_, Read8(0x04000077u));
    }
    if (sweep_tick && apu_ch1_active_ && apu_ch1_sweep_enabled_) {
      const uint8_t nr10 = Read8(0x04000060u);
      uint8_t sweep_period = static_cast<uint8_t>((nr10 >> 4) & 0x7u);
      if (sweep_period == 0) sweep_period = 8;
      if (apu_ch1_sweep_timer_ == 0) apu_ch1_sweep_timer_ = sweep_period;
      if (--apu_ch1_sweep_timer_ == 0) {
        apu_ch1_sweep_timer_ = sweep_period;
        const uint8_t shift = nr10 & 0x7u;
        if (shift != 0u) {
          const uint16_t delta = static_cast<uint16_t>(apu_ch1_sweep_freq_ >> shift);
          uint16_t next = apu_ch1_sweep_freq_;
          if (nr10 & 0x8u) {
            next = static_cast<uint16_t>(apu_ch1_sweep_freq_ - delta);
          } else {
            next = static_cast<uint16_t>(apu_ch1_sweep_freq_ + delta);
          }
          if (next > 2047u) {
            apu_ch1_active_ = false;
          } else {
            apu_ch1_sweep_freq_ = next;
            Write8(0x04000064u, static_cast<uint8_t>(next & 0xFFu));
            const uint8_t nr14_hi = Read8(0x04000065u);
            Write8(0x04000065u, static_cast<uint8_t>((nr14_hi & ~0x7u) | ((next >> 8) & 0x7u)));
            if ((nr10 & 0x8u) == 0) {
              const uint16_t next_delta = static_cast<uint16_t>(next >> shift);
              if (next + next_delta > 2047u) {
                apu_ch1_active_ = false;
              }
            }
          }
        }
      }
    }
  }

  auto duty_high_steps = [](uint16_t duty) -> int {
    switch (duty & 0x3u) {
      case 0: return 1;  // 12.5%
      case 1: return 2;  // 25%
      case 2: return 4;  // 50%
      case 3: return 6;  // 75%
      default: return 4;
    }
  };
  auto square_sample = [&](uint32_t* phase, uint16_t freq_reg, uint16_t duty_reg) -> int {
    const uint16_t n = static_cast<uint16_t>(freq_reg & 0x07FFu);
    const uint32_t hz = (2048u > n) ? (131072u / std::max<uint16_t>(1u, static_cast<uint16_t>(2048u - n))) : 0u;
    *phase += hz * std::max<uint32_t>(1u, cycles);
    const int step = static_cast<int>((*phase / 1024u) & 7u);
    const int high = duty_high_steps(static_cast<uint16_t>(duty_reg >> 6));
    return (step < high) ? 48 : -48;
  };

  int ch1 = 0;
  int ch2 = 0;
  int ch3 = 0;
  int ch4 = 0;
  if (apu_ch1_active_) {  // CH1
    const uint16_t nr11 = ReadIO16(0x04000062u);
    const uint16_t nr13 = ReadIO16(0x04000064u);
    const uint16_t nr14 = ReadIO16(0x04000065u);
    const uint16_t freq = static_cast<uint16_t>(nr13 | ((nr14 & 0x7u) << 8));
    const int env_vol = std::max<int>(0, std::min<int>(15, apu_env_ch1_));
    ch1 = (square_sample(&apu_phase_sq1_, freq, nr11) * env_vol) / 15;
  }
  if (apu_ch2_active_) {  // CH2
    const uint16_t nr21 = ReadIO16(0x04000068u);
    const uint16_t nr23 = ReadIO16(0x0400006Cu);
    const uint16_t nr24 = ReadIO16(0x0400006Du);
    const uint16_t freq = static_cast<uint16_t>(nr23 | ((nr24 & 0x7u) << 8));
    const int env_vol = std::max<int>(0, std::min<int>(15, apu_env_ch2_));
    ch2 = (square_sample(&apu_phase_sq2_, freq, nr21) * env_vol) / 15;
  }
  if (apu_ch3_active_) {  // CH3 wave
    const uint16_t nr30 = ReadIO16(0x04000070u);
    const uint16_t nr32 = ReadIO16(0x04000072u);
    if (nr30 & 0x0080u) {
      const uint16_t nr33 = ReadIO16(0x04000074u);
      const uint16_t nr34 = ReadIO16(0x04000075u);
      const uint16_t n = static_cast<uint16_t>(nr33 | ((nr34 & 0x7u) << 8));
      const uint32_t hz = (2048u > n) ? (65536u / std::max<uint16_t>(1u, static_cast<uint16_t>(2048u - n))) : 0u;
      apu_phase_wave_ += hz * std::max<uint32_t>(1u, cycles);
      const bool two_bank_mode = (nr30 & (1u << 5)) != 0;
      const bool bank_select = (nr30 & (1u << 6)) != 0;
      const uint32_t sample_idx = (apu_phase_wave_ / 2048u) & (two_bank_mode ? 15u : 31u);
      const size_t bank_base = two_bank_mode ? (bank_select ? 16u : 0u) : 0u;
      const size_t wave_off = bank_base + static_cast<size_t>(sample_idx / 2u);
      const uint8_t packed = (wave_off < 32u) ? io_regs_[0x90 + wave_off] : 0;
      uint8_t sample4 = (sample_idx & 1u) ? (packed & 0x0Fu) : (packed >> 4);
      const uint16_t vol_code = (nr32 >> 5) & 0x3u;
      if (vol_code == 0) sample4 = 0;
      else if (vol_code == 2) sample4 >>= 1;
      else if (vol_code == 3) sample4 >>= 2;
      ch3 = static_cast<int>(sample4) * 8 - 60;
    }
  }
  if (apu_ch4_active_) {  // CH4 noise
    const uint16_t nr43 = ReadIO16(0x04000078u);
    const uint32_t div = (nr43 & 0x7u) == 0 ? 8u : (nr43 & 0x7u) * 16u;
    const uint32_t shift = (nr43 >> 4) & 0xFu;
    const uint32_t period = div << shift;
    const bool narrow_7bit = (nr43 & (1u << 3)) != 0;
    for (uint32_t i = 0; i < std::max<uint32_t>(1u, cycles / std::max<uint32_t>(1u, period)); ++i) {
      const uint16_t x = static_cast<uint16_t>((apu_noise_lfsr_ ^ (apu_noise_lfsr_ >> 1)) & 1u);
      apu_noise_lfsr_ = static_cast<uint16_t>((apu_noise_lfsr_ >> 1) | (x << 14));
      if (narrow_7bit) {
        apu_noise_lfsr_ = static_cast<uint16_t>((apu_noise_lfsr_ & ~0x40u) | (x << 6));
      }
    }
    const int env_vol = std::max<int>(0, std::min<int>(15, apu_env_ch4_));
    ch4 = ((apu_noise_lfsr_ & 1u) ? 28 : -28) * env_vol / 15;
  }

  const bool right_ch1 = (soundcnt_l & (1u << 0)) != 0;
  const bool right_ch2 = (soundcnt_l & (1u << 1)) != 0;
  const bool right_ch3 = (soundcnt_l & (1u << 2)) != 0;
  const bool right_ch4 = (soundcnt_l & (1u << 3)) != 0;
  const bool left_ch1 = (soundcnt_l & (1u << 4)) != 0;
  const bool left_ch2 = (soundcnt_l & (1u << 5)) != 0;
  const bool left_ch3 = (soundcnt_l & (1u << 6)) != 0;
  const bool left_ch4 = (soundcnt_l & (1u << 7)) != 0;
  const int right_sum = (right_ch1 ? ch1 : 0) + (right_ch2 ? ch2 : 0) +
                        (right_ch3 ? ch3 : 0) + (right_ch4 ? ch4 : 0);
  const int left_sum = (left_ch1 ? ch1 : 0) + (left_ch2 ? ch2 : 0) +
                       (left_ch3 ? ch3 : 0) + (left_ch4 ? ch4 : 0);

  const int left_vol = (soundcnt_l >> 4) & 0x7;
  const int right_vol = soundcnt_l & 0x7;
  const int psg_master = (soundcnt_h & 0x0003u) == 0 ? 1 : ((soundcnt_h & 0x0003u) == 1 ? 2 : 4);
  int psg_mix = ((left_sum * left_vol) + (right_sum * right_vol)) / 8;
  psg_mix = (psg_mix * psg_master) / 4;

  const int fifo_a_gain = (soundcnt_h & (1u << 2)) ? 2 : 1;
  const int fifo_b_gain = (soundcnt_h & (1u << 3)) ? 2 : 1;
  const bool fifo_a_right = (soundcnt_h & (1u << 8)) != 0;
  const bool fifo_a_left = (soundcnt_h & (1u << 9)) != 0;
  const bool fifo_b_right = (soundcnt_h & (1u << 12)) != 0;
  const bool fifo_b_left = (soundcnt_h & (1u << 13)) != 0;
  const int fifo_right = (fifo_a_right ? fifo_a_last_sample_ * fifo_a_gain : 0) +
                         (fifo_b_right ? fifo_b_last_sample_ * fifo_b_gain : 0);
  const int fifo_left = (fifo_a_left ? fifo_a_last_sample_ * fifo_a_gain : 0) +
                        (fifo_b_left ? fifo_b_last_sample_ * fifo_b_gain : 0);
  const int fifo_mix = (fifo_left + fifo_right) / 2;
  const int mixed = psg_mix + fifo_mix;
  audio_mix_level_ = static_cast<uint16_t>(ClampToByteLocal(mixed) & 0xFFu);
  uint16_t status = 0x0080u;
  if (apu_ch1_active_) status |= 0x0001u;
  if (apu_ch2_active_) status |= 0x0002u;
  if (apu_ch3_active_) status |= 0x0004u;
  if (apu_ch4_active_) status |= 0x0008u;
  soundcnt_x = status;
  io_regs_[0x84] = static_cast<uint8_t>(soundcnt_x & 0xFFu);
  io_regs_[0x85] = static_cast<uint8_t>((soundcnt_x >> 8) & 0xFFu);
}

void GBACore::SyncKeyInputRegister() {
  const uint16_t active_low = static_cast<uint16_t>((~keys_pressed_mask_) & 0x03FFu);
  const size_t keyinput_off = static_cast<size_t>(0x04000130u - 0x04000000u);
  io_regs_[keyinput_off] = static_cast<uint8_t>(active_low & 0xFFu);
  io_regs_[keyinput_off + 1] = static_cast<uint8_t>((active_low >> 8) & 0x03u);

  const uint16_t keycnt = ReadIO16(0x04000132u);
  if ((keycnt & 0x4000u) == 0) return;  // IRQ disabled
  const uint16_t mask = keycnt & 0x03FFu;
  const bool and_mode = (keycnt & 0x8000u) != 0;
  const uint16_t pressed = static_cast<uint16_t>(keys_pressed_mask_ & 0x03FFu);
  const bool hit = and_mode ? ((pressed & mask) == mask) : ((pressed & mask) != 0);
  if (hit) {
    RaiseInterrupt(1u << 12);  // Keypad interrupt
  }
}

void GBACore::RaiseInterrupt(uint16_t mask) {
  const size_t off = static_cast<size_t>(0x04000202u - 0x04000000u);
  const uint16_t if_reg = static_cast<uint16_t>(io_regs_[off]) |
                          (static_cast<uint16_t>(io_regs_[off + 1]) << 8);
  const uint16_t next = static_cast<uint16_t>(if_reg | mask);
  io_regs_[off] = static_cast<uint8_t>(next & 0xFF);
  io_regs_[off + 1] = static_cast<uint8_t>((next >> 8) & 0xFF);
}

// =========================================================================
// EnterException
// FIXED: lr_adjust はベクタアドレスではなく例外モード (new_mode) で判断する。
//
// 旧コード: vector_addr == 0x18 || vector_addr == 0x1C の時のみ lr_adjust=4
//   → カスタム IRQ ベクタ (0x03007FFC の値) を使う場合は vector_addr が
//     ゲームのハンドラアドレスになるため lr_adjust=0 のまま。
//   → LR_irq = PC の代わりに PC+4 になるべきところが PC になり、
//     SUBS PC, LR, #4 で 1命令手前に戻る → 無限ループでROM停止。
//
// 修正: IRQ モード (0x12) / FIQ モード (0x11) なら常に lr_adjust=4。
// =========================================================================
void GBACore::EnterException(uint32_t vector_addr, uint32_t new_mode,
                              bool disable_irq, bool thumb_state) {
  const uint32_t old_cpsr = cpu_.cpsr;
  const uint32_t target_mode = new_mode & 0x1Fu;
  debug_last_exception_vector_ = vector_addr;
  debug_last_exception_pc_     = cpu_.regs[15];
  debug_last_exception_cpsr_   = old_cpsr;

  // FIXED: モードベースで lr_adjust を決定する。
  //   IRQ (0x12) / FIQ (0x11): LR = interrupted PC + 4
  //     実機では SUBS PC, LR, #4 で返るため。
  //   SVC (0x13) / UND (0x1B): LR = 次命令アドレス (呼び出し元が先に +2/+4 済み)
  //     MOVS PC, LR で返るため +4 は不要。
  const uint32_t lr_adjust = (target_mode == 0x12u || target_mode == 0x11u) ? 4u : 0u;

  SwitchCpuMode(target_mode);
  if (HasSpsr(target_mode)) cpu_.spsr[target_mode] = old_cpsr;
  cpu_.regs[14] = cpu_.regs[15] + lr_adjust;

  cpu_.cpsr = (cpu_.cpsr & ~0x1Fu) | target_mode;
  cpu_.active_mode = target_mode;
  if (disable_irq) cpu_.cpsr |= (1u << 7);

  cpu_.cpsr &= ~(1u << 5);  // 例外は常に ARM モードで入る
  cpu_.regs[15] = vector_addr;
  if (CpuExceptionTraceEnabled()) {
    std::fprintf(stderr,
                 "[EXC] vec=%08X mode=%02X old_cpsr=%08X new_cpsr=%08X old_thumb=%u lr=%08X pc=%08X\n",
                 vector_addr, target_mode, old_cpsr, cpu_.cpsr,
                 thumb_state ? 1u : 0u, cpu_.regs[14], cpu_.regs[15]);
  }
}

// =========================================================================
// ServiceInterruptIfNeeded
// =========================================================================
void GBACore::ServiceInterruptIfNeeded() {
  const uint16_t ie     = ReadIO16(0x04000200u);
  const uint16_t iflags = ReadIO16(0x04000202u);
  const uint16_t pending = static_cast<uint16_t>(ie & iflags);

  if (pending != 0) {
    cpu_.halted = false;  // 有効な割り込みが保留中なら常にHALTを解除
  }

  const uint16_t ime = ReadIO16(0x04000208u) & 0x1u;
  if (ime == 0) return;
  if (cpu_.cpsr & (1u << 7)) return;  // I フラグがセットされている
  if (pending == 0) return;

  // BIOS スタイルの IRQ フラグミラーを IWRAM に保持
  const uint32_t irq_flags_addr  = 0x03007FF8u;
  const uint32_t old_irq_flags   = Read32(irq_flags_addr);
  Write32(irq_flags_addr, old_irq_flags | pending);

  // BIOS ベクタ起動中は BIOS IRQ ハンドラ (0x18) へ
  const bool use_bios_irq = bios_loaded_ && bios_boot_via_vector_;
  if (use_bios_irq) {
    EnterException(0x00000018u, 0x12u, true, false);
    return;
  }

  // カスタム IRQ ベクタ (0x03007FFC が指すアドレス) を使用
  const uint32_t irq_vector   = Read32(0x03007FFCu);
  const bool     vector_thumb = (irq_vector & 1u) != 0;
  const uint32_t vector_addr  = irq_vector & ~1u;
  const bool     vector_valid = (vector_addr >= 0x02000000u && vector_addr <= 0x0DFFFFFFu);
  if (vector_valid) {
    EnterException(vector_addr, 0x12u, true, vector_thumb);
    if (vector_thumb) {
      // Thumb IRQ ハンドラ: CPSR の Thumb ビットを再セット
      cpu_.cpsr      |= (1u << 5);
      cpu_.regs[15]   = vector_addr;  // EnterException が ARM モードにした後に戻す
    }
    return;
  }
  // vector_addr が無効な場合は IRQ を取れないが IF は保持したまま次回へ
}

}  // namespace gba
