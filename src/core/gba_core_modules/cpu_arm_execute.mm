#include "../gba_core.h"
#include <algorithm>
#include <cstring>
#include <vector>

namespace gba {

void GBACore::ExecuteArmInstruction(uint32_t opcode) {
  uint32_t cond = opcode >> 28;
  if (!CheckCondition(cond)) return;

  uint32_t type = (opcode >> 24) & 0xF;

  // High-performance opcode dispatch (simple version for now)
  switch (type) {
    case 0x0:
    case 0x1:
    case 0x2:
    case 0x3: {
      // Data Processing / PSR transfer
      uint32_t op = (opcode >> 21) & 0xF;
      bool s = (opcode >> 20) & 1;
      uint32_t rn_idx = (opcode >> 16) & 0xF;
      uint32_t rd_idx = (opcode >> 12) & 0xF;
      uint32_t shifter_operand = 0;
      bool carry_out = GetFlagC();

      if ((opcode & 0x02000000)) { // Immediate
        shifter_operand = ExpandArmImmediate(opcode & 0xFFF);
      } else { // Register / Register-shifted
        uint32_t rm_idx = opcode & 0xF;
        uint32_t shift_type = (opcode >> 5) & 0x3;
        uint32_t shift_amount = (opcode >> 7) & 0x1F;
        if ((opcode & 0x10)) { // Register shifted
           uint32_t rs_idx = (opcode >> 8) & 0xF;
           shift_amount = cpu_.regs[rs_idx] & 0xFF;
        }
        shifter_operand = ApplyShift(cpu_.regs[rm_idx], shift_type, shift_amount, &carry_out);
      }

      uint32_t rn = cpu_.regs[rn_idx];
      uint32_t res = 0;
      switch (op) {
        case 0x0: res = rn & shifter_operand; if (s) SetNZFlags(res); break; // AND
        case 0x1: res = rn ^ shifter_operand; if (s) SetNZFlags(res); break; // EOR
        case 0x2: res = rn - shifter_operand; if (s) SetSubFlags(rn, shifter_operand, static_cast<uint64_t>(rn) - shifter_operand); break; // SUB
        case 0x4: res = rn + shifter_operand; if (s) SetAddFlags(rn, shifter_operand, static_cast<uint64_t>(rn) + shifter_operand); break; // ADD
        case 0x8: if (s) SetNZFlags(rn & shifter_operand); break; // TST
        case 0xA: if (s) SetSubFlags(rn, shifter_operand, static_cast<uint64_t>(rn) - shifter_operand); break; // CMP
        case 0xC: res = rn | shifter_operand; if (s) SetNZFlags(res); break; // ORR
        case 0xD: res = shifter_operand; if (s) SetNZFlags(res); break; // MOV
        case 0xF: res = ~shifter_operand; if (s) SetNZFlags(res); break; // MVN
        // ... and so on ...
      }
      if (!(op >= 0x8 && op <= 0xB)) cpu_.regs[rd_idx] = res;
      if (s && op != 0x8 && op != 0xA) SetFlagC(carry_out);
      break;
    }
    case 0x8:
    case 0x9: {
      // Branch / BL
      uint32_t offset = (opcode & 0xFFFFFF) << 2;
      if (offset & 0x02000000) offset |= 0xFC000000; // Sign extend
      if ((opcode >> 24) & 1) cpu_.regs[14] = cpu_.regs[15] + 4; // BL
      cpu_.regs[15] += offset + 4;
      break;
    }
    case 0xA:
    case 0xB: {
        // Load/Store
        // ...
        break;
    }
    case 0xF: {
      // SWI
      HandleSoftwareInterrupt(opcode & 0x00FFFFFF, false);
      break;
    }
    default:
      break;
  }
}

uint32_t GBACore::EstimateArmCycles(uint32_t opcode) const {
    // S-cycles and N-cycles estimation logic
    return 1;
}

} // namespace gba
