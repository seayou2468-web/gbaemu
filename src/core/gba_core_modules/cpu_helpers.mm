#ifndef GBA_CORE_CPU_HELPERS_IMPL
#define GBA_CORE_CPU_HELPERS_IMPL

// ---- BEGIN gba_core_cpu.cpp ----
#include "../gba_core.h"

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
    default: return true;              // mGBA ARMTestCondition behavior
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

void GBACore::HandleUndefinedInstruction(bool thumb_state) {
  if (bios_boot_via_vector_) {
    EnterException(0x00000004u, 0x1Bu, true, false);
    return;
  }
  cpu_.regs[15] += thumb_state ? 2u : 4u;
}

}  // namespace gba

#endif  // GBA_CORE_CPU_HELPERS_IMPL
