#include "../gba_core.h"

namespace gba {

namespace {
inline uint32_t ArmRegIndex(uint32_t op, uint32_t shift) { return (op >> shift) & 0xFu; }
inline uint32_t ArmReadBasicOperandReg(const std::array<uint32_t, 16>& regs, uint32_t r) {
  return (r == 15u) ? (regs[15] + 8u) : regs[r];
}
inline uint32_t ArmApplyRegisterShift(uint32_t value, uint32_t type, uint32_t amount, bool carry_in, bool* carry_out) {
  if ((amount & 0xFFu) == 0) {
    if (carry_out) *carry_out = carry_in;
    return value;
  }
  switch (type & 3u) {
    case 0:  // LSL
      if (amount < 32) {
        if (carry_out) *carry_out = ((value >> (32 - amount)) & 1u) != 0;
        return value << amount;
      }
      if (amount == 32) {
        if (carry_out) *carry_out = (value & 1u) != 0;
        return 0;
      }
      if (carry_out) *carry_out = false;
      return 0;
    case 1:  // LSR
      if (amount < 32) {
        if (carry_out) *carry_out = ((value >> (amount - 1)) & 1u) != 0;
        return value >> amount;
      }
      if (amount == 32) {
        if (carry_out) *carry_out = ((value >> 31) & 1u) != 0;
        return 0;
      }
      if (carry_out) *carry_out = false;
      return 0;
    case 2:  // ASR
      if (amount < 32) {
        if (carry_out) *carry_out = ((value >> (amount - 1)) & 1u) != 0;
        return static_cast<uint32_t>(static_cast<int32_t>(value) >> amount);
      }
      if (carry_out) *carry_out = ((value >> 31) & 1u) != 0;
      return (value & 0x80000000u) ? 0xFFFFFFFFu : 0u;
    default: {  // ROR
      const uint32_t rot = amount & 31u;
      if (rot == 0) {
        if (carry_out) *carry_out = ((value >> 31) & 1u) != 0;
        return value;
      }
      if (carry_out) *carry_out = ((value >> (rot - 1)) & 1u) != 0;
      return (value >> rot) | (value << (32u - rot));
    }
  }
}
inline uint32_t ArmPsrWriteMask(uint32_t opcode) {
  // ARM7TDMI (ARMv4T) supports only control and flags fields in MSR.
  // x/s field masks are ARMv5+ and should be ignored on GBA.
  uint32_t mask = 0;
  if (opcode & (1u << 16)) mask |= 0x000000FFu;  // c
  if (opcode & (1u << 19)) mask |= 0xFF000000u;  // f
  return mask;
}
}

uint32_t GBACore::EstimateArmCycles(uint32_t opcode) const {
  // ARM7TDMI近似: 基本1S + 命令種別ごとのI/N/Sを加算して概算する。
  if ((opcode & 0x0F000000u) == 0x0F000000u) return 3;  // SWI
  if ((opcode & 0x0FFFFFF0u) == 0x012FFF10u) return 3;  // BX
  if ((opcode & 0x0E000000u) == 0x0A000000u) return 3;  // B/BL
  if ((opcode & 0x0E000000u) == 0x08000000u) {          // LDM/STM
    const uint32_t rlist = opcode & 0xFFFFu;
    const uint32_t count = rlist ? static_cast<uint32_t>(__builtin_popcount(rlist)) : 1u;
    return 1u + count;
  }
  if ((opcode & 0x0C000000u) == 0x04000000u) return 3;  // LDR/STR
  if ((opcode & 0x0E000090u) == 0x00000090u && (opcode & 0x0F000000u) != 0x0F000000u) return 3;  // mode3
  if ((opcode & 0x0FC000F0u) == 0x00000090u) {          // MUL/MLA
    return (opcode & (1u << 21)) ? 3u : 2u;
  }
  if ((opcode & 0x0F8000F0u) == 0x00800090u) return 4;  // MULL/MLAL
  if ((opcode & 0x0FB00FF0u) == 0x01000090u) return 4;  // SWP/SWPB
  if ((opcode & 0x0C000000u) == 0x00000000u && (opcode & (1u << 4)) && !(opcode & (1u << 25))) {
    return 2;  // データ処理 + レジスタ指定シフトは1Iを追加
  }
  return 1;
}

void GBACore::ExecuteArmInstruction(uint32_t opcode) {
  const uint32_t cond = opcode >> 28;
  if (cond == 0xFu) {
    HandleUndefinedInstruction(false);
    return;
  }
  if (!CheckCondition(cond)) {
    cpu_.regs[15] += 4;
    return;
  }

  if ((opcode & 0x0F000000u) == 0x0F000000u) {
    HandleSoftwareInterrupt(opcode & 0xFFFFFFu, false);
    return;
  }

  // B/BL
  if ((opcode & 0x0E000000u) == 0x0A000000u) {
    int32_t off = static_cast<int32_t>((opcode & 0x00FFFFFFu) << 8) >> 6;
    const uint32_t next = cpu_.regs[15] + 4;
    if (opcode & (1u << 24)) {
      cpu_.regs[14] = next;
    }
    cpu_.regs[15] = next + static_cast<uint32_t>(off);
    return;
  }

  // BX
  if ((opcode & 0x0FFFFFF0u) == 0x012FFF10u) {
    const uint32_t rm = opcode & 0xFu;
    const uint32_t target = (rm == 15) ? (cpu_.regs[15] + 8u) : cpu_.regs[rm];
    if (target & 1u) {
      cpu_.cpsr |= (1u << 5);
      cpu_.regs[15] = target & ~1u;
    } else {
      cpu_.cpsr &= ~(1u << 5);
      cpu_.regs[15] = target & ~3u;
    }
    return;
  }

  // MUL/MLA
  if ((opcode & 0x0FC000F0u) == 0x00000090u) {
    const bool accumulate = (opcode & (1u << 21)) != 0;
    const bool set_flags = (opcode & (1u << 20)) != 0;
    const uint32_t rd = ArmRegIndex(opcode, 16);
    const uint32_t rn = ArmRegIndex(opcode, 12);
    const uint32_t rs = ArmRegIndex(opcode, 8);
    const uint32_t rm = ArmRegIndex(opcode, 0);
    if (rd != 15u) {
      uint32_t result = ArmReadBasicOperandReg(cpu_.regs, rm) * ArmReadBasicOperandReg(cpu_.regs, rs);
      if (accumulate) result += ArmReadBasicOperandReg(cpu_.regs, rn);
      cpu_.regs[rd] = result;
      if (set_flags) SetNZFlags(result);
    }
    cpu_.regs[15] += 4;
    return;
  }

  // UMULL/UMLAL/SMULL/SMLAL
  if ((opcode & 0x0F8000F0u) == 0x00800090u) {
    const bool signed_mul = (opcode & (1u << 22)) != 0;
    const bool accumulate = (opcode & (1u << 21)) != 0;
    const bool set_flags = (opcode & (1u << 20)) != 0;
    const uint32_t rd_hi = ArmRegIndex(opcode, 16);
    const uint32_t rd_lo = ArmRegIndex(opcode, 12);
    const uint32_t rs = ArmRegIndex(opcode, 8);
    const uint32_t rm = ArmRegIndex(opcode, 0);
    if (rd_hi != 15u && rd_lo != 15u) {
      uint64_t product = 0;
      if (signed_mul) {
        product = static_cast<uint64_t>(static_cast<int64_t>(static_cast<int32_t>(ArmReadBasicOperandReg(cpu_.regs, rm))) *
                                        static_cast<int64_t>(static_cast<int32_t>(ArmReadBasicOperandReg(cpu_.regs, rs))));
      } else {
        product = static_cast<uint64_t>(ArmReadBasicOperandReg(cpu_.regs, rm)) * static_cast<uint64_t>(ArmReadBasicOperandReg(cpu_.regs, rs));
      }
      if (accumulate) {
        const uint64_t old = (static_cast<uint64_t>(cpu_.regs[rd_hi]) << 32) | cpu_.regs[rd_lo];
        product += old;
      }
      cpu_.regs[rd_lo] = static_cast<uint32_t>(product);
      cpu_.regs[rd_hi] = static_cast<uint32_t>(product >> 32);
      if (set_flags) {
        cpu_.cpsr = (cpu_.cpsr & ~((1u << 31) | (1u << 30))) |
                    (cpu_.regs[rd_hi] & 0x80000000u) |
                    (((cpu_.regs[rd_hi] | cpu_.regs[rd_lo]) == 0) ? (1u << 30) : 0u);
      }
    }
    cpu_.regs[15] += 4;
    return;
  }

  // SWP/SWPB
  if ((opcode & 0x0FB00FF0u) == 0x01000090u) {
    const bool byte = (opcode & (1u << 22)) != 0;
    const uint32_t rn = ArmRegIndex(opcode, 16);
    const uint32_t rd = ArmRegIndex(opcode, 12);
    const uint32_t rm = ArmRegIndex(opcode, 0);
    const uint32_t addr = (rn == 15) ? (cpu_.regs[15] + 8u) : cpu_.regs[rn];
    const uint32_t store_value = (rm == 15) ? (cpu_.regs[15] + 12u) : cpu_.regs[rm];
    if (byte) {
      const uint8_t old = Read8(addr);
      Write8(addr, static_cast<uint8_t>(store_value));
      cpu_.regs[rd] = old;
    } else {
      const uint32_t old = Read32(addr);
      Write32(addr, store_value);
      cpu_.regs[rd] = old;
    }
    if (rd == 15) {
      cpu_.regs[15] &= ~3u;
      return;
    }
    cpu_.regs[15] += 4;
    return;
  }

  // MRS / MSR (最低限)
  if ((opcode & 0x0FBF0FFFu) == 0x010F0000u) {  // MRS Rd, CPSR/SPSR
    const bool spsr = (opcode & (1u << 22)) != 0;
    if (spsr && !HasSpsr(GetCpuMode())) {
      HandleUndefinedInstruction(false);
      return;
    }
    const uint32_t rd = ArmRegIndex(opcode, 12);
    if (rd == 15u) {
      // ARMv4T: MRS with Rd=PC is UNPREDICTABLE. Suppress side effects safely.
      cpu_.regs[15] += 4;
      return;
    }
    cpu_.regs[rd] = spsr ? cpu_.spsr[GetCpuMode() & 0x1Fu] : cpu_.cpsr;
    cpu_.regs[15] += 4;
    return;
  }
  if ((opcode & 0x0DB0F000u) == 0x0120F000u) {  // MSR CPSR/SPSR_flg, Rm
    const bool spsr = (opcode & (1u << 22)) != 0;
    if (spsr && !HasSpsr(GetCpuMode())) {
      HandleUndefinedInstruction(false);
      return;
    }
    const uint32_t rm = opcode & 0xFu;
    const uint32_t rm_value = (rm == 15) ? (cpu_.regs[15] + 12u) : cpu_.regs[rm];
    uint32_t mask = ArmPsrWriteMask(opcode);
    if (!IsPrivilegedMode(GetCpuMode())) mask &= 0xF0000000u;
    if (spsr) {
      auto& psr = cpu_.spsr[GetCpuMode() & 0x1Fu];
      psr = (psr & ~mask) | (rm_value & mask);
    } else {
      const uint32_t old_mode = GetCpuMode();
      cpu_.cpsr = (cpu_.cpsr & ~mask) | (rm_value & mask);
      if ((mask & 0x1Fu) && GetCpuMode() != old_mode) {
        SwitchCpuMode(GetCpuMode());
      }
    }
    cpu_.regs[15] += 4;
    return;
  }
  if ((opcode & 0x0DB0F000u) == 0x0320F000u) {  // MSR CPSR/SPSR_flg, #imm
    const bool spsr = (opcode & (1u << 22)) != 0;
    if (spsr && !HasSpsr(GetCpuMode())) {
      HandleUndefinedInstruction(false);
      return;
    }
    const uint32_t imm = ExpandArmImmediate(opcode & 0xFFFu);
    uint32_t mask = ArmPsrWriteMask(opcode);
    if (!IsPrivilegedMode(GetCpuMode())) mask &= 0xF0000000u;
    if (spsr) {
      auto& psr = cpu_.spsr[GetCpuMode() & 0x1Fu];
      psr = (psr & ~mask) | (imm & mask);
    } else {
      const uint32_t old_mode = GetCpuMode();
      cpu_.cpsr = (cpu_.cpsr & ~mask) | (imm & mask);
      if ((mask & 0x1Fu) && GetCpuMode() != old_mode) {
        SwitchCpuMode(GetCpuMode());
      }
    }
    cpu_.regs[15] += 4;
    return;
  }

  // LDRH/LDRSH/LDRSB/STRH (addr mode 3)
  if ((opcode & 0x0E000090u) == 0x00000090u && (opcode & 0x0F000000u) != 0x0F000000u) {
    const bool pre = (opcode & (1u << 24)) != 0;
    const bool up = (opcode & (1u << 23)) != 0;
    const bool imm = (opcode & (1u << 22)) != 0;
    const bool writeback = (opcode & (1u << 21)) != 0;
    const bool load = (opcode & (1u << 20)) != 0;
    const uint32_t rn = ArmRegIndex(opcode, 16);
    const uint32_t rd = ArmRegIndex(opcode, 12);
    const uint32_t op = (opcode >> 5) & 0x3u;  // 1=H, 2=SB, 3=SH
    uint32_t off = 0;
    if (imm) {
      off = ((opcode >> 4) & 0xF0u) | (opcode & 0xFu);
    } else {
      const uint32_t rm = opcode & 0xFu;
      off = (rm == 15) ? (cpu_.regs[15] + 8u) : cpu_.regs[rm];
    }
    uint32_t addr = (rn == 15) ? (cpu_.regs[15] + 8u) : cpu_.regs[rn];
    if (pre) addr = up ? (addr + off) : (addr - off);

    if (load) {
      if (op == 1) cpu_.regs[rd] = Read16(addr);
      else if (op == 2) cpu_.regs[rd] = static_cast<int32_t>(static_cast<int8_t>(Read8(addr)));
      else {
        // ARM7TDMI: odd address LDRSH behaves like signed byte load.
        cpu_.regs[rd] = (addr & 1u) ? static_cast<int32_t>(static_cast<int8_t>(Read8(addr)))
                                    : static_cast<int32_t>(static_cast<int16_t>(Read16(addr)));
      }
    } else if (op == 1) {
      const uint32_t store_value = (rd == 15) ? (cpu_.regs[15] + 12u) : cpu_.regs[rd];
      Write16(addr, static_cast<uint16_t>(store_value));
    }

    if (!pre) addr = up ? (addr + off) : (addr - off);
    if (rn != 15 && (writeback || !pre)) {
      // ARMv4T: load + writeback with Rd==Rn is UNPREDICTABLE.
      // Keep destination load result and suppress writeback on this hazard.
      if (!(load && rd == rn)) {
        cpu_.regs[rn] = addr;
      }
    }
    if (load && rd == 15) {
      cpu_.regs[15] &= ~3u;
      return;
    }
    cpu_.regs[15] += 4;
    return;
  }

  // LDR/STR (single data transfer, immediate/register offset)
  if ((opcode & 0x0C000000u) == 0x04000000u) {
    const bool is_imm = (opcode & (1u << 25)) == 0;
    const bool pre = (opcode & (1u << 24)) != 0;
    const bool up = (opcode & (1u << 23)) != 0;
    const bool byte = (opcode & (1u << 22)) != 0;
    const bool writeback = (opcode & (1u << 21)) != 0;
    const bool load = (opcode & (1u << 20)) != 0;
    const uint32_t rn = ArmRegIndex(opcode, 16);
    const uint32_t rd = ArmRegIndex(opcode, 12);

    uint32_t off = 0;
    if (is_imm) {
      off = opcode & 0xFFFu;
    } else {
      const uint32_t rm = opcode & 0xFu;
      const uint32_t shift = (opcode >> 5) & 0x3u;
      const bool shift_by_register = (opcode & (1u << 4)) != 0;
      uint32_t amount = 0;
      if (shift_by_register) {
        const uint32_t rs = (opcode >> 8) & 0xFu;
        amount = ((rs == 15 ? (cpu_.regs[15] + 8) : cpu_.regs[rs])) & 0xFFu;
      } else {
        amount = (opcode >> 7) & 0x1Fu;
      }
      const uint32_t rmv = (rm == 15) ? (cpu_.regs[15] + (shift_by_register ? 12u : 8u)) : cpu_.regs[rm];
      if (shift_by_register) off = ArmApplyRegisterShift(rmv, shift, amount, GetFlagC(), nullptr);
      else off = ApplyShift(rmv, shift, amount, nullptr);
    }

    uint32_t addr = (rn == 15) ? (cpu_.regs[15] + 8u) : cpu_.regs[rn];
    if (pre) {
      addr = up ? (addr + off) : (addr - off);
    }

    if (load) {
      uint32_t v = 0;
      if (byte) {
        v = Read8(addr);
      } else {
        v = (addr & 3u) ? RotateRight(Read32(addr & ~3u), (addr & 3u) * 8u) : Read32(addr);
      }
      cpu_.regs[rd] = v;
    } else {
      const uint32_t v = (rd == 15) ? (cpu_.regs[15] + 12u) : cpu_.regs[rd];
      if (byte) {
        Write8(addr, static_cast<uint8_t>(v));
      } else {
        Write32(addr, v);
      }
    }

    if (!pre) {
      addr = up ? (addr + off) : (addr - off);
    }
    if (rn != 15 && (writeback || !pre)) {
      // ARMv4T: load + writeback with Rd==Rn is UNPREDICTABLE.
      // Keep destination load result and suppress writeback on this hazard.
      if (!(load && rd == rn)) {
        cpu_.regs[rn] = addr;
      }
    }

    if (rd == 15 && load) {
      cpu_.regs[15] &= ~3u;
    } else {
      cpu_.regs[15] += 4;
    }
    return;
  }

  // LDM/STM
  if ((opcode & 0x0E000000u) == 0x08000000u) {
    const bool pre = (opcode & (1u << 24)) != 0;
    const bool up = (opcode & (1u << 23)) != 0;
    const bool s = (opcode & (1u << 22)) != 0;
    const bool writeback = (opcode & (1u << 21)) != 0;
    const bool load = (opcode & (1u << 20)) != 0;
    const uint32_t rn = ArmRegIndex(opcode, 16);
    uint32_t rlist = opcode & 0xFFFFu;
    uint32_t addr = (rn == 15) ? (cpu_.regs[15] + 8u) : cpu_.regs[rn];
    const uint32_t base_addr = addr;
    const uint32_t transfer_count = rlist ? static_cast<uint32_t>(__builtin_popcount(rlist)) : 1u;
    const uint32_t writeback_addr = up ? (base_addr + transfer_count * 4u) : (base_addr - transfer_count * 4u);
    const bool user_register_transfer = s && ((rlist & (1u << 15)) == 0);
    const bool in_fiq_mode = GetCpuMode() == 0x11u;
    if (rlist == 0) {
      // ARM7TDMI quirk: empty list transfers PC and applies +0x40 writeback.
      if (load) {
        cpu_.regs[15] = Read32(addr) & ~3u;
        if (rn != 15 && writeback) cpu_.regs[rn] = up ? (cpu_.regs[rn] + 0x40u) : (cpu_.regs[rn] - 0x40u);
        return;
      } else {
        Write32(addr, cpu_.regs[15] + 12u);
      }
      if (rn != 15 && writeback) cpu_.regs[rn] = up ? (cpu_.regs[rn] + 0x40u) : (cpu_.regs[rn] - 0x40u);
      cpu_.regs[15] += 4;
      return;
    }

    auto advance = [&](bool before) {
      if (before) addr = up ? (addr + 4) : (addr - 4);
    };
    auto finish = [&](bool after) {
      if (after) addr = up ? (addr + 4) : (addr - 4);
    };
    auto read_transfer_reg = [&](uint32_t r) -> uint32_t {
      if (!user_register_transfer) return cpu_.regs[r];
      if (r >= 8 && r <= 12) {
        return in_fiq_mode ? cpu_.banked_usr_r8_r12[r - 8] : cpu_.regs[r];
      }
      if (r == 13) return cpu_.banked_sp[0x1Fu];
      if (r == 14) return cpu_.banked_lr[0x1Fu];
      return cpu_.regs[r];
    };
    auto write_transfer_reg = [&](uint32_t r, uint32_t value) {
      if (!user_register_transfer) {
        cpu_.regs[r] = value;
        return;
      }
      if (r >= 8 && r <= 12) {
        if (in_fiq_mode) cpu_.banked_usr_r8_r12[r - 8] = value;
        else cpu_.regs[r] = value;
        return;
      }
      if (r == 13) cpu_.banked_sp[0x1Fu] = value;
      else if (r == 14) cpu_.banked_lr[0x1Fu] = value;
      else cpu_.regs[r] = value;
    };

    for (uint32_t r = 0; r < 16; ++r) {
      if ((rlist & (1u << r)) == 0) continue;
      advance(pre);
      if (load) {
        write_transfer_reg(r, Read32(addr));
      } else {
        uint32_t store_value = read_transfer_reg(r);
        if (writeback && r == rn && rn != 15) {
          const bool rn_is_first = (rlist & ((1u << r) - 1u)) == 0;
          if (!rn_is_first) store_value = writeback_addr;
        }
        if (r == 15) store_value = cpu_.regs[15] + 12u;
        Write32(addr, store_value);
      }
      finish(!pre);
    }

    if (rn != 15 && writeback) {
      // ARM7TDMI: STM writes back even when Rn is in rlist; LDM suppresses writeback when Rn is loaded.
      if (!load || ((rlist & (1u << rn)) == 0)) {
        cpu_.regs[rn] = addr;
      }
    }
    if (load && (rlist & (1u << 15))) {
      cpu_.regs[15] &= ~3u;
      if (s && HasSpsr(GetCpuMode())) {
        const uint32_t old_mode = GetCpuMode();
        cpu_.cpsr = cpu_.spsr[old_mode & 0x1Fu];
        const uint32_t new_mode = GetCpuMode();
        if (new_mode != old_mode) {
          SwitchCpuMode(new_mode);
        }
      }
      return;
    }
    cpu_.regs[15] += 4;
    return;
  }

  // ARM data processing
  if ((opcode & 0x0C000000u) == 0x00000000u) {
    const bool immediate = (opcode & (1u << 25)) != 0;
    const uint32_t op = (opcode >> 21) & 0xFu;
    const bool set_flags = (opcode & (1u << 20)) != 0;
    const uint32_t rn = ArmRegIndex(opcode, 16);
    const uint32_t rd = ArmRegIndex(opcode, 12);
    const bool operand2_reg_shift_by_reg = !immediate && ((opcode & (1u << 4)) != 0);
    const uint32_t lhs = (rn == 15)
                             ? (cpu_.regs[15] + (operand2_reg_shift_by_reg ? 12u : 8u))
                             : cpu_.regs[rn];

    bool carry = GetFlagC();
    uint32_t rhs = 0;
    if (immediate) {
      rhs = ExpandArmImmediate(opcode & 0xFFFu);
      const uint32_t rot = ((opcode >> 8) & 0xFu) * 2u;
      if (rot != 0) carry = (rhs >> 31) & 1u;
    } else {
      const uint32_t rm = opcode & 0xFu;
      const uint32_t shift_type = (opcode >> 5) & 0x3u;
      const bool shift_by_register = (opcode & (1u << 4)) != 0;
      uint32_t shift = 0;
      if (shift_by_register) {
        const uint32_t rs = (opcode >> 8) & 0xFu;
        const uint32_t rsv = (rs == 15) ? (cpu_.regs[15] + 8) : cpu_.regs[rs];
        shift = rsv & 0xFFu;
      } else {
        shift = (opcode >> 7) & 0x1Fu;
      }
      const uint32_t rmv = (rm == 15) ? (cpu_.regs[15] + (shift_by_register ? 12u : 8u)) : cpu_.regs[rm];
      if (shift_by_register) rhs = ArmApplyRegisterShift(rmv, shift_type, shift, GetFlagC(), &carry);
      else rhs = ApplyShift(rmv, shift_type, shift, &carry);
    }

    uint64_t r64 = 0;
    uint32_t result = 0;
    switch (op) {
      case 0x0: result = lhs & rhs; if (set_flags) { SetNZFlags(result); SetFlagC(carry); } break; // AND
      case 0x1: result = lhs ^ rhs; if (set_flags) { SetNZFlags(result); SetFlagC(carry); } break; // EOR
      case 0x2: r64 = static_cast<uint64_t>(lhs) - rhs; result = static_cast<uint32_t>(r64); if (set_flags) SetSubFlags(lhs, rhs, r64); break; // SUB
      case 0x3: r64 = static_cast<uint64_t>(rhs) - lhs; result = static_cast<uint32_t>(r64); if (set_flags) SetSubFlags(rhs, lhs, r64); break; // RSB
      case 0x4: r64 = static_cast<uint64_t>(lhs) + rhs; result = static_cast<uint32_t>(r64); if (set_flags) SetAddFlags(lhs, rhs, r64); break; // ADD
      case 0x5: r64 = static_cast<uint64_t>(lhs) + rhs + (GetFlagC() ? 1u : 0u); result = static_cast<uint32_t>(r64); if (set_flags) SetAddFlags(lhs, rhs + (GetFlagC() ? 1u : 0u), r64); break; // ADC
      case 0x6: r64 = static_cast<uint64_t>(lhs) - rhs - (GetFlagC() ? 0u : 1u); result = static_cast<uint32_t>(r64); if (set_flags) SetSubFlags(lhs, rhs + (GetFlagC() ? 0u : 1u), r64); break; // SBC
      case 0x7: r64 = static_cast<uint64_t>(rhs) - lhs - (GetFlagC() ? 0u : 1u); result = static_cast<uint32_t>(r64); if (set_flags) SetSubFlags(rhs, lhs + (GetFlagC() ? 0u : 1u), r64); break; // RSC
      case 0x8: result = lhs & rhs; if (set_flags) { SetNZFlags(result); SetFlagC(carry); } break; // TST
      case 0x9: result = lhs ^ rhs; if (set_flags) { SetNZFlags(result); SetFlagC(carry); } break; // TEQ
      case 0xA: r64 = static_cast<uint64_t>(lhs) - rhs; if (set_flags) SetSubFlags(lhs, rhs, r64); break; // CMP
      case 0xB: r64 = static_cast<uint64_t>(lhs) + rhs; if (set_flags) SetAddFlags(lhs, rhs, r64); break; // CMN
      case 0xC: result = lhs | rhs; if (set_flags) { SetNZFlags(result); SetFlagC(carry); } break; // ORR
      case 0xD: result = rhs; if (set_flags) { SetNZFlags(result); SetFlagC(carry); } break; // MOV
      case 0xE: result = lhs & ~rhs; if (set_flags) { SetNZFlags(result); SetFlagC(carry); } break; // BIC
      case 0xF: result = ~rhs; if (set_flags) { SetNZFlags(result); SetFlagC(carry); } break; // MVN
      default:
        cpu_.regs[15] += 4;
        return;
    }

    if (op != 0x8 && op != 0x9 && op != 0xA && op != 0xB) {
      cpu_.regs[rd] = result;
      if (rd == 15) {
        cpu_.regs[15] &= ~3u;
        if (set_flags && HasSpsr(GetCpuMode())) {
          const uint32_t old_mode = GetCpuMode();
          cpu_.cpsr = cpu_.spsr[old_mode & 0x1Fu];
          const uint32_t new_mode = GetCpuMode();
          if (new_mode != old_mode) {
            SwitchCpuMode(new_mode);
          }
        }
        return;
      }
    }
    cpu_.regs[15] += 4;
    return;
  }

  // 未実装命令はUNDEFへ
  HandleUndefinedInstruction(false);
}

uint32_t GBACore::RunCpuSlice(uint32_t cycles) {
  auto mul_internal_cycles = [&](uint32_t value) -> uint32_t {
    // ARM7TDMI 乗算の内部Iサイクル近似（値依存 1..4）
    if ((value & 0xFFFFFF00u) == 0u || (value & 0xFFFFFF00u) == 0xFFFFFF00u) return 1;
    if ((value & 0xFFFF0000u) == 0u || (value & 0xFFFF0000u) == 0xFFFF0000u) return 2;
    if ((value & 0xFF000000u) == 0u || (value & 0xFF000000u) == 0xFF000000u) return 3;
    return 4;
  };

  while (cycles > 0) {
    ServiceInterruptIfNeeded();
    if (cpu_.halted) break;

    const bool thumb = (cpu_.cpsr & (1u << 5)) != 0;
    const uint32_t pc_before = cpu_.regs[15];
    if (pc_before < 0x4000u) {
      const uint32_t a = pc_before & ~3u;
      bios_fetch_latch_ = static_cast<uint32_t>(bios_[a & 0x3FFFu]) |
                          (static_cast<uint32_t>(bios_[(a + 1) & 0x3FFFu]) << 8) |
                          (static_cast<uint32_t>(bios_[(a + 2) & 0x3FFFu]) << 16) |
                          (static_cast<uint32_t>(bios_[(a + 3) & 0x3FFFu]) << 24);
    }
    const uint64_t ws_before = waitstates_accum_;
    const uint32_t pending_refill = pipeline_refill_pending_;
    pipeline_refill_pending_ = 0;
    if (thumb) {
      const uint16_t op = Read16(cpu_.regs[15]);
      ExecuteThumbInstruction(op);
      if (cpu_.regs[15] != pc_before + 2u) {
        FlushPipeline(1);
      }
      const uint32_t base_spent = EstimateThumbCycles(op);
      const uint64_t ws_delta = waitstates_accum_ - ws_before;
      const uint32_t spent = base_spent + static_cast<uint32_t>(ws_delta) + pending_refill + pipeline_refill_pending_;
      pipeline_refill_pending_ = 0;
      cycles = (spent >= cycles) ? 0 : (cycles - spent);
      executed_cycles_ += spent;
    } else {
      const uint32_t op = Read32(cpu_.regs[15]);
      uint32_t mul_spent_override = 0;
      if ((op & 0x0FC000F0u) == 0x00000090u) {
        const uint32_t rs = ArmRegIndex(op, 8);
        const uint32_t rs_value = (rs == 15) ? (cpu_.regs[15] + 8u) : cpu_.regs[rs];
        const uint32_t i_cycles = mul_internal_cycles(rs_value);
        const bool accumulate = (op & (1u << 21)) != 0;
        mul_spent_override = 1u + i_cycles + (accumulate ? 1u : 0u);
      } else if ((op & 0x0F8000F0u) == 0x00800090u) {
        const uint32_t rs = ArmRegIndex(op, 8);
        const uint32_t rs_value = (rs == 15) ? (cpu_.regs[15] + 8u) : cpu_.regs[rs];
        const uint32_t i_cycles = mul_internal_cycles(rs_value);
        const bool accumulate = (op & (1u << 21)) != 0;
        mul_spent_override = 2u + i_cycles + (accumulate ? 1u : 0u);
      }
      ExecuteArmInstruction(op);
      if (cpu_.regs[15] != pc_before + 4u) {
        FlushPipeline(2);
      }
      const uint32_t base_spent = mul_spent_override ? mul_spent_override : EstimateArmCycles(op);
      const uint64_t ws_delta = waitstates_accum_ - ws_before;
      const uint32_t spent = base_spent + static_cast<uint32_t>(ws_delta) + pending_refill + pipeline_refill_pending_;
      pipeline_refill_pending_ = 0;
      cycles = (spent >= cycles) ? 0 : (cycles - spent);
      executed_cycles_ += spent;
    }
  }
  return cycles;
}

}  // namespace gba
