// Legacy compatibility stub.
//
// The modern CPU runtime now lives in cpu_runtime.c/cpu_arm_execute.c/etc.
// Keep this file buildable for ad-hoc experiments, but compile it only when
// explicitly requested to avoid duplicate symbols with the real runtime.
#if defined(ENABLE_CPU_UNKNOWN_COMPAT_STUB)

#include "../common.h"
#include "../includes/cpu.h"
#include "../includes/memory.h"

u32 reg_data[45];
u32 *reg = reg_data;

extern debug_state current_debug_state;
extern u32 direct_map_vram;
extern u32 frame_ticks;
extern u32 breakpoint_value;
extern u16 palette_ram_converted[512];
u32 reg_mode[7][7];
u32 spsr[6];
u32 cpu_modes[32];
const u32 psr_masks[16] = {0};

u32 instruction_count = 0;
u32 last_instruction = 0;

u32 idle_loop_target_pc = 0xFFFFFFFF;
u32 force_pc_update_target = 0;
u32 iwram_stack_optimize = 1;
u32 allow_smc_ram_u8 = 0;
u32 allow_smc_ram_u16 = 0;
u32 allow_smc_ram_u32 = 0;
u32 translation_gate_targets = 0;
u32 translation_gate_target_pc[MAX_TRANSLATION_GATES] = {0};
u32 in_interrupt = 0;
static u32 compat_cycle_accum = 0;

u8 rom_translation_cache[ROM_TRANSLATION_CACHE_SIZE];
u8 ram_translation_cache[RAM_TRANSLATION_CACHE_SIZE];
u8 bios_translation_cache[BIOS_TRANSLATION_CACHE_SIZE];
u8 *rom_translation_ptr = rom_translation_cache;
u8 *ram_translation_ptr = ram_translation_cache;
u8 *bios_translation_ptr = bios_translation_cache;

u32 *rom_branch_hash[ROM_BRANCH_HASH_SIZE] = {0};

u32 memory_region_access_read_u8[16];
u32 memory_region_access_read_s8[16];
u32 memory_region_access_read_u16[16];
u32 memory_region_access_read_s16[16];
u32 memory_region_access_read_u32[16];
u32 memory_region_access_write_u8[16];
u32 memory_region_access_write_u16[16];
u32 memory_region_access_write_u32[16];
u32 memory_reads_u8 = 0;
u32 memory_reads_s8 = 0;
u32 memory_reads_u16 = 0;
u32 memory_reads_s16 = 0;
u32 memory_reads_u32 = 0;
u32 memory_writes_u8 = 0;
u32 memory_writes_u16 = 0;
u32 memory_writes_u32 = 0;


void flush_translation_cache_rom(void) {}
void flush_translation_cache_ram(void) {}
void flush_translation_cache_bios(void) {}
void dump_translation_cache(void) {}

void init_translater(void) {}

void set_cpu_mode(cpu_mode_type new_mode) { reg[CPU_MODE] = (u32)new_mode; }

void raise_interrupt(irq_type irq_raised)
{
  (void)irq_raised;
  in_interrupt = 1;
}

void debug_on(void) { current_debug_state = STEP; }
void debug_off(debug_state new_debug_state) { current_debug_state = new_debug_state; }

u32 execute_load_u8(u32 address) { return read_memory8(address); }
u32 execute_load_u16(u32 address) { return read_memory16(address); }
u32 execute_load_u32(u32 address) { return read_memory32(address); }
u32 execute_load_s8(u32 address) { return (s32)(s8)read_memory8(address); }
u32 execute_load_s16(u32 address) { return (s32)(s16)read_memory16(address); }
void execute_store_u8(u32 address, u32 source) { write_memory8(address, (u8)source); }
void execute_store_u16(u32 address, u32 source) { write_memory16(address, (u16)source); }
void execute_store_u32(u32 address, u32 source) { write_memory32(address, source); }

u8 *block_lookup_address_arm(u32 pc) { (void)pc; return NULL; }
u8 *block_lookup_address_thumb(u32 pc) { (void)pc; return NULL; }
s32 translate_block_arm(u32 pc, translation_region_type r, u32 smc) { (void)pc; (void)r; (void)smc; return 0; }
s32 translate_block_thumb(u32 pc, translation_region_type r, u32 smc) { (void)pc; (void)r; (void)smc; return 0; }

void cpu_write_mem_savestate(file_tag_type savestate_file) { (void)savestate_file; }
void cpu_read_savestate(file_tag_type savestate_file) { (void)savestate_file; }

void init_cpu(void)
{
  memset(reg_data, 0, sizeof(reg_data));
  memset(reg_mode, 0, sizeof(reg_mode));
  memset(spsr, 0, sizeof(spsr));
  instruction_count = 0;
  last_instruction = 0;
  current_debug_state = RUN;
}

void move_reg(u32 *new_reg)
{
  if (new_reg) {
    memcpy(reg_data, new_reg, sizeof(u32) * 45);
  }
}

u32 execute_arm_translate(u32 cycles)
{
  instruction_count += cycles;
  compat_cycle_accum += cycles;
  while (compat_cycle_accum >= 960) {
    compat_cycle_accum -= 960;
    frame_ticks++;
  }
  palette_ram_converted[0] = (u16)(instruction_count & 0x7FFF);
  return cycles;
}

void execute_arm(u32 cycles)
{
  execute_arm_translate(cycles);
}

void execute_arm_step(u32 cycles)
{
  execute_arm_translate(cycles);
}

#endif  // defined(ENABLE_CPU_UNKNOWN_COMPAT_STUB)
