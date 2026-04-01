#include "../gba_core.h"

namespace gba {

namespace {
inline uint32_t ArmRegIndex(uint32_t op, uint32_t shift) { return (op >> shift) & 0xFu; }
}

uint32_t GBACore::EstimateArmCycles(uint32_t opcode) const {
  // メモリアクセス命令と乗算だけ重めに見積もる（mGBAの待機モデルに寄せる）
  if ((opcode & 0x0C000000u) == 0x04000000u) return 3;
  if ((opcode & 0x0FC000F0u) == 0x00000090u) return 3;
  if ((opcode & 0x0E000000u) == 0x0A000000u) return 3;
  return 1;
}

void GBACore::ExecuteArmInstruction(uint32_t opcode) {
  const uint32_t cond = opcode >> 28;
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
    const uint32_t target = cpu_.regs[rm];
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
    uint32_t result = cpu_.regs[rm] * cpu_.regs[rs];
    if (accumulate) result += cpu_.regs[rn];
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
    const uint32_t rd_hi = ArmRegIndex(opcode, 16);
    const uint32_t rd_lo = ArmRegIndex(opcode, 12);
    const uint32_t rs = ArmRegIndex(opcode, 8);
    const uint32_t rm = ArmRegIndex(opcode, 0);
    uint64_t product = 0;
    if (signed_mul) {
      product = static_cast<uint64_t>(static_cast<int64_t>(static_cast<int32_t>(cpu_.regs[rm])) *
                                      static_cast<int64_t>(static_cast<int32_t>(cpu_.regs[rs])));
    } else {
      product = static_cast<uint64_t>(cpu_.regs[rm]) * static_cast<uint64_t>(cpu_.regs[rs]);
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
    cpu_.regs[15] += 4;
    return;
  }

  // SWP/SWPB
  if ((opcode & 0x0FB00FF0u) == 0x01000090u) {
    const bool byte = (opcode & (1u << 22)) != 0;
    const uint32_t rn = ArmRegIndex(opcode, 16);
    const uint32_t rd = ArmRegIndex(opcode, 12);
    const uint32_t rm = ArmRegIndex(opcode, 0);
    const uint32_t addr = cpu_.regs[rn];
    if (byte) {
      const uint8_t old = Read8(addr);
      Write8(addr, static_cast<uint8_t>(cpu_.regs[rm]));
      cpu_.regs[rd] = old;
    } else {
      const uint32_t old = Read32(addr);
      Write32(addr, cpu_.regs[rm]);
      cpu_.regs[rd] = old;
    }
    cpu_.regs[15] += 4;
    return;
  }

  // MRS / MSR (最低限)
  if ((opcode & 0x0FBF0FFFu) == 0x010F0000u) {  // MRS Rd, CPSR/SPSR
    const bool spsr = (opcode & (1u << 22)) != 0;
    const uint32_t rd = ArmRegIndex(opcode, 12);
    cpu_.regs[rd] = spsr && HasSpsr(GetCpuMode()) ? cpu_.spsr[GetCpuMode() & 0x1Fu] : cpu_.cpsr;
    cpu_.regs[15] += 4;
    return;
  }
  if ((opcode & 0x0DB0F000u) == 0x0120F000u) {  // MSR CPSR/SPSR_flg, Rm
    const bool spsr = (opcode & (1u << 22)) != 0;
    const uint32_t rm = opcode & 0xFu;
    const uint32_t mask = 0xF0000000u | ((opcode & (1u << 16)) ? 0x000000FFu : 0u);
    if (spsr && HasSpsr(GetCpuMode())) {
      auto& psr = cpu_.spsr[GetCpuMode() & 0x1Fu];
      psr = (psr & ~mask) | (cpu_.regs[rm] & mask);
    } else if (!spsr) {
      cpu_.cpsr = (cpu_.cpsr & ~mask) | (cpu_.regs[rm] & mask);
    }
    cpu_.regs[15] += 4;
    return;
  }
  if ((opcode & 0x0DB0F000u) == 0x0320F000u) {  // MSR CPSR/SPSR_flg, #imm
    const bool spsr = (opcode & (1u << 22)) != 0;
    const uint32_t imm = ExpandArmImmediate(opcode & 0xFFFu);
    const uint32_t mask = 0xF0000000u | ((opcode & (1u << 16)) ? 0x000000FFu : 0u);
    if (spsr && HasSpsr(GetCpuMode())) {
      auto& psr = cpu_.spsr[GetCpuMode() & 0x1Fu];
      psr = (psr & ~mask) | (imm & mask);
    } else if (!spsr) {
      cpu_.cpsr = (cpu_.cpsr & ~mask) | (imm & mask);
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
    uint32_t off = imm ? (((opcode >> 4) & 0xF0u) | (opcode & 0xFu)) : cpu_.regs[opcode & 0xFu];
    uint32_t addr = cpu_.regs[rn];
    if (pre) addr = up ? (addr + off) : (addr - off);

    if (load) {
      if (op == 1) cpu_.regs[rd] = Read16(addr);
      else if (op == 2) cpu_.regs[rd] = static_cast<int32_t>(static_cast<int8_t>(Read8(addr)));
      else cpu_.regs[rd] = static_cast<int32_t>(static_cast<int16_t>(Read16(addr)));
    } else if (op == 1) {
      Write16(addr, static_cast<uint16_t>(cpu_.regs[rd]));
    }

    if (!pre) addr = up ? (addr + off) : (addr - off);
    if (writeback || !pre) cpu_.regs[rn] = addr;
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
      uint32_t amount = 0;
      if (opcode & (1u << 4)) {
        const uint32_t rs = (opcode >> 8) & 0xFu;
        amount = ((rs == 15 ? (cpu_.regs[15] + 8) : cpu_.regs[rs])) & 0xFFu;
      } else {
        amount = (opcode >> 7) & 0x1Fu;
      }
      const uint32_t rmv = (rm == 15) ? (cpu_.regs[15] + 8) : cpu_.regs[rm];
      off = ApplyShift(rmv, shift, amount, nullptr);
    }

    uint32_t addr = cpu_.regs[rn];
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
      const uint32_t v = cpu_.regs[rd];
      if (byte) {
        Write8(addr, static_cast<uint8_t>(v));
      } else {
        Write32(addr, v);
      }
    }

    if (!pre) {
      addr = up ? (addr + off) : (addr - off);
    }
    if (writeback || !pre) {
      cpu_.regs[rn] = addr;
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
    uint32_t addr = cpu_.regs[rn];

    auto advance = [&](bool before) {
      if (before) addr = up ? (addr + 4) : (addr - 4);
    };
    auto finish = [&](bool after) {
      if (after) addr = up ? (addr + 4) : (addr - 4);
    };

    for (uint32_t r = 0; r < 16; ++r) {
      if ((rlist & (1u << r)) == 0) continue;
      advance(pre);
      if (load) {
        cpu_.regs[r] = Read32(addr);
      } else {
        Write32(addr, cpu_.regs[r]);
      }
      finish(!pre);
    }

    if (writeback && ((rlist & (1u << rn)) == 0)) {
      cpu_.regs[rn] = addr;
    }
    if (load && (rlist & (1u << 15))) {
      cpu_.regs[15] &= ~3u;
      if (s && HasSpsr(GetCpuMode())) {
        cpu_.cpsr = cpu_.spsr[GetCpuMode() & 0x1Fu];
      }
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
    const uint32_t lhs = (rn == 15) ? (cpu_.regs[15] + 8) : cpu_.regs[rn];

    bool carry = GetFlagC();
    uint32_t rhs = 0;
    if (immediate) {
      rhs = ExpandArmImmediate(opcode & 0xFFFu);
      const uint32_t rot = ((opcode >> 8) & 0xFu) * 2u;
      if (rot != 0) carry = (rhs >> 31) & 1u;
    } else {
      const uint32_t rm = opcode & 0xFu;
      const uint32_t shift_type = (opcode >> 5) & 0x3u;
      uint32_t shift = 0;
      if (opcode & (1u << 4)) {
        const uint32_t rs = (opcode >> 8) & 0xFu;
        const uint32_t rsv = (rs == 15) ? (cpu_.regs[15] + 8) : cpu_.regs[rs];
        shift = rsv & 0xFFu;
      } else {
        shift = (opcode >> 7) & 0x1Fu;
      }
      const uint32_t rmv = (rm == 15) ? (cpu_.regs[15] + 8) : cpu_.regs[rm];
      rhs = ApplyShift(rmv, shift_type, shift, &carry);
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
          cpu_.cpsr = cpu_.spsr[GetCpuMode() & 0x1Fu];
        }
      }
    }
    cpu_.regs[15] += 4;
    return;
  }

  // 未実装命令はUNDEFへ
  HandleUndefinedInstruction(false);
}

uint32_t GBACore::RunCpuSlice(uint32_t cycles) {
  while (cycles > 0) {
    ServiceInterruptIfNeeded();
    if (cpu_.halted) break;

    const bool thumb = (cpu_.cpsr & (1u << 5)) != 0;
    if (thumb) {
      const uint16_t op = Read16(cpu_.regs[15]);
      ExecuteThumbInstruction(op);
      const uint32_t spent = EstimateThumbCycles(op);
      cycles = (spent >= cycles) ? 0 : (cycles - spent);
      executed_cycles_ += spent;
    } else {
      const uint32_t op = Read32(cpu_.regs[15]);
      ExecuteArmInstruction(op);
      const uint32_t spent = EstimateArmCycles(op);
      cycles = (spent >= cycles) ? 0 : (cycles - spent);
      executed_cycles_ += spent;
    }
  }
  return cycles;
}

}  // namespace gba
