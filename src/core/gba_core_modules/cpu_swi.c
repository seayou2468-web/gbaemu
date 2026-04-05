// Imported from reference implementation: cpu.c

#include "../common.h"

void gba_handle_arm_swi(u32 pc)
{
  reg_mode[MODE_SUPERVISOR][6] = pc + 4;
  spsr[MODE_SUPERVISOR] = reg[REG_CPSR];
  reg[REG_PC] = 0x00000008;
  reg[REG_CPSR] = (reg[REG_CPSR] & ~0x1F) | 0x13;
  set_cpu_mode(MODE_SUPERVISOR);
}

void gba_handle_thumb_swi(u32 pc)
{
  reg_mode[MODE_SUPERVISOR][6] = pc + 2;
  spsr[MODE_SUPERVISOR] = reg[REG_CPSR];
  reg[REG_PC] = 0x00000008;
  reg[REG_CPSR] = (reg[REG_CPSR] & ~0x3F) | 0x13;
  set_cpu_mode(MODE_SUPERVISOR);
}
