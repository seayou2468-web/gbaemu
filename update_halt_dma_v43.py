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

# 1. Update WriteIO16 to handle HALTCNT and DMA immediate trigger
# Extract the current inner loop of WriteIO16
match = re.search(r"void GBACore::WriteIO16\(uint32_t addr, uint16_t value\) \{(.*?)\n\}", full_content, flags=re.DOTALL | re.MULTILINE)
inner = match.group(1) if match else ""

# Add HALTCNT (0x04000300) case and improve DMA trigger
# 0x04000301 is high byte of 0x04000300.
# Bit 7 of 0x04000301 is HALT/STOP.
new_cases = """
    case 0x04000300u: {
      // POSTFLG (0x300) is RO for most part, HALTCNT (0x301)
      if (value & 0x8000u) {
        // Stop mode (conceptual)
        cpu_.halted = true;
      } else {
        // Halt mode
        cpu_.halted = true;
      }
      // POSTFLG is generally not used by games after boot
      break;
    }
"""

# Replace existing switch content or append
if "case 0x04000300u:" not in inner:
    # Insert before the closing brace of switch(addr)
    # Finding the last break; before the end of the switch
    inner = inner.replace("case 0x04000208u: value &= 0x0001u; break; // IME",
                          "case 0x04000208u: value &= 0x0001u; break; // IME" + new_cases)

# Add immediate DMA call in WriteIO16 for timing 0?
# Actually, the core loop calls StepDma regularly.
# But for better responsiveness, we could call StepDma() here if DMA is enabled and timing is 0.

write_io16_body = "void GBACore::WriteIO16(uint32_t addr, uint16_t value) {" + inner + """
  // Trigger immediate DMA if enabled
  if (addr == 0x040000B8u || addr == 0x040000C4u || addr == 0x040000D0u || addr == 0x040000DCu) {
    if ((value & 0x8000u) && ((value >> 12) & 3) == 0) {
      StepDma();
    }
  }
}"""

full_content = replace_func(full_content, "WriteIO16", write_io16_body)

with open(path, "w") as f:
    f.write(full_content)
