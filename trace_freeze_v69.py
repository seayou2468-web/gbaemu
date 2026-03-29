import sys
import re

path = "src/core/gba_core_modules/cpu_thumb_run.mm"
with open(path, "r") as f:
    content = f.read()

# Add high-frequency PC logging to RunCpuSlice to detect loops
# and also log I/O reads that might be polling forever.

logging_code = """
    static uint64_t total_instr = 0;
    total_instr++;
    if (total_instr % 100000 == 0) {
       printf("PC=%08X CPSR=%08X cycles_remain=%d\\n", cpu_.regs[15], cpu_.cpsr, remaining_cycles);
    }
"""

# Insert logging into the while loop of RunCpuSlice
pattern = r"(while \(remaining_cycles > 0\s*&& !cpu_\.halted\) \{)"
content = re.sub(pattern, r"\1" + logging_code, content)

with open(path, "w") as f:
    f.write(content)
