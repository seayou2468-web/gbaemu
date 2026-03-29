import sys
import re

path = "src/core/gba_core_modules/cpu_swi.mm"
with open(path, "r") as f:
    content = f.read()

# Add missing Math cases to HandleSoftwareInterrupt
new_math_cases = """
    case 0x06u: { // Div
      int32_t num = (int32_t)cpu_.regs[0];
      int32_t den = (int32_t)cpu_.regs[1];
      if (den == 0) {
        // GBA Div by zero behavior: returns num in R0, 0 in R1, num in R3
      } else {
        cpu_.regs[0] = static_cast<uint32_t>(num / den);
        cpu_.regs[1] = static_cast<uint32_t>(num % den);
        cpu_.regs[3] = std::abs(num / den);
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x07u: { // DivArm (num in R1, den in R0)
      int32_t den = (int32_t)cpu_.regs[0];
      int32_t num = (int32_t)cpu_.regs[1];
      if (den != 0) {
        cpu_.regs[0] = static_cast<uint32_t>(num / den);
        cpu_.regs[1] = static_cast<uint32_t>(num % den);
        cpu_.regs[3] = std::abs(num / den);
      }
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x08u: { // Sqrt
      cpu_.regs[0] = BiosSqrtLocal(cpu_.regs[0]);
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x09u: { // ArcTan
      int16_t res = BiosArcTanPolyLocal((int32_t)cpu_.regs[0]);
      cpu_.regs[0] = static_cast<uint32_t>(static_cast<uint16_t>(res));
      cpu_.regs[15] = next_pc;
      return true;
    }
    case 0x0Au: { // ArcTan2
      int16_t res = BiosArcTan2Local((int32_t)cpu_.regs[0], (int32_t)cpu_.regs[1]);
      cpu_.regs[0] = static_cast<uint32_t>(static_cast<uint16_t>(res));
      cpu_.regs[15] = next_pc;
      return true;
    }
"""

# Insert before CpuSet (0x0B)
content = content.replace("case 0x0Bu:  // CpuSet", new_math_cases + "    case 0x0Bu:  // CpuSet")

with open(path, "w") as f:
    f.write(content)
