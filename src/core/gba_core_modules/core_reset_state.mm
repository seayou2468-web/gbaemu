#include "../gba_core.h"

#include <algorithm>

namespace gba {

void GBACore::Reset() {
  frame_count_ = 0;
  executed_cycles_ = 0;
  open_bus_latch_ = 0;
  keys_pressed_mask_ = 0;
  previous_keys_mask_ = 0;
  std::fill(ewram_.begin(), ewram_.end(), 0);
  std::fill(iwram_.begin(), iwram_.end(), 0);
  std::fill(io_regs_.begin(), io_regs_.end(), 0);
  std::fill(palette_ram_.begin(), palette_ram_.end(), 0);
  std::fill(vram_.begin(), vram_.end(), 0);
  std::fill(oam_.begin(), oam_.end(), 0);
  std::fill(sram_.begin(), sram_.end(), 0xFF);
  std::fill(eeprom_.begin(), eeprom_.end(), 0xFF);
  std::fill(flash_bank1_.begin(), flash_bank1_.end(), 0xFF);
  ResetBackupControllerState();
  timers_ = {};
  affine_line_refs_valid_ = false;
  bg2_refx_line_.fill(0);
  bg2_refy_line_.fill(0);
  bg3_refx_line_.fill(0);
  bg3_refy_line_.fill(0);
  affine_line_captured_.fill(0);
  dma_was_in_vblank_ = false;
  dma_was_in_hblank_ = false;
  dma_fifo_a_request_ = false;
  dma_fifo_b_request_ = false;
  ppu_cycle_accum_ = 0;
  audio_mix_level_ = 0;
  fifo_a_.clear();
  fifo_b_.clear();
  fifo_a_last_sample_ = 0;
  fifo_b_last_sample_ = 0;
  apu_phase_sq1_ = 0;
  apu_phase_sq2_ = 0;
  apu_phase_wave_ = 0;
  apu_noise_lfsr_ = 0x7FFFu;
  apu_frame_seq_cycles_ = 0;
  apu_frame_seq_step_ = 0;
  apu_env_ch1_ = 0;
  apu_env_ch2_ = 0;
  apu_env_ch4_ = 0;
  apu_env_timer_ch1_ = 0;
  apu_env_timer_ch2_ = 0;
  apu_env_timer_ch4_ = 0;
  apu_len_ch1_ = 0;
  apu_len_ch2_ = 0;
  apu_len_ch3_ = 0;
  apu_len_ch4_ = 0;
  apu_ch1_sweep_freq_ = 0;
  apu_ch1_sweep_timer_ = 0;
  apu_ch1_sweep_enabled_ = false;
  apu_ch1_active_ = false;
  apu_ch2_active_ = false;
  apu_ch3_active_ = false;
  apu_ch4_active_ = false;
  apu_prev_trig_ch1_ = apu_prev_trig_ch2_ = apu_prev_trig_ch3_ = apu_prev_trig_ch4_ = false;
  swi_intrwait_active_ = false;
  swi_intrwait_mask_ = 0;
  bios_fetch_latch_ = 0;
  open_bus_latch_ = 0;
  // Prefer true BIOS-vector boot when a real external BIOS is loaded.
  // Built-in BIOS remains HLE/direct-boot oriented.
  const bool use_real_bios_boot = bios_loaded_ && !bios_is_builtin_;
  cpu_ = CpuState{};
  cpu_.banked_fiq_r8_r12.fill(0);
  if (use_real_bios_boot) {
    // Hardware reset: SVC mode, IRQ/FIQ disabled, ARM state.
    cpu_.cpsr = 0x000000D3u;
    cpu_.active_mode = cpu_.cpsr & 0x1Fu;
    cpu_.regs[13] = 0;
    cpu_.regs[14] = 0;
  } else {
    cpu_.active_mode = cpu_.cpsr & 0x1Fu;
    // Direct-boot baseline matching post-BIOS SoftReset state.
    cpu_.banked_sp[0x13u] = 0x03007FE0u;  // SVC
    cpu_.banked_sp[0x12u] = 0x03007FA0u;  // IRQ
    cpu_.banked_sp[0x1Fu] = 0x03007F00u;  // SYS
    cpu_.banked_lr[0x13u] = 0;
    cpu_.banked_lr[0x12u] = 0;
    cpu_.regs[13] = cpu_.banked_sp[0x1Fu];
    cpu_.regs[14] = 0;
  }
  bios_boot_via_vector_ = use_real_bios_boot;
  bios_boot_watchdog_frames_ = 0;
  halt_watchdog_frames_ = 0;
  cpu_.regs[15] = use_real_bios_boot ? 0x00000000u : 0x08000000u;
  // DISPCNT reset defaults:
  // - Real BIOS boot starts in forced blank.
  // - Direct-boot/HLE starts with forced blank cleared.
  WriteIO16(0x04000000u, use_real_bios_boot ? 0x0080u : 0x0000u);
  // Affine defaults: unit matrix (hardware boot state expectation for many
  // direct-boot test ROMs that don't initialize these explicitly).
  WriteIO16(0x04000020u, 0x0100u);  // BG2PA
  WriteIO16(0x04000022u, 0x0000u);  // BG2PB
  WriteIO16(0x04000024u, 0x0000u);  // BG2PC
  WriteIO16(0x04000026u, 0x0100u);  // BG2PD
  WriteIO16(0x04000030u, 0x0100u);  // BG3PA
  WriteIO16(0x04000032u, 0x0000u);  // BG3PB
  WriteIO16(0x04000034u, 0x0000u);  // BG3PC
  WriteIO16(0x04000036u, 0x0100u);  // BG3PD
  if (use_real_bios_boot) {
    // BIOS flow starts from line 0 baseline.
    WriteIO16(0x04000006u, 0x0000u);
    ppu_cycle_accum_ = 0;
  } else {
    // Align direct-boot timing with mGBA skip-BIOS baseline:
    // VCOUNT starts near line 0x7E and first scanline edge arrives shortly after.
    WriteIO16(0x04000006u, 0x007Eu);
    ppu_cycle_accum_ = mgba_compat::kVideoHDrawCycles - 117u;
  }
  // KEYINPUT: all released (active low)
  WriteIO16(0x04000130u, 0x03FFu);
  // IE/IF/IME
  WriteIO16(0x04000200u, 0x0000u);
  WriteIO16(0x04000202u, 0x0000u);
  WriteIO16(0x04000208u, 0x0001u);
  // POSTFLG: 0 during BIOS flow, 1 when skipping to cartridge entry.
  Write8(0x04000300u, use_real_bios_boot ? 0x00u : 0x01u);
  SyncKeyInputRegister();
  gameplay_state_ = GameplayState{};
  frame_buffer_.assign(kScreenWidth * kScreenHeight, 0xFF000000U);
  RenderDebugFrame();
}

void GBACore::LoadSaveRAM(const std::vector<uint8_t>& data) {
  ImportBackupData(data);
}

std::vector<uint8_t> GBACore::ExportBackupData() const {
  if (backup_type_ == BackupType::kEEPROM) {
    return std::vector<uint8_t>(eeprom_.begin(), eeprom_.end());
  }
  if (backup_type_ == BackupType::kFlash128K) {
    std::vector<uint8_t> out;
    out.reserve(128 * 1024);
    out.insert(out.end(), sram_.begin(), sram_.end());
    out.insert(out.end(), flash_bank1_.begin(), flash_bank1_.end());
    return out;
  }
  return std::vector<uint8_t>(sram_.begin(), sram_.end());
}

void GBACore::ImportBackupData(const std::vector<uint8_t>& data) {
  if (backup_type_ == BackupType::kEEPROM) {
    const size_t copy_size = std::min(data.size(), eeprom_.size());
    std::copy_n(data.begin(), copy_size, eeprom_.begin());
    if (copy_size < eeprom_.size()) {
      std::fill(eeprom_.begin() + static_cast<std::ptrdiff_t>(copy_size), eeprom_.end(), 0xFF);
    }
    return;
  }

  if (backup_type_ == BackupType::kFlash128K) {
    const size_t bank_size = sram_.size();
    const size_t copy0 = std::min(bank_size, data.size());
    std::copy_n(data.begin(), copy0, sram_.begin());
    if (copy0 < bank_size) {
      std::fill(sram_.begin() + static_cast<std::ptrdiff_t>(copy0), sram_.end(), 0xFF);
    }
    if (data.size() > bank_size) {
      const size_t copy1 = std::min(bank_size, data.size() - bank_size);
      std::copy_n(data.begin() + static_cast<std::ptrdiff_t>(bank_size), copy1, flash_bank1_.begin());
      if (copy1 < bank_size) {
        std::fill(flash_bank1_.begin() + static_cast<std::ptrdiff_t>(copy1), flash_bank1_.end(), 0xFF);
      }
    } else {
      std::fill(flash_bank1_.begin(), flash_bank1_.end(), 0xFF);
    }
    return;
  }

  const size_t copy_size = std::min(data.size(), sram_.size());
  std::copy_n(data.begin(), copy_size, sram_.begin());
  if (copy_size < sram_.size()) {
    std::fill(sram_.begin() + static_cast<std::ptrdiff_t>(copy_size), sram_.end(), 0xFF);
  }
}

}  // namespace gba
