#include "../gba_core.h"
#include <algorithm>

namespace gba {

namespace {
constexpr uint8_t kNintendoLogoLocal[156] = {
    0x24,0xFF,0xAE,0x51,0x69,0x9A,0xA2,0x21,0x3D,0x84,0x82,0x0A,0x84,0xE4,0x09,0xAD,
    0x11,0x24,0x8B,0x98,0xC0,0x81,0x7F,0x21,0xA3,0x52,0xBE,0x19,0x93,0x09,0xCE,0x20,
    0x10,0x46,0x4A,0x4A,0xF8,0x27,0x31,0xEC,0x58,0xC7,0xE8,0x33,0x82,0xE3,0xCE,0xBF,
    0x85,0xF4,0xDF,0x94,0xCE,0x4B,0x09,0xC1,0x94,0x56,0x8A,0xC0,0x13,0x72,0xA7,0xFC,
    0x9F,0x84,0x4D,0x73,0xA3,0xCA,0x9A,0x61,0x58,0x97,0xA3,0x27,0xFC,0x03,0x98,0x76,
    0x23,0x1D,0xC7,0x61,0x03,0x04,0xAE,0x56,0xBF,0x38,0x84,0x00,0x40,0xA7,0x0E,0xFD,
    0xFF,0x52,0xFE,0x03,0x6F,0x95,0x30,0xF1,0x97,0xFB,0xC0,0x85,0x60,0xD6,0x80,0x25,
    0xA9,0x63,0xBE,0x03,0x01,0x4E,0x38,0xE2,0xF9,0xA2,0x34,0xFF,0xBB,0x3E,0x03,0x44,
    0x78,0x00,0x90,0xCB,0x88,0x11,0x3A,0x94,0x65,0xC0,0x7C,0x63,0x87,0xF0,0x3C,0xAF,
    0xD6,0x25,0xE4,0x8B,0x38,0x0A,0xAC,0x72,0x21,0xD4,0xF8,0x07,
};
}  // namespace

// =========================================================================
// 繝舌ャ繧ｯ繧｢繝・・蛻ｶ蠕｡繝ｪ繧ｻ繝・ヨ
// =========================================================================
void GBACore::ResetBackupControllerState() {
  flash_mode_unlocked_    = false;
  flash_command_          = 0;
  flash_id_mode_          = false;
  flash_program_mode_     = false;
  flash_bank_switch_mode_ = false;
  debug_last_exception_vector_ = 0;
  debug_last_exception_pc_     = 0;
  debug_last_exception_cpsr_   = 0;
  flash_bank_             = 0;
  eeprom_cmd_bits_.clear();
  eeprom_read_bits_.clear();
  eeprom_read_pos_        = 0;
  eeprom_addr_bits_       = 0;
}

// =========================================================================
// 繝舌ャ繧ｯ繧｢繝・・ 隱ｭ縺ｿ蜿悶ｊ
// =========================================================================
uint8_t GBACore::ReadBackup8(uint32_t addr) const {
  if (backup_type_ == BackupType::kEEPROM) {
    if (eeprom_read_pos_ < eeprom_read_bits_.size()) {
      const uint8_t bit = eeprom_read_bits_[eeprom_read_pos_++] & 1u;
      if (eeprom_read_pos_ >= eeprom_read_bits_.size()) {
        eeprom_read_bits_.clear();
        eeprom_read_pos_ = 0;
      }
      return static_cast<uint8_t>(0xFEu | bit);
    }
    return 0xFFu;
  }

  const uint32_t off32 = (addr - 0x0E000000u) & 0xFFFFu;

  // Flash ID繝｢繝ｼ繝・
  if ((backup_type_ == BackupType::kFlash64K || backup_type_ == BackupType::kFlash128K)
      && flash_id_mode_) {
    if (off32 == 0) return 0xBFu;  // Sanyo陬ｽ騾閠・D
    if (off32 == 1) return (backup_type_ == BackupType::kFlash128K) ? 0x09u : 0xD4u;
  }

  const size_t idx = static_cast<size_t>(off32 % sram_.size());
  if (backup_type_ == BackupType::kFlash128K && flash_bank_ == 1u)
    return flash_bank1_[idx];
  return sram_[idx];
}

// =========================================================================
// 繝舌ャ繧ｯ繧｢繝・・ 譖ｸ縺崎ｾｼ縺ｿ
// =========================================================================
void GBACore::WriteBackup8(uint32_t addr, uint8_t value) {
  if (backup_type_ == BackupType::kEEPROM) {
    eeprom_cmd_bits_.push_back(value & 1u);
    if (eeprom_cmd_bits_.size() > 90u) { eeprom_cmd_bits_.clear(); return; }

    auto try_decode = [&](uint32_t addr_bits) -> bool {
      const size_t write_len = 2u + addr_bits + 64u + 1u;
      const size_t read_len  = 2u + addr_bits + 1u;
      const size_t block_bytes = 8u;
      const size_t max_blocks = eeprom_.size() / block_bytes;

      if (eeprom_cmd_bits_.size() == write_len) {
        if (eeprom_cmd_bits_[0] == 1u && eeprom_cmd_bits_[1] == 0u) {
          uint32_t block_addr = 0;
          for (uint32_t i = 0; i < addr_bits; ++i)
            block_addr = (block_addr << 1u) | (eeprom_cmd_bits_[2u+i] & 1u);
          const size_t block = block_addr % std::max<size_t>(1u, max_blocks);
          const size_t base  = block * block_bytes;
          for (size_t i = 0; i < block_bytes; ++i) {
            uint8_t out = 0;
            for (int b = 0; b < 8; ++b)
              out = static_cast<uint8_t>((out << 1u) | (eeprom_cmd_bits_[2u+addr_bits+i*8u+b] & 1u));
            eeprom_[base+i] = out;
          }
          eeprom_addr_bits_ = static_cast<uint8_t>(addr_bits);
          eeprom_read_bits_.assign(9, 0); eeprom_read_bits_[8] = 1;
          eeprom_cmd_bits_.clear();
          return true;
        }
      }
      if (eeprom_cmd_bits_.size() == read_len) {
        if (eeprom_cmd_bits_[0] == 1u && eeprom_cmd_bits_[1] == 1u) {
          uint32_t block_addr = 0;
          for (uint32_t i = 0; i < addr_bits; ++i)
            block_addr = (block_addr << 1u) | (eeprom_cmd_bits_[2u+i] & 1u);
          eeprom_addr_bits_ = static_cast<uint8_t>(addr_bits);
          const size_t block = block_addr % std::max<size_t>(1u, max_blocks);
          const size_t base  = block * block_bytes;
          eeprom_read_bits_.clear();
          for (int i = 0; i < 4; ++i) eeprom_read_bits_.push_back(0);  // dummy
          for (size_t i = 0; i < block_bytes; ++i) {
            const uint8_t byte = eeprom_[base+i];
            for (int b = 7; b >= 0; --b)
              eeprom_read_bits_.push_back(static_cast<uint8_t>((byte >> b) & 1u));
          }
          eeprom_read_pos_ = 0;
          eeprom_cmd_bits_.clear();
          return true;
        }
      }
      return false;
    };

    if      (eeprom_addr_bits_ == 6u)  { try_decode(6u); }
    else if (eeprom_addr_bits_ == 14u) { try_decode(14u); }
    else { try_decode(14u) || try_decode(6u); }
    return;
  }

  const uint32_t off32 = (addr - 0x0E000000u) & 0xFFFFu;
  const size_t off = static_cast<size_t>(off32 % sram_.size());

  // SRAM / unknown
  if (backup_type_ != BackupType::kFlash64K && backup_type_ != BackupType::kFlash128K) {
    sram_[off] = value;
    return;
  }

  // Flash 繝励Ο繧ｰ繝ｩ繝繝｢繝ｼ繝・
  if (flash_program_mode_) {
    auto& target = (backup_type_ == BackupType::kFlash128K && flash_bank_ == 1u)
                   ? flash_bank1_ : sram_;
    target[off] = static_cast<uint8_t>(target[off] & value);  // NOR: 1竊・縺ｮ縺ｿ
    flash_program_mode_ = false;
    return;
  }
  // 繝舌Φ繧ｯ蛻・ｊ譖ｿ縺医Δ繝ｼ繝・
  if (flash_bank_switch_mode_) {
    flash_bank_ = static_cast<uint8_t>(value & 1u);
    flash_bank_switch_mode_ = false;
    return;
  }

  // Flash 繧ｳ繝槭Φ繝峨す繝ｼ繧ｱ繝ｳ繧ｹ
  if (!flash_mode_unlocked_) {
    if (off32 == 0x5555u && value == 0xAAu) { flash_mode_unlocked_ = true; flash_command_ = 1; }
    return;
  }
  if (flash_command_ == 1) {
    if (off32 == 0x2AAAu && value == 0x55u) { flash_command_ = 2; }
    else ResetBackupControllerState();
    return;
  }
  if (flash_command_ == 2 && off32 == 0x5555u) {
    flash_mode_unlocked_ = false; flash_command_ = 0;
    if      (value == 0x90u) { flash_id_mode_ = true; }
    else if (value == 0xF0u) { flash_id_mode_ = false; }
    else if (value == 0xA0u) { flash_program_mode_ = true; }
    else if (value == 0xB0u && backup_type_ == BackupType::kFlash128K) { flash_bank_switch_mode_ = true; }
    else if (value == 0x80u) { flash_command_ = 3; flash_mode_unlocked_ = true; }
    else ResetBackupControllerState();
    return;
  }
  // 繧､繝ｬ繝ｼ繧ｹ繧ｷ繝ｼ繧ｱ繝ｳ繧ｹ
  if (flash_command_ == 3) {
    if (off32 == 0x5555u && value == 0xAAu) { flash_command_ = 4; }
    else ResetBackupControllerState();
    return;
  }
  if (flash_command_ == 4) {
    if (off32 == 0x2AAAu && value == 0x55u) { flash_command_ = 5; }
    else ResetBackupControllerState();
    return;
  }
  if (flash_command_ == 5) {
    if (value == 0x10u && off32 == 0x5555u) {
      std::fill(sram_.begin(), sram_.end(), 0xFFu);
      if (backup_type_ == BackupType::kFlash128K)
        std::fill(flash_bank1_.begin(), flash_bank1_.end(), 0xFFu);
    } else if (value == 0x30u) {
      const size_t sector_base = off & ~static_cast<size_t>(0x0FFFu);
      const size_t sector_end  = std::min(sector_base + 0x1000u, sram_.size());
      auto& target = (backup_type_ == BackupType::kFlash128K && flash_bank_ == 1u)
                     ? flash_bank1_ : sram_;
      std::fill(target.begin() + static_cast<std::ptrdiff_t>(sector_base),
                target.begin() + static_cast<std::ptrdiff_t>(sector_end), 0xFFu);
    }
    ResetBackupControllerState();
    return;
  }
  ResetBackupControllerState();
}

// =========================================================================
// RunCycles - 繧ｹ繧ｱ繧ｸ繝･繝ｼ繝ｩ繝｡繧､繝ｳ繝ｫ繝ｼ繝・// 鬆・ｺ・ CPU 竊・Timers 竊・APU 竊・PPU (蜷・せ繝ｩ繧､繧ｹ)
// =========================================================================
void GBACore::RunCycles(uint32_t cycles) {
  if (!loaded_) return;

  // Keep hardware side effects close to the instruction that triggered them.
  // Large batches skew timer/DMA state because IO writes become visible only
  // after the whole CPU slice completes.
  const uint32_t kSlice = 1u;

  uint32_t remaining = cycles;
  while (remaining > 0u) {
    const uint32_t requested = std::min(remaining, kSlice);

    // CPU螳溯｡・(HALT縺ｪ繧牙叉譎ょ叉譎ゅΜ繧ｿ繝ｼ繝ｳ)
    uint32_t elapsed = RunCpuSlice(requested);
    if (elapsed == 0u) elapsed = requested;
    executed_cycles_ += elapsed;

    // 繧ｿ繧､繝槭・譖ｴ譁ｰ
    StepTimers(elapsed);

    // APU譖ｴ譁ｰ
    StepApu(elapsed);
    StepSio(elapsed);

    // PPU譖ｴ譁ｰ (HBlank/VBlank 繧､繝吶Φ繝育匱轣ｫ繧貞性繧)
    StepPpu(elapsed);

    // 蜊ｳ譎・MA (start_timing=0)
    StepDma();

    remaining = (elapsed >= remaining) ? 0u : (remaining - elapsed);
  }
}

// =========================================================================
// SetKeys
// =========================================================================
void GBACore::SetKeys(uint16_t keys_pressed_mask) {
  keys_pressed_mask_ = keys_pressed_mask;
  SyncKeyInputRegister();
}

// =========================================================================
// StepFrame - 1繝輔Ξ繝ｼ繝蛻・ｮ溯｡後＠縺ｦ繝ｬ繝ｳ繝繝ｪ繝ｳ繧ｰ
// =========================================================================
void GBACore::StepFrame() {
  if (!loaded_) return;
  frame_rendered_in_vblank_ = false;
  bg_scroll_line_valid_ = false;
  bg_affine_params_line_valid_ = false;
  RunCycles(kCyclesPerFrame);
  ++frame_count_;

  // BIOS襍ｷ蜍募ｮ御ｺ・､懷・
  if (bios_boot_via_vector_) {
    if (cpu_.regs[15] >= 0x08000000u) {
      bios_boot_via_vector_   = false;
      bios_boot_watchdog_frames_ = 0;
      Write8(0x04000300u, 0x01u);  // POSTFLG=1
    } else {
      ++bios_boot_watchdog_frames_;
      // 繧ｦ繧ｩ繝・メ繝峨ャ繧ｰ: 300繝輔Ξ繝ｼ繝莉･荳械IOS縺九ｉ蜃ｺ縺ｪ縺・ｴ蜷医・蠑ｷ蛻ｶ邨ゆｺ・
      if (bios_boot_watchdog_frames_ > 300u) {
        bios_boot_via_vector_ = false;
        cpu_.regs[15] = 0x08000000u;
        Write8(0x04000300u, 0x01u);
      }
    }
  }

  // HALT 繧ｦ繧ｩ繝・メ繝峨ャ繧ｰ: 蜑ｲ繧願ｾｼ縺ｿ縺ｪ縺礼┌髯食ALT繧帝亟縺・
  if (!bios_boot_via_vector_ && cpu_.halted) {
    const uint16_t ie     = ReadIO16(0x04000200u);
    const uint16_t iflags = ReadIO16(0x04000202u);
    const uint16_t ime    = static_cast<uint16_t>(ReadIO16(0x04000208u) & 1u);
    if (ime == 0u || (ie & iflags) == 0u) {
      ++halt_watchdog_frames_;
      if (halt_watchdog_frames_ > 120u) {
        cpu_.halted          = false;
        swi_intrwait_active_ = false;
        swi_intrwait_mask_   = 0;
        halt_watchdog_frames_ = 0;
      }
    } else {
      halt_watchdog_frames_ = 0;
    }
  } else {
    halt_watchdog_frames_ = 0;
  }

  UpdateGameplayFromInput();
  if (!frame_rendered_in_vblank_) {
    // Fallback path: if this frame didn't cross VBlank boundary in StepPpu,
    // render from current state.
    RenderDebugFrame();
  }
}

// =========================================================================
// ROM繝倥ャ繝陬懷ｮ後メ繧ｧ繝・け險育ｮ・
// =========================================================================
uint8_t GBACore::ComputeComplementCheck() const {
  int sum = 0;
  for (size_t i = 0xA0; i <= 0xBC && i < rom_.size(); ++i)
    sum += rom_[i];
  return static_cast<uint8_t>((-sum - 0x19) & 0xFF);
}

// =========================================================================
// Nintendo繝ｭ繧ｴ讀懆ｨｼ
// =========================================================================
bool GBACore::ValidateNintendoLogo() const {
  if (rom_.size() < 0xA0u) return false;
  for (size_t i = 0; i < sizeof(kNintendoLogoLocal); ++i) {
    if (rom_[0x04 + i] != kNintendoLogoLocal[i]) return false;
  }
  return true;
}

// =========================================================================
// 繧ｲ繝ｼ繝繝励Ξ繧､迥ｶ諷区峩譁ｰ (繝・Δ逕ｨ)
// =========================================================================
void GBACore::UpdateGameplayFromInput() {
  constexpr int kStep = 2;
  const uint16_t pressed_edge = static_cast<uint16_t>(keys_pressed_mask_ & ~previous_keys_mask_);

  if (keys_pressed_mask_ & kKeyRight) gameplay_state_.player_x += kStep;
  if (keys_pressed_mask_ & kKeyLeft)  gameplay_state_.player_x -= kStep;
  if (keys_pressed_mask_ & kKeyDown)  gameplay_state_.player_y += kStep;
  if (keys_pressed_mask_ & kKeyUp)    gameplay_state_.player_y -= kStep;

  gameplay_state_.player_x = std::clamp(gameplay_state_.player_x, 0, kScreenWidth - 1);
  gameplay_state_.player_y = std::clamp(gameplay_state_.player_y, 0, kScreenHeight - 1);

  if (keys_pressed_mask_ & kKeyA)  gameplay_state_.score += 3;
  if (keys_pressed_mask_ & kKeyB)  gameplay_state_.score += 1;
  if (keys_pressed_mask_ & kKeyR)  gameplay_state_.score += 2;
  if (keys_pressed_mask_ & kKeyL)  gameplay_state_.score += 2;
  if (pressed_edge & kKeyStart)    gameplay_state_.score += 5;
  if ((pressed_edge & kKeySelect) && gameplay_state_.score > 0) --gameplay_state_.score;

  if ((keys_pressed_mask_ & kKeyA) && (keys_pressed_mask_ & kKeyB)) {
    ++gameplay_state_.combo;
    gameplay_state_.score += 2;
  } else {
    gameplay_state_.combo = 0;
  }

  if (gameplay_state_.player_x >= kScreenWidth  - 20) gameplay_state_.checkpoints |= 0x1u;
  if (gameplay_state_.player_y >= kScreenHeight - 15) gameplay_state_.checkpoints |= 0x2u;
  if (gameplay_state_.player_x <= 20)                 gameplay_state_.checkpoints |= 0x4u;
  if (gameplay_state_.player_y <= 15)                 gameplay_state_.checkpoints |= 0x8u;

  if (gameplay_state_.checkpoints == 0x0Fu &&
      gameplay_state_.score >= 300u &&
      frame_count_ >= 180u) {
    gameplay_state_.cleared = true;
  }
  previous_keys_mask_ = keys_pressed_mask_;
}

}  // namespace gba
