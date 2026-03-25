// Unified Objective-C++ core implementation.
// Merged directly from:
// - gba_core.cpp
// - gba_core_cpu.cpp
// - gba_core_memory.cpp
// - gba_core_ppu.cpp

// ---- BEGIN gba_core.cpp ----
#include "gba_core.h"
#include "mgba_hle_bios_blob.h"

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
    if (error) *error = "BIOS too small (needs 16KB).";
    return false;
  }
  std::copy_n(bios.begin(), bios_.size(), bios_.begin());
  bios_loaded_ = true;
  bios_is_builtin_ = false;
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
  if (loaded_) {
    Reset();
  }
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
  std::fill(eeprom_.begin(), eeprom_.end(), 0xFF);
  std::fill(flash_bank1_.begin(), flash_bank1_.end(), 0xFF);
  ResetBackupControllerState();
  timers_ = {};
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
  bios_latch_ = 0;
  cpu_ = CpuState{};
  cpu_.active_mode = cpu_.cpsr & 0x1Fu;
  cpu_.banked_fiq_r8_r12.fill(0);
  // Real hardware leaves post-boot stack pointers at these locations after
  // BIOS SoftReset (GBATEK "SWI 00h - SoftReset"), then enters game code.
  cpu_.banked_sp[0x13u] = 0x03007FE0u;  // SVC
  cpu_.banked_sp[0x12u] = 0x03007FA0u;  // IRQ
  cpu_.banked_sp[0x1Fu] = 0x03007F00u;  // SYS
  cpu_.banked_lr[0x13u] = 0;
  cpu_.banked_lr[0x12u] = 0;
  cpu_.regs[13] = cpu_.banked_sp[0x1Fu];
  cpu_.regs[14] = 0;
  // Real boot executes from BIOS reset vector only for externally supplied BIOS.
  // Built-in BIOS is a compatibility stub and still uses direct cartridge entry.
  const bool use_real_bios_boot = bios_loaded_ && !bios_is_builtin_;
  cpu_.regs[15] = use_real_bios_boot ? 0x00000000u : 0x08000000u;
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
  // POSTFLG remains 0 during real BIOS boot, and is 1 for direct cartridge fallback.
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
  append_u32(&blob, 10u);  // version
  append_u64(&blob, frame_count_);
  append_u64(&blob, executed_cycles_);
  append_u32(&blob, cpu_.cpsr);
  append_u32(&blob, ppu_cycle_accum_);
  append_u32(&blob, audio_mix_level_);
  append_u32(&blob, bios_latch_);
  append_u32(&blob, keys_pressed_mask_);
  append_u32(&blob, previous_keys_mask_);
  append_u32(&blob, static_cast<uint32_t>(backup_type_));
  append_u32(&blob, flash_mode_unlocked_ ? 1u : 0u);
  append_u32(&blob, flash_command_);
  append_u32(&blob, flash_id_mode_ ? 1u : 0u);
  append_u32(&blob, flash_program_mode_ ? 1u : 0u);
  append_u32(&blob, flash_bank_switch_mode_ ? 1u : 0u);
  append_u32(&blob, flash_bank_);
  append_u32(&blob, static_cast<uint32_t>(static_cast<uint16_t>(fifo_a_last_sample_)));
  append_u32(&blob, static_cast<uint32_t>(static_cast<uint16_t>(fifo_b_last_sample_)));
  append_u32(&blob, apu_phase_sq1_);
  append_u32(&blob, apu_phase_sq2_);
  append_u32(&blob, apu_phase_wave_);
  append_u32(&blob, apu_noise_lfsr_);
  append_u32(&blob, apu_frame_seq_cycles_);
  append_u32(&blob, apu_frame_seq_step_);
  append_u32(&blob, apu_env_ch1_);
  append_u32(&blob, apu_env_ch2_);
  append_u32(&blob, apu_env_ch4_);
  append_u32(&blob, apu_env_timer_ch1_);
  append_u32(&blob, apu_env_timer_ch2_);
  append_u32(&blob, apu_env_timer_ch4_);
  append_u32(&blob, apu_len_ch1_);
  append_u32(&blob, apu_len_ch2_);
  append_u32(&blob, apu_len_ch3_);
  append_u32(&blob, apu_len_ch4_);
  append_u32(&blob, apu_ch1_sweep_freq_);
  append_u32(&blob, apu_ch1_sweep_timer_);
  append_u32(&blob, apu_ch1_sweep_enabled_ ? 1u : 0u);
  append_u32(&blob, apu_ch1_active_ ? 1u : 0u);
  append_u32(&blob, apu_ch2_active_ ? 1u : 0u);
  append_u32(&blob, apu_ch3_active_ ? 1u : 0u);
  append_u32(&blob, apu_ch4_active_ ? 1u : 0u);
  append_u32(&blob, static_cast<uint32_t>(fifo_a_.size()));
  for (uint8_t b : fifo_a_) append_u32(&blob, b);
  append_u32(&blob, static_cast<uint32_t>(fifo_b_.size()));
  for (uint8_t b : fifo_b_) append_u32(&blob, b);
  append_u32(&blob, static_cast<uint32_t>(eeprom_read_pos_));
  append_u32(&blob, static_cast<uint32_t>(eeprom_cmd_bits_.size()));
  for (uint8_t b : eeprom_cmd_bits_) append_u32(&blob, b);
  append_u32(&blob, static_cast<uint32_t>(eeprom_read_bits_.size()));
  for (uint8_t b : eeprom_read_bits_) append_u32(&blob, b);
  for (uint32_t r : cpu_.regs) append_u32(&blob, r);
  for (uint32_t v : cpu_.banked_fiq_r8_r12) append_u32(&blob, v);
  for (uint32_t v : cpu_.banked_sp) append_u32(&blob, v);
  for (uint32_t v : cpu_.banked_lr) append_u32(&blob, v);
  for (uint32_t v : cpu_.spsr) append_u32(&blob, v);
  append_u32(&blob, cpu_.active_mode);
  blob.insert(blob.end(), ewram_.begin(), ewram_.end());
  blob.insert(blob.end(), iwram_.begin(), iwram_.end());
  blob.insert(blob.end(), io_regs_.begin(), io_regs_.end());
  blob.insert(blob.end(), palette_ram_.begin(), palette_ram_.end());
  blob.insert(blob.end(), vram_.begin(), vram_.end());
  blob.insert(blob.end(), oam_.begin(), oam_.end());
  blob.insert(blob.end(), sram_.begin(), sram_.end());
  blob.insert(blob.end(), eeprom_.begin(), eeprom_.end());
  blob.insert(blob.end(), flash_bank1_.begin(), flash_bank1_.end());
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
  if (!read_u32(&off, &version) ||
      (version != 1u && version != 2u && version != 3u && version != 4u && version != 5u &&
       version != 6u && version != 7u && version != 8u && version != 9u && version != 10u)) {
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
  apu_frame_seq_cycles_ = 0;
  apu_frame_seq_step_ = 0;
  apu_env_ch1_ = apu_env_ch2_ = apu_env_ch4_ = 0;
  apu_env_timer_ch1_ = apu_env_timer_ch2_ = apu_env_timer_ch4_ = 0;
  apu_len_ch1_ = apu_len_ch2_ = apu_len_ch4_ = 0;
  apu_len_ch3_ = 0;
  apu_ch1_sweep_freq_ = 0;
  apu_ch1_sweep_timer_ = 0;
  apu_ch1_sweep_enabled_ = false;
  apu_ch1_active_ = apu_ch2_active_ = apu_ch3_active_ = apu_ch4_active_ = false;
  apu_prev_trig_ch1_ = apu_prev_trig_ch2_ = apu_prev_trig_ch3_ = apu_prev_trig_ch4_ = false;
  if (version >= 6u) {
    if (!read_u32(&off, &bios_latch_)) return false;
  } else {
    bios_latch_ = 0;
  }
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
    if (version >= 3u) {
      if (!read_u32(&off, &tmp32)) return false;
      flash_bank_switch_mode_ = (tmp32 & 1u) != 0;
      if (!read_u32(&off, &tmp32)) return false;
      flash_bank_ = static_cast<uint8_t>(tmp32 & 0x1u);
      if (version >= 8u) {
        if (!read_u32(&off, &tmp32)) return false;
        fifo_a_last_sample_ = static_cast<int16_t>(tmp32 & 0xFFFFu);
        if (!read_u32(&off, &tmp32)) return false;
        fifo_b_last_sample_ = static_cast<int16_t>(tmp32 & 0xFFFFu);
        if (version >= 9u) {
          if (!read_u32(&off, &apu_phase_sq1_)) return false;
          if (!read_u32(&off, &apu_phase_sq2_)) return false;
          if (!read_u32(&off, &apu_phase_wave_)) return false;
          if (!read_u32(&off, &tmp32)) return false;
          apu_noise_lfsr_ = static_cast<uint16_t>(tmp32 & 0x7FFFu);
          if (version >= 10u) {
            if (!read_u32(&off, &apu_frame_seq_cycles_)) return false;
            if (!read_u32(&off, &tmp32)) return false;
            apu_frame_seq_step_ = static_cast<uint8_t>(tmp32 & 0x7u);
            if (!read_u32(&off, &tmp32)) return false;
            apu_env_ch1_ = static_cast<uint8_t>(tmp32 & 0xFu);
            if (!read_u32(&off, &tmp32)) return false;
            apu_env_ch2_ = static_cast<uint8_t>(tmp32 & 0xFu);
            if (!read_u32(&off, &tmp32)) return false;
            apu_env_ch4_ = static_cast<uint8_t>(tmp32 & 0xFu);
            if (!read_u32(&off, &tmp32)) return false;
            apu_env_timer_ch1_ = static_cast<uint8_t>(tmp32 & 0x7u);
            if (!read_u32(&off, &tmp32)) return false;
            apu_env_timer_ch2_ = static_cast<uint8_t>(tmp32 & 0x7u);
            if (!read_u32(&off, &tmp32)) return false;
            apu_env_timer_ch4_ = static_cast<uint8_t>(tmp32 & 0x7u);
            if (!read_u32(&off, &tmp32)) return false;
            apu_len_ch1_ = static_cast<uint8_t>(tmp32 & 0x3Fu);
            if (!read_u32(&off, &tmp32)) return false;
            apu_len_ch2_ = static_cast<uint8_t>(tmp32 & 0x3Fu);
            if (!read_u32(&off, &tmp32)) return false;
            apu_len_ch3_ = static_cast<uint16_t>(tmp32 & 0xFFu);
            if (!read_u32(&off, &tmp32)) return false;
            apu_len_ch4_ = static_cast<uint8_t>(tmp32 & 0x3Fu);
            if (!read_u32(&off, &tmp32)) return false;
            apu_ch1_sweep_freq_ = static_cast<uint16_t>(tmp32 & 0x7FFu);
            if (!read_u32(&off, &tmp32)) return false;
            apu_ch1_sweep_timer_ = static_cast<uint8_t>(tmp32 & 0x7u);
            if (!read_u32(&off, &tmp32)) return false;
            apu_ch1_sweep_enabled_ = (tmp32 & 1u) != 0;
            if (!read_u32(&off, &tmp32)) return false;
            apu_ch1_active_ = (tmp32 & 1u) != 0;
            if (!read_u32(&off, &tmp32)) return false;
            apu_ch2_active_ = (tmp32 & 1u) != 0;
            if (!read_u32(&off, &tmp32)) return false;
            apu_ch3_active_ = (tmp32 & 1u) != 0;
            if (!read_u32(&off, &tmp32)) return false;
            apu_ch4_active_ = (tmp32 & 1u) != 0;
          }
        } else {
          apu_phase_sq1_ = 0;
          apu_phase_sq2_ = 0;
          apu_phase_wave_ = 0;
          apu_noise_lfsr_ = 0x7FFFu;
        }
        if (!read_u32(&off, &tmp32)) return false;
        fifo_a_.assign(tmp32, 0);
        for (size_t i = 0; i < fifo_a_.size(); ++i) {
          uint32_t v = 0;
          if (!read_u32(&off, &v)) return false;
          fifo_a_[i] = static_cast<uint8_t>(v & 0xFFu);
        }
        if (!read_u32(&off, &tmp32)) return false;
        fifo_b_.assign(tmp32, 0);
        for (size_t i = 0; i < fifo_b_.size(); ++i) {
          uint32_t v = 0;
          if (!read_u32(&off, &v)) return false;
          fifo_b_[i] = static_cast<uint8_t>(v & 0xFFu);
        }
      } else {
        fifo_a_.clear();
        fifo_b_.clear();
        fifo_a_last_sample_ = 0;
        fifo_b_last_sample_ = 0;
        apu_phase_sq1_ = 0;
        apu_phase_sq2_ = 0;
        apu_phase_wave_ = 0;
        apu_noise_lfsr_ = 0x7FFFu;
      }
      if (version >= 7u) {
        if (!read_u32(&off, &tmp32)) return false;
        eeprom_read_pos_ = tmp32;
        if (!read_u32(&off, &tmp32)) return false;
        eeprom_cmd_bits_.assign(tmp32, 0);
        for (size_t i = 0; i < eeprom_cmd_bits_.size(); ++i) {
          uint32_t v = 0;
          if (!read_u32(&off, &v)) return false;
          eeprom_cmd_bits_[i] = static_cast<uint8_t>(v & 1u);
        }
        if (!read_u32(&off, &tmp32)) return false;
        eeprom_read_bits_.assign(tmp32, 0);
        for (size_t i = 0; i < eeprom_read_bits_.size(); ++i) {
          uint32_t v = 0;
          if (!read_u32(&off, &v)) return false;
          eeprom_read_bits_[i] = static_cast<uint8_t>(v & 1u);
        }
      } else {
        eeprom_cmd_bits_.clear();
        eeprom_read_bits_.clear();
        eeprom_read_pos_ = 0;
      }
    } else {
      flash_bank_switch_mode_ = false;
      flash_bank_ = 0;
      eeprom_cmd_bits_.clear();
      eeprom_read_bits_.clear();
      eeprom_read_pos_ = 0;
    }
  } else {
    backup_type_ = DetectBackupTypeFromRom();
    ResetBackupControllerState();
    fifo_a_.clear();
    fifo_b_.clear();
    fifo_a_last_sample_ = 0;
    fifo_b_last_sample_ = 0;
    apu_phase_sq1_ = 0;
    apu_phase_sq2_ = 0;
    apu_phase_wave_ = 0;
    apu_noise_lfsr_ = 0x7FFFu;
  }
  for (uint32_t& r : cpu_.regs) {
    if (!read_u32(&off, &r)) return false;
  }
  if (version >= 4u) {
    if (version >= 5u) {
      for (uint32_t& v : cpu_.banked_fiq_r8_r12) if (!read_u32(&off, &v)) return false;
    } else {
      cpu_.banked_fiq_r8_r12.fill(0);
    }
    for (uint32_t& v : cpu_.banked_sp) if (!read_u32(&off, &v)) return false;
    for (uint32_t& v : cpu_.banked_lr) if (!read_u32(&off, &v)) return false;
    for (uint32_t& v : cpu_.spsr) if (!read_u32(&off, &v)) return false;
    if (!read_u32(&off, &cpu_.active_mode)) return false;
    cpu_.active_mode &= 0x1Fu;
    cpu_.cpsr = (cpu_.cpsr & ~0x1Fu) | cpu_.active_mode;
  } else {
    cpu_.active_mode = cpu_.cpsr & 0x1Fu;
    cpu_.banked_fiq_r8_r12.fill(0);
    cpu_.banked_sp.fill(0);
    cpu_.banked_lr.fill(0);
    cpu_.spsr.fill(0);
    cpu_.banked_sp[cpu_.active_mode] = cpu_.regs[13];
    cpu_.banked_lr[cpu_.active_mode] = cpu_.regs[14];
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
  if (version >= 7u) {
    if (!read_block(eeprom_)) {
      if (error) *error = "Savestate payload truncated.";
      return false;
    }
  } else {
    std::fill(eeprom_.begin(), eeprom_.end(), 0xFF);
  }
  if (version >= 3u) {
    if (!read_block(flash_bank1_)) {
      if (error) *error = "Savestate payload truncated.";
      return false;
    }
  } else {
    std::fill(flash_bank1_.begin(), flash_bank1_.end(), 0xFF);
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

// ---- END gba_core.cpp ----
// ---- BEGIN gba_core_cpu.cpp ----
#include "gba_core.h"

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdlib>
#include <limits>

namespace gba {
namespace {
int16_t BiosArcTanPoly(int32_t i) {
  const int32_t a = -((i * i) >> 14);
  int32_t b = ((0xA9 * a) >> 14) + 0x390;
  b = ((b * a) >> 14) + 0x91C;
  b = ((b * a) >> 14) + 0xFB6;
  b = ((b * a) >> 14) + 0x16AA;
  b = ((b * a) >> 14) + 0x2081;
  b = ((b * a) >> 14) + 0x3651;
  b = ((b * a) >> 14) + 0xA2F9;
  return static_cast<int16_t>((i * b) >> 16);
}

int16_t BiosArcTan2(int32_t x, int32_t y) {
  if (y == 0) return static_cast<int16_t>(x >= 0 ? 0 : 0x8000);
  if (x == 0) return static_cast<int16_t>(y >= 0 ? 0x4000 : 0xC000);
  if (y >= 0) {
    if (x >= 0) {
      if (x >= y) return BiosArcTanPoly((y << 14) / x);
    } else if (-x >= y) {
      return static_cast<int16_t>(BiosArcTanPoly((y << 14) / x) + 0x8000);
    }
    return static_cast<int16_t>(0x4000 - BiosArcTanPoly((x << 14) / y));
  }
  if (x <= 0) {
    if (-x > -y) return static_cast<int16_t>(BiosArcTanPoly((y << 14) / x) + 0x8000);
  } else if (x >= -y) {
    return static_cast<int16_t>(BiosArcTanPoly((y << 14) / x) + 0x10000);
  }
  return static_cast<int16_t>(0xC000 - BiosArcTanPoly((x << 14) / y));
}

uint32_t BiosSqrt(uint32_t x) {
  if (x == 0) return 0;
  uint32_t upper = x;
  uint32_t bound = 1;
  while (bound < upper) {
    upper >>= 1;
    bound <<= 1;
  }
  while (true) {
    upper = x;
    uint32_t accum = 0;
    uint32_t lower = bound;
    while (true) {
      const uint32_t old_lower = lower;
      if (lower <= upper >> 1) lower <<= 1;
      if (old_lower >= upper >> 1) break;
    }
    while (true) {
      accum <<= 1;
      if (upper >= lower) {
        ++accum;
        upper -= lower;
      }
      if (lower == bound) break;
      lower >>= 1;
    }
    const uint32_t old_bound = bound;
    bound += accum;
    bound >>= 1;
    if (bound >= old_bound) return old_bound;
  }
}
}  // namespace

uint32_t GBACore::RotateRight(uint32_t value, unsigned bits) const {
  bits &= 31u;
  if (bits == 0) return value;
  return (value >> bits) | (value << (32u - bits));
}

uint32_t GBACore::ApplyShift(uint32_t value,
                             uint32_t shift_type,
                             uint32_t shift_amount,
                             bool* carry_out) const {
  if (!carry_out) return value;
  *carry_out = GetFlagC();
  switch (shift_type & 0x3u) {
    case 0: {  // LSL
      if (shift_amount == 0) return value;
      if (shift_amount < 32) {
        *carry_out = ((value >> (32u - shift_amount)) & 1u) != 0;
        return value << shift_amount;
      }
      if (shift_amount == 32) {
        *carry_out = (value & 1u) != 0;
        return 0;
      }
      *carry_out = false;
      return 0;
    }
    case 1: {  // LSR
      if (shift_amount == 0 || shift_amount == 32) {
        *carry_out = (value >> 31) != 0;
        return 0;
      }
      if (shift_amount > 32) {
        *carry_out = false;
        return 0;
      }
      *carry_out = ((value >> (shift_amount - 1u)) & 1u) != 0;
      return value >> shift_amount;
    }
    case 2: {  // ASR
      if (shift_amount == 0 || shift_amount >= 32) {
        *carry_out = (value >> 31) != 0;
        return (value & 0x80000000u) ? 0xFFFFFFFFu : 0u;
      }
      *carry_out = ((value >> (shift_amount - 1u)) & 1u) != 0;
      return static_cast<uint32_t>(static_cast<int32_t>(value) >> shift_amount);
    }
    case 3: {  // ROR / RRX
      if (shift_amount == 0) {  // RRX
        const bool old_c = GetFlagC();
        *carry_out = (value & 1u) != 0;
        return (old_c ? 0x80000000u : 0u) | (value >> 1);
      }
      const uint32_t rot = shift_amount & 31u;
      const uint32_t result = RotateRight(value, rot == 0 ? 32 : rot);
      *carry_out = (result >> 31) != 0;
      return result;
    }
    default:
      return value;
  }
}

bool GBACore::GetFlagC() const { return (cpu_.cpsr & (1u << 29)) != 0; }

void GBACore::SetFlagC(bool carry) {
  if (carry) {
    cpu_.cpsr |= (1u << 29);
  } else {
    cpu_.cpsr &= ~(1u << 29);
  }
}

uint32_t GBACore::ExpandArmImmediate(uint32_t imm12) const {
  const uint32_t imm8 = imm12 & 0xFFu;
  const uint32_t rotate = ((imm12 >> 8) & 0xFu) * 2u;
  return RotateRight(imm8, rotate);
}

bool GBACore::CheckCondition(uint32_t cond) const {
  const bool n = (cpu_.cpsr & (1u << 31)) != 0;
  const bool z = (cpu_.cpsr & (1u << 30)) != 0;
  const bool c = (cpu_.cpsr & (1u << 29)) != 0;
  const bool v = (cpu_.cpsr & (1u << 28)) != 0;

  switch (cond & 0xFu) {
    case 0x0: return z;                // EQ
    case 0x1: return !z;               // NE
    case 0x2: return c;                // CS/HS
    case 0x3: return !c;               // CC/LO
    case 0x4: return n;                // MI
    case 0x5: return !n;               // PL
    case 0x6: return v;                // VS
    case 0x7: return !v;               // VC
    case 0x8: return c && !z;          // HI
    case 0x9: return !c || z;          // LS
    case 0xA: return n == v;           // GE
    case 0xB: return n != v;           // LT
    case 0xC: return !z && (n == v);   // GT
    case 0xD: return z || (n != v);    // LE
    case 0xE: return true;             // AL
    default: return false;             // NV
  }
}

void GBACore::SetNZFlags(uint32_t value) {
  cpu_.cpsr = (cpu_.cpsr & ~((1u << 31) | (1u << 30))) |
              ((value & 0x80000000u) ? (1u << 31) : 0u) |
              ((value == 0) ? (1u << 30) : 0u);
}

void GBACore::SetAddFlags(uint32_t lhs, uint32_t rhs, uint64_t result64) {
  const uint32_t result32 = static_cast<uint32_t>(result64);
  SetNZFlags(result32);
  const bool carry = (result64 >> 32) != 0;
  const bool overflow = ((~(lhs ^ rhs) & (lhs ^ result32)) & 0x80000000u) != 0;
  cpu_.cpsr = (cpu_.cpsr & ~((1u << 29) | (1u << 28))) |
              (carry ? (1u << 29) : 0u) |
              (overflow ? (1u << 28) : 0u);
}

void GBACore::SetSubFlags(uint32_t lhs, uint32_t rhs, uint64_t result64) {
  const uint32_t result32 = static_cast<uint32_t>(result64);
  SetNZFlags(result32);
  const bool carry = lhs >= rhs;  // no borrow
  const bool overflow = (((lhs ^ rhs) & (lhs ^ result32)) & 0x80000000u) != 0;
  cpu_.cpsr = (cpu_.cpsr & ~((1u << 29) | (1u << 28))) |
              (carry ? (1u << 29) : 0u) |
              (overflow ? (1u << 28) : 0u);
}

uint32_t GBACore::GetCpuMode() const { return cpu_.cpsr & 0x1Fu; }

bool GBACore::IsPrivilegedMode(uint32_t mode) const { return mode != 0x10u; }

bool GBACore::HasSpsr(uint32_t mode) const {
  return mode == 0x11u || mode == 0x12u || mode == 0x13u || mode == 0x17u || mode == 0x1Bu;
}

void GBACore::SwitchCpuMode(uint32_t new_mode) {
  new_mode &= 0x1Fu;
  const uint32_t old_mode = cpu_.active_mode & 0x1Fu;
  if (old_mode == new_mode) return;
  if (old_mode == 0x11u) {  // Leaving FIQ: bank out R8-R12.
    for (size_t i = 0; i < cpu_.banked_fiq_r8_r12.size(); ++i) {
      cpu_.banked_fiq_r8_r12[i] = cpu_.regs[8 + i];
    }
  }
  cpu_.banked_sp[old_mode] = cpu_.regs[13];
  cpu_.banked_lr[old_mode] = cpu_.regs[14];
  if (new_mode == 0x11u) {  // Entering FIQ: bank in R8-R12.
    for (size_t i = 0; i < cpu_.banked_fiq_r8_r12.size(); ++i) {
      cpu_.regs[8 + i] = cpu_.banked_fiq_r8_r12[i];
    }
  }
  cpu_.regs[13] = cpu_.banked_sp[new_mode];
  cpu_.regs[14] = cpu_.banked_lr[new_mode];
  cpu_.active_mode = new_mode;
  cpu_.cpsr = (cpu_.cpsr & ~0x1Fu) | new_mode;
}

uint32_t GBACore::EstimateArmCycles(uint32_t opcode) const {
  if ((opcode & 0x0E000000u) == 0x0A000000u) return 3u;              // B/BL
  if ((opcode & 0x0E000000u) == 0x08000000u) return 2u;              // LDM/STM
  if ((opcode & 0x0C000000u) == 0x04000000u) return 2u;              // LDR/STR
  if ((opcode & 0x0FC000F0u) == 0x00000090u) return 2u;              // MUL/MLA
  if ((opcode & 0x0F8000F0u) == 0x00800090u) return 3u;              // UMULL/...
  if ((opcode & 0x0F000000u) == 0x0F000000u) return 3u;              // SWI
  return 1u;                                                          // ALU/other
}

uint32_t GBACore::EstimateThumbCycles(uint16_t opcode) const {
  if ((opcode & 0xF800u) == 0xE000u) return 3u;                      // B
  if ((opcode & 0xF000u) == 0xD000u) return 2u;                      // Bcond/SWI space
  if ((opcode & 0xF000u) == 0xC000u) return 2u;                      // LDMIA/STMIA
  if ((opcode & 0xE000u) == 0x6000u || (opcode & 0xF000u) == 0x8000u) return 2u;  // Load/store
  if ((opcode & 0xF800u) == 0x4800u) return 2u;                      // LDR literal
  return 1u;                                                          // ALU/other
}

void GBACore::HandleRegisterRamReset(uint8_t flags) {
  // SWI 01h RegisterRamReset
  if (flags & 0x01u) std::fill(ewram_.begin(), ewram_.end(), 0);
  if (flags & 0x02u) {
    // BIOS keeps the top 0x200 bytes of IWRAM (0x03007E00-0x03007FFF)
    // intact because they are used for IRQ vectors/stacks/work area.
    constexpr size_t kIwramReservedTail = 0x200u;
    if (iwram_.size() > kIwramReservedTail) {
      std::fill(iwram_.begin(), iwram_.end() - static_cast<std::ptrdiff_t>(kIwramReservedTail), 0);
    }
  }
  if (flags & 0x04u) std::fill(palette_ram_.begin(), palette_ram_.end(), 0);
  if (flags & 0x08u) std::fill(vram_.begin(), vram_.end(), 0);
  if (flags & 0x10u) std::fill(oam_.begin(), oam_.end(), 0);
}

void GBACore::HandleCpuSet(bool fast_mode) {
  const uint32_t src = cpu_.regs[0];
  const uint32_t dst = cpu_.regs[1];
  const uint32_t cnt = cpu_.regs[2];
  const bool fill = (cnt & (1u << 24)) != 0;
  const bool word32 = fast_mode || ((cnt & (1u << 26)) != 0);
  uint32_t units = cnt & 0x1FFFFFu;
  if (fast_mode) units = (cnt & 0x1FFFFFu) * 8u;

  if (units == 0) return;

  if (word32) {
    const uint32_t value = Read32(src & ~3u);
    for (uint32_t i = 0; i < units; ++i) {
      const uint32_t saddr = fill ? (src & ~3u) : ((src + i * 4u) & ~3u);
      const uint32_t daddr = (dst + i * 4u) & ~3u;
      Write32(daddr, fill ? value : Read32(saddr));
    }
  } else {
    const uint16_t value = Read16(src & ~1u);
    for (uint32_t i = 0; i < units; ++i) {
      const uint32_t saddr = fill ? (src & ~1u) : ((src + i * 2u) & ~1u);
      const uint32_t daddr = (dst + i * 2u) & ~1u;
      Write16(daddr, fill ? value : Read16(saddr));
    }
  }
}

bool GBACore::HandleSoftwareInterrupt(uint32_t swi_imm, bool thumb_state) {
  // When any BIOS image is mapped (external or built-in mGBA HLE BIOS),
  // dispatch SWI via SVC exception and let BIOS code execute the service.
  if (bios_loaded_) return false;

  const uint32_t next_pc = cpu_.regs[15] + (thumb_state ? 2u : 4u);
  switch (swi_imm & 0xFFu) {
    case 0x00u:  // SoftReset
      Reset();
      return true;
    case 0x01u:  // RegisterRamReset
      HandleRegisterRamReset(static_cast<uint8_t>(cpu_.regs[0] & 0xFFu));
      cpu_.regs[15] = next_pc;
      return true;
    case 0x04u:  // IntrWait
    case 0x05u: {  // VBlankIntrWait
      uint16_t request = 0;
      if ((swi_imm & 0xFFu) == 0x05u) {
        request = 0x0001u;  // VBlank
      } else {
        request = static_cast<uint16_t>(cpu_.regs[1] & 0x3FFFu);
        if (request == 0) request = 0x0001u;
      }
      // R0==0: discard already-raised requested IRQ flags before waiting.
      if ((cpu_.regs[0] & 0x1u) == 0u) {
        WriteIO16(0x04000202u, request);
      }
      const uint16_t ie = ReadIO16(0x04000200u);
      WriteIO16(0x04000200u, static_cast<uint16_t>(ie | request));
      WriteIO16(0x04000208u, 0x0001u);  // IME on
      swi_intrwait_active_ = true;
      swi_intrwait_mask_ = request;
      cpu_.halted = true;
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x02u:  // Halt
    case 0x03u:  // Stop (approximated as Halt)
      cpu_.halted = true;
      cpu_.regs[15] = next_pc;
      return true;
    case mgba_compat::kSwiDiv: {  // Div
      const int32_t num = static_cast<int32_t>(cpu_.regs[0]);
      const int32_t den = static_cast<int32_t>(cpu_.regs[1]);
      if (den == 0) {
        cpu_.regs[0] = static_cast<uint32_t>((num < 0) ? -1 : 1);
        cpu_.regs[1] = static_cast<uint32_t>(num);
        cpu_.regs[3] = 1;
      } else if (den == -1 && num == std::numeric_limits<int32_t>::min()) {
        cpu_.regs[0] = static_cast<uint32_t>(std::numeric_limits<int32_t>::min());
        cpu_.regs[1] = 0;
        cpu_.regs[3] = static_cast<uint32_t>(std::numeric_limits<int32_t>::min());
      } else {
        const std::div_t qr = std::div(num, den);
        const int32_t q = qr.quot;
        const int32_t r = qr.rem;
        cpu_.regs[0] = static_cast<uint32_t>(q);
        cpu_.regs[1] = static_cast<uint32_t>(r);
        cpu_.regs[3] = static_cast<uint32_t>(q < 0 ? -q : q);
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case mgba_compat::kSwiDivArm: {  // DivArm (R0=denom, R1=numer)
      const int32_t den = static_cast<int32_t>(cpu_.regs[0]);
      const int32_t num = static_cast<int32_t>(cpu_.regs[1]);
      if (den == 0) {
        cpu_.regs[0] = static_cast<uint32_t>((num < 0) ? -1 : 1);
        cpu_.regs[1] = static_cast<uint32_t>(num);
        cpu_.regs[3] = 1;
      } else if (den == -1 && num == std::numeric_limits<int32_t>::min()) {
        cpu_.regs[0] = static_cast<uint32_t>(std::numeric_limits<int32_t>::min());
        cpu_.regs[1] = 0;
        cpu_.regs[3] = static_cast<uint32_t>(std::numeric_limits<int32_t>::min());
      } else {
        const std::div_t qr = std::div(num, den);
        const int32_t q = qr.quot;
        const int32_t r = qr.rem;
        cpu_.regs[0] = static_cast<uint32_t>(q);
        cpu_.regs[1] = static_cast<uint32_t>(r);
        cpu_.regs[3] = static_cast<uint32_t>(q < 0 ? -q : q);
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case mgba_compat::kSwiSqrt: {  // Sqrt
      const uint32_t x = cpu_.regs[0];
      cpu_.regs[0] = BiosSqrt(x);
      cpu_.regs[15] = next_pc;
      return true;
    }
    case mgba_compat::kSwiArcTan: {  // ArcTan
      const int32_t tan_q14 = static_cast<int32_t>(cpu_.regs[0]);
      cpu_.regs[0] = static_cast<uint32_t>(static_cast<uint16_t>(BiosArcTanPoly(tan_q14)));
      cpu_.regs[15] = next_pc;
      return true;
    }
    case mgba_compat::kSwiArcTan2: {  // ArcTan2
      const int32_t x = static_cast<int32_t>(cpu_.regs[0]);
      const int32_t y = static_cast<int32_t>(cpu_.regs[1]);
      cpu_.regs[0] = static_cast<uint32_t>(static_cast<uint16_t>(BiosArcTan2(x, y)));
      cpu_.regs[3] = 0x170u;  // BIOS side-effect observed by many titles.
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x0Eu: {  // BgAffineSet
      uint32_t src = cpu_.regs[0];
      uint32_t dst = cpu_.regs[1];
      uint32_t count = cpu_.regs[2];
      while (count--) {
        const double ox = static_cast<double>(static_cast<int32_t>(Read32(src + 0u))) / 256.0;
        const double oy = static_cast<double>(static_cast<int32_t>(Read32(src + 4u))) / 256.0;
        const double cx = static_cast<double>(static_cast<int16_t>(Read16(src + 8u)));
        const double cy = static_cast<double>(static_cast<int16_t>(Read16(src + 10u)));
        const double sx = static_cast<double>(static_cast<int16_t>(Read16(src + 12u))) / 256.0;
        const double sy = static_cast<double>(static_cast<int16_t>(Read16(src + 14u))) / 256.0;
        const double theta =
            static_cast<double>((Read16(src + 16u) >> 8) & 0xFFu) / 128.0 * 3.14159265358979323846;
        src += 20u;

        const double cos_t = std::cos(theta);
        const double sin_t = std::sin(theta);
        const double a = cos_t * sx;
        const double b = -sin_t * sx;
        const double c = sin_t * sy;
        const double d = cos_t * sy;
        const double rx = ox - (a * cx + b * cy);
        const double ry = oy - (c * cx + d * cy);

        Write16(dst + 0u, static_cast<uint16_t>(static_cast<int16_t>(std::lround(a * 256.0))));
        Write16(dst + 2u, static_cast<uint16_t>(static_cast<int16_t>(std::lround(b * 256.0))));
        Write16(dst + 4u, static_cast<uint16_t>(static_cast<int16_t>(std::lround(c * 256.0))));
        Write16(dst + 6u, static_cast<uint16_t>(static_cast<int16_t>(std::lround(d * 256.0))));
        Write32(dst + 8u, static_cast<uint32_t>(static_cast<int32_t>(std::lround(rx * 256.0))));
        Write32(dst + 12u, static_cast<uint32_t>(static_cast<int32_t>(std::lround(ry * 256.0))));
        dst += 16u;
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x0Fu: {  // ObjAffineSet
      uint32_t src = cpu_.regs[0];
      uint32_t dst = cpu_.regs[1];
      uint32_t count = cpu_.regs[2];
      const uint32_t diff = cpu_.regs[3];
      while (count--) {
        const double sx = static_cast<double>(static_cast<int16_t>(Read16(src + 0u))) / 256.0;
        const double sy = static_cast<double>(static_cast<int16_t>(Read16(src + 2u))) / 256.0;
        const double theta =
            static_cast<double>((Read16(src + 4u) >> 8) & 0xFFu) / 128.0 * 3.14159265358979323846;
        src += 8u;
        const double cos_t = std::cos(theta);
        const double sin_t = std::sin(theta);
        const double a = cos_t * sx;
        const double b = -sin_t * sx;
        const double c = sin_t * sy;
        const double d = cos_t * sy;
        Write16(dst + 0u, static_cast<uint16_t>(static_cast<int16_t>(std::lround(a * 256.0))));
        Write16(dst + diff, static_cast<uint16_t>(static_cast<int16_t>(std::lround(b * 256.0))));
        Write16(dst + diff * 2u, static_cast<uint16_t>(static_cast<int16_t>(std::lround(c * 256.0))));
        Write16(dst + diff * 3u, static_cast<uint16_t>(static_cast<int16_t>(std::lround(d * 256.0))));
        dst += diff * 4u;
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x10u: {  // BitUnPack
      uint32_t src = cpu_.regs[0];
      uint32_t dst = cpu_.regs[1];
      const uint32_t info = cpu_.regs[2];
      uint32_t source_len = Read16(info + 0u);
      const uint32_t source_width = Read8(info + 2u);
      const uint32_t dest_width = Read8(info + 3u);
      if ((source_width != 1u && source_width != 2u && source_width != 4u && source_width != 8u) ||
          (dest_width != 1u && dest_width != 2u && dest_width != 4u && dest_width != 8u &&
           dest_width != 16u && dest_width != 32u)) {
        cpu_.regs[15] = next_pc;
        return true;
      }
      const uint32_t bias = Read32(info + 4u);
      uint8_t in = 0;
      uint32_t out = 0;
      int bits_remaining = 0;
      int bits_eaten = 0;
      while (source_len > 0 || bits_remaining > 0) {
        if (bits_remaining == 0) {
          in = Read8(src++);
          bits_remaining = 8;
          --source_len;
        }
        uint32_t scaled = static_cast<uint32_t>(in) & ((1u << source_width) - 1u);
        in = static_cast<uint8_t>(in >> source_width);
        if (scaled != 0u || (bias & 0x80000000u) != 0u) {
          scaled += (bias & 0x7FFFFFFFu);
        }
        bits_remaining -= static_cast<int>(source_width);
        out |= (scaled << bits_eaten);
        bits_eaten += static_cast<int>(dest_width);
        if (bits_eaten == 32) {
          Write32(dst, out);
          dst += 4u;
          out = 0;
          bits_eaten = 0;
        }
      }
      cpu_.regs[0] = src;
      cpu_.regs[1] = dst;
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x11u:  // LZ77UnCompWram
    case 0x12u: {  // LZ77UnCompVram
      uint32_t src = cpu_.regs[0];
      const uint32_t dst = cpu_.regs[1];
      const uint32_t header = Read32(src);
      src += 4u;
      if ((header & 0xFFu) != 0x10u) {
        cpu_.regs[15] = next_pc;
        return true;
      }
      const uint32_t out_size = header >> 8;
      std::vector<uint8_t> out;
      out.reserve(out_size);
      while (out.size() < out_size) {
        uint8_t flags = Read8(src++);
        for (int i = 0; i < 8 && out.size() < out_size; ++i) {
          if ((flags & 0x80u) != 0) {
            const uint8_t b1 = Read8(src++);
            const uint8_t b2 = Read8(src++);
            const uint32_t len = static_cast<uint32_t>((b1 >> 4) + 3u);
            const uint32_t disp = static_cast<uint32_t>(((b1 & 0x0Fu) << 8) | b2);
            if (disp + 1u > out.size()) break;
            size_t copy_from = out.size() - (disp + 1u);
            for (uint32_t j = 0; j < len && out.size() < out_size; ++j) {
              out.push_back(out[copy_from + j]);
            }
          } else {
            out.push_back(Read8(src++));
          }
          flags <<= 1;
        }
      }
      const bool to_vram = ((swi_imm & 0xFFu) == 0x12u);
      if (to_vram) {
        uint32_t i = 0;
        while (i < out.size()) {
          const uint16_t lo = out[i];
          const uint16_t hi = (i + 1 < out.size()) ? static_cast<uint16_t>(out[i + 1]) : 0u;
          Write16(dst + i, static_cast<uint16_t>(lo | (hi << 8)));
          i += 2;
        }
      } else {
        for (uint32_t i = 0; i < out.size(); ++i) {
          Write8(dst + i, out[i]);
        }
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x13u: {  // HuffUnComp (4-bit/8-bit)
      uint32_t src = cpu_.regs[0];
      const uint32_t dst = cpu_.regs[1];
      const uint32_t header = Read32(src);
      src += 4u;
      if ((header & 0xFFu) != 0x20u) {
        cpu_.regs[15] = next_pc;
        return true;
      }
      const uint32_t out_size = header >> 8;
      const uint8_t data_bits = Read8(src++);
      if (data_bits != 4u && data_bits != 8u) {
        cpu_.regs[15] = next_pc;
        return true;
      }
      const uint8_t tree_size_field = Read8(src++);
      const uint32_t tree_bytes = static_cast<uint32_t>(tree_size_field + 1u) * 2u;
      const uint32_t tree_base = src;
      uint32_t stream = src + tree_bytes;

      auto read_stream_bit = [&](uint32_t* ptr, uint32_t* bitbuf, int* bits_left) -> uint32_t {
        if (*bits_left == 0) {
          *bitbuf = Read32(*ptr);
          *ptr += 4u;
          *bits_left = 32;
        }
        const uint32_t bit = (*bitbuf >> 31) & 1u;
        *bitbuf <<= 1;
        --(*bits_left);
        return bit;
      };

      auto decode_symbol = [&](uint32_t* ptr, uint32_t* bitbuf, int* bits_left) -> uint8_t {
        uint32_t node_off = 0u;
        while (true) {
          const uint8_t node = Read8(tree_base + node_off);
          const uint32_t dir = read_stream_bit(ptr, bitbuf, bits_left);
          const uint32_t child_off = node_off + (static_cast<uint32_t>(node & 0x3Fu) + 1u) * 2u;
          const uint32_t entry_off = child_off + dir;
          const bool terminal = (node & (dir ? 0x80u : 0x40u)) != 0;
          if (terminal) {
            return Read8(tree_base + entry_off);
          }
          node_off = entry_off;
          if (node_off >= tree_bytes) return 0;
        }
      };

      std::vector<uint8_t> out;
      out.reserve(out_size);
      uint32_t bitbuf = 0;
      int bits_left = 0;
      if (data_bits == 8u) {
        while (out.size() < out_size) {
          out.push_back(decode_symbol(&stream, &bitbuf, &bits_left));
        }
      } else {  // 4-bit
        while (out.size() < out_size) {
          const uint8_t lo = static_cast<uint8_t>(decode_symbol(&stream, &bitbuf, &bits_left) & 0x0Fu);
          uint8_t byte = lo;
          if (out.size() + 1u < out_size) {
            const uint8_t hi = static_cast<uint8_t>(decode_symbol(&stream, &bitbuf, &bits_left) & 0x0Fu);
            byte = static_cast<uint8_t>(lo | (hi << 4));
          }
          out.push_back(byte);
        }
      }
      for (uint32_t i = 0; i < out.size(); ++i) {
        Write8(dst + i, out[i]);
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x14u:  // RLUnCompWram
    case 0x15u: {  // RLUnCompVram
      uint32_t src = cpu_.regs[0];
      const uint32_t dst = cpu_.regs[1];
      const uint32_t header = Read32(src);
      src += 4u;
      if ((header & 0xFFu) != 0x30u) {
        cpu_.regs[15] = next_pc;
        return true;
      }
      const uint32_t out_size = header >> 8;
      std::vector<uint8_t> out;
      out.reserve(out_size);
      while (out.size() < out_size) {
        const uint8_t ctrl = Read8(src++);
        if ((ctrl & 0x80u) != 0) {
          const uint32_t len = static_cast<uint32_t>((ctrl & 0x7Fu) + 3u);
          const uint8_t value = Read8(src++);
          for (uint32_t i = 0; i < len && out.size() < out_size; ++i) out.push_back(value);
        } else {
          const uint32_t len = static_cast<uint32_t>((ctrl & 0x7Fu) + 1u);
          for (uint32_t i = 0; i < len && out.size() < out_size; ++i) out.push_back(Read8(src++));
        }
      }
      const bool to_vram = ((swi_imm & 0xFFu) == 0x15u);
      if (to_vram) {
        uint32_t i = 0;
        while (i < out.size()) {
          const uint16_t lo = out[i];
          const uint16_t hi = (i + 1 < out.size()) ? static_cast<uint16_t>(out[i + 1]) : 0u;
          Write16(dst + i, static_cast<uint16_t>(lo | (hi << 8)));
          i += 2;
        }
      } else {
        for (uint32_t i = 0; i < out.size(); ++i) {
          Write8(dst + i, out[i]);
        }
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x16u:  // Diff8bitUnFilterWram
    case 0x17u: {  // Diff8bitUnFilterVram
      uint32_t src = cpu_.regs[0];
      const uint32_t dst = cpu_.regs[1];
      const uint32_t header = Read32(src);
      src += 4u;
      if ((header & 0xFFu) != 0x80u) {
        cpu_.regs[15] = next_pc;
        return true;
      }
      const uint32_t out_size = header >> 8;
      std::vector<uint8_t> out;
      out.reserve(out_size);
      uint8_t acc = 0;
      for (uint32_t i = 0; i < out_size; ++i) {
        const uint8_t delta = Read8(src++);
        if (i == 0) {
          acc = delta;
        } else {
          acc = static_cast<uint8_t>(acc + delta);
        }
        out.push_back(acc);
      }
      const bool to_vram = ((swi_imm & 0xFFu) == 0x17u);
      if (to_vram) {
        uint32_t i = 0;
        while (i < out.size()) {
          const uint16_t lo = out[i];
          const uint16_t hi = (i + 1 < out.size()) ? static_cast<uint16_t>(out[i + 1]) : 0u;
          Write16(dst + i, static_cast<uint16_t>(lo | (hi << 8)));
          i += 2;
        }
      } else {
        for (uint32_t i = 0; i < out.size(); ++i) {
          Write8(dst + i, out[i]);
        }
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x18u: {  // Diff16bitUnFilter
      uint32_t src = cpu_.regs[0];
      const uint32_t dst = cpu_.regs[1];
      const uint32_t header = Read32(src);
      src += 4u;
      if ((header & 0xFFu) != 0x80u) {
        cpu_.regs[15] = next_pc;
        return true;
      }
      const uint32_t out_size = header >> 8;
      uint16_t acc = 0;
      for (uint32_t i = 0; i + 1 < out_size; i += 2) {
        const uint16_t delta = Read16(src);
        src += 2u;
        if (i == 0) {
          acc = delta;
        } else {
          acc = static_cast<uint16_t>(acc + delta);
        }
        Write16(dst + i, acc);
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x0Bu:  // CpuSet
      HandleCpuSet(false);
      cpu_.regs[15] = next_pc;
      return true;
    case 0x0Cu:  // CpuFastSet
      HandleCpuSet(true);
      cpu_.regs[15] = next_pc;
      return true;
    case mgba_compat::kSwiGetBiosChecksum:  // GetBiosChecksum
      cpu_.regs[0] = mgba_compat::kBiosChecksum;
      cpu_.regs[1] = 1u;
      cpu_.regs[3] = 0x4000u;
      cpu_.regs[15] = next_pc;
      return true;
    default:
      return false;
  }
}

void GBACore::ExecuteArmInstruction(uint32_t opcode) {
  auto arm_reg_value = [&](uint32_t reg) -> uint32_t {
    if ((reg & 0xFu) == 15u) return cpu_.regs[15] + 8u;
    return cpu_.regs[reg & 0xFu];
  };
  auto arm_shift_operand_value = [&](uint32_t reg, bool reg_shift) -> uint32_t {
    if ((reg & 0xFu) != 15u) return cpu_.regs[reg & 0xFu];
    return cpu_.regs[15] + (reg_shift ? 12u : 8u);
  };

  const uint32_t cond = (opcode >> 28) & 0xFu;
  if (!CheckCondition(cond)) {
    cpu_.regs[15] += 4;
    return;
  }

  // BX Rm
  if ((opcode & 0x0FFFFFF0u) == 0x012FFF10u) {
    const uint32_t rm = opcode & 0xFu;
    const uint32_t target = arm_reg_value(rm);
    if (target & 1u) {
      cpu_.cpsr |= (1u << 5);  // Thumb bit.
      cpu_.regs[15] = target & ~1u;
    } else {
      cpu_.cpsr &= ~(1u << 5);
      cpu_.regs[15] = target & ~3u;
    }
    return;
  }

  // Branch
  if ((opcode & 0x0E000000u) == 0x0A000000u) {
    int32_t offset = static_cast<int32_t>(opcode & 0x00FFFFFFu);
    if (offset & 0x00800000u) offset |= ~0x00FFFFFF;
    offset <<= 2;
    if (opcode & (1u << 24)) {
      cpu_.regs[14] = cpu_.regs[15] + 4u;  // BL
    }
    cpu_.regs[15] = cpu_.regs[15] + 8u + static_cast<uint32_t>(offset);
    return;
  }

  // Halfword/signed data transfer (LDRH/STRH/LDRSB/LDRSH)
  if ((opcode & 0x0E000090u) == 0x00000090u && (opcode & 0x0FC000F0u) != 0x00000090u) {
    const bool pre = (opcode & (1u << 24)) != 0;
    const bool up = (opcode & (1u << 23)) != 0;
    const bool imm = (opcode & (1u << 22)) != 0;
    const bool write_back = (opcode & (1u << 21)) != 0;
    const bool load = (opcode & (1u << 20)) != 0;
    const uint32_t rn = (opcode >> 16) & 0xFu;
    const uint32_t rd = (opcode >> 12) & 0xFu;
    const uint32_t s = (opcode >> 6) & 0x1u;
    const uint32_t h = (opcode >> 5) & 0x1u;

    uint32_t offset = 0;
    if (imm) {
      offset = ((opcode >> 8) & 0xFu) << 4;
      offset |= (opcode & 0xFu);
    } else {
      offset = arm_reg_value(opcode & 0xFu);
    }

    uint32_t addr = arm_reg_value(rn);
    if (pre) {
      addr = up ? (addr + offset) : (addr - offset);
    }

    if (load) {
      uint32_t value = 0;
      if (s == 0u && h == 1u) {  // LDRH
        value = Read16(addr & ~1u);
      } else if (s == 1u && h == 0u) {  // LDRSB
        value = static_cast<uint32_t>(static_cast<int32_t>(static_cast<int8_t>(Read8(addr))));
      } else if (s == 1u && h == 1u) {  // LDRSH
        if (addr & 1u) {
          value = static_cast<uint32_t>(static_cast<int32_t>(static_cast<int8_t>(Read8(addr))));
        } else {
          value = static_cast<uint32_t>(static_cast<int32_t>(static_cast<int16_t>(Read16(addr))));
        }
      } else {
        EnterException(0x00000004u, 0x1Bu, true, false);  // Undefined instruction
        return;
      }
      cpu_.regs[rd] = value;
    } else {
      if (s == 0u && h == 1u) {  // STRH
        Write16(addr & ~1u, static_cast<uint16_t>(arm_reg_value(rd) & 0xFFFFu));
      } else {
        cpu_.regs[15] += 4;
        return;
      }
    }

    if (!pre) {
      addr = up ? (addr + offset) : (addr - offset);
    }
    if (write_back || !pre) cpu_.regs[rn] = addr;
    cpu_.regs[15] += 4;
    return;
  }

  // MUL / MLA
  if ((opcode & 0x0FC000F0u) == 0x00000090u) {
    const bool set_flags = (opcode & (1u << 20)) != 0;
    const bool accumulate = (opcode & (1u << 21)) != 0;
    const uint32_t rd = (opcode >> 16) & 0xFu;
    const uint32_t rn = (opcode >> 12) & 0xFu;
    const uint32_t rs = (opcode >> 8) & 0xFu;
    const uint32_t rm = opcode & 0xFu;
    uint32_t result = arm_reg_value(rm) * arm_reg_value(rs);
    if (accumulate) result += arm_reg_value(rn);
    cpu_.regs[rd] = result;
    if (set_flags) SetNZFlags(result);
    cpu_.regs[15] += 4;
    return;
  }

  // UMULL/UMLAL/SMULL/SMLAL
  if ((opcode & 0x0F8000F0u) == 0x00800090u) {
    const bool signed_mul = (opcode & (1u << 22)) != 0;
    const bool accumulate = (opcode & (1u << 21)) != 0;
    const bool set_flags = (opcode & (1u << 20)) != 0;
    const uint32_t rd_hi = (opcode >> 16) & 0xFu;
    const uint32_t rd_lo = (opcode >> 12) & 0xFu;
    const uint32_t rs = (opcode >> 8) & 0xFu;
    const uint32_t rm = opcode & 0xFu;

    uint64_t result = 0;
    if (signed_mul) {
      const int64_t a = static_cast<int64_t>(static_cast<int32_t>(arm_reg_value(rm)));
      const int64_t b = static_cast<int64_t>(static_cast<int32_t>(arm_reg_value(rs)));
      int64_t wide = a * b;
      if (accumulate) {
        const uint64_t acc_u = (static_cast<uint64_t>(cpu_.regs[rd_hi]) << 32) | cpu_.regs[rd_lo];
        wide += static_cast<int64_t>(acc_u);
      }
      result = static_cast<uint64_t>(wide);
    } else {
      result = static_cast<uint64_t>(arm_reg_value(rm)) * static_cast<uint64_t>(arm_reg_value(rs));
      if (accumulate) {
        const uint64_t acc = (static_cast<uint64_t>(cpu_.regs[rd_hi]) << 32) | cpu_.regs[rd_lo];
        result += acc;
      }
    }

    cpu_.regs[rd_lo] = static_cast<uint32_t>(result & 0xFFFFFFFFu);
    cpu_.regs[rd_hi] = static_cast<uint32_t>(result >> 32);
    if (set_flags) {
      const uint32_t nz = cpu_.regs[rd_hi] | cpu_.regs[rd_lo];
      SetNZFlags(nz);
    }
    cpu_.regs[15] += 4;
    return;
  }

  // SWP/SWPB
  if ((opcode & 0x0FB00FF0u) == 0x01000090u) {
    const bool byte = (opcode & (1u << 22)) != 0;
    const uint32_t rn = (opcode >> 16) & 0xFu;
    const uint32_t rd = (opcode >> 12) & 0xFu;
    const uint32_t rm = opcode & 0xFu;
    const uint32_t addr = arm_reg_value(rn);
    if (byte) {
      const uint8_t old = Read8(addr);
      Write8(addr, static_cast<uint8_t>(arm_reg_value(rm) & 0xFFu));
      cpu_.regs[rd] = old;
    } else {
      const uint32_t aligned = addr & ~3u;
      const uint32_t old = Read32(aligned);
      Write32(aligned, arm_reg_value(rm));
      cpu_.regs[rd] = old;
    }
    cpu_.regs[15] += 4;
    return;
  }

  // CLZ
  if ((opcode & 0x0FFF0FF0u) == 0x016F0F10u) {
    const uint32_t rd = (opcode >> 12) & 0xFu;
    const uint32_t rm = opcode & 0xFu;
    cpu_.regs[rd] = static_cast<uint32_t>(std::countl_zero(cpu_.regs[rm]));
    cpu_.regs[15] += 4;
    return;
  }

  // LDM/STM
  if ((opcode & 0x0E000000u) == 0x08000000u) {
    const uint32_t rn = (opcode >> 16) & 0xFu;
    const bool load = (opcode & (1u << 20)) != 0;
    const bool write_back = (opcode & (1u << 21)) != 0;
    const bool psr_or_user = (opcode & (1u << 22)) != 0;
    const bool up = (opcode & (1u << 23)) != 0;
    const bool pre = (opcode & (1u << 24)) != 0;
    const uint32_t reg_list = opcode & 0xFFFFu;
    const uint32_t count = std::popcount(reg_list);
    if (count == 0) {  // ARMv4 treats empty list as transfer of R15.
      const uint32_t base = cpu_.regs[rn];
      const uint32_t addr = up ? (pre ? base + 4u : base) : (pre ? base - 4u : base);
      if (load) {
        cpu_.regs[15] = Read32(addr) & ~3u;
        return;
      } else {
        Write32(addr, cpu_.regs[15] + 4u);
      }
      if (write_back) cpu_.regs[rn] = up ? (base + 0x40u) : (base - 0x40u);
      cpu_.regs[15] += 4;
      return;
    }

    const uint32_t base = cpu_.regs[rn];
    uint32_t start_addr = base;
    if (up) {
      start_addr = pre ? (base + 4u) : base;
    } else {
      start_addr = pre ? (base - 4u * count) : (base - 4u * (count - 1u));
    }
    uint32_t addr = start_addr;
    for (int r = 0; r < 16; ++r) {
      if ((reg_list & (1u << r)) == 0) continue;
      if (load) {
        cpu_.regs[r] = Read32(addr);
      } else {
        uint32_t value = arm_reg_value(r);
        if (r == 15) value += 4u;
        Write32(addr, value);
      }
      addr += 4u;
    }
    if (load && psr_or_user && (reg_list & (1u << 15)) && HasSpsr(GetCpuMode())) {
      const uint32_t old_mode = GetCpuMode();
      const uint32_t restored = cpu_.spsr[old_mode];
      cpu_.cpsr = restored;
      const uint32_t new_mode = restored & 0x1Fu;
      if (new_mode != old_mode) {
        SwitchCpuMode(new_mode);
      } else {
        cpu_.active_mode = new_mode;
      }
    }
    if (write_back && !(load && (reg_list & (1u << rn)))) {
      cpu_.regs[rn] = up ? (base + 4u * count) : (base - 4u * count);
    }
    if (load && (reg_list & (1u << 15))) {
      if (cpu_.cpsr & (1u << 5)) {
        cpu_.regs[15] &= ~1u;
      } else {
        cpu_.regs[15] &= ~3u;
      }
      return;
    }
    cpu_.regs[15] += 4;
    return;
  }

  // Halfword / signed transfer (LDRH/LDRSH/LDRSB/STRH)
  if ((opcode & 0x0E000090u) == 0x00000090u && (opcode & 0x0F000000u) == 0x00000000u) {
    const bool pre = (opcode & (1u << 24)) != 0;
    const bool up = (opcode & (1u << 23)) != 0;
    const bool imm = (opcode & (1u << 22)) != 0;
    const bool write_back = (opcode & (1u << 21)) != 0;
    const bool load = (opcode & (1u << 20)) != 0;
    const uint32_t rn = (opcode >> 16) & 0xFu;
    const uint32_t rd = (opcode >> 12) & 0xFu;
    const uint32_t sh = (opcode >> 5) & 0x3u;
    const uint32_t offset = imm ? (((opcode >> 8) & 0xFu) << 4u) | (opcode & 0xFu)
                                : arm_reg_value(opcode & 0xFu);

    uint32_t addr = arm_reg_value(rn);
    if (pre) addr = up ? (addr + offset) : (addr - offset);

    if (load) {
      if (sh == 0x1) {  // LDRH
        cpu_.regs[rd] = Read16(addr & ~1u);
      } else if (sh == 0x2) {  // LDRSB
        cpu_.regs[rd] = static_cast<uint32_t>(static_cast<int32_t>(static_cast<int8_t>(Read8(addr))));
      } else if (sh == 0x3) {  // LDRSH
        cpu_.regs[rd] = static_cast<uint32_t>(static_cast<int32_t>(static_cast<int16_t>(Read16(addr & ~1u))));
      }
    } else if (sh == 0x1) {  // STRH only
      Write16(addr & ~1u, static_cast<uint16_t>(cpu_.regs[rd] & 0xFFFFu));
    }

    if (!pre) addr = up ? (addr + offset) : (addr - offset);
    if (write_back || !pre) cpu_.regs[rn] = addr;
    cpu_.regs[15] += 4;
    return;
  }

  // LDR/STR immediate / register offset
  if ((opcode & 0x0C000000u) == 0x04000000u) {
    const uint32_t rn = (opcode >> 16) & 0xFu;
    const uint32_t rd = (opcode >> 12) & 0xFu;
    const bool load = (opcode & (1u << 20)) != 0;
    const bool byte = (opcode & (1u << 22)) != 0;
    const bool up = (opcode & (1u << 23)) != 0;
    const bool pre = (opcode & (1u << 24)) != 0;
    const bool write_back = (opcode & (1u << 21)) != 0;
    const bool imm = (opcode & (1u << 25)) == 0;
    uint32_t offset = 0;
    if (imm) {
      offset = opcode & 0xFFFu;
    } else {
      const uint32_t rm = opcode & 0xFu;
      const uint32_t shift_type = (opcode >> 5) & 0x3u;
      const uint32_t shift_imm = (opcode >> 7) & 0x1Fu;
      bool ignored_carry = false;
      offset = ApplyShift(cpu_.regs[rm], shift_type, shift_imm, &ignored_carry);
    }
    uint32_t addr = arm_reg_value(rn);
    if (pre) {
      addr = up ? (addr + offset) : (addr - offset);
    }
    if (load) {
      if (byte) {
        cpu_.regs[rd] = Read8(addr);
      } else {
        const uint32_t aligned = addr & ~3u;
        const uint32_t raw = Read32(aligned);
        const uint32_t rot = (addr & 3u) * 8u;
        cpu_.regs[rd] = (rot == 0) ? raw : RotateRight(raw, rot);
      }
    } else {
      if (byte) {
        Write8(addr, static_cast<uint8_t>(cpu_.regs[rd] & 0xFFu));
      } else {
        Write32(addr & ~3u, cpu_.regs[rd]);
      }
    }
    if (!pre) {
      addr = up ? (addr + offset) : (addr - offset);
    }
    if (write_back || !pre) cpu_.regs[rn] = addr;
    cpu_.regs[15] += 4;
    return;
  }

  // MRS CPSR/SPSR
  if ((opcode & 0x0FBF0FFFu) == 0x010F0000u) {
    const uint32_t rd = (opcode >> 12) & 0xFu;
    const bool use_spsr = (opcode & (1u << 22)) != 0;
    const uint32_t mode = GetCpuMode();
    cpu_.regs[rd] = (use_spsr && HasSpsr(mode)) ? cpu_.spsr[mode] : cpu_.cpsr;
    cpu_.regs[15] += 4;
    return;
  }
  // MSR CPSR/SPSR with field mask support
  if ((opcode & 0x0DB0F000u) == 0x0120F000u) {
    const bool use_imm = (opcode & (1u << 25)) != 0;
    const bool write_spsr = (opcode & (1u << 22)) != 0;
    const uint32_t field_mask = (opcode >> 16) & 0xFu;
    uint32_t value = 0;
    if (use_imm) {
      value = ExpandArmImmediate(opcode & 0xFFFu);
    } else {
      value = cpu_.regs[opcode & 0xFu];
    }
    uint32_t mask = 0;
    if (field_mask & 0x8u) mask |= 0xFF000000u;
    if (field_mask & 0x4u) mask |= 0x00FF0000u;
    if (field_mask & 0x2u) mask |= 0x0000FF00u;
    if (field_mask & 0x1u) mask |= 0x000000FFu;
    if (mask == 0) {
      cpu_.regs[15] += 4;
      return;
    }

    const uint32_t mode = GetCpuMode();
    if (write_spsr) {
      if (HasSpsr(mode)) cpu_.spsr[mode] = (cpu_.spsr[mode] & ~mask) | (value & mask);
      cpu_.regs[15] += 4;
      return;
    }

    if (!IsPrivilegedMode(mode)) {
      mask &= 0xF0000000u;  // User mode can only update condition flags.
    }
    const uint32_t new_cpsr = (cpu_.cpsr & ~mask) | (value & mask);
    const uint32_t old_mode = GetCpuMode();
    const uint32_t new_mode = new_cpsr & 0x1Fu;
    cpu_.cpsr = new_cpsr;
    if (new_mode != old_mode && IsPrivilegedMode(old_mode)) {
      SwitchCpuMode(new_mode);
    } else {
      cpu_.active_mode = GetCpuMode();
    }
    cpu_.regs[15] += 4;
    return;
  }

  // SWI
  if ((opcode & 0x0F000000u) == 0x0F000000u) {
    if (HandleSoftwareInterrupt(opcode & 0x00FFFFFFu, false)) return;
    EnterException(0x00000008u, 0x13u, true, false);  // SVC mode
    return;
  }

  // Data processing (expanded subset)
  if ((opcode & 0x0C000000u) == 0x00000000u) {
    const bool imm = (opcode & (1u << 25)) != 0;
    const bool set_flags = (opcode & (1u << 20)) != 0;
    const uint32_t op = (opcode >> 21) & 0xFu;
    const uint32_t rn = (opcode >> 16) & 0xFu;
    const uint32_t rd = (opcode >> 12) & 0xFu;
    uint32_t operand2 = 0;
    bool shifter_carry = GetFlagC();
    if (imm) {
      const uint32_t rotate = ((opcode >> 8) & 0xFu) * 2u;
      operand2 = ExpandArmImmediate(opcode & 0xFFFu);
      if (rotate != 0) shifter_carry = (operand2 >> 31) != 0;
    } else {
      const uint32_t rm = opcode & 0xFu;
      const bool reg_shift = (opcode & (1u << 4)) != 0;
      const uint32_t shift_type = (opcode >> 5) & 0x3u;
      uint32_t shift_amount = 0;
      if (reg_shift) {
        const uint32_t rs = (opcode >> 8) & 0xFu;
        shift_amount = arm_reg_value(rs) & 0xFFu;
      } else {
        shift_amount = (opcode >> 7) & 0x1Fu;
      }
      operand2 = ApplyShift(arm_shift_operand_value(rm, reg_shift), shift_type, shift_amount, &shifter_carry);
    }

    auto set_logic_flags = [&](uint32_t value) {
      SetNZFlags(value);
      SetFlagC(shifter_carry);
    };
    auto do_add = [&](uint32_t lhs, uint32_t rhs, uint32_t carry_in, uint32_t* out) {
      const uint64_t r64 = static_cast<uint64_t>(lhs) + static_cast<uint64_t>(rhs) + carry_in;
      *out = static_cast<uint32_t>(r64);
      if (set_flags) SetAddFlags(lhs, rhs + carry_in, r64);
    };
    auto do_sub = [&](uint32_t lhs, uint32_t rhs, uint32_t borrow, uint32_t* out) {
      const uint64_t r64 = static_cast<uint64_t>(lhs) - static_cast<uint64_t>(rhs) - borrow;
      *out = static_cast<uint32_t>(r64);
      if (set_flags) SetSubFlags(lhs, rhs + borrow, r64);
    };

    bool writes_result = true;
    switch (op) {
      case 0x0: { // AND
        const uint32_t r = arm_reg_value(rn) & operand2;
        cpu_.regs[rd] = r;
        if (set_flags) set_logic_flags(r);
        break;
      }
      case 0x1: { // EOR
        const uint32_t r = arm_reg_value(rn) ^ operand2;
        cpu_.regs[rd] = r;
        if (set_flags) set_logic_flags(r);
        break;
      }
      case 0x2: { // SUB
        const uint64_t r64 = static_cast<uint64_t>(arm_reg_value(rn)) - static_cast<uint64_t>(operand2);
        cpu_.regs[rd] = static_cast<uint32_t>(r64);
        if (set_flags) SetSubFlags(arm_reg_value(rn), operand2, r64);
        break;
      }
      case 0x3: { // RSB
        const uint64_t r64 = static_cast<uint64_t>(operand2) - static_cast<uint64_t>(arm_reg_value(rn));
        cpu_.regs[rd] = static_cast<uint32_t>(r64);
        if (set_flags) SetSubFlags(operand2, arm_reg_value(rn), r64);
        break;
      }
      case 0x4: { // ADD
        const uint64_t r64 = static_cast<uint64_t>(arm_reg_value(rn)) + static_cast<uint64_t>(operand2);
        cpu_.regs[rd] = static_cast<uint32_t>(r64);
        if (set_flags) SetAddFlags(arm_reg_value(rn), operand2, r64);
        break;
      }
      case 0x5: { // ADC
        uint32_t r = 0;
        do_add(arm_reg_value(rn), operand2, GetFlagC() ? 1u : 0u, &r);
        cpu_.regs[rd] = r;
        break;
      }
      case 0x6: { // SBC
        uint32_t r = 0;
        do_sub(arm_reg_value(rn), operand2, GetFlagC() ? 0u : 1u, &r);
        cpu_.regs[rd] = r;
        break;
      }
      case 0x7: { // RSC
        uint32_t r = 0;
        do_sub(operand2, arm_reg_value(rn), GetFlagC() ? 0u : 1u, &r);
        cpu_.regs[rd] = r;
        break;
      }
      case 0x8: { // TST
        writes_result = false;
        set_logic_flags(arm_reg_value(rn) & operand2);
        break;
      }
      case 0x9: { // TEQ
        writes_result = false;
        set_logic_flags(arm_reg_value(rn) ^ operand2);
        break;
      }
      case 0xA: { // CMP
        writes_result = false;
        const uint64_t r64 = static_cast<uint64_t>(arm_reg_value(rn)) - static_cast<uint64_t>(operand2);
        SetSubFlags(arm_reg_value(rn), operand2, r64);
        break;
      }
      case 0xB: { // CMN
        writes_result = false;
        const uint64_t r64 = static_cast<uint64_t>(arm_reg_value(rn)) + static_cast<uint64_t>(operand2);
        SetAddFlags(arm_reg_value(rn), operand2, r64);
        break;
      }
      case 0xC: { // ORR
        const uint32_t r = arm_reg_value(rn) | operand2;
        cpu_.regs[rd] = r;
        if (set_flags) set_logic_flags(r);
        break;
      }
      case 0xD: { // MOV
        cpu_.regs[rd] = operand2;
        if (set_flags) set_logic_flags(operand2);
        break;
      }
      case 0xE: { // BIC
        const uint32_t r = arm_reg_value(rn) & ~operand2;
        cpu_.regs[rd] = r;
        if (set_flags) set_logic_flags(r);
        break;
      }
      case 0xF: { // MVN
        const uint32_t r = ~operand2;
        cpu_.regs[rd] = r;
        if (set_flags) set_logic_flags(r);
        break;
      }
      default:
        EnterException(0x00000004u, 0x1Bu, true, false);  // Undefined instruction
        return;
    }

    if (writes_result && rd == 15) {
      if (set_flags && HasSpsr(GetCpuMode())) {
        const uint32_t old_mode = GetCpuMode();
        const uint32_t restored = cpu_.spsr[old_mode];
        cpu_.cpsr = restored;
        const uint32_t new_mode = restored & 0x1Fu;
        if (new_mode != old_mode) {
          SwitchCpuMode(new_mode);
        } else {
          cpu_.active_mode = new_mode;
        }
      }
      if (cpu_.cpsr & (1u << 5)) {
        cpu_.regs[15] &= ~1u;
      } else {
        cpu_.regs[15] &= ~3u;
      }
      return;
    }
    cpu_.regs[15] += 4;
    return;
  }

  EnterException(0x00000004u, 0x1Bu, true, false);  // Undefined instruction
  return;
}

void GBACore::ExecuteThumbInstruction(uint16_t opcode) {
  // Shift by immediate (LSL/LSR/ASR)
  // Thumb format 1 is 000xx (xx=00/01/10). Exclude 00011 (ADD/SUB format 2).
  if ((opcode & 0xE000u) == 0x0000u && (opcode & 0x1800u) != 0x1800u) {
    const uint16_t shift_type = (opcode >> 11) & 0x3u;
    const uint16_t imm5 = (opcode >> 6) & 0x1Fu;
    const uint16_t rs = (opcode >> 3) & 0x7u;
    const uint16_t rd = opcode & 0x7u;
    bool carry = GetFlagC();
    const uint32_t result = ApplyShift(cpu_.regs[rs], shift_type, imm5, &carry);
    cpu_.regs[rd] = result;
    SetNZFlags(result);
    SetFlagC(carry);
    cpu_.regs[15] += 2;
    return;
  }

  // Add/sub register or immediate3
  if ((opcode & 0xF800u) == 0x1800u) {
    const bool immediate = (opcode & (1u << 10)) != 0;
    const bool sub = (opcode & (1u << 9)) != 0;
    const uint16_t rn_or_imm3 = (opcode >> 6) & 0x7u;
    const uint16_t rs = (opcode >> 3) & 0x7u;
    const uint16_t rd = opcode & 0x7u;
    const uint32_t rhs = immediate ? rn_or_imm3 : cpu_.regs[rn_or_imm3];
    uint64_t r64 = 0;
    if (sub) {
      r64 = static_cast<uint64_t>(cpu_.regs[rs]) - static_cast<uint64_t>(rhs);
      cpu_.regs[rd] = static_cast<uint32_t>(r64);
      SetSubFlags(cpu_.regs[rs], rhs, r64);
    } else {
      r64 = static_cast<uint64_t>(cpu_.regs[rs]) + static_cast<uint64_t>(rhs);
      cpu_.regs[rd] = static_cast<uint32_t>(r64);
      SetAddFlags(cpu_.regs[rs], rhs, r64);
    }
    cpu_.regs[15] += 2;
    return;
  }

  // MOV/CMP/ADD/SUB immediate (001xx)
  if ((opcode & 0xE000u) == 0x2000u) {
    const uint16_t op = (opcode >> 11) & 0x3u;
    const uint16_t rd = (opcode >> 8) & 0x7u;
    const uint32_t imm8 = opcode & 0xFFu;
    switch (op) {
      case 0:  // MOV
        cpu_.regs[rd] = imm8;
        SetNZFlags(cpu_.regs[rd]);
        break;
      case 1: {  // CMP
        const uint64_t r64 = static_cast<uint64_t>(cpu_.regs[rd]) - static_cast<uint64_t>(imm8);
        SetSubFlags(cpu_.regs[rd], imm8, r64);
        break;
      }
      case 2: {  // ADD
        const uint32_t lhs = cpu_.regs[rd];
        const uint64_t r64 = static_cast<uint64_t>(lhs) + static_cast<uint64_t>(imm8);
        cpu_.regs[rd] = static_cast<uint32_t>(r64);
        SetAddFlags(lhs, imm8, r64);
        break;
      }
      case 3: {  // SUB
        const uint32_t lhs = cpu_.regs[rd];
        const uint64_t r64 = static_cast<uint64_t>(lhs) - static_cast<uint64_t>(imm8);
        cpu_.regs[rd] = static_cast<uint32_t>(r64);
        SetSubFlags(lhs, imm8, r64);
        break;
      }
    }
    cpu_.regs[15] += 2;
    return;
  }

  // ALU operations
  if ((opcode & 0xFC00u) == 0x4000u) {
    const uint16_t alu_op = (opcode >> 6) & 0xFu;
    const uint16_t rs = (opcode >> 3) & 0x7u;
    const uint16_t rd = opcode & 0x7u;
    switch (alu_op) {
      case 0x0: { cpu_.regs[rd] &= cpu_.regs[rs]; SetNZFlags(cpu_.regs[rd]); break; }           // AND
      case 0x1: { cpu_.regs[rd] ^= cpu_.regs[rs]; SetNZFlags(cpu_.regs[rd]); break; }           // EOR
      case 0x2: {  // LSL reg
        bool c = GetFlagC();
        cpu_.regs[rd] = ApplyShift(cpu_.regs[rd], 0, cpu_.regs[rs] & 0xFFu, &c);
        SetNZFlags(cpu_.regs[rd]);
        SetFlagC(c);
        break;
      }
      case 0x3: {  // LSR reg
        bool c = GetFlagC();
        cpu_.regs[rd] = ApplyShift(cpu_.regs[rd], 1, cpu_.regs[rs] & 0xFFu, &c);
        SetNZFlags(cpu_.regs[rd]);
        SetFlagC(c);
        break;
      }
      case 0x4: {  // ASR reg
        bool c = GetFlagC();
        cpu_.regs[rd] = ApplyShift(cpu_.regs[rd], 2, cpu_.regs[rs] & 0xFFu, &c);
        SetNZFlags(cpu_.regs[rd]);
        SetFlagC(c);
        break;
      }
      case 0x5: {  // ADC
        const uint32_t lhs = cpu_.regs[rd];
        const uint32_t rhs = cpu_.regs[rs];
        const uint32_t carry = GetFlagC() ? 1u : 0u;
        const uint64_t r64 = static_cast<uint64_t>(lhs) + static_cast<uint64_t>(rhs) + carry;
        cpu_.regs[rd] = static_cast<uint32_t>(r64);
        SetAddFlags(lhs, rhs + carry, r64);
        break;
      }
      case 0x6: {  // SBC
        const uint32_t lhs = cpu_.regs[rd];
        const uint32_t rhs = cpu_.regs[rs];
        const uint32_t borrow = GetFlagC() ? 0u : 1u;
        const uint64_t r64 = static_cast<uint64_t>(lhs) - static_cast<uint64_t>(rhs) - borrow;
        cpu_.regs[rd] = static_cast<uint32_t>(r64);
        SetSubFlags(lhs, rhs + borrow, r64);
        break;
      }
      case 0x7: {  // ROR
        bool c = GetFlagC();
        const uint32_t amount = cpu_.regs[rs] & 0xFFu;
        cpu_.regs[rd] = ApplyShift(cpu_.regs[rd], 3, amount, &c);
        SetNZFlags(cpu_.regs[rd]);
        SetFlagC(c);
        break;
      }
      case 0x8: {  // TST
        SetNZFlags(cpu_.regs[rd] & cpu_.regs[rs]);
        break;
      }
      case 0x9: {  // NEG
        const uint32_t rhs = cpu_.regs[rs];
        const uint64_t r64 = static_cast<uint64_t>(0) - static_cast<uint64_t>(rhs);
        cpu_.regs[rd] = static_cast<uint32_t>(r64);
        SetSubFlags(0u, rhs, r64);
        break;
      }
      case 0xA: {  // CMP
        const uint64_t r64 = static_cast<uint64_t>(cpu_.regs[rd]) - static_cast<uint64_t>(cpu_.regs[rs]);
        SetSubFlags(cpu_.regs[rd], cpu_.regs[rs], r64);
        break;
      }
      case 0xB: {  // CMN
        const uint64_t r64 = static_cast<uint64_t>(cpu_.regs[rd]) + static_cast<uint64_t>(cpu_.regs[rs]);
        SetAddFlags(cpu_.regs[rd], cpu_.regs[rs], r64);
        break;
      }
      case 0xC: { cpu_.regs[rd] |= cpu_.regs[rs]; SetNZFlags(cpu_.regs[rd]); break; }           // ORR
      case 0xD: {  // MUL
        cpu_.regs[rd] *= cpu_.regs[rs];
        SetNZFlags(cpu_.regs[rd]);
        break;
      }
      case 0xE: { cpu_.regs[rd] &= ~cpu_.regs[rs]; SetNZFlags(cpu_.regs[rd]); break; }           // BIC
      case 0xF: { cpu_.regs[rd] = ~cpu_.regs[rs]; SetNZFlags(cpu_.regs[rd]); break; }            // MVN
      default:
        break;
    }
    cpu_.regs[15] += 2;
    return;
  }

  // High register operations / BX
  if ((opcode & 0xFC00u) == 0x4400u) {
    const uint16_t op = (opcode >> 8) & 0x3u;
    const uint16_t h1 = (opcode >> 7) & 0x1u;
    const uint16_t h2 = (opcode >> 6) & 0x1u;
    const uint16_t rs = ((h2 << 3) | ((opcode >> 3) & 0x7u)) & 0xFu;
    const uint16_t rd = ((h1 << 3) | (opcode & 0x7u)) & 0xFu;
    if (op == 3) {  // BX
      const uint32_t target = cpu_.regs[rs];
      if (target & 1u) {
        cpu_.cpsr |= (1u << 5);
        cpu_.regs[15] = target & ~1u;
      } else {
        cpu_.cpsr &= ~(1u << 5);
        cpu_.regs[15] = target & ~3u;
      }
      return;
    }
    if (op == 0) {  // ADD
      cpu_.regs[rd] += cpu_.regs[rs];
      if (rd == 15) {
        cpu_.regs[15] &= ~1u;
        return;
      }
    } else if (op == 1) {  // CMP
      const uint64_t r64 = static_cast<uint64_t>(cpu_.regs[rd]) - static_cast<uint64_t>(cpu_.regs[rs]);
      SetSubFlags(cpu_.regs[rd], cpu_.regs[rs], r64);
    } else if (op == 2) {  // MOV
      cpu_.regs[rd] = cpu_.regs[rs];
      if (rd == 15) {
        cpu_.regs[15] &= ~1u;
        return;
      }
    }
    cpu_.regs[15] += 2;
    return;
  }

  // PC-relative load
  if ((opcode & 0xF800u) == 0x4800u) {
    const uint16_t rd = (opcode >> 8) & 0x7u;
    const uint32_t imm = (opcode & 0xFFu) << 2u;
    const uint32_t base = (cpu_.regs[15] + 4u) & ~3u;
    cpu_.regs[rd] = Read32(base + imm);
    cpu_.regs[15] += 2;
    return;
  }

  // Load/store with register offset
  if ((opcode & 0xF200u) == 0x5000u) {
    const bool load = (opcode & (1u << 11)) != 0;
    const bool byte = (opcode & (1u << 10)) != 0;
    const uint16_t ro = (opcode >> 6) & 0x7u;
    const uint16_t rb = (opcode >> 3) & 0x7u;
    const uint16_t rd = opcode & 0x7u;
    const uint32_t addr = cpu_.regs[rb] + cpu_.regs[ro];
    if (load) {
      if (byte) {
        cpu_.regs[rd] = Read8(addr);
      } else {
        const uint32_t aligned = addr & ~3u;
        const uint32_t raw = Read32(aligned);
        const uint32_t rot = (addr & 3u) * 8u;
        cpu_.regs[rd] = (rot == 0) ? raw : RotateRight(raw, rot);
      }
    } else if (byte) {
      Write8(addr, static_cast<uint8_t>(cpu_.regs[rd] & 0xFFu));
    } else {
      Write32(addr & ~3u, cpu_.regs[rd]);
    }
    cpu_.regs[15] += 2;
    return;
  }

  // Load/store sign-extended byte/halfword
  if ((opcode & 0xF200u) == 0x5200u) {
    const uint16_t op = (opcode >> 10) & 0x3u;
    const uint16_t ro = (opcode >> 6) & 0x7u;
    const uint16_t rb = (opcode >> 3) & 0x7u;
    const uint16_t rd = opcode & 0x7u;
    const uint32_t addr = cpu_.regs[rb] + cpu_.regs[ro];
    switch (op) {
      case 0x0: Write16(addr & ~1u, static_cast<uint16_t>(cpu_.regs[rd])); break;  // STRH
      case 0x1: cpu_.regs[rd] = Read16(addr & ~1u); break;                          // LDRH
      case 0x2: cpu_.regs[rd] = static_cast<uint32_t>(static_cast<int8_t>(Read8(addr))); break;  // LDSB
      case 0x3:
        if (addr & 1u) {
          cpu_.regs[rd] = static_cast<uint32_t>(static_cast<int8_t>(Read8(addr)));
        } else {
          cpu_.regs[rd] = static_cast<uint32_t>(static_cast<int16_t>(Read16(addr)));
        }
        break; // LDSH
    }
    cpu_.regs[15] += 2;
    return;
  }

  // Load/store immediate offset
  if ((opcode & 0xE000u) == 0x6000u) {
    const bool load = (opcode & (1u << 11)) != 0;
    const bool byte = (opcode & (1u << 12)) != 0;
    const uint16_t imm5 = (opcode >> 6) & 0x1Fu;
    const uint16_t rb = (opcode >> 3) & 0x7u;
    const uint16_t rd = opcode & 0x7u;
    const uint32_t offset = byte ? imm5 : (imm5 << 2u);
    const uint32_t addr = cpu_.regs[rb] + offset;
    if (load) {
      if (byte) {
        cpu_.regs[rd] = Read8(addr);
      } else {
        const uint32_t aligned = addr & ~3u;
        const uint32_t raw = Read32(aligned);
        const uint32_t rot = (addr & 3u) * 8u;
        cpu_.regs[rd] = (rot == 0) ? raw : RotateRight(raw, rot);
      }
    } else if (byte) {
      Write8(addr, static_cast<uint8_t>(cpu_.regs[rd]));
    } else {
      Write32(addr & ~3u, cpu_.regs[rd]);
    }
    cpu_.regs[15] += 2;
    return;
  }

  // Load/store halfword immediate
  if ((opcode & 0xF000u) == 0x8000u) {
    const bool load = (opcode & (1u << 11)) != 0;
    const uint16_t imm5 = (opcode >> 6) & 0x1Fu;
    const uint16_t rb = (opcode >> 3) & 0x7u;
    const uint16_t rd = opcode & 0x7u;
    const uint32_t addr = cpu_.regs[rb] + (imm5 << 1u);
    if (load) {
      cpu_.regs[rd] = Read16(addr & ~1u);
    } else {
      Write16(addr & ~1u, static_cast<uint16_t>(cpu_.regs[rd] & 0xFFFFu));
    }
    cpu_.regs[15] += 2;
    return;
  }

  // SP-relative load/store
  if ((opcode & 0xF000u) == 0x9000u) {
    const bool load = (opcode & (1u << 11)) != 0;
    const uint16_t rd = (opcode >> 8) & 0x7u;
    const uint32_t imm = (opcode & 0xFFu) << 2u;
    const uint32_t addr = cpu_.regs[13] + imm;
    if (load) {
      cpu_.regs[rd] = Read32(addr & ~3u);
    } else {
      Write32(addr & ~3u, cpu_.regs[rd]);
    }
    cpu_.regs[15] += 2;
    return;
  }

  // ADD to PC/SP
  if ((opcode & 0xF000u) == 0xA000u) {
    const bool use_sp = (opcode & (1u << 11)) != 0;
    const uint16_t rd = (opcode >> 8) & 0x7u;
    const uint32_t imm = (opcode & 0xFFu) << 2u;
    const uint32_t base = use_sp ? cpu_.regs[13] : ((cpu_.regs[15] + 4u) & ~3u);
    cpu_.regs[rd] = base + imm;
    cpu_.regs[15] += 2;
    return;
  }

  // ADD/SUB SP immediate
  if ((opcode & 0xFF00u) == 0xB000u) {
    const bool sub = (opcode & (1u << 7)) != 0;
    const uint32_t imm = (opcode & 0x7Fu) << 2u;
    cpu_.regs[13] = sub ? (cpu_.regs[13] - imm) : (cpu_.regs[13] + imm);
    cpu_.regs[15] += 2;
    return;
  }

  // PUSH/POP
  if ((opcode & 0xF600u) == 0xB400u) {
    const bool load = (opcode & (1u << 11)) != 0;  // POP when set
    const bool r = (opcode & (1u << 8)) != 0;      // LR/PC bit
    const uint16_t reg_list = opcode & 0xFFu;
    if (!load) {  // PUSH
      if (r) {
        cpu_.regs[13] -= 4u;
        Write32(cpu_.regs[13], cpu_.regs[14]);
      }
      for (int i = 7; i >= 0; --i) {
        if (reg_list & (1u << i)) {
          cpu_.regs[13] -= 4u;
          Write32(cpu_.regs[13], cpu_.regs[i]);
        }
      }
    } else {      // POP
      for (int i = 0; i < 8; ++i) {
        if (reg_list & (1u << i)) {
          cpu_.regs[i] = Read32(cpu_.regs[13]);
          cpu_.regs[13] += 4u;
        }
      }
      if (r) {
        const uint32_t target = Read32(cpu_.regs[13]);
        if (target & 1u) {
          cpu_.cpsr |= (1u << 5);   // stay/enter Thumb
          cpu_.regs[15] = target & ~1u;
        } else {
          cpu_.cpsr &= ~(1u << 5);  // switch to ARM
          cpu_.regs[15] = target & ~3u;
        }
        cpu_.regs[13] += 4u;
        return;
      }
    }
    cpu_.regs[15] += 2;
    return;
  }

  // LDMIA/STMIA
  if ((opcode & 0xF000u) == 0xC000u) {
    const bool load = (opcode & (1u << 11)) != 0;
    const uint16_t rb = (opcode >> 8) & 0x7u;
    const uint16_t reg_list = opcode & 0xFFu;
    uint32_t addr = cpu_.regs[rb];
    for (int i = 0; i < 8; ++i) {
      if ((reg_list & (1u << i)) == 0) continue;
      if (load) {
        cpu_.regs[i] = Read32(addr);
      } else {
        Write32(addr, cpu_.regs[i]);
      }
      addr += 4u;
    }
    cpu_.regs[rb] = addr;
    cpu_.regs[15] += 2;
    return;
  }

  // Thumb SWI
  if ((opcode & 0xFF00u) == 0xDF00u) {
    if (HandleSoftwareInterrupt(opcode & 0x00FFu, true)) return;
    EnterException(0x00000008u, 0x13u, true, false);  // SVC mode
    return;
  }

  // Conditional branch
  if ((opcode & 0xF000u) == 0xD000u && (opcode & 0x0F00u) != 0x0F00u) {
    const uint32_t cond = (opcode >> 8) & 0xFu;
    int32_t offset = static_cast<int32_t>(opcode & 0xFFu);
    if (offset & 0x80) offset |= ~0xFF;
    offset <<= 1;
    if (CheckCondition(cond)) {
      cpu_.regs[15] = cpu_.regs[15] + 4u + static_cast<uint32_t>(offset);
    } else {
      cpu_.regs[15] += 2;
    }
    return;
  }

  // Long branch with link (Thumb BL pair, minimal handling)
  if ((opcode & 0xF800u) == 0xF000u || (opcode & 0xF800u) == 0xF800u) {
    const bool second = (opcode & 0x0800u) != 0;
    const int32_t off11 = static_cast<int32_t>(opcode & 0x07FFu);
    if (!second) {
      int32_t hi = off11;
      if (hi & 0x400) hi |= ~0x7FF;
      cpu_.regs[14] = cpu_.regs[15] + 4u + static_cast<uint32_t>(hi << 12);
      cpu_.regs[15] += 2;
    } else {
      const uint32_t target = cpu_.regs[14] + static_cast<uint32_t>(off11 << 1);
      cpu_.regs[14] = (cpu_.regs[15] + 2u) | 1u;
      cpu_.regs[15] = target & ~1u;
    }
    return;
  }

  // Unconditional branch (11100)
  if ((opcode & 0xF800u) == 0xE000u) {
    int32_t offset = static_cast<int32_t>(opcode & 0x07FFu);
    if (offset & 0x400) offset |= ~0x7FF;
    offset <<= 1;
    cpu_.regs[15] = cpu_.regs[15] + 4u + static_cast<uint32_t>(offset);
    return;
  }

  // Canonical Thumb NOP (MOV r8, r8)
  if (opcode == 0x46C0u) {
    cpu_.regs[15] += 2;
    return;
  }

  EnterException(0x00000004u, 0x1Bu, true, false);  // Undefined instruction
}

void GBACore::RunCpuSlice(uint32_t cycles) {
  if (cpu_.halted) {
    bool woke_from_intrwait = false;
    if (swi_intrwait_active_) {
      const uint16_t iflags = ReadIO16(0x04000202u);
      const uint16_t matched = static_cast<uint16_t>(iflags & swi_intrwait_mask_);
      if (matched != 0u) {
        WriteIO16(0x04000202u, matched);
        swi_intrwait_active_ = false;
        swi_intrwait_mask_ = 0;
        cpu_.halted = false;
        woke_from_intrwait = true;
      }
    }
    if (!woke_from_intrwait) {
      const uint16_t ie = ReadIO16(0x04000200u);
      const uint16_t iflags = ReadIO16(0x04000202u);
      if ((ie & iflags) == 0) return;
      cpu_.halted = false;
    }
  }
  auto is_exec_addr_valid = [&](uint32_t addr) -> bool {
    if (bios_loaded_ && addr < 0x00004000u) return true;  // BIOS
    if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) return true;  // EWRAM mirror
    if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) return true;  // IWRAM mirror
    if (addr >= 0x08000000u && addr <= 0x0DFFFFFFu) return true;  // ROM mirrors
    return false;
  };
  uint32_t consumed = 0;
  while (consumed < cycles) {
    ServiceInterruptIfNeeded();
    const uint32_t pc = cpu_.regs[15];
    if (cpu_.cpsr & (1u << 5)) {
      const uint16_t opcode = Read16(pc);
      consumed += EstimateThumbCycles(opcode);
      ExecuteThumbInstruction(opcode);
    } else {
      const uint32_t opcode = Read32(pc);
      consumed += EstimateArmCycles(opcode);
      ExecuteArmInstruction(opcode);
    }
    // Keep PC sane when branch jumps outside executable mapped ranges.
    // Do not remap valid BIOS/IWRAM/EWRAM/ROM addresses.
    if (!is_exec_addr_valid(cpu_.regs[15])) {
      const uint32_t mask = (cpu_.cpsr & (1u << 5)) ? 0x1FFFFFEu : 0x1FFFFFCu;
      cpu_.regs[15] = 0x08000000u + static_cast<uint32_t>((cpu_.regs[15] & mask) % std::max<size_t>(4, rom_.size()));
    }
  }
}

void GBACore::DebugStepCpuInstructions(uint32_t count) {
  for (uint32_t i = 0; i < count; ++i) {
    if (cpu_.halted) {
      bool woke_from_intrwait = false;
      if (swi_intrwait_active_) {
        const uint16_t iflags = ReadIO16(0x04000202u);
        const uint16_t matched = static_cast<uint16_t>(iflags & swi_intrwait_mask_);
        if (matched != 0u) {
          WriteIO16(0x04000202u, matched);
          swi_intrwait_active_ = false;
          swi_intrwait_mask_ = 0;
          cpu_.halted = false;
          woke_from_intrwait = true;
        }
      }
      if (!woke_from_intrwait) {
        const uint16_t ie = ReadIO16(0x04000200u);
        const uint16_t iflags = ReadIO16(0x04000202u);
        if ((ie & iflags) == 0) return;
        cpu_.halted = false;
      }
    }
    ServiceInterruptIfNeeded();
    if (cpu_.cpsr & (1u << 5)) {
      const uint16_t opcode = Read16(cpu_.regs[15]);
      ExecuteThumbInstruction(opcode);
    } else {
      const uint32_t opcode = Read32(cpu_.regs[15]);
      ExecuteArmInstruction(opcode);
    }
  }
}

}  // namespace gba

// ---- END gba_core_cpu.cpp ----
// ---- BEGIN gba_core_memory.cpp ----
#include "gba_core.h"

namespace gba {
namespace {
inline uint32_t MirrorOffset(uint32_t addr, uint32_t base, uint32_t mask) {
  return (addr - base) & mask;
}

inline uint32_t VramOffset(uint32_t addr) {
  uint32_t off32 = MirrorOffset(addr, 0x06000000u, 0x1FFFFu);
  if (off32 >= 0x18000u) off32 -= 0x8000u;
  return off32;
}
}  // namespace

uint32_t GBACore::Read32(uint32_t addr) const {
  // 0x00000000-0x00003FFF: BIOS
  if (bios_loaded_ && addr < 0x00004000u) {
    if (cpu_.regs[15] < 0x00004000u) {
      const uint32_t off32 = addr & 0x3FFFu;
      if (off32 <= bios_.size() - 4) {
        const size_t off = static_cast<size_t>(off32);
        bios_latch_ = static_cast<uint32_t>(bios_[off]) |
                      (static_cast<uint32_t>(bios_[off + 1]) << 8) |
                      (static_cast<uint32_t>(bios_[off + 2]) << 16) |
                      (static_cast<uint32_t>(bios_[off + 3]) << 24);
        return bios_latch_;
      }
    }
    return bios_latch_;
  }
  // 0x02000000-0x02FFFFFF: EWRAM mirror (256KB)
  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x02000000u, 0x3FFFFu);
    if (off32 <= ewram_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint32_t>(ewram_[off]) |
             (static_cast<uint32_t>(ewram_[off + 1]) << 8) |
             (static_cast<uint32_t>(ewram_[off + 2]) << 16) |
             (static_cast<uint32_t>(ewram_[off + 3]) << 24);
    }
  }
  // 0x03000000-0x03FFFFFF: IWRAM mirror (32KB)
  if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x03000000u, 0x7FFFu);
    if (off32 <= iwram_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint32_t>(iwram_[off]) |
             (static_cast<uint32_t>(iwram_[off + 1]) << 8) |
             (static_cast<uint32_t>(iwram_[off + 2]) << 16) |
             (static_cast<uint32_t>(iwram_[off + 3]) << 24);
    }
  }
  // 0x04000000-0x040003FF: IO
  if (addr >= 0x04000000u && addr <= 0x040003FCu) {
    const uint32_t off32 = addr - 0x04000000u;
    if (off32 <= io_regs_.size() - 4) {
      const uint16_t lo = ReadIO16(addr);
      const uint16_t hi = ReadIO16(addr + 2);
      return static_cast<uint32_t>(lo) | (static_cast<uint32_t>(hi) << 16);
    }
  }
  // 0x05000000-0x050003FF: Palette RAM
  if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x05000000u, 0x3FFu);
    if (off32 <= palette_ram_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint32_t>(palette_ram_[off]) |
             (static_cast<uint32_t>(palette_ram_[off + 1]) << 8) |
             (static_cast<uint32_t>(palette_ram_[off + 2]) << 16) |
             (static_cast<uint32_t>(palette_ram_[off + 3]) << 24);
    }
  }
  // 0x06000000-0x06017FFF: VRAM
  if (addr >= 0x06000000u && addr <= 0x06FFFFFFu) {
    const uint32_t off32 = VramOffset(addr);
    if (off32 <= vram_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint32_t>(vram_[off]) |
             (static_cast<uint32_t>(vram_[off + 1]) << 8) |
             (static_cast<uint32_t>(vram_[off + 2]) << 16) |
             (static_cast<uint32_t>(vram_[off + 3]) << 24);
    }
  }
  // 0x07000000-0x070003FF: OAM
  if (addr >= 0x07000000u && addr <= 0x07FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x07000000u, 0x3FFu);
    if (off32 <= oam_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint32_t>(oam_[off]) |
             (static_cast<uint32_t>(oam_[off + 1]) << 8) |
             (static_cast<uint32_t>(oam_[off + 2]) << 16) |
             (static_cast<uint32_t>(oam_[off + 3]) << 24);
    }
  }
  // 0x0E000000-0x0E00FFFF: SRAM/Flash window (modeled as SRAM)
  if (addr >= 0x0E000000u) {
    return static_cast<uint32_t>(ReadBackup8(addr)) |
           (static_cast<uint32_t>(ReadBackup8(addr + 1)) << 8) |
           (static_cast<uint32_t>(ReadBackup8(addr + 2)) << 16) |
           (static_cast<uint32_t>(ReadBackup8(addr + 3)) << 24);
  }
  // 0x08000000-0x0DFFFFFF: ROM mirror (32MB window)
  if (addr >= 0x08000000u && addr <= 0x0DFFFFFFu) {
    if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u) {
      return static_cast<uint32_t>(ReadBackup8(addr)) |
             (static_cast<uint32_t>(ReadBackup8(addr + 1u)) << 8) |
             (static_cast<uint32_t>(ReadBackup8(addr + 2u)) << 16) |
             (static_cast<uint32_t>(ReadBackup8(addr + 3u)) << 24);
    }
    if (!rom_.empty()) {
      const size_t base = static_cast<size_t>((addr - 0x08000000u) & 0x01FFFFFFu);
      const size_t off0 = base % rom_.size();
      const size_t off1 = (base + 1u) % rom_.size();
      const size_t off2 = (base + 2u) % rom_.size();
      const size_t off3 = (base + 3u) % rom_.size();
      return static_cast<uint32_t>(rom_[off0]) |
             (static_cast<uint32_t>(rom_[off1]) << 8) |
             (static_cast<uint32_t>(rom_[off2]) << 16) |
             (static_cast<uint32_t>(rom_[off3]) << 24);
    }
  }
  return 0;
}

uint16_t GBACore::Read16(uint32_t addr) const {
  if (bios_loaded_ && addr < 0x00004000u) {
    if (cpu_.regs[15] < 0x00004000u) {
      const uint32_t off32 = addr & 0x3FFFu;
      if (off32 <= bios_.size() - 2) {
        const size_t off = static_cast<size_t>(off32);
        const uint16_t value = static_cast<uint16_t>(bios_[off]) |
                               static_cast<uint16_t>(bios_[off + 1] << 8);
        const uint32_t shift = (addr & 2u) * 8u;
        bios_latch_ = (bios_latch_ & ~(0xFFFFu << shift)) | (static_cast<uint32_t>(value) << shift);
        return value;
      }
    }
    return static_cast<uint16_t>((bios_latch_ >> ((addr & 2u) * 8u)) & 0xFFFFu);
  }
  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x02000000u, 0x3FFFFu);
    if (off32 <= ewram_.size() - 2) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint16_t>(ewram_[off]) |
             static_cast<uint16_t>(ewram_[off + 1] << 8);
    }
  }
  if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x03000000u, 0x7FFFu);
    if (off32 <= iwram_.size() - 2) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint16_t>(iwram_[off]) |
             static_cast<uint16_t>(iwram_[off + 1] << 8);
    }
  }
  if (addr >= 0x08000000u && addr <= 0x0DFFFFFFu) {
    if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u) {
      return static_cast<uint16_t>(ReadBackup8(addr)) |
             static_cast<uint16_t>(ReadBackup8(addr + 1u) << 8);
    }
    if (!rom_.empty()) {
      const size_t base = static_cast<size_t>((addr - 0x08000000u) & 0x01FFFFFFu);
      const size_t off0 = base % rom_.size();
      const size_t off1 = (base + 1u) % rom_.size();
      return static_cast<uint16_t>(rom_[off0]) |
             static_cast<uint16_t>(rom_[off1] << 8);
    }
  }
  if (addr >= 0x04000000u && addr <= 0x040003FEu) {
    const uint32_t off32 = addr - 0x04000000u;
    if (off32 <= io_regs_.size() - 2) {
      return ReadIO16(addr & ~1u);
    }
  }
  if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x05000000u, 0x3FFu);
    if (off32 <= palette_ram_.size() - 2) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint16_t>(palette_ram_[off]) |
             static_cast<uint16_t>(palette_ram_[off + 1] << 8);
    }
  }
  if (addr >= 0x06000000u && addr <= 0x06FFFFFFu) {
    const uint32_t off32 = VramOffset(addr);
    if (off32 <= vram_.size() - 2) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint16_t>(vram_[off]) |
             static_cast<uint16_t>(vram_[off + 1] << 8);
    }
  }
  if (addr >= 0x07000000u && addr <= 0x07FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x07000000u, 0x3FFu);
    if (off32 <= oam_.size() - 2) {
      const size_t off = static_cast<size_t>(off32);
      return static_cast<uint16_t>(oam_[off]) |
             static_cast<uint16_t>(oam_[off + 1] << 8);
    }
  }
  if (addr >= 0x0E000000u) {
    return static_cast<uint16_t>(ReadBackup8(addr)) |
           static_cast<uint16_t>(ReadBackup8(addr + 1) << 8);
  }
  return 0;
}

uint8_t GBACore::Read8(uint32_t addr) const {
  if (bios_loaded_ && addr < 0x00004000u) {
    if (cpu_.regs[15] < 0x00004000u) {
      const uint8_t value = bios_[static_cast<size_t>(addr & 0x3FFFu)];
      const uint32_t shift = (addr & 3u) * 8u;
      bios_latch_ = (bios_latch_ & ~(0xFFu << shift)) | (static_cast<uint32_t>(value) << shift);
      return value;
    }
    return static_cast<uint8_t>((bios_latch_ >> ((addr & 3u) * 8u)) & 0xFFu);
  }
  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x02000000u, 0x3FFFFu);
    if (off32 < ewram_.size()) {
      return ewram_[static_cast<size_t>(off32)];
    }
  }
  if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x03000000u, 0x7FFFu);
    if (off32 < iwram_.size()) {
      return iwram_[static_cast<size_t>(off32)];
    }
  }
  if (addr >= 0x08000000u && addr <= 0x0DFFFFFFu) {
    if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u) {
      return ReadBackup8(addr);
    }
    if (!rom_.empty()) {
      const size_t off = static_cast<size_t>((addr - 0x08000000u) & 0x01FFFFFFu) % rom_.size();
      return rom_[off];
    }
  }
  if (addr >= 0x04000000u && addr <= 0x040003FFu) {
    const uint32_t off32 = addr - 0x04000000u;
    if (off32 < io_regs_.size()) {
      const uint16_t half = ReadIO16(addr & ~1u);
      return static_cast<uint8_t>((addr & 1u) ? ((half >> 8) & 0xFFu) : (half & 0xFFu));
    }
  }
  if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x05000000u, 0x3FFu);
    if (off32 < palette_ram_.size()) return palette_ram_[static_cast<size_t>(off32)];
  }
  if (addr >= 0x06000000u && addr <= 0x06FFFFFFu) {
    const uint32_t off32 = VramOffset(addr);
    if (off32 < vram_.size()) return vram_[static_cast<size_t>(off32)];
  }
  if (addr >= 0x07000000u && addr <= 0x07FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x07000000u, 0x3FFu);
    if (off32 < oam_.size()) return oam_[static_cast<size_t>(off32)];
  }
  if (addr >= 0x0E000000u) {
    return ReadBackup8(addr);
  }
  return 0;
}

