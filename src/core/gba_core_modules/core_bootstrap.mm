#include "../gba_core.h"
#include "../../debug/trace.h"
#include <algorithm>
#include <cstring>

namespace gba {

bool GBACore::LoadBIOS(const std::vector<uint8_t>& bios, std::string* error) {
  if (bios.size() != 16384) {
    if (error) *error = "Invalid BIOS size";
    return false;
  }
  std::copy(bios.begin(), bios.end(), bios_.begin());
  bios_loaded_ = true;
  bios_is_builtin_ = false;
  return true;
}

void GBACore::LoadBuiltInBIOS() {
  // Use HLE BIOS or embedded blob
  // For now, assume we have a way to get it or just set a flag
  bios_is_builtin_ = true;
  bios_loaded_ = true;
}

bool GBACore::LoadROM(const std::vector<uint8_t>& rom, std::string* error) {
  if (rom.size() < 0x100) {
    if (error) *error = "ROM too small";
    return false;
  }
  rom_ = rom;

  // Extract ROM info
  rom_info_.title = std::string(reinterpret_cast<const char*>(&rom_[0xA0]), 12);
  rom_info_.game_code = std::string(reinterpret_cast<const char*>(&rom_[0xAC]), 4);
  rom_info_.maker_code = std::string(reinterpret_cast<const char*>(&rom_[0xB0]), 2);
  rom_info_.fixed_value = rom_[0xB2];
  rom_info_.unit_code = rom_[0xB3];
  rom_info_.device_type = rom_[0xB4];
  rom_info_.version = rom_[0xBC];
  rom_info_.complement_check = rom_[0xBD];

  rom_info_.computed_complement_check = ComputeComplementCheck();
  rom_info_.complement_check_valid = (rom_info_.complement_check == rom_info_.computed_complement_check);
  rom_info_.logo_valid = ValidateNintendoLogo();

  backup_type_ = DetectBackupTypeFromRom();
  Reset();
  loaded_ = true;
  return true;
}

uint8_t GBACore::ComputeComplementCheck() const {
  uint8_t res = 0;
  for (size_t i = 0xA0; i <= 0xBC; ++i) {
    res = res - rom_[i];
  }
  return (res - 0x19);
}

bool GBACore::ValidateNintendoLogo() const {
  // Simplification: Check if it matches expected GBA logo bytes
  return true; // Assume valid for now
}

void GBACore::RunCycles(uint32_t cycles) {
  if (!loaded_) return;

  uint32_t cycles_to_run = cycles;
  while (cycles_to_run > 0) {
    uint32_t slice = std::min(cycles_to_run, 128u);
    uint32_t ran = RunCpuSlice(slice);

    StepPpu(ran);
    StepTimers(ran);
    StepApu(ran);
    StepSio(ran);

    executed_cycles_ += ran;
    if (ran >= cycles_to_run) break;
    cycles_to_run -= ran;
  }
}

void GBACore::StepFrame() {
  RunCycles(kCyclesPerFrame);
  frame_count_++;
}

void GBACore::SetKeys(uint16_t keys_pressed_mask) {
  previous_keys_mask_ = keys_pressed_mask_;
  keys_pressed_mask_ = keys_pressed_mask;
  SyncKeyInputRegister();
}

void GBACore::UpdateGameplayFromInput() {
  // Logic to update gameplay_state_ based on keys_pressed_mask_
  // This is specific to the "demo" or internal state tracking
}

} // namespace gba
