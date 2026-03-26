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


void GBACore::ResetBackupControllerState() {
  flash_mode_unlocked_ = false;
  flash_command_ = 0;
  flash_id_mode_ = false;
  flash_program_mode_ = false;
  flash_bank_switch_mode_ = false;
  debug_last_exception_vector_ = 0;
  debug_last_exception_pc_ = 0;
  debug_last_exception_cpsr_ = 0;
  flash_bank_ = 0;
  eeprom_cmd_bits_.clear();
  eeprom_read_bits_.clear();
  eeprom_read_pos_ = 0;
}

uint8_t GBACore::ReadBackup8(uint32_t addr) const {
  if (backup_type_ == BackupType::kEEPROM) {
    if (eeprom_read_pos_ < eeprom_read_bits_.size()) {
      const uint8_t bit = static_cast<uint8_t>(eeprom_read_bits_[eeprom_read_pos_++] & 1u);
      if (eeprom_read_pos_ >= eeprom_read_bits_.size()) {
        eeprom_read_bits_.clear();
        eeprom_read_pos_ = 0;
      }
      return static_cast<uint8_t>(0xFEu | bit);
    }
    return 0xFFu;
  }

  const uint32_t off32 = (addr - 0x0E000000u) & 0xFFFFu;
  if ((backup_type_ == BackupType::kFlash64K || backup_type_ == BackupType::kFlash128K) && flash_id_mode_) {
    if (off32 == 0) return 0xBF;  // Sanyo/Panasonic style manufacturer id (common)
    if (off32 == 1) return (backup_type_ == BackupType::kFlash128K) ? 0x09u : 0xD4u;
  }
  const size_t idx = static_cast<size_t>(off32 % sram_.size());
  if (backup_type_ == BackupType::kFlash128K && flash_bank_ == 1u) {
    return flash_bank1_[idx];
  }
  return sram_[idx];
}

