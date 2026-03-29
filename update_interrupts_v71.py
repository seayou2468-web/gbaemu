import sys
import re

path = "src/core/gba_core_modules/apu_interrupts.mm"
with open(path, "r") as f:
    content = f.read()

# Wake up CPU even if IME=0 or CPSR.I=1 if IE & IF != 0
# GBA documentation says the HALT state is exited whenever (IE & IF) != 0.
# The ServiceInterruptIfNeeded only performs the Jump, but waking up is separate.

new_service = """void GBACore::ServiceInterruptIfNeeded() {
  const uint16_t ie = ReadIO16(0x04000200u);
  const uint16_t iflags = ReadIO16(0x04000202u);
  const uint16_t pending = static_cast<uint16_t>(ie & iflags);

  if (pending != 0) {
    cpu_.halted = false; // Always wake up if any enabled interrupt is pending
  }

  const uint16_t ime = ReadIO16(0x04000208u) & 0x1u;
  if (ime == 0) return;
  if (cpu_.cpsr & (1u << 7)) return;  // I flag set
  if (pending == 0) return;

  // Keep BIOS-style IRQ flags mirror in IWRAM
  const uint32_t irq_flags_addr = 0x03007FF8u;
  const uint32_t old_irq_flags = Read32(irq_flags_addr);
  Write32(irq_flags_addr, old_irq_flags | pending);

  const bool use_bios_irq = bios_loaded_ && bios_boot_via_vector_;
  if (use_bios_irq) {
    EnterException(0x00000018u, 0x12u, true, false);
    return;
  }
  const uint32_t irq_vector = Read32(0x03007FFCu);
  const bool vector_thumb = (irq_vector & 1u) != 0;
  const uint32_t vector_addr = irq_vector & ~1u;
  const bool vector_valid = (vector_addr >= 0x02000000u && vector_addr <= 0x0DFFFFFFu);
  if (vector_valid) {
    EnterException(vector_addr, 0x12u, true, vector_thumb);
    return;
  }
}"""

content = re.sub(r"void GBACore::ServiceInterruptIfNeeded\(\) \{.*?^\}", new_service, content, flags=re.DOTALL | re.MULTILINE)

with open(path, "w") as f:
    f.write(content)