void GBACore::Write32(uint32_t addr, uint32_t value) {
  if (addr == 0x040000A0u || addr == 0x040000A4u) {
    PushAudioFifo(addr == 0x040000A0u, value);
    return;
  }
  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x02000000u, 0x3FFFFu);
    if (off32 <= ewram_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      ewram_[off] = static_cast<uint8_t>(value & 0xFF);
      ewram_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
      ewram_[off + 2] = static_cast<uint8_t>((value >> 16) & 0xFF);
      ewram_[off + 3] = static_cast<uint8_t>((value >> 24) & 0xFF);
      return;
    }
  }
  if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x03000000u, 0x7FFFu);
    if (off32 <= iwram_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      iwram_[off] = static_cast<uint8_t>(value & 0xFF);
      iwram_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
      iwram_[off + 2] = static_cast<uint8_t>((value >> 16) & 0xFF);
      iwram_[off + 3] = static_cast<uint8_t>((value >> 24) & 0xFF);
      return;
    }
  }
  if (addr >= 0x04000000u && addr <= 0x040003FCu) {
    const uint32_t off32 = addr - 0x04000000u;
    if (off32 <= io_regs_.size() - 4) {
      WriteIO16(addr, static_cast<uint16_t>(value & 0xFFFFu));
      WriteIO16(addr + 2, static_cast<uint16_t>((value >> 16) & 0xFFFFu));
      return;
    }
  }
  if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x05000000u, 0x3FFu);
    if (off32 <= palette_ram_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      palette_ram_[off] = static_cast<uint8_t>(value & 0xFF);
      palette_ram_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
      palette_ram_[off + 2] = static_cast<uint8_t>((value >> 16) & 0xFF);
      palette_ram_[off + 3] = static_cast<uint8_t>((value >> 24) & 0xFF);
      return;
    }
  }
  if (addr >= 0x06000000u && addr <= 0x06FFFFFFu) {
    const uint32_t off32 = VramOffset(addr);
    if (off32 <= vram_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      vram_[off] = static_cast<uint8_t>(value & 0xFF);
      vram_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
      vram_[off + 2] = static_cast<uint8_t>((value >> 16) & 0xFF);
      vram_[off + 3] = static_cast<uint8_t>((value >> 24) & 0xFF);
      return;
    }
  }
  if (addr >= 0x07000000u && addr <= 0x07FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x07000000u, 0x3FFu);
    if (off32 <= oam_.size() - 4) {
      const size_t off = static_cast<size_t>(off32);
      oam_[off] = static_cast<uint8_t>(value & 0xFF);
      oam_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
      oam_[off + 2] = static_cast<uint8_t>((value >> 16) & 0xFF);
      oam_[off + 3] = static_cast<uint8_t>((value >> 24) & 0xFF);
      return;
    }
  }
  if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u && addr <= 0x0DFFFFFFu) {
    WriteBackup8(addr, static_cast<uint8_t>(value & 0x1u));
    WriteBackup8(addr + 1u, static_cast<uint8_t>((value >> 8) & 0x1u));
    WriteBackup8(addr + 2u, static_cast<uint8_t>((value >> 16) & 0x1u));
    WriteBackup8(addr + 3u, static_cast<uint8_t>((value >> 24) & 0x1u));
    return;
  }
  if (addr >= 0x0E000000u) {
    WriteBackup8(addr, static_cast<uint8_t>(value & 0xFFu));
    WriteBackup8(addr + 1, static_cast<uint8_t>((value >> 8) & 0xFFu));
    WriteBackup8(addr + 2, static_cast<uint8_t>((value >> 16) & 0xFFu));
    WriteBackup8(addr + 3, static_cast<uint8_t>((value >> 24) & 0xFFu));
    return;
  }
}