void GBACore::WriteBackup8(uint32_t addr, uint8_t value) {
  if (backup_type_ == BackupType::kEEPROM) {
    const uint8_t bit = static_cast<uint8_t>(value & 1u);
    eeprom_cmd_bits_.push_back(bit);
    auto reset_cmd = [&]() {
      eeprom_cmd_bits_.clear();
    };
    auto load_read_bits = [&](uint32_t block_addr, uint32_t addr_bits) {
      eeprom_read_bits_.clear();
      eeprom_read_pos_ = 0;
      for (int i = 0; i < 4; ++i) eeprom_read_bits_.push_back(0);  // dummy bits
      const size_t block_bytes = 8;
      const size_t max_blocks = eeprom_.size() / block_bytes;
      const size_t block = static_cast<size_t>(block_addr % std::max<uint32_t>(1, static_cast<uint32_t>(max_blocks)));
      const size_t base = block * block_bytes;
      (void)addr_bits;
      for (size_t i = 0; i < block_bytes; ++i) {
        const uint8_t byte = eeprom_[base + i];
        for (int b = 7; b >= 0; --b) {
          eeprom_read_bits_.push_back(static_cast<uint8_t>((byte >> b) & 1u));
        }
      }
    };
    auto try_decode = [&](uint32_t addr_bits) -> bool {
      const size_t write_len = 2u + addr_bits + 64u + 1u;
      const size_t read_len = 2u + addr_bits + 1u;
      if (eeprom_cmd_bits_.size() == write_len) {
        const uint8_t op0 = eeprom_cmd_bits_[0];
        const uint8_t op1 = eeprom_cmd_bits_[1];
        if (op0 == 1u && op1 == 0u) {  // write
          uint32_t block_addr = 0;
          for (uint32_t i = 0; i < addr_bits; ++i) {
            block_addr = (block_addr << 1u) | static_cast<uint32_t>(eeprom_cmd_bits_[2u + i] & 1u);
          }
          const size_t block_bytes = 8;
          const size_t max_blocks = eeprom_.size() / block_bytes;
          const size_t block = static_cast<size_t>(block_addr % std::max<uint32_t>(1, static_cast<uint32_t>(max_blocks)));
          const size_t base = block * block_bytes;
          for (size_t i = 0; i < block_bytes; ++i) {
            uint8_t out = 0;
            for (int b = 0; b < 8; ++b) {
              const size_t bit_idx = 2u + addr_bits + (i * 8u) + static_cast<size_t>(b);
              out = static_cast<uint8_t>((out << 1u) | (eeprom_cmd_bits_[bit_idx] & 1u));
            }
            eeprom_[base + i] = out;
          }
          reset_cmd();
          return true;
        }
      }
      if (eeprom_cmd_bits_.size() == read_len) {
        const uint8_t op0 = eeprom_cmd_bits_[0];
        const uint8_t op1 = eeprom_cmd_bits_[1];
        if (op0 == 1u && op1 == 1u) {  // read
          uint32_t block_addr = 0;
          for (uint32_t i = 0; i < addr_bits; ++i) {
            block_addr = (block_addr << 1u) | static_cast<uint32_t>(eeprom_cmd_bits_[2u + i] & 1u);
          }
          load_read_bits(block_addr, addr_bits);
          reset_cmd();
          return true;
        }
      }
      return false;
    };

    if (eeprom_cmd_bits_.size() > 90u) {
      reset_cmd();
      return;
    }
    if (try_decode(6u) || try_decode(14u)) {
      return;
    }
    return;
  }

  const uint32_t off32 = (addr - 0x0E000000u) & 0xFFFFu;
  const size_t off = static_cast<size_t>(off32 % sram_.size());

  // SRAM/unknown/eeprom fallback: raw byte write model.
  if (backup_type_ != BackupType::kFlash64K && backup_type_ != BackupType::kFlash128K) {
    sram_[off] = value;
    return;
  }

  if (flash_program_mode_) {
    // NOR flash programming behavior: only 1->0 transitions.
    auto& target = (backup_type_ == BackupType::kFlash128K && flash_bank_ == 1u) ? flash_bank1_ : sram_;
    target[off] = static_cast<uint8_t>(target[off] & value);
    flash_program_mode_ = false;
    return;
  }

  if (flash_bank_switch_mode_) {
    flash_bank_ = static_cast<uint8_t>(value & 0x1u);
    flash_bank_switch_mode_ = false;
    return;
  }

  // Flash command prefix: AA to 0x5555 then 55 to 0x2AAA.
  if (!flash_mode_unlocked_) {
    if (off32 == 0x5555u && value == 0xAAu) {
      flash_mode_unlocked_ = true;
      flash_command_ = 1;
      return;
    }
    // Non-command byte writes are ignored while not in program mode.
    return;
  }

  if (flash_command_ == 1) {
    if (off32 == 0x2AAAu && value == 0x55u) {
      flash_command_ = 2;
      return;
    }
    ResetBackupControllerState();
    return;
  }

  // third step command byte at 0x5555.
  if (flash_command_ == 2 && off32 == 0x5555u) {
    if (value == 0x90u) {
      flash_id_mode_ = true;
      flash_mode_unlocked_ = false;
      flash_command_ = 0;
      return;
    }
    if (value == 0xF0u) {
      flash_id_mode_ = false;
      flash_mode_unlocked_ = false;
      flash_command_ = 0;
      return;
    }
    if (value == 0xA0u) {
      flash_program_mode_ = true;
      flash_mode_unlocked_ = false;
      flash_command_ = 0;
      return;
    }
    if (value == 0xB0u && backup_type_ == BackupType::kFlash128K) {
      flash_bank_switch_mode_ = true;
      flash_mode_unlocked_ = false;
      flash_command_ = 0;
      return;
    }
    if (value == 0x80u) {
      // Erase setup done; wait for 2nd unlock + erase command.
      flash_command_ = 3;
      return;
    }
    ResetBackupControllerState();
    return;
  }

  // Erase flow: AA 55 80 AA 55 (30 sector / 10 chip)
  if (flash_command_ == 3) {
    if (off32 == 0x5555u && value == 0xAAu) {
      flash_command_ = 4;
      return;
    }
    ResetBackupControllerState();
    return;
  }
  if (flash_command_ == 4) {
    if (off32 == 0x2AAAu && value == 0x55u) {
      flash_command_ = 5;
      return;
    }
    ResetBackupControllerState();
    return;
  }
  if (flash_command_ == 5) {
    if (value == 0x10u && off32 == 0x5555u) {
      std::fill(sram_.begin(), sram_.end(), 0xFF);
      if (backup_type_ == BackupType::kFlash128K) {
        std::fill(flash_bank1_.begin(), flash_bank1_.end(), 0xFF);
      }
    } else if (value == 0x30u) {
      const size_t sector_base = off & ~static_cast<size_t>(0x0FFFu);
      const size_t sector_end = std::min(sector_base + 0x1000u, sram_.size());
      auto& target = (backup_type_ == BackupType::kFlash128K && flash_bank_ == 1u) ? flash_bank1_ : sram_;
      std::fill(target.begin() + static_cast<std::ptrdiff_t>(sector_base),
                target.begin() + static_cast<std::ptrdiff_t>(sector_end), 0xFF);
    }
    ResetBackupControllerState();
    return;
  }

  ResetBackupControllerState();
}

