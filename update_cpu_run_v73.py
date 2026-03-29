import sys
import re

path = "src/core/gba_core_modules/cpu_thumb_run.mm"
with open(path, "r") as f:
    content = f.read()

# Add watchdog/protection to the main execution loop to prevent infinite loops
# if ReadBus/ReadIO/Interrupts logic fails to provide an exit condition.

protect_loop = """
    if (!is_exec_addr_valid(cpu_.regs[15])) {
      // Emergency: if PC escapes to unmapped region, force it back to a safe place
      // or stop execution for this slice.
      break;
    }
"""

pattern = r"(while \(consumed < cycles\) \{)"
content = re.sub(pattern, r"\1" + protect_loop, content)

# Clean up previous trace prints if any
content = re.sub(r"static uint64_t total_instr.*?\n\s*\}\n", "", content, flags=re.DOTALL)

with open(path, "w") as f:
    f.write(content)
