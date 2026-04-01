#include "../gba_core.h"
#include <algorithm>
#include <cstring>
#include <vector>

namespace gba {

void GBACore::ExecuteThumbInstruction(uint16_t opcode) {
  uint16_t type = opcode >> 11;

  switch (type) {
    case 0x00:
    case 0x01: {
      // Format 1: Shift (LSL, LSR, ASR)
      uint16_t op = (opcode >> 11) & 0x3;
      uint16_t imm = (opcode >> 6) & 0x1F;
      uint16_t rs = (opcode >> 3) & 0x7;
      uint16_t rd = opcode & 0x7;

      bool carry_out = GetFlagC();
      cpu_.regs[rd] = ApplyShift(cpu_.regs[rs], op, imm, &carry_out);
      SetNZFlags(cpu_.regs[rd]);
      SetFlagC(carry_out);
      break;
    }
    case 0x04:
    case 0x05: {
      // Format 4: ALU Operations
      uint16_t op = (opcode >> 6) & 0xF;
      uint16_t rs = (opcode >> 3) & 0x7;
      uint16_t rd = opcode & 0x7;

      uint32_t rn = cpu_.regs[rd];
      uint32_t rm = cpu_.regs[rs];
      uint32_t res = 0;
      switch (op) {
        case 0x0: res = rn & rm; SetNZFlags(res); break; // AND
        case 0x1: res = rn ^ rm; SetNZFlags(res); break; // EOR
        case 0x4: res = rn + rm; SetAddFlags(rn, rm, static_cast<uint64_t>(rn) + rm); break; // ADC
        case 0x8: SetNZFlags(rn & rm); break; // TST
        case 0x9: res = 0 - rm; SetSubFlags(0, rm, static_cast<uint64_t>(0) - rm); break; // NEG
        case 0xA: SetSubFlags(rn, rm, static_cast<uint64_t>(rn) - rm); break; // CMP
        case 0xB: SetSubFlags(rn, rm, static_cast<uint64_t>(rn) + rm); break; // CMN (Add but flags only)
        case 0xC: res = rn | rm; SetNZFlags(res); break; // ORR
        case 0xD: res = rn * rm; SetNZFlags(res); break; // MUL
        case 0xF: res = ~rm; SetNZFlags(res); break; // MVN
        // ... and so on ...
      }
      if (op != 0x8 && op != 0xA && op != 0xB) cpu_.regs[rd] = res;
      break;
    }
    case 0x1C: {
        // SWI
        HandleSoftwareInterrupt(opcode & 0xFF, true);
        break;
    }
    default:
      break;
  }
}

uint32_t GBACore::EstimateThumbCycles(uint16_t opcode) const {
    // S-cycles and N-cycles estimation logic
    return 1;
}

} // namespace gba