void GBACore::Write16(uint32_t addr, uint16_t value) {
  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x02000000u, 0x3FFFFu);
    if (off32 <= ewram_.size() - 2) {
      const size_t off = static_cast<size_t>(off32);
      ewram_[off] = static_cast<uint8_t>(value & 0xFF);
      ewram_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
      return;
    }
  }
  if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x03000000u, 0x7FFFu);
    if (off32 <= iwram_.size() - 2) {
      const size_t off = static_cast<size_t>(off32);
      iwram_[off] = static_cast<uint8_t>(value & 0xFF);
      iwram_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
      return;
    }
  }
  if (addr >= 0x04000000u && addr <= 0x040003FEu) {
    const uint32_t off32 = addr - 0x04000000u;
    if (off32 <= io_regs_.size() - 2) {
      WriteIO16(addr & ~1u, value);
      return;
    }
  }
  if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x05000000u, 0x3FFu);
    if (off32 <= palette_ram_.size() - 2) {
      const size_t off = static_cast<size_t>(off32);
      palette_ram_[off] = static_cast<uint8_t>(value & 0xFF);
      palette_ram_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
      return;
    }
  }
  if (addr >= 0x06000000u && addr <= 0x06FFFFFFu) {
    const uint32_t off32 = VramOffset(addr);
    if (off32 <= vram_.size() - 2) {
      const size_t off = static_cast<size_t>(off32);
      vram_[off] = static_cast<uint8_t>(value & 0xFF);
      vram_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
      return;
    }
  }
  if (addr >= 0x07000000u && addr <= 0x07FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x07000000u, 0x3FFu);
    if (off32 <= oam_.size() - 2) {
      const size_t off = static_cast<size_t>(off32);
      oam_[off] = static_cast<uint8_t>(value & 0xFF);
      oam_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
      return;
    }
  }
  if (addr >= 0x0E000000u) {
    WriteBackup8(addr, static_cast<uint8_t>(value & 0xFFu));
    WriteBackup8(addr + 1, static_cast<uint8_t>((value >> 8) & 0xFFu));
    return;
  }
  if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u && addr <= 0x0DFFFFFFu) {
    WriteBackup8(addr, static_cast<uint8_t>(value & 0x1u));
    WriteBackup8(addr + 1u, static_cast<uint8_t>((value >> 8) & 0x1u));
    return;
  }
}

