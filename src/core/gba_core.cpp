#include "gba_core.h"

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

  if (rom_info_.fixed_value != 0x96) {
    if (error) *error = "Invalid Nintendo header fixed value at 0xB2.";
    loaded_ = false;
    return false;
  }
  // Some homebrew/test ROMs can intentionally alter logo/complement fields.
  // Keep the validity flags for diagnostics, but do not hard-fail loading.
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
    if (error) *error = "BIOS too small (needs 16KB).";
    return false;
  }
  std::copy_n(bios.begin(), bios_.size(), bios_.begin());
  bios_loaded_ = true;
  return true;
}

void GBACore::LoadBuiltInBIOS() {
  std::fill(bios_.begin(), bios_.end(), 0);
  // Very small built-in BIOS stub:
  // - vector table entries branch to 0x100
  // - SWI vector returns immediately
  auto write32le = [&](size_t off, uint32_t v) {
    if (off + 3 >= bios_.size()) return;
    bios_[off] = static_cast<uint8_t>(v & 0xFF);
    bios_[off + 1] = static_cast<uint8_t>((v >> 8) & 0xFF);
    bios_[off + 2] = static_cast<uint8_t>((v >> 16) & 0xFF);
    bios_[off + 3] = static_cast<uint8_t>((v >> 24) & 0xFF);
  };

  // ARM B 0x100 from vectors (cond=1110, opcode=1010, imm24)
  auto make_branch = [](uint32_t from, uint32_t to) -> uint32_t {
    int32_t delta = static_cast<int32_t>(to) - static_cast<int32_t>(from + 8u);
    int32_t imm24 = (delta >> 2) & 0x00FFFFFF;
    return 0xEA000000u | static_cast<uint32_t>(imm24);
  };
  for (size_t vec = 0; vec <= 0x1C; vec += 4) {
    write32le(vec, make_branch(static_cast<uint32_t>(vec), 0x100u));
  }
  // SWI vector at 0x08: MOVS PC, LR
  write32le(0x08, 0xE1B0F00Eu);
  // IRQ vector at 0x18: SUBS PC, LR, #4
  write32le(0x18, 0xE25EF004u);
  // Reset handler @0x100: branch to cartridge space 0x08000000
  write32le(0x100, make_branch(0x100u, 0x08000000u));
  bios_loaded_ = true;
}

void GBACore::Reset() {
  frame_count_ = 0;
  executed_cycles_ = 0;
  keys_pressed_mask_ = 0;
  previous_keys_mask_ = 0;
  std::fill(ewram_.begin(), ewram_.end(), 0);
  std::fill(iwram_.begin(), iwram_.end(), 0);
  std::fill(io_regs_.begin(), io_regs_.end(), 0);
  std::fill(palette_ram_.begin(), palette_ram_.end(), 0);
  std::fill(vram_.begin(), vram_.end(), 0);
  std::fill(oam_.begin(), oam_.end(), 0);
  std::fill(sram_.begin(), sram_.end(), 0xFF);
  ResetBackupControllerState();
  timers_ = {};
  ppu_cycle_accum_ = 0;
  audio_mix_level_ = 0;
  cpu_ = CpuState{};
  cpu_.regs[15] = 0x08000000u;  // ROM entry area.
  // DISPCNT default: mode 0, forced blank off.
  WriteIO16(0x04000000u, 0x0000u);
  // VCOUNT
  WriteIO16(0x04000006u, 0x0000u);
  // KEYINPUT: all released (active low)
  WriteIO16(0x04000130u, 0x03FFu);
  // IE/IF/IME
  WriteIO16(0x04000200u, 0x0000u);
  WriteIO16(0x04000202u, 0x0000u);
  WriteIO16(0x04000208u, 0x0001u);
  SyncKeyInputRegister();
  gameplay_state_ = GameplayState{};
  frame_buffer_.assign(kScreenWidth * kScreenHeight, 0xFF000000U);
  RenderDebugFrame();
}

void GBACore::LoadSaveRAM(const std::vector<uint8_t>& data) {
  const size_t copy_size = std::min(data.size(), sram_.size());
  std::copy_n(data.begin(), copy_size, sram_.begin());
  if (copy_size < sram_.size()) {
    std::fill(sram_.begin() + static_cast<std::ptrdiff_t>(copy_size), sram_.end(), 0xFF);
  }
}

