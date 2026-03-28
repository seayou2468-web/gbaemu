import sys
import re

path = "src/core/gba_core_modules/memory_bus.mm"
with open(path, "r") as f:
    full_content = f.read()

def replace_func(c, name, body):
    pattern = rf"(uint\d+_t|void) GBACore::{name}\(uint32_t addr(?:, (?:uint\d+_t|uint16_t|uint8_t) value)?\) (?:const )?\{{.*?^}}"
    if re.search(pattern, c, flags=re.DOTALL | re.MULTILINE):
        return re.sub(pattern, body, c, flags=re.DOTALL | re.MULTILINE)
    return c

# 1. Update WriteIO16 with HALTCNT and STOP side effects
match = re.search(r"void GBACore::WriteIO16\(uint32_t addr, uint16_t value\) \{(.*?)\n\}", full_content, flags=re.DOTALL | re.MULTILINE)
inner = match.group(1) if match else ""

new_cases = """
    case 0x04000300u: {
      // POSTFLG (0x300) / HALTCNT (0x301)
      if (value & 0x8000u) {
        // STOP mode: Stops almost everything.
        cpu_.halted = true;
      } else {
        // HALT mode: CPU enters low-power state until IRQ.
        cpu_.halted = true;
      }
      break;
    }
"""

if "case 0x04000300u:" not in inner:
    inner = inner.replace("case 0x04000208u: value &= 0x0001u; break; // IME",
                          "case 0x04000208u: value &= 0x0001u; break; // IME" + new_cases)

# Add StepDma trigger for immediate DMA
inner += """
  // Immediate DMA trigger
  if (addr == 0x040000B8u || addr == 0x040000C4u || addr == 0x040000D0u || addr == 0x040000DCu) {
    if ((value & 0x8000u) && ((value >> 12) & 3) == 0) {
      StepDma();
    }
  }
"""

write_io16_body = "void GBACore::WriteIO16(uint32_t addr, uint16_t value) {" + inner + "\n}"

full_content = replace_func(full_content, "WriteIO16", write_io16_body)

with open(path, "w") as f:
    f.write(full_content)