void GBACore::Write8(uint32_t addr, uint8_t value) {
  if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x02000000u, 0x3FFFFu);
    if (off32 < ewram_.size()) {
      ewram_[static_cast<size_t>(off32)] = value;
      return;
    }
  }
  if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr, 0x03000000u, 0x7FFFu);
    if (off32 < iwram_.size()) {
      iwram_[static_cast<size_t>(off32)] = value;
      return;
    }
  }
  if (addr >= 0x05000000u && addr <= 0x05FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr & ~1u, 0x05000000u, 0x3FFu);
    if (off32 + 1u < palette_ram_.size()) {
      const size_t off = static_cast<size_t>(off32);
      palette_ram_[off] = value;
      palette_ram_[off + 1] = value;
      return;
    }
  }
  if (addr >= 0x06000000u && addr <= 0x06FFFFFFu) {
    const uint32_t off32 = VramOffset(addr & ~1u);
    if (off32 + 1u < vram_.size()) {
      const size_t off = static_cast<size_t>(off32);
      vram_[off] = value;
      vram_[off + 1] = value;
      return;
    }
  }
  if (addr >= 0x07000000u && addr <= 0x07FFFFFFu) {
    const uint32_t off32 = MirrorOffset(addr & ~1u, 0x07000000u, 0x3FFu);
    if (off32 + 1u < oam_.size()) {
      const size_t off = static_cast<size_t>(off32);
      oam_[off] = value;
      oam_[off + 1] = value;
      return;
    }
  }
  if (addr >= 0x0E000000u) {
    WriteBackup8(addr, value);
    return;
  }
  if (backup_type_ == BackupType::kEEPROM && addr >= 0x0D000000u && addr <= 0x0DFFFFFFu) {
    WriteBackup8(addr, static_cast<uint8_t>(value & 0x1u));
    return;
  }
  if (addr >= 0x04000000u && addr <= 0x040003FFu) {
    const uint32_t off32 = addr - 0x04000000u;
    if (off32 < io_regs_.size()) {
      const uint16_t old = ReadIO16(addr & ~1u);
      if (addr & 1u) {
        WriteIO16(addr & ~1u, static_cast<uint16_t>((old & 0x00FFu) | (static_cast<uint16_t>(value) << 8)));
      } else {
        WriteIO16(addr & ~1u, static_cast<uint16_t>((old & 0xFF00u) | value));
      }
    }
  }
}

