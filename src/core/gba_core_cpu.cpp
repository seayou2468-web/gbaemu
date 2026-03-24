#include "gba_core.h"

#include <algorithm>
#include <bit>

namespace gba {
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
        writes_result = false;
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

  // Unknown ARM instruction -> undefined exception.
  EnterException(0x00000004u, 0x1Bu, true, false);
}

void GBACore::ExecuteThumbInstruction(uint16_t opcode) {
  // Shift by immediate (LSL/LSR/ASR)
  if ((opcode & 0xE000u) == 0x0000u) {
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
      case 0x3: cpu_.regs[rd] = static_cast<uint32_t>(static_cast<int16_t>(Read16(addr & ~1u))); break; // LDSH
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
      for (int i = 7; i >= 0; --i) {
        if (reg_list & (1u << i)) {
          cpu_.regs[13] -= 4u;
          Write32(cpu_.regs[13], cpu_.regs[i]);
        }
      }
      if (r) {
        cpu_.regs[13] -= 4u;
        Write32(cpu_.regs[13], cpu_.regs[14]);
      }
    } else {      // POP
      for (int i = 0; i < 8; ++i) {
        if (reg_list & (1u << i)) {
          cpu_.regs[i] = Read32(cpu_.regs[13]);
          cpu_.regs[13] += 4u;
        }
      }
      if (r) {
        cpu_.regs[15] = Read32(cpu_.regs[13]) & ~1u;
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

  // Unknown Thumb instruction -> undefined exception.
  EnterException(0x00000004u, 0x1Bu, true, false);
}

void GBACore::RunCpuSlice(uint32_t cycles) {
  if (cpu_.halted) return;
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
    // Keep PC sane when branch jumps outside mapped ranges.
    if (cpu_.regs[15] < 0x02000000u || cpu_.regs[15] > 0x09FFFFFFu) {
      const uint32_t mask = (cpu_.cpsr & (1u << 5)) ? 0x1FFFFFEu : 0x1FFFFFCu;
      cpu_.regs[15] = 0x08000000u + static_cast<uint32_t>((cpu_.regs[15] & mask) % std::max<size_t>(4, rom_.size()));
    }
  }
}

}  // namespace gba
