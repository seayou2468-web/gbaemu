#include "../gba_core.h"
#include <algorithm>
#include <cstring>
#include <vector>

namespace gba {

bool GBACore::HandleSoftwareInterrupt(uint32_t swi_imm, bool thumb_state) {
  // GBA BIOS SWI functions
  uint32_t swi_num = thumb_state ? swi_imm : (swi_imm & 0xFF);

  switch (swi_num) {
    case 0x00: // SoftReset
      Reset();
      return true;
    case 0x01: // RegisterRamReset
      HandleRegisterRamReset(cpu_.regs[0]);
      return true;
    case 0x02: // Halt
      cpu_.halted = true;
      return true;
    case 0x03: // Stop
      cpu_.halted = true;
      return true;
    case 0x04: // IntrWait
      swi_intrwait_active_ = true;
      swi_intrwait_mask_ = cpu_.regs[1];
      cpu_.halted = true;
      return true;
    case 0x05: // VBlankIntrWait
      swi_intrwait_active_ = true;
      swi_intrwait_mask_ = 1; // VBlank mask
      cpu_.halted = true;
      return true;
    case 0x0B: // CpuSet
      HandleCpuSet(false);
      return true;
    case 0x0C: // CpuFastSet
      HandleCpuSet(true);
      return true;
    // ... many more SWI functions like ArcTan, Sqrt, etc. ...
    default:
      // Enter SWI exception vector (0x00000008)
      EnterException(0x00000008, 0x13, true, false); // Supervisor mode, Disable IRQ, ARM state
      return true;
  }
}

void GBACore::EnterException(uint32_t vector_addr, uint32_t new_mode, bool disable_irq, bool thumb_state) {
  uint32_t current_pc = cpu_.regs[15];
  uint32_t current_cpsr = cpu_.cpsr;

  SwitchCpuMode(new_mode);
  cpu_.spsr[new_mode] = current_cpsr;
  cpu_.regs[14] = current_pc; // LR = PC (or PC-4, depending on the exception type)

  if (disable_irq) cpu_.cpsr |= (1 << 7); // Set I-flag

  if (thumb_state) cpu_.cpsr |= (1 << 5); // Thumb state
  else cpu_.cpsr &= ~(1 << 5); // ARM state

  cpu_.regs[15] = vector_addr;
}

void GBACore::HandleRegisterRamReset(uint8_t flags) {
  if (flags & 0x01) ewram_.fill(0);
  if (flags & 0x02) iwram_.fill(0);
  if (flags & 0x04) palette_ram_.fill(0);
  if (flags & 0x08) vram_.fill(0);
  if (flags & 0x10) oam_.fill(0);
  if (flags & 0x80) Reset(); // Reset CPU regs, but flag is technically for all IO regs
}

void GBACore::HandleCpuSet(bool fast_mode) {
  uint32_t src = cpu_.regs[0];
  uint32_t dst = cpu_.regs[1];
  uint32_t count = cpu_.regs[2] & 0x1FFFFF;
  bool fill = (cpu_.regs[2] >> 24) & 1;

  if (fast_mode) {
    // 32-bit transfer/fill
    for (uint32_t i = 0; i < count; ++i) {
      if (fill) Write32(dst, Read32(src));
      else {
        Write32(dst, Read32(src));
        src += 4;
      }
      dst += 4;
    }
  } else {
    // 16-bit transfer/fill
    for (uint32_t i = 0; i < count; ++i) {
      if (fill) Write16(dst, Read16(src));
      else {
        Write16(dst, Read16(src));
        src += 2;
      }
      dst += 2;
    }
  }
}

} // namespace gba