uint16_t GBACore::ReadIO16(uint32_t addr) const {
  if (addr < 0x04000000u || addr > 0x040003FEu) return 0;
  const size_t off = static_cast<size_t>(addr - 0x04000000u);
  if (off + 1 >= io_regs_.size()) return 0;
  return static_cast<uint16_t>(io_regs_[off]) |
         static_cast<uint16_t>(io_regs_[off + 1] << 8);
}

void GBACore::WriteIO16(uint32_t addr, uint16_t value) {
  if (addr < 0x04000000u || addr > 0x040003FEu) return;
  const size_t off = static_cast<size_t>(addr - 0x04000000u);
  if (off + 1 >= io_regs_.size()) return;
  // KEYINPUT is read-only from CPU side in this model (updated from SetKeys).
  if (addr == 0x04000130u) return;
  // IF: write-1-to-clear bits
  if (addr == 0x04000202u) {
    const uint16_t old = ReadIO16(addr);
    const uint16_t next = static_cast<uint16_t>(old & ~value);
    io_regs_[off] = static_cast<uint8_t>(next & 0xFF);
    io_regs_[off + 1] = static_cast<uint8_t>((next >> 8) & 0xFF);
    return;
  }
  // IME only bit0 is used.
  if (addr == 0x04000208u) {
    value &= 0x0001u;
  }
  // DISPSTAT: bits 0-2 are status (read-only), bits 3-5/8-15 writable.
  if (addr == 0x04000004u) {
    const uint16_t old = ReadIO16(addr);
    value = static_cast<uint16_t>((value & 0xFFF8u) | (old & 0x0007u));
  }
  // VCOUNT is read-only.
  if (addr == 0x04000006u) {
    return;
  }
  // SOUNDCNT_X: only bit7 is writable; bits0-3 are read-only channel-active flags.
  if (addr == 0x04000084u) {
    const uint16_t old = ReadIO16(addr);
    const uint16_t ro_status = static_cast<uint16_t>(old & 0x000Fu);
    value = static_cast<uint16_t>((value & 0x0080u) | ro_status);
    const bool master_was_on = (old & 0x0080u) != 0;
    const bool master_now_on = (value & 0x0080u) != 0;
    if (master_was_on && !master_now_on) {
      for (size_t i = 0x60u; i <= 0x81u && i < io_regs_.size(); ++i) io_regs_[i] = 0;
      apu_ch1_active_ = apu_ch2_active_ = apu_ch3_active_ = apu_ch4_active_ = false;
      apu_prev_trig_ch1_ = apu_prev_trig_ch2_ = apu_prev_trig_ch3_ = apu_prev_trig_ch4_ = false;
      audio_mix_level_ = 0;
      fifo_a_.clear();
      fifo_b_.clear();
      fifo_a_last_sample_ = 0;
      fifo_b_last_sample_ = 0;
    }
  }
  // SOUNDCNT_H FIFO reset bits.
  if (addr == 0x04000082u) {
    if (value & (1u << 11)) {
      fifo_a_.clear();
      fifo_a_last_sample_ = 0;
      value = static_cast<uint16_t>(value & ~(1u << 11));
    }
    if (value & (1u << 15)) {
      fifo_b_.clear();
      fifo_b_last_sample_ = 0;
      value = static_cast<uint16_t>(value & ~(1u << 15));
    }
  }
  io_regs_[off] = static_cast<uint8_t>(value & 0xFF);
  io_regs_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFF);
}


}  // namespace gba

// ---- END gba_core_memory.cpp ----
// ---- BEGIN gba_core_ppu.cpp ----
#include "gba_core.h"

#include <algorithm>

namespace gba {
namespace {
uint8_t ClampToByteLocal(int value) {
  if (value < 0) return 0;
  if (value > 255) return 255;
  return static_cast<uint8_t>(value);
}

constexpr int kBackdropPriority = 4;
constexpr uint8_t kLayerBg0 = 0;
constexpr uint8_t kLayerBg1 = 1;
constexpr uint8_t kLayerBg2 = 2;
constexpr uint8_t kLayerBg3 = 3;
constexpr uint8_t kLayerBackdrop = 4;

std::vector<uint8_t>& BgPriorityBuffer() {
  static std::vector<uint8_t> buffer;
  return buffer;
}

void EnsureBgPriorityBufferSize() {
  auto& buffer = BgPriorityBuffer();
  const size_t required = static_cast<size_t>(GBACore::kScreenWidth) * GBACore::kScreenHeight;
  if (buffer.size() != required) {
    buffer.assign(required, static_cast<uint8_t>(kBackdropPriority));
  }
}

std::vector<uint8_t>& ObjWindowMaskBuffer() {
  static std::vector<uint8_t> buffer;
  return buffer;
}

std::vector<uint8_t>& ObjDrawnMaskBuffer() {
  static std::vector<uint8_t> buffer;
  return buffer;
}

std::vector<uint8_t>& BgLayerBuffer() {
  static std::vector<uint8_t> buffer;
  return buffer;
}

std::vector<uint32_t>& BgBaseColorBuffer() {
  static std::vector<uint32_t> buffer;
  return buffer;
}

std::vector<uint32_t>& BgSecondColorBuffer() {
  static std::vector<uint32_t> buffer;
  return buffer;
}

std::vector<uint8_t>& BgSecondLayerBuffer() {
  static std::vector<uint8_t> buffer;
  return buffer;
}

void EnsureBgLayerBufferSize() {
  auto& buffer = BgLayerBuffer();
  const size_t required = static_cast<size_t>(GBACore::kScreenWidth) * GBACore::kScreenHeight;
  if (buffer.size() != required) {
    buffer.assign(required, kLayerBackdrop);
  } else {
    std::fill(buffer.begin(), buffer.end(), kLayerBackdrop);
  }
}

void EnsureBgBaseColorBufferSize() {
  auto& buffer = BgBaseColorBuffer();
  const size_t required = static_cast<size_t>(GBACore::kScreenWidth) * GBACore::kScreenHeight;
  if (buffer.size() != required) {
    buffer.assign(required, 0xFF000000u);
  }
}

void EnsureBgSecondBuffersSize() {
  auto& color = BgSecondColorBuffer();
  auto& layer = BgSecondLayerBuffer();
  const size_t required = static_cast<size_t>(GBACore::kScreenWidth) * GBACore::kScreenHeight;
  if (color.size() != required) {
    color.assign(required, 0xFF000000u);
  } else {
    std::fill(color.begin(), color.end(), 0xFF000000u);
  }
  if (layer.size() != required) {
    layer.assign(required, kLayerBackdrop);
  } else {
    std::fill(layer.begin(), layer.end(), kLayerBackdrop);
  }
}

void EnsureObjDrawnMaskBufferSize() {
  auto& buffer = ObjDrawnMaskBuffer();
  const size_t required = static_cast<size_t>(GBACore::kScreenWidth) * GBACore::kScreenHeight;
  if (buffer.size() != required) {
    buffer.assign(required, 0u);
  } else {
    std::fill(buffer.begin(), buffer.end(), 0u);
  }
}

void EnsureObjWindowMaskBufferSize() {
  auto& buffer = ObjWindowMaskBuffer();
  const size_t required = static_cast<size_t>(GBACore::kScreenWidth) * GBACore::kScreenHeight;
  if (buffer.size() != required) {
    buffer.assign(required, 0u);
  } else {
    std::fill(buffer.begin(), buffer.end(), 0u);
  }
}

uint32_t Bgr555ToRgba8888(uint16_t bgr) {
  const uint8_t r5 = static_cast<uint8_t>((bgr >> 0) & 0x1F);
  const uint8_t g5 = static_cast<uint8_t>((bgr >> 5) & 0x1F);
  const uint8_t b5 = static_cast<uint8_t>((bgr >> 10) & 0x1F);
  const uint8_t r = static_cast<uint8_t>((r5 << 3) | (r5 >> 2));
  const uint8_t g = static_cast<uint8_t>((g5 << 3) | (g5 >> 2));
  const uint8_t b = static_cast<uint8_t>((b5 << 3) | (b5 >> 2));
  return 0xFF000000u | (static_cast<uint32_t>(r) << 16) |
         (static_cast<uint32_t>(g) << 8) | b;
}

uint16_t ReadBackdropBgr(const std::array<uint8_t, 1024>& palette_ram) {
  return static_cast<uint16_t>(palette_ram[0]) |
         static_cast<uint16_t>(palette_ram[1] << 8);
}

bool IsWithinWindowAxis(int p, int start, int end, int axis_max) {
  const int s = std::clamp(start, 0, axis_max);
  int e = std::clamp(end, 0, axis_max);
  // GBATEK: X1>X2/Y1>Y2 are treated as X2/Y2=max; and X1=X2=0 (Y1=Y2=0)
  // disables that window axis.
  if (s == 0 && e == 0) return false;
  if (s > e) e = axis_max;
  return p >= s && p < e;
}

uint8_t ResolveWindowControl(uint16_t dispcnt, uint16_t winin, uint16_t winout,
                         uint16_t win0h, uint16_t win0v, uint16_t win1h, uint16_t win1v,
                         const std::vector<uint8_t>& obj_window_mask,
                         int x, int y) {
  const bool win0_enabled = (dispcnt & (1u << 13)) != 0;
  const bool win1_enabled = (dispcnt & (1u << 14)) != 0;
  const bool objwin_enabled = (dispcnt & (1u << 15)) != 0;
  if (!win0_enabled && !win1_enabled && !objwin_enabled) return 0x3Fu;

  const int win0_l = std::min<int>(240, (win0h >> 8) & 0xFFu);
  const int win0_r = std::min<int>(240, win0h & 0xFFu);
  const int win0_t = std::min<int>(160, (win0v >> 8) & 0xFFu);
  const int win0_b = std::min<int>(160, win0v & 0xFFu);
  const int win1_l = std::min<int>(240, (win1h >> 8) & 0xFFu);
  const int win1_r = std::min<int>(240, win1h & 0xFFu);
  const int win1_t = std::min<int>(160, (win1v >> 8) & 0xFFu);
  const int win1_b = std::min<int>(160, win1v & 0xFFu);

  const bool in_win0 = win0_enabled && IsWithinWindowAxis(x, win0_l, win0_r, 240) &&
                       IsWithinWindowAxis(y, win0_t, win0_b, 160);
  const bool in_win1 = win1_enabled && IsWithinWindowAxis(x, win1_l, win1_r, 240) &&
                       IsWithinWindowAxis(y, win1_t, win1_b, 160);

  uint8_t control = static_cast<uint8_t>(winout & 0xFFu);  // outside window
  if (in_win0) control = static_cast<uint8_t>(winin & 0xFFu);
  else if (in_win1) control = static_cast<uint8_t>((winin >> 8) & 0xFFu);
  else if (objwin_enabled) {
    const size_t off = static_cast<size_t>(y) * GBACore::kScreenWidth + x;
    if (off < obj_window_mask.size() && obj_window_mask[off] != 0) {
      control = static_cast<uint8_t>((winout >> 8) & 0x3Fu);
    }
  }
  return control;
}

bool IsBgVisibleByWindow(uint8_t control, int bg) {
  return (control & (1u << bg)) != 0;
}

bool IsBgVisibleByWindow(uint16_t dispcnt, uint16_t winin, uint16_t winout,
                         uint16_t win0h, uint16_t win0v, uint16_t win1h, uint16_t win1v,
                         int bg, int x, int y) {
  const uint8_t control =
      ResolveWindowControl(dispcnt, winin, winout, win0h, win0v, win1h, win1v, ObjWindowMaskBuffer(), x, y);
  return IsBgVisibleByWindow(control, bg);
}

bool IsObjVisibleByWindow(uint16_t dispcnt, uint16_t winin, uint16_t winout,
                          uint16_t win0h, uint16_t win0v, uint16_t win1h, uint16_t win1v,
                          int x, int y) {
  const uint8_t control = ResolveWindowControl(dispcnt, winin, winout, win0h, win0v, win1h, win1v,
                                               ObjWindowMaskBuffer(), x, y);
  return (control & (1u << 4)) != 0;
}

uint16_t LayerToBlendMask(uint8_t layer, bool top_is_obj) {
  if (top_is_obj) return static_cast<uint16_t>(1u << 4);   // OBJ
  if (layer <= kLayerBg3) return static_cast<uint16_t>(1u << layer);  // BG0..BG3
  return static_cast<uint16_t>(1u << 5);  // Backdrop
}
}  // namespace
void GBACore::RenderMode3Frame() {
  // Mode 3: 240x160 direct color (BGR555) in VRAM.
  EnsureBgPriorityBufferSize();
  EnsureBgLayerBufferSize();
  EnsureBgSecondBuffersSize();
  auto& bg_layer = BgLayerBuffer();
  auto& bg_priority = BgPriorityBuffer();
  auto& second_color = BgSecondColorBuffer();
  auto& second_layer = BgSecondLayerBuffer();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint16_t bg2cnt = ReadIO16(0x0400000Cu);
  const uint16_t winin = ReadIO16(0x04000048u);
  const uint16_t winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u);
  const uint16_t win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u);
  const uint16_t win1v = ReadIO16(0x04000046u);
  const bool bg2_enabled = (dispcnt & (1u << 10)) != 0;
  const uint8_t bg2_priority = static_cast<uint8_t>(bg2cnt & 0x3u);
  const bool wrap = (bg2cnt & (1u << 13)) != 0;
  const bool mosaic = (bg2cnt & (1u << 6)) != 0;
  const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
  const int mos_h = static_cast<int>((mosaic_reg & 0xFu) + 1u);
  const int mos_v = static_cast<int>(((mosaic_reg >> 4) & 0xFu) + 1u);
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));
  const int16_t pa = static_cast<int16_t>(ReadIO16(0x04000020u));
  const int16_t pb = static_cast<int16_t>(ReadIO16(0x04000022u));
  const int16_t pc = static_cast<int16_t>(ReadIO16(0x04000024u));
  const int16_t pd = static_cast<int16_t>(ReadIO16(0x04000026u));
  auto read_s32_le = [&](uint32_t addr) -> int32_t {
    const uint32_t v = static_cast<uint32_t>(Read8(addr)) |
                       (static_cast<uint32_t>(Read8(addr + 1u)) << 8) |
                       (static_cast<uint32_t>(Read8(addr + 2u)) << 16) |
                       (static_cast<uint32_t>(Read8(addr + 3u)) << 24);
    int32_t s = static_cast<int32_t>(v);
    if ((s & 0x08000000) != 0) s |= static_cast<int32_t>(0xF0000000);
    return s;
  };
  const int32_t refx = read_s32_le(0x04000028u);
  const int32_t refy = read_s32_le(0x0400002Cu);

  if (!bg2_enabled) {
    std::fill(frame_buffer_.begin(), frame_buffer_.end(), backdrop);
    std::fill(bg_priority.begin(), bg_priority.end(), static_cast<uint8_t>(kBackdropPriority));
    std::fill(bg_layer.begin(), bg_layer.end(), kLayerBackdrop);
    std::fill(second_color.begin(), second_color.end(), backdrop);
    std::fill(second_layer.begin(), second_layer.end(), kLayerBackdrop);
    return;
  }

  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      const size_t fb_off = static_cast<size_t>(y) * kScreenWidth + x;
      if (!IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 2, x, y)) {
        frame_buffer_[fb_off] = backdrop;
        bg_priority[fb_off] = static_cast<uint8_t>(kBackdropPriority);
        bg_layer[fb_off] = kLayerBackdrop;
        second_color[fb_off] = backdrop;
        second_layer[fb_off] = kLayerBackdrop;
        continue;
      }
      const int sample_x = mosaic ? ((x / mos_h) * mos_h) : x;
      const int sample_y = mosaic ? ((y / mos_v) * mos_v) : y;
      const int64_t tex_x_fp =
          static_cast<int64_t>(refx) + static_cast<int64_t>(pa) * sample_x + static_cast<int64_t>(pb) * sample_y;
      const int64_t tex_y_fp =
          static_cast<int64_t>(refy) + static_cast<int64_t>(pc) * sample_x + static_cast<int64_t>(pd) * sample_y;
      int sx = static_cast<int>(tex_x_fp >> 8);
      int sy = static_cast<int>(tex_y_fp >> 8);
      if (wrap) {
        sx = ((sx % kScreenWidth) + kScreenWidth) % kScreenWidth;
        sy = ((sy % kScreenHeight) + kScreenHeight) % kScreenHeight;
      }
      if (sx < 0 || sy < 0 || sx >= kScreenWidth || sy >= kScreenHeight) {
        frame_buffer_[fb_off] = backdrop;
        bg_priority[fb_off] = static_cast<uint8_t>(kBackdropPriority);
        bg_layer[fb_off] = kLayerBackdrop;
        second_color[fb_off] = backdrop;
        second_layer[fb_off] = kLayerBackdrop;
        continue;
      }
      const size_t off = static_cast<size_t>((sy * kScreenWidth + sx) * 2);
      if (off + 1 >= vram_.size()) {
        frame_buffer_[fb_off] = backdrop;
        bg_priority[fb_off] = static_cast<uint8_t>(kBackdropPriority);
        bg_layer[fb_off] = kLayerBackdrop;
        second_color[fb_off] = backdrop;
        second_layer[fb_off] = kLayerBackdrop;
        continue;
      }
      const uint16_t bgr555 = static_cast<uint16_t>(vram_[off]) |
                              static_cast<uint16_t>(vram_[off + 1] << 8);
      frame_buffer_[fb_off] = Bgr555ToRgba8888(bgr555);
      bg_priority[fb_off] = bg2_priority;
      bg_layer[fb_off] = kLayerBg2;
      second_color[fb_off] = backdrop;
      second_layer[fb_off] = kLayerBackdrop;
    }
  }
}