void GBACore::RunCycles(uint32_t cycles) {
  if (!loaded_) return;
  executed_cycles_ += cycles;
  uint32_t remaining = cycles;
  constexpr uint32_t kSchedulerSliceCycles = 4;
  while (remaining > 0) {
    const uint32_t slice = std::min<uint32_t>(remaining, kSchedulerSliceCycles);
    RunCpuSlice(slice);
    StepTimers(slice);
    StepApu(slice);
    StepPpu(slice);
    StepDma();
    remaining -= slice;
  }
}

void GBACore::SetKeys(uint16_t keys_pressed_mask) {
  keys_pressed_mask_ = keys_pressed_mask;
  SyncKeyInputRegister();
}

void GBACore::StepFrame() {
  if (!loaded_) return;
  RunCycles(kCyclesPerFrame);
  ++frame_count_;

  if (bios_boot_via_vector_) {
    if (cpu_.regs[15] >= 0x08000000u) {
      bios_boot_via_vector_ = false;
      bios_boot_watchdog_frames_ = 0;
      Write8(0x04000300u, 0x01u);
    } else {
      ++bios_boot_watchdog_frames_;
      // Watchdog fallback: if BIOS init does not hand off to ROM for a long
      // time, switch to direct cartridge entry to avoid permanent white screen.
      if (bios_boot_watchdog_frames_ > 240u) {
        bios_boot_via_vector_ = false;
        bios_boot_watchdog_frames_ = 0;
        cpu_.cpsr = static_cast<uint32_t>((cpu_.cpsr & ~0x1Fu) | 0x1Fu);
        cpu_.cpsr &= ~(1u << 5);
        cpu_.active_mode = cpu_.cpsr & 0x1Fu;
        cpu_.halted = false;
        swi_intrwait_active_ = false;
        swi_intrwait_mask_ = 0;
        cpu_.regs[15] = 0x08000000u;
        Write8(0x04000300u, 0x01u);
        const uint16_t dispcnt = ReadIO16(0x04000000u);
        WriteIO16(0x04000000u, static_cast<uint16_t>(dispcnt & ~(1u << 7)));
      }
    }
  }

  // Halt watchdog for HLE/direct mode: avoid permanent hangs when software
  // enters SWI Halt/IntrWait without a valid interrupt source configured.
  if (!bios_boot_via_vector_ && cpu_.halted) {
    const uint16_t ie = ReadIO16(0x04000200u);
    const uint16_t iflags = ReadIO16(0x04000202u);
    const uint16_t ime = static_cast<uint16_t>(ReadIO16(0x04000208u) & 0x1u);
    if (ime == 0u || (ie & iflags) == 0u) {
      ++halt_watchdog_frames_;
      if (halt_watchdog_frames_ > 120u) {
        cpu_.halted = false;
        swi_intrwait_active_ = false;
        swi_intrwait_mask_ = 0;
        halt_watchdog_frames_ = 0;
      }
    } else {
      halt_watchdog_frames_ = 0;
    }
  } else {
    halt_watchdog_frames_ = 0;
  }

  UpdateGameplayFromInput();
  RenderDebugFrame();
}