std::vector<uint8_t> GBACore::SaveStateBlob() const {
  auto append_u32 = [](std::vector<uint8_t>* out, uint32_t v) {
    out->push_back(static_cast<uint8_t>(v & 0xFF));
    out->push_back(static_cast<uint8_t>((v >> 8) & 0xFF));
    out->push_back(static_cast<uint8_t>((v >> 16) & 0xFF));
    out->push_back(static_cast<uint8_t>((v >> 24) & 0xFF));
  };
  auto append_u64 = [&](std::vector<uint8_t>* out, uint64_t v) {
    append_u32(out, static_cast<uint32_t>(v & 0xFFFFFFFFu));
    append_u32(out, static_cast<uint32_t>(v >> 32));
  };
  std::vector<uint8_t> blob;
  blob.reserve(512 * 1024);
  blob.insert(blob.end(), {'G', 'B', 'A', 'S'});
  append_u32(&blob, 2u);  // version
  append_u64(&blob, frame_count_);
  append_u64(&blob, executed_cycles_);
  append_u32(&blob, cpu_.cpsr);
  append_u32(&blob, ppu_cycle_accum_);
  append_u32(&blob, audio_mix_level_);
  append_u32(&blob, keys_pressed_mask_);
  append_u32(&blob, previous_keys_mask_);
  append_u32(&blob, static_cast<uint32_t>(backup_type_));
  append_u32(&blob, flash_mode_unlocked_ ? 1u : 0u);
  append_u32(&blob, flash_command_);
  append_u32(&blob, flash_id_mode_ ? 1u : 0u);
  append_u32(&blob, flash_program_mode_ ? 1u : 0u);
  for (uint32_t r : cpu_.regs) append_u32(&blob, r);
  blob.insert(blob.end(), ewram_.begin(), ewram_.end());
  blob.insert(blob.end(), iwram_.begin(), iwram_.end());
  blob.insert(blob.end(), io_regs_.begin(), io_regs_.end());
  blob.insert(blob.end(), palette_ram_.begin(), palette_ram_.end());
  blob.insert(blob.end(), vram_.begin(), vram_.end());
  blob.insert(blob.end(), oam_.begin(), oam_.end());
  blob.insert(blob.end(), sram_.begin(), sram_.end());
  return blob;
}

bool GBACore::LoadStateBlob(const std::vector<uint8_t>& blob, std::string* error) {
  auto read_u32 = [&](size_t* off, uint32_t* out) -> bool {
    if (*off + 4 > blob.size()) return false;
    *out = static_cast<uint32_t>(blob[*off]) |
           (static_cast<uint32_t>(blob[*off + 1]) << 8) |
           (static_cast<uint32_t>(blob[*off + 2]) << 16) |
           (static_cast<uint32_t>(blob[*off + 3]) << 24);
    *off += 4;
    return true;
  };
  auto read_u64 = [&](size_t* off, uint64_t* out) -> bool {
    uint32_t lo = 0, hi = 0;
    if (!read_u32(off, &lo) || !read_u32(off, &hi)) return false;
    *out = static_cast<uint64_t>(lo) | (static_cast<uint64_t>(hi) << 32);
    return true;
  };

  size_t off = 0;
  if (blob.size() < 8 || blob[0] != 'G' || blob[1] != 'B' || blob[2] != 'A' || blob[3] != 'S') {
    if (error) *error = "Invalid savestate magic.";
    return false;
  }
  off = 4;
  uint32_t version = 0;
  if (!read_u32(&off, &version) || (version != 1u && version != 2u)) {
    if (error) *error = "Unsupported savestate version.";
    return false;
  }
  uint32_t tmp32 = 0;
  if (!read_u64(&off, &frame_count_) ||
      !read_u64(&off, &executed_cycles_) ||
      !read_u32(&off, &cpu_.cpsr) ||
      !read_u32(&off, &ppu_cycle_accum_) ||
      !read_u32(&off, &tmp32)) {
    if (error) *error = "Savestate header truncated.";
    return false;
  }
  audio_mix_level_ = static_cast<uint16_t>(tmp32 & 0xFFFFu);
  if (!read_u32(&off, &tmp32)) return false;
  keys_pressed_mask_ = static_cast<uint16_t>(tmp32 & 0xFFFFu);
  if (!read_u32(&off, &tmp32)) return false;
  previous_keys_mask_ = static_cast<uint16_t>(tmp32 & 0xFFFFu);
  if (version >= 2u) {
    if (!read_u32(&off, &tmp32)) return false;
    backup_type_ = static_cast<BackupType>(tmp32 & 0xFFu);
    if (!read_u32(&off, &tmp32)) return false;
    flash_mode_unlocked_ = (tmp32 & 1u) != 0;
    if (!read_u32(&off, &tmp32)) return false;
    flash_command_ = static_cast<uint8_t>(tmp32 & 0xFFu);
    if (!read_u32(&off, &tmp32)) return false;
    flash_id_mode_ = (tmp32 & 1u) != 0;
    if (!read_u32(&off, &tmp32)) return false;
    flash_program_mode_ = (tmp32 & 1u) != 0;
  } else {
    backup_type_ = DetectBackupTypeFromRom();
    ResetBackupControllerState();
  }
  for (uint32_t& r : cpu_.regs) {
    if (!read_u32(&off, &r)) return false;
  }
  auto read_block = [&](auto& arr) -> bool {
    if (off + arr.size() > blob.size()) return false;
    std::copy_n(blob.begin() + static_cast<std::ptrdiff_t>(off), arr.size(), arr.begin());
    off += arr.size();
    return true;
  };
  if (!read_block(ewram_) || !read_block(iwram_) || !read_block(io_regs_) ||
      !read_block(palette_ram_) || !read_block(vram_) || !read_block(oam_) || !read_block(sram_)) {
    if (error) *error = "Savestate payload truncated.";
    return false;
  }
  loaded_ = true;
  SyncKeyInputRegister();
  RenderDebugFrame();
  return true;
}

