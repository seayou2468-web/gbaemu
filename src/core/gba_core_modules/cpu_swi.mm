#include "../gba_core.h"

namespace gba {

void GBACore::EnterException(uint32_t vector_addr, uint32_t new_mode, bool disable_irq, bool thumb_state) {
  debug_last_exception_vector_ = vector_addr;
  debug_last_exception_pc_ = cpu_.regs[15];
  debug_last_exception_cpsr_ = cpu_.cpsr;

  const uint32_t return_addr = cpu_.regs[15] + (thumb_state ? 2u : 4u);
  const uint32_t prev_cpsr = cpu_.cpsr;

  SwitchCpuMode(new_mode);
  if (HasSpsr(new_mode)) {
    cpu_.spsr[new_mode & 0x1Fu] = prev_cpsr;
  }
  cpu_.regs[14] = return_addr;

  if (disable_irq) cpu_.cpsr |= (1u << 7);
  cpu_.cpsr &= ~(1u << 5);  // ARM state
  cpu_.regs[15] = vector_addr;
  cpu_.halted = false;
}

bool GBACore::HandleSoftwareInterrupt(uint32_t swi_imm, bool thumb_state) {
  switch (swi_imm & 0xFFu) {
    case mgba_compat::kSwiGetBiosChecksum:
      cpu_.regs[0] = mgba_compat::kBiosChecksum;
      break;
    case mgba_compat::kSwiDiv:
    case mgba_compat::kSwiDivArm: {
      const int32_t num = static_cast<int32_t>(cpu_.regs[0]);
      const int32_t den = static_cast<int32_t>(cpu_.regs[1]);
      if (den == 0) {
        cpu_.regs[0] = 0;
        cpu_.regs[1] = static_cast<uint32_t>(num);
        cpu_.regs[3] = 0;
      } else {
        cpu_.regs[0] = static_cast<uint32_t>(num / den);
        cpu_.regs[1] = static_cast<uint32_t>(num % den);
        cpu_.regs[3] = static_cast<uint32_t>(num < 0 ? -num : num);
      }
      break;
    }
    case mgba_compat::kSwiSqrt: {
      uint32_t x = cpu_.regs[0];
      uint32_t r = 0;
      uint32_t bit = 1u << 30;
      while (bit > x) bit >>= 2;
      while (bit) {
        if (x >= r + bit) {
          x -= r + bit;
          r = (r >> 1) + bit;
        } else {
          r >>= 1;
        }
        bit >>= 2;
      }
      cpu_.regs[0] = r;
      break;
    }
    default:
      break;
  }
  EnterException(0x08u, 0x13u, true, thumb_state);
  return true;
}

void GBACore::HandleUndefinedInstruction(bool thumb_state) {
  EnterException(0x04u, 0x1Bu, true, thumb_state);
}

void GBACore::HandleCpuSet(bool fast_mode) {
  const uint32_t src = cpu_.regs[0];
  const uint32_t dst = cpu_.regs[1];
  const uint32_t control = cpu_.regs[2];
  const bool fill = (control & (1u << 24)) != 0;
  uint32_t words = control & 0x1FFFFFu;
  const uint32_t step = fast_mode ? 4u : 2u;
  if (words == 0) return;

  if (fill) {
    const uint32_t v = fast_mode ? Read32(src) : Read16(src);
    for (uint32_t i = 0; i < words; ++i) {
      if (fast_mode) Write32(dst + i * step, v);
      else Write16(dst + i * step, static_cast<uint16_t>(v));
    }
  } else {
    for (uint32_t i = 0; i < words; ++i) {
      if (fast_mode) Write32(dst + i * step, Read32(src + i * step));
      else Write16(dst + i * step, Read16(src + i * step));
    }
  }
}

}  // namespace gba