uint8_t GBACore::ComputeComplementCheck() const {
  int sum = 0;
  for (size_t i = 0xA0; i <= 0xBC && i < rom_.size(); ++i) {
    sum += rom_[i];
  }
  return static_cast<uint8_t>((-sum - 0x19) & 0xFF);
}

bool GBACore::ValidateNintendoLogo() const {
  if (rom_.size() < 0xA0) return false;
  for (size_t i = 0; i < sizeof(kNintendoLogoLocal); ++i) {
    if (rom_[0x04 + i] != kNintendoLogoLocal[i]) {
      return false;
    }
  }
  return true;
}

void GBACore::UpdateGameplayFromInput() {
  constexpr int kStep = 2;
  const uint16_t pressed_edge = static_cast<uint16_t>(keys_pressed_mask_ & ~previous_keys_mask_);

  if (keys_pressed_mask_ & kKeyRight) gameplay_state_.player_x += kStep;
  if (keys_pressed_mask_ & kKeyLeft) gameplay_state_.player_x -= kStep;
  if (keys_pressed_mask_ & kKeyDown) gameplay_state_.player_y += kStep;
  if (keys_pressed_mask_ & kKeyUp) gameplay_state_.player_y -= kStep;
  if (keys_pressed_mask_ & kKeyR) gameplay_state_.player_x += 1;
  if (keys_pressed_mask_ & kKeyL) gameplay_state_.player_x -= 1;

  gameplay_state_.player_x = std::clamp(gameplay_state_.player_x, 0, kScreenWidth - 1);
  gameplay_state_.player_y = std::clamp(gameplay_state_.player_y, 0, kScreenHeight - 1);

  if (keys_pressed_mask_ & kKeyA) {
    gameplay_state_.score += 3;
  }
  if (keys_pressed_mask_ & kKeyB) {
    gameplay_state_.score += 1;
  }
  if (keys_pressed_mask_ & kKeyR) {
    gameplay_state_.score += 2;
  }
  if (keys_pressed_mask_ & kKeyL) {
    gameplay_state_.score += 2;
  }
  if (pressed_edge & kKeyStart) {
    gameplay_state_.score += 5;
  }
  if ((pressed_edge & kKeySelect) && gameplay_state_.score > 0) {
    --gameplay_state_.score;
  }
  if ((keys_pressed_mask_ & kKeyA) && (keys_pressed_mask_ & kKeyB)) {
    ++gameplay_state_.combo;
    gameplay_state_.score += 2;
  } else {
    gameplay_state_.combo = 0;
  }

  constexpr int kRightCheckpointX = kScreenWidth - 20;
  constexpr int kBottomCheckpointY = kScreenHeight - 15;
  constexpr int kLeftCheckpointX = 20;
  constexpr int kTopCheckpointY = 15;

  if (gameplay_state_.player_x >= kRightCheckpointX) gameplay_state_.checkpoints |= 0x1;
  if (gameplay_state_.player_y >= kBottomCheckpointY) gameplay_state_.checkpoints |= 0x2;
  if (gameplay_state_.player_x <= kLeftCheckpointX) gameplay_state_.checkpoints |= 0x4;
  if (gameplay_state_.player_y <= kTopCheckpointY) gameplay_state_.checkpoints |= 0x8;

  constexpr uint8_t kAllCheckpoints = 0x0F;
  if (gameplay_state_.checkpoints == kAllCheckpoints &&
      gameplay_state_.score >= 300 &&
      frame_count_ >= 180) {
    gameplay_state_.cleared = true;
  }
  previous_keys_mask_ = keys_pressed_mask_;
}


}  // namespace gba

