import sys
import re

path = "src/core/gba_core_modules/apu_interrupts.mm"
with open(path, "r") as f:
    content = f.read()

# Correct EnterException LR adjustment
# If PC is the address of the next instruction to execute:
# For IRQ: LR = PC + 4. SUBS PC, LR, #4 returns to PC.
# For SWI: handled in SWI logic, but usually LR = PC (where PC is already advanced)
# or LR = PC_at_SWI + 4/2.

new_enter_exception = """void GBACore::EnterException(uint32_t vector_addr, uint32_t new_mode, bool disable_irq, bool thumb_state) {
  const uint32_t old_cpsr = cpu_.cpsr;
  const uint32_t target_mode = new_mode & 0x1Fu;
  debug_last_exception_vector_ = vector_addr;
  debug_last_exception_pc_ = cpu_.regs[15];
  debug_last_exception_cpsr_ = old_cpsr;

  // GBA return address logic:
  // PC is the address of the instruction that would have been executed next.
  // For IRQ/FIQ: Handler returns with SUBS PC, LR, #4.
  // To return to PC, LR must be PC + 4.
  // For SWI/Undef: Handler returns with MOVS PC, LR (ARM) or similar.
  // To return to PC, LR must be PC.
  uint32_t lr_adjust = 0;
  if (vector_addr == 0x18u || vector_addr == 0x1Cu) { // IRQ or FIQ
    lr_adjust = 4;
  }

  SwitchCpuMode(target_mode);
  if (HasSpsr(target_mode)) cpu_.spsr[target_mode] = old_cpsr;
  cpu_.regs[14] = cpu_.regs[15] + lr_adjust;

  cpu_.cpsr = (cpu_.cpsr & ~0x1Fu) | target_mode;
  cpu_.active_mode = target_mode;
  if (disable_irq) cpu_.cpsr |= (1u << 7);

  cpu_.cpsr &= ~(1u << 5); // Exceptions always enter ARM mode
  cpu_.regs[15] = vector_addr;
}"""

content = re.sub(r"void GBACore::EnterException\(uint32_t vector_addr, uint32_t new_mode, bool disable_irq, bool thumb_state\) \{.*?^\}",
                 new_enter_exception, content, flags=re.DOTALL | re.MULTILINE)

with open(path, "w") as f:
    f.write(content)

# Also check HandleSoftwareInterrupt in cpu_swi.mm
swi_path = "src/core/gba_core_modules/cpu_swi.mm"
with open(swi_path, "r") as f:
    swi_content = f.read()

# For SWI, EnterException is called. We want to return to the instruction AFTER the SWI.
# PC is the address of the SWI instruction.
# ARM: next is PC + 4. Thumb: next is PC + 2.
# EnterException with lr_adjust=0 will set LR = PC.
# This is NOT what we want for SWI. We want LR = PC + 4 (ARM) or PC + 2 (Thumb).

new_swi_call = """if (bios_loaded_ && bios_boot_via_vector_) {
    // Save next instruction address to LR
    const bool thumb = (cpu_.cpsr & (1u << 5)) != 0;
    cpu_.regs[15] += thumb ? 2 : 4;
    EnterException(0x00000008u, 0x13u, true, thumb);
    return true;
  }"""
swi_content = re.sub(r"if \(bios_loaded_ && bios_boot_via_vector_\) \{.*?EnterException\(0x00000008u, 0x13u, true, thumb_state\);.*?return true;.*?\}",
                     new_swi_call, swi_content, flags=re.DOTALL | re.MULTILINE)

with open(swi_path, "w") as f:
    f.write(swi_content)
