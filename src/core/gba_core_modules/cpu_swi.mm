#include "../gba_core.h"
#include <algorithm>
#include <cstring>

namespace gba {

bool GBACore::HandleSoftwareInterrupt(uint32_t swi_imm, bool thumb_state) {
  uint32_t swi_num = thumb_state ? swi_imm : (swi_imm & 0xFF);

  switch (swi_num) {
    case 0x00: Reset(); break;
    case 0x01: HandleRegisterRamReset(cpu_.regs[0]); break;
    case 0x02: cpu_.halted = true; break;
    case 0x03: cpu_.halted = true; break;
    case 0x04: swi_intrwait_active_ = true; swi_intrwait_mask_ = cpu_.regs[1]; cpu_.halted = true; break;
    case 0x05: swi_intrwait_active_ = true; swi_intrwait_mask_ = 1; cpu_.halted = true; break;
    case 0x0B: HandleCpuSet(false); break;
    case 0x0C: HandleCpuSet(true); break;
    default: EnterException(0x00000008, 0x13, true, false); break;
  }
  return true;
}

void GBACore::EnterException(uint32_t vector_addr, uint32_t new_mode, bool disable_irq, bool thumb_state) {
  uint32_t current_pc = cpu_.regs[15];
  uint32_t current_cpsr = cpu_.cpsr;
  SwitchCpuMode(new_mode);
  cpu_.spsr[NormalizeSpLrBankMode(new_mode)] = current_cpsr;
  cpu_.regs[14] = current_pc;
  if (disable_irq) cpu_.cpsr |= (1 << 7);
  if (thumb_state) cpu_.cpsr |= (1 << 5); else cpu_.cpsr &= ~(1 << 5);
  cpu_.regs[15] = vector_addr;
}

void GBACore::HandleRegisterRamReset(uint8_t flags) {
  if (flags & 0x01) ewram_.fill(0);
  if (flags & 0x02) iwram_.fill(0);
  if (flags & 0x04) palette_ram_.fill(0);
  if (flags & 0x08) vram_.fill(0);
  if (flags & 0x10) oam_.fill(0);
}

void GBACore::HandleCpuSet(bool fast_mode) {
  uint32_t src = cpu_.regs[0];
  uint32_t dst = cpu_.regs[1];
  uint32_t count = cpu_.regs[2] & 0x1FFFFF;
  bool fill = (cpu_.regs[2] >> 24) & 1;
  uint32_t unit = fast_mode ? 4 : 2;
  for (uint32_t i = 0; i < count; ++i) {
    if (fast_mode) { uint32_t val = Read32(src); Write32(dst, val); if (!fill) src += 4; }
    else { uint16_t val = Read16(src); Write16(dst, val); if (!fill) src += 2; }
    dst += unit;
  }
}

} // namespace gba
