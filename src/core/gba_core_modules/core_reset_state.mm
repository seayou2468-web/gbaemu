// core_reset_state.mm
// GBA core hardware reset – initialises CPU, PPU scanline buffers, and all state.

#include "../gba_core.h"

#include <algorithm>
#include <cstring>

namespace gba {

uint32_t GBACore::NormalizeSpLrBankMode(uint32_t mode) {
  switch (mode & 0x1Fu) {
    case 0x10: case 0x11: case 0x12: case 0x13:
    case 0x17: case 0x1B: case 0x1F:
      return mode & 0x1Fu;
    default:
      return 0x1Fu;
  }
}

void GBACore::Reset() {
  // ── Memory ────────────────────────────────────────────────────────────────
  std::fill(ewram_.begin(),       ewram_.end(),       0);
  std::fill(iwram_.begin(),       iwram_.end(),       0);
  std::fill(io_regs_.begin(),     io_regs_.end(),     0);
  std::fill(palette_ram_.begin(), palette_ram_.end(), 0);
  std::fill(vram_.begin(),        vram_.end(),        0);
  std::fill(oam_.begin(),         oam_.end(),         0);

  // ── CPU ───────────────────────────────────────────────────────────────────
  cpu_ = CpuState{};
  cpu_.active_mode = 0x1Fu;
  cpu_.cpsr        = 0x1Fu;
  cpu_.regs.fill(0);
  cpu_.banked_sp.fill(0);
  cpu_.banked_lr.fill(0);
  cpu_.spsr.fill(0);

  if (bios_loaded_ && bios_boot_via_vector_) {
    cpu_.regs[15] = 0x00000000u;
  } else {
    cpu_.regs[15] = 0x08000000u;
  }
  cpu_.regs[13] = 0x03007F00u;  // SP_usr initial value

  // ── PPU ───────────────────────────────────────────────────────────────────
  ppu_cycle_accum_ = 0;

  // Size the frame buffer; fill with black
  frame_buffer_.assign(kScreenWidth * kScreenHeight, 0xFF000000u);

  // Clear scanline pixel buffers (0x8000 = transparent sentinel)
  for (int b = 0; b < 4; ++b) ppu_bg_[b].fill(0x8000u);
  ppu_obj_.fill(0x8000u);
  ppu_obj_attr_.fill(0);
  ppu_objwin_.fill(false);
  ppu_win_mask_.fill(0x3Fu);

  // Affine reference points: latch from registers (all zero at reset)
  ppu_bg2_refx_    = 0;
  ppu_bg2_refy_    = 0;
  ppu_bg3_refx_    = 0;
  ppu_bg3_refy_    = 0;
  ppu_affine_latched_ = false;

  // Legacy affine internals (used by timing_dma.mm)
  bg2_refx_internal_ = 0;
  bg2_refy_internal_ = 0;
  bg3_refx_internal_ = 0;
  bg3_refy_internal_ = 0;

  frame_rendered_in_vblank_ = false;
  frame_count_              = 0;

  // ── Misc ──────────────────────────────────────────────────────────────────
  executed_cycles_  = 0;
  waitstates_accum_ = 0;
  last_access_valid_ = false;
  last_access_addr_  = 0;
  last_access_size_  = 0;
  open_bus_latch_    = 0;
  bios_fetch_latch_  = 0;
  bios_data_latch_   = 0;
  gamepak_prefetch_credit_ = 0;
  pipeline_refill_pending_ = 0;
  RebuildGamePakWaitstateTables(0);

  debug_last_exception_vector_ = 0;
  debug_last_exception_pc_     = 0;
  debug_last_exception_cpsr_   = cpu_.cpsr;

  SyncKeyInputRegister();
}

void GBACore::HandleRegisterRamReset(uint8_t flags) {
  if (flags & 0x01u) std::fill(ewram_.begin(),       ewram_.end(),       0);
  if (flags & 0x02u) std::fill(iwram_.begin(),        iwram_.end(),       0);
  if (flags & 0x04u) std::fill(palette_ram_.begin(),  palette_ram_.end(), 0);
  if (flags & 0x08u) std::fill(vram_.begin(),         vram_.end(),        0);
  if (flags & 0x10u) std::fill(oam_.begin(),          oam_.end(),         0);
}



}  // namespace gba