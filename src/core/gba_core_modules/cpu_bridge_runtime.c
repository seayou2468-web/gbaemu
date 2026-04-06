#include "../common.h"

u8 rom_translation_cache[ROM_TRANSLATION_CACHE_SIZE];
u8 ram_translation_cache[RAM_TRANSLATION_CACHE_SIZE];
u8 bios_translation_cache[BIOS_TRANSLATION_CACHE_SIZE];
u8 *rom_translation_ptr = rom_translation_cache;
u8 *ram_translation_ptr = ram_translation_cache;
u8 *bios_translation_ptr = bios_translation_cache;

u32 idle_loop_target_pc = 0xFFFFFFFF;
u32 force_pc_update_target = 0;
u32 iwram_stack_optimize = 0;
u32 allow_smc_ram_u8 = 0;
u32 allow_smc_ram_u16 = 0;
u32 allow_smc_ram_u32 = 0;
u32 translation_gate_targets = 0;
u32 translation_gate_target_pc[MAX_TRANSLATION_GATES];
u32 *rom_branch_hash[ROM_BRANCH_HASH_SIZE];

void flush_translation_cache_rom()
{
  rom_translation_ptr = rom_translation_cache;
}

void flush_translation_cache_ram()
{
  ram_translation_ptr = ram_translation_cache;
}

void flush_translation_cache_bios()
{
  bios_translation_ptr = bios_translation_cache;
}

void dump_translation_cache()
{
}
