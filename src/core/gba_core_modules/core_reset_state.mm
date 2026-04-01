#include "../gba_core.h"

#include <algorithm>
#include <cstring>

namespace gba {

uint32_t GBACore::NormalizeSpLrBankMode(uint32_t mode) {
  switch (mode & 0x1Fu) {
    case 0x10: case 0x11: case 0x12: case 0x13: case 0x17: case 0x1B: case 0x1F:
      return mode & 0x1Fu;
    default:
      return 0x1Fu;
  }
}

void GBACore::Reset() {
  std::fill(ewram_.begin(), ewram_.end(), 0);
  std::fill(iwram_.begin(), iwram_.end(), 0);
  std::fill(io_regs_.begin(), io_regs_.end(), 0);
  std::fill(palette_ram_.begin(), palette_ram_.end(), 0);
  std::fill(vram_.begin(), vram_.end(), 0);
  std::fill(oam_.begin(), oam_.end(), 0);

  cpu_ = CpuState{};
  cpu_.active_mode = 0x1Fu;
  cpu_.cpsr = 0x1Fu;
  cpu_.regs.fill(0);
  cpu_.banked_sp.fill(0);
  cpu_.banked_lr.fill(0);
  cpu_.spsr.fill(0);

  if (bios_loaded_ && bios_boot_via_vector_) {
    cpu_.regs[15] = 0x00000000u;
    cpu_.regs[13] = 0x03007F00u;
  } else {
    cpu_.regs[15] = 0x08000000u;
    cpu_.regs[13] = 0x03007F00u;
  }

  ppu_cycle_accum_ = 0;
  apu_frame_seq_cycles_ = 0;
  frame_count_ = 0;
  executed_cycles_ = 0;
  debug_last_exception_vector_ = 0;
  debug_last_exception_pc_ = 0;
  debug_last_exception_cpsr_ = cpu_.cpsr;

  SyncKeyInputRegister();
}

void GBACore::HandleRegisterRamReset(uint8_t flags) {
  if (flags & 0x01u) std::fill(ewram_.begin(), ewram_.end(), 0);
  if (flags & 0x02u) std::fill(iwram_.begin(), iwram_.end(), 0);
  if (flags & 0x04u) std::fill(palette_ram_.begin(), palette_ram_.end(), 0);
  if (flags & 0x08u) std::fill(vram_.begin(), vram_.end(), 0);
  if (flags & 0x10u) std::fill(oam_.begin(), oam_.end(), 0);
}

}  // namespace gba
