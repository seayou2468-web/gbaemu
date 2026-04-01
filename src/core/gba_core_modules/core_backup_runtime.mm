#include "../gba_core.h"

#include <algorithm>

namespace gba {

GBACore::BackupType GBACore::DetectBackupTypeFromRom() const {
  if (rom_.empty()) return BackupType::kUnknown;
  const std::string s(reinterpret_cast<const char*>(rom_.data()), rom_.size());
  if (s.find("EEPROM_V") != std::string::npos) return BackupType::kEEPROM;
  if (s.find("FLASH1M_V") != std::string::npos) return BackupType::kFlash128K;
  if (s.find("FLASH512_V") != std::string::npos || s.find("FLASH_V") != std::string::npos) return BackupType::kFlash64K;
  if (s.find("SRAM_V") != std::string::npos) return BackupType::kSRAM;
  return BackupType::kUnknown;
}

void GBACore::ResetBackupControllerState() {
  backup_type_ = DetectBackupTypeFromRom();
  eeprom_cmd_bits_.clear();
  eeprom_read_bits_.clear();
  eeprom_read_pos_ = 0;
  eeprom_addr_bits_ = 0;

  flash_mode_unlocked_ = false;
  flash_id_mode_ = false;
  flash_program_mode_ = false;
  flash_bank_switch_mode_ = false;
  flash_command_ = 0;
  flash_bank_ = 0;
}

uint8_t GBACore::ReadBackup8(uint32_t addr) const {
  addr &= 0xFFFFu;
  if (backup_type_ == BackupType::kEEPROM) {
    return eeprom_[addr & (eeprom_.size() - 1)];
  }

  if (backup_type_ == BackupType::kFlash64K || backup_type_ == BackupType::kFlash128K) {
    if (flash_id_mode_) {
      if ((addr & 0xFF) == 0x00) return 0xC2;  // Macronix-like manufacturer
      if ((addr & 0xFF) == 0x01) return (backup_type_ == BackupType::kFlash128K) ? 0x09 : 0x1C;
    }
    if (backup_type_ == BackupType::kFlash128K && flash_bank_ == 1) {
      return flash_bank1_[addr & 0xFFFFu];
    }
  }
  return sram_[addr & (sram_.size() - 1)];
}

void GBACore::WriteBackup8(uint32_t addr, uint8_t value) {
  addr &= 0xFFFFu;

  if (backup_type_ == BackupType::kEEPROM) {
    eeprom_[addr & (eeprom_.size() - 1)] = value;
    return;
  }

  if (backup_type_ == BackupType::kFlash64K || backup_type_ == BackupType::kFlash128K) {
    // AMD flash command sequence (最小限)
    if (addr == 0x5555 && value == 0xAA) {
      flash_mode_unlocked_ = true;
      return;
    }
    if (flash_mode_unlocked_ && addr == 0x2AAA && value == 0x55) {
      return;
    }
    if (flash_mode_unlocked_ && addr == 0x5555) {
      flash_mode_unlocked_ = false;
      switch (value) {
        case 0x90: flash_id_mode_ = true; return;
        case 0xF0: flash_id_mode_ = false; flash_program_mode_ = false; flash_bank_switch_mode_ = false; return;
        case 0xA0: flash_program_mode_ = true; return;
        case 0xB0: flash_bank_switch_mode_ = true; return;
        case 0x80: flash_command_ = 0x80; return;
        case 0x10:
          if (flash_command_ == 0x80) {
            std::fill(sram_.begin(), sram_.end(), 0xFF);
            std::fill(flash_bank1_.begin(), flash_bank1_.end(), 0xFF);
            flash_command_ = 0;
          }
          return;
        default: break;
      }
    }

    if (flash_bank_switch_mode_ && addr == 0x0000) {
      flash_bank_ = value & 1u;
      flash_bank_switch_mode_ = false;
      return;
    }

    if (flash_program_mode_) {
      if (backup_type_ == BackupType::kFlash128K && flash_bank_ == 1) {
        flash_bank1_[addr & 0xFFFFu] = value;
      } else {
        sram_[addr & 0xFFFFu] = value;
      }
      flash_program_mode_ = false;
      return;
    }
  }

  sram_[addr & (sram_.size() - 1)] = value;
}

void GBACore::LoadSaveRAM(const std::vector<uint8_t>& data) {
  std::fill(sram_.begin(), sram_.end(), 0xFF);
  const size_t n = std::min(sram_.size(), data.size());
  std::copy_n(data.begin(), n, sram_.begin());
}

std::vector<uint8_t> GBACore::ExportBackupData() const {
  if (backup_type_ == BackupType::kEEPROM) return std::vector<uint8_t>(eeprom_.begin(), eeprom_.end());

  if (backup_type_ == BackupType::kFlash128K) {
    std::vector<uint8_t> out(128 * 1024, 0xFF);
    std::copy(sram_.begin(), sram_.begin() + 64 * 1024, out.begin());
    std::copy(flash_bank1_.begin(), flash_bank1_.begin() + 64 * 1024, out.begin() + 64 * 1024);
    return out;
  }
  return std::vector<uint8_t>(sram_.begin(), sram_.end());
}

void GBACore::ImportBackupData(const std::vector<uint8_t>& data) {
  if (backup_type_ == BackupType::kEEPROM) {
    std::fill(eeprom_.begin(), eeprom_.end(), 0xFF);
    const size_t n = std::min(eeprom_.size(), data.size());
    std::copy_n(data.begin(), n, eeprom_.begin());
    return;
  }

  if (backup_type_ == BackupType::kFlash128K && data.size() >= 128 * 1024) {
    std::copy_n(data.begin(), 64 * 1024, sram_.begin());
    std::copy_n(data.begin() + 64 * 1024, 64 * 1024, flash_bank1_.begin());
    return;
  }
  LoadSaveRAM(data);
}

}  // namespace gba
