#include "../gba_core.h"

#include <algorithm>

namespace gba {

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
  append_u32(&blob, 11u);  // version
  append_u64(&blob, frame_count_);
  append_u64(&blob, executed_cycles_);
  append_u32(&blob, cpu_.cpsr);
  append_u32(&blob, ppu_cycle_accum_);
  append_u32(&blob, audio_mix_level_);
  append_u32(&blob, bios_fetch_latch_);
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
  append_u32(&blob, static_cast<uint32_t>(eeprom_addr_bits_));
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
    if (!read_u32(&off, &bios_fetch_latch_)) return false;
  } else {
    bios_fetch_latch_ = 0;
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
        if (version >= 11u) {
          if (!read_u32(&off, &tmp32)) return false;
          eeprom_addr_bits_ = static_cast<uint8_t>(tmp32 & 0x0Fu);
        } else {
          eeprom_addr_bits_ = 0;
        }
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
        eeprom_addr_bits_ = 0;
      }
    } else {
      flash_bank_switch_mode_ = false;
      flash_bank_ = 0;
      eeprom_cmd_bits_.clear();
      eeprom_read_bits_.clear();
      eeprom_read_pos_ = 0;
      eeprom_addr_bits_ = 0;
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

}  // namespace gba
