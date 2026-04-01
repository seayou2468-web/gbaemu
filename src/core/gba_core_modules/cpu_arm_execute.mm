#include "../gba_core.h"

#include <limits>

namespace gba {

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
  // Match only when SH!=00 so MUL/MLA, long-mul, and SWP encodings are excluded.
  if ((opcode & 0x0E000090u) == 0x00000090u && (opcode & 0x00000060u) != 0u) {
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
        HandleUndefinedInstruction(false);
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
      const bool z = (result == 0);
      const bool n = (cpu_.regs[rd_hi] & 0x80000000u) != 0;
      cpu_.cpsr = (cpu_.cpsr & ~((1u << 31) | (1u << 30))) |
                  (n ? (1u << 31) : 0u) |
                  (z ? (1u << 30) : 0u);
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
      const uint32_t raw = Read32(aligned);
      const uint32_t rot = (addr & 3u) * 8u;
      const uint32_t old = (rot == 0) ? raw : RotateRight(raw, rot);
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
      if (shift_imm == 0 && shift_type != 0) {
        if (shift_type == 3) { // RRX
          const bool old_c = GetFlagC();
          offset = (old_c ? 0x80000000u : 0u) | (cpu_.regs[rm] >> 1);
        } else { // LSR 32 / ASR 32
          offset = ApplyShift(cpu_.regs[rm], shift_type, 32, &ignored_carry);
        }
      } else {
        offset = ApplyShift(cpu_.regs[rm], shift_type, shift_imm, &ignored_carry);
      }
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
    if (load && rd == 15u) {
      cpu_.regs[15] &= ~3u;
      return;
    }
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
      if (reg_shift) {
        if (shift_amount == 0) {
          operand2 = arm_shift_operand_value(rm, true);
        } else {
          operand2 = ApplyShift(arm_shift_operand_value(rm, true), shift_type, shift_amount, &shifter_carry);
        }
      } else { // Immediate shift
        if (shift_amount == 0 && shift_type != 0) {
          if (shift_type == 3) { // RRX
            const bool old_c = GetFlagC();
            const uint32_t val = arm_shift_operand_value(rm, false);
            shifter_carry = (val & 1u) != 0;
            operand2 = (old_c ? 0x80000000u : 0u) | (val >> 1);
          } else { // LSR 32 / ASR 32
            operand2 = ApplyShift(arm_shift_operand_value(rm, false), shift_type, 32, &shifter_carry);
          }
        } else {
          operand2 = ApplyShift(arm_shift_operand_value(rm, false), shift_type, shift_amount, &shifter_carry);
        }
      }
    }

    auto set_logic_flags = [&](uint32_t value) {
      SetNZFlags(value);
      SetFlagC(shifter_carry);
    };
    auto do_add = [&](uint32_t lhs, uint32_t rhs, uint32_t carry_in, uint32_t* out) {
      const uint64_t r64 = static_cast<uint64_t>(lhs) + static_cast<uint64_t>(rhs) + carry_in;
      *out = static_cast<uint32_t>(r64);
      if (set_flags) {
        SetNZFlags(*out);
        const bool carry = (r64 >> 32) != 0;
        const int64_t sres = static_cast<int64_t>(static_cast<int32_t>(lhs)) +
                             static_cast<int64_t>(static_cast<int32_t>(rhs)) +
                             static_cast<int64_t>(carry_in);
        const bool overflow =
            (sres > static_cast<int64_t>(std::numeric_limits<int32_t>::max())) ||
            (sres < static_cast<int64_t>(std::numeric_limits<int32_t>::min()));
        cpu_.cpsr = (cpu_.cpsr & ~((1u << 29) | (1u << 28))) |
                    (carry ? (1u << 29) : 0u) |
                    (overflow ? (1u << 28) : 0u);
      }
    };
    auto do_sub = [&](uint32_t lhs, uint32_t rhs, uint32_t borrow, uint32_t* out) {
      const uint64_t r64 = static_cast<uint64_t>(lhs) - static_cast<uint64_t>(rhs) - borrow;
      *out = static_cast<uint32_t>(r64);
      if (set_flags) {
        SetNZFlags(*out);
        const uint64_t subtrahend = static_cast<uint64_t>(rhs) + static_cast<uint64_t>(borrow);
        const bool carry = static_cast<uint64_t>(lhs) >= subtrahend;  // no borrow
        const int64_t sres = static_cast<int64_t>(static_cast<int32_t>(lhs)) -
                             static_cast<int64_t>(static_cast<int32_t>(rhs)) -
                             static_cast<int64_t>(borrow);
        const bool overflow =
            (sres > static_cast<int64_t>(std::numeric_limits<int32_t>::max())) ||
            (sres < static_cast<int64_t>(std::numeric_limits<int32_t>::min()));
        cpu_.cpsr = (cpu_.cpsr & ~((1u << 29) | (1u << 28))) |
                    (carry ? (1u << 29) : 0u) |
                    (overflow ? (1u << 28) : 0u);
      }
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
        const uint32_t rn_val = arm_reg_value(rn);
        uint32_t r = 0;
        do_sub(rn_val, operand2, 0u, &r);
        cpu_.regs[rd] = r;
        break;
      }
      case 0x3: { // RSB
        const uint32_t rn_val = arm_reg_value(rn);
        uint32_t r = 0;
        do_sub(operand2, rn_val, 0u, &r);
        cpu_.regs[rd] = r;
        break;
      }
      case 0x4: { // ADD
        const uint32_t rn_val = arm_reg_value(rn);
        uint32_t r = 0;
        do_add(rn_val, operand2, 0u, &r);
        cpu_.regs[rd] = r;
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
        const uint32_t rn_val = arm_reg_value(rn);
        const uint64_t r64 = static_cast<uint64_t>(rn_val) - static_cast<uint64_t>(operand2);
        SetSubFlags(rn_val, operand2, r64);
        break;
      }
      case 0xB: { // CMN
        writes_result = false;
        const uint32_t rn_val = arm_reg_value(rn);
        const uint64_t r64 = static_cast<uint64_t>(rn_val) + static_cast<uint64_t>(operand2);
        SetAddFlags(rn_val, operand2, r64);
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
        HandleUndefinedInstruction(false);
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

  HandleUndefinedInstruction(false);
  return;
}

}  // namespace gba
