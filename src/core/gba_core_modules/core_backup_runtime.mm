#include "../gba_core.h"
#include <algorithm>
#include <cstring>

namespace gba {

GBACore::BackupType GBACore::DetectBackupTypeFromRom() const {
  std::string rom_str(reinterpret_cast<const char*>(rom_.data()), std::min(rom_.size(), size_t(0x10000)));
  if (rom_str.find("SRAM_V") != std::string::npos) return BackupType::kSRAM;
  if (rom_str.find("FLASH_V") != std::string::npos || rom_str.find("FLASH512_V") != std::string::npos) return BackupType::kFlash64K;
  if (rom_str.find("FLASH1M_V") != std::string::npos) return BackupType::kFlash128K;
  if (rom_str.find("EEPROM_V") != std::string::npos) return BackupType::kEEPROM;
  return BackupType::kUnknown;
}

uint8_t GBACore::ReadBackup8(uint32_t addr) const {
  switch (backup_type_) {
    case BackupType::kSRAM: return sram_[addr & 0x7FFF];
    case BackupType::kFlash64K: case BackupType::kFlash128K:
      if (flash_id_mode_) { if (addr == 0) return 0x62; if (addr == 1) return (backup_type_ == BackupType::kFlash64K) ? 0x13 : 0x09; }
      if (backup_type_ == BackupType::kFlash128K) return (flash_bank_ == 0) ? sram_[addr & 0xFFFF] : flash_bank1_[addr & 0xFFFF];
      return sram_[addr & 0xFFFF];
    default: return 0xFF;
  }
}

void GBACore::WriteBackup8(uint32_t addr, uint8_t value) {
  switch (backup_type_) {
    case BackupType::kSRAM: sram_[addr & 0x7FFF] = value; break;
    case BackupType::kFlash64K: case BackupType::kFlash128K:
      if (flash_program_mode_) {
        if (backup_type_ == BackupType::kFlash128K) { if (flash_bank_ == 0) sram_[addr & 0xFFFF] = value; else flash_bank1_[addr & 0xFFFF] = value; }
        else sram_[addr & 0xFFFF] = value;
        flash_program_mode_ = false; break;
      }
      if (addr == 0x5555 && value == 0xAA) flash_mode_unlocked_ = true;
      else if (flash_mode_unlocked_ && addr == 0x2AAA && value == 0x55) {}
      else if (flash_mode_unlocked_ && addr == 0x5555) {
        flash_command_ = value;
        if (value == 0x90) flash_id_mode_ = true;
        else if (value == 0xF0) flash_id_mode_ = false;
        else if (value == 0xA0) flash_program_mode_ = true;
        else if (value == 0xB1) flash_bank_switch_mode_ = true;
        flash_mode_unlocked_ = false;
      } else if (flash_bank_switch_mode_ && addr == 0x0000) { flash_bank_ = value & 1; flash_bank_switch_mode_ = false; }
      break;
    default: break;
  }
}

} // namespace gba