void GBACore::RenderMode4Frame() {
  EnsureBgPriorityBufferSize();
  EnsureBgLayerBufferSize();
  EnsureBgSecondBuffersSize();
  auto& bg_layer = BgLayerBuffer();
  auto& bg_priority = BgPriorityBuffer();
  auto& second_color = BgSecondColorBuffer();
  auto& second_layer = BgSecondLayerBuffer();
  EnsureObjDrawnMaskBufferSize();
  auto& obj_drawn = ObjDrawnMaskBuffer();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint16_t bg2cnt = ReadIO16(0x0400000Cu);
  const uint16_t winin = ReadIO16(0x04000048u);
  const uint16_t winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u);
  const uint16_t win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u);
  const uint16_t win1v = ReadIO16(0x04000046u);
  const bool bg2_enabled = (dispcnt & (1u << 10)) != 0;
  const uint8_t bg2_priority = static_cast<uint8_t>(bg2cnt & 0x3u);
  const bool wrap = (bg2cnt & (1u << 13)) != 0;
  const bool mosaic = (bg2cnt & (1u << 6)) != 0;
  const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
  const int mos_h = static_cast<int>((mosaic_reg & 0xFu) + 1u);
  const int mos_v = static_cast<int>(((mosaic_reg >> 4) & 0xFu) + 1u);
  const bool page1 = (dispcnt & (1u << 4)) != 0;
  const size_t page_base = page1 ? 0xA000u : 0u;
  const int16_t pa = static_cast<int16_t>(ReadIO16(0x04000020u));
  const int16_t pb = static_cast<int16_t>(ReadIO16(0x04000022u));
  const int16_t pc = static_cast<int16_t>(ReadIO16(0x04000024u));
  const int16_t pd = static_cast<int16_t>(ReadIO16(0x04000026u));
  auto read_s32_le = [&](uint32_t addr) -> int32_t {
    const uint32_t v = static_cast<uint32_t>(Read8(addr)) |
                       (static_cast<uint32_t>(Read8(addr + 1u)) << 8) |
                       (static_cast<uint32_t>(Read8(addr + 2u)) << 16) |
                       (static_cast<uint32_t>(Read8(addr + 3u)) << 24);
    int32_t s = static_cast<int32_t>(v);
    if ((s & 0x08000000) != 0) s |= static_cast<int32_t>(0xF0000000);
    return s;
  };
  const int32_t refx = read_s32_le(0x04000028u);
  const int32_t refy = read_s32_le(0x0400002Cu);

  const uint16_t backdrop_bgr = ReadBackdropBgr(palette_ram_);
  const uint32_t backdrop = Bgr555ToRgba8888(backdrop_bgr);

  auto palette_color = [&](uint16_t idx) -> uint32_t {
    const size_t off = static_cast<size_t>((idx & 0xFFu) * 2u);
    if (off + 1 >= palette_ram_.size()) return backdrop;
    const uint16_t bgr = static_cast<uint16_t>(palette_ram_[off]) |
                         static_cast<uint16_t>(palette_ram_[off + 1] << 8);
    return Bgr555ToRgba8888(bgr);
  };

  if (!bg2_enabled) {
    std::fill(frame_buffer_.begin(), frame_buffer_.end(), backdrop);
    std::fill(bg_priority.begin(), bg_priority.end(), static_cast<uint8_t>(kBackdropPriority));
    std::fill(bg_layer.begin(), bg_layer.end(), kLayerBackdrop);
    std::fill(second_color.begin(), second_color.end(), backdrop);
    std::fill(second_layer.begin(), second_layer.end(), kLayerBackdrop);
    return;
  }

  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      const size_t fb_off = static_cast<size_t>(y) * kScreenWidth + x;
      if (!IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 2, x, y)) {
        frame_buffer_[fb_off] = backdrop;
        bg_priority[fb_off] = static_cast<uint8_t>(kBackdropPriority);
        bg_layer[fb_off] = kLayerBackdrop;
        second_color[fb_off] = backdrop;
        second_layer[fb_off] = kLayerBackdrop;
        continue;
      }
      const int sample_x = mosaic ? ((x / mos_h) * mos_h) : x;
      const int sample_y = mosaic ? ((y / mos_v) * mos_v) : y;
      const int64_t tex_x_fp =
          static_cast<int64_t>(refx) + static_cast<int64_t>(pa) * sample_x + static_cast<int64_t>(pb) * sample_y;
      const int64_t tex_y_fp =
          static_cast<int64_t>(refy) + static_cast<int64_t>(pc) * sample_x + static_cast<int64_t>(pd) * sample_y;
      int sx = static_cast<int>(tex_x_fp >> 8);
      int sy = static_cast<int>(tex_y_fp >> 8);
      if (wrap) {
        sx = ((sx % kScreenWidth) + kScreenWidth) % kScreenWidth;
        sy = ((sy % kScreenHeight) + kScreenHeight) % kScreenHeight;
      }
      if (sx < 0 || sy < 0 || sx >= kScreenWidth || sy >= kScreenHeight) {
        frame_buffer_[fb_off] = backdrop;
        bg_priority[fb_off] = static_cast<uint8_t>(kBackdropPriority);
        bg_layer[fb_off] = kLayerBackdrop;
        second_color[fb_off] = backdrop;
        second_layer[fb_off] = kLayerBackdrop;
        continue;
      }
      const size_t off = page_base + static_cast<size_t>(sy * kScreenWidth + sx);
      const uint8_t index = (off < vram_.size()) ? vram_[off] : 0;
      if (index == 0u) {
        frame_buffer_[fb_off] = backdrop;
        bg_priority[fb_off] = static_cast<uint8_t>(kBackdropPriority);
        bg_layer[fb_off] = kLayerBackdrop;
        second_color[fb_off] = backdrop;
        second_layer[fb_off] = kLayerBackdrop;
        continue;
      }
      frame_buffer_[fb_off] = palette_color(index);
      bg_priority[fb_off] = bg2_priority;
      bg_layer[fb_off] = kLayerBg2;
      second_color[fb_off] = backdrop;
      second_layer[fb_off] = kLayerBackdrop;
    }
  }
}

void GBACore::RenderMode5Frame() {
  EnsureBgPriorityBufferSize();
  EnsureBgLayerBufferSize();
  EnsureBgSecondBuffersSize();
  auto& bg_layer = BgLayerBuffer();
  auto& bg_priority = BgPriorityBuffer();
  auto& second_color = BgSecondColorBuffer();
  auto& second_layer = BgSecondLayerBuffer();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint16_t bg2cnt = ReadIO16(0x0400000Cu);
  const uint16_t winin = ReadIO16(0x04000048u);
  const uint16_t winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u);
  const uint16_t win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u);
  const uint16_t win1v = ReadIO16(0x04000046u);
  const bool bg2_enabled = (dispcnt & (1u << 10)) != 0;
  const uint8_t bg2_priority = static_cast<uint8_t>(bg2cnt & 0x3u);
  const bool wrap = (bg2cnt & (1u << 13)) != 0;
  const bool mosaic = (bg2cnt & (1u << 6)) != 0;
  const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
  const int mos_h = static_cast<int>((mosaic_reg & 0xFu) + 1u);
  const int mos_v = static_cast<int>(((mosaic_reg >> 4) & 0xFu) + 1u);
  const bool page1 = (dispcnt & (1u << 4)) != 0;
  const size_t page_base = page1 ? 0xA000u : 0u;
  constexpr int kMode5Width = 160;
  constexpr int kMode5Height = 128;
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));
  const int16_t pa = static_cast<int16_t>(ReadIO16(0x04000020u));
  const int16_t pb = static_cast<int16_t>(ReadIO16(0x04000022u));
  const int16_t pc = static_cast<int16_t>(ReadIO16(0x04000024u));
  const int16_t pd = static_cast<int16_t>(ReadIO16(0x04000026u));
  auto read_s32_le = [&](uint32_t addr) -> int32_t {
    const uint32_t v = static_cast<uint32_t>(Read8(addr)) |
                       (static_cast<uint32_t>(Read8(addr + 1u)) << 8) |
                       (static_cast<uint32_t>(Read8(addr + 2u)) << 16) |
                       (static_cast<uint32_t>(Read8(addr + 3u)) << 24);
    int32_t s = static_cast<int32_t>(v);
    if ((s & 0x08000000) != 0) s |= static_cast<int32_t>(0xF0000000);
    return s;
  };
  const int32_t refx = read_s32_le(0x04000028u);
  const int32_t refy = read_s32_le(0x0400002Cu);

  std::fill(frame_buffer_.begin(), frame_buffer_.end(), backdrop);
  std::fill(bg_priority.begin(), bg_priority.end(), static_cast<uint8_t>(kBackdropPriority));
  std::fill(bg_layer.begin(), bg_layer.end(), kLayerBackdrop);
  std::fill(second_color.begin(), second_color.end(), backdrop);
  std::fill(second_layer.begin(), second_layer.end(), kLayerBackdrop);

  if (!bg2_enabled) return;

  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      const size_t fb_off = static_cast<size_t>(y) * kScreenWidth + x;
      if (!IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 2, x, y)) {
        continue;
      }
      const int sample_x = mosaic ? ((x / mos_h) * mos_h) : x;
      const int sample_y = mosaic ? ((y / mos_v) * mos_v) : y;
      const int64_t tex_x_fp =
          static_cast<int64_t>(refx) + static_cast<int64_t>(pa) * sample_x + static_cast<int64_t>(pb) * sample_y;
      const int64_t tex_y_fp =
          static_cast<int64_t>(refy) + static_cast<int64_t>(pc) * sample_x + static_cast<int64_t>(pd) * sample_y;
      int sx = static_cast<int>(tex_x_fp >> 8);
      int sy = static_cast<int>(tex_y_fp >> 8);
      if (wrap) {
        sx = ((sx % kMode5Width) + kMode5Width) % kMode5Width;
        sy = ((sy % kMode5Height) + kMode5Height) % kMode5Height;
      }
      if (sx < 0 || sy < 0 || sx >= kMode5Width || sy >= kMode5Height) continue;
      const size_t off = page_base + static_cast<size_t>((sy * kMode5Width + sx) * 2);
      if (off + 1 >= vram_.size()) continue;
      const uint16_t bgr555 = static_cast<uint16_t>(vram_[off]) |
                              static_cast<uint16_t>(vram_[off + 1] << 8);
      frame_buffer_[fb_off] = Bgr555ToRgba8888(bgr555);
      bg_priority[fb_off] = bg2_priority;
      bg_layer[fb_off] = kLayerBg2;
      second_color[fb_off] = backdrop;
      second_layer[fb_off] = kLayerBackdrop;
    }
  }
}

void GBACore::BuildObjWindowMask() {
  EnsureObjWindowMaskBufferSize();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  if ((dispcnt & (1u << 15)) == 0 || (dispcnt & (1u << 12)) == 0) return;

  static constexpr int kObjDim[3][4][2] = {
      {{8, 8}, {16, 16}, {32, 32}, {64, 64}},
      {{16, 8}, {32, 8}, {32, 16}, {64, 32}},
      {{8, 16}, {8, 32}, {16, 32}, {32, 64}},
  };
  const bool obj_1d = (dispcnt & (1u << 6)) != 0;
  auto& mask = ObjWindowMaskBuffer();

  for (int obj = 127; obj >= 0; --obj) {
    const size_t off = static_cast<size_t>(obj * 8);
    if (off + 5 >= oam_.size()) continue;
    const uint16_t attr0 = static_cast<uint16_t>(oam_[off]) |
                           static_cast<uint16_t>(oam_[off + 1] << 8);
    const uint16_t attr1 = static_cast<uint16_t>(oam_[off + 2]) |
                           static_cast<uint16_t>(oam_[off + 3] << 8);
    const uint16_t attr2 = static_cast<uint16_t>(oam_[off + 4]) |
                           static_cast<uint16_t>(oam_[off + 5] << 8);
    if (((attr0 >> 8) & 0x3u) != 2u) continue;  // OBJ window

    const bool affine = (attr0 & (1u << 8)) != 0;
    const bool double_size = affine && ((attr0 & (1u << 9)) != 0);
    const int shape = (attr0 >> 14) & 0x3;
    const int size = (attr1 >> 14) & 0x3;
    if (shape >= 3) continue;
    const int src_w = kObjDim[shape][size][0];
    const int src_h = kObjDim[shape][size][1];
    const int draw_w = double_size ? (src_w * 2) : src_w;
    const int draw_h = double_size ? (src_h * 2) : src_h;

    int y = attr0 & 0xFF;
    int x = attr1 & 0x1FF;
    if (y >= 160) y -= 256;
    if (x >= 240) x -= 512;

    const bool color_256 = (attr0 & (1u << 13)) != 0;
    const bool mosaic = (attr0 & (1u << 12)) != 0;
    const bool hflip = (attr1 & (1u << 12)) != 0;
    const bool vflip = (attr1 & (1u << 13)) != 0;
    const uint16_t tile_id = attr2 & 0x03FFu;
    const uint16_t palbank = static_cast<uint16_t>((attr2 >> 12) & 0xFu);
    const size_t obj_chr_base = 0x10000u;

    int16_t pa = 0, pb = 0, pc = 0, pd = 0;
    if (affine) {
      const uint16_t affine_idx = static_cast<uint16_t>((attr1 >> 9) & 0x1Fu);
      const size_t pa_off = static_cast<size_t>(affine_idx) * 0x20u + 0x06u;
      const size_t pb_off = static_cast<size_t>(affine_idx) * 0x20u + 0x0Eu;
      const size_t pc_off = static_cast<size_t>(affine_idx) * 0x20u + 0x16u;
      const size_t pd_off = static_cast<size_t>(affine_idx) * 0x20u + 0x1Eu;
      if (pd_off + 1 >= oam_.size()) continue;
      pa = static_cast<int16_t>(static_cast<uint16_t>(oam_[pa_off]) |
                                static_cast<uint16_t>(oam_[pa_off + 1] << 8));
      pb = static_cast<int16_t>(static_cast<uint16_t>(oam_[pb_off]) |
                                static_cast<uint16_t>(oam_[pb_off + 1] << 8));
      pc = static_cast<int16_t>(static_cast<uint16_t>(oam_[pc_off]) |
                                static_cast<uint16_t>(oam_[pc_off + 1] << 8));
      pd = static_cast<int16_t>(static_cast<uint16_t>(oam_[pd_off]) |
                                static_cast<uint16_t>(oam_[pd_off + 1] << 8));
    }

    for (int py = 0; py < draw_h; ++py) {
      const int sy = y + py;
      if (sy < 0 || sy >= kScreenHeight) continue;
      for (int px = 0; px < draw_w; ++px) {
        const int sx = x + px;
        if (sx < 0 || sx >= kScreenWidth) continue;
        int tx = 0, ty = 0;
        int sample_px = px;
        int sample_py = py;
        if (mosaic) {
          const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
          const int mos_h = static_cast<int>(((mosaic_reg >> 8) & 0xFu) + 1);
          const int mos_v = static_cast<int>(((mosaic_reg >> 12) & 0xFu) + 1);
          sample_px = (px / mos_h) * mos_h;
          sample_py = (py / mos_v) * mos_v;
        }
        if (affine) {
          const int cx = draw_w / 2;
          const int cy = draw_h / 2;
          const int dx = sample_px - cx;
          const int dy = sample_py - cy;
          const int src_cx = src_w / 2;
          const int src_cy = src_h / 2;
          tx = src_cx + static_cast<int>((static_cast<int32_t>(pa) * dx +
                                          static_cast<int32_t>(pb) * dy) >>
                                         8);
          ty = src_cy + static_cast<int>((static_cast<int32_t>(pc) * dx +
                                          static_cast<int32_t>(pd) * dy) >>
                                         8);
          if (tx < 0 || ty < 0 || tx >= src_w || ty >= src_h) continue;
        } else {
          tx = hflip ? (src_w - 1 - sample_px) : sample_px;
          ty = vflip ? (src_h - 1 - sample_py) : sample_py;
        }

        uint16_t color_index = 0;
        if (color_256) {
          const int tile_x = tx / 8;
          const int tile_y = ty / 8;
          const int in_x = tx & 7;
          const int in_y = ty & 7;
          const int tile_stride = obj_1d ? (src_w / 8) : 32;
          const size_t chr_off = obj_chr_base +
                                 static_cast<size_t>((tile_id + tile_y * tile_stride + tile_x) * 64 +
                                                     in_y * 8 + in_x);
          if (chr_off >= vram_.size()) continue;
          color_index = vram_[chr_off];
        } else {
          const int tile_x = tx / 8;
          const int tile_y = ty / 8;
          const int in_x = tx & 7;
          const int in_y = ty & 7;
          const int tile_stride = obj_1d ? (src_w / 8) : 32;
          const size_t chr_off = obj_chr_base +
                                 static_cast<size_t>((tile_id + tile_y * tile_stride + tile_x) * 32 +
                                                     in_y * 4 + in_x / 2);
          if (chr_off >= vram_.size()) continue;
          const uint8_t packed = vram_[chr_off];
          const uint8_t nib = (in_x & 1) ? (packed >> 4) : (packed & 0x0F);
          if (nib == 0u) continue;
          color_index = static_cast<uint16_t>(palbank * 16u + nib);
        }
        if (color_256 && color_index == 0u) continue;
        const size_t fb_off = static_cast<size_t>(sy) * kScreenWidth + sx;
        mask[fb_off] = 1u;
      }
    }
  }
}

void GBACore::RenderSprites() {
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  if ((dispcnt & (1u << 12)) == 0) return;  // OBJ disable
  const uint16_t winin = ReadIO16(0x04000048u);
  const uint16_t winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u);
  const uint16_t win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u);
  const uint16_t win1v = ReadIO16(0x04000046u);
  const uint16_t bldcnt = ReadIO16(0x04000050u);
  const uint16_t bldalpha = ReadIO16(0x04000052u);
  const uint32_t eva = std::min<uint32_t>(16u, bldalpha & 0x1Fu);
  const uint32_t evb = std::min<uint32_t>(16u, (bldalpha >> 8) & 0x1Fu);
  const bool obj_is_1st_target = (bldcnt & (1u << 4)) != 0;
  const bool any_2nd_target = ((bldcnt >> 8) & 0x3Fu) != 0;

  EnsureBgPriorityBufferSize();
  auto& bg_priority = BgPriorityBuffer();
  EnsureObjDrawnMaskBufferSize();
  auto& obj_drawn = ObjDrawnMaskBuffer();
  auto& bg_layer = BgLayerBuffer();
  auto& bg_base = BgBaseColorBuffer();

  static constexpr int kObjDim[3][4][2] = {
      {{8, 8}, {16, 16}, {32, 32}, {64, 64}},     // square
      {{16, 8}, {32, 8}, {32, 16}, {64, 32}},     // horizontal
      {{8, 16}, {8, 32}, {16, 32}, {32, 64}},     // vertical
  };
  const bool obj_1d = (dispcnt & (1u << 6)) != 0;

  auto palette_color = [&](uint16_t idx) -> uint32_t {
    const size_t off = static_cast<size_t>((idx & 0x1FFu) * 2u);
    if (off + 1 >= palette_ram_.size()) return 0xFF000000u;
    const uint16_t bgr = static_cast<uint16_t>(palette_ram_[off]) |
                         static_cast<uint16_t>(palette_ram_[off + 1] << 8);
    return Bgr555ToRgba8888(bgr);
  };

  for (int obj = 127; obj >= 0; --obj) {
    const size_t off = static_cast<size_t>(obj * 8);
    if (off + 5 >= oam_.size()) continue;
    const uint16_t attr0 = static_cast<uint16_t>(oam_[off]) |
                           static_cast<uint16_t>(oam_[off + 1] << 8);
    const uint16_t attr1 = static_cast<uint16_t>(oam_[off + 2]) |
                           static_cast<uint16_t>(oam_[off + 3] << 8);
    const uint16_t attr2 = static_cast<uint16_t>(oam_[off + 4]) |
                           static_cast<uint16_t>(oam_[off + 5] << 8);

    const uint16_t obj_mode = (attr0 >> 8) & 0x3u;
    if (obj_mode == 2u) continue;  // OBJ-window sprites are consumed by BuildObjWindowMask().
    const bool affine = (attr0 & (1u << 8)) != 0;
    const bool double_size = affine && ((attr0 & (1u << 9)) != 0);

    const int shape = (attr0 >> 14) & 0x3;
    const int size = (attr1 >> 14) & 0x3;
    if (shape >= 3) continue;
    const int src_w = kObjDim[shape][size][0];
    const int src_h = kObjDim[shape][size][1];
    const int draw_w = double_size ? (src_w * 2) : src_w;
    const int draw_h = double_size ? (src_h * 2) : src_h;

    int y = attr0 & 0xFF;
    int x = attr1 & 0x1FF;
    if (y >= 160) y -= 256;
    if (x >= 240) x -= 512;

    const bool color_256 = (attr0 & (1u << 13)) != 0;
    const bool mosaic = (attr0 & (1u << 12)) != 0;
    const bool hflip = (attr1 & (1u << 12)) != 0;
    const bool vflip = (attr1 & (1u << 13)) != 0;
    const uint8_t obj_priority = static_cast<uint8_t>((attr2 >> 10) & 0x3u);
    const uint16_t tile_id = attr2 & 0x03FFu;
    const uint16_t palbank = static_cast<uint16_t>((attr2 >> 12) & 0xFu);
    const size_t obj_chr_base = 0x10000u;

    int16_t pa = 0;
    int16_t pb = 0;
    int16_t pc = 0;
    int16_t pd = 0;
    if (affine) {
      const uint16_t affine_idx = static_cast<uint16_t>((attr1 >> 9) & 0x1Fu);
      const size_t pa_off = static_cast<size_t>(affine_idx) * 0x20u + 0x06u;
      const size_t pb_off = static_cast<size_t>(affine_idx) * 0x20u + 0x0Eu;
      const size_t pc_off = static_cast<size_t>(affine_idx) * 0x20u + 0x16u;
      const size_t pd_off = static_cast<size_t>(affine_idx) * 0x20u + 0x1Eu;
      if (pd_off + 1 >= oam_.size()) continue;
      pa = static_cast<int16_t>(static_cast<uint16_t>(oam_[pa_off]) |
                                static_cast<uint16_t>(oam_[pa_off + 1] << 8));
      pb = static_cast<int16_t>(static_cast<uint16_t>(oam_[pb_off]) |
                                static_cast<uint16_t>(oam_[pb_off + 1] << 8));
      pc = static_cast<int16_t>(static_cast<uint16_t>(oam_[pc_off]) |
                                static_cast<uint16_t>(oam_[pc_off + 1] << 8));
      pd = static_cast<int16_t>(static_cast<uint16_t>(oam_[pd_off]) |
                                static_cast<uint16_t>(oam_[pd_off + 1] << 8));
    }

    for (int py = 0; py < draw_h; ++py) {
      const int sy = y + py;
      if (sy < 0 || sy >= kScreenHeight) continue;
      for (int px = 0; px < draw_w; ++px) {
        const int sx = x + px;
        if (sx < 0 || sx >= kScreenWidth) continue;
        if (!IsObjVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, sx, sy)) {
          continue;
        }

        int tx = 0;
        int ty = 0;
        int sample_px = px;
        int sample_py = py;
        if (mosaic) {
          const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
          const int mos_h = static_cast<int>(((mosaic_reg >> 8) & 0xFu) + 1);
          const int mos_v = static_cast<int>(((mosaic_reg >> 12) & 0xFu) + 1);
          sample_px = (px / mos_h) * mos_h;
          sample_py = (py / mos_v) * mos_v;
        }
        if (affine) {
          const int cx = draw_w / 2;
          const int cy = draw_h / 2;
          const int dx = sample_px - cx;
          const int dy = sample_py - cy;
          const int src_cx = src_w / 2;
          const int src_cy = src_h / 2;
          tx = src_cx + static_cast<int>((static_cast<int32_t>(pa) * dx +
                                          static_cast<int32_t>(pb) * dy) >>
                                         8);
          ty = src_cy + static_cast<int>((static_cast<int32_t>(pc) * dx +
                                          static_cast<int32_t>(pd) * dy) >>
                                         8);
          if (tx < 0 || ty < 0 || tx >= src_w || ty >= src_h) continue;
        } else {
          tx = hflip ? (src_w - 1 - sample_px) : sample_px;
          ty = vflip ? (src_h - 1 - sample_py) : sample_py;
        }

        uint16_t color_index = 0;
        if (color_256) {
          const int tile_x = tx / 8;
          const int tile_y = ty / 8;
          const int in_x = tx & 7;
          const int in_y = ty & 7;
          const int tile_stride = obj_1d ? (src_w / 8) : 32;
          const size_t chr_off = obj_chr_base +
                                 static_cast<size_t>((tile_id + tile_y * tile_stride + tile_x) * 64 +
                                                     in_y * 8 + in_x);
          if (chr_off >= vram_.size()) continue;
          color_index = vram_[chr_off];
        } else {
          const int tile_x = tx / 8;
          const int tile_y = ty / 8;
          const int in_x = tx & 7;
          const int in_y = ty & 7;
          const int tile_stride = obj_1d ? (src_w / 8) : 32;
          const size_t chr_off = obj_chr_base +
                                 static_cast<size_t>((tile_id + tile_y * tile_stride + tile_x) * 32 +
                                                     in_y * 4 + in_x / 2);
          if (chr_off >= vram_.size()) continue;
          const uint8_t packed = vram_[chr_off];
          const uint8_t nib = (in_x & 1) ? (packed >> 4) : (packed & 0x0F);
          if (nib == 0u) continue;
          color_index = static_cast<uint16_t>(palbank * 16u + nib);
        }
        if (color_256 && color_index == 0u) continue;  // transparent
        const size_t fb_off = static_cast<size_t>(sy) * kScreenWidth + sx;
        if (obj_priority > bg_priority[fb_off]) continue;
        uint32_t obj_px = palette_color(color_index);
        if (obj_mode == 1u) {
          const uint8_t window_control = ResolveWindowControl(
              dispcnt, winin, winout, win0h, win0v, win1h, win1v, ObjWindowMaskBuffer(), sx, sy);
          const bool effects_enabled = (window_control & (1u << 5)) != 0;
          bool second_target_ok = false;
          if (obj_drawn[fb_off] != 0u) {
            second_target_ok = (bldcnt & (1u << (8 + 4))) != 0;  // OBJ as 2nd target
          } else if (bg_priority[fb_off] == kBackdropPriority) {
            second_target_ok = (bldcnt & (1u << (8 + 5))) != 0;  // BD as 2nd target
          } else {
            const uint8_t layer = (fb_off < bg_layer.size()) ? bg_layer[fb_off] : kLayerBackdrop;
            const uint16_t layer_mask = static_cast<uint16_t>(1u << (8u + std::min<uint8_t>(layer, 5u)));
            second_target_ok = (bldcnt & layer_mask) != 0;
          }
          if (!(effects_enabled && obj_is_1st_target && any_2nd_target && second_target_ok)) {
            frame_buffer_[fb_off] = obj_px;
            bg_priority[fb_off] = obj_priority;
            obj_drawn[fb_off] = 1u;
            continue;
          }
          // Semi-transparent OBJ: approximate hardware blend using current
          // framebuffer pixel as 2nd target.
          const uint32_t under =
              (obj_drawn[fb_off] != 0u) ? frame_buffer_[fb_off]
                                        : ((fb_off < bg_base.size()) ? bg_base[fb_off] : frame_buffer_[fb_off]);
          const uint8_t sr = static_cast<uint8_t>((obj_px >> 16) & 0xFFu);
          const uint8_t sg = static_cast<uint8_t>((obj_px >> 8) & 0xFFu);
          const uint8_t sb = static_cast<uint8_t>(obj_px & 0xFFu);
          const uint8_t ur = static_cast<uint8_t>((under >> 16) & 0xFFu);
          const uint8_t ug = static_cast<uint8_t>((under >> 8) & 0xFFu);
          const uint8_t ub = static_cast<uint8_t>(under & 0xFFu);
          const uint8_t rr = ClampToByteLocal(static_cast<int>((sr * eva + ur * evb) / 16u));
          const uint8_t rg = ClampToByteLocal(static_cast<int>((sg * eva + ug * evb) / 16u));
          const uint8_t rb = ClampToByteLocal(static_cast<int>((sb * eva + ub * evb) / 16u));
          obj_px = 0xFF000000u | (static_cast<uint32_t>(rr) << 16) |
                   (static_cast<uint32_t>(rg) << 8) | rb;
        }
        frame_buffer_[fb_off] = obj_px;
        bg_priority[fb_off] = obj_priority;
        obj_drawn[fb_off] = 1u;
      }
    }
  }
}

