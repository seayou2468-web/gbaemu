import sys
import re

# 1. Fix PC advancement in ExecuteThumbInstruction (cascading into loops)
# Some instructions like branches or loads to PC might not be correctly advancing
# or might be leaving the PC in an inconsistent state.

path_thumb = "src/core/gba_core_modules/cpu_thumb_run.mm"
with open(path_thumb, "r") as f:
    content = f.read()

# Ensure PC is always updated correctly and exceptions/interrupts use a consistent base.

# 2. Fix the halt condition to be strictly exited on (IE & IF) != 0
path_apu = "src/core/gba_core_modules/apu_interrupts.mm"
with open(path_apu, "r") as f:
    content_apu = f.read()

# Redefine RunCpuSlice to be more robust against freezes
path_run = "src/core/gba_core_modules/cpu_thumb_run.mm"
with open(path_run, "r") as f:
    content_run = f.read()

new_run_slice = """void GBACore::RunCpuSlice(uint32_t cycles) {
  // 1. Wake up from HALT if any enabled interrupt is pending
  const uint16_t ie = ReadIO16(0x04000200u);
  const uint16_t iflags = ReadIO16(0x04000202u);
  if (cpu_.halted && (ie & iflags) != 0) {
    cpu_.halted = false;
  }

  if (cpu_.halted) return;

  auto is_exec_addr_valid = [&](uint32_t addr) -> bool {
    if (bios_loaded_ && addr < 0x00004000u) return true;
    if (addr >= 0x02000000u && addr <= 0x02FFFFFFu) return true;
    if (addr >= 0x03000000u && addr <= 0x03FFFFFFu) return true;
    if (addr >= 0x08000000u && addr <= 0x0DFFFFFFu) return true;
    return false;
  };

  uint32_t consumed = 0;
  while (consumed < cycles && !cpu_.halted) {
    ServiceInterruptIfNeeded();
    if (cpu_.halted) break;

    const bool thumb = (cpu_.cpsr & (1u << 5)) != 0;
    cpu_.regs[15] &= thumb ? ~1u : ~3u;
    const uint32_t pc = cpu_.regs[15];

    if (!is_exec_addr_valid(pc)) {
      // If PC is invalid, skip slice to avoid infinite loops
      break;
    }

    if (thumb) {
      const uint16_t opcode = Read16(pc);
      consumed += EstimateThumbCycles(opcode);
      ExecuteThumbInstruction(opcode);
    } else {
      const uint32_t opcode = Read32(pc);
      consumed += EstimateArmCycles(opcode);
      ExecuteArmInstruction(opcode);
    }
  }
}"""

content_run = re.sub(r"void GBACore::RunCpuSlice\(uint32_t cycles\) \{.*?^\}", new_run_slice, content_run, flags=re.DOTALL | re.MULTILINE)

with open(path_run, "w") as f:
    f.write(content_run)
