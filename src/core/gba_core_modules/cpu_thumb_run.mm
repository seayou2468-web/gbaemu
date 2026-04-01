#include "../gba_core.h"

namespace gba {

uint32_t GBACore::EstimateThumbCycles(uint16_t opcode) const {
  if ((opcode & 0xF000u) == 0xD000u || (opcode & 0xF800u) == 0xE000u) return 3;
  if ((opcode & 0xF800u) == 0xF000u || (opcode & 0xF800u) == 0xF800u) return 3;
  if ((opcode & 0xF000u) == 0x5000u || (opcode & 0xF000u) == 0x6000u) return 2;
  return 1;
}

void GBACore::ExecuteThumbInstruction(uint16_t opcode) {
  // BL prefix (H=10) / suffix (H=11)
  if ((opcode & 0xF800u) == 0xF000u) {
    const int32_t off = static_cast<int16_t>((opcode & 0x07FFu) << 5) << 7;
    cpu_.regs[14] = cpu_.regs[15] + 4 + static_cast<uint32_t>(off);
    cpu_.regs[15] += 2;
    return;
  }
  if ((opcode & 0xF800u) == 0xF800u) {
    const uint32_t off = (opcode & 0x07FFu) << 1;
    const uint32_t next = cpu_.regs[15] + 2;
    const uint32_t target = cpu_.regs[14] + off;
    cpu_.regs[14] = (next - 1u);
    cpu_.regs[15] = target & ~1u;
    return;
  }

  // SWI
  if ((opcode & 0xFF00u) == 0xDF00u) {
    HandleSoftwareInterrupt(opcode & 0xFFu, true);
    return;
  }
  // BKPT (ARMv5+, here treat as undefined trap)
  if ((opcode & 0xFF00u) == 0xBE00u) {
    HandleUndefinedInstruction(true);
    return;
  }

  // unconditional branch
  if ((opcode & 0xF800u) == 0xE000u) {
    int32_t off = static_cast<int16_t>((opcode & 0x7FFu) << 5) >> 4;
    cpu_.regs[15] = cpu_.regs[15] + 4 + static_cast<uint32_t>(off);
    return;
  }

  // conditional branch
  if ((opcode & 0xF000u) == 0xD000u && (opcode & 0x0F00u) != 0x0F00u) {
    const uint32_t cond = (opcode >> 8) & 0xFu;
    const int32_t off = static_cast<int8_t>(opcode & 0xFFu) << 1;
    if (CheckCondition(cond)) {
      cpu_.regs[15] = cpu_.regs[15] + 4 + static_cast<uint32_t>(off);
    } else {
      cpu_.regs[15] += 2;
    }
    return;
  }

  // BX / high register operations
  if ((opcode & 0xFC00u) == 0x4400u) {
    const uint32_t op = (opcode >> 8) & 0x3u;
    const uint32_t h1 = (opcode >> 7) & 1u;
    const uint32_t h2 = (opcode >> 6) & 1u;
    const uint32_t rd = (opcode & 0x7u) | (h1 << 3);
    const uint32_t rm = ((opcode >> 3) & 0x7u) | (h2 << 3);
    if (op == 0) {
      cpu_.regs[rd] += cpu_.regs[rm];
      if (rd == 15) cpu_.regs[15] &= ~1u;
    } else if (op == 1) {
      const uint64_t r64 = static_cast<uint64_t>(cpu_.regs[rd]) - cpu_.regs[rm];
      SetSubFlags(cpu_.regs[rd], cpu_.regs[rm], r64);
    } else if (op == 2) {
      cpu_.regs[rd] = cpu_.regs[rm];
      if (rd == 15) cpu_.regs[15] &= ~1u;
    } else {
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
    cpu_.regs[15] += 2;
    return;
  }

  // Thumb ALU register form
  if ((opcode & 0xFC00u) == 0x4000u) {
    const uint32_t op = (opcode >> 6) & 0xFu;
    const uint32_t rs = (opcode >> 3) & 0x7u;
    const uint32_t rd = opcode & 0x7u;
    const uint32_t s = cpu_.regs[rs];
    const uint32_t d = cpu_.regs[rd];
    uint64_t r64 = 0;
    switch (op) {
      case 0x0: cpu_.regs[rd] = d & s; SetNZFlags(cpu_.regs[rd]); break;
      case 0x1: cpu_.regs[rd] = d ^ s; SetNZFlags(cpu_.regs[rd]); break;
      case 0x2: cpu_.regs[rd] = ApplyShift(d, 0, s & 0xFFu, nullptr); SetNZFlags(cpu_.regs[rd]); break;
      case 0x3: cpu_.regs[rd] = ApplyShift(d, 1, s & 0xFFu, nullptr); SetNZFlags(cpu_.regs[rd]); break;
      case 0x4: cpu_.regs[rd] = ApplyShift(d, 2, s & 0xFFu, nullptr); SetNZFlags(cpu_.regs[rd]); break;
      case 0x5: r64 = static_cast<uint64_t>(d) + s + (GetFlagC() ? 1u : 0u); cpu_.regs[rd] = static_cast<uint32_t>(r64); SetAddFlags(d, s + (GetFlagC() ? 1u : 0u), r64); break;
      case 0x6: r64 = static_cast<uint64_t>(d) - s - (GetFlagC() ? 0u : 1u); cpu_.regs[rd] = static_cast<uint32_t>(r64); SetSubFlags(d, s + (GetFlagC() ? 0u : 1u), r64); break;
      case 0x7: cpu_.regs[rd] = ApplyShift(d, 3, s & 0xFFu, nullptr); SetNZFlags(cpu_.regs[rd]); break;
      case 0x8: SetNZFlags(d & s); break;
      case 0x9: r64 = static_cast<uint64_t>(0) - s; cpu_.regs[rd] = static_cast<uint32_t>(r64); SetSubFlags(0, s, r64); break;
      case 0xA: r64 = static_cast<uint64_t>(d) - s; SetSubFlags(d, s, r64); break;
      case 0xB: r64 = static_cast<uint64_t>(d) + s; SetAddFlags(d, s, r64); break;
      case 0xC: cpu_.regs[rd] = d | s; SetNZFlags(cpu_.regs[rd]); break;
      case 0xD: cpu_.regs[rd] = d * s; SetNZFlags(cpu_.regs[rd]); break;
      case 0xE: cpu_.regs[rd] = d & ~s; SetNZFlags(cpu_.regs[rd]); break;
      case 0xF: cpu_.regs[rd] = ~s; SetNZFlags(cpu_.regs[rd]); break;
    }
    cpu_.regs[15] += 2;
    return;
  }

  // ALU immediate add/sub/mov/cmp
  if ((opcode & 0xE000u) == 0x2000u) {
    const uint32_t op = (opcode >> 11) & 0x3u;
    const uint32_t rd = (opcode >> 8) & 0x7u;
    const uint32_t imm8 = opcode & 0xFFu;
    if (op == 0) {
      cpu_.regs[rd] = imm8;
      SetNZFlags(cpu_.regs[rd]);
    } else if (op == 1) {
      const uint64_t r64 = static_cast<uint64_t>(cpu_.regs[rd]) - imm8;
      SetSubFlags(cpu_.regs[rd], imm8, r64);
    } else if (op == 2) {
      const uint64_t r64 = static_cast<uint64_t>(cpu_.regs[rd]) + imm8;
      cpu_.regs[rd] = static_cast<uint32_t>(r64);
      SetAddFlags(cpu_.regs[rd] - imm8, imm8, r64);
    } else {
      const uint64_t r64 = static_cast<uint64_t>(cpu_.regs[rd]) - imm8;
      cpu_.regs[rd] = static_cast<uint32_t>(r64);
      SetSubFlags(cpu_.regs[rd] + imm8, imm8, r64);
    }
    cpu_.regs[15] += 2;
    return;
  }

  // LDR literal
  if ((opcode & 0xF800u) == 0x4800u) {
    const uint32_t rd = (opcode >> 8) & 0x7u;
    const uint32_t imm = (opcode & 0xFFu) << 2;
    const uint32_t base = (cpu_.regs[15] + 4) & ~3u;
    cpu_.regs[rd] = Read32(base + imm);
    cpu_.regs[15] += 2;
    return;
  }

  // register offset LDR/STR + sign-ext loads
  if ((opcode & 0xF200u) == 0x5000u) {
    const uint32_t op = (opcode >> 9) & 0x7u;
    const uint32_t rm = (opcode >> 6) & 0x7u;
    const uint32_t rn = (opcode >> 3) & 0x7u;
    const uint32_t rd = opcode & 0x7u;
    const uint32_t addr = cpu_.regs[rn] + cpu_.regs[rm];
    switch (op) {
      case 0: Write32(addr, cpu_.regs[rd]); break;                                         // STR
      case 1: Write16(addr, static_cast<uint16_t>(cpu_.regs[rd])); break;                  // STRH
      case 2: Write8(addr, static_cast<uint8_t>(cpu_.regs[rd])); break;                    // STRB
      case 3: cpu_.regs[rd] = static_cast<int32_t>(static_cast<int8_t>(Read8(addr))); break;  // LDSB
      case 4: cpu_.regs[rd] = Read32(addr); break;                                          // LDR
      case 5: cpu_.regs[rd] = Read16(addr); break;                                          // LDRH
      case 6: cpu_.regs[rd] = Read8(addr); break;                                           // LDRB
      case 7: cpu_.regs[rd] = static_cast<int32_t>(static_cast<int16_t>(Read16(addr))); break; // LDSH
    }
    cpu_.regs[15] += 2;
    return;
  }

  // STR/LDR immediate
  if ((opcode & 0xE000u) == 0x6000u) {
    const bool is_load = (opcode & 0x0800u) != 0;
    const uint32_t imm5 = (opcode >> 6) & 0x1Fu;
    const uint32_t rb = (opcode >> 3) & 0x7u;
    const uint32_t rd = opcode & 0x7u;
    const uint32_t addr = cpu_.regs[rb] + (imm5 << 2);
    if (is_load) {
      cpu_.regs[rd] = Read32(addr);
    } else {
      Write32(addr, cpu_.regs[rd]);
    }
    cpu_.regs[15] += 2;
    return;
  }

  // STRB/LDRB immediate
  if ((opcode & 0xF000u) == 0x7000u) {
    const bool is_load = (opcode & 0x0800u) != 0;
    const uint32_t imm5 = (opcode >> 6) & 0x1Fu;
    const uint32_t rb = (opcode >> 3) & 0x7u;
    const uint32_t rd = opcode & 0x7u;
    const uint32_t addr = cpu_.regs[rb] + imm5;
    if (is_load) cpu_.regs[rd] = Read8(addr);
    else Write8(addr, static_cast<uint8_t>(cpu_.regs[rd]));
    cpu_.regs[15] += 2;
    return;
  }

  // STRH/LDRH immediate
  if ((opcode & 0xF000u) == 0x8000u) {
    const bool is_load = (opcode & 0x0800u) != 0;
    const uint32_t imm5 = (opcode >> 6) & 0x1Fu;
    const uint32_t rb = (opcode >> 3) & 0x7u;
    const uint32_t rd = opcode & 0x7u;
    const uint32_t addr = cpu_.regs[rb] + (imm5 << 1);
    if (is_load) cpu_.regs[rd] = Read16(addr);
    else Write16(addr, static_cast<uint16_t>(cpu_.regs[rd]));
    cpu_.regs[15] += 2;
    return;
  }

  // SP relative load/store
  if ((opcode & 0xF000u) == 0x9000u) {
    const bool is_load = (opcode & 0x0800u) != 0;
    const uint32_t rd = (opcode >> 8) & 0x7u;
    const uint32_t imm = (opcode & 0xFFu) << 2;
    const uint32_t addr = cpu_.regs[13] + imm;
    if (is_load) cpu_.regs[rd] = Read32(addr);
    else Write32(addr, cpu_.regs[rd]);
    cpu_.regs[15] += 2;
    return;
  }

  // ADD Rd, PC/SP, #imm
  if ((opcode & 0xF000u) == 0xA000u) {
    const bool use_sp = (opcode & 0x0800u) != 0;
    const uint32_t rd = (opcode >> 8) & 0x7u;
    const uint32_t imm = (opcode & 0xFFu) << 2;
    const uint32_t base = use_sp ? cpu_.regs[13] : ((cpu_.regs[15] + 4) & ~3u);
    cpu_.regs[rd] = base + imm;
    cpu_.regs[15] += 2;
    return;
  }

  // ADD/SUB SP, #imm
  if ((opcode & 0xFF00u) == 0xB000u) {
    const uint32_t imm = (opcode & 0x7Fu) << 2;
    if (opcode & 0x80u) cpu_.regs[13] -= imm;
    else cpu_.regs[13] += imm;
    cpu_.regs[15] += 2;
    return;
  }

  // PUSH/POP
  if ((opcode & 0xF600u) == 0xB400u) {
    uint32_t rlist = opcode & 0xFFu;
    if (opcode & 0x0100u) rlist |= (1u << ((opcode & 0x0800u) ? 15u : 14u));
    const bool is_pop = (opcode & 0x0800u) != 0;
    if (is_pop) {
      for (uint32_t r = 0; r < 16; ++r) if (rlist & (1u << r)) { cpu_.regs[r] = Read32(cpu_.regs[13]); cpu_.regs[13] += 4; }
      if (rlist & (1u << 15)) cpu_.regs[15] &= ~1u;
    } else {
      for (int r = 15; r >= 0; --r) if (rlist & (1u << r)) { cpu_.regs[13] -= 4; Write32(cpu_.regs[13], cpu_.regs[r]); }
    }
    cpu_.regs[15] += 2;
    return;
  }

  // STMIA/LDMIA
  if ((opcode & 0xF000u) == 0xC000u) {
    const bool is_load = (opcode & 0x0800u) != 0;
    const uint32_t rn = (opcode >> 8) & 0x7u;
    const uint32_t rlist = opcode & 0xFFu;
    uint32_t addr = cpu_.regs[rn];
    for (uint32_t r = 0; r < 8; ++r) {
      if ((rlist & (1u << r)) == 0) continue;
      if (is_load) cpu_.regs[r] = Read32(addr);
      else Write32(addr, cpu_.regs[r]);
      addr += 4;
    }
    cpu_.regs[rn] = addr;
    cpu_.regs[15] += 2;
    return;
  }

  // ADD/SUB register
  if ((opcode & 0xF800u) == 0x1800u) {
    const bool is_sub = (opcode & 0x0200u) != 0;
    const bool is_imm = (opcode & 0x0400u) != 0;
    const uint32_t rn = (opcode >> 3) & 0x7u;
    const uint32_t rd = opcode & 0x7u;
    const uint32_t op2 = is_imm ? ((opcode >> 6) & 0x7u) : cpu_.regs[(opcode >> 6) & 0x7u];
    const uint32_t lhs = cpu_.regs[rn];
    uint64_t r64 = 0;
    if (is_sub) {
      r64 = static_cast<uint64_t>(lhs) - op2;
      cpu_.regs[rd] = static_cast<uint32_t>(r64);
      SetSubFlags(lhs, op2, r64);
    } else {
      r64 = static_cast<uint64_t>(lhs) + op2;
      cpu_.regs[rd] = static_cast<uint32_t>(r64);
      SetAddFlags(lhs, op2, r64);
    }
    cpu_.regs[15] += 2;
    return;
  }

  cpu_.regs[15] += 2;
}

}  // namespace gba
