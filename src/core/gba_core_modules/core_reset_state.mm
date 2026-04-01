#include "../gba_core.h"
#include <algorithm>
#include <cstring>

namespace gba {

void GBACore::Reset() {
  // Clear CPU state
  cpu_.regs.fill(0);
  cpu_.cpsr = 0x1Fu; // System mode
  cpu_.banked_fiq_r8_r12.fill(0);
  cpu_.banked_sp.fill(0);
  cpu_.banked_lr.fill(0);
  cpu_.spsr.fill(0);
  cpu_.active_mode = 0x1Fu;
  cpu_.halted = false;

  // Initial PC depends on BIOS
  if (bios_loaded_) {
    cpu_.regs[15] = 0x00000000;
  } else {
    cpu_.regs[15] = 0x08000000;
  }

  // Clear memory
  ewram_.fill(0);
  iwram_.fill(0);
  io_regs_.fill(0);
  palette_ram_.fill(0);
  vram_.fill(0);
  oam_.fill(0);
  // SRAM is usually persistent, but reset for clean start if not loaded
  // sram_.fill(0xFF);

  // Reset PPU state
  ppu_cycle_accum_ = 0;
  bg2_refx_internal_ = 0;
  bg2_refy_internal_ = 0;
  bg3_refx_internal_ = 0;
  bg3_refy_internal_ = 0;

  // Reset APU
  fifo_a_.clear();
  fifo_b_.clear();
  // ... more APU reset ...

  // Reset Timers
  for (auto& t : timers_) {
    t.reload = 0;
    t.control = 0;
    t.counter = 0;
    t.prescaler_accum = 0;
  }

  // Reset DMA
  for (auto& d : dma_shadows_) {
    d.active = false;
    d.pending = false;
  }

  frame_count_ = 0;
  executed_cycles_ = 0;
  swi_intrwait_active_ = false;

  ResetBackupControllerState();
  RebuildGamePakWaitstateTables(0); // Default waitstates
}

void GBACore::ResetBackupControllerState() {
  flash_mode_unlocked_ = false;
  flash_command_ = 0;
  flash_id_mode_ = false;
  flash_program_mode_ = false;
  flash_bank_switch_mode_ = false;
  flash_bank_ = 0;
  eeprom_cmd_bits_.clear();
  eeprom_read_bits_.clear();
  eeprom_read_pos_ = 0;
}

} // namespace gba
