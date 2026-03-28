// Unified Objective-C++ core implementation.
// Merged directly from:
// - gba_core.cpp
// - gba_core_cpu.cpp
// - gba_core_memory.cpp
// - gba_core_ppu.cpp

// ---- BEGIN gba_core.cpp ----
#include "../gba_core.h"
#include "../mgba_hle_bios_blob.h"

#include <algorithm>
#include <cstring>
#include <string_view>

namespace gba {
namespace {
constexpr uint8_t kNintendoLogo[156] = {
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

GBACore::BackupType GBACore::DetectBackupTypeFromRom() const {
  if (rom_.empty()) return BackupType::kUnknown;
  const std::string_view sv(reinterpret_cast<const char*>(rom_.data()), rom_.size());
  if (sv.find("FLASH512_V") != std::string_view::npos ||
      sv.find("FLASH_V") != std::string_view::npos ||
      sv.find("SST_") != std::string_view::npos) {
    return BackupType::kFlash64K;
  }
  if (sv.find("FLASH1M_V") != std::string_view::npos ||
      sv.find("FLASH1M1024_V") != std::string_view::npos) {
    return BackupType::kFlash128K;
  }
  if (sv.find("SRAM_V") != std::string_view::npos ||
      sv.find("SRAM_F_V") != std::string_view::npos) {
    return BackupType::kSRAM;
  }
  if (sv.find("EEPROM_V") != std::string_view::npos) {
    return BackupType::kEEPROM;
  }
  return BackupType::kUnknown;
}

bool GBACore::LoadROM(const std::vector<uint8_t>& rom, std::string* error) {
  if (rom.size() < 0xC0) {
    if (error) *error = "ROM too small (needs at least 0xC0 bytes).";
    return false;
  }

  rom_ = rom;
  loaded_ = true;
  backup_type_ = DetectBackupTypeFromRom();

  rom_info_.title = std::string(reinterpret_cast<const char*>(&rom_[0xA0]), 12);
  rom_info_.title.erase(std::find(rom_info_.title.begin(), rom_info_.title.end(), '\0'),
                        rom_info_.title.end());
  rom_info_.game_code = std::string(reinterpret_cast<const char*>(&rom_[0xAC]), 4);
  rom_info_.maker_code = std::string(reinterpret_cast<const char*>(&rom_[0xB0]), 2);
  rom_info_.fixed_value = rom_[0xB2];
  rom_info_.unit_code = rom_[0xB3];
  rom_info_.device_type = rom_[0xB4];
  rom_info_.version = rom_[0xBC];
  rom_info_.complement_check = rom_[0xBD];
  rom_info_.computed_complement_check = ComputeComplementCheck();
  rom_info_.logo_valid = ValidateNintendoLogo();
  rom_info_.complement_check_valid = (rom_info_.complement_check == rom_info_.computed_complement_check);

  // Some homebrew/test ROMs can intentionally alter header fields.
  // Keep validity flags for diagnostics, but do not hard-fail loading.
  if (rom_info_.fixed_value != 0x96 && error) {
    *error = "Warning: Header fixed value at 0xB2 is not 0x96.";
  }
  if (!rom_info_.logo_valid && error) {
    *error = "Warning: Nintendo logo area mismatch (0x04-0x9F).";
  }
  if (!rom_info_.complement_check_valid && error) {
    *error = "Warning: Header complement check mismatch (0xBD).";
  }

  Reset();
  return true;
}

bool GBACore::LoadBIOS(const std::vector<uint8_t>& bios, std::string* error) {
  if (bios.size() < bios_.size()) {
    if (error) *error = "BIOS too small (needs at least 16KB).";
    return false;
  }
  std::copy_n(bios.begin(), bios_.size(), bios_.begin());
  bios_loaded_ = true;
  bios_is_builtin_ = false;
  bios_fetch_latch_ = 0;
  open_bus_latch_ = 0;
  // If a ROM is already loaded, immediately reinitialize so execution and SWI
  // handling use the newly loaded BIOS image.
  if (loaded_) {
    Reset();
  }
  return true;
}

void GBACore::LoadBuiltInBIOS() {
  bios_ = kMgbaHleBios;
  bios_loaded_ = true;
  bios_is_builtin_ = true;
  bios_fetch_latch_ = 0;
  open_bus_latch_ = 0;
  if (loaded_) {
    Reset();
  }
}

}  // namespace gba
