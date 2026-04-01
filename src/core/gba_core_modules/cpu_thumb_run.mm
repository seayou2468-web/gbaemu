#include "../gba_core.h"
#include <algorithm>
#include <cstring>

namespace gba {

void GBACore::ExecuteThumbInstruction(uint16_t opcode) {
  uint16_t type = opcode >> 11;

  switch (type) {
    case 0x00: case 0x01: {
      uint16_t op = (opcode >> 11) & 0x3;
      uint16_t imm = (opcode >> 6) & 0x1F;
      uint16_t rs = (opcode >> 3) & 0x7;
      uint16_t rd = opcode & 0x7;
      bool carry_out = GetFlagC();
      cpu_.regs[rd] = ApplyShift(cpu_.regs[rs], op, imm, &carry_out);
      SetNZFlags(cpu_.regs[rd]); SetFlagC(carry_out); break;
    }
    case 0x1C: { HandleSoftwareInterrupt(opcode & 0xFF, true); break; }
    default: break;
  }
}

uint32_t GBACore::EstimateThumbCycles(uint16_t opcode) const { return 1; }

} // namespace gba