void GBACore::RenderMode0Frame() {
  EnsureBgPriorityBufferSize();
  EnsureBgLayerBufferSize();
  EnsureBgSecondBuffersSize();
  auto& bg_layer = BgLayerBuffer();
  auto& bg_priority = BgPriorityBuffer();
  auto& second_color = BgSecondColorBuffer();
  auto& second_layer = BgSecondLayerBuffer();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint16_t winin = ReadIO16(0x04000048u);
  const uint16_t winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u);
  const uint16_t win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u);
  const uint16_t win1v = ReadIO16(0x04000046u);

  auto palette_color = [&](uint16_t idx) -> uint32_t {
    const size_t off = static_cast<size_t>((idx & 0x1FFu) * 2u);
    if (off + 1 >= palette_ram_.size()) return 0xFF000000u;
    const uint16_t bgr = static_cast<uint16_t>(palette_ram_[off]) |
                         static_cast<uint16_t>(palette_ram_[off + 1] << 8);
    return Bgr555ToRgba8888(bgr);
  };

  auto sample_text_bg = [&](int bg, int x, int y, uint16_t* out_idx, bool* out_opaque) {
    *out_idx = 0;
    *out_opaque = false;
    const uint16_t bgcnt = ReadIO16(static_cast<uint32_t>(0x04000008u + bg * 2));
    const uint32_t char_base = ((bgcnt >> 2) & 0x3u) * 16u * 1024u;
    const uint32_t screen_base = ((bgcnt >> 8) & 0x1Fu) * 2u * 1024u;
    const bool color_256 = (bgcnt & (1u << 7)) != 0;
    const uint32_t screen_size = (bgcnt >> 14) & 0x3u;
    const int map_w = (screen_size & 1u) ? 64 : 32;
    const int map_h = (screen_size & 2u) ? 64 : 32;
    const uint16_t hofs = ReadIO16(static_cast<uint32_t>(0x04000010u + bg * 4));
    const uint16_t vofs = ReadIO16(static_cast<uint32_t>(0x04000012u + bg * 4));

    const int sx = (x + hofs) & (map_w * 8 - 1);
    const int sy = (y + vofs) & (map_h * 8 - 1);
    const int tile_x = sx / 8;
    const int tile_y = sy / 8;
    const int pixel_x = sx & 7;
    const int pixel_y = sy & 7;

    const int sc_x = tile_x / 32;
    const int sc_y = tile_y / 32;
    const int local_x = tile_x & 31;
    const int local_y = tile_y & 31;
    int screenblock = 0;
    switch (screen_size) {
      case 0: screenblock = 0; break;
      case 1: screenblock = sc_x; break;
      case 2: screenblock = sc_y; break;
      case 3: screenblock = sc_y * 2 + sc_x; break;
      default: screenblock = 0; break;
    }

    const size_t se_off = static_cast<size_t>(screen_base + screenblock * 0x800u +
                                              (local_y * 32 + local_x) * 2u);
    if (se_off + 1 >= vram_.size()) return;
    const uint16_t se = static_cast<uint16_t>(vram_[se_off]) |
                        static_cast<uint16_t>(vram_[se_off + 1] << 8);
    const uint16_t tile_id = se & 0x03FFu;
    const bool hflip = (se & (1u << 10)) != 0;
    const bool vflip = (se & (1u << 11)) != 0;
    const uint16_t palbank = static_cast<uint16_t>((se >> 12) & 0xFu);

    const int tx = hflip ? (7 - pixel_x) : pixel_x;
    const int ty = vflip ? (7 - pixel_y) : pixel_y;
    if (color_256) {
      const size_t chr_off = static_cast<size_t>(char_base + tile_id * 64u + ty * 8u + tx);
      const uint16_t idx = (chr_off < vram_.size()) ? vram_[chr_off] : 0;
      if ((idx & 0xFFu) == 0u) return;
      *out_idx = idx;
      *out_opaque = true;
      return;
    }
    const size_t chr_off = static_cast<size_t>(char_base + tile_id * 32u + ty * 4u + tx / 2);
    const uint8_t packed = (chr_off < vram_.size()) ? vram_[chr_off] : 0;
    const uint8_t nibble = (tx & 1) ? (packed >> 4) : (packed & 0x0F);
    if (nibble == 0) return;
    *out_idx = static_cast<uint16_t>(palbank * 16u + nibble);
    *out_opaque = true;
  };

  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      uint16_t best_idx = 0;
      int best_prio = 4;
      bool have_bg = false;
      uint8_t best_bg_layer = kLayerBackdrop;
      uint16_t second_idx = 0;
      int second_prio = 4;
      bool have_second = false;
      uint8_t second_bg_layer = kLayerBackdrop;
      for (int bg = 0; bg < 4; ++bg) {
        if ((dispcnt & (1u << (8 + bg))) == 0) continue;
        if (!IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, bg, x, y)) {
          continue;
        }
        const uint16_t bgcnt = ReadIO16(static_cast<uint32_t>(0x04000008u + bg * 2));
        const int prio = bgcnt & 0x3u;
        uint16_t idx = 0;
        bool opaque = false;
        sample_text_bg(bg, x, y, &idx, &opaque);
        if (!opaque) continue;
        if (!have_bg || prio < best_prio ||
            (prio == best_prio && static_cast<uint8_t>(bg) < best_bg_layer)) {
          if (have_bg) {
            second_prio = best_prio;
            second_idx = best_idx;
            second_bg_layer = best_bg_layer;
            have_second = true;
          }
          best_prio = prio;
          best_idx = idx;
          have_bg = true;
          best_bg_layer = static_cast<uint8_t>(bg);
        } else if (!have_second || prio < second_prio ||
                   (prio == second_prio && static_cast<uint8_t>(bg) < second_bg_layer)) {
          second_prio = prio;
          second_idx = idx;
          second_bg_layer = static_cast<uint8_t>(bg);
          have_second = true;
        }
      }
      const size_t off = static_cast<size_t>(y) * kScreenWidth + x;
      frame_buffer_[off] = palette_color(have_bg ? best_idx : 0);
      bg_priority[off] =
          static_cast<uint8_t>(have_bg ? best_prio : kBackdropPriority);
      bg_layer[off] = have_bg ? best_bg_layer : kLayerBackdrop;
      second_color[off] = palette_color(have_second ? second_idx : 0);
      second_layer[off] = have_second ? second_bg_layer : kLayerBackdrop;
    }
  }
}

void GBACore::RenderMode1Frame() {
  EnsureBgPriorityBufferSize();
  EnsureBgLayerBufferSize();
  EnsureBgSecondBuffersSize();
  auto& bg_layer = BgLayerBuffer();
  auto& bg_priority = BgPriorityBuffer();
  auto& second_color = BgSecondColorBuffer();
  auto& second_layer = BgSecondLayerBuffer();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint16_t winin = ReadIO16(0x04000048u);
  const uint16_t winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u);
  const uint16_t win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u);
  const uint16_t win1v = ReadIO16(0x04000046u);

  auto palette_color = [&](uint16_t idx) -> uint32_t {
    const size_t off = static_cast<size_t>((idx & 0x1FFu) * 2u);
    if (off + 1 >= palette_ram_.size()) return 0xFF000000u;
    const uint16_t bgr = static_cast<uint16_t>(palette_ram_[off]) |
                         static_cast<uint16_t>(palette_ram_[off + 1] << 8);
    return Bgr555ToRgba8888(bgr);
  };

  auto sample_text_bg = [&](int bg, int x, int y, uint16_t* out_idx, bool* out_opaque) {
    *out_idx = 0;
    *out_opaque = false;
    const uint16_t bgcnt = ReadIO16(static_cast<uint32_t>(0x04000008u + bg * 2));
    const uint32_t char_base = ((bgcnt >> 2) & 0x3u) * 16u * 1024u;
    const uint32_t screen_base = ((bgcnt >> 8) & 0x1Fu) * 2u * 1024u;
    const bool color_256 = (bgcnt & (1u << 7)) != 0;
    const uint32_t screen_size = (bgcnt >> 14) & 0x3u;
    const int map_w = (screen_size & 1u) ? 64 : 32;
    const int map_h = (screen_size & 2u) ? 64 : 32;
    const uint16_t hofs = ReadIO16(static_cast<uint32_t>(0x04000010u + bg * 4));
    const uint16_t vofs = ReadIO16(static_cast<uint32_t>(0x04000012u + bg * 4));

    const int sx = (x + hofs) & (map_w * 8 - 1);
    const int sy = (y + vofs) & (map_h * 8 - 1);
    const int tile_x = sx / 8;
    const int tile_y = sy / 8;
    const int pixel_x = sx & 7;
    const int pixel_y = sy & 7;

    const int sc_x = tile_x / 32;
    const int sc_y = tile_y / 32;
    const int local_x = tile_x & 31;
    const int local_y = tile_y & 31;
    int screenblock = 0;
    switch (screen_size) {
      case 0: screenblock = 0; break;
      case 1: screenblock = sc_x; break;
      case 2: screenblock = sc_y; break;
      case 3: screenblock = sc_y * 2 + sc_x; break;
      default: screenblock = 0; break;
    }
    const size_t se_off = static_cast<size_t>(screen_base + screenblock * 0x800u +
                                              (local_y * 32 + local_x) * 2u);
    if (se_off + 1 >= vram_.size()) return;
    const uint16_t se = static_cast<uint16_t>(vram_[se_off]) |
                        static_cast<uint16_t>(vram_[se_off + 1] << 8);
    const uint16_t tile_id = se & 0x03FFu;
    const bool hflip = (se & (1u << 10)) != 0;
    const bool vflip = (se & (1u << 11)) != 0;
    const uint16_t palbank = static_cast<uint16_t>((se >> 12) & 0xFu);
    const int tx = hflip ? (7 - pixel_x) : pixel_x;
    const int ty = vflip ? (7 - pixel_y) : pixel_y;

    if (color_256) {
      const size_t chr_off = static_cast<size_t>(char_base + tile_id * 64u + ty * 8u + tx);
      const uint16_t idx = (chr_off < vram_.size()) ? vram_[chr_off] : 0;
      if ((idx & 0xFFu) == 0u) return;
      *out_idx = idx;
      *out_opaque = true;
      return;
    }
    const size_t chr_off = static_cast<size_t>(char_base + tile_id * 32u + ty * 4u + tx / 2);
    const uint8_t packed = (chr_off < vram_.size()) ? vram_[chr_off] : 0;
    const uint8_t nibble = (tx & 1) ? (packed >> 4) : (packed & 0x0F);
    if (nibble == 0) return;
    *out_idx = static_cast<uint16_t>(palbank * 16u + nibble);
    *out_opaque = true;
  };

  auto sample_affine_bg2 = [&](int x, int y, uint16_t* out_idx, bool* out_opaque) {
    *out_idx = 0;
    *out_opaque = false;
    const uint16_t bgcnt = ReadIO16(0x0400000Cu);
    const uint32_t char_base = ((bgcnt >> 2) & 0x3u) * 16u * 1024u;
    const uint32_t screen_base = ((bgcnt >> 8) & 0x1Fu) * 2u * 1024u;
    const bool wrap = (bgcnt & (1u << 13)) != 0;
    const bool mosaic = (bgcnt & (1u << 6)) != 0;
    const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
    const int mos_h = static_cast<int>((mosaic_reg & 0xFu) + 1u);
    const int mos_v = static_cast<int>(((mosaic_reg >> 4) & 0xFu) + 1u);
    const uint32_t screen_size = (bgcnt >> 14) & 0x3u;
    const int size_px = 128 << screen_size;
    const int tiles_per_row = size_px / 8;

    const int16_t pa = static_cast<int16_t>(ReadIO16(0x04000020u));
    const int16_t pb = static_cast<int16_t>(ReadIO16(0x04000022u));
    const int16_t pc = static_cast<int16_t>(ReadIO16(0x04000024u));
    const int16_t pd = static_cast<int16_t>(ReadIO16(0x04000026u));

    auto read_s32_le = [&](uint32_t addr) -> int32_t {
      const uint32_t v = static_cast<uint32_t>(Read8(addr)) |
                         (static_cast<uint32_t>(Read8(addr + 1u)) << 8) |
                         (static_cast<uint32_t>(Read8(addr + 2u)) << 16) |
                         (static_cast<uint32_t>(Read8(addr + 3u)) << 24);
      int32_t s = static_cast<int32_t>(v);
      if ((s & 0x08000000) != 0) s |= static_cast<int32_t>(0xF0000000);
      return s;
    };
    const int32_t bg2x = read_s32_le(0x04000028u);
    const int32_t bg2y = read_s32_le(0x0400002Cu);

    const int sample_x = mosaic ? ((x / mos_h) * mos_h) : x;
    const int sample_y = mosaic ? ((y / mos_v) * mos_v) : y;
    int64_t ref_x = static_cast<int64_t>(bg2x) +
                    static_cast<int64_t>(pa) * sample_x + static_cast<int64_t>(pb) * sample_y;
    int64_t ref_y = static_cast<int64_t>(bg2y) +
                    static_cast<int64_t>(pc) * sample_x + static_cast<int64_t>(pd) * sample_y;
    int tx = static_cast<int>(ref_x >> 8);
    int ty = static_cast<int>(ref_y >> 8);

    if (wrap) {
      tx %= size_px;
      ty %= size_px;
      if (tx < 0) tx += size_px;
      if (ty < 0) ty += size_px;
    } else if (tx < 0 || ty < 0 || tx >= size_px || ty >= size_px) {
      return;
    }

    const int tile_x = tx / 8;
    const int tile_y = ty / 8;
    const int pixel_x = tx & 7;
    const int pixel_y = ty & 7;
    const size_t map_off = static_cast<size_t>(screen_base + tile_y * tiles_per_row + tile_x);
    if (map_off >= vram_.size()) return;
    const uint16_t tile_id = vram_[map_off];
    const size_t chr_off = static_cast<size_t>(char_base + tile_id * 64u + pixel_y * 8u + pixel_x);
    if (chr_off >= vram_.size()) return;
    const uint16_t idx = vram_[chr_off];
    if ((idx & 0xFFu) == 0u) return;
    *out_idx = idx;
    *out_opaque = true;
  };

  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      uint16_t best_idx = 0;
      int best_prio = 4;
      bool have_bg = false;
      uint8_t best_bg_layer = kLayerBackdrop;
      uint16_t second_idx = 0;
      int second_prio = 4;
      bool have_second = false;
      uint8_t second_bg_layer = kLayerBackdrop;

      auto consider = [&](uint16_t idx, int prio, uint8_t layer) {
        if (!have_bg || prio < best_prio || (prio == best_prio && layer < best_bg_layer)) {
          if (have_bg) {
            second_idx = best_idx;
            second_prio = best_prio;
            second_bg_layer = best_bg_layer;
            have_second = true;
          }
          best_idx = idx;
          best_prio = prio;
          best_bg_layer = layer;
          have_bg = true;
          return;
        }
        if (!have_second || prio < second_prio || (prio == second_prio && layer < second_bg_layer)) {
          second_idx = idx;
          second_prio = prio;
          second_bg_layer = layer;
          have_second = true;
        }
      };

      if ((dispcnt & (1u << 8)) != 0 &&
          IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 0, x, y)) {
        uint16_t idx = 0;
        bool opaque = false;
        sample_text_bg(0, x, y, &idx, &opaque);
        if (opaque) {
          const int prio = ReadIO16(0x04000008u) & 0x3u;
          consider(idx, prio, kLayerBg0);
        }
      }
      if ((dispcnt & (1u << 9)) != 0 &&
          IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 1, x, y)) {
        uint16_t idx = 0;
        bool opaque = false;
        sample_text_bg(1, x, y, &idx, &opaque);
        if (opaque) {
          const int prio = ReadIO16(0x0400000Au) & 0x3u;
          consider(idx, prio, kLayerBg1);
        }
      }
      if ((dispcnt & (1u << 10)) != 0 &&
          IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 2, x, y)) {
        uint16_t idx = 0;
        bool opaque = false;
        sample_affine_bg2(x, y, &idx, &opaque);
        if (opaque) {
          const int prio = ReadIO16(0x0400000Cu) & 0x3u;
          consider(idx, prio, kLayerBg2);
        }
      }
      const size_t off = static_cast<size_t>(y) * kScreenWidth + x;
      frame_buffer_[off] = palette_color(have_bg ? best_idx : 0);
      bg_priority[off] =
          static_cast<uint8_t>(have_bg ? best_prio : kBackdropPriority);
      bg_layer[off] = have_bg ? best_bg_layer : kLayerBackdrop;
      second_color[off] = palette_color(have_second ? second_idx : 0);
      second_layer[off] = have_second ? second_bg_layer : kLayerBackdrop;
    }
  }
}

void GBACore::RenderMode2Frame() {
  EnsureBgPriorityBufferSize();
  EnsureBgLayerBufferSize();
  EnsureBgSecondBuffersSize();
  auto& bg_layer = BgLayerBuffer();
  auto& bg_priority = BgPriorityBuffer();
  auto& second_color = BgSecondColorBuffer();
  auto& second_layer = BgSecondLayerBuffer();
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint16_t winin = ReadIO16(0x04000048u);
  const uint16_t winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u);
  const uint16_t win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u);
  const uint16_t win1v = ReadIO16(0x04000046u);

  auto palette_color = [&](uint16_t idx) -> uint32_t {
    const size_t off = static_cast<size_t>((idx & 0x1FFu) * 2u);
    if (off + 1 >= palette_ram_.size()) return 0xFF000000u;
    const uint16_t bgr = static_cast<uint16_t>(palette_ram_[off]) |
                         static_cast<uint16_t>(palette_ram_[off + 1] << 8);
    return Bgr555ToRgba8888(bgr);
  };

  auto sample_affine_bg = [&](int bg, int x, int y, uint16_t* out_idx, bool* out_opaque) {
    *out_idx = 0;
    *out_opaque = false;

    const uint32_t bgcnt_addr = static_cast<uint32_t>(0x04000008u + bg * 2u);
    const uint16_t bgcnt = ReadIO16(bgcnt_addr);
    const uint32_t char_base = ((bgcnt >> 2) & 0x3u) * 16u * 1024u;
    const uint32_t screen_base = ((bgcnt >> 8) & 0x1Fu) * 2u * 1024u;
    const bool wrap = (bgcnt & (1u << 13)) != 0;
    const bool mosaic = (bgcnt & (1u << 6)) != 0;
    const uint16_t mosaic_reg = ReadIO16(0x0400004Cu);
    const int mos_h = static_cast<int>((mosaic_reg & 0xFu) + 1u);
    const int mos_v = static_cast<int>(((mosaic_reg >> 4) & 0xFu) + 1u);
    const uint32_t screen_size = (bgcnt >> 14) & 0x3u;
    const int size_px = 128 << screen_size;
    const int tiles_per_row = size_px / 8;

    const uint32_t affine_base = (bg == 2) ? 0x04000020u : 0x04000030u;
    const int16_t pa = static_cast<int16_t>(ReadIO16(affine_base + 0u));
    const int16_t pb = static_cast<int16_t>(ReadIO16(affine_base + 2u));
    const int16_t pc = static_cast<int16_t>(ReadIO16(affine_base + 4u));
    const int16_t pd = static_cast<int16_t>(ReadIO16(affine_base + 6u));

    const uint32_t ref_base = (bg == 2) ? 0x04000028u : 0x04000038u;
    auto read_s32_le = [&](uint32_t addr) -> int32_t {
      const uint32_t v = static_cast<uint32_t>(Read8(addr)) |
                         (static_cast<uint32_t>(Read8(addr + 1u)) << 8) |
                         (static_cast<uint32_t>(Read8(addr + 2u)) << 16) |
                         (static_cast<uint32_t>(Read8(addr + 3u)) << 24);
      int32_t s = static_cast<int32_t>(v);
      if ((s & 0x08000000) != 0) s |= static_cast<int32_t>(0xF0000000);
      return s;
    };
    const int32_t refx = read_s32_le(ref_base);
    const int32_t refy = read_s32_le(ref_base + 4u);

    const int sample_x = mosaic ? ((x / mos_h) * mos_h) : x;
    const int sample_y = mosaic ? ((y / mos_v) * mos_v) : y;
    int64_t tex_x_fp = static_cast<int64_t>(refx) +
                       static_cast<int64_t>(pa) * sample_x + static_cast<int64_t>(pb) * sample_y;
    int64_t tex_y_fp = static_cast<int64_t>(refy) +
                       static_cast<int64_t>(pc) * sample_x + static_cast<int64_t>(pd) * sample_y;
    int tx = static_cast<int>(tex_x_fp >> 8);
    int ty = static_cast<int>(tex_y_fp >> 8);

    if (wrap) {
      tx %= size_px;
      ty %= size_px;
      if (tx < 0) tx += size_px;
      if (ty < 0) ty += size_px;
    } else if (tx < 0 || ty < 0 || tx >= size_px || ty >= size_px) {
      return;
    }

    const int tile_x = tx / 8;
    const int tile_y = ty / 8;
    const int pixel_x = tx & 7;
    const int pixel_y = ty & 7;
    const size_t map_off = static_cast<size_t>(screen_base + tile_y * tiles_per_row + tile_x);
    if (map_off >= vram_.size()) return;
    const uint16_t tile_id = vram_[map_off];
    const size_t chr_off = static_cast<size_t>(char_base + tile_id * 64u + pixel_y * 8u + pixel_x);
    if (chr_off >= vram_.size()) return;
    const uint16_t idx = vram_[chr_off];
    if ((idx & 0xFFu) == 0u) return;

    *out_idx = idx;
    *out_opaque = true;
  };

  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      uint16_t best_idx = 0;
      int best_prio = 4;
      bool have_bg = false;
      uint8_t best_bg_layer = kLayerBackdrop;
      uint16_t second_idx = 0;
      int second_prio = 4;
      bool have_second = false;
      uint8_t second_bg_layer = kLayerBackdrop;

      auto consider = [&](uint16_t idx, int prio, uint8_t layer) {
        if (!have_bg || prio < best_prio || (prio == best_prio && layer < best_bg_layer)) {
          if (have_bg) {
            second_idx = best_idx;
            second_prio = best_prio;
            second_bg_layer = best_bg_layer;
            have_second = true;
          }
          best_idx = idx;
          best_prio = prio;
          best_bg_layer = layer;
          have_bg = true;
          return;
        }
        if (!have_second || prio < second_prio || (prio == second_prio && layer < second_bg_layer)) {
          second_idx = idx;
          second_prio = prio;
          second_bg_layer = layer;
          have_second = true;
        }
      };

      if ((dispcnt & (1u << 10)) != 0 &&
          IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 2, x, y)) {
        uint16_t idx = 0;
        bool opaque = false;
        sample_affine_bg(2, x, y, &idx, &opaque);
        if (opaque) {
          const int prio = ReadIO16(0x0400000Cu) & 0x3u;
          consider(idx, prio, kLayerBg2);
        }
      }
      if ((dispcnt & (1u << 11)) != 0 &&
          IsBgVisibleByWindow(dispcnt, winin, winout, win0h, win0v, win1h, win1v, 3, x, y)) {
        uint16_t idx = 0;
        bool opaque = false;
        sample_affine_bg(3, x, y, &idx, &opaque);
        if (opaque) {
          const int prio = ReadIO16(0x0400000Eu) & 0x3u;
          consider(idx, prio, kLayerBg3);
        }
      }

      const size_t off = static_cast<size_t>(y) * kScreenWidth + x;
      frame_buffer_[off] = palette_color(have_bg ? best_idx : 0);
      bg_priority[off] =
          static_cast<uint8_t>(have_bg ? best_prio : kBackdropPriority);
      bg_layer[off] = have_bg ? best_bg_layer : kLayerBackdrop;
      second_color[off] = palette_color(have_second ? second_idx : 0);
      second_layer[off] = have_second ? second_bg_layer : kLayerBackdrop;
    }
  }
}