uint8_t GBACore::DebugRead8(uint32_t addr) const { return Read8(addr); }
uint16_t GBACore::DebugRead16(uint32_t addr) const { return Read16(addr); }
uint32_t GBACore::DebugRead32(uint32_t addr) const { return Read32(addr); }
void GBACore::DebugWrite8(uint32_t addr, uint8_t value) { Write8(addr, value); }
void GBACore::DebugWrite16(uint32_t addr, uint16_t value) { Write16(addr, value); }
void GBACore::DebugWrite32(uint32_t addr, uint32_t value) { Write32(addr, value); }

void GBACore::ResetBackupControllerState() {
  flash_mode_unlocked_ = false;
  flash_command_ = 0;
  flash_id_mode_ = false;
  flash_program_mode_ = false;
}

uint8_t GBACore::ReadBackup8(uint32_t addr) const {
  const uint32_t off32 = (addr - 0x0E000000u) & 0xFFFFu;
  if (backup_type_ == BackupType::kFlash64K && flash_id_mode_) {
    if (off32 == 0) return 0xBF;  // Sanyo/Panasonic style manufacturer id (common)
    if (off32 == 1) return 0xD4;  // 64Kbit/512Kbit class device id (common test expectation)
  }
  return sram_[static_cast<size_t>(off32 % sram_.size())];
}

void GBACore::WriteBackup8(uint32_t addr, uint8_t value) {
  const uint32_t off32 = (addr - 0x0E000000u) & 0xFFFFu;
  const size_t off = static_cast<size_t>(off32 % sram_.size());

  // SRAM/unknown/eeprom fallback: raw byte write model.
  if (backup_type_ != BackupType::kFlash64K) {
    sram_[off] = value;
    return;
  }

  if (flash_program_mode_) {
    // NOR flash programming behavior: only 1->0 transitions.
    sram_[off] = static_cast<uint8_t>(sram_[off] & value);
    flash_program_mode_ = false;
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
    } else if (value == 0x30u) {
      const size_t sector_base = off & ~static_cast<size_t>(0x0FFFu);
      const size_t sector_end = std::min(sector_base + 0x1000u, sram_.size());
      std::fill(sram_.begin() + static_cast<std::ptrdiff_t>(sector_base),
                sram_.begin() + static_cast<std::ptrdiff_t>(sector_end), 0xFF);
    }
    ResetBackupControllerState();
    return;
  }

  ResetBackupControllerState();
}

void GBACore::RunCycles(uint32_t cycles) {
  if (!loaded_) return;
  executed_cycles_ += cycles;
  RunCpuSlice(cycles);
  StepTimers(cycles);
  StepDma();
  StepApu(cycles);
  StepPpu(cycles);
}

void GBACore::SetKeys(uint16_t keys_pressed_mask) {
  keys_pressed_mask_ = keys_pressed_mask;
  SyncKeyInputRegister();
}

void GBACore::StepFrame() {
  if (!loaded_) return;
  RunCycles(kCyclesPerFrame);
  ++frame_count_;
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
  for (size_t i = 0; i < sizeof(kNintendoLogo); ++i) {
    if (rom_[0x04 + i] != kNintendoLogo[i]) {
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