void GBACore::StepPpu(uint32_t cycles) {
  constexpr uint32_t kHBlankStartCycle = mgba_compat::kVideoHDrawCycles;
  auto write_io_raw16 = [&](uint32_t addr, uint16_t value) {
    const size_t off = static_cast<size_t>(addr - 0x04000000u);
    if (off + 1 >= io_regs_.size()) return;
    io_regs_[off] = static_cast<uint8_t>(value & 0xFFu);
    io_regs_[off + 1] = static_cast<uint8_t>((value >> 8) & 0xFFu);
  };
  uint32_t remaining = cycles;
  while (remaining > 0) {
    uint16_t dispstat = ReadIO16(0x04000004u);
    const bool in_hblank = (dispstat & 0x0002u) != 0;
    const uint32_t boundary = in_hblank ? kCyclesPerScanline : kHBlankStartCycle;
    const uint32_t until_boundary = (ppu_cycle_accum_ < boundary) ? (boundary - ppu_cycle_accum_) : 0u;
    const uint32_t advance = std::min<uint32_t>(remaining, std::max<uint32_t>(1u, until_boundary));
    ppu_cycle_accum_ += advance;
    remaining -= advance;

    // HBlank edge
    if (!in_hblank && ppu_cycle_accum_ >= kHBlankStartCycle) {
      dispstat = static_cast<uint16_t>(dispstat | 0x0002u);
      if (dispstat & (1u << 4)) {
        RaiseInterrupt(1u << 1);  // HBlank IRQ
      }
      write_io_raw16(0x04000004u, dispstat);
    }

    // End-of-scanline edge
    if (ppu_cycle_accum_ >= kCyclesPerScanline) {
      ppu_cycle_accum_ -= kCyclesPerScanline;

      uint16_t vcount = ReadIO16(0x04000006u);
      vcount = static_cast<uint16_t>((vcount + 1u) % mgba_compat::kVideoTotalLines);
      write_io_raw16(0x04000006u, vcount);

      dispstat = ReadIO16(0x04000004u);
      const bool was_vblank = (dispstat & 0x0001u) != 0;
      const bool now_vblank = vcount >= mgba_compat::kVideoVisibleLines;
      if (now_vblank) {
        dispstat = static_cast<uint16_t>(dispstat | 0x0001u);
        if (!was_vblank && (dispstat & (1u << 3))) {
          RaiseInterrupt(0x0001u);  // VBlank IRQ
        }
      } else {
        dispstat = static_cast<uint16_t>(dispstat & ~0x0001u);
      }

      const uint16_t vcount_compare = static_cast<uint16_t>((dispstat >> 8) & 0x00FFu);
      const bool vcount_match = (vcount == vcount_compare);
      if (vcount_match) {
        if ((dispstat & 0x0004u) == 0u && (dispstat & (1u << 5))) {
          RaiseInterrupt(1u << 2);  // VCount IRQ
        }
        dispstat = static_cast<uint16_t>(dispstat | 0x0004u);
      } else {
        dispstat = static_cast<uint16_t>(dispstat & ~0x0004u);
      }

      // New scanline starts outside HBlank.
      dispstat = static_cast<uint16_t>(dispstat & ~0x0002u);
      write_io_raw16(0x04000004u, dispstat);
    }
  }
}

void GBACore::StepTimers(uint32_t cycles) {
  static constexpr uint32_t kPrescalerLut[4] = {1, 64, 256, 1024};
  bool overflowed[4] = {false, false, false, false};
  for (size_t i = 0; i < timers_.size(); ++i) {
    TimerState& t = timers_[i];
    const uint16_t cnt_h = ReadIO16(static_cast<uint32_t>(0x04000102u + i * 4u));
    t.control = cnt_h;
    if ((cnt_h & 0x0080u) == 0) continue;  // disabled
    const bool count_up = (cnt_h & 0x0004u) != 0;

    auto tick_once = [&](bool* ov) {
      const uint16_t old = t.counter;
      t.counter = static_cast<uint16_t>(t.counter + 1u);
      if (t.counter == 0) {
        t.counter = ReadIO16(static_cast<uint32_t>(0x04000100u + i * 4u));
        ConsumeAudioFifoOnTimer(i);
        if (cnt_h & 0x0040u) {
          RaiseInterrupt(static_cast<uint16_t>(1u << static_cast<uint16_t>(3u + i)));
        }
        *ov = true;
      }
      if (old == 0xFFFFu) return;
    };

    if (count_up && i > 0) {
      if (overflowed[i - 1]) {
        tick_once(&overflowed[i]);
      }
      WriteIO16(static_cast<uint32_t>(0x04000100u + i * 4u), t.counter);
      continue;
    }

    const uint32_t prescaler = kPrescalerLut[cnt_h & 0x3u];
    t.prescaler_accum += cycles;
    while (t.prescaler_accum >= prescaler) {
      t.prescaler_accum -= prescaler;
      tick_once(&overflowed[i]);
    }
    WriteIO16(static_cast<uint32_t>(0x04000100u + i * 4u), t.counter);
  }
}

void GBACore::StepDma() {
  const uint16_t dispstat = ReadIO16(0x04000004u);
  const bool in_vblank = (dispstat & 0x0001u) != 0;
  const bool in_hblank = (dispstat & 0x0002u) != 0;
  const bool vblank_rising = in_vblank && !dma_was_in_vblank_;
  const bool hblank_rising = in_hblank && !dma_was_in_hblank_;
  dma_was_in_vblank_ = in_vblank;
  dma_was_in_hblank_ = in_hblank;
  for (int ch = 0; ch < 4; ++ch) {
    const uint32_t base = static_cast<uint32_t>(0x040000B0u + ch * 12u);
    const uint32_t src = Read32(base + 0u);
    const uint32_t dst = Read32(base + 4u);
    const uint16_t cnt_l = ReadIO16(base + 8u);
    const uint16_t cnt_h = ReadIO16(base + 10u);
    if ((cnt_h & 0x8000u) == 0) continue;
    const uint16_t start_timing = static_cast<uint16_t>((cnt_h >> 12) & 0x3u);
    bool fire_now = false;
    if (start_timing == 0u) fire_now = true;                      // Immediate
    if (start_timing == 1u && vblank_rising) fire_now = true;     // VBlank edge
    if (start_timing == 2u && hblank_rising) fire_now = true;     // HBlank edge
    if (start_timing == 3u) {
      // Sound FIFO DMA (DMA1/DMA2) request timing.
      if (ch != 1 && ch != 2) continue;
      const uint32_t fifo_addr = dst & ~3u;
      const bool is_fifo_a = fifo_addr == 0x040000A0u;
      const bool is_fifo_b = fifo_addr == 0x040000A4u;
      if (!is_fifo_a && !is_fifo_b) continue;
      fire_now = is_fifo_a ? dma_fifo_a_request_ : dma_fifo_b_request_;
      if (!fire_now) continue;
      if (is_fifo_a) dma_fifo_a_request_ = false;
      if (is_fifo_b) dma_fifo_b_request_ = false;
    }
    if (!fire_now) continue;

    bool word32 = (cnt_h & (1u << 10)) != 0;
    uint32_t count = cnt_l;
    if (count == 0) count = (ch == 3) ? 0x10000u : 0x4000u;
    if (start_timing == 3u) {
      // FIFO DMA always transfers 4 words and keeps destination fixed.
      word32 = true;
      count = mgba_compat::kAudioFifoDmaWordsPerBurst;
    }

    int dst_ctl = (cnt_h >> 5) & 0x3;
    const int src_ctl = (cnt_h >> 7) & 0x3;
    if (start_timing == 3u) dst_ctl = 2;  // fixed destination (FIFO register)
    const int step = word32 ? 4 : 2;
    int dst_step = step;
    int src_step = step;
    if (dst_ctl == 1) dst_step = -step;
    if (dst_ctl == 2) dst_step = 0;
    if (src_ctl == 1) src_step = -step;
    if (src_ctl == 2) src_step = 0;

    uint32_t src_cur = src;
    uint32_t dst_cur = dst;
    for (uint32_t n = 0; n < count; ++n) {
      if (word32) {
        Write32(dst_cur, Read32(src_cur));
      } else {
        Write16(dst_cur, Read16(src_cur));
      }
      src_cur = static_cast<uint32_t>(static_cast<int64_t>(src_cur) + src_step);
      dst_cur = static_cast<uint32_t>(static_cast<int64_t>(dst_cur) + dst_step);
    }

    Write32(base + 0u, src_cur);
    Write32(base + 4u, (dst_ctl == 3) ? dst : dst_cur);
    const bool repeat = (cnt_h & (1u << 9)) != 0;
    uint16_t next_cnt_h = cnt_h;
    if (!(repeat && start_timing != 0u)) {
      next_cnt_h = static_cast<uint16_t>(cnt_h & ~0x8000u);
    }
    WriteIO16(base + 10u, next_cnt_h);
    if (cnt_h & (1u << 14)) {
      RaiseInterrupt(static_cast<uint16_t>(1u << static_cast<uint16_t>(8u + ch)));
    }
  }
}

void GBACore::PushAudioFifo(bool fifo_a, uint32_t value) {
  auto& fifo = fifo_a ? fifo_a_ : fifo_b_;
  for (int i = 0; i < 4; ++i) {
    fifo.push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xFFu));
  }
  if (fifo.size() > mgba_compat::kAudioFifoCapacityBytes) {
    fifo.erase(fifo.begin(), fifo.begin() + static_cast<std::ptrdiff_t>(
      fifo.size() - mgba_compat::kAudioFifoCapacityBytes));
  }
}

void GBACore::ConsumeAudioFifoOnTimer(size_t timer_index) {
  const uint16_t soundcnt_h = ReadIO16(0x04000082u);
  const bool fifo_a_timer1 = (soundcnt_h & (1u << 10)) != 0;
  const bool fifo_b_timer1 = (soundcnt_h & (1u << 14)) != 0;
  auto pop_fifo = [&](std::vector<uint8_t>* fifo, int16_t* last_sample) {
    if (!fifo->empty()) {
      const int8_t sample = static_cast<int8_t>(fifo->front());
      fifo->erase(fifo->begin());
      *last_sample = static_cast<int16_t>(sample);
    } else {
      *last_sample = 0;
    }
  };
  if ((timer_index == 0u && !fifo_a_timer1) || (timer_index == 1u && fifo_a_timer1)) {
    pop_fifo(&fifo_a_, &fifo_a_last_sample_);
    if (fifo_a_.size() <= mgba_compat::kAudioFifoDmaRequestThreshold) dma_fifo_a_request_ = true;
  }
  if ((timer_index == 0u && !fifo_b_timer1) || (timer_index == 1u && fifo_b_timer1)) {
    pop_fifo(&fifo_b_, &fifo_b_last_sample_);
    if (fifo_b_.size() <= mgba_compat::kAudioFifoDmaRequestThreshold) dma_fifo_b_request_ = true;
  }
}

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
    const uint16_t nr12 = ReadIO16(0x04000063u);
    const uint16_t nr13 = ReadIO16(0x04000064u);
    const uint16_t nr14 = ReadIO16(0x04000065u);
    const uint16_t freq = static_cast<uint16_t>(nr13 | ((nr14 & 0x7u) << 8));
    const int env_vol = std::max<int>(0, std::min<int>(15, apu_env_ch1_));
    ch1 = (square_sample(&apu_phase_sq1_, freq, nr11) * env_vol) / 15;
  }
  if (apu_ch2_active_) {  // CH2
    const uint16_t nr21 = ReadIO16(0x04000068u);
    const uint16_t nr22 = ReadIO16(0x04000069u);
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
    const uint16_t nr42 = ReadIO16(0x04000077u);
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
                          static_cast<uint16_t>(io_regs_[off + 1] << 8);
  const uint16_t next = static_cast<uint16_t>(if_reg | mask);
  io_regs_[off] = static_cast<uint8_t>(next & 0xFF);
  io_regs_[off + 1] = static_cast<uint8_t>((next >> 8) & 0xFF);
}

void GBACore::EnterException(uint32_t vector_addr, uint32_t new_mode, bool disable_irq, bool thumb_state) {
  const uint32_t old_cpsr = cpu_.cpsr;
  const uint32_t target_mode = new_mode & 0x1Fu;
  debug_last_exception_vector_ = vector_addr;
  debug_last_exception_pc_ = cpu_.regs[15];
  debug_last_exception_cpsr_ = old_cpsr;
  const bool old_thumb = (old_cpsr & (1u << 5)) != 0;
  uint32_t lr_adjust = old_thumb ? 2u : 4u;
  // IRQ/FIQ return uses SUBS PC,LR,#4; LR must be biased accordingly.
  if (vector_addr == 0x00000018u || vector_addr == 0x0000001Cu) {
    lr_adjust = 4u;
  }
  SwitchCpuMode(target_mode);
  if (HasSpsr(target_mode)) cpu_.spsr[target_mode] = old_cpsr;
  cpu_.regs[14] = cpu_.regs[15] + lr_adjust;
  cpu_.cpsr = (cpu_.cpsr & ~0x1Fu) | target_mode;
  cpu_.active_mode = target_mode;
  if (disable_irq) cpu_.cpsr |= (1u << 7);
  if (thumb_state) {
    cpu_.cpsr |= (1u << 5);
    cpu_.regs[15] = vector_addr & ~1u;
  } else {
    cpu_.cpsr &= ~(1u << 5);
    cpu_.regs[15] = vector_addr & ~3u;
  }
}

void GBACore::ServiceInterruptIfNeeded() {
  const uint16_t ime = ReadIO16(0x04000208u) & 0x1u;
  if (ime == 0) return;
  if (cpu_.cpsr & (1u << 7)) return;  // I flag set
  const uint16_t ie = ReadIO16(0x04000200u);
  const uint16_t iflags = ReadIO16(0x04000202u);
  const uint16_t pending = static_cast<uint16_t>(ie & iflags);
  if (pending == 0) return;
  // Keep BIOS-style IRQ flags mirror in IWRAM for IntrWait/VBlankIntrWait users.
  const uint32_t irq_flags_addr = 0x03007FF8u;
  const uint32_t old_irq_flags = Read32(irq_flags_addr);
  Write32(irq_flags_addr, old_irq_flags | pending);

  // If BIOS is available, route through the hardware IRQ vector.
  if (bios_loaded_) {
    EnterException(0x00000018u, 0x12u, true, false);
    return;
  }
  // No BIOS: prefer cartridge-provided IRQ vector (0x03007FFC).
  const uint32_t irq_vector = Read32(0x03007FFCu);
  const bool vector_thumb = (irq_vector & 1u) != 0;
  const uint32_t vector_addr = irq_vector & ~1u;
  const bool vector_valid = (vector_addr >= 0x08000000u && vector_addr <= 0x0DFFFFFFu);
  if (vector_valid) {
    EnterException(vector_addr, 0x12u, true, vector_thumb);
    return;
  }
  // No safe vector installed; keep pending flags latched for polling code.
}

void GBACore::ApplyColorEffects() {
  const uint16_t dispcnt = ReadIO16(0x04000000u);
  const uint16_t winin = ReadIO16(0x04000048u);
  const uint16_t winout = ReadIO16(0x0400004Au);
  const uint16_t win0h = ReadIO16(0x04000040u);
  const uint16_t win0v = ReadIO16(0x04000042u);
  const uint16_t win1h = ReadIO16(0x04000044u);
  const uint16_t win1v = ReadIO16(0x04000046u);
  const uint16_t bldcnt = ReadIO16(0x04000050u);
  const uint16_t bldalpha = ReadIO16(0x04000052u);
  const uint16_t bldy = ReadIO16(0x04000054u);
  const uint32_t mode = (bldcnt >> 6) & 0x3u;
  if (mode == 0u) return;

  const uint32_t eva = std::min<uint32_t>(16u, bldalpha & 0x1Fu);
  const uint32_t evb = std::min<uint32_t>(16u, (bldalpha >> 8) & 0x1Fu);
  const uint32_t evy = std::min<uint32_t>(16u, bldy & 0x1Fu);
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));
  const uint8_t back_r = static_cast<uint8_t>((backdrop >> 16) & 0xFFu);
  const uint8_t back_g = static_cast<uint8_t>((backdrop >> 8) & 0xFFu);
  const uint8_t back_b = static_cast<uint8_t>(backdrop & 0xFFu);
  auto& bg_layer = BgLayerBuffer();
  auto& bg_priority = BgPriorityBuffer();
  auto& obj_drawn = ObjDrawnMaskBuffer();
  auto& bg_base = BgBaseColorBuffer();
  auto& bg_second = BgSecondColorBuffer();
  auto& bg_second_layer = BgSecondLayerBuffer();
  for (int y = 0; y < kScreenHeight; ++y) {
    for (int x = 0; x < kScreenWidth; ++x) {
      const size_t fb_off = static_cast<size_t>(y) * kScreenWidth + x;
      const uint8_t window_control =
          ResolveWindowControl(dispcnt, winin, winout, win0h, win0v, win1h, win1v, ObjWindowMaskBuffer(), x, y);
      if ((window_control & (1u << 5)) == 0) continue;  // color effects masked by window
      const bool top_is_obj = (fb_off < obj_drawn.size()) && (obj_drawn[fb_off] != 0u);
      const uint8_t top_layer = (fb_off < bg_layer.size()) ? bg_layer[fb_off] : kLayerBackdrop;
      const uint16_t top_mask = LayerToBlendMask(top_layer, top_is_obj);
      if ((bldcnt & top_mask) == 0) continue;  // top pixel is not 1st target

      uint32_t& px = frame_buffer_[fb_off];
      uint8_t r = static_cast<uint8_t>((px >> 16) & 0xFFu);
      uint8_t g = static_cast<uint8_t>((px >> 8) & 0xFFu);
      uint8_t b = static_cast<uint8_t>(px & 0xFFu);
      if (mode == 1u) {
        uint8_t sr = back_r;
        uint8_t sg = back_g;
        uint8_t sb = back_b;
        uint16_t second_mask = static_cast<uint16_t>(1u << (8 + 5));  // backdrop
        if (top_is_obj && fb_off < bg_base.size() && fb_off < bg_priority.size() &&
            bg_priority[fb_off] != kBackdropPriority) {
          const uint8_t under_layer = (fb_off < bg_layer.size()) ? bg_layer[fb_off] : kLayerBackdrop;
          second_mask = static_cast<uint16_t>(1u << (8u + std::min<uint8_t>(under_layer, 5u)));
          const uint32_t under = bg_base[fb_off];
          sr = static_cast<uint8_t>((under >> 16) & 0xFFu);
          sg = static_cast<uint8_t>((under >> 8) & 0xFFu);
          sb = static_cast<uint8_t>(under & 0xFFu);
        } else if (!top_is_obj && fb_off < bg_second.size() && fb_off < bg_second_layer.size() &&
                   bg_second_layer[fb_off] != kLayerBackdrop) {
          const uint8_t under_layer = bg_second_layer[fb_off];
          second_mask = static_cast<uint16_t>(1u << (8u + std::min<uint8_t>(under_layer, 5u)));
          const uint32_t under = bg_second[fb_off];
          sr = static_cast<uint8_t>((under >> 16) & 0xFFu);
          sg = static_cast<uint8_t>((under >> 8) & 0xFFu);
          sb = static_cast<uint8_t>(under & 0xFFu);
        }
        if ((bldcnt & second_mask) == 0) continue;
        r = ClampToByteLocal(static_cast<int>((r * eva + sr * evb) / 16u));
        g = ClampToByteLocal(static_cast<int>((g * eva + sg * evb) / 16u));
        b = ClampToByteLocal(static_cast<int>((b * eva + sb * evb) / 16u));
      } else if (mode == 2u) {  // brighten
        r = ClampToByteLocal(static_cast<int>(r + ((255 - r) * evy) / 16u));
        g = ClampToByteLocal(static_cast<int>(g + ((255 - g) * evy) / 16u));
        b = ClampToByteLocal(static_cast<int>(b + ((255 - b) * evy) / 16u));
      } else if (mode == 3u) {  // darken
        r = ClampToByteLocal(static_cast<int>(r - (r * evy) / 16u));
        g = ClampToByteLocal(static_cast<int>(g - (g * evy) / 16u));
        b = ClampToByteLocal(static_cast<int>(b - (b * evy) / 16u));
      }
      px = 0xFF000000u | (static_cast<uint32_t>(r) << 16) |
           (static_cast<uint32_t>(g) << 8) | b;
    }
  }
}

void GBACore::RenderDebugFrame() {
  if (frame_buffer_.empty()) {
    frame_buffer_.assign(kScreenWidth * kScreenHeight, 0xFF000000U);
  }

  const uint16_t dispcnt = ReadIO16(0x04000000u);
  if ((dispcnt & (1u << 7)) != 0) {
    std::fill(frame_buffer_.begin(), frame_buffer_.end(), 0xFFFFFFFFu);
    EnsureBgPriorityBufferSize();
    std::fill(BgPriorityBuffer().begin(), BgPriorityBuffer().end(),
              static_cast<uint8_t>(kBackdropPriority));
    return;
  }
  EnsureObjDrawnMaskBufferSize();
  EnsureBgBaseColorBufferSize();
  EnsureBgSecondBuffersSize();
  BuildObjWindowMask();
  const uint16_t bg_mode = dispcnt & 0x7u;
  if (bg_mode == 0u) {
    RenderMode0Frame();
    BgBaseColorBuffer() = frame_buffer_;
    RenderSprites();
    ApplyColorEffects();
    return;
  }
  if (bg_mode == 1u) {
    RenderMode1Frame();
    BgBaseColorBuffer() = frame_buffer_;
    RenderSprites();
    ApplyColorEffects();
    return;
  }
  if (bg_mode == 2u) {
    RenderMode2Frame();
    BgBaseColorBuffer() = frame_buffer_;
    RenderSprites();
    ApplyColorEffects();
    return;
  }
  if (bg_mode == 3u) {
    RenderMode3Frame();
    BgBaseColorBuffer() = frame_buffer_;
    RenderSprites();
    ApplyColorEffects();
    return;
  }
  if (bg_mode == 4u) {
    RenderMode4Frame();
    BgBaseColorBuffer() = frame_buffer_;
    RenderSprites();
    ApplyColorEffects();
    return;
  }
  if (bg_mode == 5u) {
    RenderMode5Frame();
    BgBaseColorBuffer() = frame_buffer_;
    RenderSprites();
    ApplyColorEffects();
    return;
  }
  const uint32_t backdrop = Bgr555ToRgba8888(ReadBackdropBgr(palette_ram_));
  std::fill(frame_buffer_.begin(), frame_buffer_.end(), backdrop);
  EnsureBgPriorityBufferSize();
  std::fill(BgPriorityBuffer().begin(), BgPriorityBuffer().end(),
            static_cast<uint8_t>(kBackdropPriority));
}

uint64_t GBACore::ComputeFrameHash() const {
  uint64_t hash = 1469598103934665603ULL;
  constexpr uint64_t kPrime = 1099511628211ULL;

  for (uint32_t px : frame_buffer_) {
    hash ^= px;
    hash *= kPrime;
  }
  hash ^= static_cast<uint64_t>(gameplay_state_.player_x) << 1;
  hash ^= static_cast<uint64_t>(gameplay_state_.player_y) << 9;
  hash ^= static_cast<uint64_t>(gameplay_state_.score) << 17;
  return hash;
}

bool GBACore::ValidateFrameBuffer(std::string* error) const {
  const size_t expected_size = static_cast<size_t>(kScreenWidth) * static_cast<size_t>(kScreenHeight);
  if (frame_buffer_.size() != expected_size) {
    if (error) *error = "Invalid framebuffer size.";
    return false;
  }

  uint32_t first_px = 0;
  bool first_px_set = false;
  bool found_distinct_pixel = false;
  uint32_t row_xor_accum = 0;

  for (int y = 0; y < kScreenHeight; ++y) {
    uint32_t row_hash = 2166136261u;
    for (int x = 0; x < kScreenWidth; ++x) {
      const uint32_t px = frame_buffer_[static_cast<size_t>(y) * kScreenWidth + x];
      if ((px & 0xFF000000u) != 0xFF000000u) {
        if (error) *error = "Found pixel with invalid alpha channel.";
        return false;
      }
      row_hash ^= px;
      row_hash *= 16777619u;
    }

    row_xor_accum ^= row_hash;

    for (int x = 0; x < kScreenWidth; ++x) {
      const uint32_t px = frame_buffer_[static_cast<size_t>(y) * kScreenWidth + x];
      if (!first_px_set) {
        first_px = px;
        first_px_set = true;
      } else if (px != first_px) {
        found_distinct_pixel = true;
      }
    }
  }

  if (!found_distinct_pixel) {
    if (error) *error = "Framebuffer has no visible variation (all pixels identical).";
    return false;
  }
  if (row_xor_accum == 0u) {
    if (error) *error = "Framebuffer row signatures collapsed unexpectedly.";
    return false;
  }
  return true;
}


}  // namespace gba

// ---- END gba_core_ppu.cpp ----
